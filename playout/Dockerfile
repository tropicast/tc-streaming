# AutoDJ playout worker (#63): Liquidsoap plus the supervisor that runs one
# Liquidsoap process per station. Pinned by digest: the encoders decide what
# listeners hear when a station falls back to AutoDJ.
FROM savonet/liquidsoap:v2.4.6@sha256:1d4ecfc1b53851c5f018d1ada430302a0678f789a6e96f6de5264255f679689c

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/*

COPY supervisor.py /usr/local/bin/playout-supervisor.py

# The image's liquidsoap user (uid 100). Track cache and per-station state
# are volumes or tmpfs (see compose.yaml).
RUN install -d -o liquidsoap -g liquidsoap -m 0750 /var/cache/playout /run/playout
USER liquidsoap

HEALTHCHECK --interval=15s --timeout=3s --start-period=30s --retries=3 \
    CMD ["python3", "/usr/local/bin/playout-supervisor.py", "healthcheck"]

ENTRYPOINT ["python3", "-u", "/usr/local/bin/playout-supervisor.py"]
