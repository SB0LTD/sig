FROM ubuntu:24.04 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl xz-utils ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Download upstream zig (stable, known to work) to compile the watcher.
# The watcher only uses std APIs, so upstream zig compiles it fine.
RUN curl -L "https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz" \
    | tar -xJ -C /opt && \
    ln -s /opt/zig-linux-x86_64-0.13.0/zig /usr/local/bin/zig && \
    zig version

WORKDIR /app
COPY main.sig main.zig

# Build a static musl binary
RUN zig build-exe main.zig \
    -target x86_64-linux-musl -OReleaseSafe \
    --name sig-sync-watcher

FROM scratch
COPY --from=builder /app/sig-sync-watcher /sig-sync-watcher
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["/sig-sync-watcher"]
