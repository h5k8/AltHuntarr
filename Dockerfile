# syntax=docker/dockerfile:1
FROM alpine:3.22

LABEL org.opencontainers.image.title="altHuntarrrscript" \
      org.opencontainers.image.description="Small Sonarr/Radarr missing and cutoff search orchestrator" \
    org.opencontainers.image.source="https://github.com/h5k8/AltHuntarr" \
      org.opencontainers.image.licenses="MIT"

RUN apk add --no-cache \
        bash \
        coreutils \
        curl \
        jq \
        su-exec \
        util-linux \
    && install -d -m 0700 /config /data/state /data/logs /usr/share/althuntarr

COPY altHuntarrrscript.sh /usr/local/bin/altHuntarrrscript.sh
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY examples/config.example.json /usr/share/althuntarr/config.example.json

RUN chmod 0755 /usr/local/bin/altHuntarrrscript.sh /usr/local/bin/docker-entrypoint.sh \
    && chmod 0644 /usr/share/althuntarr/config.example.json

WORKDIR /config
VOLUME ["/config", "/data"]

ENV ALTHUNTARR_CONFIG=/config/config.json \
    ALTHUNTARR_SECRETS=/config/secrets.json \
    PUID=99 \
    PGID=100 \
    ALTHUNTARR_INTERVAL=900 \
    ALTHUNTARR_RUN_ONCE=false \
    ALTHUNTARR_DRY_RUN=false \
    ALTHUNTARR_SHOW_CANDIDATES=false

HEALTHCHECK --interval=1m --timeout=5s --start-period=10s --retries=3 \
    CMD ["/usr/local/bin/docker-entrypoint.sh", "healthcheck"]

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
