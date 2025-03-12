#!/bin/bash
# curl https://url.sh | sh -s -- [enabled|disabled|check]

cat << 'SCRIPT_EOF' > /tmp/rancher-port-check.sh
#!/bin/bash
set -e

# Initialize variables
EXPECTED_MODE="${1:-check}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="/tmp/rancher-port-check-${TIMESTAMP}"
SCRIPT_LOG="${LOG_DIR}/script.log"

# Create log directory
mkdir -p "${LOG_DIR}"

# Setup logging
exec > >(tee -a "${SCRIPT_LOG}") 2>&1

echo "=========================================================="
echo "Rancher Port Checker - Started at $(date)"
echo "Mode: ${EXPECTED_MODE}"
echo "Log directory: ${LOG_DIR}"
echo "=========================================================="

# Validate kubectl availability
if ! command -v kubectl &> /dev/null; then
    echo "❌ Error: kubectl is not installed or not in PATH"
    exit 1
fi

# Validate namespace exists
if ! kubectl get namespace cattle-system &> /dev/null; then
    echo "❌ Error: cattle-system namespace not found"
    exit 1
fi

# Function to check if string is in array
contains() {
    local element match="$1"
    shift
    for element; do
        [[ "${element}" == "${match}" ]] && return 0
    done
    return 1
}

# Get all rancher pods (filtering out webhooks and other non-rancher pods)
echo "📋 Retrieving Rancher pods from cattle-system namespace..."
RANCHER_PODS=($(kubectl get pods -n cattle-system --no-headers | grep "^rancher-" | grep -v webhook | awk '{print $1}'))

if [ ${#RANCHER_PODS[@]} -eq 0 ]; then
    echo "❌ Error: No Rancher pods found in cattle-system namespace"
    exit 1
fi

echo "✅ Found ${#RANCHER_PODS[@]} Rancher pods"

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

# Array to store results
declare -A RESULTS

# Process each Rancher pod
for pod in "${RANCHER_PODS[@]}"; do
    POD_LOG="${LOG_DIR}/${pod}.log"
    echo ""
    echo "🔍 Processing pod: ${pod}"
    echo "   Log file: ${POD_LOG}"
    
    # Copy the check script to a temporary file in the pod
    echo "   Creating debug container..."
    
    # Execute in a debug container
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
        echo "❌ Failed to determine port status for pod: ${pod}"
    else
        STATUS="${PORT_STATUS}"
        
        if [ "${EXPECTED_MODE}" == "enabled" ] && [ "${STATUS}" == "ENABLED" ]; then
            echo "✅ Port 6666 is ENABLED as expected on pod: ${pod}"
            RESULTS["${pod}"]="PASS"
        elif [ "${EXPECTED_MODE}" == "disabled" ] && [ "${STATUS}" == "DISABLED" ]; then
            echo "✅ Port 6666 is DISABLED as expected on pod: ${pod}"
            RESULTS["${pod}"]="PASS"
        elif [ "${EXPECTED_MODE}" == "check" ]; then
            echo "ℹ️ Port 6666 is ${STATUS} on pod: ${pod}"
            RESULTS["${pod}"]="${STATUS}"
        else
            echo "❌ Port 6666 is ${STATUS} but expected ${EXPECTED_MODE} on pod: ${pod}"
            RESULTS["${pod}"]="FAIL"
        fi
    fi
done

# Print summary
echo ""
echo "=========================================================="
echo "SUMMARY REPORT"
echo "=========================================================="
echo "Mode: ${EXPECTED_MODE}"
echo "Total pods checked: ${#RANCHER_PODS[@]}"

# Count results
PASS_COUNT=0
FAIL_COUNT=0
ENABLED_COUNT=0
DISABLED_COUNT=0
ERROR_COUNT=0

for pod in "${RANCHER_PODS[@]}"; do
    result="${RESULTS["${pod}"]}"
    case "${result}" in
        "PASS") ((PASS_COUNT++)) ;;
        "FAIL") ((FAIL_COUNT++)) ;;
        "ENABLED") ((ENABLED_COUNT++)) ;;
        "DISABLED") ((DISABLED_COUNT++)) ;;
        *) ((ERROR_COUNT++)) ;;
    esac
done

if [ "${EXPECTED_MODE}" != "check" ]; then
    echo "Passed: ${PASS_COUNT}/${#RANCHER_PODS[@]}"
    echo "Failed: ${FAIL_COUNT}/${#RANCHER_PODS[@]}"
    echo "Errors: ${ERROR_COUNT}/${#RANCHER_PODS[@]}"
    
    if [ ${FAIL_COUNT} -eq 0 ] && [ ${ERROR_COUNT} -eq 0 ]; then
        echo "✅ All pods match expected state: ${EXPECTED_MODE}"
        EXIT_CODE=0
    else
        echo "❌ Some pods do not match expected state: ${EXPECTED_MODE}"
        EXIT_CODE=1
    fi
else
    echo "Enabled: ${ENABLED_COUNT}/${#RANCHER_PODS[@]}"
    echo "Disabled: ${DISABLED_COUNT}/${#RANCHER_PODS[@]}"
    echo "Errors: ${ERROR_COUNT}/${#RANCHER_PODS[@]}"
    EXIT_CODE=0
fi

echo ""
echo "Detailed logs available in: ${LOG_DIR}"
echo "=========================================================="
echo "Rancher Port Checker - Finished at $(date)"
echo "=========================================================="

exit ${EXIT_CODE}
SCRIPT_EOF

chmod +x /tmp/rancher-port-check.sh
/tmp/rancher-port-check.sh "$@"
