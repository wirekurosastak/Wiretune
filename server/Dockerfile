# The Wiretune server as a container image. Build it from the repository's root, which holds the core package too:
#
#   docker build -f server/Dockerfile -t wiretune-server .
#   docker build -f server/Dockerfile --build-arg WITH_FFMPEG=true -t wiretune-server:ffmpeg .   # converts for slow links
#   docker run -d -p 5200:5200 -v /srv/music:/music:ro -v wiretune-data:/data wiretune-server
#
# docs/server.md#docker says more. DART_VERSION is the Dart of the Flutter that CI uses (DART_VERSION in
# .github/workflows/release.yml).
ARG DART_VERSION=3.13.5

FROM dart:${DART_VERSION} AS build
WORKDIR /src
COPY packages/wiretune_core/ packages/wiretune_core/
COPY server/ server/
WORKDIR /src/server
RUN dart pub get --enforce-lockfile && dart build cli --output build

# The executable needs nothing but the C library; SQLite comes in the bundle's lib/. The same Debian as the build stage,
# so that the C library is the one it was built against.
FROM debian:trixie-slim
# ffmpeg (about 450 MB more) lets the server convert music to Opus or MP3 for players on a slow connection
# (docs/server.md#streaming-on-a-slow-connection): --build-arg WITH_FFMPEG=true. Without it the server sends the original
# files.
ARG WITH_FFMPEG=false
RUN if [ "$WITH_FFMPEG" = true ]; then \
        apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*; \
    fi
RUN useradd --system --uid 10001 --user-group --home-dir /data --no-create-home wiretune \
    && mkdir /data /music && chown wiretune:wiretune /data
COPY --from=build /src/server/build/bundle/ /opt/wiretune/
USER wiretune
ENV WIRETUNE_LIBRARY=/music \
    WIRETUNE_DATA_DIR=/data \
    WIRETUNE_HOST=0.0.0.0 \
    WIRETUNE_PORT=5200
VOLUME ["/data"]
EXPOSE 5200
ENTRYPOINT ["/opt/wiretune/bin/wiretune_server"]
