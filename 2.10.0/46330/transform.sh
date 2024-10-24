#!/bin/bash
set -e  # Exit on any error

# Check command line arguments
if [ "$#" -ne 3 ]; then
    echo "Usage: Either run directly or pipe via curl:"
    echo "  Direct: $0 <rancher_url> <rancher_token> <kubeconfig_path>"
    echo "  Curl: curl ... | bash -s <rancher_url> <rancher_token> <kubeconfig_path>"
    exit 1
fi

# Set variables from command line arguments
RANCHER_INPUT=$1
RANCHER_TOKEN=$2
KUBECONFIG_PATH=$3

# Declare arrays for test results
declare -a TEST_RESULTS=()
declare -a TEST_NAMES=()

# Check for required commands
check_required_commands() {
    if ! command -v jq &> /dev/null; then
        echo "Error: jq is not installed but is required for this script."
        echo "To install jq on Mac:"
        echo "  Using homebrew: brew install jq"
        echo "  Using MacPorts: sudo port install jq"
        exit 1
    fi

    if ! command -v kubectl &> /dev/null; then
        echo "Error: kubectl is not installed but is required for this script."
        echo "Please install kubectl and try again."
        exit 1
    fi
}

# Validate kubeconfig and kubectl access
check_kubectl_access() {
    local config_path=$1
    
    if [ ! -f "$config_path" ]; then
        echo "Error: Kubeconfig file not found at: $config_path"
        exit 1
    fi
    
    export KUBECONFIG=$config_path
    echo "Using kubeconfig: $KUBECONFIG"
    
    if ! kubectl get nodes &> /dev/null; then
        echo "Error: Unable to access the Kubernetes cluster"
        exit 1
    fi
    echo "✅ Successfully connected to Kubernetes cluster"
}

