FROM registry.redhat.io/ubi9/ubi:latest

# Install required packages including SSH server
RUN dnf update -y && \
    dnf install -y \
    jq \
    tar \
    git \
    make \
    gcc \
    golang \
    gpgme-devel \
    device-mapper-devel \
    openssh-server \
    hostname \
    containers-common \
    && dnf clean all

# Build custom skopeo with encryption support
RUN git clone -b dev https://github.com/font/skopeo.git /tmp/skopeo && \
    cd /tmp/skopeo && \
    make bin/skopeo && \
    cp bin/skopeo /usr/local/bin/skopeo && \
    chmod +x /usr/local/bin/skopeo && \
    rm -rf /tmp/skopeo

# Configure SSH
RUN ssh-keygen -A && \
    mkdir -p /root/.ssh && \
    chmod 700 /root/.ssh

# Copy SSH configuration and authorized keys
COPY sshd_config /etc/ssh/sshd_config
COPY authorized_keys /root/.ssh/authorized_keys
RUN chmod 600 /root/.ssh/authorized_keys

# Copy the download script
COPY download-model.sh /usr/local/bin/download-model.sh
RUN chmod +x /usr/local/bin/download-model.sh

# Expose SSH port
EXPOSE 22

# Set the entrypoint to the download script
ENTRYPOINT ["/usr/local/bin/download-model.sh"]
