#!/bin/sh
set -e

GO_VERSION="1.23.6"

install_go() {
    if command -v go >/dev/null 2>&1; then
        return
    fi
    curl -sSL -o /tmp/go.tgz "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" --insecure
    tar -C /usr/local -xzf /tmp/go.tgz
    export PATH=$PATH:/usr/local/go/bin
}

build_binary() {
    if [ -x /usr/local/bin/vai-snapshot ]; then
        return
    fi

    cat <<'EOGO' >/tmp/vai_snapshot.go
package main

import (
    "context"
    "database/sql"
    "log"
    "time"
    _ "modernc.org/sqlite"
)

func main() {
    ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
    defer cancel()

    db, err := sql.Open("sqlite", "/var/lib/rancher/informer_object_cache.db")
    if err != nil {
        log.Fatalf("open db: %v", err)
    }
    defer db.Close()

    if _, err = db.ExecContext(ctx, "VACUUM INTO '/tmp/snapshot.db'"); err != nil {
        log.Fatalf("vacuum: %v", err)
    }
}
EOGO

    mkdir -p /tmp/vai_snapshot
    mv /tmp/vai_snapshot.go /tmp/vai_snapshot/main.go
    cd /tmp/vai_snapshot
    go mod init vai-snapshot >/dev/null 2>&1 || true
    GO111MODULE=on go get modernc.org/sqlite >/dev/null
    go build -o /usr/local/bin/vai-snapshot .
}

install_go
build_binary
/bin/rm -f /tmp/snapshot.db
/usr/local/bin/vai-snapshot

