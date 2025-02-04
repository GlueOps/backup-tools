# Use an official Ubuntu runtime as a parent image
FROM ubuntu:22.04@sha256:ed1544e454989078f5dec1bfdabd8c5cc9c48e0705d07b678ab6ae3fb61952d2

ENV VERSION_AWS_CLI="2.18.12"
ENV VERSION_GH_CLI="2.59.0"
ENV VERSION_VAULT="1.14.10"

# Update the system and install required packages
RUN apt-get update -y && \
    apt-get upgrade -y && \
    apt-get install -y curl unzip groff-base less gnupg2 git jq && \
    rm -rf /var/lib/apt/lists/*

# Install specific AWS CLI version
RUN curl --proto =https "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${VERSION_AWS_CLI}.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install &&    \
    rm -rf awscliv2.zip aws

# Install Vault CLI
RUN curl --proto =https -fsSL https://releases.hashicorp.com/vault/${VERSION_VAULT}/vault_${VERSION_VAULT}_linux_amd64.zip -o vault.zip && \
    unzip vault.zip && \
    mv vault /usr/bin/ && \
    chmod +x /usr/bin/vault && \
    rm vault.zip

# Install GitHub CLI
RUN curl --proto =https -LO https://github.com/cli/cli/releases/download/v${VERSION_GH_CLI}/gh_${VERSION_GH_CLI}_linux_amd64.deb && \
    dpkg -i gh_${VERSION_GH_CLI}_linux_amd64.deb && \
    rm gh_${VERSION_GH_CLI}_linux_amd64.deb

# Set working directory in the container
RUN mkdir /app

ADD github-backup.sh /usr/bin/backup-github
ADD vault-backup.sh /usr/bin/backup-vault
ADD s3-backup.sh /usr/bin/s3-backup


WORKDIR /app

CMD ["bash"]
