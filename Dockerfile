# Use an official Ubuntu runtime as a parent image
FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

# renovate: datasource=github-tags depName=aws/aws-cli
ARG VERSION_AWS_CLI=2.35.15
# renovate: datasource=github-tags depName=cli/cli
ARG VERSION_GH_CLI=2.96.0
# renovate: datasource=github-tags depName=openbao/openbao
ARG VERSION_OPENBAO=2.5.5
# renovate: datasource=github-tags depName=grafana/loki
ARG VERSION_LOKI=3.7.6
# renovate: datasource=github-releases depName=restic/restic
ARG VERSION_RESTIC=0.19.1

# Update the system and install required packages
RUN apt-get update -y && \
    apt-get upgrade -y && \
    apt-get install -y curl unzip bzip2 groff-base less gnupg2 git jq tmux && \
    rm -rf /var/lib/apt/lists/*

# Install loki's logcli
RUN curl --proto =https -L -o logcli-linux-amd64.zip https://github.com/grafana/loki/releases/download/v${VERSION_LOKI}/logcli-linux-amd64.zip \
    && unzip logcli-linux-amd64.zip \
    && mv logcli-linux-amd64 /usr/bin/logcli \
    && rm logcli-linux-amd64.zip

# Install specific AWS CLI version
RUN curl --proto =https "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${VERSION_AWS_CLI}.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install &&    \
    rm -rf awscliv2.zip aws

# renovate: datasource=github-tags depName=openbao/openbao
ARG VERSION_OPENBAO=2.5.5

#Download and install Bao
ADD https://github.com/openbao/openbao/releases/download/v${VERSION_OPENBAO}/bao_${VERSION_OPENBAO}_Linux_x86_64.tar.gz /tmp/bao_${VERSION_OPENBAO}_Linux_x86_64.tar.gz

# Unzip the Bao binary and clean up
RUN tar -xzvf /tmp/bao_${VERSION_OPENBAO}_Linux_x86_64.tar.gz bao && mv bao /usr/local/bin/bao && \
    rm /tmp/bao_${VERSION_OPENBAO}_Linux_x86_64.tar.gz

    
# Install GitHub CLI
RUN curl --proto =https -LO https://github.com/cli/cli/releases/download/v${VERSION_GH_CLI}/gh_${VERSION_GH_CLI}_linux_amd64.deb && \
    dpkg -i gh_${VERSION_GH_CLI}_linux_amd64.deb && \
    rm gh_${VERSION_GH_CLI}_linux_amd64.deb

# Install restic (single static binary, shipped bzip2-compressed)
RUN curl --proto =https -fsSL -o /tmp/restic.bz2 \
      "https://github.com/restic/restic/releases/download/v${VERSION_RESTIC}/restic_${VERSION_RESTIC}_linux_amd64.bz2" && \
    bunzip2 -c /tmp/restic.bz2 > /usr/local/bin/restic && \
    chmod 0755 /usr/local/bin/restic && \
    rm -f /tmp/restic.bz2 && \
    restic version

# Set working directory in the container
RUN mkdir /app

ADD github-backup.sh /usr/bin/backup-github
ADD vault-backup.sh /usr/bin/backup-vault
ADD s3-backup.sh /usr/bin/s3-backup
ADD nfs-backup.sh /usr/bin/backup-nfs
ADD nfs-restore.sh /usr/bin/restore-nfs
ADD restic-common.sh /usr/lib/backup-tools/restic-common.sh
RUN chmod 0755 /usr/bin/backup-nfs /usr/bin/restore-nfs && \
    chmod 0644 /usr/lib/backup-tools/restic-common.sh

ENV CACHED_VERSION_OPENBAO=${VERSION_OPENBAO}

WORKDIR /app

CMD ["bash"]
