# The core version is a dependency of every plugin, so it is the first thing to
# bump and the last thing to guess. 2.479.1 was fine when this was written; the
# current plugin releases require 2.504.3, and the failure arrives as fifty
# lines of "requires a greater version of Jenkins" that name plugins rather than
# the base image. See plugins.txt.
FROM jenkins/jenkins:2.504.3-lts-jdk17

USER root

# The pipeline shells out to these, so they belong in the image rather than in
# a setup step somebody has to remember.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv \
        docker.io curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSLo /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl" \
    && chmod +x /usr/local/bin/kubectl

RUN curl -sSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.4.3/kustomize_v5.4.3_linux_amd64.tar.gz" \
        | tar xz -C /usr/local/bin

RUN pip3 install --break-system-packages --no-cache-dir \
        pytest ansible-core ansible-lint pyyaml jsonschema python-hcl2

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

USER jenkins
