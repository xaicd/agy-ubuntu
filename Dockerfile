###############################################################################
# agy-ubuntu — sandboxed Ubuntu 24.04 dev container
#
#   * 100% of internal traffic is routed through an embedded Mihomo
#     (Clash Meta) TUN interface (clash0)
#   * Totally isolated from the host network: runs on the DEFAULT bridge,
#     never on --network host
#   * Google Antigravity CLI (agy) pre-installed
#
# OFFLINE build: all binaries/packages are pre-downloaded into ./downloads/
# (see the host-side bootstrap in this repo) and COPYed in, so the build makes
# no network requests at all. This sidesteps the host's flaky container egress.
###############################################################################

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# agy (and other user-local tools) install into /root/.local/bin —
# make that directory globally resolvable.
ENV PATH="/root/.local/bin:${PATH}"

#------------------------------------------------------------------------------
# Base dev tools — pre-downloaded .debs with the full dependency closure
# (ca-certificates, curl, git, iproute2, iptables, nano, tzdata, xdg-utils).
# dpkg two-pass (unpack all, then configure) resolves ordering correctly.
#------------------------------------------------------------------------------
COPY downloads/debs/ /tmp/debs/
RUN dpkg --unpack /tmp/debs/*.deb && \
    dpkg --configure -a && \
    rm -rf /tmp/debs

#------------------------------------------------------------------------------
# Mihomo (Clash Meta) core — stable v1.18.0, linux-amd64 (pre-downloaded)
#------------------------------------------------------------------------------
RUN mkdir -p /root/.config/mihomo
COPY downloads/mihomo /usr/local/bin/mihomo
RUN chmod +x /usr/local/bin/mihomo

#------------------------------------------------------------------------------
# Google Antigravity CLI — pre-downloaded tarball (contains binary `antigravity`)
#------------------------------------------------------------------------------
COPY downloads/agy.tar.gz /tmp/agy.tar.gz
RUN mkdir -p /root/.local/bin && \
    tar -xzf /tmp/agy.tar.gz -C /tmp/ antigravity && \
    mv /tmp/antigravity /root/.local/bin/agy && \
    chmod +x /root/.local/bin/agy && \
    rm -f /tmp/agy.tar.gz

#------------------------------------------------------------------------------
# Entrypoint + default workspace
#------------------------------------------------------------------------------
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /root/workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
