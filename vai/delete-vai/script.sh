#!/bin/zsh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

show_usage() {
    echo -e "${BOLD}Usage:${NC}"
    echo "  $0 [options]"
    echo
    echo -e "${BOLD}Options:${NC}"
    echo "  -a, --auto-mode    - Auto mode: delete all instances without prompting"
    echo "  -d, --dry-run      - Dry run: show what would be done without making changes"
    echo "  -h, --help         - Show this help message"
    echo
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0                # Interactive mode: check all pods and prompt for each instance"
    echo "  $0 --auto-mode    # Auto mode: delete all vai-query instances without prompting"
    echo "  $0 --dry-run      # Dry run: only report findings without making changes"
    echo
    echo -e "${BOLD}Curl Usage:${NC}"
    echo "  curl -sL https://raw.githubusercontent.com/brudnak/rancher-test-scripts/main/script.sh | zsh"
    echo "  curl -sL https://raw.githubusercontent.com/brudnak/rancher-test-scripts/main/script.sh | zsh -s -- --auto-mode"
}

check_prerequisites() {
    local prerequisites_met=true

    echo -e "${BOLD}Checking prerequisites...${NC}"

    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}❌ kubectl not found${NC}"
        echo "Please install kubectl and ensure it's in your PATH"
        prerequisites_met=false
    else
        echo -e "${GREEN}✅ kubectl found${NC}"

        if ! kubectl get nodes &> /dev/null; then
            echo -e "${RED}❌ Cannot connect to Kubernetes cluster${NC}"
            echo "Please check your cluster connection and kubectl configuration"
            prerequisites_met=false
        else
            echo -e "${GREEN}✅ Kubernetes cluster is accessible${NC}"

            if ! kubectl get namespace cattle-system &> /dev/null; then
                echo -e "${RED}❌ cattle-system namespace not found${NC}"
                echo "Please ensure you're connected to a Rancher cluster"
                prerequisites_met=false
            else
                echo -e "${GREEN}✅ cattle-system namespace found${NC}"
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
    echo -e "\n${BOLD}=== 📊 SUMMARY ===${NC}"
    echo -e "Total pods checked: ${BLUE}$TOTAL_PODS${NC}"
    echo -e "Pods with vai-query: ${YELLOW}$INFECTED_PODS${NC}"
    
    if [ "$AUTO_MODE" = true ]; then
        echo -e "Action taken: ${RED}Automatically deleted all vai-query instances${NC}"
    elif [ "$DRY_RUN" = true ]; then
        echo -e "Action taken: ${BLUE}Dry run - no changes made${NC}"
    else
        echo -e "Deleted instances: ${RED}$DELETED_COUNT${NC}"
        echo -e "Kept instances: ${GREEN}$KEPT_COUNT${NC}"
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
        *) echo -e "${RED}Unknown parameter: $1${NC}"; show_usage; exit 1 ;;
    esac
done

# Initialize counters
TOTAL_PODS=0
INFECTED_PODS=0
DELETED_COUNT=0
KEPT_COUNT=0

echo -e "${BOLD}VAI-Query detector for Rancher pods${NC}"
echo "==============================================="
if ! check_prerequisites; then
    echo -e "\n${RED}${BOLD}Prerequisites check failed!${NC}"
    echo "Please install missing components and try again"
    exit 1
fi
echo "==============================================="

if [ "$AUTO_MODE" = true ]; then
    echo -e "${YELLOW}Running in AUTO MODE - will delete all vai-query instances${NC}"
elif [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}Running in DRY RUN mode - no changes will be made${NC}"
else
    echo -e "${GREEN}Running in INTERACTIVE mode - will ask for confirmation${NC}"
fi

echo -e "\n${BOLD}Fetching Rancher pods in cattle-system namespace...${NC}"
# Only target rancher- pods that don't contain webhook or upgrade in their name
PODS=($(kubectl get pods -n cattle-system | grep "^rancher-" | grep -v "webhook" | grep -v "upgrade" | awk '{print $1}'))

