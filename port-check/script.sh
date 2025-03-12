#!/bin/sh
# Rancher Port 6666 Checker - POSIX shell compatible, designed for curl | sh usage
# Usage: curl https://raw.githubusercontent.com/brudnak/rancher-test-scripts/refs/heads/main/port-check/script.sh | sh -s enabled

# Get parameter (default to check if none provided)
EXPECTED_MODE="${1:-check}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="/tmp/rancher-port-check-${TIMESTAMP}"

# Create log directory
mkdir -p "${LOG_DIR}"

# Setup logging
echo "=========================================================="
echo "Rancher Port Checker - Started at $(date)"
echo "Mode: ${EXPECTED_MODE}"
echo "Log directory: ${LOG_DIR}"
echo "=========================================================="

# Log the command being run for debugging
echo "Executing with kubectl context: $(kubectl config current-context)"
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

# Process each Rancher pod
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
    
    echo "   Creating debug session..."
    
    # Create a temporary file to hold the check command
    TMP_CMD="${LOG_DIR}/${pod}-cmd.sh"
    cat > "${TMP_CMD}" << 'EOF'
#!/bin/sh
echo "Running port check from debug container..."
echo "Installing iproute2 package..."
apk add --no-cache iproute2 > /dev/null
echo "Checking listening ports with ss -lntp..."
SS_OUTPUT=$(ss -lntp)
echo "${SS_OUTPUT}"

# Check specifically for port 6666
if echo "${SS_OUTPUT}" | grep -q ":6666"; then
    echo "PORT_STATUS:ENABLED"
else
    echo "PORT_STATUS:DISABLED"
fi
EOF
    
    chmod +x "${TMP_CMD}"
    
    # Get container name (usually there's only one, but we'll check)
    CONTAINER=$(kubectl get pod -n cattle-system ${pod} -o jsonpath='{.spec.containers[0].name}')
    
    # Run debug session
    echo "   Starting debug container for pod ${pod}..."
    
    # Method 1: Try using kubectl debug with image
    kubectl -n cattle-system debug pod/${pod} -it --image=alpine:latest -- /bin/sh -c "cat > /tmp/check.sh << 'EOF'
#!/bin/sh
echo 'Installing iproute2...'
apk add --no-cache iproute2 > /dev/null 2>&1
echo 'Checking listening ports...'
ss -lntp
echo ''
if ss -lntp | grep -q ':6666'; then
    echo 'PORT_STATUS:ENABLED'
else
    echo 'PORT_STATUS:DISABLED'
fi
EOF
chmod +x /tmp/check.sh && /tmp/check.sh" > "${POD_LOG}" 2>&1
    
    # Check if the debug command was successful by looking for PORT_STATUS in the log
    if grep -q "PORT_STATUS:" "${POD_LOG}"; then
        PORT_STATUS=$(grep "PORT_STATUS:" "${POD_LOG}" | cut -d':' -f2)
        
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
    else
        echo "   ❌ Failed to determine port status"
        echo "   Check logs at ${POD_LOG} for details"
        # Display the error from the log file
        echo "   Error output: $(head -n 10 ${POD_LOG} | grep -i error || echo 'No specific error found. See log for details.')"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        
        # Try an alternative method if the first one failed
        echo "   Attempting alternative method..."
        # Method 2: Try using kubectl exec directly if debug fails
        kubectl -n cattle-system exec ${pod} -c ${CONTAINER} -- sh -c "echo 'PORT CHECK FALLBACK'; netstat -tulpn 2>/dev/null || ss -lntp 2>/dev/null || echo 'Neither netstat nor ss available'" >> "${POD_LOG}" 2>&1
        
        # Log the alternative attempt
        echo "   Alternative method results saved to log"
    fi
    
    echo ""
done

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

if [ ${ERROR_COUNT} -gt 0 ]; then
    echo "⚠️ There were errors during execution. Please check the logs for details."
    echo "Common issues:"
    echo "  - Debug containers may not be supported in your Kubernetes cluster"
    echo "  - Your kubectl context might not have sufficient permissions"
    echo "  - The iproute2 package might not be installable in the debug container"
    echo ""
    echo "You can check the logs in ${LOG_DIR} for more details"
fi

exit ${EXIT_CODE}