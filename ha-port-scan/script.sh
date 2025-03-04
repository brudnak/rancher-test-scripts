#!/bin/bash
set -e

# Allow script to be run via curl
# Example usage: curl -s https://raw.githubusercontent.com/brudnak/rancher-test-scripts/refs/heads/main/ha-port-scan/script.sh | bash

# Set default variables
PORT_TO_CHECK="${PORT_TO_CHECK:-6666}"
PORT_HEX="${PORT_HEX:-1A0A}"
KUBECONFIG="${KUBECONFIG:-local.yaml}"
NAMESPACE="${NAMESPACE:-cattle-system}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="port-check-${TIMESTAMP}"

# Print script header
echo "======================================================"
echo "   Rancher Pod Port Check - $(date)"
echo "======================================================"
echo "Checking for port ${PORT_TO_CHECK} (hex: ${PORT_HEX}) in Rancher pods"
echo ""

# Create log directory
mkdir -p "${LOG_DIR}"
echo "[INFO] Created log directory: ${LOG_DIR}"

# Function to log messages
log() {
    local level="$1"
    local message="$2"
    echo "[${level}] ${message}"
    echo "[${level}] ${message}" >> "${LOG_DIR}/port-check.log"
}

# Check if kubeconfig exists
if [ ! -f "${KUBECONFIG}" ]; then
    if [ -n "${KUBECONFIG_ENV}" ]; then
        KUBECONFIG="${KUBECONFIG_ENV}"
        log "INFO" "Using KUBECONFIG from environment variable: ${KUBECONFIG}"
    else
        log "ERROR" "Kubeconfig file '${KUBECONFIG}' not found!"
        log "ERROR" "Please ensure your kubeconfig file is present in the current directory and named 'local.yaml'"
        log "ERROR" "Alternatively, you can set KUBECONFIG_ENV when running the curl command:"
        log "ERROR" "  curl -s https://raw.githubusercontent.com/yourusername/rancher-port-check/main/rancher-port-check.sh | KUBECONFIG_ENV=/path/to/config.yaml bash"
        exit 1
    fi
fi

log "INFO" "Using kubeconfig: ${KUBECONFIG}"

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    log "ERROR" "kubectl command not found! Please install kubectl."
    exit 1
fi

# Check if we can connect to the cluster
log "INFO" "Verifying connection to Kubernetes cluster..."
if ! kubectl --kubeconfig="${KUBECONFIG}" get nodes &> /dev/null; then
    log "ERROR" "Failed to connect to Kubernetes cluster. Check your kubeconfig and cluster status."
    exit 1
fi

# Get all rancher pods in cattle-system namespace (excluding webhook pods)
log "INFO" "Finding Rancher pods in namespace '${NAMESPACE}'..."
PODS=$(kubectl --kubeconfig="${KUBECONFIG}" get pods -n "${NAMESPACE}" -l app=rancher --no-headers | grep -v webhook | awk '{print $1}')

if [ -z "${PODS}" ]; then
    log "ERROR" "No Rancher pods found in namespace '${NAMESPACE}'!"
    exit 1
fi

POD_COUNT=$(echo "${PODS}" | wc -l)
log "INFO" "Found ${POD_COUNT} Rancher pod(s)"

# Function to check if port is listening
check_port_listening() {
    local pod="$1"
    local tcp_file="${LOG_DIR}/${pod}_tcp.log"
    local tcp6_file="${LOG_DIR}/${pod}_tcp6.log"
    local results_file="${LOG_DIR}/${pod}_results.log"

    log "INFO" "Checking pod: ${pod}"
    
    # Get TCP and TCP6 port information from the pod
    log "INFO" "Extracting network information from pod..."
    kubectl --kubeconfig="${KUBECONFIG}" exec -n "${NAMESPACE}" "${pod}" -- cat /proc/net/tcp > "${tcp_file}" 2>/dev/null || true
    kubectl --kubeconfig="${KUBECONFIG}" exec -n "${NAMESPACE}" "${pod}" -- cat /proc/net/tcp6 > "${tcp6_file}" 2>/dev/null || true
    
    # Check if the files were created successfully
    if [ ! -s "${tcp_file}" ] && [ ! -s "${tcp6_file}" ]; then
        log "ERROR" "Failed to extract network information from pod ${pod}"
        return 1
    fi
    
    # Check for the specific port
    log "INFO" "Checking for port ${PORT_TO_CHECK} in pod ${pod}..."
    
    echo "Port check results for pod: ${pod}" > "${results_file}"
    echo "--------------------------------------------" >> "${results_file}"
    echo "Checking for port ${PORT_TO_CHECK} (hex ${PORT_HEX})..." >> "${results_file}"
    
    local port_found=false
    
    # Check in TCP
    if grep -q ":${PORT_HEX}" "${tcp_file}" 2>/dev/null; then
        log "SUCCESS" "Port ${PORT_TO_CHECK} is LISTENING on pod ${pod} (TCP)"
        echo "TCP: Port ${PORT_TO_CHECK} is LISTENING" >> "${results_file}"
        grep ":${PORT_HEX}" "${tcp_file}" >> "${results_file}"
        port_found=true
    else
        echo "TCP: Port ${PORT_TO_CHECK} is NOT listening" >> "${results_file}"
    fi
    
    # Check in TCP6
    if grep -q ":${PORT_HEX}" "${tcp6_file}" 2>/dev/null; then
        log "SUCCESS" "Port ${PORT_TO_CHECK} is LISTENING on pod ${pod} (TCP6)"
        echo "TCP6: Port ${PORT_TO_CHECK} is LISTENING" >> "${results_file}"
        grep ":${PORT_HEX}" "${tcp6_file}" >> "${results_file}"
        port_found=true
    else
        echo "TCP6: Port ${PORT_TO_CHECK} is NOT listening" >> "${results_file}"
    fi
    
    if [ "$port_found" = false ]; then
        log "WARNING" "Port ${PORT_TO_CHECK} is NOT listening on pod ${pod}"
    fi
    
    echo "--------------------------------------------" >> "${results_file}"
    return 0
}

# Process each pod
TOTAL_PODS=$(echo "${PODS}" | wc -w)
CURRENT_POD=0
LISTENING_PODS=0

for pod in ${PODS}; do
    CURRENT_POD=$((CURRENT_POD + 1))
    log "INFO" "Processing pod ${CURRENT_POD}/${TOTAL_PODS}: ${pod}"
    
    # Check if the port is listening on this pod
    if check_port_listening "${pod}"; then
        # Check if the port was actually found
        if grep -q "is LISTENING" "${LOG_DIR}/${pod}_results.log"; then
            LISTENING_PODS=$((LISTENING_PODS + 1))
        fi
    fi
    
    echo ""
done

# Print summary
echo "======================================================"
echo "                      SUMMARY                         "
echo "======================================================"
echo "Total Rancher pods checked: ${TOTAL_PODS}"
echo "Pods with port ${PORT_TO_CHECK} listening: ${LISTENING_PODS}"
echo ""
echo "Detailed logs saved in: ${LOG_DIR}"
echo "======================================================"

if [ ${LISTENING_PODS} -gt 0 ]; then
    log "SUCCESS" "${LISTENING_PODS} pod(s) have port ${PORT_TO_CHECK} listening"
    exit 0
else 
    log "WARNING" "No pods have port ${PORT_TO_CHECK} listening"
    exit 1
fi