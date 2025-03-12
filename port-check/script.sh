#!/bin/sh
# Rancher Port 6666 Checker - Using port-forward method only
# Usage: curl https://raw.githubusercontent.com/brudnak/rancher-test-scripts/refs/heads/main/port-check/script.sh | sh -s enabled

# Get parameter (default to check if none provided)
EXPECTED_MODE="${1:-check}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Create log directory in current path where script is executed
LOG_DIR="./rancher-port-check-${TIMESTAMP}"
mkdir -p "${LOG_DIR}"

# Setup logging
echo "=========================================================="
echo "Rancher Port Checker - Started at $(date)"
echo "Mode: ${EXPECTED_MODE}"
echo "Log directory: ${LOG_DIR}"
echo "=========================================================="

# Log the command being run for debugging
echo "Executing with kubectl context: $(kubectl config current-context 2>/dev/null || echo 'Unknown')"
echo ""

# Validate kubectl availability
if ! command -v kubectl > /dev/null 2>&1; then
    echo "❌ Error: kubectl is not installed or not in PATH"
    exit 1
fi

# Validate namespace exists
if ! kubectl get namespace cattle-system > /dev/null 2>&1; then
    echo "❌ Error: cattle-system namespace not found"
    exit 1
fi

# Get all rancher pods (filtering out webhooks and other non-rancher pods)
echo "📋 Retrieving Rancher pods from cattle-system namespace..."
RANCHER_PODS=$(kubectl get pods -n cattle-system --no-headers | grep "^rancher-" | grep -v webhook | awk '{print $1}')

if [ -z "${RANCHER_PODS}" ]; then
    echo "❌ Error: No Rancher pods found in cattle-system namespace"
    exit 1
fi

# Count pods (sh compatible)
POD_COUNT=$(echo "${RANCHER_PODS}" | wc -w)
echo "✅ Found ${POD_COUNT} Rancher pods"
echo ""

# Initialize counters
PASS_COUNT=0
FAIL_COUNT=0
ENABLED_COUNT=0
DISABLED_COUNT=0
ERROR_COUNT=0

