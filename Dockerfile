# Use an official Ubuntu runtime as a parent image
FROM ubuntu:22.04@sha256:77906da86b60585ce12215807090eb327e7386c8fafb5402369e421f44eff17e

ENV VERSION_AWS_CLI="2.15.30"
ENV VERSION_GH_CLI="2.44.1"
ENV VERSION_RCLONE="1.66.0"
ENV VERSION_VAULT="1.14.10"
ENV VERSION_LOKI="2.9.6"

# Update the system and install required packages
RUN apt-get update -y && \
    apt-get upgrade -y && \
    apt-get install -y curl unzip groff-base less gnupg2 git jq && \
    rm -rf /var/lib/apt/lists/*

# Install specific AWS CLI version
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${VERSION_AWS_CLI}.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install &&    \
    rm -rf awscliv2.zip aws

# Install Vault CLI
RUN curl -fsSL https://releases.hashicorp.com/vault/${VERSION_VAULT}/vault_${VERSION_VAULT}_linux_amd64.zip -o vault.zip && \
    unzip vault.zip && \
    mv vault /usr/bin/ && \
    chmod +x /usr/bin/vault && \
    rm vault.zip

# Install loki's logcli
RUN curl -L -o logcli-linux-amd64.zip https://github.com/grafana/loki/releases/download/v${VERSION_LOKI}/logcli-linux-amd64.zip \
    && unzip logcli-linux-amd64.zip \
    && mv logcli-linux-amd64 /usr/bin/logcli \
    && rm logcli-linux-amd64.zip

# Install GitHub CLI
RUN curl -LO https://github.com/cli/cli/releases/download/v${VERSION_GH_CLI}/gh_${VERSION_GH_CLI}_linux_amd64.deb && \
    dpkg -i gh_${VERSION_GH_CLI}_linux_amd64.deb && \
    rm gh_${VERSION_GH_CLI}_linux_amd64.deb

RUN curl -LO https://github.com/rclone/rclone/releases/download/v${VERSION_RCLONE}/rclone-v${VERSION_RCLONE}-linux-amd64.deb && \
    dpkg -i rclone-v${VERSION_RCLONE}-linux-amd64.deb && \
    rm rclone-v${VERSION_RCLONE}-linux-amd64.deb
ADD rclone.conf /root/.config/rclone/rclone.conf

# Set working directory in the container
RUN mkdir /app

ADD github-backup.sh /usr/bin/backup-github
ADD gdrive-backup.sh /usr/bin/backup-gdrive
ADD loki-logcli-backup.sh /usr/bin/backup-loki-logs-as-json
ADD vault-backup.sh /usr/bin/backup-vault
ADD s3-backup.sh /usr/bin/s3-backup


WORKDIR /app

CMD ["bash"]
