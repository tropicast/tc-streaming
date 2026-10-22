# Caddy with the layer4 module, so the ingest host can carry raw Icecast
# source streams (PUT/SOURCE without Content-Length) after TLS (#6).
# The build runs on the builder's platform and Go cross-compiles for the
# target, so the arm64 CI runner builds the x86 image without emulation.
FROM --platform=$BUILDPLATFORM caddy:2.11.7-builder AS build
ARG TARGETOS TARGETARCH
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH xcaddy build v2.11.6 --with github.com/mholt/caddy-l4@v0.1.2

FROM caddy:2.11.7
COPY --from=build /usr/bin/caddy /usr/bin/caddy