# Process each Rancher pod using port-forward method only
for pod in ${RANCHER_PODS}; do
    POD_LOG="${LOG_DIR}/${pod}.log"
    echo "🔍 Processing pod: ${pod}"
    
    # First check if the pod is ready
    POD_STATUS=$(kubectl get pod -n cattle-system ${pod} -o jsonpath='{.status.phase}')
    if [ "${POD_STATUS}" != "Running" ]; then
        echo "   ⚠️ Pod ${pod} is not in Running state (current: ${POD_STATUS})"
        echo "   Skipping..."
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi
    
    echo "   Checking port 6666 using port-forward method..."
    
    # Use a unique port based on PID to avoid conflicts
    TMP_PORT=$((10000 + $$))
    
    # Try port-forwarding to see if the port is available
    kubectl port-forward -n cattle-system pod/${pod} ${TMP_PORT}:6666 > "${POD_LOG}.portforward" 2>&1 &
    PF_PID=$!
    
    # Give it a moment to establish
    sleep 2
    
    # Check if port-forward is running (which means the port exists)
    if kill -0 ${PF_PID} 2>/dev/null; then
        # The port is available for forwarding, meaning it's listening in the pod
        PORT_STATUS="ENABLED"
        echo "PORT_STATUS:ENABLED" > "${POD_LOG}"
        
        # Clean up the port-forward
        kill ${PF_PID} 2>/dev/null
        wait ${PF_PID} 2>/dev/null
        
        echo "   Port 6666 is ENABLED (port-forward successful)"
    else
        # Check the error message to see if it's because the port doesn't exist
        if grep -q "unknown port name or number: 6666" "${POD_LOG}.portforward" || \
           grep -q "address already in use" "${POD_LOG}.portforward"; then
            PORT_STATUS="DISABLED"
            echo "PORT_STATUS:DISABLED" > "${POD_LOG}"
            echo "   Port 6666 is DISABLED (port-forward failed - port not available)"
        else
            # Something else went wrong with port-forward
            cat "${POD_LOG}.portforward" >> "${POD_LOG}"
            echo "   ⚠️ Port-forward failed for an unexpected reason, checking error..."
            
            # Try one more time with a different port number
            TMP_PORT=$((11000 + $$))
            kubectl port-forward -n cattle-system pod/${pod} ${TMP_PORT}:6666 > "${POD_LOG}.retry" 2>&1 &
            PF_PID=$!
            sleep 2
            
            if kill -0 ${PF_PID} 2>/dev/null; then
                PORT_STATUS="ENABLED"
                echo "PORT_STATUS:ENABLED" >> "${POD_LOG}"
                kill ${PF_PID} 2>/dev/null
                wait ${PF_PID} 2>/dev/null
                echo "   Port 6666 is ENABLED (port-forward retry successful)"
            else
                PORT_STATUS="DISABLED"
                echo "PORT_STATUS:DISABLED" >> "${POD_LOG}"
                echo "   Port 6666 is DISABLED (port-forward retry also failed)"
            fi
        fi
    fi
    
    # Evaluate results based on port status
    if [ -z "${PORT_STATUS}" ]; then
        echo "   ❌ Failed to determine port status"
        echo "   Check logs at ${POD_LOG} for details"
        ERROR_COUNT=$((ERROR_COUNT + 1))
    else
        if [ "${EXPECTED_MODE}" = "enabled" ] && [ "${PORT_STATUS}" = "ENABLED" ]; then
            echo "   ✅ Port 6666 is ENABLED as expected"
            PASS_COUNT=$((PASS_COUNT + 1))
        elif [ "${EXPECTED_MODE}" = "disabled" ] && [ "${PORT_STATUS}" = "DISABLED" ]; then
            echo "   ✅ Port 6666 is DISABLED as expected"
            PASS_COUNT=$((PASS_COUNT + 1))
        elif [ "${EXPECTED_MODE}" = "check" ]; then
            echo "   ℹ️ Port 6666 is ${PORT_STATUS}"
            if [ "${PORT_STATUS}" = "ENABLED" ]; then
                ENABLED_COUNT=$((ENABLED_COUNT + 1))
            else
                DISABLED_COUNT=$((DISABLED_COUNT + 1))
            fi
        else
            echo "   ❌ Port 6666 is ${PORT_STATUS} but expected ${EXPECTED_MODE}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    fi
    
    echo ""
done

# Save script output to main log file
MAIN_LOG="${LOG_DIR}/main.log"
echo "Saving main log to ${MAIN_LOG}"

# Print summary
echo "=========================================================="
echo "SUMMARY REPORT"
echo "=========================================================="
echo "Mode: ${EXPECTED_MODE}"
echo "Total pods checked: ${POD_COUNT}"

if [ "${EXPECTED_MODE}" != "check" ]; then
    echo "Passed: ${PASS_COUNT}/${POD_COUNT}"
    echo "Failed: ${FAIL_COUNT}/${POD_COUNT}"
    echo "Errors: ${ERROR_COUNT}/${POD_COUNT}"
    
    if [ ${FAIL_COUNT} -eq 0 ] && [ ${ERROR_COUNT} -eq 0 ]; then
        echo "✅ All pods match expected state: ${EXPECTED_MODE}"
        EXIT_CODE=0
    else
        echo "❌ Some pods do not match expected state: ${EXPECTED_MODE}"
        EXIT_CODE=1
    fi
else
    echo "Enabled: ${ENABLED_COUNT}/${POD_COUNT}"
    echo "Disabled: ${DISABLED_COUNT}/${POD_COUNT}"
    echo "Errors: ${ERROR_COUNT}/${POD_COUNT}"
    EXIT_CODE=0
fi

echo ""
echo "Detailed logs available in: ${LOG_DIR}"
echo "=========================================================="
echo "Rancher Port Checker - Finished at $(date)"
echo "=========================================================="

exit ${EXIT_CODE}