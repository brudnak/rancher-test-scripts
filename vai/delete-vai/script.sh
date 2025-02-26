#!/bin/zsh

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

show_usage() {
    echo "${BOLD}Usage:${NC}"
    echo "  $0 [options]"
    echo
    echo "${BOLD}Options:${NC}"
    echo "  -a, --auto-mode    - Auto mode: delete all instances without prompting"
    echo "  -d, --dry-run      - Dry run: show what would be done without making changes"
    echo "  -h, --help         - Show this help message"
    echo
    echo "${BOLD}Examples:${NC}"
    echo "  $0                # Interactive mode: check all pods and prompt for each instance"
    echo "  $0 --auto-mode    # Auto mode: delete all vai-query instances without prompting"
    echo "  $0 --dry-run      # Dry run: only report findings without making changes"
    echo
    echo "${BOLD}Curl Usage:${NC}"
    echo "  curl -sL https://raw.githubusercontent.com/brudnak/rancher-test-scripts/refs/heads/main/vai/delete-vai/script.sh | zsh -s -- --auto-mode"
    echo "  Note: When running via curl, use --auto-mode or --dry-run as interactive mode is not supported"
}

check_prerequisites() {
    local prerequisites_met=true

    echo "${BOLD}Checking prerequisites...${NC}"

    if ! command -v kubectl &> /dev/null; then
        echo "${RED}❌ kubectl not found${NC}"
        echo "Please install kubectl and ensure it's in your PATH"
        prerequisites_met=false
    else
        echo "${GREEN}✅ kubectl found${NC}"

        if ! kubectl get nodes &> /dev/null; then
            echo "${RED}❌ Cannot connect to Kubernetes cluster${NC}"
            echo "Please check your cluster connection and kubectl configuration"
            prerequisites_met=false
        else
            echo "${GREEN}✅ Kubernetes cluster is accessible${NC}"

            if ! kubectl get namespace cattle-system &> /dev/null; then
                echo "${RED}❌ cattle-system namespace not found${NC}"
                echo "Please ensure you're connected to a Rancher cluster"
                prerequisites_met=false
            else
                echo "${GREEN}✅ cattle-system namespace found${NC}"
            fi
        fi
    fi

    $prerequisites_met
}

format_time_duration() {
    local seconds=$1
    local days=$((seconds / 86400))
    local remainder=$((seconds % 86400))
    local hours=$((remainder / 3600))
    local remainder=$((remainder % 3600))
    local minutes=$((remainder / 60))
    local secs=$((remainder % 60))
    
    if [ $days -gt 0 ]; then
        if [ $days -eq 1 ]; then
            printf "1 day, "
        else
            printf "%d days, " $days
        fi
    fi
    
    if [ $hours -gt 0 ]; then
        if [ $hours -eq 1 ]; then
            printf "1 hour, "
        else
            printf "%d hours, " $hours
        fi
    fi
    
    if [ $minutes -gt 0 ]; then
        if [ $minutes -eq 1 ]; then
            printf "1 minute, "
        else
            printf "%d minutes, " $minutes
        fi
    fi
    
    if [ $secs -eq 1 ]; then
        printf "1 second"
    else
        printf "%d seconds" $secs
    fi
}

print_summary() {
    echo
    echo "${BOLD}=== 📊 SUMMARY ===${NC}"
    echo "Total pods checked: ${BLUE}$TOTAL_PODS${NC}"
    echo "Pods with vai-query: ${YELLOW}$INFECTED_PODS${NC}"
    
    if [ "$AUTO_MODE" = true ]; then
        echo "Action taken: ${RED}Automatically deleted all vai-query instances${NC}"
    elif [ "$DRY_RUN" = true ]; then
        echo "Action taken: ${BLUE}Dry run - no changes made${NC}"
    else
        echo "Deleted instances: ${RED}$DELETED_COUNT${NC}"
        echo "Kept instances: ${GREEN}$KEPT_COUNT${NC}"
    fi
}

# Process command line arguments
AUTO_MODE=false
DRY_RUN=false

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -a|--auto-mode) AUTO_MODE=true; shift ;;
        -d|--dry-run) DRY_RUN=true; shift ;;
        -h|--help) show_usage; exit 0 ;;
        *) echo "${RED}Unknown parameter: $1${NC}"; show_usage; exit 1 ;;
    esac
done

# Check if we're being piped in a way that would prevent interactive input
if [ -p /dev/stdin ] && [ "$AUTO_MODE" = false ] && [ "$DRY_RUN" = false ]; then
    echo "${RED}Error: Running via curl pipe requires --auto-mode or --dry-run${NC}"
    echo "Please use one of these flags when running via curl, for example:"
    echo "  curl -sL https://raw.githubusercontent.com/username/repo/main/script.sh | zsh -s -- --auto-mode"
    echo "  curl -sL https://raw.githubusercontent.com/username/repo/main/script.sh | zsh -s -- --dry-run"
    exit 1
fi

# Initialize counters
TOTAL_PODS=0
INFECTED_PODS=0
DELETED_COUNT=0
KEPT_COUNT=0

echo "${BOLD}VAI-Query detector for Rancher pods${NC}"
echo "==============================================="
if ! check_prerequisites; then
    echo
    echo "${RED}${BOLD}Prerequisites check failed!${NC}"
    echo "Please install missing components and try again"
    exit 1
