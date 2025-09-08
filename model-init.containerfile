FROM fedora:42

RUN dnf update && dnf install -y skopeo
