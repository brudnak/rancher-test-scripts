#!/bin/zsh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

show_usage() {
    echo -e "${BOLD}Usage:${NC}"
    echo "  $0 <namespace> <duration_minutes>"
    echo
    echo -e "${BOLD}Arguments:${NC}"
    echo "  namespace         - The namespace to search for"
    echo "  duration_minutes  - Maximum time to keep checking (in minutes, default: 3)"
    echo
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0 dadfish 5     # Search for 'dadfish' namespace for up to 5 minutes"
    echo "  $0 myspace 2     # Search for 'myspace' namespace for up to 2 minutes"
    echo
    echo -e "${BOLD}Curl Usage:${NC}"
    echo "  curl -sL https://raw.githubusercontent.com/brudnak/rancher-test-scripts/refs/heads/main/vai/namespace/script.sh | zsh -s -- myspace 3"
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

    if ! command -v sqlite3 &> /dev/null; then
        echo -e "${RED}❌ sqlite3 not found${NC}"
        echo "Please install sqlite3:"
        echo "  - For Mac: brew install sqlite"
        echo "  - For Ubuntu/Debian: sudo apt-get install sqlite3"
        echo "  - For RHEL/CentOS: sudo yum install sqlite"
        prerequisites_met=false
    else
        echo -e "${GREEN}✅ sqlite3 found${NC}"
    fi

    $prerequisites_met
}

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while ps -p $pid > /dev/null; do
        for i in ${(s::)spinstr}; do
            echo -ne "\r[${i}] Waiting for next check... ($(date '+%H:%M:%S'))"
            sleep $delay
        done
    done
    echo -ne "\r\033[K"
}

format_time_remaining() {
    local seconds=$1
    local minutes=$((seconds / 60))
    seconds=$((seconds % 60))
    printf "%02d:%02d" $minutes $seconds
}

print_final_summary() {
    local actual_duration=$1
    local planned_duration=$2
    local early_exit=$3

    echo -e "\n${BOLD}=== 📊 FINAL SUMMARY ===${NC}"
    echo -e "Search for: ${BLUE}$NAMESPACE_TO_FIND${NC}"
    if [ "$early_exit" = true ]; then
        echo -e "${GREEN}✅ Successfully found in all pods!${NC}"
        echo -e "Planned duration: ${YELLOW}$planned_duration minutes${NC}"
        local minutes_taken=$(printf "%.2f" "$(echo "scale=2; $actual_duration/60" | bc)")
        echo -e "Actual duration: ${GREEN}$minutes_taken minutes${NC}"
        local percent_faster=$(printf "%.1f" "$(echo "scale=1; ($planned_duration*60-$actual_duration)/($planned_duration*60)*100" | bc)")
        echo -e "Completed ${GREEN}$percent_faster%${NC} faster than maximum time"
    else
        echo -e "${RED}❌ Did not find namespace in all pods within time limit${NC}"
        echo -e "Duration: ${YELLOW}$planned_duration minutes${NC} (maximum time reached)"
    fi

    echo -e "\n${BOLD}Pod Discovery Timeline:${NC}"
    for pod in ${(k)pod_first_found}; do
        found_time=$((${pod_first_found[$pod]} - START_TIME))
        echo -e "${BLUE}$pod:${NC} Found after ${GREEN}$found_time seconds${NC}"
    done

    if [ "$early_exit" = true ]; then
        echo -e "\n${BOLD}Total propagation time:${NC} ${GREEN}$total_propagation_time seconds${NC}"
    fi

    echo -e "\n${BOLD}Cache files saved in:${NC}"
    echo "$HOME/Downloads/rancher-caches/"
}

if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_usage
    exit 1
fi

NAMESPACE_TO_FIND="$1"
DURATION_MINUTES=${2:-3}

if ! [[ "$DURATION_MINUTES" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: Duration must be a positive number${NC}"
    show_usage
    exit 1
fi

DURATION=$((DURATION_MINUTES * 60))
INTERVAL=15
START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION))

echo -e "${BOLD}Performing initial checks...${NC}"
echo "==============================================="
if ! check_prerequisites; then
    echo -e "\n${RED}${BOLD}Prerequisites check failed!${NC}"
    echo "Please install missing components and try again"
    exit 1
fi
echo "==============================================="

typeset -A pod_found_times
typeset -A pod_first_found

echo -e "${BOLD}Starting search for namespace: ${BLUE}$NAMESPACE_TO_FIND${NC}"
echo -e "Maximum runtime: ${YELLOW}$DURATION_MINUTES minutes${NC}, checking every ${YELLOW}15 seconds${NC}"
echo -e "Start time: ${GREEN}$(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo "==============================================="

