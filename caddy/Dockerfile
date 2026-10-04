# Caddy with the layer4 module, so the ingest host can carry raw Icecast
# source streams (PUT/SOURCE without Content-Length) after TLS (#6).
FROM caddy:2.11.6-builder AS build
RUN xcaddy build v2.11.6 --with github.com/mholt/caddy-l4@v0.1.2

FROM caddy:2.11.6
COPY --from=build /usr/bin/caddy /usr/bin/caddy
