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
NS_NAME="job-state-test-${TEST_RUN_ID}"
if [[ ! $NS_NAME =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    echo "Generated namespace name $NS_NAME is invalid. Using fallback name."
    NS_NAME="job-state-test-x${TEST_RUN_ID}"
fi

JOB_NAME="qa-failing-job-${TEST_RUN_ID}"

echo "Test run ID: $TEST_RUN_ID"
echo "Using namespace: $NS_NAME"
echo "Using job name: $JOB_NAME"

# ============================================================
# Helper: Query Steve API for jobs
# ============================================================
check_jobs_api() {
    local query=$1
    local description=$2
    local expect_job_present=$3  # "true" or "false"
    local full_url="${BASE_URL}/v1/batch.jobs${query}"
    local response
    local job_found

    echo -e "\n=== $description ==="
    echo "Testing jobs with query: ${query}"
    echo "Full URL: ${full_url}"
    echo "To test manually:"
    echo "curl -sk -u \"${RANCHER_TOKEN}\" -H 'Accept: application/json' -H 'Content-Type: application/json' \"${full_url}\""
    echo "---"

    response=$(curl -sk -u "${RANCHER_TOKEN}" -H 'Accept: application/json' -H 'Content-Type: application/json' "${full_url}")

    if [ -z "$response" ]; then
        echo "❌ Empty response from API"
        TEST_RESULTS+=("FAIL")
        TEST_NAMES+=("$description")
        return 1
    fi

    # Check if our specific job is in the response
    job_found=$(echo "$response" | jq -r --arg job_id "${NS_NAME}/${JOB_NAME}" '.data[]? | select(.id == $job_id) | .id // empty')

    local actual_count
    actual_count=$(echo "$response" | jq '.data | length')

    echo "Total items returned: $actual_count"
    echo "Looking for job: ${NS_NAME}/${JOB_NAME}"

    if [ "$expect_job_present" == "true" ]; then
        if [ -n "$job_found" ]; then
            echo "✅ Test passed: Job '${JOB_NAME}' found in results as expected"
            # Print the state info for the job
            echo "Job state details:"
            echo "$response" | jq --arg job_id "${NS_NAME}/${JOB_NAME}" '.data[] | select(.id == $job_id) | {id: .id, state: .metadata.state}'
            TEST_RESULTS+=("PASS")
        else
            echo "❌ Test failed: Job '${JOB_NAME}' NOT found in results (expected present)"
            echo "Jobs returned:"
            echo "$response" | jq -r '.data[].id'
            TEST_RESULTS+=("FAIL")
        fi
    else
        if [ -z "$job_found" ]; then
            echo "✅ Test passed: Job '${JOB_NAME}' correctly absent from results"
            TEST_RESULTS+=("PASS")
        else
            echo "❌ Test failed: Job '${JOB_NAME}' found in results (expected absent)"
            echo "Job state details:"
            echo "$response" | jq --arg job_id "${NS_NAME}/${JOB_NAME}" '.data[] | select(.id == $job_id) | {id: .id, state: .metadata.state}'
            TEST_RESULTS+=("FAIL")
        fi
    fi
    TEST_NAMES+=("$description")
    echo "---"
}

# ============================================================
# Helper: Get the current metadata.state.name for the job from Steve
# ============================================================
get_job_state() {
    local full_url="${BASE_URL}/v1/batch.jobs/${NS_NAME}/${JOB_NAME}"
    local response
    response=$(curl -sk -u "${RANCHER_TOKEN}" -H 'Accept: application/json' -H 'Content-Type: application/json' "${full_url}")
    echo "$response" | jq -r '.metadata.state.name // "unknown"'
}

# ============================================================
# Helper: Wait for the job to reach a specific state in Steve
# ============================================================
wait_for_job_state() {
    local target_state=$1
    local timeout=$2
    local interval=5
    local elapsed=0

    echo "Waiting up to ${timeout}s for job '${JOB_NAME}' to reach state '${target_state}'..."

    while [ $elapsed -lt $timeout ]; do
        local current_state
        current_state=$(get_job_state)
        echo "  [${elapsed}s] Current state: ${current_state}"

        if [ "$current_state" == "$target_state" ]; then
            echo "✅ Job reached target state '${target_state}' after ${elapsed}s"
            return 0
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
    done

    echo "❌ Timeout: Job did not reach state '${target_state}' within ${timeout}s"
    echo "  Final state: $(get_job_state)"
    return 1
}

# ============================================================
# Setup: Create namespace and job
# ============================================================
echo -e "\n============================================"
echo "SETUP: Creating test namespace and failing job"
echo "============================================"

echo "Creating namespace: $NS_NAME"
if ! kubectl create ns $NS_NAME; then
    echo "Failed to create namespace"
    exit 1
fi

echo "Creating failing job: $JOB_NAME"
cat << EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: $NS_NAME
  labels:
    test: job-state-test
spec:
  template:
    spec:
      containers:
      - name: alpine-sleep
        image: alpine
        command: ["sh", "-c", "sleep 60; exit 1"]
      restartPolicy: Never
  backoffLimit: 0
EOF

if [ $? -ne 0 ]; then
    echo "Failed to create job $JOB_NAME"
    exit 1
fi
echo "Successfully created Job $JOB_NAME"

# ============================================================
# Phase 1: Verify "active" state (within 60s window)
# ============================================================
echo -e "\n============================================"
echo "PHASE 1: Verify job enters 'active' state"
echo "============================================"

# Wait for the job to appear as active in Steve
if ! wait_for_job_state "active" 30; then
    echo "⚠️  Job did not reach 'active' state — checking current state..."
    CURRENT=$(get_job_state)
    echo "Current state: $CURRENT"
    echo "Proceeding with tests anyway..."
fi

# Test 1: Filter for active jobs — our job should be present
check_jobs_api "?filter=metadata.state.name=active&projectsornamespaces=${NS_NAME}" \
    "Phase 1 - Active filter: Job should be present" "true"

# Test 2: Filter for error jobs — our job should NOT be present yet
check_jobs_api "?filter=metadata.state.name=error&projectsornamespaces=${NS_NAME}" \
    "Phase 1 - Error filter: Job should NOT be present" "false"

# ============================================================
# Phase 2: Wait for failure and verify "error" state
# ============================================================
echo -e "\n============================================"
echo "PHASE 2: Wait for job failure and verify 'error' state"
echo "============================================"

echo "The job container sleeps 60s then exits 1. Waiting for state transition..."
echo "Also monitoring kubectl job status..."

# Wait for the job to transition to error in Steve
if ! wait_for_job_state "error" 120; then
    echo "⚠️  Job did not reach 'error' state in Steve"
    echo "Checking kubectl status for diagnostics..."
    kubectl get job $JOB_NAME -n $NS_NAME -o jsonpath='{.status}' | jq .
    kubectl get pods -n $NS_NAME -l job-name=$JOB_NAME -o wide
fi

# Test 3: Filter for active jobs — our job should NO LONGER be present
check_jobs_api "?filter=metadata.state.name=active&projectsornamespaces=${NS_NAME}" \
    "Phase 2 - Active filter: Job should NOT be present" "false"

# Test 4: Filter for error jobs — our job SHOULD be present
check_jobs_api "?filter=metadata.state.name=error&projectsornamespaces=${NS_NAME}" \
    "Phase 2 - Error filter: Job should be present" "true"

# ============================================================
# Bonus: Direct job lookup to show full state object
# ============================================================
echo -e "\n============================================"
echo "BONUS: Full state object from Steve for job"
echo "============================================"

DIRECT_URL="${BASE_URL}/v1/batch.jobs/${NS_NAME}/${JOB_NAME}"
echo "Fetching: $DIRECT_URL"
echo "To test manually:"
echo "curl -sk -u \"${RANCHER_TOKEN}\" -H 'Accept: application/json' \"${DIRECT_URL}\""

DIRECT_RESPONSE=$(curl -sk -u "${RANCHER_TOKEN}" -H 'Accept: application/json' -H 'Content-Type: application/json' "${DIRECT_URL}")
echo "metadata.state object:"
echo "$DIRECT_RESPONSE" | jq '.metadata.state'
echo ""
echo "Job .status from Steve:"
echo "$DIRECT_RESPONSE" | jq '.status'

# ============================================================
# Test Summary
# ============================================================
echo -e "\nTest Summary:"
echo "Test Run ID: $TEST_RUN_ID"
echo "Namespace: $NS_NAME"
echo "Job Name: $JOB_NAME"

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
    if [ $total -gt 0 ]; then
        echo "Success rate: $(( (passed * 100) / total ))%"
    fi
    echo "========================================="
}

print_test_summary

# ============================================================
# Cleanup
# ============================================================
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

                echo "Getting current job and pods in namespace $NS_NAME..."
                kubectl get jobs,pods -n $NS_NAME || true

                echo "Deleting job $JOB_NAME..."
                kubectl delete job $JOB_NAME -n $NS_NAME --timeout=30s || true
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

cleanup

echo "Test script completed"