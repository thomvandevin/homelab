FROM debian:bookworm-slim

# renovate: datasource=github-releases depName=kubernetes/kubernetes
ARG KUBECTL_VERSION=1.37.1
# renovate: datasource=github-releases depName=helm/helm
ARG HELM_VERSION=4.3.0
# renovate: datasource=github-releases depName=getsops/sops
ARG SOPS_VERSION=3.13.3
# renovate: datasource=github-releases depName=FiloSottile/age
ARG AGE_VERSION=1.3.2
# renovate: datasource=github-releases depName=cli/cli
ARG GH_VERSION=2.102.0
# renovate: datasource=gitlab-releases depName=gitlab-org/cli
ARG GLAB_VERSION=1.121.0
# renovate: datasource=github-releases depName=coder/code-server
ARG CODE_SERVER_VERSION=4.140.0
ARG NODE_MAJOR=24

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git gnupg jq less openssh-client openssh-server \
      procps ripgrep tmux unzip vim-tiny xz-utils \
    && curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN TARGETARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" | tar -xz -C /usr/local/bin --strip-components=1 "linux-${TARGETARCH}/helm" \
    && curl -fsSL "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${TARGETARCH}" -o /usr/local/bin/sops \
    && chmod +x /usr/local/bin/sops \
    && curl -fsSL "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-${TARGETARCH}.tar.gz" | tar -xz -C /usr/local/bin --strip-components=1 age/age age/age-keygen \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${TARGETARCH}.deb" -o /tmp/gh.deb \
    && curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${TARGETARCH}.deb" -o /tmp/glab.deb \
    && dpkg -i /tmp/gh.deb /tmp/glab.deb \
    && rm /tmp/*.deb \
    && curl -fsSL https://code-server.dev/install.sh | sh -s -- --method standalone --prefix /usr/local --version "${CODE_SERVER_VERSION}"

# sshd refuses to start without its privilege separation directory, even as
# a non-root user that cannot use it
RUN mkdir -p /run/sshd \
    && useradd --create-home --uid 1000 --shell /bin/bash dev

COPY sshd_config /opt/workspace/sshd_config
COPY entrypoint.sh rc-loop /usr/local/bin/
RUN chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/rc-loop

USER dev
WORKDIR /home/dev
ENV PATH="/home/dev/.local/bin:${PATH}"
EXPOSE 2222 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