fi
echo "==============================================="

if [ "$AUTO_MODE" = true ]; then
    echo "${YELLOW}Running in AUTO MODE - will delete all vai-query instances${NC}"
elif [ "$DRY_RUN" = true ]; then
    echo "${BLUE}Running in DRY RUN mode - no changes will be made${NC}"
else
    echo "${GREEN}Running in INTERACTIVE mode - will ask for confirmation${NC}"
fi

echo
echo "${BOLD}Fetching Rancher pods in cattle-system namespace...${NC}"
# Only target rancher- pods that don't contain webhook or upgrade in their name
PODS=($(kubectl get pods -n cattle-system | grep "^rancher-" | grep -v "webhook" | grep -v "upgrade" | awk '{print $1}'))

if [ ${#PODS[@]} -eq 0 ]; then
    echo "${RED}No matching Rancher pods found in cattle-system namespace${NC}"
    exit 1
fi

echo "Found ${#PODS[@]} Rancher pods to check"

for pod in "${PODS[@]}"; do
    ((TOTAL_PODS++))
    echo
    echo "${BOLD}=== 🔍 Checking pod: ${BLUE}$pod${NC} ${BOLD}===${NC}"
    
    # Check if vai-query exists in /usr/local/bin
    VAI_CHECK=$(kubectl exec -n cattle-system "$pod" -- bash -c "if [ -f /usr/local/bin/vai-query ]; then echo 'found'; else echo 'not-found'; fi" 2>/dev/null)
    
    if [[ "$VAI_CHECK" != "found" ]]; then
        echo "${GREEN}✅ vai-query not found in this pod${NC}"
        continue
    fi
    
    ((INFECTED_PODS++))
    echo "${RED}⚠️ vai-query found in this pod!${NC}"
    
    # Get detailed file information
    FILE_INFO=$(kubectl exec -n cattle-system "$pod" -- bash -c "ls -la /usr/local/bin/vai-query" 2>/dev/null)
    echo "${YELLOW}File details:${NC} $FILE_INFO"
    
    # Try to get file modification timestamp and calculate age
    TIMESTAMP=$(kubectl exec -n cattle-system "$pod" -- bash -c "stat -c %Y /usr/local/bin/vai-query 2>/dev/null || echo 'unknown'" 2>/dev/null)
    CURRENT_TIME=$(date +%s)
    
    if [[ "$TIMESTAMP" != "unknown" && "$TIMESTAMP" != "" ]]; then
        AGE_SECONDS=$((CURRENT_TIME - TIMESTAMP))
        FORMATTED_AGE=$(format_time_duration $AGE_SECONDS)
        echo "${YELLOW}File age:${NC} $FORMATTED_AGE (created/modified at $(date -r $TIMESTAMP '+%Y-%m-%d %H:%M:%S'))"
    else
        echo "${YELLOW}File age:${NC} Could not determine"
    fi
    
    # Check file type
    FILE_TYPE=$(kubectl exec -n cattle-system "$pod" -- bash -c "file /usr/local/bin/vai-query" 2>/dev/null)
    echo "${YELLOW}File type:${NC} $FILE_TYPE"
    
    # Action based on mode
    if [ "$AUTO_MODE" = true ]; then
        echo "${RED}Automatically deleting vai-query from pod $pod...${NC}"
        DELETE_RESULT=$(kubectl exec -n cattle-system "$pod" -- bash -c "rm -f /usr/local/bin/vai-query" 2>&1)
        if [ $? -eq 0 ]; then
            echo "${GREEN}✅ Successfully deleted vai-query${NC}"
            ((DELETED_COUNT++))
        else
            echo "${RED}❌ Failed to delete vai-query: $DELETE_RESULT${NC}"
        fi
    elif [ "$DRY_RUN" = true ]; then
        echo "${BLUE}[DRY RUN] Would ask whether to delete vai-query from pod $pod${NC}"
    else
        echo -n "${BOLD}Delete vai-query from this pod? [y/N]: ${NC}"
        read -r answer
        
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            echo "${RED}Deleting vai-query from pod $pod...${NC}"
            DELETE_RESULT=$(kubectl exec -n cattle-system "$pod" -- bash -c "rm -f /usr/local/bin/vai-query" 2>&1)
            DELETE_STATUS=$?
            if [ $DELETE_STATUS -eq 0 ]; then
                echo "${GREEN}✅ Successfully deleted vai-query${NC}"
                ((DELETED_COUNT++))
                
                # Verify it's gone
                VERIFY=$(kubectl exec -n cattle-system "$pod" -- bash -c "if [ -f /usr/local/bin/vai-query ]; then echo 'still-exists'; else echo 'removed'; fi" 2>/dev/null)
                if [[ "$VERIFY" == "removed" ]]; then
                    echo "${GREEN}✅ Verified: vai-query has been removed${NC}"
                else
                    echo "${RED}⚠️ Warning: vai-query might still exist despite deletion attempt${NC}"
                fi
            else
                echo "${RED}❌ Failed to delete vai-query (exit code: $DELETE_STATUS)${NC}"
                echo "${RED}Error: $DELETE_RESULT${NC}"
            fi
        else
            echo "${BLUE}Keeping vai-query in this pod${NC}"
            ((KEPT_COUNT++))
        fi
    fi
done

print_summary