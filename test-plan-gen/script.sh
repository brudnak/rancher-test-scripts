#!/bin/bash

# Function to display usage information
usage() {
  echo "===== Test Template Generator ====="
  echo "This script generates a Markdown test template from a list of test titles."
  echo
  echo "Usage: $0 [options]"
  echo
  echo "Options:"
  echo "  -o, --output FILE   Output file name (default: test_template.md)"
  echo "  -p, --priority VAL  Default priority (default: P0)"
  echo "  -h, --help          Display this help message"
  echo
  echo "The script looks for 'tests.txt' in the current directory."
  echo "tests.txt should contain one test title per line."
  exit 1
}

# Parse command line arguments
OUTPUT_FILE="test_template.md"
DEFAULT_PRIORITY="P0"
TITLES_FILE="tests.txt"

while [[ "$#" -gt 0 ]]; do
  case $1 in
    -o|--output) OUTPUT_FILE="$2"; shift ;;
    -p|--priority) DEFAULT_PRIORITY="$2"; shift ;;
    -h|--help) usage ;;
    -*) echo "Unknown parameter: $1"; usage ;;
    *) TITLES_FILE="$1" ;;
  esac
  shift
done

# Check if titles file exists
if [ ! -f "$TITLES_FILE" ]; then
  echo "Error: Test titles file '$TITLES_FILE' not found"
  echo 
  echo "Please create a file named 'tests.txt' in the current directory with one test title per line."
  echo "Example content of tests.txt:"
  echo "------------------------"
  echo "First Test Case"
  echo "Second Test Case"
  echo "Third Test Case"
  echo "------------------------"
  exit 1
fi

# Count the number of test cases - make sure we count lines properly
TEST_COUNT=$(grep -c "[^[:space:]]" "$TITLES_FILE")

# Generate the header part of the template
cat > "$OUTPUT_FILE" << EOL
<!-- -->
<!-- -->

<details>
    <summary>🧪 Test Environment... CLICK TO EXPAND! ⬅️</summary>
<br>



</details>

<a name="top"></a>

### 🧪 Test Cases

| \\#  | Priority | Description & Link | PASS/FAIL        |
| --- | -------- | ------------------ | ---------------- |
EOL

# Generate the table rows
counter=1
while IFS= read -r title || [ -n "$title" ]; do
  # Skip empty lines
  if [[ "$title" =~ [^[:space:]] ]]; then
    echo "| $counter   | $DEFAULT_PRIORITY       | [$title](#test-$counter)  | ⏸️ NOT TESTED YET |" >> "$OUTPUT_FILE"
    ((counter++))
  fi
done < "$TITLES_FILE"

# Recalculate the final count to make sure it's accurate
FINAL_COUNT=$((counter - 1))

# Generate the details section header
cat >> "$OUTPUT_FILE" << EOL

<details>
    <summary>🚨 $FINAL_COUNT test cases... CLICK TO EXPAND! (For table links to work) ⬅️</summary>
<br>

EOL

# Generate individual test case templates
counter=1
while IFS= read -r title || [ -n "$title" ]; do
  # Skip empty lines
  if [[ "$title" =~ [^[:space:]] ]]; then
    cat >> "$OUTPUT_FILE" << EOL
# $counter / $title Status: ⏸️ NOT TESTED YET

<a name="test-$counter"></a>

**:small_red_triangle: [back to top](#top)**

<details>
    <summary>Test $counter details... Click to expand</summary>

**Test Steps for Validation**

1. step 1
2. step 2

**✅ Expected Outcome**

**✅ Actual Outcome**


</details>
<hr>

EOL
    ((counter++))
  fi
done < "$TITLES_FILE"

# Close the details section
echo "</details>" >> "$OUTPUT_FILE"

echo "Test template has been generated in $OUTPUT_FILE with $FINAL_COUNT test cases."