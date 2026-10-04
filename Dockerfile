FROM debian:bookworm-slim AS build

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl pkg-config \
        libcurl4-openssl-dev libogg-dev librhash-dev libssl-dev \
        libvorbis-dev libxml2-dev libxslt1-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN curl -fsSL --retry 3 \
        https://downloads.xiph.org/releases/igloo/libigloo-0.9.5.tar.gz \
        -o libigloo.tar.gz \
    && echo "ea22e9119f7a2188810f99100c5155c6762d4595ae213b9ac29e69b4f0b87289  libigloo.tar.gz" | sha256sum -c - \
    && tar -xzf libigloo.tar.gz \
    && cd libigloo-0.9.5 \
    && ./configure --prefix=/usr/local \
    && make -j2 \
    && make install \
    && ldconfig

RUN curl -fsSL --retry 3 \
        https://downloads.xiph.org/releases/icecast/icecast-2.5.0.tar.gz \
        -o icecast.tar.gz \
    && echo "d9aa07c7429aec19d950ff6fd425c371f77158cd34ff220fc191b2c186c67c7a  icecast.tar.gz" | sha256sum -c - \
    && tar -xzf icecast.tar.gz \
    && cd icecast-2.5.0 \
    && PKG_CONFIG_PATH=/usr/local/lib/pkgconfig ./configure \
        --prefix=/usr/local --disable-yp \
    && make -j2 \
    && make install

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl python3 \
        libcurl4 libogg0 librhash0 libssl3 libvorbis0a libxml2 libxslt1.1 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 icecast \
    && useradd --uid 10001 --gid icecast --no-create-home \
        --shell /usr/sbin/nologin icecast \
    && install -d -o icecast -g icecast -m 0700 /run/icecast

COPY --from=build /usr/local/ /usr/local/
RUN ldconfig

COPY icecast.xml /etc/icecast/icecast.xml
COPY docker-entrypoint.py /usr/local/bin/docker-entrypoint.py

USER icecast
EXPOSE 8000

HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
    CMD curl --fail --silent --output /dev/null http://127.0.0.1:8000/status-json.xsl || exit 1

ENTRYPOINT ["python3", "/usr/local/bin/docker-entrypoint.py"]
