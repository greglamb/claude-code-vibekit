#!/bin/bash

# filesplitter.sh - Split large text files into token-limited chunks for Claude CLI

set -euo pipefail

# Cleanup function
cleanup() {
    local exit_code=$?
    if [ -n "${temp_file:-}" ] && [ -f "$temp_file" ]; then
        rm -f "$temp_file"
    fi
    exit $exit_code
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
MAX_TOKENS="${MAX_TOKENS:-25000}"
TOKEN_BUFFER=1000  # Safety buffer to ensure we stay under limit
CHUNK_MODE="${CHUNK_MODE:-safe}"  # safe or fast
DEBUG="${DEBUG:-false}"  # Enable debug output
TOKENCOUNT_CMD="${TOKENCOUNT_CMD:-$SCRIPT_DIR/../tokencount/tokencount.py}"  # Path to tokencount command

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to show usage
show_usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  split <input_file> [output_prefix]     Split a file into parts
  join <prefix>                          Join parts back into single file
  check <prefix>                         Check token counts of existing parts
  reprocess <prefix>                    Reprocess existing parts (after edits)
  append <prefix> <content_file>         Add content to existing parts
  summary <prefix>                       Show summary of part contents

Options:
  -h, --help                            Show this help message

Environment variables:
  CHUNK_MODE=safe|fast  (default: safe)
  MAX_TOKENS=25000      (default: 25000)
  DEBUG=true|false      (default: false)
  TOKENCOUNT_CMD=path   (default: ../tokencount/tokencount.py)

Examples:
  $0 split large_document.txt doc
  $0 check doc
  $0 reprocess doc
  $0 append doc new_content.txt
  $0 join doc > recovered_document.txt

  # With custom tokencount path:
  TOKENCOUNT_CMD=/usr/local/bin/tokencount $0 split large.txt
EOF
}

# Check if tokencount command exists
check_dependencies() {
    if [ ! -f "$TOKENCOUNT_CMD" ] || [ ! -x "$TOKENCOUNT_CMD" ]; then
        echo -e "${RED}Error: tokencount command not found or not executable${NC}"
        echo "Expected at: $TOKENCOUNT_CMD"
        echo ""
        echo "The default location is relative to this script:"
        echo "  $(dirname "$SCRIPT_DIR")/tokencount/tokencount.py"
        echo ""
        echo "You can specify a custom path by setting TOKENCOUNT_CMD:"
        echo "  TOKENCOUNT_CMD=/path/to/tokencount $0 ..."
        echo "  export TOKENCOUNT_CMD=/path/to/tokencount"
        echo ""
        echo "Or ensure tokencount exists at the expected location."
        exit 1
    fi
}

# Function to count tokens in a string
count_tokens() {
    echo "$1" | "$TOKENCOUNT_CMD"
}

# Function to create the prefix for a part
create_prefix() {
    local part_num=$1
    local total_parts=$2

    cat <<EOF
Model: GPT-4

The total length of the content that I want to send you is too large to send in only one piece.

For sending you that content, I will follow this rule:

[START PART $part_num/$total_parts]
this is the content of the part $part_num out of $total_parts in total
[END PART $part_num/$total_parts]

Then you just answer: "Received part $part_num/$total_parts"

And when I tell you "ALL PARTS SENT", then you can continue processing the data and answering my requests.
EOF
}

# Function to create the postfix for a part
create_postfix() {
    local part_num=$1
    local total_parts=$2

    if [ "$part_num" -lt "$total_parts" ]; then
        cat <<EOF

Remember not answering yet. Just acknowledge you received this part with the message "Part $part_num/$total_parts received" and wait for the next part.
EOF
    else
        cat <<EOF

ALL PARTS SENT. Now you can continue processing the request.
EOF
    fi
}

# Function to estimate wrapper tokens for a part
estimate_wrapper_tokens() {
    local part_num=$1
    local total_parts=$2

    # Create wrapper and count actual tokens
    local prefix=$(create_prefix "$part_num" "$total_parts")
    local postfix=$(create_postfix "$part_num" "$total_parts")
    local markers="[START PART $part_num/$total_parts]"$'\n'"[END PART $part_num/$total_parts]"

    local wrapper="${prefix}"

# Function to extract content from a part file
extract_content() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo -e "${RED}Error: Part file '$file' not found${NC}" >&2
        return 1
    fi
    # Extract content between START PART and END PART markers
    sed -n '/\[START PART [0-9]*\/[0-9]*\]/,/\[END PART [0-9]*\/[0-9]*\]/{
        /\[START PART [0-9]*\/[0-9]*\]/d
        /\[END PART [0-9]*\/[0-9]*\]/d
        p
    }' "$file"
}

# Function to find all part files for a prefix
find_part_files() {
    local prefix="$1"
    # Use a more specific pattern to avoid matching backup directories
    ls "${prefix}"_[0-9]*_of_[0-9]*.txt 2>/dev/null | sort -V
}

# Split command
cmd_split() {
    local input_file="$1"
    local output_prefix="${2:-$(basename "$input_file" | sed 's/\.[^.]*$//')_part}"

    if [ ! -f "$input_file" ]; then
        echo -e "${RED}Error: Input file '$input_file' not found${NC}"
        exit 1
    fi

    # Check for existing parts
    existing_parts=$(find_part_files "$output_prefix")
    if [ -n "$existing_parts" ]; then
        echo -e "${YELLOW}Warning: Found existing parts with prefix '$output_prefix'${NC}"
        read -p "Overwrite existing parts? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 1
        fi
        rm -f $existing_parts
    fi

    split_file "$input_file" "$output_prefix"
}

# Main splitting logic
split_file() {
    local input_file="$1"
    local output_prefix="$2"

    # Count total lines for progress
    echo "Counting total lines..."
    total_lines=$(wc -l < "$input_file")
    echo "Total lines: $total_lines"

    # Estimate wrapper overhead
    dummy_wrapper_tokens=$(estimate_wrapper_tokens 99 99)
    echo "Estimated wrapper overhead: ~$dummy_wrapper_tokens tokens"

    temp_parts=()
    current_part=""
    current_tokens=0
    line_count=0

    # Read file line by line
    while IFS= read -r line || [ -n "$line" ]; do
        line_count=$((line_count + 1))

        # Handle empty lines properly
        if [ -z "$line" ]; then
            current_part="${current_part}"

    # Don't forget the last part
    if [ -n "$current_part" ]; then
        temp_parts+=("$current_part")
    fi

    echo -e "\nTotal parts needed: ${#temp_parts[@]}"

    # Create the actual files
    total_parts=${#temp_parts[@]}

    for i in "${!temp_parts[@]}"; do
        part_num=$((i + 1))
        output_file="${output_prefix}_${part_num}_of_${total_parts}.txt"

        echo "Creating part $part_num/$total_parts: $output_file"

        {
            create_prefix "$part_num" "$total_parts"
            echo ""
            echo "[START PART $part_num/$total_parts]"
            printf "%s" "${temp_parts[$i]}"
            echo "[END PART $part_num/$total_parts]"
            create_postfix "$part_num" "$total_parts"
        } > "$output_file"

        # Verify token count
        final_tokens=$("$TOKENCOUNT_CMD" < "$output_file")
        echo "  Token count: $final_tokens"

        if [ $final_tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}  ERROR: Part $part_num exceeds $MAX_TOKENS tokens ($final_tokens)!${NC}"
            echo "  Consider using a smaller MAX_TOKENS value or splitting by paragraphs."
            exit 1
        fi
    done

    create_helper_script "$output_prefix" "$total_parts"

    echo -e "\n${GREEN}Success!${NC}"
    echo "- Split '$input_file' into $total_parts parts"
    echo "- Output files: ${output_prefix}_*_of_${total_parts}.txt"
    echo "- Helper script: ${output_prefix}_send_to_claude.sh"
}

# Check command - verify token counts of existing parts
cmd_check() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Checking parts with prefix '$prefix'..."
    echo ""

    local any_issues=false

    for part_file in $parts; do
        tokens=$("$TOKENCOUNT_CMD" < "$part_file")

        if [ $tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}✗ $part_file: $tokens tokens (EXCEEDS LIMIT)${NC}"
            any_issues=true
        elif [ $tokens -gt $((MAX_TOKENS - TOKEN_BUFFER)) ]; then
            echo -e "${YELLOW}⚠ $part_file: $tokens tokens (near limit)${NC}"
        else
            echo -e "${GREEN}✓ $part_file: $tokens tokens${NC}"
        fi
    done

    if [ "$any_issues" = true ]; then
        echo -e "\n${RED}Issues found! Run 'reprocess' to fix.${NC}"
        exit 1
    else
        echo -e "\n${GREEN}All parts are within token limits.${NC}"
    fi
}

# Join command - reconstruct original file from parts
cmd_join() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}Joining parts with prefix '$prefix'...${NC}" >&2

    for part_file in $parts; do
        extract_content "$part_file"
    done
}

# Reprocess command - handle edited parts that may have grown
cmd_reprocess() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Reprocessing parts with prefix '$prefix'..."

    # First, join all parts back together
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"

    # Get the current total parts number
    current_total=$(echo "$parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt$/\2/p')

    if [ -z "$current_total" ]; then
        echo -e "${RED}Error: Could not determine total parts from existing files${NC}"
        exit 1
    fi

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"

    # Report changes
    new_parts=$(find_part_files "$prefix")
    new_total=$(echo "$new_parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    echo ""
    if [ "$current_total" != "$new_total" ]; then
        echo -e "${YELLOW}Part count changed: $current_total → $new_total${NC}"
    else
        echo -e "${GREEN}Part count unchanged: $new_total parts${NC}"
    fi
}

# Append command - add new content to existing parts
cmd_append() {
    local prefix="$1"
    local new_content_file="$2"

    if [ ! -f "$new_content_file" ]; then
        echo -e "${RED}Error: Content file '$new_content_file' not found${NC}"
        exit 1
    fi

    local parts=$(find_part_files "$prefix")
    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Appending content to parts with prefix '$prefix'..."

    # Join existing content and append new content
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"
    cat "$new_content_file" >> "$temp_file"

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the combined file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"
}

# Create helper script for sending to Claude
create_helper_script() {
    local prefix="$1"
    local total_parts="$2"
    local helper_script="${prefix}_send_to_claude.sh"

    cat > "$helper_script" <<'HELPER'
#!/bin/bash
set -e

# Check if claude command exists
if ! command -v claude &> /dev/null; then
    echo "Error: 'claude' command not found. Please install Claude Code CLI."
    exit 1
fi

echo "Sending all parts to Claude Code CLI..."
echo "Make sure to wait for acknowledgment after each part!"
echo ""

HELPER

    for i in $(seq 1 $total_parts); do
        echo "echo \"Sending part $i/$total_parts...\"" >> "$helper_script"
        echo "claude < \"${prefix}_${i}_of_${total_parts}.txt\"" >> "$helper_script"
        if [ $i -lt $total_parts ]; then
            echo "echo \"\"" >> "$helper_script"
            echo "echo \"Waiting for acknowledgment...\"" >> "$helper_script"
            echo "echo \"Claude should respond: 'Part $i/$total_parts received'\"" >> "$helper_script"
            echo "read -p \"Press Enter after Claude acknowledges part $i: \"" >> "$helper_script"
        fi
        echo "" >> "$helper_script"
    done

    echo "echo \"All parts sent successfully!\"" >> "$helper_script"
    chmod +x "$helper_script"
}

# Summary command - show overview of parts
cmd_summary() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Summary of parts with prefix '$prefix':"
    echo ""

    for part_file in $parts; do
        tokens=$("$TOKENCOUNT_CMD" < "$part_file")
        content=$(extract_content "$part_file")
        lines=$(echo "$content" | wc -l)
        first_line=$(echo "$content" | head -1 | cut -c1-60)
        last_line=$(echo "$content" | tail -1 | cut -c1-60)

        echo -e "${GREEN}$part_file${NC}"
        echo "  Tokens: $tokens"
        echo "  Lines: $lines"
        echo "  First: $first_line..."
        echo "  Last:  $last_line..."
        echo ""
    done
}

# Main script logic
check_dependencies

if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

command="$1"
shift

case "$command" in
    split)
        [ $# -lt 1 ] && { echo "Error: Missing input file"; show_usage; exit 1; }
        cmd_split "$@"
        ;;
    check)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_check "$1"
        ;;
    join)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_join "$1"
        ;;
    reprocess)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_reprocess "$1"
        ;;
    append)
        [ $# -lt 2 ] && { echo "Error: Missing prefix or content file"; show_usage; exit 1; }
        cmd_append "$1" "$2"
        ;;
    summary)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_summary "$1"
        ;;
    -h|--help|help)
        show_usage
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$command'${NC}"
        show_usage
        exit 1
        ;;
