FROM golang:1.23-alpine AS build
WORKDIR /app
COPY main.go .
RUN CGO_ENABLED=0 go build -o watcher main.go

FROM gcr.io/distroless/static-debian12
COPY --from=build /app/watcher /watcher
ENTRYPOINT ["/watcher"]
