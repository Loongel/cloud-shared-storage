FROM flyio/litefs:0.5 AS litefs
FROM kopia/kopia:0.23 AS kopia

FROM golang:1.22-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -buildvcs=false -o /out/cs-storage-server ./cmd/cs-storage-server  && CGO_ENABLED=0 go build -buildvcs=false -o /out/cs-storage-daemon ./cmd/cs-storage-daemon  && CGO_ENABLED=0 go build -buildvcs=false -o /out/cs-storage-plugin ./cmd/cs-storage-plugin  && CGO_ENABLED=0 go build -buildvcs=false -o /out/cs-storage-admin ./cmd/cs-storage-admin  && CGO_ENABLED=0 go build -buildvcs=false -o /out/cs-storage-router ./cmd/cs-storage-router

FROM debian:bookworm-slim
RUN apt-get update  && apt-get install -y --no-install-recommends ca-certificates fuse3 rclone gocryptfs glusterfs-client glusterfs-server sqlite3  && rm -rf /var/lib/apt/lists/*
COPY --from=litefs /usr/local/bin/litefs /usr/local/bin/litefs
COPY --from=kopia /usr/bin/kopia /usr/local/bin/kopia
COPY --from=build /out/ /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/cs-storage-server"]