if [ ${#PODS[@]} -eq 0 ]; then
    echo -e "${RED}No matching Rancher pods found in cattle-system namespace${NC}"
    exit 1
fi

echo -e "Found ${#PODS[@]} Rancher pods to check"

for pod in "${PODS[@]}"; do
    ((TOTAL_PODS++))
    echo -e "\n${BOLD}=== 🔍 Checking pod: ${BLUE}$pod${NC} ${BOLD}===${NC}"
    
    # Check if vai-query exists in /usr/local/bin
    VAI_CHECK=$(kubectl exec -n cattle-system "$pod" -- bash -c "if [ -f /usr/local/bin/vai-query ]; then echo 'found'; else echo 'not-found'; fi" 2>/dev/null)
    
    if [[ "$VAI_CHECK" != "found" ]]; then
        echo -e "${GREEN}✅ vai-query not found in this pod${NC}"
        continue
    fi
    
    ((INFECTED_PODS++))
    echo -e "${RED}⚠️ vai-query found in this pod!${NC}"
    
    # Get detailed file information
    FILE_INFO=$(kubectl exec -n cattle-system "$pod" -- bash -c "ls -la /usr/local/bin/vai-query" 2>/dev/null)
    echo -e "${YELLOW}File details:${NC} $FILE_INFO"
    
    # Try to get file modification timestamp and calculate age
    TIMESTAMP=$(kubectl exec -n cattle-system "$pod" -- bash -c "stat -c %Y /usr/local/bin/vai-query 2>/dev/null || echo 'unknown'" 2>/dev/null)
    CURRENT_TIME=$(date +%s)
    
    if [[ "$TIMESTAMP" != "unknown" && "$TIMESTAMP" != "" ]]; then
        AGE_SECONDS=$((CURRENT_TIME - TIMESTAMP))
        FORMATTED_AGE=$(format_time_duration $AGE_SECONDS)
        echo -e "${YELLOW}File age:${NC} $FORMATTED_AGE (created/modified at $(date -r $TIMESTAMP '+%Y-%m-%d %H:%M:%S'))"
    else
        echo -e "${YELLOW}File age:${NC} Could not determine"
    fi
    
    # Check file type
    FILE_TYPE=$(kubectl exec -n cattle-system "$pod" -- bash -c "file /usr/local/bin/vai-query" 2>/dev/null)
    echo -e "${YELLOW}File type:${NC} $FILE_TYPE"
    
    # Action based on mode
    if [ "$AUTO_MODE" = true ]; then
        if [ "$DRY_RUN" = true ]; then
            echo -e "${BLUE}[DRY RUN] Would delete vai-query from pod $pod${NC}"
        else
            echo -e "${RED}Automatically deleting vai-query from pod $pod...${NC}"
            DELETE_RESULT=$(kubectl exec -n cattle-system "$pod" -- bash -c "rm -f /usr/local/bin/vai-query" 2>&1)
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ Successfully deleted vai-query${NC}"
                ((DELETED_COUNT++))
            else
                echo -e "${RED}❌ Failed to delete vai-query: $DELETE_RESULT${NC}"
            fi
        fi
    elif [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY RUN] Would ask whether to delete vai-query from pod $pod${NC}"
    else
        echo -ne "${BOLD}Delete vai-query from this pod? [y/N]: ${NC}"
        read -r answer
        
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            echo -e "${RED}Deleting vai-query from pod $pod...${NC}"
            DELETE_RESULT=$(kubectl exec -n cattle-system "$pod" -- bash -c "rm -f /usr/local/bin/vai-query" 2>&1)
            DELETE_STATUS=$?
            if [ $DELETE_STATUS -eq 0 ]; then
                echo -e "${GREEN}✅ Successfully deleted vai-query${NC}"
                ((DELETED_COUNT++))
                
                # Verify it's gone
                VERIFY=$(kubectl exec -n cattle-system "$pod" -- bash -c "if [ -f /usr/local/bin/vai-query ]; then echo 'still-exists'; else echo 'removed'; fi" 2>/dev/null)
                if [[ "$VERIFY" == "removed" ]]; then
                    echo -e "${GREEN}✅ Verified: vai-query has been removed${NC}"
                else
                    echo -e "${RED}⚠️ Warning: vai-query might still exist despite deletion attempt${NC}"
                fi
            else
                echo -e "${RED}❌ Failed to delete vai-query (exit code: $DELETE_STATUS)${NC}"
                echo -e "${RED}Error: $DELETE_RESULT${NC}"
            fi
        else
            echo -e "${BLUE}Keeping vai-query in this pod${NC}"
            ((KEPT_COUNT++))
        fi
    fi
done

print_summary