esac\n'
            continue
        fi

        # Check tokens periodically or when approaching limit
        if [ $line_count -eq 1 ] || [ $((line_count % 10)) -eq 0 ] || [ $current_tokens -gt $((MAX_TOKENS - TOKEN_BUFFER - dummy_wrapper_tokens - 5000)) ]; then
            test_content="${current_part}${line}"

    # Don't forget the last part
    if [ -n "$current_part" ]; then
        temp_parts+=("$current_part")
    fi

    echo -e "\nTotal parts needed: ${#temp_parts[@]}"

    # Create the actual files
    total_parts=${#temp_parts[@]}

    for i in "${!temp_parts[@]}"; do
        part_num=$((i + 1))
        output_file="${output_prefix}_${part_num}_of_${total_parts}.txt"

        echo "Creating part $part_num/$total_parts: $output_file"

        {
            create_prefix "$part_num" "$total_parts"
            echo ""
            echo "[START PART $part_num/$total_parts]"
            printf "%s" "${temp_parts[$i]}"
            echo "[END PART $part_num/$total_parts]"
            create_postfix "$part_num" "$total_parts"
        } > "$output_file"

        # Verify token count
        final_tokens=$(tokencount < "$output_file")
        echo "  Token count: $final_tokens"

        if [ $final_tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}  ERROR: Part $part_num exceeds $MAX_TOKENS tokens ($final_tokens)!${NC}"
            echo "  Consider using a smaller MAX_TOKENS value or splitting by paragraphs."
            exit 1
        fi
    done

    create_helper_script "$output_prefix" "$total_parts"

    echo -e "\n${GREEN}Success!${NC}"
    echo "- Split '$input_file' into $total_parts parts"
    echo "- Output files: ${output_prefix}_*_of_${total_parts}.txt"
    echo "- Helper script: ${output_prefix}_send_to_claude.sh"
}

# Check command - verify token counts of existing parts
cmd_check() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Checking parts with prefix '$prefix'..."
    echo ""

    local any_issues=false

    for part_file in $parts; do
        tokens=$(tokencount < "$part_file")

        if [ $tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}✗ $part_file: $tokens tokens (EXCEEDS LIMIT)${NC}"
            any_issues=true
        elif [ $tokens -gt $((MAX_TOKENS - TOKEN_BUFFER)) ]; then
            echo -e "${YELLOW}⚠ $part_file: $tokens tokens (near limit)${NC}"
        else
            echo -e "${GREEN}✓ $part_file: $tokens tokens${NC}"
        fi
    done

    if [ "$any_issues" = true ]; then
        echo -e "\n${RED}Issues found! Run 'reprocess' to fix.${NC}"
        exit 1
    else
        echo -e "\n${GREEN}All parts are within token limits.${NC}"
    fi
}

# Join command - reconstruct original file from parts
cmd_join() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}Joining parts with prefix '$prefix'...${NC}" >&2

    for part_file in $parts; do
        extract_content "$part_file"
    done
}

# Reprocess command - handle edited parts that may have grown
cmd_reprocess() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Reprocessing parts with prefix '$prefix'..."

    # First, join all parts back together
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"

    # Get the current total parts number
    current_total=$(echo "$parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"

    # Report changes
    new_parts=$(find_part_files "$prefix")
    new_total=$(echo "$new_parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    echo ""
    if [ "$current_total" != "$new_total" ]; then
        echo -e "${YELLOW}Part count changed: $current_total → $new_total${NC}"
    else
        echo -e "${GREEN}Part count unchanged: $new_total parts${NC}"
    fi
}

# Append command - add new content to existing parts
cmd_append() {
    local prefix="$1"
    local new_content_file="$2"

    if [ ! -f "$new_content_file" ]; then
        echo -e "${RED}Error: Content file '$new_content_file' not found${NC}"
        exit 1
    fi

    local parts=$(find_part_files "$prefix")
    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Appending content to parts with prefix '$prefix'..."

    # Join existing content and append new content
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"
    cat "$new_content_file" >> "$temp_file"

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the combined file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"
}

# Create helper script for sending to Claude
create_helper_script() {
    local prefix="$1"
    local total_parts="$2"
    local helper_script="${prefix}_send_to_claude.sh"

    cat > "$helper_script" <<'HELPER'
#!/bin/bash
set -e

# Check if claude command exists
if ! command -v claude &> /dev/null; then
    echo "Error: 'claude' command not found. Please install Claude Code CLI."
    exit 1
fi

echo "Sending all parts to Claude Code CLI..."
echo "Make sure to wait for acknowledgment after each part!"
echo ""

HELPER

    for i in $(seq 1 $total_parts); do
        echo "echo \"Sending part $i/$total_parts...\"" >> "$helper_script"
        echo "claude < \"${prefix}_${i}_of_${total_parts}.txt\"" >> "$helper_script"
        if [ $i -lt $total_parts ]; then
            echo "echo \"\"" >> "$helper_script"
            echo "echo \"Waiting for acknowledgment...\"" >> "$helper_script"
            echo "echo \"Claude should respond: 'Part $i/$total_parts received'\"" >> "$helper_script"
            echo "read -p \"Press Enter after Claude acknowledges part $i: \"" >> "$helper_script"
        fi
        echo "" >> "$helper_script"
    done

    echo "echo \"All parts sent successfully!\"" >> "$helper_script"
    chmod +x "$helper_script"
}

# Main script logic
check_dependencies

if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

command="$1"
shift

case "$command" in
    split)
        [ $# -lt 1 ] && { echo "Error: Missing input file"; show_usage; exit 1; }
        cmd_split "$@"
        ;;
    check)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_check "$1"
        ;;
    join)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_join "$1"
        ;;
    reprocess)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_reprocess "$1"
        ;;
    append)
        [ $# -lt 2 ] && { echo "Error: Missing prefix or content file"; show_usage; exit 1; }
        cmd_append "$1" "$2"
        ;;
    -h|--help|help)
        show_usage
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$command'${NC}"
        show_usage
        exit 1
        ;;
esac\n'
            test_tokens=$(echo "$test_content" | tokencount)

            if [ $test_tokens -gt $((MAX_TOKENS - TOKEN_BUFFER - dummy_wrapper_tokens)) ] && [ -n "$current_part" ]; then
                temp_parts+=("$current_part")
                current_part="${line}"

    # Don't forget the last part
    if [ -n "$current_part" ]; then
        temp_parts+=("$current_part")
    fi

    echo -e "\nTotal parts needed: ${#temp_parts[@]}"

    # Create the actual files
    total_parts=${#temp_parts[@]}

    for i in "${!temp_parts[@]}"; do
        part_num=$((i + 1))
        output_file="${output_prefix}_${part_num}_of_${total_parts}.txt"

        echo "Creating part $part_num/$total_parts: $output_file"

        {
            create_prefix "$part_num" "$total_parts"
            echo ""
            echo "[START PART $part_num/$total_parts]"
            printf "%s" "${temp_parts[$i]}"
            echo "[END PART $part_num/$total_parts]"
            create_postfix "$part_num" "$total_parts"
        } > "$output_file"

        # Verify token count
        final_tokens=$(tokencount < "$output_file")
        echo "  Token count: $final_tokens"

        if [ $final_tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}  ERROR: Part $part_num exceeds $MAX_TOKENS tokens ($final_tokens)!${NC}"
            echo "  Consider using a smaller MAX_TOKENS value or splitting by paragraphs."
            exit 1
        fi
    done

    create_helper_script "$output_prefix" "$total_parts"

    echo -e "\n${GREEN}Success!${NC}"
    echo "- Split '$input_file' into $total_parts parts"
    echo "- Output files: ${output_prefix}_*_of_${total_parts}.txt"
    echo "- Helper script: ${output_prefix}_send_to_claude.sh"
}

# Check command - verify token counts of existing parts
cmd_check() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Checking parts with prefix '$prefix'..."
    echo ""

    local any_issues=false

    for part_file in $parts; do
        tokens=$(tokencount < "$part_file")

        if [ $tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}✗ $part_file: $tokens tokens (EXCEEDS LIMIT)${NC}"
            any_issues=true
        elif [ $tokens -gt $((MAX_TOKENS - TOKEN_BUFFER)) ]; then
            echo -e "${YELLOW}⚠ $part_file: $tokens tokens (near limit)${NC}"
        else
            echo -e "${GREEN}✓ $part_file: $tokens tokens${NC}"
        fi
    done

    if [ "$any_issues" = true ]; then
        echo -e "\n${RED}Issues found! Run 'reprocess' to fix.${NC}"
        exit 1
    else
        echo -e "\n${GREEN}All parts are within token limits.${NC}"
    fi
}

# Join command - reconstruct original file from parts
cmd_join() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}Joining parts with prefix '$prefix'...${NC}" >&2

    for part_file in $parts; do
        extract_content "$part_file"
    done
}

# Reprocess command - handle edited parts that may have grown
cmd_reprocess() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Reprocessing parts with prefix '$prefix'..."

    # First, join all parts back together
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"

    # Get the current total parts number
    current_total=$(echo "$parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"

    # Report changes
    new_parts=$(find_part_files "$prefix")
    new_total=$(echo "$new_parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    echo ""
    if [ "$current_total" != "$new_total" ]; then
        echo -e "${YELLOW}Part count changed: $current_total → $new_total${NC}"
    else
        echo -e "${GREEN}Part count unchanged: $new_total parts${NC}"
    fi
}

# Append command - add new content to existing parts
cmd_append() {
    local prefix="$1"
    local new_content_file="$2"

    if [ ! -f "$new_content_file" ]; then
        echo -e "${RED}Error: Content file '$new_content_file' not found${NC}"
        exit 1
    fi

    local parts=$(find_part_files "$prefix")
    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Appending content to parts with prefix '$prefix'..."

    # Join existing content and append new content
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"
    cat "$new_content_file" >> "$temp_file"

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the combined file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"
}

# Create helper script for sending to Claude
create_helper_script() {
    local prefix="$1"
    local total_parts="$2"
    local helper_script="${prefix}_send_to_claude.sh"

    cat > "$helper_script" <<'HELPER'
#!/bin/bash
set -e

# Check if claude command exists
if ! command -v claude &> /dev/null; then
    echo "Error: 'claude' command not found. Please install Claude Code CLI."
    exit 1
fi

echo "Sending all parts to Claude Code CLI..."
echo "Make sure to wait for acknowledgment after each part!"
echo ""

HELPER

    for i in $(seq 1 $total_parts); do
        echo "echo \"Sending part $i/$total_parts...\"" >> "$helper_script"
        echo "claude < \"${prefix}_${i}_of_${total_parts}.txt\"" >> "$helper_script"
        if [ $i -lt $total_parts ]; then
            echo "echo \"\"" >> "$helper_script"
            echo "echo \"Waiting for acknowledgment...\"" >> "$helper_script"
            echo "echo \"Claude should respond: 'Part $i/$total_parts received'\"" >> "$helper_script"
            echo "read -p \"Press Enter after Claude acknowledges part $i: \"" >> "$helper_script"
        fi
        echo "" >> "$helper_script"
    done

    echo "echo \"All parts sent successfully!\"" >> "$helper_script"
    chmod +x "$helper_script"
}

# Main script logic
check_dependencies

if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

command="$1"
shift

case "$command" in
    split)
        [ $# -lt 1 ] && { echo "Error: Missing input file"; show_usage; exit 1; }
        cmd_split "$@"
        ;;
    check)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_check "$1"
        ;;
    join)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_join "$1"
        ;;
    reprocess)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_reprocess "$1"
        ;;
    append)
        [ $# -lt 2 ] && { echo "Error: Missing prefix or content file"; show_usage; exit 1; }
        cmd_append "$1" "$2"
        ;;
    -h|--help|help)
        show_usage
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$command'${NC}"
        show_usage
        exit 1
        ;;
