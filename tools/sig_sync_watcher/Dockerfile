FROM alpine:3.19 AS builder

RUN apk add --no-cache curl xz
ARG SIG_VERSION=latest
RUN DOWNLOAD_URL=$(curl -s https://api.github.com/repos/SB0LTD/sig/releases/${SIG_VERSION} \
    | grep -o '"browser_download_url": *"[^"]*x86_64-linux[^"]*\.tar\.xz"' \
    | head -1 | cut -d'"' -f4) && \
    curl -L "$DOWNLOAD_URL" | tar -xJ -C /opt && \
    ln -s /opt/sig-*/bin/sig /usr/local/bin/sig

WORKDIR /app
COPY main.sig main.sig

RUN sig build-exe main.sig \
    -target x86_64-linux-musl -OReleaseSafe \
    --name sig-sync-watcher

FROM scratch
COPY --from=builder /app/sig-sync-watcher /sig-sync-watcher
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["/sig-sync-watcher"]
