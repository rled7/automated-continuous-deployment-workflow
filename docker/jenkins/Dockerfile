# Jenkins controller with the plugins in plugins.txt installed at build time.
# The official image does not install plugins from a mounted plugins.txt at
# runtime, so without this build step Jenkins started with no plugins, and
# without the configuration-as-code plugin jenkins.yaml was silently ignored.
FROM jenkins/jenkins:lts-jdk17 AS plugins
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

FROM jenkins/jenkins:lts-jdk17
COPY --from=plugins /usr/share/jenkins/ref/plugins /usr/share/jenkins/ref/plugins
