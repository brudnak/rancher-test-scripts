#!/bin/sh
# Rancher Port 6666 Checker - POSIX shell compatible, designed for curl | sh usage
# Usage: curl https://raw.githubusercontent.com/brudnak/rancher-test-scripts/refs/heads/main/port-check/script.sh | sh -s enabled
# Or: curl https://raw.githubusercontent.com/brudnak/rancher-test-scripts/refs/heads/main/port-check/script.sh | sh -s disabled
# Or: curl https://raw.githubusercontent.com/brudnak/rancher-test-scripts/refs/heads/main/port-check/script.sh | sh (defaults to "check" mode)

# Get parameter (default to check if none provided)
EXPECTED_MODE="${1:-check}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="/tmp/rancher-port-check-${TIMESTAMP}"
SCRIPT_LOG="${LOG_DIR}/script.log"

# Create log directory
mkdir -p "${LOG_DIR}"

# Setup logging
echo "=========================================================="
echo "Rancher Port Checker - Started at $(date)"
echo "Mode: ${EXPECTED_MODE}"
echo "Log directory: ${LOG_DIR}"
echo "=========================================================="

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

# Create the debug script that will be executed in the debug container
cat << 'EOF' > "${LOG_DIR}/check-ports.sh"
#!/bin/sh
set -e

echo "Installing required packages..."
apk add --no-cache iproute2 > /dev/null

echo "Checking listening ports..."
SS_OUTPUT=$(ss -lntp)
echo "$SS_OUTPUT"

# Check specifically for port 6666
if echo "$SS_OUTPUT" | grep -q ":6666"; then
    echo "PORT_STATUS:ENABLED"
else
    echo "PORT_STATUS:DISABLED"
fi
EOF

# Make the script executable
chmod +x "${LOG_DIR}/check-ports.sh"

# Initialize counters
PASS_COUNT=0
FAIL_COUNT=0
ENABLED_COUNT=0
DISABLED_COUNT=0
ERROR_COUNT=0

# Process each Rancher pod
for pod in ${RANCHER_PODS}; do
    POD_LOG="${LOG_DIR}/${pod}.log"
    echo ""
    echo "🔍 Processing pod: ${pod}"
    echo "   Log file: ${POD_LOG}"
    
    # Execute in a debug container
    echo "   Creating debug container..."
    
    # Execute debug container with script
    kubectl -n cattle-system debug ${pod} -it --image=alpine:latest -- /bin/sh -c "cat > /tmp/check-ports.sh << 'INNEREOF'
$(cat ${LOG_DIR}/check-ports.sh)
INNEREOF
chmod +x /tmp/check-ports.sh
/tmp/check-ports.sh" > "${POD_LOG}" 2>&1
    
    # Extract PORT_STATUS from the log file
    PORT_STATUS=$(grep "PORT_STATUS:" "${POD_LOG}" | cut -d':' -f2)
    
    if [ -z "${PORT_STATUS}" ]; then
        STATUS="ERROR"
        echo "❌ Failed to determine port status for pod: ${pod}"
        echo "   Check logs at ${POD_LOG} for details"
        ERROR_COUNT=$((ERROR_COUNT + 1))
    else
        STATUS="${PORT_STATUS}"
        
        if [ "${EXPECTED_MODE}" = "enabled" ] && [ "${STATUS}" = "ENABLED" ]; then
            echo "✅ Port 6666 is ENABLED as expected on pod: ${pod}"
            PASS_COUNT=$((PASS_COUNT + 1))
        elif [ "${EXPECTED_MODE}" = "disabled" ] && [ "${STATUS}" = "DISABLED" ]; then
            echo "✅ Port 6666 is DISABLED as expected on pod: ${pod}"
            PASS_COUNT=$((PASS_COUNT + 1))
        elif [ "${EXPECTED_MODE}" = "check" ]; then
            echo "ℹ️ Port 6666 is ${STATUS} on pod: ${pod}"
            if [ "${STATUS}" = "ENABLED" ]; then
                ENABLED_COUNT=$((ENABLED_COUNT + 1))
            else
                DISABLED_COUNT=$((DISABLED_COUNT + 1))
            fi
        else
            echo "❌ Port 6666 is ${STATUS} but expected ${EXPECTED_MODE} on pod: ${pod}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    fi
done

# Print summary
echo ""
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