esac\n'
                current_tokens=$(echo "$current_part" | tokencount)
            else
                current_part="${test_content}"
                current_tokens=$test_tokens
            fi
        else
            current_part="${current_part}${line}"

    # Don't forget the last part
    if [ -n "$current_part" ]; then
        temp_parts+=("$current_part")
    fi

    echo -e "\nTotal parts needed: ${#temp_parts[@]}"

    # Create the actual files
    total_parts=${#temp_parts[@]}

    for i in "${!temp_parts[@]}"; do
        part_num=$((i + 1))
        output_file="${output_prefix}_${part_num}_of_${total_parts}.txt"

        echo "Creating part $part_num/$total_parts: $output_file"

        {
            create_prefix "$part_num" "$total_parts"
            echo ""
            echo "[START PART $part_num/$total_parts]"
            printf "%s" "${temp_parts[$i]}"
            echo "[END PART $part_num/$total_parts]"
            create_postfix "$part_num" "$total_parts"
        } > "$output_file"

        # Verify token count
        final_tokens=$(tokencount < "$output_file")
        echo "  Token count: $final_tokens"

        if [ $final_tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}  ERROR: Part $part_num exceeds $MAX_TOKENS tokens ($final_tokens)!${NC}"
            echo "  Consider using a smaller MAX_TOKENS value or splitting by paragraphs."
            exit 1
        fi
    done

    create_helper_script "$output_prefix" "$total_parts"

    echo -e "\n${GREEN}Success!${NC}"
    echo "- Split '$input_file' into $total_parts parts"
    echo "- Output files: ${output_prefix}_*_of_${total_parts}.txt"
    echo "- Helper script: ${output_prefix}_send_to_claude.sh"
}

# Check command - verify token counts of existing parts
cmd_check() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Checking parts with prefix '$prefix'..."
    echo ""

    local any_issues=false

    for part_file in $parts; do
        tokens=$(tokencount < "$part_file")

        if [ $tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}✗ $part_file: $tokens tokens (EXCEEDS LIMIT)${NC}"
            any_issues=true
        elif [ $tokens -gt $((MAX_TOKENS - TOKEN_BUFFER)) ]; then
            echo -e "${YELLOW}⚠ $part_file: $tokens tokens (near limit)${NC}"
        else
            echo -e "${GREEN}✓ $part_file: $tokens tokens${NC}"
        fi
    done

    if [ "$any_issues" = true ]; then
        echo -e "\n${RED}Issues found! Run 'reprocess' to fix.${NC}"
        exit 1
    else
        echo -e "\n${GREEN}All parts are within token limits.${NC}"
    fi
}

# Join command - reconstruct original file from parts
cmd_join() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}Joining parts with prefix '$prefix'...${NC}" >&2

    for part_file in $parts; do
        extract_content "$part_file"
    done
}

# Reprocess command - handle edited parts that may have grown
cmd_reprocess() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Reprocessing parts with prefix '$prefix'..."

    # First, join all parts back together
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"

    # Get the current total parts number
    current_total=$(echo "$parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"

    # Report changes
    new_parts=$(find_part_files "$prefix")
    new_total=$(echo "$new_parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    echo ""
    if [ "$current_total" != "$new_total" ]; then
        echo -e "${YELLOW}Part count changed: $current_total → $new_total${NC}"
    else
        echo -e "${GREEN}Part count unchanged: $new_total parts${NC}"
    fi
}

# Append command - add new content to existing parts
cmd_append() {
    local prefix="$1"
    local new_content_file="$2"

    if [ ! -f "$new_content_file" ]; then
        echo -e "${RED}Error: Content file '$new_content_file' not found${NC}"
        exit 1
    fi

    local parts=$(find_part_files "$prefix")
    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Appending content to parts with prefix '$prefix'..."

    # Join existing content and append new content
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"
    cat "$new_content_file" >> "$temp_file"

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the combined file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"
}

# Create helper script for sending to Claude
create_helper_script() {
    local prefix="$1"
    local total_parts="$2"
    local helper_script="${prefix}_send_to_claude.sh"

    cat > "$helper_script" <<'HELPER'
#!/bin/bash
set -e

# Check if claude command exists
if ! command -v claude &> /dev/null; then
    echo "Error: 'claude' command not found. Please install Claude Code CLI."
    exit 1
fi

echo "Sending all parts to Claude Code CLI..."
echo "Make sure to wait for acknowledgment after each part!"
echo ""

HELPER

    for i in $(seq 1 $total_parts); do
        echo "echo \"Sending part $i/$total_parts...\"" >> "$helper_script"
        echo "claude < \"${prefix}_${i}_of_${total_parts}.txt\"" >> "$helper_script"
        if [ $i -lt $total_parts ]; then
            echo "echo \"\"" >> "$helper_script"
            echo "echo \"Waiting for acknowledgment...\"" >> "$helper_script"
            echo "echo \"Claude should respond: 'Part $i/$total_parts received'\"" >> "$helper_script"
            echo "read -p \"Press Enter after Claude acknowledges part $i: \"" >> "$helper_script"
        fi
        echo "" >> "$helper_script"
    done

    echo "echo \"All parts sent successfully!\"" >> "$helper_script"
    chmod +x "$helper_script"
}

# Main script logic
check_dependencies

if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

command="$1"
shift

case "$command" in
    split)
        [ $# -lt 1 ] && { echo "Error: Missing input file"; show_usage; exit 1; }
        cmd_split "$@"
        ;;
    check)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_check "$1"
        ;;
    join)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_join "$1"
        ;;
    reprocess)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_reprocess "$1"
        ;;
    append)
        [ $# -lt 2 ] && { echo "Error: Missing prefix or content file"; show_usage; exit 1; }
        cmd_append "$1" "$2"
        ;;
    -h|--help|help)
        show_usage
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$command'${NC}"
        show_usage
        exit 1
        ;;
esac\n'
        fi

        # Progress indicator
        if [ $((line_count % 100)) -eq 0 ]; then
            printf "\rProcessed %d/%d lines (%.1f%%)..." "$line_count" "$total_lines" \
                "$(echo "scale=1; $line_count * 100 / $total_lines" | bc)"
        fi
    done < "$input_file"

    # Don't forget the last part
    if [ -n "$current_part" ]; then
        temp_parts+=("$current_part")
    fi

    echo -e "\nTotal parts needed: ${#temp_parts[@]}"

    # Create the actual files
    total_parts=${#temp_parts[@]}

    for i in "${!temp_parts[@]}"; do
        part_num=$((i + 1))
        output_file="${output_prefix}_${part_num}_of_${total_parts}.txt"

        echo "Creating part $part_num/$total_parts: $output_file"

        {
            create_prefix "$part_num" "$total_parts"
            echo ""
            echo "[START PART $part_num/$total_parts]"
            printf "%s" "${temp_parts[$i]}"
            echo "[END PART $part_num/$total_parts]"
            create_postfix "$part_num" "$total_parts"
        } > "$output_file"

        # Verify token count
        final_tokens=$(tokencount < "$output_file")
        echo "  Token count: $final_tokens"

        if [ $final_tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}  ERROR: Part $part_num exceeds $MAX_TOKENS tokens ($final_tokens)!${NC}"
            echo "  Consider using a smaller MAX_TOKENS value or splitting by paragraphs."
            exit 1
        fi
    done

    create_helper_script "$output_prefix" "$total_parts"

    echo -e "\n${GREEN}Success!${NC}"
    echo "- Split '$input_file' into $total_parts parts"
    echo "- Output files: ${output_prefix}_*_of_${total_parts}.txt"
    echo "- Helper script: ${output_prefix}_send_to_claude.sh"
}

# Check command - verify token counts of existing parts
cmd_check() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Checking parts with prefix '$prefix'..."
    echo ""

    local any_issues=false

    for part_file in $parts; do
        tokens=$(tokencount < "$part_file")

        if [ $tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}✗ $part_file: $tokens tokens (EXCEEDS LIMIT)${NC}"
            any_issues=true
        elif [ $tokens -gt $((MAX_TOKENS - TOKEN_BUFFER)) ]; then
            echo -e "${YELLOW}⚠ $part_file: $tokens tokens (near limit)${NC}"
        else
            echo -e "${GREEN}✓ $part_file: $tokens tokens${NC}"
        fi
    done

    if [ "$any_issues" = true ]; then
        echo -e "\n${RED}Issues found! Run 'reprocess' to fix.${NC}"
        exit 1
    else
        echo -e "\n${GREEN}All parts are within token limits.${NC}"
    fi
}

# Join command - reconstruct original file from parts
cmd_join() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}Joining parts with prefix '$prefix'...${NC}" >&2

    for part_file in $parts; do
        extract_content "$part_file"
    done
}

# Reprocess command - handle edited parts that may have grown
cmd_reprocess() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Reprocessing parts with prefix '$prefix'..."

    # First, join all parts back together
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"

    # Get the current total parts number
    current_total=$(echo "$parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"

    # Report changes
    new_parts=$(find_part_files "$prefix")
    new_total=$(echo "$new_parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    echo ""
    if [ "$current_total" != "$new_total" ]; then
        echo -e "${YELLOW}Part count changed: $current_total → $new_total${NC}"
    else
        echo -e "${GREEN}Part count unchanged: $new_total parts${NC}"
    fi
}

# Append command - add new content to existing parts
cmd_append() {
    local prefix="$1"
    local new_content_file="$2"

    if [ ! -f "$new_content_file" ]; then
        echo -e "${RED}Error: Content file '$new_content_file' not found${NC}"
        exit 1
    fi

    local parts=$(find_part_files "$prefix")
    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Appending content to parts with prefix '$prefix'..."

    # Join existing content and append new content
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"
    cat "$new_content_file" >> "$temp_file"

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the combined file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"
}

# Create helper script for sending to Claude
create_helper_script() {
    local prefix="$1"
    local total_parts="$2"
    local helper_script="${prefix}_send_to_claude.sh"

    cat > "$helper_script" <<'HELPER'
#!/bin/bash
set -e

# Check if claude command exists
if ! command -v claude &> /dev/null; then
    echo "Error: 'claude' command not found. Please install Claude Code CLI."
    exit 1
fi

echo "Sending all parts to Claude Code CLI..."
echo "Make sure to wait for acknowledgment after each part!"
echo ""

HELPER

    for i in $(seq 1 $total_parts); do
        echo "echo \"Sending part $i/$total_parts...\"" >> "$helper_script"
        echo "claude < \"${prefix}_${i}_of_${total_parts}.txt\"" >> "$helper_script"
        if [ $i -lt $total_parts ]; then
            echo "echo \"\"" >> "$helper_script"
            echo "echo \"Waiting for acknowledgment...\"" >> "$helper_script"
            echo "echo \"Claude should respond: 'Part $i/$total_parts received'\"" >> "$helper_script"
            echo "read -p \"Press Enter after Claude acknowledges part $i: \"" >> "$helper_script"
        fi
        echo "" >> "$helper_script"
    done

    echo "echo \"All parts sent successfully!\"" >> "$helper_script"
    chmod +x "$helper_script"
}

# Main script logic
check_dependencies

if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

command="$1"
shift

case "$command" in
    split)
        [ $# -lt 1 ] && { echo "Error: Missing input file"; show_usage; exit 1; }
        cmd_split "$@"
        ;;
    check)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_check "$1"
        ;;
    join)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_join "$1"
        ;;
    reprocess)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_reprocess "$1"
        ;;
    append)
        [ $# -lt 2 ] && { echo "Error: Missing prefix or content file"; show_usage; exit 1; }
        cmd_append "$1" "$2"
        ;;
    -h|--help|help)
        show_usage
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$command'${NC}"
        show_usage
        exit 1
        ;;
esac\n\n'"${markers}"

# Function to extract content from a part file
extract_content() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo -e "${RED}Error: Part file '$file' not found${NC}" >&2
        return 1
    fi
    # Extract content between START PART and END PART markers
    sed -n '/\[START PART [0-9]*\/[0-9]*\]/,/\[END PART [0-9]*\/[0-9]*\]/{
        /\[START PART [0-9]*\/[0-9]*\]/d
        /\[END PART [0-9]*\/[0-9]*\]/d
        p
    }' "$file"
}

# Function to find all part files for a prefix
find_part_files() {
    local prefix="$1"
    # Use a more specific pattern to avoid matching backup directories
    ls "${prefix}"_[0-9]*_of_[0-9]*.txt 2>/dev/null | sort -V
}

# Split command
cmd_split() {
    local input_file="$1"
    local output_prefix="${2:-$(basename "$input_file" | sed 's/\.[^.]*$//')_part}"

    if [ ! -f "$input_file" ]; then
        echo -e "${RED}Error: Input file '$input_file' not found${NC}"
        exit 1
    fi

    # Check for existing parts
    existing_parts=$(find_part_files "$output_prefix")
    if [ -n "$existing_parts" ]; then
        echo -e "${YELLOW}Warning: Found existing parts with prefix '$output_prefix'${NC}"
        read -p "Overwrite existing parts? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 1
        fi
        rm -f $existing_parts
    fi

    split_file "$input_file" "$output_prefix"
}

