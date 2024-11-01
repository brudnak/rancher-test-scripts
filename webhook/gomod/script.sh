#!/bin/bash

# Function to show usage
show_usage() {
    echo "Usage: $0 <rancher_go.mod> <webhook_go.mod>"
    echo "Example: $0 rancher.mod webhook.mod"
}

# Check if correct number of arguments provided
if [ "$#" -ne 2 ]; then
    show_usage
    exit 1
fi

RANCHER_MOD="$1"
WEBHOOK_MOD="$2"

# Verify input files exist
if [ ! -f "$RANCHER_MOD" ]; then
    echo "Error: Rancher go.mod file '$RANCHER_MOD' not found"
    exit 1
fi

if [ ! -f "$WEBHOOK_MOD" ]; then
    echo "Error: Webhook go.mod file '$WEBHOOK_MOD' not found"
    exit 1
fi

# Set up logging and output
timestamp=$(date '+%Y%m%d_%H%M%S')
output_file="rancher_deps_comparison_${timestamp}.txt"

# Function to extract clean repository name from a line
get_repo_name() {
    echo "$1" | sed -n 's/.*github.com\/rancher\/\([^/ ]*\).*/\1/p'
}

# Function to extract all instances of a repo from a file
get_all_instances() {
    local file="$1"
    local repo="$2"
    # Find all lines containing the repo, including both requires and replaces
    grep "github.com/rancher/${repo}[/ ]" "$file" || true
}

# Function to extract and format dependencies
extract_deps() {
    local file="$1"
    local prefix="$2"
    echo -e "\n${prefix} Dependencies (github.com/rancher/*)"
    echo "=================================================="
    echo -e "\nRequire statements:"
    grep "github.com/rancher" "$file" | grep -v "=>" || true
    echo -e "\nReplace statements:"
    grep "github.com/rancher.*=>" "$file" || true
}

{
    echo "Rancher Dependencies Comparison Report - Generated at $(date)"
    echo "==========================================================="
    echo "Comparing:"
    echo "  Rancher: $RANCHER_MOD"
    echo "  Webhook: $WEBHOOK_MOD"
    echo "==========================================================="

    # List all Rancher dependencies from each file
    extract_deps "$RANCHER_MOD" "Rancher Module"
    extract_deps "$WEBHOOK_MOD" "Webhook Module"

    # Create lists of unique repository names
    echo -e "\nFinding all unique Rancher repositories..."
    {
        grep "github.com/rancher" "$RANCHER_MOD" "$WEBHOOK_MOD" | \
        sed 's/.*github.com\/rancher\/\([^/ ]*\).*/\1/' | \
        sort -u
    } > temp_repos.txt

    # Compare versions for each repository
    echo -e "\nDetailed Version Analysis:"
    echo "=========================="
    version_mismatches=0
    
    while read -r repo; do
        rancher_instances=$(get_all_instances "$RANCHER_MOD" "$repo")
        webhook_instances=$(get_all_instances "$WEBHOOK_MOD" "$repo")
        
        # Only process if repo exists in both files
        if [[ -n "$rancher_instances" && -n "$webhook_instances" ]]; then
            echo -e "\nRepository: github.com/rancher/$repo"
            echo "In Rancher:"
            while IFS= read -r line; do
                echo "    $line"
            done <<< "$rancher_instances"
            
            echo "In Webhook:"
            while IFS= read -r line; do
                echo "    $line"
            done <<< "$webhook_instances"
            
            # Check for version mismatches
            rancher_versions=$(echo "$rancher_instances" | grep -o 'v[0-9][^ ]*' | sort -u)
            webhook_versions=$(echo "$webhook_instances" | grep -o 'v[0-9][^ ]*' | sort -u)
            
            if [[ "$rancher_versions" != "$webhook_versions" ]]; then
                ((version_mismatches++))
            fi
        fi
    done < temp_repos.txt

    echo -e "\nVersion Mismatches Found ($version_mismatches total):"
    echo "==========================================="
    while read -r repo; do
        rancher_instances=$(get_all_instances "$RANCHER_MOD" "$repo")
        webhook_instances=$(get_all_instances "$WEBHOOK_MOD" "$repo")
        
        if [[ -n "$rancher_instances" && -n "$webhook_instances" ]]; then
            rancher_versions=$(echo "$rancher_instances" | grep -o 'v[0-9][^ ]*' | sort -u)
            webhook_versions=$(echo "$webhook_instances" | grep -o 'v[0-9][^ ]*' | sort -u)
            
            if [[ "$rancher_versions" != "$webhook_versions" ]]; then
                echo -e "\nRepository: github.com/rancher/$repo"
                echo "In Rancher:"
                while IFS= read -r line; do
                    echo "    $line"
                done <<< "$rancher_instances"
                
                echo "In Webhook:"
                while IFS= read -r line; do
                    echo "    $line"
                done <<< "$webhook_instances"
            fi
        fi
    done < temp_repos.txt

    echo -e "\nSummary:"
    echo "========"
    echo "Total Rancher dependencies in $RANCHER_MOD: $(grep -c "github.com/rancher" "$RANCHER_MOD")"
    echo "Total Rancher dependencies in $WEBHOOK_MOD: $(grep -c "github.com/rancher" "$WEBHOOK_MOD")"
    echo "Number of version mismatches found: $version_mismatches"

    # Cleanup
    rm -f temp_repos.txt
} | tee "$output_file"

echo "Report generated: $output_file"
