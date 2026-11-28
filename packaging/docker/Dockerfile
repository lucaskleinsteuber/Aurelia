# Tarven Server in a container. Built on your own computer from the newest stable server release
# on GitHub (checked against its signed SHA256SUMS); ffmpeg comes from Debian. See docs/DOCKER.md.
FROM docker.io/library/debian:trixie-slim

ARG TARVEN_REPOSITORY=lucaskleinsteuber/Tarven
# Empty for the newest stable release, or a signed build number (153 and newer), such as 175.
ARG TARVEN_BUILD=
ARG TARGETARCH

# With ffmpeg come the VA-API drivers for a video chip passed in with /dev/dri: AMD, and Intel on amd64.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl jq openssl libicu76 ffmpeg mesa-va-drivers \
    && if [ "${TARGETARCH:-$(dpkg --print-architecture)}" = amd64 ]; then \
         apt-get install -y --no-install-recommends intel-media-va-driver i965-va-driver; fi \
    && (apt-get install -y --no-install-recommends whisper.cpp || echo "whisper.cpp is not in this Debian; subtitles from speech stay off.") \
    && rm -rf /var/lib/apt/lists/*

COPY fetch-server.sh /tmp/fetch-server.sh
RUN bash /tmp/fetch-server.sh "$TARVEN_REPOSITORY" "${TARGETARCH:-$(dpkg --print-architecture)}" "$TARVEN_BUILD" \
    && rm /tmp/fetch-server.sh \
    && useradd --system --user-group --home-dir /data --no-create-home --shell /usr/sbin/nologin tarven \
    && install -d -o tarven -g tarven -m 0700 /data

COPY tarven /usr/local/bin/tarven
# Compose files from before the rename to Tarven call the command `aurelia`.
RUN ln -s tarven /usr/local/bin/aurelia

ENV TARVEN_DATA_DIR=/data \
    HOME=/data \
    DOTNET_CLI_TELEMETRY_OPTOUT=1
WORKDIR /data
VOLUME /data
EXPOSE 43111
ENTRYPOINT ["/usr/local/bin/tarven"]
CMD ["run"]