# Main splitting logic
split_file() {
    local input_file="$1"
    local output_prefix="$2"

    # Count total lines for progress
    echo "Counting total lines..."
    total_lines=$(wc -l < "$input_file")
    echo "Total lines: $total_lines"

    # Estimate wrapper overhead
    dummy_wrapper_tokens=$(estimate_wrapper_tokens 99 99)
    echo "Estimated wrapper overhead: ~$dummy_wrapper_tokens tokens"

    temp_parts=()
    current_part=""
    current_tokens=0
    line_count=0

    # Read file line by line
    while IFS= read -r line || [ -n "$line" ]; do
        line_count=$((line_count + 1))

        # Handle empty lines properly
        if [ -z "$line" ]; then
            current_part="${current_part}"

    # Don't forget the last part
    if [ -n "$current_part" ]; then
        temp_parts+=("$current_part")
    fi

    echo -e "\nTotal parts needed: ${#temp_parts[@]}"

    # Create the actual files
    total_parts=${#temp_parts[@]}

    for i in "${!temp_parts[@]}"; do
        part_num=$((i + 1))
        output_file="${output_prefix}_${part_num}_of_${total_parts}.txt"

        echo "Creating part $part_num/$total_parts: $output_file"

        {
            create_prefix "$part_num" "$total_parts"
            echo ""
            echo "[START PART $part_num/$total_parts]"
            printf "%s" "${temp_parts[$i]}"
            echo "[END PART $part_num/$total_parts]"
            create_postfix "$part_num" "$total_parts"
        } > "$output_file"

        # Verify token count
        final_tokens=$(tokencount < "$output_file")
        echo "  Token count: $final_tokens"

        if [ $final_tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}  ERROR: Part $part_num exceeds $MAX_TOKENS tokens ($final_tokens)!${NC}"
            echo "  Consider using a smaller MAX_TOKENS value or splitting by paragraphs."
            exit 1
        fi
    done

    create_helper_script "$output_prefix" "$total_parts"

    echo -e "\n${GREEN}Success!${NC}"
    echo "- Split '$input_file' into $total_parts parts"
    echo "- Output files: ${output_prefix}_*_of_${total_parts}.txt"
    echo "- Helper script: ${output_prefix}_send_to_claude.sh"
}

# Check command - verify token counts of existing parts
cmd_check() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Checking parts with prefix '$prefix'..."
    echo ""

    local any_issues=false

    for part_file in $parts; do
        tokens=$(tokencount < "$part_file")

        if [ $tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}✗ $part_file: $tokens tokens (EXCEEDS LIMIT)${NC}"
            any_issues=true
        elif [ $tokens -gt $((MAX_TOKENS - TOKEN_BUFFER)) ]; then
            echo -e "${YELLOW}⚠ $part_file: $tokens tokens (near limit)${NC}"
        else
            echo -e "${GREEN}✓ $part_file: $tokens tokens${NC}"
        fi
    done

    if [ "$any_issues" = true ]; then
        echo -e "\n${RED}Issues found! Run 'reprocess' to fix.${NC}"
        exit 1
    else
        echo -e "\n${GREEN}All parts are within token limits.${NC}"
    fi
}

# Join command - reconstruct original file from parts
cmd_join() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}Joining parts with prefix '$prefix'...${NC}" >&2

    for part_file in $parts; do
        extract_content "$part_file"
    done
}

# Reprocess command - handle edited parts that may have grown
cmd_reprocess() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Reprocessing parts with prefix '$prefix'..."

    # First, join all parts back together
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"

    # Get the current total parts number
    current_total=$(echo "$parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt$/\2/p')

    if [ -z "$current_total" ]; then
        echo -e "${RED}Error: Could not determine total parts from existing files${NC}"
        exit 1
    fi

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"

    # Report changes
    new_parts=$(find_part_files "$prefix")
    new_total=$(echo "$new_parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    echo ""
    if [ "$current_total" != "$new_total" ]; then
        echo -e "${YELLOW}Part count changed: $current_total → $new_total${NC}"
    else
        echo -e "${GREEN}Part count unchanged: $new_total parts${NC}"
    fi
}

# Append command - add new content to existing parts
cmd_append() {
    local prefix="$1"
    local new_content_file="$2"

    if [ ! -f "$new_content_file" ]; then
        echo -e "${RED}Error: Content file '$new_content_file' not found${NC}"
        exit 1
    fi

    local parts=$(find_part_files "$prefix")
    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Appending content to parts with prefix '$prefix'..."

    # Join existing content and append new content
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"
    cat "$new_content_file" >> "$temp_file"

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the combined file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"
}

# Create helper script for sending to Claude
create_helper_script() {
    local prefix="$1"
    local total_parts="$2"
    local helper_script="${prefix}_send_to_claude.sh"

    cat > "$helper_script" <<'HELPER'
#!/bin/bash
set -e

# Check if claude command exists
if ! command -v claude &> /dev/null; then
    echo "Error: 'claude' command not found. Please install Claude Code CLI."
    exit 1
fi

echo "Sending all parts to Claude Code CLI..."
echo "Make sure to wait for acknowledgment after each part!"
echo ""

HELPER

    for i in $(seq 1 $total_parts); do
        echo "echo \"Sending part $i/$total_parts...\"" >> "$helper_script"
        echo "claude < \"${prefix}_${i}_of_${total_parts}.txt\"" >> "$helper_script"
        if [ $i -lt $total_parts ]; then
            echo "echo \"\"" >> "$helper_script"
            echo "echo \"Waiting for acknowledgment...\"" >> "$helper_script"
            echo "echo \"Claude should respond: 'Part $i/$total_parts received'\"" >> "$helper_script"
            echo "read -p \"Press Enter after Claude acknowledges part $i: \"" >> "$helper_script"
        fi
        echo "" >> "$helper_script"
    done

    echo "echo \"All parts sent successfully!\"" >> "$helper_script"
    chmod +x "$helper_script"
}

# Summary command - show overview of parts
cmd_summary() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Summary of parts with prefix '$prefix':"
    echo ""

    for part_file in $parts; do
        tokens=$(tokencount < "$part_file")
        content=$(extract_content "$part_file")
        lines=$(echo "$content" | wc -l)
        first_line=$(echo "$content" | head -1 | cut -c1-60)
        last_line=$(echo "$content" | tail -1 | cut -c1-60)

        echo -e "${GREEN}$part_file${NC}"
        echo "  Tokens: $tokens"
        echo "  Lines: $lines"
        echo "  First: $first_line..."
        echo "  Last:  $last_line..."
        echo ""
    done
}

# Main script logic
check_dependencies

if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

command="$1"
shift

case "$command" in
    split)
        [ $# -lt 1 ] && { echo "Error: Missing input file"; show_usage; exit 1; }
        cmd_split "$@"
        ;;
    check)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_check "$1"
        ;;
    join)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_join "$1"
        ;;
    reprocess)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_reprocess "$1"
        ;;
    append)
        [ $# -lt 2 ] && { echo "Error: Missing prefix or content file"; show_usage; exit 1; }
        cmd_append "$1" "$2"
        ;;
    summary)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_summary "$1"
        ;;
    -h|--help|help)
        show_usage
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$command'${NC}"
        show_usage
        exit 1
        ;;
esac\n'
            continue
        fi

        # Check tokens periodically or when approaching limit
        if [ $line_count -eq 1 ] || [ $((line_count % 10)) -eq 0 ] || [ $current_tokens -gt $((MAX_TOKENS - TOKEN_BUFFER - dummy_wrapper_tokens - 5000)) ]; then
            test_content="${current_part}${line}"

    # Don't forget the last part
    if [ -n "$current_part" ]; then
        temp_parts+=("$current_part")
    fi

    echo -e "\nTotal parts needed: ${#temp_parts[@]}"

    # Create the actual files
    total_parts=${#temp_parts[@]}

    for i in "${!temp_parts[@]}"; do
        part_num=$((i + 1))
        output_file="${output_prefix}_${part_num}_of_${total_parts}.txt"

        echo "Creating part $part_num/$total_parts: $output_file"

        {
            create_prefix "$part_num" "$total_parts"
            echo ""
            echo "[START PART $part_num/$total_parts]"
            printf "%s" "${temp_parts[$i]}"
            echo "[END PART $part_num/$total_parts]"
            create_postfix "$part_num" "$total_parts"
        } > "$output_file"

        # Verify token count
        final_tokens=$(tokencount < "$output_file")
        echo "  Token count: $final_tokens"

        if [ $final_tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}  ERROR: Part $part_num exceeds $MAX_TOKENS tokens ($final_tokens)!${NC}"
            echo "  Consider using a smaller MAX_TOKENS value or splitting by paragraphs."
            exit 1
        fi
    done

    create_helper_script "$output_prefix" "$total_parts"

    echo -e "\n${GREEN}Success!${NC}"
    echo "- Split '$input_file' into $total_parts parts"
    echo "- Output files: ${output_prefix}_*_of_${total_parts}.txt"
    echo "- Helper script: ${output_prefix}_send_to_claude.sh"
}

# Check command - verify token counts of existing parts
cmd_check() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Checking parts with prefix '$prefix'..."
    echo ""

    local any_issues=false

    for part_file in $parts; do
        tokens=$(tokencount < "$part_file")

        if [ $tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}✗ $part_file: $tokens tokens (EXCEEDS LIMIT)${NC}"
            any_issues=true
        elif [ $tokens -gt $((MAX_TOKENS - TOKEN_BUFFER)) ]; then
            echo -e "${YELLOW}⚠ $part_file: $tokens tokens (near limit)${NC}"
        else
            echo -e "${GREEN}✓ $part_file: $tokens tokens${NC}"
        fi
    done

    if [ "$any_issues" = true ]; then
        echo -e "\n${RED}Issues found! Run 'reprocess' to fix.${NC}"
        exit 1
    else
        echo -e "\n${GREEN}All parts are within token limits.${NC}"
    fi
}

# Join command - reconstruct original file from parts
cmd_join() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}Joining parts with prefix '$prefix'...${NC}" >&2

    for part_file in $parts; do
        extract_content "$part_file"
    done
}

# Reprocess command - handle edited parts that may have grown
cmd_reprocess() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Reprocessing parts with prefix '$prefix'..."

    # First, join all parts back together
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"

    # Get the current total parts number
    current_total=$(echo "$parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"

    # Report changes
    new_parts=$(find_part_files "$prefix")
    new_total=$(echo "$new_parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    echo ""
    if [ "$current_total" != "$new_total" ]; then
        echo -e "${YELLOW}Part count changed: $current_total → $new_total${NC}"
    else
        echo -e "${GREEN}Part count unchanged: $new_total parts${NC}"
    fi
}

# Append command - add new content to existing parts
cmd_append() {
    local prefix="$1"
    local new_content_file="$2"

    if [ ! -f "$new_content_file" ]; then
        echo -e "${RED}Error: Content file '$new_content_file' not found${NC}"
        exit 1
    fi

    local parts=$(find_part_files "$prefix")
    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Appending content to parts with prefix '$prefix'..."

    # Join existing content and append new content
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"
    cat "$new_content_file" >> "$temp_file"

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the combined file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"
}

# Create helper script for sending to Claude
create_helper_script() {
    local prefix="$1"
    local total_parts="$2"
    local helper_script="${prefix}_send_to_claude.sh"

    cat > "$helper_script" <<'HELPER'
#!/bin/bash
set -e

# Check if claude command exists
if ! command -v claude &> /dev/null; then
    echo "Error: 'claude' command not found. Please install Claude Code CLI."
    exit 1
fi

echo "Sending all parts to Claude Code CLI..."
echo "Make sure to wait for acknowledgment after each part!"
echo ""

HELPER

    for i in $(seq 1 $total_parts); do
        echo "echo \"Sending part $i/$total_parts...\"" >> "$helper_script"
        echo "claude < \"${prefix}_${i}_of_${total_parts}.txt\"" >> "$helper_script"
        if [ $i -lt $total_parts ]; then
            echo "echo \"\"" >> "$helper_script"
            echo "echo \"Waiting for acknowledgment...\"" >> "$helper_script"
            echo "echo \"Claude should respond: 'Part $i/$total_parts received'\"" >> "$helper_script"
            echo "read -p \"Press Enter after Claude acknowledges part $i: \"" >> "$helper_script"
        fi
        echo "" >> "$helper_script"
    done

    echo "echo \"All parts sent successfully!\"" >> "$helper_script"
    chmod +x "$helper_script"
}

# Main script logic
check_dependencies

if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

command="$1"
shift

case "$command" in
    split)
        [ $# -lt 1 ] && { echo "Error: Missing input file"; show_usage; exit 1; }
        cmd_split "$@"
        ;;
    check)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_check "$1"
        ;;
    join)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_join "$1"
        ;;
    reprocess)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_reprocess "$1"
        ;;
    append)
        [ $# -lt 2 ] && { echo "Error: Missing prefix or content file"; show_usage; exit 1; }
        cmd_append "$1" "$2"
        ;;
    -h|--help|help)
        show_usage
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$command'${NC}"
        show_usage
        exit 1
        ;;
