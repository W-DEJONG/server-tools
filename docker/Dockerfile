ARG DEBIAN_CODENAME=bookworm
FROM debian:${DEBIAN_CODENAME}

ARG DEBIAN_CODENAME
ENV DEBIAN_FRONTEND=noninteractive
ENV NEEDRESTART_MODE=a
ENV container=docker
ENV TZ=UTC

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        systemd \
        systemd-sysv \
        dbus \
        tzdata \
        sudo \
        curl \
        wget \
        gnupg \
        lsb-release \
        ca-certificates \
        procps \
        iproute2 \
        vim-tiny \
        less \
    && ln -fs /usr/share/zoneinfo/UTC /etc/localtime \
    && dpkg-reconfigure -f noninteractive tzdata \
    && useradd -m -s /bin/bash admin \
    && ln -s /usr/local/lib/server-tools/server-tool /usr/local/bin/server-tool \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Drop default systemd units that do not make sense in a container
RUN find /etc/systemd/system /lib/systemd/system \
        -path '*.wants/*' \
        -not -name '*journald*' \
        -not -name '*systemd-tmpfiles*' \
        -not -name '*systemd-user-sessions*' \
        -not -name '*dbus*' \
        -exec rm -f {} + \
    && mkdir -p /etc/systemd/system/multi-user.target.wants \
    && ln -sf /lib/systemd/system/dbus.service /etc/systemd/system/multi-user.target.wants/dbus.service

STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
