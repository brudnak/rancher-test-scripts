#!/bin/zsh
set -e

NAMESPACE="${1}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
# Use PWD instead of realpath
RUN_DIR="${PWD}/vai-run-${TIMESTAMP}"

if [ -z "$NAMESPACE" ]; then
    echo "Usage: $0 <namespace>"
    exit 1
fi

mkdir -p "$RUN_DIR"

# Create the pod script that will be uploaded and executed
cat << 'EOF' > "$RUN_DIR/pod-vacuum.sh"
#!/bin/sh
set -e

echo "Starting vacuum process..."

# Check if Go is already installed and in PATH
check_go() {
    if command -v go &> /dev/null; then
        return 0
    elif [ -x "/usr/local/go/bin/go" ]; then
        export PATH=$PATH:/usr/local/go/bin
        return 0
    fi
    return 1
}

# Install Go only if needed
if ! check_go; then
    echo "Installing Go..."
    curl -L -o go.tar.gz https://go.dev/dl/go1.22.4.linux-amd64.tar.gz --insecure
    tar -C /usr/local -xzf go.tar.gz
    rm go.tar.gz
    export PATH=$PATH:/usr/local/go/bin
else
    echo "Go is already installed"
fi

# Check if vacuum tool already exists and is working
if [ -f "/tmp/vai-vacuum/vacuum-tool" ]; then
    echo "Found existing vacuum tool, attempting to use it..."
    if /tmp/vai-vacuum/vacuum-tool; then
        echo "Existing vacuum tool worked successfully"
        exit 0
    else
        echo "Existing vacuum tool failed, rebuilding..."
    fi
fi

# Create and build vacuum tool
mkdir -p /tmp/vai-vacuum
cd /tmp/vai-vacuum

# Only initialize module if needed
if [ ! -f "go.mod" ]; then
    go mod init vai-vacuum
fi

# Only create main.go if it doesn't exist or is different
cat << 'GOFILE' > main.go.tmp
package main

import (
    "database/sql"
    "log"
    _ "modernc.org/sqlite"
)

func main() {
    db, err := sql.Open("sqlite", "/var/lib/rancher/informer_object_cache.db")
    if err != nil {
        log.Fatal(err)
    }
    defer db.Close()

    _, err = db.Exec("VACUUM INTO '/tmp/snapshot.db'")
    if err != nil {
        log.Fatal(err)
    }
}
GOFILE

if ! cmp -s main.go.tmp main.go; then
    mv main.go.tmp main.go
    echo "Rebuilding vacuum tool..."
    go get modernc.org/sqlite
    go build -o vacuum-tool main.go
else
    rm main.go.tmp
    echo "Using existing vacuum tool..."
fi

./vacuum-tool
echo "Vacuum process completed"
EOF

# Process each Rancher pod
for pod in $(kubectl get pods -n cattle-system -l app=rancher --no-headers | grep -v webhook | awk '{print $1}'); do
    echo "Processing pod: $pod"
    POD_DIR="$RUN_DIR/$pod"
    mkdir -p "$POD_DIR"
    
    # Copy and execute vacuum script on pod
    echo "Running vacuum process on pod..."
    kubectl cp "$RUN_DIR/pod-vacuum.sh" "cattle-system/$pod:/tmp/pod-vacuum.sh"
    kubectl exec -n cattle-system $pod -- chmod +x /tmp/pod-vacuum.sh
    kubectl exec -n cattle-system $pod -- /tmp/pod-vacuum.sh
    
    # Copy snapshot locally
    echo "Copying snapshot from pod..."
    kubectl cp "cattle-system/$pod:/tmp/snapshot.db" "$POD_DIR/snapshot.db"
    
    # Check namespace locally
    if [ -f "$POD_DIR/snapshot.db" ]; then
        echo "Checking snapshot from $pod..."
        result=$(sqlite3 "$POD_DIR/snapshot.db" \
            "SELECT \"metadata.name\" FROM \"_v1_Namespace_fields\" 
             WHERE \"metadata.name\" = '$NAMESPACE';")
        
        if [ -n "$result" ]; then
            echo "✅ Found namespace '$NAMESPACE' in pod: $pod"
        else
            echo "❌ Namespace '$NAMESPACE' not found in pod: $pod"
        fi
    else
        echo "❌ Failed to copy snapshot from pod"
    fi
    
    # Only clean up temporary files, leave Go and the tool installed
    echo "Cleaning up temporary files..."
    kubectl exec -n cattle-system $pod -- rm -f /tmp/pod-vacuum.sh /tmp/snapshot.db
done

echo "All snapshots saved in: $RUN_DIR"
