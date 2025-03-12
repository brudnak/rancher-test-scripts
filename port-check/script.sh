#!/bin/sh
# This script can be served from a web server and executed via:
# curl https://raw.githubusercontent.com/brudnak/rancher-test-scripts/refs/heads/main/port-check/script.sh | sh -s enabled|disabled|check

# Get parameter
EXPECTED_MODE="${1:-check}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="/tmp/rancher-port-check-${TIMESTAMP}"
SCRIPT_LOG="${LOG_DIR}/script.log"

# Create log directory
mkdir -p "${LOG_DIR}"

# Setup logging (compatible with sh)
exec > "${SCRIPT_LOG}" 2>&1
exec 3>&1
echo "==========================================================" | tee /dev/fd/3
echo "Rancher Port Checker - Started at $(date)" | tee /dev/fd/3
echo "Mode: ${EXPECTED_MODE}" | tee /dev/fd/3
echo "Log directory: ${LOG_DIR}" | tee /dev/fd/3
echo "==========================================================" | tee /dev/fd/3

# Validate kubectl availability
if ! command -v kubectl > /dev/null 2>&1; then
    echo "❌ Error: kubectl is not installed or not in PATH" | tee /dev/fd/3
    exit 1
fi

# Validate namespace exists
if ! kubectl get namespace cattle-system > /dev/null 2>&1; then
    echo "❌ Error: cattle-system namespace not found" | tee /dev/fd/3
    exit 1
fi

# Get all rancher pods (filtering out webhooks and other non-rancher pods)
echo "📋 Retrieving Rancher pods from cattle-system namespace..." | tee /dev/fd/3
RANCHER_PODS=$(kubectl get pods -n cattle-system --no-headers | grep "^rancher-" | grep -v webhook | awk '{print $1}')

if [ -z "${RANCHER_PODS}" ]; then
    echo "❌ Error: No Rancher pods found in cattle-system namespace" | tee /dev/fd/3
    exit 1
fi

# Count pods (sh compatible)
POD_COUNT=$(echo "${RANCHER_PODS}" | wc -w)
echo "✅ Found ${POD_COUNT} Rancher pods" | tee /dev/fd/3

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
    echo "" | tee /dev/fd/3
    echo "🔍 Processing pod: ${pod}" | tee /dev/fd/3
    echo "   Log file: ${POD_LOG}" | tee /dev/fd/3
    
    # Execute in a debug container
    echo "   Creating debug container..." | tee /dev/fd/3
    
    # Create a temporary file with the debug script content
    DEBUG_SCRIPT="${LOG_DIR}/${pod}-debug-script.sh"
    cat "${LOG_DIR}/check-ports.sh" > "${DEBUG_SCRIPT}"
    
    # Execute debug container with script
    DEBUG_OUTPUT=$(kubectl -n cattle-system debug ${pod} -it --image=alpine:latest -- /bin/sh -c "cat > /tmp/check-ports.sh << 'INNEREOF'
$(cat ${LOG_DIR}/check-ports.sh)
INNEREOF
chmod +x /tmp/check-ports.sh
/tmp/check-ports.sh
" 2>&1)
    
    # Save the output
    echo "${DEBUG_OUTPUT}" > "${POD_LOG}"
    
    # Extract PORT_STATUS
    PORT_STATUS=$(echo "${DEBUG_OUTPUT}" | grep "PORT_STATUS:" | cut -d':' -f2)
    
    if [ -z "${PORT_STATUS}" ]; then
        STATUS="ERROR"
        echo "❌ Failed to determine port status for pod: ${pod}" | tee /dev/fd/3
        ERROR_COUNT=$((ERROR_COUNT + 1))
    else
        STATUS="${PORT_STATUS}"
        
        if [ "${EXPECTED_MODE}" = "enabled" ] && [ "${STATUS}" = "ENABLED" ]; then
            echo "✅ Port 6666 is ENABLED as expected on pod: ${pod}" | tee /dev/fd/3
            PASS_COUNT=$((PASS_COUNT + 1))
        elif [ "${EXPECTED_MODE}" = "disabled" ] && [ "${STATUS}" = "DISABLED" ]; then
            echo "✅ Port 6666 is DISABLED as expected on pod: ${pod}" | tee /dev/fd/3
            PASS_COUNT=$((PASS_COUNT + 1))
        elif [ "${EXPECTED_MODE}" = "check" ]; then
            echo "ℹ️ Port 6666 is ${STATUS} on pod: ${pod}" | tee /dev/fd/3
            if [ "${STATUS}" = "ENABLED" ]; then
                ENABLED_COUNT=$((ENABLED_COUNT + 1))
            else
                DISABLED_COUNT=$((DISABLED_COUNT + 1))
            fi
        else
            echo "❌ Port 6666 is ${STATUS} but expected ${EXPECTED_MODE} on pod: ${pod}" | tee /dev/fd/3
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    fi
done

# Print summary
echo "" | tee /dev/fd/3
echo "==========================================================" | tee /dev/fd/3
echo "SUMMARY REPORT" | tee /dev/fd/3
echo "==========================================================" | tee /dev/fd/3
echo "Mode: ${EXPECTED_MODE}" | tee /dev/fd/3
echo "Total pods checked: ${POD_COUNT}" | tee /dev/fd/3

if [ "${EXPECTED_MODE}" != "check" ]; then
    echo "Passed: ${PASS_COUNT}/${POD_COUNT}" | tee /dev/fd/3
    echo "Failed: ${FAIL_COUNT}/${POD_COUNT}" | tee /dev/fd/3
    echo "Errors: ${ERROR_COUNT}/${POD_COUNT}" | tee /dev/fd/3
    
    if [ ${FAIL_COUNT} -eq 0 ] && [ ${ERROR_COUNT} -eq 0 ]; then
        echo "✅ All pods match expected state: ${EXPECTED_MODE}" | tee /dev/fd/3
        EXIT_CODE=0
    else
        echo "❌ Some pods do not match expected state: ${EXPECTED_MODE}" | tee /dev/fd/3
        EXIT_CODE=1
    fi
else
    echo "Enabled: ${ENABLED_COUNT}/${POD_COUNT}" | tee /dev/fd/3
    echo "Disabled: ${DISABLED_COUNT}/${POD_COUNT}" | tee /dev/fd/3
    echo "Errors: ${ERROR_COUNT}/${POD_COUNT}" | tee /dev/fd/3
    EXIT_CODE=0
fi

echo "" | tee /dev/fd/3
echo "Detailed logs available in: ${LOG_DIR}" | tee /dev/fd/3
echo "==========================================================" | tee /dev/fd/3
echo "Rancher Port Checker - Finished at $(date)" | tee /dev/fd/3
echo "==========================================================" | tee /dev/fd/3

exit ${EXIT_CODE}
