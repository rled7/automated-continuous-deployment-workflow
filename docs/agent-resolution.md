# How builds get their agent

Every build should run in a `cicd-agent` pod: the agent image
(`docker/jenkins-agent/Dockerfile`, which has every tool the pipeline calls)
plus a Docker daemon in a `dind` sidecar. This page covers how Jenkins makes
sure of that however a pipeline asks for its agent, the bug that prompted it,
and how the harness checks it.

## The bug

The Jenkinsfile asked for its agent like this:

```groovy
agent {
    kubernetes {
        label 'cicd-agent'
        defaultContainer 'cicd'
    }
}
```

`jenkins.yaml` defines a pod template named and labelled `cicd-agent`, so it
looks as if this selects it. It doesn't. The Kubernetes plugin turns a
`kubernetes { }` block into a **new** pod template. `label` only names that
new template. It does not inherit anything from the existing template with
that label. The pod Jenkins started had just the plugin's default `jnlp`
container (stock `jenkins/inbound-agent`). It had no `cicd` container, no
tools and no Docker. Jenkins logs a hint, `label option is deprecated ... use
inheritFrom`, but the build carries on and fails later at whatever step first
needs a tool.

The `pr-preview-teardown` job in `jenkins.yaml` had the same block.

Fixing the Jenkinsfile to say `inheritFrom 'cicd-agent'` solves this one
case. But anyone can write the agent block a different way later. So Jenkins
is now configured to resolve every way of asking to the same pod, and the
harness checks each way.

## The fix: three layers

### 1. The preferred form, in the Jenkinsfile

```groovy
agent {
    kubernetes {
        inheritFrom 'cicd-agent'   // the pod template in jenkins.yaml
        defaultContainer 'cicd'    // steps run in the tools container
    }
}
```

`Jenkinsfile` and the `pr-preview-teardown` job both use this.

### 2. Every other way of asking, resolved by Jenkins' configuration

`docker/jenkins/jenkins.yaml`:

```yaml
jenkins:
  numExecutors: 0                          # (d) nothing builds on the controller
  clouds:
    - kubernetes:
        defaultsProviderTemplate: "cicd-agent"   # (a) every pod inherits cicd-agent
        templates:
          - name: "cicd-agent"
            label: "cicd-agent"                  # (b) label matching
            nodeUsageMode: NORMAL                # (c) builds that name no label
            containers:                          # (e) container templates, not yaml
              - name: "jnlp"                     # (f) the agent image here too
                image: "ghcr.io/YOUR_ORG/jenkins-cicd-agent:latest"
                envVars:
                  - envVar: {key: "DOCKER_HOST", value: "tcp://localhost:2375"}
              - name: "cicd"
                image: "ghcr.io/YOUR_ORG/jenkins-cicd-agent:latest"
                command: "sleep"
                args: "infinity"
              - name: "dind"
                image: "docker:27-dind"
                args: "dockerd --host=tcp://127.0.0.1:2375 --tls=false"
                privileged: true
            volumes:
              - emptyDirVolume: {mountPath: "/var/lib/docker"}
```

Each setting covers one way of asking:

| The pipeline says | What resolves it |
|---|---|
| `kubernetes { inheritFrom 'cicd-agent' }` | names the template directly |
| `kubernetes { label 'cicd-agent' }` (deprecated) | **(a)** the plugin puts `defaultsProviderTemplate` in front of every template's `inheritFrom`, so the new template inherits `cicd-agent` anyway |
| `kubernetes { yaml '...' }` (a pod of its own) | **(a)**, plus **(e)**: the plugin's default `yamlMergeStrategy` is *override*, so a pipeline's own yaml **replaces** the template's yaml. Container templates are always merged, so the containers are defined as container templates |
| `agent { label 'cicd-agent' }`, `node('cicd-agent')` | **(b)** the cloud provisions the template whose label matches |
| `agent any`, `node { }` | **(c)** a template in `NORMAL` mode also takes builds with no label; **(d)** with no controller executors, the cloud is the only place they can run |
| any of the above with no `defaultContainer` | **(f)** steps run in `jnlp`, which is the agent image with `DOCKER_HOST` set |

These are the plugin's own rules, read from its code (`kubernetes` plugin
4560.x):

- `PodTemplateUtils.unwrap(template, defaultProviderTemplate, all)` builds the
  parent list as `[defaultsProviderTemplate] + template.inheritFrom.split(' ')`.
- `PodTemplate.getNodeUsageMode()` defaults to `EXCLUSIVE`, which is why (c)
  is set explicitly.
- `PodTemplateStepExecution` uses `label` as the new template's label and
  `inheritFrom` (when given) as its parent. Nothing links the two.

### 3. The harness checks every way of asking

Two checks run the same list of agent blocks,
`harness/fixtures/agent-forms.Jenkinsfile`, which has one stage per syntax:

```groovy
pipeline {
    agent none
    stages {
        stage('kubernetes inheritFrom')        { agent { kubernetes { inheritFrom 'cicd-agent'; defaultContainer 'cicd' } } ... }
        stage('kubernetes label (deprecated)') { agent { kubernetes { label 'cicd-agent' } } ... }
        stage('kubernetes yaml only')          { agent { kubernetes { yaml '...' } } ... }
        stage('label')                         { agent { label 'cicd-agent' } ... }
        stage('any')                           { agent any ... }
    }
}
```

