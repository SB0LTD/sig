ARG BOOTSTRAP_TAG=bootstrap-sig-v19

FROM ubuntu:24.04 AS builder

ARG BOOTSTRAP_TAG

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Download bootstrap sig (version from build arg)
RUN curl -sL "https://github.com/SB0LTD/sig/releases/download/${BOOTSTRAP_TAG}/bootstrap-sig-x86_64-linux.tar.gz" \
    | tar -xz -C /opt && \
    chmod +x /opt/bin/sig /opt/bin/zig && \
    echo "sig binary ready (${BOOTSTRAP_TAG})"

WORKDIR /app

# Copy the sig standard library (needed for compilation)
COPY lib/ /app/lib/

# Copy watcher source
COPY tools/sig_sync_watcher/main.sig /app/main.zig

# Build a static musl binary
RUN /opt/bin/sig build-exe main.zig \
    --zig-lib-dir /app/lib \
    -target x86_64-linux-musl -OReleaseSafe -lc \
    --name sig-sync-watcher

FROM alpine:3.21
RUN apk add --no-cache curl ca-certificates
COPY --from=builder /app/sig-sync-watcher /sig-sync-watcher

# Stateless — compares Codeberg RSS against sig repo manifest on every request.
# No in-memory state, cold starts are fine.
ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["/sig-sync-watcher"]