esac\n'
            test_tokens=$(echo "$test_content" | tokencount)

            if [ $test_tokens -gt $((MAX_TOKENS - TOKEN_BUFFER - dummy_wrapper_tokens)) ] && [ -n "$current_part" ]; then
                temp_parts+=("$current_part")
                current_part="${line}"

    # Don't forget the last part
    if [ -n "$current_part" ]; then
        temp_parts+=("$current_part")
    fi

    echo -e "\nTotal parts needed: ${#temp_parts[@]}"

    # Create the actual files
    total_parts=${#temp_parts[@]}

    for i in "${!temp_parts[@]}"; do
        part_num=$((i + 1))
        output_file="${output_prefix}_${part_num}_of_${total_parts}.txt"

        echo "Creating part $part_num/$total_parts: $output_file"

        {
            create_prefix "$part_num" "$total_parts"
            echo ""
            echo "[START PART $part_num/$total_parts]"
            printf "%s" "${temp_parts[$i]}"
            echo "[END PART $part_num/$total_parts]"
            create_postfix "$part_num" "$total_parts"
        } > "$output_file"

        # Verify token count
        final_tokens=$(tokencount < "$output_file")
        echo "  Token count: $final_tokens"

        if [ $final_tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}  ERROR: Part $part_num exceeds $MAX_TOKENS tokens ($final_tokens)!${NC}"
            echo "  Consider using a smaller MAX_TOKENS value or splitting by paragraphs."
            exit 1
        fi
    done

    create_helper_script "$output_prefix" "$total_parts"

    echo -e "\n${GREEN}Success!${NC}"
    echo "- Split '$input_file' into $total_parts parts"
    echo "- Output files: ${output_prefix}_*_of_${total_parts}.txt"
    echo "- Helper script: ${output_prefix}_send_to_claude.sh"
}

# Check command - verify token counts of existing parts
cmd_check() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Checking parts with prefix '$prefix'..."
    echo ""

    local any_issues=false

    for part_file in $parts; do
        tokens=$(tokencount < "$part_file")

        if [ $tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}✗ $part_file: $tokens tokens (EXCEEDS LIMIT)${NC}"
            any_issues=true
        elif [ $tokens -gt $((MAX_TOKENS - TOKEN_BUFFER)) ]; then
            echo -e "${YELLOW}⚠ $part_file: $tokens tokens (near limit)${NC}"
        else
            echo -e "${GREEN}✓ $part_file: $tokens tokens${NC}"
        fi
    done

    if [ "$any_issues" = true ]; then
        echo -e "\n${RED}Issues found! Run 'reprocess' to fix.${NC}"
        exit 1
    else
        echo -e "\n${GREEN}All parts are within token limits.${NC}"
    fi
}

# Join command - reconstruct original file from parts
cmd_join() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}Joining parts with prefix '$prefix'...${NC}" >&2

    for part_file in $parts; do
        extract_content "$part_file"
    done
}

# Reprocess command - handle edited parts that may have grown
cmd_reprocess() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Reprocessing parts with prefix '$prefix'..."

    # First, join all parts back together
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"

    # Get the current total parts number
    current_total=$(echo "$parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"

    # Report changes
    new_parts=$(find_part_files "$prefix")
    new_total=$(echo "$new_parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    echo ""
    if [ "$current_total" != "$new_total" ]; then
        echo -e "${YELLOW}Part count changed: $current_total → $new_total${NC}"
    else
        echo -e "${GREEN}Part count unchanged: $new_total parts${NC}"
    fi
}

# Append command - add new content to existing parts
cmd_append() {
    local prefix="$1"
    local new_content_file="$2"

    if [ ! -f "$new_content_file" ]; then
        echo -e "${RED}Error: Content file '$new_content_file' not found${NC}"
        exit 1
    fi

    local parts=$(find_part_files "$prefix")
    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Appending content to parts with prefix '$prefix'..."

    # Join existing content and append new content
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"
    cat "$new_content_file" >> "$temp_file"

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the combined file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"
}

# Create helper script for sending to Claude
create_helper_script() {
    local prefix="$1"
    local total_parts="$2"
    local helper_script="${prefix}_send_to_claude.sh"

    cat > "$helper_script" <<'HELPER'
#!/bin/bash
set -e

# Check if claude command exists
if ! command -v claude &> /dev/null; then
    echo "Error: 'claude' command not found. Please install Claude Code CLI."
    exit 1
fi

echo "Sending all parts to Claude Code CLI..."
echo "Make sure to wait for acknowledgment after each part!"
echo ""

HELPER

    for i in $(seq 1 $total_parts); do
        echo "echo \"Sending part $i/$total_parts...\"" >> "$helper_script"
        echo "claude < \"${prefix}_${i}_of_${total_parts}.txt\"" >> "$helper_script"
        if [ $i -lt $total_parts ]; then
            echo "echo \"\"" >> "$helper_script"
            echo "echo \"Waiting for acknowledgment...\"" >> "$helper_script"
            echo "echo \"Claude should respond: 'Part $i/$total_parts received'\"" >> "$helper_script"
            echo "read -p \"Press Enter after Claude acknowledges part $i: \"" >> "$helper_script"
        fi
        echo "" >> "$helper_script"
    done

    echo "echo \"All parts sent successfully!\"" >> "$helper_script"
    chmod +x "$helper_script"
}

# Main script logic
check_dependencies

if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

command="$1"
shift

case "$command" in
    split)
        [ $# -lt 1 ] && { echo "Error: Missing input file"; show_usage; exit 1; }
        cmd_split "$@"
        ;;
    check)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_check "$1"
        ;;
    join)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_join "$1"
        ;;
    reprocess)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_reprocess "$1"
        ;;
    append)
        [ $# -lt 2 ] && { echo "Error: Missing prefix or content file"; show_usage; exit 1; }
        cmd_append "$1" "$2"
        ;;
    -h|--help|help)
        show_usage
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$command'${NC}"
        show_usage
        exit 1
        ;;
esac\n'
                current_tokens=$(echo "$current_part" | tokencount)
            else
                current_part="${test_content}"
                current_tokens=$test_tokens
            fi
        else
            current_part="${current_part}${line}"

    # Don't forget the last part
    if [ -n "$current_part" ]; then
        temp_parts+=("$current_part")
    fi

    echo -e "\nTotal parts needed: ${#temp_parts[@]}"

    # Create the actual files
    total_parts=${#temp_parts[@]}

    for i in "${!temp_parts[@]}"; do
        part_num=$((i + 1))
        output_file="${output_prefix}_${part_num}_of_${total_parts}.txt"

        echo "Creating part $part_num/$total_parts: $output_file"

        {
            create_prefix "$part_num" "$total_parts"
            echo ""
            echo "[START PART $part_num/$total_parts]"
            printf "%s" "${temp_parts[$i]}"
            echo "[END PART $part_num/$total_parts]"
            create_postfix "$part_num" "$total_parts"
        } > "$output_file"

        # Verify token count
        final_tokens=$(tokencount < "$output_file")
        echo "  Token count: $final_tokens"

        if [ $final_tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}  ERROR: Part $part_num exceeds $MAX_TOKENS tokens ($final_tokens)!${NC}"
            echo "  Consider using a smaller MAX_TOKENS value or splitting by paragraphs."
            exit 1
        fi
    done

    create_helper_script "$output_prefix" "$total_parts"

    echo -e "\n${GREEN}Success!${NC}"
    echo "- Split '$input_file' into $total_parts parts"
    echo "- Output files: ${output_prefix}_*_of_${total_parts}.txt"
    echo "- Helper script: ${output_prefix}_send_to_claude.sh"
}

# Check command - verify token counts of existing parts
cmd_check() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Checking parts with prefix '$prefix'..."
    echo ""

    local any_issues=false

    for part_file in $parts; do
        tokens=$(tokencount < "$part_file")

        if [ $tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}✗ $part_file: $tokens tokens (EXCEEDS LIMIT)${NC}"
            any_issues=true
        elif [ $tokens -gt $((MAX_TOKENS - TOKEN_BUFFER)) ]; then
            echo -e "${YELLOW}⚠ $part_file: $tokens tokens (near limit)${NC}"
        else
            echo -e "${GREEN}✓ $part_file: $tokens tokens${NC}"
        fi
    done

    if [ "$any_issues" = true ]; then
        echo -e "\n${RED}Issues found! Run 'reprocess' to fix.${NC}"
        exit 1
    else
        echo -e "\n${GREEN}All parts are within token limits.${NC}"
    fi
}

# Join command - reconstruct original file from parts
cmd_join() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}Joining parts with prefix '$prefix'...${NC}" >&2

    for part_file in $parts; do
        extract_content "$part_file"
    done
}

# Reprocess command - handle edited parts that may have grown
cmd_reprocess() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Reprocessing parts with prefix '$prefix'..."

    # First, join all parts back together
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"

    # Get the current total parts number
    current_total=$(echo "$parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"

    # Report changes
    new_parts=$(find_part_files "$prefix")
    new_total=$(echo "$new_parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    echo ""
    if [ "$current_total" != "$new_total" ]; then
        echo -e "${YELLOW}Part count changed: $current_total → $new_total${NC}"
    else
        echo -e "${GREEN}Part count unchanged: $new_total parts${NC}"
    fi
}

# Append command - add new content to existing parts
cmd_append() {
    local prefix="$1"
    local new_content_file="$2"

    if [ ! -f "$new_content_file" ]; then
        echo -e "${RED}Error: Content file '$new_content_file' not found${NC}"
        exit 1
    fi

    local parts=$(find_part_files "$prefix")
    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Appending content to parts with prefix '$prefix'..."

    # Join existing content and append new content
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"
    cat "$new_content_file" >> "$temp_file"

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the combined file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"
}

# Create helper script for sending to Claude
create_helper_script() {
    local prefix="$1"
    local total_parts="$2"
    local helper_script="${prefix}_send_to_claude.sh"

    cat > "$helper_script" <<'HELPER'
#!/bin/bash
set -e

# Check if claude command exists
if ! command -v claude &> /dev/null; then
    echo "Error: 'claude' command not found. Please install Claude Code CLI."
    exit 1
fi

echo "Sending all parts to Claude Code CLI..."
echo "Make sure to wait for acknowledgment after each part!"
echo ""

HELPER

    for i in $(seq 1 $total_parts); do
        echo "echo \"Sending part $i/$total_parts...\"" >> "$helper_script"
        echo "claude < \"${prefix}_${i}_of_${total_parts}.txt\"" >> "$helper_script"
        if [ $i -lt $total_parts ]; then
            echo "echo \"\"" >> "$helper_script"
            echo "echo \"Waiting for acknowledgment...\"" >> "$helper_script"
            echo "echo \"Claude should respond: 'Part $i/$total_parts received'\"" >> "$helper_script"
            echo "read -p \"Press Enter after Claude acknowledges part $i: \"" >> "$helper_script"
        fi
        echo "" >> "$helper_script"
    done

    echo "echo \"All parts sent successfully!\"" >> "$helper_script"
    chmod +x "$helper_script"
}

# Main script logic
check_dependencies

if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

command="$1"
shift

case "$command" in
    split)
        [ $# -lt 1 ] && { echo "Error: Missing input file"; show_usage; exit 1; }
        cmd_split "$@"
        ;;
    check)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_check "$1"
        ;;
    join)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_join "$1"
        ;;
    reprocess)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_reprocess "$1"
        ;;
    append)
        [ $# -lt 2 ] && { echo "Error: Missing prefix or content file"; show_usage; exit 1; }
        cmd_append "$1" "$2"
        ;;
    -h|--help|help)
        show_usage
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$command'${NC}"
        show_usage
        exit 1
        ;;
