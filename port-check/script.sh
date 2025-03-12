#!/bin/sh
# Rancher Port 6666 Checker - Non-interactive version
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

# METHOD 1: Try to use ephemeral containers (requires K8s >= 1.23)
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
    
    echo "   Attempting method with ephemeral container (non-interactive)..."
    
    # Create a temporary script for the port check
    CHECK_SCRIPT="${LOG_DIR}/${pod}-check.sh"
    cat > "${CHECK_SCRIPT}" << 'EOF'
#!/bin/sh
echo "Running port check..."
echo "Installing iproute2 package..."
apk add --no-cache iproute2 > /dev/null 2>&1
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
    
    # Try non-interactive debug (using --quiet to avoid TTY errors)
    kubectl debug -n cattle-system pod/${pod} --image=alpine:latest --quiet -- sh -c "cat > /tmp/check.sh << 'DEBUGEOF'
$(cat ${CHECK_SCRIPT})
DEBUGEOF
chmod +x /tmp/check.sh && /tmp/check.sh" > "${POD_LOG}" 2>&1
    
    # Check if the debug command produced the expected output
    if grep -q "PORT_STATUS:" "${POD_LOG}"; then
        PORT_STATUS=$(grep "PORT_STATUS:" "${POD_LOG}" | tail -1 | cut -d':' -f2)
        echo "   Successfully checked port status with debug container"
    else
        echo "   Debug container method failed, trying exec method..."
        
        # METHOD 2: Try kubectl exec if the container has the right tools
        kubectl -n cattle-system exec ${pod} -- sh -c "command -v ss || command -v netstat" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo "   Found networking tools in the container, using exec method..."
            kubectl -n cattle-system exec ${pod} -- sh -c "ss -lntp 2>/dev/null || netstat -tulpn 2>/dev/null" > "${POD_LOG}.exec" 2>&1
            
            # Check for port 6666 in the output
            if grep -q ":6666" "${POD_LOG}.exec"; then
                PORT_STATUS="ENABLED"
                echo "PORT_STATUS:ENABLED" >> "${POD_LOG}"
            else
                PORT_STATUS="DISABLED"
                echo "PORT_STATUS:DISABLED" >> "${POD_LOG}"
            fi
            echo "   Port check completed using exec method"
        else
            echo "   ❌ No networking tools available in container and debug container failed"
            echo "   Attempting port-forward method as last resort..."
            
            # METHOD 3: Try port-forwarding to see if the port is available
            TMP_PORT=$((10000 + $$))  # Use PID to create a somewhat unique port
            kubectl port-forward -n cattle-system pod/${pod} ${TMP_PORT}:6666 > /dev/null 2>&1 &
            PF_PID=$!
            sleep 3
            
            # Check if port-forward is successful
            if kill -0 ${PF_PID} 2>/dev/null; then
                PORT_STATUS="ENABLED"
                echo "PORT_STATUS:ENABLED" >> "${POD_LOG}"
                echo "   Port check completed using port-forward method"
                kill ${PF_PID}
            else
                PORT_STATUS="DISABLED"
                echo "PORT_STATUS:DISABLED" >> "${POD_LOG}"
                echo "   Port check completed using port-forward method"
            fi
        fi
    fi
    
    # Evaluate results based on port status
    if [ -z "${PORT_STATUS}" ]; then
        echo "   ❌ Failed to determine port status after all methods"
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