# Function to format URL
format_url() {
    local url=$1
    url=${url%/}
    url=${url#http://}
    url=${url#https://}
    echo $url
}

# Generate test run ID
TEST_RUN_ID=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)
NS_NAME="backup-test-${TEST_RUN_ID}"

# Run initial checks
echo "Checking required commands..."
check_required_commands

echo "Validating kubectl access..."
check_kubectl_access "$KUBECONFIG_PATH"

RANCHER=$(format_url $RANCHER_INPUT)
PROTOCOL="https"
BASE_URL="${PROTOCOL}://${RANCHER}"

echo "Using Base URL: $BASE_URL"
echo "Using Token: ${RANCHER_TOKEN:0:10}..."
echo "Test run ID: $TEST_RUN_ID"
echo "Using namespace: $NS_NAME"

# Create CRD
create_backup_crd() {
    cat << 'EOF' > backup-crd.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: backups.stable.example.com
spec:
  group: stable.example.com
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                frequency:
                  type: string
                destination:
                  type: string
            _id:
              type: string
              description: "Original ID before transformation"
  scope: Namespaced
  names:
    plural: backups
    singular: backup
    kind: Backup
    shortNames:
      - bkp
EOF

    if ! kubectl get crd backups.stable.example.com &> /dev/null; then
        echo "Creating CRD..."
        kubectl apply -f backup-crd.yaml
        echo "Waiting for CRD to be established..."
        sleep 5
    else
        echo "CRD already exists"
    fi
}

# Create test namespace
create_test_namespace() {
    echo "Creating namespace: $NS_NAME"
    kubectl create ns $NS_NAME
}

# Create a backup resource
create_backup() {
    local name=$1
    local original_id=$2
    
    cat << EOF | kubectl apply -f -
apiVersion: stable.example.com/v1
kind: Backup
metadata:
  name: $name
  namespace: $NS_NAME
  labels:
    test: backup-test
spec:
  frequency: "daily"
  destination: "/backup/$name"
_id: "$original_id"
EOF
}

# Check API response
check_api() {
    local query=$1
    local expected_count=$2
    local description=$3
    local check_type=${4:-"count"} # Can be "count" or "transform"
    local full_url="${BASE_URL}/v1/stable.example.com.backups${query}"
    local response
    local actual_count

    echo -e "\n=== $description ==="
    echo "Testing backups with query: ${query}"
    echo "Full URL: ${full_url}"
    echo "To test manually:"
    echo "curl -sk -u \"${RANCHER_TOKEN}\" -H 'Accept: application/json' \"${full_url}\""
    echo "---"

    response=$(curl -sk -u "${RANCHER_TOKEN}" -H 'Accept: application/json' "${full_url}")
    
    if [ "$check_type" = "transform" ]; then
        # Check if _id and id fields are correct for the first item
        local _id=$(echo "$response" | jq -r '.data[0]._id')
        local id=$(echo "$response" | jq -r '.data[0].id')
        local name=$(echo "$response" | jq -r '.data[0].metadata.name')
        
        echo "Checking ID transformation:"
        echo "Original _id: $_id"
        echo "Transformed id: $id"
        
        # Verify id includes namespace and matches expected format
        if [[ "$id" == "$NS_NAME/$name" && "$_id" == "backup-$name" ]]; then
            echo "✅ Test passed: ID transformation verified"
            TEST_RESULTS+=("PASS")
        else
            echo "❌ Test failed: ID transformation incorrect"
            TEST_RESULTS+=("FAIL")
        fi
    else
        actual_count=$(echo "$response" | jq '.data | length')
        
        if [ -z "$actual_count" ]; then
            echo "❌ Failed to parse response"
            TEST_RESULTS+=("FAIL")
            TEST_NAMES+=("$description")
            return 1
        fi

        if [ "$actual_count" -eq "$expected_count" ]; then
            echo "✅ Test passed: Found $actual_count items (expected $expected_count)"
            TEST_RESULTS+=("PASS")
        else
            echo "❌ Test failed: Found $actual_count items (expected $expected_count)"
            TEST_RESULTS+=("FAIL")
        fi
    fi
    
    TEST_NAMES+=("$description")
}

# Print test summary
print_test_summary() {
    local total=${#TEST_RESULTS[@]}
    local passed=0
    echo -e "\n============== Test Summary =============="
    echo "Total tests run: $total"
    
    for i in "${!TEST_RESULTS[@]}"; do
        if [[ "${TEST_RESULTS[$i]}" == "PASS" ]]; then
            echo "✅ ${TEST_NAMES[$i]}"
            ((passed++))
        else
            echo "❌ ${TEST_NAMES[$i]}"
        fi
    done
    
    echo -e "\nResults:"
    echo "Passed: $passed"
    echo "Failed: $((total - passed))"
    echo "Success rate: $(( (passed * 100) / total ))%"
    echo "========================================="
}

# Main execution
echo "Setting up test environment..."
create_backup_crd
create_test_namespace

# Create test backups
echo "Creating test backups..."
for i in {1..3}; do
    BACKUP_NAME="backup-$i"
    create_backup $BACKUP_NAME "backup-$BACKUP_NAME"
    echo "Created backup: $BACKUP_NAME"
done

# Wait for resources to be available
echo "Waiting for resources to be available..."
sleep 5

# Run tests focusing on ID transformation and basic operations
echo -e "\n=== ID TRANSFORMATION TESTS ==="
check_api "?filter=id=${NS_NAME}/backup-1" 1 "Verify ID Transform" "transform"

echo -e "\n=== FILTER TESTS ==="
check_api "?filter=id=${NS_NAME}/backup-1,id=${NS_NAME}/backup-2" 2 "Filter Multiple IDs"

echo -e "\n=== SORT TESTS ==="
check_api "?sort=-id" 3 "Sort by Transformed ID Descending"
check_api "?sort=id" 3 "Sort by Transformed ID Ascending"

echo -e "\n=== LIMIT TESTS ==="
check_api "?limit=2" 2 "Basic Limit Test"
check_api "?sort=-id&limit=2" 2 "Sort and Limit Combined"

# Print test summary
print_test_summary

# Cleanup function
cleanup() {
    echo "Before cleanup, please verify the test results above."
    
    while true; do
        echo "Do you want to cleanup the test resources? (y/n)"
        read -r response < /dev/tty || {
            echo "Failed to get terminal input. Skipping cleanup."
            echo "To cleanup manually, run: kubectl delete ns $NS_NAME"
            return 1
        }
        case $response in
            [Yy]* )
                echo "Starting cleanup process..."
                echo "Deleting namespace $NS_NAME..."
                kubectl delete ns $NS_NAME --timeout=30s || true
                echo "Deleting CRD..."
                kubectl delete -f backup-crd.yaml || true
                rm -f backup-crd.yaml
                echo "Cleanup completed"
                break
                ;;
            [Nn]* )
                echo "Skipping cleanup. To cleanup later, run:"
                echo "kubectl delete ns $NS_NAME"
                echo "kubectl delete -f backup-crd.yaml"
                break
                ;;
            * )
                echo "Please answer y or n."
                ;;
        esac
    done
}

# Run cleanup
cleanup

echo "Test script completed"