**Offline, in the `jenkins` stage** (`harness/lib/agent-resolution.groovy`,
runs anywhere Docker runs). In the running Jenkins, it does the following for
the Jenkinsfile, the fixture and every inline pipeline job:

1. Jenkins' own declarative parser reads the agent blocks. Every syntax is
   read the way Jenkins reads it, including stage-level and nested agents:

   ```groovy
   def model = new JsonSlurper().parseText(
       Converter.scriptToPipelineDef(text).toJSON().toString()).pipeline
   ```

2. The Kubernetes plugin's own code turns each block into the pod it would
   create. That covers inheritance, the defaults template and label matching:

   ```groovy
   def pod = { PodTemplate t ->
       def unwrapped = cloud.getUnwrappedTemplate(t)
       def agent = new KubernetesSlave.Builder().podTemplate(unwrapped).cloud(cloud).build()
       new PodTemplateBuilder(unwrapped, agent).build()
   }
   // kubernetes { ... }   → a PodTemplate with that label / inheritFrom / yaml
   // label 'x', node('x') → cloud.getTemplatesFor(Label.parseExpression('x'))
   // any                  → cloud.getTemplatesFor(null)
   ```

3. It then checks the pod. The container the steps run in (`defaultContainer`,
   else `jnlp`) must be the agent image and have `DOCKER_HOST`. A privileged
   `dind` container must have storage at `/var/lib/docker`. `jnlp` must not
   have its command replaced. The controller must have no executors.

Output (`harness/.results/logs/jenkins.log`):

```
── Jenkinsfile
ok    pipeline: kubernetes inheritFrom 'cicd-agent' → pod [dind, jnlp, cicd], steps in cicd
── harness/fixtures/agent-forms.Jenkinsfile
ok    stage 'kubernetes label (deprecated)': kubernetes label 'cicd-agent' (deprecated, use inheritFrom) → pod [dind, jnlp, cicd], steps in jnlp
ok    stage 'kubernetes yaml only': kubernetes → pod [dind, jnlp, cicd], steps in jnlp
ok    stage 'label': label 'cicd-agent' → template cicd-agent → pod [dind, jnlp, cicd], steps in jnlp
ok    stage 'any': any → template cicd-agent → pod [dind, jnlp, cicd], steps in jnlp
── job pr-preview-teardown
ok    pipeline: kubernetes inheritFrom 'cicd-agent' → pod [dind, jnlp, cicd], steps in cicd
```

To confirm the check catches regressions, each safeguard was switched off
in a running Jenkins:

| Switched off | Check reports |
|---|---|
| `defaultsProviderTemplate` | `kubernetes label (deprecated)` and `kubernetes yaml only` → `pod [jnlp]`, steps in `jenkins/inbound-agent`, no `DOCKER_HOST`, no `dind`. This is the original bug |
| `numExecutors: 0` (set to 2) | the controller has 2 executors: `agent any` would build on the controller |
| `nodeUsageMode: NORMAL` | `agent any`: no pod template takes builds without a label |

Before (e) moved the containers out of the template's yaml, the check also
failed `kubernetes yaml only` (`pod [jnlp]`). That is how the yaml override
rule was found.

**For real, in the `pipeline` stage** (kind, so a Linux host or GitHub
Actions). After the Jenkinsfile build, the stage runs the fixture as the
`agent-forms` job. Each stage starts its pod and runs:

```sh
for i in $(seq 60); do docker info >/dev/null 2>&1 && break; sleep 2; done
for c in git node npm trivy sonar-scanner kubectl kustomize; do command -v "$c" || exit 1; done
docker version --format 'Docker server {{.Server.Version}}'
```

Each stage is recorded as a step (`agent form: <stage>`), and its console log
is saved to `logs/pipeline-agent-forms.log`.

## What is still not covered

These fail the offline check with a message saying what to use instead:

- `agent { docker { ... } }` and `agent { dockerfile true }`. Jenkins would
  run the build in a container on the node, which here is a pod. Use
  `kubernetes { inheritFrom 'cicd-agent' }`.
- `kubernetes { yamlFile '...' }`. The file is read from the workspace at build
  time, so it can't be checked before the build.
- A label no template carries (`agent { label 'linux' }`). Nothing could ever
  run it, and the build would wait in the queue forever.
- Scripted pipelines (`node { }` outside a `pipeline { }` block). Jenkins'
  declarative parser can't read them. At run time, layers (a)–(f) still apply
  to them.

## Adding a new pod template

If a pipeline needs a different pod (more memory, another tool):

1. Add a template in `jenkins.yaml` that sets `inheritFrom: "cicd-agent"` and
   adds or overrides containers with container templates.
2. Ask for it with `kubernetes { inheritFrom '<name>' }`.
3. Run `harness/verify.sh jenkins`. A new stage in
   `harness/fixtures/agent-forms.Jenkinsfile` also makes the `pipeline` stage
   run it for real.
