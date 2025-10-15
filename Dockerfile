# Use an official Ubuntu runtime as a parent image
FROM ubuntu:24.04@sha256:66460d557b25769b102175144d538d88219c077c678a49af4afca6fbfc1b5252

# renovate: datasource=github-tags depName=aws/aws-cli
ARG VERSION_AWS_CLI=2.31.15
# renovate: datasource=github-tags depName=cli/cli
ARG VERSION_GH_CLI=2.63.2
# renovate: datasource=github-tags depName=openbao/openbao
ARG VERSION_OPENBAO=2.4.1
# renovate: datasource=github-tags depName=grafana/loki
ARG VERSION_LOKI=2.9.10

# Update the system and install required packages
RUN apt-get update -y && \
    apt-get upgrade -y && \
    apt-get install -y curl unzip groff-base less gnupg2 git jq tmux && \
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

# Install OpenBao CLI
RUN curl --proto =https -LO https://github.com/openbao/openbao/releases/download/v${VERSION_OPENBAO}/bao_${VERSION_OPENBAO}_linux_amd64.deb && \
    dpkg -i bao_${VERSION_OPENBAO}_linux_amd64.deb && \
    rm bao_${VERSION_OPENBAO}_linux_amd64.deb
    
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
