#!/bin/sh
# vai-snapshot.sh - Creates VAI snapshot, outputs ONLY base64 or ERROR
set -e

# Use cached tool
[ -x /tmp/vai-vacuum ] && exec /tmp/vai-vacuum

# Setup Go silently
export PATH=$PATH:/usr/local/go/bin
if ! command -v go >/dev/null 2>&1; then
    cd /tmp >/dev/null 2>&1
    curl -sL https://go.dev/dl/go1.23.6.linux-amd64.tar.gz -o go.tar.gz 2>/dev/null || { echo "ERROR: Failed to download Go"; exit 1; }
    tar -C /usr/local -xzf go.tar.gz 2>/dev/null || { echo "ERROR: Failed to install Go"; exit 1; }
fi

# Build vacuum tool
cd /tmp >/dev/null 2>&1
cat > vacuum.go << 'EOF'
package main
import (
    "database/sql"
    "encoding/base64"
    "fmt"
    "io"
    "os"
    _ "modernc.org/sqlite"
)
func main() {
    db, err := sql.Open("sqlite", "/var/lib/rancher/informer_object_cache.db?mode=ro")
    if err != nil {
        fmt.Printf("ERROR: Failed to open database: %v\n", err)
        os.Exit(1)
    }
    defer db.Close()
    
    if _, err = db.Exec("VACUUM INTO '/tmp/snapshot.db'"); err != nil {
        fmt.Printf("ERROR: Failed to create snapshot: %v\n", err)
        os.Exit(1)
    }
    
    f, err := os.Open("/tmp/snapshot.db")
    if err != nil {
        fmt.Printf("ERROR: Failed to read snapshot: %v\n", err)
        os.Exit(1)
    }
    defer f.Close()
    defer os.Remove("/tmp/snapshot.db")
    
    encoder := base64.NewEncoder(base64.StdEncoding, os.Stdout)
    io.Copy(encoder, f)
    encoder.Close()
}
EOF

go mod init vacuum >/dev/null 2>&1 || { echo "ERROR: Failed to init Go module"; exit 1; }
go get modernc.org/sqlite >/dev/null 2>&1 || { echo "ERROR: Failed to get sqlite module"; exit 1; }
go build -ldflags="-w -s" -o vai-vacuum vacuum.go >/dev/null 2>&1 || { echo "ERROR: Failed to build vacuum tool"; exit 1; }
chmod +x vai-vacuum

exec ./vai-vacuum