esac\n'
        fi

        # Progress indicator
        if [ $((line_count % 100)) -eq 0 ]; then
            printf "\rProcessed %d/%d lines (%.1f%%)..." "$line_count" "$total_lines" \
                "$(echo "scale=1; $line_count * 100 / $total_lines" | bc)"
        fi
    done < "$input_file"

    # Don't forget the last part
    if [ -n "$current_part" ]; then
        temp_parts+=("$current_part")
    fi

    echo -e "\nTotal parts needed: ${#temp_parts[@]}"

    # Create the actual files
    total_parts=${#temp_parts[@]}

    for i in "${!temp_parts[@]}"; do
        part_num=$((i + 1))
        output_file="${output_prefix}_${part_num}_of_${total_parts}.txt"

        echo "Creating part $part_num/$total_parts: $output_file"

        {
            create_prefix "$part_num" "$total_parts"
            echo ""
            echo "[START PART $part_num/$total_parts]"
            printf "%s" "${temp_parts[$i]}"
            echo "[END PART $part_num/$total_parts]"
            create_postfix "$part_num" "$total_parts"
        } > "$output_file"

        # Verify token count
        final_tokens=$(tokencount < "$output_file")
        echo "  Token count: $final_tokens"

        if [ $final_tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}  ERROR: Part $part_num exceeds $MAX_TOKENS tokens ($final_tokens)!${NC}"
            echo "  Consider using a smaller MAX_TOKENS value or splitting by paragraphs."
            exit 1
        fi
    done

    create_helper_script "$output_prefix" "$total_parts"

    echo -e "\n${GREEN}Success!${NC}"
    echo "- Split '$input_file' into $total_parts parts"
    echo "- Output files: ${output_prefix}_*_of_${total_parts}.txt"
    echo "- Helper script: ${output_prefix}_send_to_claude.sh"
}

# Check command - verify token counts of existing parts
cmd_check() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Checking parts with prefix '$prefix'..."
    echo ""

    local any_issues=false

    for part_file in $parts; do
        tokens=$(tokencount < "$part_file")

        if [ $tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}✗ $part_file: $tokens tokens (EXCEEDS LIMIT)${NC}"
            any_issues=true
        elif [ $tokens -gt $((MAX_TOKENS - TOKEN_BUFFER)) ]; then
            echo -e "${YELLOW}⚠ $part_file: $tokens tokens (near limit)${NC}"
        else
            echo -e "${GREEN}✓ $part_file: $tokens tokens${NC}"
        fi
    done

    if [ "$any_issues" = true ]; then
        echo -e "\n${RED}Issues found! Run 'reprocess' to fix.${NC}"
        exit 1
    else
        echo -e "\n${GREEN}All parts are within token limits.${NC}"
    fi
}

# Join command - reconstruct original file from parts
cmd_join() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}Joining parts with prefix '$prefix'...${NC}" >&2

    for part_file in $parts; do
        extract_content "$part_file"
    done
}

# Reprocess command - handle edited parts that may have grown
cmd_reprocess() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Reprocessing parts with prefix '$prefix'..."

    # First, join all parts back together
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"

    # Get the current total parts number
    current_total=$(echo "$parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"

    # Report changes
    new_parts=$(find_part_files "$prefix")
    new_total=$(echo "$new_parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    echo ""
    if [ "$current_total" != "$new_total" ]; then
        echo -e "${YELLOW}Part count changed: $current_total → $new_total${NC}"
    else
        echo -e "${GREEN}Part count unchanged: $new_total parts${NC}"
    fi
}

# Append command - add new content to existing parts
cmd_append() {
    local prefix="$1"
    local new_content_file="$2"

    if [ ! -f "$new_content_file" ]; then
        echo -e "${RED}Error: Content file '$new_content_file' not found${NC}"
        exit 1
    fi

    local parts=$(find_part_files "$prefix")
    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Appending content to parts with prefix '$prefix'..."

    # Join existing content and append new content
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"
    cat "$new_content_file" >> "$temp_file"

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the combined file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"
}

# Create helper script for sending to Claude
create_helper_script() {
    local prefix="$1"
    local total_parts="$2"
    local helper_script="${prefix}_send_to_claude.sh"

    cat > "$helper_script" <<'HELPER'
#!/bin/bash
set -e

# Check if claude command exists
if ! command -v claude &> /dev/null; then
    echo "Error: 'claude' command not found. Please install Claude Code CLI."
    exit 1
fi

echo "Sending all parts to Claude Code CLI..."
echo "Make sure to wait for acknowledgment after each part!"
echo ""

HELPER

    for i in $(seq 1 $total_parts); do
        echo "echo \"Sending part $i/$total_parts...\"" >> "$helper_script"
        echo "claude < \"${prefix}_${i}_of_${total_parts}.txt\"" >> "$helper_script"
        if [ $i -lt $total_parts ]; then
            echo "echo \"\"" >> "$helper_script"
            echo "echo \"Waiting for acknowledgment...\"" >> "$helper_script"
            echo "echo \"Claude should respond: 'Part $i/$total_parts received'\"" >> "$helper_script"
            echo "read -p \"Press Enter after Claude acknowledges part $i: \"" >> "$helper_script"
        fi
        echo "" >> "$helper_script"
    done

    echo "echo \"All parts sent successfully!\"" >> "$helper_script"
    chmod +x "$helper_script"
}

# Main script logic
check_dependencies

if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

command="$1"
shift

case "$command" in
    split)
        [ $# -lt 1 ] && { echo "Error: Missing input file"; show_usage; exit 1; }
        cmd_split "$@"
        ;;
    check)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_check "$1"
        ;;
    join)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_join "$1"
        ;;
    reprocess)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_reprocess "$1"
        ;;
    append)
        [ $# -lt 2 ] && { echo "Error: Missing prefix or content file"; show_usage; exit 1; }
        cmd_append "$1" "$2"
        ;;
    -h|--help|help)
        show_usage
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$command'${NC}"
        show_usage
        exit 1
        ;;
esac\n'"${postfix}"
    echo "$wrapper" | "$TOKENCOUNT_CMD"
}

# Function to extract content from a part file
extract_content() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo -e "${RED}Error: Part file '$file' not found${NC}" >&2
        return 1
    fi
    # Extract content between START PART and END PART markers
    sed -n '/\[START PART [0-9]*\/[0-9]*\]/,/\[END PART [0-9]*\/[0-9]*\]/{
        /\[START PART [0-9]*\/[0-9]*\]/d
        /\[END PART [0-9]*\/[0-9]*\]/d
        p
    }' "$file"
}

# Function to find all part files for a prefix
find_part_files() {
    local prefix="$1"
    # Use a more specific pattern to avoid matching backup directories
    ls "${prefix}"_[0-9]*_of_[0-9]*.txt 2>/dev/null | sort -V
}

# Split command
cmd_split() {
    local input_file="$1"
    local output_prefix="${2:-$(basename "$input_file" | sed 's/\.[^.]*$//')_part}"

    if [ ! -f "$input_file" ]; then
        echo -e "${RED}Error: Input file '$input_file' not found${NC}"
        exit 1
    fi

    # Check for existing parts
    existing_parts=$(find_part_files "$output_prefix")
    if [ -n "$existing_parts" ]; then
        echo -e "${YELLOW}Warning: Found existing parts with prefix '$output_prefix'${NC}"
        read -p "Overwrite existing parts? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 1
        fi
        rm -f $existing_parts
    fi

    split_file "$input_file" "$output_prefix"
}

# Main splitting logic
split_file() {
    local input_file="$1"
    local output_prefix="$2"

    # Count total lines for progress
    echo "Counting total lines..."
    total_lines=$(wc -l < "$input_file")
    echo "Total lines: $total_lines"

    # Estimate wrapper overhead
    dummy_wrapper_tokens=$(estimate_wrapper_tokens 99 99)
    echo "Estimated wrapper overhead: ~$dummy_wrapper_tokens tokens"

    temp_parts=()
    current_part=""
    current_tokens=0
    line_count=0

    # Read file line by line
    while IFS= read -r line || [ -n "$line" ]; do
        line_count=$((line_count + 1))

        # Handle empty lines properly
        if [ -z "$line" ]; then
            current_part="${current_part}"

    # Don't forget the last part
    if [ -n "$current_part" ]; then
        temp_parts+=("$current_part")
    fi

    echo -e "\nTotal parts needed: ${#temp_parts[@]}"

    # Create the actual files
    total_parts=${#temp_parts[@]}

    for i in "${!temp_parts[@]}"; do
        part_num=$((i + 1))
        output_file="${output_prefix}_${part_num}_of_${total_parts}.txt"

        echo "Creating part $part_num/$total_parts: $output_file"

        {
            create_prefix "$part_num" "$total_parts"
            echo ""
            echo "[START PART $part_num/$total_parts]"
            printf "%s" "${temp_parts[$i]}"
            echo "[END PART $part_num/$total_parts]"
            create_postfix "$part_num" "$total_parts"
        } > "$output_file"

        # Verify token count
        final_tokens=$(tokencount < "$output_file")
        echo "  Token count: $final_tokens"

        if [ $final_tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}  ERROR: Part $part_num exceeds $MAX_TOKENS tokens ($final_tokens)!${NC}"
            echo "  Consider using a smaller MAX_TOKENS value or splitting by paragraphs."
            exit 1
        fi
    done

    create_helper_script "$output_prefix" "$total_parts"

    echo -e "\n${GREEN}Success!${NC}"
    echo "- Split '$input_file' into $total_parts parts"
    echo "- Output files: ${output_prefix}_*_of_${total_parts}.txt"
    echo "- Helper script: ${output_prefix}_send_to_claude.sh"
}

# Check command - verify token counts of existing parts
cmd_check() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Checking parts with prefix '$prefix'..."
    echo ""

    local any_issues=false

    for part_file in $parts; do
        tokens=$(tokencount < "$part_file")

        if [ $tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}✗ $part_file: $tokens tokens (EXCEEDS LIMIT)${NC}"
            any_issues=true
        elif [ $tokens -gt $((MAX_TOKENS - TOKEN_BUFFER)) ]; then
            echo -e "${YELLOW}⚠ $part_file: $tokens tokens (near limit)${NC}"
        else
            echo -e "${GREEN}✓ $part_file: $tokens tokens${NC}"
        fi
    done

    if [ "$any_issues" = true ]; then
        echo -e "\n${RED}Issues found! Run 'reprocess' to fix.${NC}"
        exit 1
    else
        echo -e "\n${GREEN}All parts are within token limits.${NC}"
    fi
}

# Join command - reconstruct original file from parts
cmd_join() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}Joining parts with prefix '$prefix'...${NC}" >&2

    for part_file in $parts; do
        extract_content "$part_file"
    done
}

# Reprocess command - handle edited parts that may have grown
cmd_reprocess() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Reprocessing parts with prefix '$prefix'..."

    # First, join all parts back together
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"

    # Get the current total parts number
    current_total=$(echo "$parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt$/\2/p')

    if [ -z "$current_total" ]; then
        echo -e "${RED}Error: Could not determine total parts from existing files${NC}"
        exit 1
    fi

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"

    # Report changes
    new_parts=$(find_part_files "$prefix")
    new_total=$(echo "$new_parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    echo ""
    if [ "$current_total" != "$new_total" ]; then
        echo -e "${YELLOW}Part count changed: $current_total → $new_total${NC}"
    else
        echo -e "${GREEN}Part count unchanged: $new_total parts${NC}"
    fi
}

# Append command - add new content to existing parts
cmd_append() {
    local prefix="$1"
    local new_content_file="$2"

    if [ ! -f "$new_content_file" ]; then
        echo -e "${RED}Error: Content file '$new_content_file' not found${NC}"
        exit 1
    fi

    local parts=$(find_part_files "$prefix")
    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Appending content to parts with prefix '$prefix'..."

    # Join existing content and append new content
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"
    cat "$new_content_file" >> "$temp_file"

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the combined file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"
}

# Create helper script for sending to Claude
create_helper_script() {
    local prefix="$1"
    local total_parts="$2"
    local helper_script="${prefix}_send_to_claude.sh"

    cat > "$helper_script" <<'HELPER'
#!/bin/bash
set -e

# Check if claude command exists
if ! command -v claude &> /dev/null; then
    echo "Error: 'claude' command not found. Please install Claude Code CLI."
    exit 1
fi

echo "Sending all parts to Claude Code CLI..."
echo "Make sure to wait for acknowledgment after each part!"
echo ""

HELPER

    for i in $(seq 1 $total_parts); do
        echo "echo \"Sending part $i/$total_parts...\"" >> "$helper_script"
        echo "claude < \"${prefix}_${i}_of_${total_parts}.txt\"" >> "$helper_script"
        if [ $i -lt $total_parts ]; then
            echo "echo \"\"" >> "$helper_script"
            echo "echo \"Waiting for acknowledgment...\"" >> "$helper_script"
            echo "echo \"Claude should respond: 'Part $i/$total_parts received'\"" >> "$helper_script"
            echo "read -p \"Press Enter after Claude acknowledges part $i: \"" >> "$helper_script"
        fi
        echo "" >> "$helper_script"
    done

    echo "echo \"All parts sent successfully!\"" >> "$helper_script"
    chmod +x "$helper_script"
}

# Summary command - show overview of parts
cmd_summary() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Summary of parts with prefix '$prefix':"
    echo ""

    for part_file in $parts; do
        tokens=$(tokencount < "$part_file")
        content=$(extract_content "$part_file")
        lines=$(echo "$content" | wc -l)
        first_line=$(echo "$content" | head -1 | cut -c1-60)
        last_line=$(echo "$content" | tail -1 | cut -c1-60)

        echo -e "${GREEN}$part_file${NC}"
        echo "  Tokens: $tokens"
        echo "  Lines: $lines"
        echo "  First: $first_line..."
        echo "  Last:  $last_line..."
        echo ""
    done
}

