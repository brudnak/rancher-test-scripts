#!/bin/bash
set -e  # Exit on any error

# Check command line arguments
if [ "$#" -ne 3 ]; then
    echo "Usage: Either run directly or pipe via curl:"
    echo "  Direct: $0 <rancher_url> <rancher_token> <kubeconfig_path>"
    echo "  Curl: curl ... | bash -s <rancher_url> <rancher_token> <kubeconfig_path>"
    echo ""
    echo "Examples:"
    echo "  Direct: $0 rancher.example.com token-abc123 local.yml"
    echo "  Curl: curl https://raw.githubusercontent.com/user/repo/main/script.sh | bash -s rancher.example.com token-abc123 local.yml"
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
        echo ""
        echo "To install jq on Linux:"
        echo "  Ubuntu/Debian: sudo apt-get install jq"
        echo "  CentOS/RHEL: sudo yum install jq"
        echo ""
        echo "Please install jq and try again."
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

    # Check if kubeconfig file exists
    if [ ! -f "$config_path" ]; then
        echo "Error: Kubeconfig file not found at: $config_path"
        exit 1
    fi

    # Export KUBECONFIG
    export KUBECONFIG=$config_path
    echo "Using kubeconfig: $KUBECONFIG"

    # Test kubectl access
    echo "Testing kubectl access..."
    if ! kubectl get nodes &> /dev/null; then
        echo "Error: Unable to access the Kubernetes cluster using the provided kubeconfig"
        echo "Please check your kubeconfig and try again"
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

# Generate a random string for test run identification using only alphanumeric chars
TEST_RUN_ID=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)
if [ -z "$TEST_RUN_ID" ]; then
    echo "Failed to generate test run ID"
    exit 1
fi