check_pods() {
    local iteration=$1
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local BASE_DIR="$HOME/Downloads/rancher-caches/$timestamp"

    mkdir -p "$BASE_DIR"

    echo -e "\n${BOLD}📊 Iteration $iteration - $(date '+%Y-%m-%d %H:%M:%S')${NC}"

    local current_time=$(date +%s)
    local elapsed=$((current_time - START_TIME))
    local remaining=$((END_TIME - current_time))
    echo -e "${YELLOW}⏱  Time elapsed: $(format_time_remaining $elapsed) | Remaining: $(format_time_remaining $remaining)${NC}"

    local found_count=0

    kubectl get pods -n cattle-system --no-headers | grep "^rancher-" | grep -v "webhook" | grep -v "upgrade" | while read -r line; do
        local pod_name=$(echo "$line" | awk '{print $1}')
        echo -e "\n${BLUE}🔍 Processing pod: $pod_name${NC}"

        local POD_DIR="$BASE_DIR/$pod_name"
        mkdir -p "$POD_DIR"

        if kubectl cp "cattle-system/$pod_name:informer_object_cache.db" "$POD_DIR/informer_object_cache.db" 2>/dev/null; then
            if [ -s "$POD_DIR/informer_object_cache.db" ]; then
                echo -e "📁 Cache file copied successfully"
                local search_result=$(sqlite3 "$POD_DIR/informer_object_cache.db" "SELECT \"metadata.name\"
                                    FROM \"_v1_Namespace_fields\"
                                    WHERE \"metadata.name\" LIKE '%$NAMESPACE_TO_FIND%';" 2>/dev/null)

                if [ -n "$search_result" ]; then
                    echo -e "${GREEN}✅ Found match in pod: $pod_name${NC}"
                    current_time=$(date +%s)
                    pod_found_times[$pod_name]=$current_time

                    if [ -z "${pod_first_found[$pod_name]}" ]; then
                        pod_first_found[$pod_name]=$current_time
                        echo -e "${GREEN}🎉 First appearance in $pod_name at $(date '+%Y-%m-%d %H:%M:%S')${NC}"
                    fi
                    ((found_count++))
                else
                    echo -e "${RED}❌ No match in pod: $pod_name${NC}"
                    unset "pod_found_times[$pod_name]"
                fi
            else
                echo -e "${RED}⚠️  Warning: Copied file is empty for $pod_name${NC}"
                rm -f "$POD_DIR/informer_object_cache.db"
            fi
        else
            echo -e "${RED}❌ Failed to copy cache from $pod_name${NC}"
        fi
    done

    ls -dt "$HOME/Downloads/rancher-caches"/*/ 2>/dev/null | tail -n +4 | xargs rm -rf 2>/dev/null

    if [ $found_count -eq 3 ]; then
        echo -e "\n${GREEN}${BOLD}🎯 !!! NAMESPACE FOUND IN ALL PODS !!!${NC}"
        echo -e "${BOLD}Time to propagate across all pods:${NC}"
        local earliest_time=$END_TIME
        local latest_time=0

        for pod in ${(k)pod_first_found}; do
            local found_time=${pod_first_found[$pod]}
            local time_diff=$((found_time - START_TIME))
            echo -e "${BLUE}$pod:${NC} Found after ${GREEN}$time_diff seconds${NC}"

            if [ $found_time -lt $earliest_time ]; then
                earliest_time=$found_time
            fi
            if [ $found_time -gt $latest_time ]; then
                latest_time=$found_time
            fi
        done

        total_propagation_time=$((latest_time - earliest_time))
        echo -e "${BOLD}Total propagation time:${NC} ${GREEN}$total_propagation_time seconds${NC}"
        echo "==============================================="

        local actual_duration=$(($(date +%s) - START_TIME))
        print_final_summary $actual_duration $DURATION_MINUTES true
        exit 0
    fi
}

iteration=1
while [ $(date +%s) -lt $END_TIME ]; do
    check_pods $iteration

    current_time=$(date +%s)
    if [ $((current_time + INTERVAL)) -lt $END_TIME ]; then
        sleep $INTERVAL &
        spinner $!
    else
        remaining_time=$((END_TIME - current_time))
        if [ $remaining_time -gt 0 ]; then
            sleep $remaining_time &
            spinner $!
        fi
    fi

    ((iteration++))
done

actual_duration=$(($(date +%s) - START_TIME))
print_final_summary $actual_duration $DURATION_MINUTES false
