FROM factoriotools/factorio:stable

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/sync-github-mods.sh /usr/local/bin/sync-github-mods.sh
COPY scripts/factorio-entrypoint.sh /usr/local/bin/factorio-entrypoint.sh

RUN chmod +x /usr/local/bin/sync-github-mods.sh /usr/local/bin/factorio-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/factorio-entrypoint.sh"]
