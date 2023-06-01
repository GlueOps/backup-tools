# Use an official Ubuntu runtime as a parent image
FROM ubuntu:22.04

ENV VERSION_AWS_CLI="2.11.24"
ENV VERSION_GH_CLI="2.30.0"
ENV VERSION_RCLONE="1.62.2"

# Update the system and install required packages
RUN apt-get update -y && \
    apt-get upgrade -y && \
    apt-get install -y curl unzip groff-base less gnupg2 git && \
    rm -rf /var/lib/apt/lists/*

# Install specific AWS CLI version
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${VERSION_AWS_CLI}.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install &&    \
    rm -rf awscliv2.zip aws

# Install GitHub CLI
RUN curl -LO https://github.com/cli/cli/releases/download/v${VERSION_GH_CLI}/gh_${VERSION_GH_CLI}_linux_amd64.deb && \
    dpkg -i gh_${VERSION_GH_CLI}_linux_amd64.deb && \
    rm gh_${VERSION_GH_CLI}_linux_amd64.deb

RUN curl -LO https://github.com/rclone/rclone/releases/download/v${VERSION_RCLONE}/rclone-v${VERSION_RCLONE}-linux-amd64.deb && \
    dpkg -i rclone-v${VERSION_RCLONE}-linux-amd64.deb && \
    rm rclone-v${VERSION_RCLONE}-linux-amd64.deb
ADD rclone.conf /root/.config/rclone/rclone.conf

# Set working directory in the container
RUN mkdir /backups
WORKDIR /backups

ADD github-backup.sh /backups/github-backup.sh
ADD gdrive-backup.sh /backups/gdrive-backup.sh

CMD ["bash"]
