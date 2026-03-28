FROM alpine:3.19 AS builder

# Install Zig
RUN apk add --no-cache curl xz
ARG ZIG_VERSION=0.16.0-dev.3006+94355f192
RUN curl -L https://ziglang.org/builds/zig-linux-x86_64-${ZIG_VERSION}.tar.xz | tar -xJ -C /opt
ENV PATH="/opt/zig-linux-x86_64-${ZIG_VERSION}:$PATH"

WORKDIR /app

# Copy sig library and watcher source
COPY lib/sig/ lib/sig/
COPY tools/sig_sync_watcher/main.sig tools/sig_sync_watcher/main.sig

# Build static binary — .sig files are syntactically identical to .zig
RUN zig build-exe tools/sig_sync_watcher/main.sig \
    --mod sig::lib/sig/sig.zig \
    --deps sig \
    -target x86_64-linux-musl -OReleaseSafe \
    --name sig-sync-watcher

# Minimal runtime image
FROM scratch
COPY --from=builder /app/sig-sync-watcher /sig-sync-watcher
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["/sig-sync-watcher"]
