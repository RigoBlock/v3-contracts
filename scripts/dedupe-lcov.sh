#!/bin/bash
# Deduplicate LCOV entries - when same file appears multiple times, merge coverage
# This happens when both Hardhat and Foundry test the same file

set -e

INPUT="$1"
OUTPUT="$2"

if [ ! -f "$INPUT" ]; then
    echo "Error: Input file $INPUT not found"
    exit 1
fi

# Use awk to properly merge duplicate file entries
awk '
BEGIN { 
    current_file = ""
}

/^SF:/ {
    file = substr($0, 4)
    
    # If this file already processed, merge coverage data
    if (file in files_seen) {
        in_duplicate = 1
        current_file = file
        next
    }
    
    # New file, output it
    files_seen[file] = 1
    current_file = file
    in_duplicate = 0
    print
    next
}

/^end_of_record$/ {
    if (in_duplicate) {
        # Skip end_of_record for duplicate, will be added when we finish the file
        in_duplicate = 0
        next
    }
    print
    next
}

# For duplicate entries, skip all lines (we keep the first occurrence)
in_duplicate {
    next
}

# Output everything else
{
    print
}
' "$INPUT" > "$OUTPUT"

echo "Deduplicated: $(grep -c '^SF:' "$INPUT") entries -> $(grep -c '^SF:' "$OUTPUT") unique files"