# Main script logic
check_dependencies

if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

command="$1"
shift

case "$command" in
    split)
        [ $# -lt 1 ] && { echo "Error: Missing input file"; show_usage; exit 1; }
        cmd_split "$@"
        ;;
    check)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_check "$1"
        ;;
    join)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_join "$1"
        ;;
    reprocess)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_reprocess "$1"
        ;;
    append)
        [ $# -lt 2 ] && { echo "Error: Missing prefix or content file"; show_usage; exit 1; }
        cmd_append "$1" "$2"
        ;;
    summary)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_summary "$1"
        ;;
    -h|--help|help)
        show_usage
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$command'${NC}"
        show_usage
        exit 1
        ;;
esac\n'
            continue
        fi

        # Check tokens periodically or when approaching limit
        if [ $line_count -eq 1 ] || [ $((line_count % 10)) -eq 0 ] || [ $current_tokens -gt $((MAX_TOKENS - TOKEN_BUFFER - dummy_wrapper_tokens - 5000)) ]; then
            test_content="${current_part}${line}"

    # Don't forget the last part
    if [ -n "$current_part" ]; then
        temp_parts+=("$current_part")
    fi

    echo -e "\nTotal parts needed: ${#temp_parts[@]}"

    # Create the actual files
    total_parts=${#temp_parts[@]}

    for i in "${!temp_parts[@]}"; do
        part_num=$((i + 1))
        output_file="${output_prefix}_${part_num}_of_${total_parts}.txt"

        echo "Creating part $part_num/$total_parts: $output_file"

        {
            create_prefix "$part_num" "$total_parts"
            echo ""
            echo "[START PART $part_num/$total_parts]"
            printf "%s" "${temp_parts[$i]}"
            echo "[END PART $part_num/$total_parts]"
            create_postfix "$part_num" "$total_parts"
        } > "$output_file"

        # Verify token count
        final_tokens=$(tokencount < "$output_file")
        echo "  Token count: $final_tokens"

        if [ $final_tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}  ERROR: Part $part_num exceeds $MAX_TOKENS tokens ($final_tokens)!${NC}"
            echo "  Consider using a smaller MAX_TOKENS value or splitting by paragraphs."
            exit 1
        fi
    done

    create_helper_script "$output_prefix" "$total_parts"

    echo -e "\n${GREEN}Success!${NC}"
    echo "- Split '$input_file' into $total_parts parts"
    echo "- Output files: ${output_prefix}_*_of_${total_parts}.txt"
    echo "- Helper script: ${output_prefix}_send_to_claude.sh"
}

# Check command - verify token counts of existing parts
cmd_check() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Checking parts with prefix '$prefix'..."
    echo ""

    local any_issues=false

    for part_file in $parts; do
        tokens=$(tokencount < "$part_file")

        if [ $tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}✗ $part_file: $tokens tokens (EXCEEDS LIMIT)${NC}"
            any_issues=true
        elif [ $tokens -gt $((MAX_TOKENS - TOKEN_BUFFER)) ]; then
            echo -e "${YELLOW}⚠ $part_file: $tokens tokens (near limit)${NC}"
        else
            echo -e "${GREEN}✓ $part_file: $tokens tokens${NC}"
        fi
    done

    if [ "$any_issues" = true ]; then
        echo -e "\n${RED}Issues found! Run 'reprocess' to fix.${NC}"
        exit 1
    else
        echo -e "\n${GREEN}All parts are within token limits.${NC}"
    fi
}

# Join command - reconstruct original file from parts
cmd_join() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}Joining parts with prefix '$prefix'...${NC}" >&2

    for part_file in $parts; do
        extract_content "$part_file"
    done
}

# Reprocess command - handle edited parts that may have grown
cmd_reprocess() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Reprocessing parts with prefix '$prefix'..."

    # First, join all parts back together
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"

    # Get the current total parts number
    current_total=$(echo "$parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"

    # Report changes
    new_parts=$(find_part_files "$prefix")
    new_total=$(echo "$new_parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    echo ""
    if [ "$current_total" != "$new_total" ]; then
        echo -e "${YELLOW}Part count changed: $current_total → $new_total${NC}"
    else
        echo -e "${GREEN}Part count unchanged: $new_total parts${NC}"
    fi
}

# Append command - add new content to existing parts
cmd_append() {
    local prefix="$1"
    local new_content_file="$2"

    if [ ! -f "$new_content_file" ]; then
        echo -e "${RED}Error: Content file '$new_content_file' not found${NC}"
        exit 1
    fi

    local parts=$(find_part_files "$prefix")
    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Appending content to parts with prefix '$prefix'..."

    # Join existing content and append new content
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"
    cat "$new_content_file" >> "$temp_file"

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the combined file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"
}

# Create helper script for sending to Claude
create_helper_script() {
    local prefix="$1"
    local total_parts="$2"
    local helper_script="${prefix}_send_to_claude.sh"

    cat > "$helper_script" <<'HELPER'
#!/bin/bash
set -e

# Check if claude command exists
if ! command -v claude &> /dev/null; then
    echo "Error: 'claude' command not found. Please install Claude Code CLI."
    exit 1
fi

echo "Sending all parts to Claude Code CLI..."
echo "Make sure to wait for acknowledgment after each part!"
echo ""

HELPER

    for i in $(seq 1 $total_parts); do
        echo "echo \"Sending part $i/$total_parts...\"" >> "$helper_script"
        echo "claude < \"${prefix}_${i}_of_${total_parts}.txt\"" >> "$helper_script"
        if [ $i -lt $total_parts ]; then
            echo "echo \"\"" >> "$helper_script"
            echo "echo \"Waiting for acknowledgment...\"" >> "$helper_script"
            echo "echo \"Claude should respond: 'Part $i/$total_parts received'\"" >> "$helper_script"
            echo "read -p \"Press Enter after Claude acknowledges part $i: \"" >> "$helper_script"
        fi
        echo "" >> "$helper_script"
    done

    echo "echo \"All parts sent successfully!\"" >> "$helper_script"
    chmod +x "$helper_script"
}

# Main script logic
check_dependencies

if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

command="$1"
shift

case "$command" in
    split)
        [ $# -lt 1 ] && { echo "Error: Missing input file"; show_usage; exit 1; }
        cmd_split "$@"
        ;;
    check)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_check "$1"
        ;;
    join)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_join "$1"
        ;;
    reprocess)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_reprocess "$1"
        ;;
    append)
        [ $# -lt 2 ] && { echo "Error: Missing prefix or content file"; show_usage; exit 1; }
        cmd_append "$1" "$2"
        ;;
    -h|--help|help)
        show_usage
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$command'${NC}"
        show_usage
        exit 1
        ;;
esac\n'
            test_tokens=$(echo "$test_content" | tokencount)

            if [ $test_tokens -gt $((MAX_TOKENS - TOKEN_BUFFER - dummy_wrapper_tokens)) ] && [ -n "$current_part" ]; then
                temp_parts+=("$current_part")
                current_part="${line}"

    # Don't forget the last part
    if [ -n "$current_part" ]; then
        temp_parts+=("$current_part")
    fi

    echo -e "\nTotal parts needed: ${#temp_parts[@]}"

    # Create the actual files
    total_parts=${#temp_parts[@]}

    for i in "${!temp_parts[@]}"; do
        part_num=$((i + 1))
        output_file="${output_prefix}_${part_num}_of_${total_parts}.txt"

        echo "Creating part $part_num/$total_parts: $output_file"

        {
            create_prefix "$part_num" "$total_parts"
            echo ""
            echo "[START PART $part_num/$total_parts]"
            printf "%s" "${temp_parts[$i]}"
            echo "[END PART $part_num/$total_parts]"
            create_postfix "$part_num" "$total_parts"
        } > "$output_file"

        # Verify token count
        final_tokens=$(tokencount < "$output_file")
        echo "  Token count: $final_tokens"

        if [ $final_tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}  ERROR: Part $part_num exceeds $MAX_TOKENS tokens ($final_tokens)!${NC}"
            echo "  Consider using a smaller MAX_TOKENS value or splitting by paragraphs."
            exit 1
        fi
    done

    create_helper_script "$output_prefix" "$total_parts"

    echo -e "\n${GREEN}Success!${NC}"
    echo "- Split '$input_file' into $total_parts parts"
    echo "- Output files: ${output_prefix}_*_of_${total_parts}.txt"
    echo "- Helper script: ${output_prefix}_send_to_claude.sh"
}

# Check command - verify token counts of existing parts
cmd_check() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Checking parts with prefix '$prefix'..."
    echo ""

    local any_issues=false

    for part_file in $parts; do
        tokens=$(tokencount < "$part_file")

        if [ $tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}✗ $part_file: $tokens tokens (EXCEEDS LIMIT)${NC}"
            any_issues=true
        elif [ $tokens -gt $((MAX_TOKENS - TOKEN_BUFFER)) ]; then
            echo -e "${YELLOW}⚠ $part_file: $tokens tokens (near limit)${NC}"
        else
            echo -e "${GREEN}✓ $part_file: $tokens tokens${NC}"
        fi
    done

    if [ "$any_issues" = true ]; then
        echo -e "\n${RED}Issues found! Run 'reprocess' to fix.${NC}"
        exit 1
    else
        echo -e "\n${GREEN}All parts are within token limits.${NC}"
    fi
}

# Join command - reconstruct original file from parts
cmd_join() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}Joining parts with prefix '$prefix'...${NC}" >&2

    for part_file in $parts; do
        extract_content "$part_file"
    done
}

# Reprocess command - handle edited parts that may have grown
cmd_reprocess() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Reprocessing parts with prefix '$prefix'..."

    # First, join all parts back together
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"

    # Get the current total parts number
    current_total=$(echo "$parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"

    # Report changes
    new_parts=$(find_part_files "$prefix")
    new_total=$(echo "$new_parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    echo ""
    if [ "$current_total" != "$new_total" ]; then
        echo -e "${YELLOW}Part count changed: $current_total → $new_total${NC}"
    else
        echo -e "${GREEN}Part count unchanged: $new_total parts${NC}"
    fi
}

# Append command - add new content to existing parts
cmd_append() {
    local prefix="$1"
    local new_content_file="$2"

    if [ ! -f "$new_content_file" ]; then
        echo -e "${RED}Error: Content file '$new_content_file' not found${NC}"
        exit 1
    fi

    local parts=$(find_part_files "$prefix")
    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Appending content to parts with prefix '$prefix'..."

    # Join existing content and append new content
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"
    cat "$new_content_file" >> "$temp_file"

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the combined file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"
}

# Create helper script for sending to Claude
create_helper_script() {
    local prefix="$1"
    local total_parts="$2"
    local helper_script="${prefix}_send_to_claude.sh"

    cat > "$helper_script" <<'HELPER'
#!/bin/bash
set -e

# Check if claude command exists
if ! command -v claude &> /dev/null; then
    echo "Error: 'claude' command not found. Please install Claude Code CLI."
    exit 1
fi

echo "Sending all parts to Claude Code CLI..."
echo "Make sure to wait for acknowledgment after each part!"
echo ""

HELPER

    for i in $(seq 1 $total_parts); do
        echo "echo \"Sending part $i/$total_parts...\"" >> "$helper_script"
        echo "claude < \"${prefix}_${i}_of_${total_parts}.txt\"" >> "$helper_script"
        if [ $i -lt $total_parts ]; then
            echo "echo \"\"" >> "$helper_script"
            echo "echo \"Waiting for acknowledgment...\"" >> "$helper_script"
            echo "echo \"Claude should respond: 'Part $i/$total_parts received'\"" >> "$helper_script"
            echo "read -p \"Press Enter after Claude acknowledges part $i: \"" >> "$helper_script"
        fi
        echo "" >> "$helper_script"
    done

    echo "echo \"All parts sent successfully!\"" >> "$helper_script"
    chmod +x "$helper_script"
}

# Main script logic
check_dependencies

if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

command="$1"
shift

case "$command" in
    split)
        [ $# -lt 1 ] && { echo "Error: Missing input file"; show_usage; exit 1; }
        cmd_split "$@"
        ;;
    check)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_check "$1"
        ;;
    join)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_join "$1"
        ;;
    reprocess)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_reprocess "$1"
        ;;
    append)
        [ $# -lt 2 ] && { echo "Error: Missing prefix or content file"; show_usage; exit 1; }
        cmd_append "$1" "$2"
        ;;
    -h|--help|help)
        show_usage
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$command'${NC}"
        show_usage
        exit 1
        ;;
