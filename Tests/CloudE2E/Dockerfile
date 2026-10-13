# A disposable stand-in for a freshly installed Ubuntu 24.04 server, used to test
# Termuctive cloud projects end to end. Python is intentionally absent so the
# toolkit bootstrap is exercised exactly as on a new machine.
FROM ubuntu:24.04

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates openssh-server sudo \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd \
    && useradd --create-home --shell /bin/bash admin \
    && echo 'admin:termuctive' | chpasswd \
    && usermod -aG sudo admin

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
