# Aurelia Server in a container. Built on your own computer from the newest stable server release
# on GitHub (checked against its SHA256SUMS); ffmpeg comes from Debian. See docs/DOCKER.md.
FROM docker.io/library/debian:trixie-slim

ARG AURELIA_REPOSITORY=lucaskleinsteuber/Aurelia
# Empty for the newest stable release, or a build number such as 135.
ARG AURELIA_BUILD=
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl jq libicu76 ffmpeg \
    && rm -rf /var/lib/apt/lists/*

COPY fetch-server.sh /tmp/fetch-server.sh
RUN bash /tmp/fetch-server.sh "$AURELIA_REPOSITORY" "${TARGETARCH:-$(dpkg --print-architecture)}" "$AURELIA_BUILD" \
    && rm /tmp/fetch-server.sh \
    && useradd --system --user-group --home-dir /data --no-create-home --shell /usr/sbin/nologin aurelia \
    && install -d -o aurelia -g aurelia -m 0700 /data

COPY aurelia /usr/local/bin/aurelia

ENV AURELIA_DATA_DIR=/data \
    HOME=/data \
    DOTNET_CLI_TELEMETRY_OPTOUT=1
WORKDIR /data
VOLUME /data
EXPOSE 43111
ENTRYPOINT ["/usr/local/bin/aurelia"]
CMD ["run"]