esac\n'
                current_tokens=$(echo "$current_part" | tokencount)
            else
                current_part="${test_content}"
                current_tokens=$test_tokens
            fi
        else
            current_part="${current_part}${line}"

    # Don't forget the last part
    if [ -n "$current_part" ]; then
        temp_parts+=("$current_part")
    fi

    echo -e "\nTotal parts needed: ${#temp_parts[@]}"

    # Create the actual files
    total_parts=${#temp_parts[@]}

    for i in "${!temp_parts[@]}"; do
        part_num=$((i + 1))
        output_file="${output_prefix}_${part_num}_of_${total_parts}.txt"

        echo "Creating part $part_num/$total_parts: $output_file"

        {
            create_prefix "$part_num" "$total_parts"
            echo ""
            echo "[START PART $part_num/$total_parts]"
            printf "%s" "${temp_parts[$i]}"
            echo "[END PART $part_num/$total_parts]"
            create_postfix "$part_num" "$total_parts"
        } > "$output_file"

        # Verify token count
        final_tokens=$(tokencount < "$output_file")
        echo "  Token count: $final_tokens"

        if [ $final_tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}  ERROR: Part $part_num exceeds $MAX_TOKENS tokens ($final_tokens)!${NC}"
            echo "  Consider using a smaller MAX_TOKENS value or splitting by paragraphs."
            exit 1
        fi
    done

    create_helper_script "$output_prefix" "$total_parts"

    echo -e "\n${GREEN}Success!${NC}"
    echo "- Split '$input_file' into $total_parts parts"
    echo "- Output files: ${output_prefix}_*_of_${total_parts}.txt"
    echo "- Helper script: ${output_prefix}_send_to_claude.sh"
}

# Check command - verify token counts of existing parts
cmd_check() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Checking parts with prefix '$prefix'..."
    echo ""

    local any_issues=false

    for part_file in $parts; do
        tokens=$(tokencount < "$part_file")

        if [ $tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}✗ $part_file: $tokens tokens (EXCEEDS LIMIT)${NC}"
            any_issues=true
        elif [ $tokens -gt $((MAX_TOKENS - TOKEN_BUFFER)) ]; then
            echo -e "${YELLOW}⚠ $part_file: $tokens tokens (near limit)${NC}"
        else
            echo -e "${GREEN}✓ $part_file: $tokens tokens${NC}"
        fi
    done

    if [ "$any_issues" = true ]; then
        echo -e "\n${RED}Issues found! Run 'reprocess' to fix.${NC}"
        exit 1
    else
        echo -e "\n${GREEN}All parts are within token limits.${NC}"
    fi
}

# Join command - reconstruct original file from parts
cmd_join() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}Joining parts with prefix '$prefix'...${NC}" >&2

    for part_file in $parts; do
        extract_content "$part_file"
    done
}

# Reprocess command - handle edited parts that may have grown
cmd_reprocess() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Reprocessing parts with prefix '$prefix'..."

    # First, join all parts back together
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"

    # Get the current total parts number
    current_total=$(echo "$parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"

    # Report changes
    new_parts=$(find_part_files "$prefix")
    new_total=$(echo "$new_parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    echo ""
    if [ "$current_total" != "$new_total" ]; then
        echo -e "${YELLOW}Part count changed: $current_total → $new_total${NC}"
    else
        echo -e "${GREEN}Part count unchanged: $new_total parts${NC}"
    fi
}

# Append command - add new content to existing parts
cmd_append() {
    local prefix="$1"
    local new_content_file="$2"

    if [ ! -f "$new_content_file" ]; then
        echo -e "${RED}Error: Content file '$new_content_file' not found${NC}"
        exit 1
    fi

    local parts=$(find_part_files "$prefix")
    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Appending content to parts with prefix '$prefix'..."

    # Join existing content and append new content
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"
    cat "$new_content_file" >> "$temp_file"

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the combined file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"
}

# Create helper script for sending to Claude
create_helper_script() {
    local prefix="$1"
    local total_parts="$2"
    local helper_script="${prefix}_send_to_claude.sh"

    cat > "$helper_script" <<'HELPER'
#!/bin/bash
set -e

# Check if claude command exists
if ! command -v claude &> /dev/null; then
    echo "Error: 'claude' command not found. Please install Claude Code CLI."
    exit 1
fi

echo "Sending all parts to Claude Code CLI..."
echo "Make sure to wait for acknowledgment after each part!"
echo ""

HELPER

    for i in $(seq 1 $total_parts); do
        echo "echo \"Sending part $i/$total_parts...\"" >> "$helper_script"
        echo "claude < \"${prefix}_${i}_of_${total_parts}.txt\"" >> "$helper_script"
        if [ $i -lt $total_parts ]; then
            echo "echo \"\"" >> "$helper_script"
            echo "echo \"Waiting for acknowledgment...\"" >> "$helper_script"
            echo "echo \"Claude should respond: 'Part $i/$total_parts received'\"" >> "$helper_script"
            echo "read -p \"Press Enter after Claude acknowledges part $i: \"" >> "$helper_script"
        fi
        echo "" >> "$helper_script"
    done

    echo "echo \"All parts sent successfully!\"" >> "$helper_script"
    chmod +x "$helper_script"
}

# Main script logic
check_dependencies

if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

command="$1"
shift

case "$command" in
    split)
        [ $# -lt 1 ] && { echo "Error: Missing input file"; show_usage; exit 1; }
        cmd_split "$@"
        ;;
    check)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_check "$1"
        ;;
    join)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_join "$1"
        ;;
    reprocess)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_reprocess "$1"
        ;;
    append)
        [ $# -lt 2 ] && { echo "Error: Missing prefix or content file"; show_usage; exit 1; }
        cmd_append "$1" "$2"
        ;;
    -h|--help|help)
        show_usage
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$command'${NC}"
        show_usage
        exit 1
        ;;
esac\n'
        fi

        # Progress indicator
        if [ $((line_count % 100)) -eq 0 ]; then
            printf "\rProcessed %d/%d lines (%.1f%%)..." "$line_count" "$total_lines" \
                "$(echo "scale=1; $line_count * 100 / $total_lines" | bc)"
        fi
    done < "$input_file"

    # Don't forget the last part
    if [ -n "$current_part" ]; then
        temp_parts+=("$current_part")
    fi

    echo -e "\nTotal parts needed: ${#temp_parts[@]}"

    # Create the actual files
    total_parts=${#temp_parts[@]}

    for i in "${!temp_parts[@]}"; do
        part_num=$((i + 1))
        output_file="${output_prefix}_${part_num}_of_${total_parts}.txt"

        echo "Creating part $part_num/$total_parts: $output_file"

        {
            create_prefix "$part_num" "$total_parts"
            echo ""
            echo "[START PART $part_num/$total_parts]"
            printf "%s" "${temp_parts[$i]}"
            echo "[END PART $part_num/$total_parts]"
            create_postfix "$part_num" "$total_parts"
        } > "$output_file"

        # Verify token count
        final_tokens=$(tokencount < "$output_file")
        echo "  Token count: $final_tokens"

        if [ $final_tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}  ERROR: Part $part_num exceeds $MAX_TOKENS tokens ($final_tokens)!${NC}"
            echo "  Consider using a smaller MAX_TOKENS value or splitting by paragraphs."
            exit 1
        fi
    done

    create_helper_script "$output_prefix" "$total_parts"

    echo -e "\n${GREEN}Success!${NC}"
    echo "- Split '$input_file' into $total_parts parts"
    echo "- Output files: ${output_prefix}_*_of_${total_parts}.txt"
    echo "- Helper script: ${output_prefix}_send_to_claude.sh"
}

# Check command - verify token counts of existing parts
cmd_check() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Checking parts with prefix '$prefix'..."
    echo ""

    local any_issues=false

    for part_file in $parts; do
        tokens=$(tokencount < "$part_file")

        if [ $tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}✗ $part_file: $tokens tokens (EXCEEDS LIMIT)${NC}"
            any_issues=true
        elif [ $tokens -gt $((MAX_TOKENS - TOKEN_BUFFER)) ]; then
            echo -e "${YELLOW}⚠ $part_file: $tokens tokens (near limit)${NC}"
        else
            echo -e "${GREEN}✓ $part_file: $tokens tokens${NC}"
        fi
    done

    if [ "$any_issues" = true ]; then
        echo -e "\n${RED}Issues found! Run 'reprocess' to fix.${NC}"
        exit 1
    else
        echo -e "\n${GREEN}All parts are within token limits.${NC}"
    fi
}

# Join command - reconstruct original file from parts
cmd_join() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}Joining parts with prefix '$prefix'...${NC}" >&2

    for part_file in $parts; do
        extract_content "$part_file"
    done
}

# Reprocess command - handle edited parts that may have grown
cmd_reprocess() {
    local prefix="$1"
    local parts=$(find_part_files "$prefix")

    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Reprocessing parts with prefix '$prefix'..."

    # First, join all parts back together
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"

    # Get the current total parts number
    current_total=$(echo "$parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"

    # Report changes
    new_parts=$(find_part_files "$prefix")
    new_total=$(echo "$new_parts" | tail -1 | sed -n 's/.*_\([0-9]*\)_of_\([0-9]*\)\.txt/\2/p')

    echo ""
    if [ "$current_total" != "$new_total" ]; then
        echo -e "${YELLOW}Part count changed: $current_total → $new_total${NC}"
    else
        echo -e "${GREEN}Part count unchanged: $new_total parts${NC}"
    fi
}

# Append command - add new content to existing parts
cmd_append() {
    local prefix="$1"
    local new_content_file="$2"

    if [ ! -f "$new_content_file" ]; then
        echo -e "${RED}Error: Content file '$new_content_file' not found${NC}"
        exit 1
    fi

    local parts=$(find_part_files "$prefix")
    if [ -z "$parts" ]; then
        echo -e "${RED}Error: No part files found with prefix '$prefix'${NC}"
        exit 1
    fi

    echo "Appending content to parts with prefix '$prefix'..."

    # Join existing content and append new content
    temp_file=$(mktemp)
    cmd_join "$prefix" > "$temp_file"
    cat "$new_content_file" >> "$temp_file"

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    mv $parts "$backup_dir/"

    # Re-split the combined file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"
}

# Create helper script for sending to Claude
create_helper_script() {
    local prefix="$1"
    local total_parts="$2"
    local helper_script="${prefix}_send_to_claude.sh"

    cat > "$helper_script" <<'HELPER'
#!/bin/bash
set -e

# Check if claude command exists
if ! command -v claude &> /dev/null; then
    echo "Error: 'claude' command not found. Please install Claude Code CLI."
    exit 1
fi

echo "Sending all parts to Claude Code CLI..."
echo "Make sure to wait for acknowledgment after each part!"
echo ""

HELPER

    for i in $(seq 1 $total_parts); do
        echo "echo \"Sending part $i/$total_parts...\"" >> "$helper_script"
        echo "claude < \"${prefix}_${i}_of_${total_parts}.txt\"" >> "$helper_script"
        if [ $i -lt $total_parts ]; then
            echo "echo \"\"" >> "$helper_script"
            echo "echo \"Waiting for acknowledgment...\"" >> "$helper_script"
            echo "echo \"Claude should respond: 'Part $i/$total_parts received'\"" >> "$helper_script"
            echo "read -p \"Press Enter after Claude acknowledges part $i: \"" >> "$helper_script"
        fi
        echo "" >> "$helper_script"
    done

    echo "echo \"All parts sent successfully!\"" >> "$helper_script"
    chmod +x "$helper_script"
}

# Main script logic
check_dependencies

if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

command="$1"
shift

case "$command" in
    split)
        [ $# -lt 1 ] && { echo "Error: Missing input file"; show_usage; exit 1; }
        cmd_split "$@"
        ;;
    check)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_check "$1"
        ;;
    join)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_join "$1"
        ;;
    reprocess)
        [ $# -lt 1 ] && { echo "Error: Missing prefix"; show_usage; exit 1; }
        cmd_reprocess "$1"
        ;;
    append)
        [ $# -lt 2 ] && { echo "Error: Missing prefix or content file"; show_usage; exit 1; }
        cmd_append "$1" "$2"
        ;;
    -h|--help|help)
        show_usage
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$command'${NC}"
        show_usage
        exit 1
        ;;
esac