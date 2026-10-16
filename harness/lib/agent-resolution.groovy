// Resolves every agent a declarative pipeline asks for the way Jenkins does,
// and checks that each one becomes a pod whose steps run in the agent image
// next to a Docker daemon. Runs in Jenkins' script console. Checks the
// pipelines the harness passes in (__PIPELINES__: name → base64 text) and
// every pipeline job defined inline in Jenkins.
//
// Jenkins' own parser reads the agent blocks (so every syntax is understood
// the way Jenkins understands it), and the Kubernetes plugin's own code turns
// each one into a pod (pod template inheritance, the cloud's
// defaultsProviderTemplate, label matching). See docs/agent-resolution.md.
import groovy.json.JsonSlurper
import hudson.model.Label
import jenkins.model.Jenkins
import org.csanchez.jenkins.plugins.kubernetes.KubernetesCloud
import org.csanchez.jenkins.plugins.kubernetes.KubernetesSlave
import org.csanchez.jenkins.plugins.kubernetes.PodTemplate
import org.csanchez.jenkins.plugins.kubernetes.PodTemplateBuilder
import org.jenkinsci.plugins.pipeline.modeldefinition.parser.Converter
import org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition
import org.jenkinsci.plugins.workflow.job.WorkflowJob

def PIPELINES = __PIPELINES__

def j = Jenkins.get()
j.getAllItems(WorkflowJob).each { job ->
    if (job.definition instanceof CpsFlowDefinition) {
        PIPELINES["job ${job.fullName}"] = Base64.encoder.encodeToString(job.definition.script.getBytes('UTF-8'))
    }
}
def failures = 0
def fail = { msg -> println "FAIL  $msg"; failures++ }

def cloud = j.clouds.find { it instanceof KubernetesCloud }
if (cloud == null) { println 'FAIL  no Kubernetes cloud in jenkins.yaml'; return }
def base = cloud.templates.find { it.name == 'cicd-agent' }
if (base == null) { println 'FAIL  no cicd-agent pod template in the Kubernetes cloud'; return }
// The pod the plugin would create, built by the plugin for an agent that is
// never registered or launched.
def pod = { PodTemplate t ->
    def unwrapped = cloud.getUnwrappedTemplate(t)
    def agent = new KubernetesSlave.Builder().podTemplate(unwrapped).cloud(cloud).build()
    new PodTemplateBuilder(unwrapped, agent).build()
}
def agentImage = pod(base).spec.containers.find { it.name == 'cicd' }?.image
println "agent image (cicd container of cicd-agent): $agentImage"
println "defaultsProviderTemplate: ${cloud.defaultsProviderTemplate ?: '(none)'}"
println "controller executors: ${j.numExecutors}"
if (j.numExecutors != 0) {
    fail "the controller has ${j.numExecutors} executors: agent any (and node()) would build on the controller, without the tools"
}

// One agent block → [description, pod, container the steps run in], or a
// String saying why it cannot resolve.
def resolve = { Map agent ->
    def args = [:]
    agent.arguments.each { args[it.key] = it.value?.value }
    if (agent.argument != null) args.label = agent.argument.value
    switch (agent.type) {
        case 'kubernetes':
            if (args.yamlFile) return "kubernetes yamlFile '${args.yamlFile}' is read from the workspace at build time; use inheritFrom 'cicd-agent'"
            def t = new PodTemplate()
            t.label = args.label ?: 'agent-resolution-check'
            t.inheritFrom = args.inheritFrom
            if (args.yaml) t.yaml = args.yaml
            def how = args.inheritFrom ? "kubernetes inheritFrom '${args.inheritFrom}'" :
                      args.label ? "kubernetes label '${args.label}' (deprecated, use inheritFrom)" : 'kubernetes'
            return [how, pod(t), args.defaultContainer ?: 'jnlp']
        case 'label':
        case 'node':
            if (!args.label) return "agent ${agent.type} without a label"
            def matches = cloud.getTemplatesFor(Label.parseExpression(args.label))
            if (!matches) return "label '${args.label}' matches no pod template; nothing could ever run it"
            return ["${agent.type} '${args.label}' → template ${matches[0].name}", pod(matches[0]), 'jnlp']
        case 'any':
            def matches = cloud.getTemplatesFor(null)
            if (!matches) return 'agent any: no pod template takes builds without a label (nodeUsageMode NORMAL)'
            return ["any → template ${matches[0].name}", pod(matches[0]), 'jnlp']
        case 'none':
            return null
        default:
            return "agent ${agent.type} is not a Kubernetes pod; use kubernetes { inheritFrom 'cicd-agent' }"
    }
}

// Every agent block in the pipeline, with the stage it belongs to.
def agents
agents = { node, String where ->
    def found = []
    if (node instanceof Map) {
        def here = node.name ? "stage '${node.name}'" : where
        if (node.agent instanceof Map) found << [here, node.agent]
        node.each { k, v -> if (k != 'agent') found.addAll(agents(v, here)) }
    } else if (node instanceof List) {
        node.each { found.addAll(agents(it, where)) }
    }
    found
}

PIPELINES.each { name, encoded ->
    println "── $name"
    def text = new String(Base64.decoder.decode(encoded), 'UTF-8')
    def model
    try {
        model = new JsonSlurper().parseText(Converter.scriptToPipelineDef(text).toJSON().toString()).pipeline
    } catch (e) {
        fail "$name: not a declarative pipeline Jenkins can parse: ${e.message?.readLines()?.first()}"
        return
    }
    def blocks = agents(model, 'pipeline')
    if (!blocks) fail "$name: no agent block"
    blocks.each { where, agent ->
        def r = resolve(agent)
        if (r == null) { println "ok    $where: agent none"; return }
        if (r instanceof String) { fail "$where: $r"; return }
        def (how, p, stepsIn) = r
        def names = p.spec.containers*.name
        def steps = p.spec.containers.find { it.name == stepsIn }
        def problems = []
        if (steps == null) problems << "steps run in container '$stepsIn', which the pod does not have"
        else {
            if (steps.image != agentImage) problems << "steps run in '$stepsIn' (${steps.image}), not the agent image"
            if (!steps.env?.any { it.name == 'DOCKER_HOST' }) problems << "'$stepsIn' has no DOCKER_HOST for the dind sidecar"
        }
        def dind = p.spec.containers.find { it.name == 'dind' }
        if (dind == null) problems << 'no dind container (Docker stages need it)'
        else {
            if (!dind.securityContext?.privileged) problems << 'dind is not privileged'
            if (!dind.volumeMounts?.any { it.mountPath == '/var/lib/docker' }) problems << 'dind has no volume at /var/lib/docker'
        }
        if (p.spec.containers.find { it.name == 'jnlp' }?.command) problems << 'jnlp has a command, which replaces the agent connection'
        def line = "$where: $how → pod [${names.join(', ')}], steps in $stepsIn"
        if (problems) fail "$line: ${problems.join('; ')}" else println "ok    $line"
    }
}
println(failures ? "RESULT: $failures problem(s)" : 'RESULT: every agent resolves to the agent image with Docker')
