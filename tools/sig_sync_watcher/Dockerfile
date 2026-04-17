FROM ubuntu:24.04 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Download bootstrap-sig-v9 (dev=.full, supports build-exe)
RUN curl -sL "https://github.com/SB0LTD/sig/releases/download/bootstrap-sig-v9/bootstrap-sig-x86_64-linux.tar.gz" \
    | tar -xz -C /opt && \
    mv /opt/bin /opt/sig && \
    chmod +x /opt/sig/sig && \
    echo "sig binary ready"

WORKDIR /app

# Copy the sig standard library (needed for compilation)
COPY lib/ /app/lib/

# Copy watcher source
COPY tools/sig_sync_watcher/main.sig /app/main.sig

# Build a static musl binary
RUN /opt/sig/sig build-exe main.sig \
    --zig-lib-dir /app/lib \
    -target x86_64-linux-musl -OReleaseSafe \
    --name sig-sync-watcher

FROM alpine:3.21
RUN apk add --no-cache curl ca-certificates
COPY --from=builder /app/sig-sync-watcher /sig-sync-watcher

ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["/sig-sync-watcher"]