# Ensure we have a valid namespace name
NS_NAME="synthetic-test-${TEST_RUN_ID}"
if [[ ! $NS_NAME =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    echo "Generated namespace name $NS_NAME is invalid. Using fallback name."
    NS_NAME="synthetic-test-x${TEST_RUN_ID}"
fi

echo "Test run ID: $TEST_RUN_ID"
echo "Using namespace: $NS_NAME"

check_api() {
    local query=$1
    local expected_count=$2
    local description=$3
    local full_url="${BASE_URL}/v1/pods${query}"
    local response
    local actual_count

    echo -e "\n=== $description ==="
    echo "Testing pods with query: ${query}"
    echo "Full URL: ${full_url}"
    echo "To test manually:"
    echo "curl -sk -u \"${RANCHER_TOKEN}\" -H 'Accept: application/json' -H 'Content-Type: application/json' \"${full_url}\""
    echo "---"

    response=$(curl -sk -u "${RANCHER_TOKEN}" -H 'Accept: application/json' -H 'Content-Type: application/json' "${full_url}")

    # Use jq to count items in the data array
    actual_count=$(echo "$response" | jq '.data | length')

    if [ -z "$actual_count" ]; then
        echo "❌ Failed to parse response"
        echo "$response"
        TEST_RESULTS+=("FAIL")
        TEST_NAMES+=("$description")
        return 1
    fi

    if [ "$actual_count" -eq "$expected_count" ]; then
        echo "✅ Test passed: Found $actual_count items (expected $expected_count)"
        echo "Items found:"
        echo "$response" | jq -r '.data[].id'
        TEST_RESULTS+=("PASS")
    else
        echo "❌ Test failed: Found $actual_count items (expected $expected_count)"
        echo "Response data:"
        echo "$response" | jq '.data'
        TEST_RESULTS+=("FAIL")
    fi
    TEST_NAMES+=("$description")
    echo "---"
}


# Function to wait for all pods to be running and return their names
wait_for_running_pods() {
    local namespace=$1
    local timeout=60
    local interval=5
    local elapsed=0

    echo "Waiting up to ${timeout}s for all pods to be running in namespace $namespace..."

    while [ $elapsed -lt $timeout ]; do
        # Get count of running pods
        local running_count=$(kubectl get pods -n $namespace -l test=synthetic-test \
            -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' | wc -w)
        local total_count=$(kubectl get pods -n $namespace -l test=synthetic-test --no-headers | wc -l)

        echo "Current status: $running_count/$total_count pods running"

        if [ "$running_count" -eq "$total_count" ] && [ "$running_count" -gt 0 ]; then
            echo "✅ All pods are now running"
            return 0
        fi

        sleep $interval
        elapsed=$((elapsed + interval))

        # Show status of non-running pods
        echo "Pods not yet running:"
        kubectl get pods -n $namespace -l test=synthetic-test \
            --field-selector 'status.phase!=Running' -o wide
    done

    echo "❌ Timeout waiting for pods to be running"
    echo "Final pod status:"
    kubectl get pods -n $namespace -l test=synthetic-test -o wide
    return 1
}

# Create test namespace
echo "Creating namespace: $NS_NAME"
if ! kubectl create ns $NS_NAME; then
    echo "Failed to create namespace"
    exit 1
fi

# Create test pods with random suffixes
declare -a POD_NAMES
for i in {1..3}; do
    RANDOM_SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)
    if [ -z "$RANDOM_SUFFIX" ]; then
        echo "Failed to generate random suffix"
        exit 1
    fi

    POD_NAME="test-pod-$i-${RANDOM_SUFFIX}"
    POD_NAMES+=($POD_NAME)

    echo "Creating pod $POD_NAME in namespace $NS_NAME..."

    cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  namespace: $NS_NAME
  labels:
    test: synthetic-test
spec:
  containers:
  - name: nginx
    image: nginx:latest
EOF

    if [ $? -ne 0 ]; then
        echo "Failed to create pod $POD_NAME"
        exit 1
    fi
    echo "Successfully created Pod $POD_NAME"
done

echo "Waiting for pods to be in Running state..."
if ! wait_for_running_pods $NS_NAME; then
    echo "Failed to get pods to Running state"
    exit 1
fi

# Store pod names for reference
POD1=${POD_NAMES[0]}
POD2=${POD_NAMES[1]}

# SYNTHETIC FIELD TESTS
echo -e "\n=== SYNTHETIC FIELD TESTS ==="

# Test filtering by id - note the comma separation for OR conditions
check_api "?filter=id=${NS_NAME}/${POD1}" 1 "Filter by ID Test" || echo "ID filter test failed"

# Test filtering by multiple ids with comma separation
check_api "?filter=id=${NS_NAME}/${POD1},id=${NS_NAME}/${POD2}" 2 "Filter by Multiple IDs Test" || echo "Multiple ID filter test failed"

# Test filtering by running state with projectsornamespaces
check_api "?filter=metadata.state.name=running&projectsornamespaces=${NS_NAME}" 3 "Filter Running Pods Test" || echo "Running state filter test failed"

# Test multiple filters with comma for OR and & for AND
check_api "?filter=id=${NS_NAME}/${POD1},id=${NS_NAME}/${POD2}&filter=metadata.state.name=running" 2 "Filter by IDs AND State Test" || echo "Multiple filter test failed"

# SORT TESTS
echo -e "\n=== SORT TESTS ==="

# Sort by id descending (only running pods)
check_api "?sort=-id&projectsornamespaces=${NS_NAME}" 3 "Sort Pods by ID Descending Test" || echo "Sort test failed"

# Sort by state and filter
check_api "?sort=-metadata.state.name&filter=metadata.state.name=running&projectsornamespaces=${NS_NAME}" 3 "Sort Pods by State Test" || echo "Sort by state test failed"

# LIMIT TESTS
echo -e "\n=== LIMIT TESTS ==="

# Limit results
check_api "?limit=2&projectsornamespaces=${NS_NAME}" 2 "Limit Pods Test" || echo "Limit test failed"

# Combined sort, filter, and limit
check_api "?sort=-id&filter=metadata.state.name=running&limit=2&projectsornamespaces=${NS_NAME}" 2 "Combined Operations Test" || echo "Combined operations test failed"

echo -e "\nTest Summary:"
echo "Test Run ID: $TEST_RUN_ID"
echo "Namespace: $NS_NAME"
echo "Pod Names:"
for pod in "${POD_NAMES[@]}"; do
    echo "- $pod"
done

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

# Run the test summary
print_test_summary

# Cleanup function
cleanup() {
    echo "Before cleanup, please verify the test results above."
    echo "All curl commands are provided for manual verification."
    
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
                
                echo "Getting current pods in namespace $NS_NAME..."
                kubectl get pods -n $NS_NAME || true
                
                echo "Deleting pods in namespace $NS_NAME..."
                kubectl delete pods -n $NS_NAME -l test=synthetic-test --timeout=30s || true
                sleep 2
                
                echo "Deleting namespace $NS_NAME..."
                kubectl delete ns $NS_NAME --timeout=30s || true
                sleep 2
                
                echo "Cleanup completed"
                break
                ;;
            [Nn]* )
                echo "Skipping cleanup. To cleanup later, run:"
                echo "kubectl delete ns $NS_NAME"
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
