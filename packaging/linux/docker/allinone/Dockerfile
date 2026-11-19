# syntax=docker/dockerfile:1.7
#
# Josi + Ollama + the Josi model in ONE image.
#
#   ./build.sh            builds josi-allinone:v7 (needs the model file and the Josi .deb, see README.md)
#   ./install.sh          what a tester runs
#
# Layer order is on purpose, biggest and slowest-changing first:
#   1. the official Ollama image (pinned)
#   2. the Josi model, created inside it            <- the big layer, almost never changes
#   3. the operating system pieces Josi needs       <- systemd, python, rsync ...
#   4. Josi itself (the .deb)                        <- changes with every Josi update
#   5. our scripts and units                         <- a few kilobytes
# A Josi update therefore only re-pulls layers 4 and 5.
FROM ollama/ollama:0.40.16

ENV container=docker \
    DEBIAN_FRONTEND=noninteractive \
    OLLAMA_KEEP_ALIVE=-1 \
    OLLAMA_HOST=127.0.0.1:11434 \
    JOSI_BROWSER=0

# ---- 2. the model. The GGUF is read from a build context ("model") and never
# becomes a layer of its own: only Ollama's copy of it does. Ollama runs only
# for the length of this one command, with no GPU (creating a model needs none).
COPY Modelfile /tmp/Modelfile
RUN --mount=type=bind,from=model,source=/,target=/model \
    set -eu; \
    ollama serve > /tmp/ollama-build.log 2>&1 & \
    serve=$!; \
    i=0; until ollama list >/dev/null 2>&1; do i=$((i+1)); [ "$i" -lt 120 ] || { cat /tmp/ollama-build.log; echo "ollama did not start"; exit 1; }; sleep 1; done; \
    ollama create josi-qwen3.5-9b -f /tmp/Modelfile; \
    ollama list; \
    kill "$serve"; wait "$serve" || true; \
    # Ollama makes its own identity key the first time it runs; it must not be shared by every copy of this image.
    rm -f /tmp/Modelfile /tmp/ollama-build.log /root/.ollama/id_ed25519 /root/.ollama/id_ed25519.pub

# ---- 3. what Josi needs from the operating system. systemd runs Josi's own
# services exactly as on a real install (that is what the Josi package expects).
# No browser libraries: Josi's own browser is off in this image (it downloads
# Chrome when first used), so nothing is fetched at first run.
RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus sudo curl ca-certificates procps iproute2 \
      python3 rsync acl libstdc++6 unzip jq \
    && rm -rf /var/lib/apt/lists/* \
    && find /usr/lib/systemd/system /etc/systemd/system -path '*.wants/*' \
         \( -name '*getty*' -o -name '*udev*' -o -name '*update-utmp*' -o -name '*timesyncd*' -o -name '*apt-daily*' \) -delete \
    && systemctl mask getty.target console-getty.service systemd-udevd.service systemd-udev-trigger.service \
         systemd-timesyncd.service apt-daily.timer apt-daily-upgrade.timer \
         systemd-binfmt.service proc-sys-fs-binfmt_misc.automount proc-sys-fs-binfmt_misc.mount \
    && (id josi >/dev/null 2>&1 || useradd --create-home --shell /bin/bash josi)

# ---- 4. Josi. The package comes from a second build context ("pkg") so it is not
# stored twice. (systemd is not running during a build; the first start
# configures and starts Josi.)
RUN --mount=type=bind,from=pkg,source=/,target=/pkg \
    apt-get update && apt-get install -y --no-install-recommends /pkg/josi_*_amd64.deb \
    && rm -rf /var/lib/apt/lists/*

# ---- 5. our scripts and units
COPY josi-allinone-entry josi-allinone-warm josi-allinone-watch josi-allinone-health josi-firstboot josi-adopt.py josi-keyswap /usr/local/sbin/
COPY ollama-allinone.service josi-allinone-warm.service josi-allinone-watch.service josi-firstboot.service josi-keyswap.path josi-keyswap.service /etc/systemd/system/
RUN chmod 0755 /usr/local/sbin/josi-allinone-* /usr/local/sbin/josi-firstboot /usr/local/sbin/josi-keyswap \
    && systemctl enable ollama-allinone.service josi-allinone-warm.service josi-firstboot.service josi-allinone-watch.service josi-keyswap.path

# Josi's data lives in named volumes, never in the image.
VOLUME ["/var/lib/josi", "/var/lib/josi-pc", "/etc/josi", "/home/josi"]
EXPOSE 8080
STOPSIGNAL SIGRTMIN+3
HEALTHCHECK --interval=30s --timeout=10s --start-period=240s --retries=4 CMD ["/usr/local/sbin/josi-allinone-health"]
ENTRYPOINT ["/usr/local/sbin/josi-allinone-entry"]
