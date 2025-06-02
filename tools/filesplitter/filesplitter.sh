#!/bin/bash

# filesplitter.sh - Split large text files into token-limited chunks for Claude CLI

set -euo pipefail

# Cleanup function
cleanup() {
    local exit_code=$?
    if [ -n "${temp_file:-}" ] && [ -f "${temp_file:-}" ]; then
        rm -f "$temp_file"
    fi
    # Clear any partial files on failure
    if [ $exit_code -ne 0 ] && [ -n "${output_prefix:-}" ] && [ -n "${part_num:-}" ]; then
        echo -e "\n${YELLOW}Cleaning up partial files...${NC}" >&2
        rm -f "${output_prefix}_${part_num}_of_"*.txt 2>/dev/null
    fi
    exit $exit_code
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Get the directory where this script is located (handles symlinks)
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"

# Configuration
MAX_TOKENS="${MAX_TOKENS:-25000}"
TOKEN_BUFFER=1000  # Safety buffer to ensure we stay under limit
CHUNK_MODE="${CHUNK_MODE:-safe}"  # safe or fast
DEBUG="${DEBUG:-false}"  # Enable debug output
TOKENCOUNT_CMD="${TOKENCOUNT_CMD:-$SCRIPT_DIR/../tokencount/tokencount}"  # Path to tokencount command

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
  index <directory>                      Create index of all split docs in directory

Options:
  -h, --help                            Show this help message

Environment variables:
  CHUNK_MODE=safe|fast  (default: safe)
  MAX_TOKENS=25000      (default: 25000)
  DEBUG=true|false      (default: false)
  TOKENCOUNT_CMD=path   (default: ../tokencount/tokencount)

Examples:
  $0 split large_document.txt doc
  $0 check doc
  $0 reprocess doc
  $0 append doc new_content.txt
  $0 join doc > recovered_document.txt
  $0 index docs/

  # Split PRD into docs directory:
  $0 split prd.md docs/prd/prd

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
        echo "  $(dirname "$SCRIPT_DIR")/tokencount/tokencount"
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
    local doc_name=$3

    cat <<EOF
[DOCUMENT: $doc_name - Part $part_num of $total_parts]
[CONTINUES TO: ${doc_name}_part_$((part_num + 1))_of_${total_parts}.txt]

This is part $part_num of $total_parts of the complete document.
Read all parts in sequence to understand the full content.
EOF
}

# Function to create the postfix for a part
create_postfix() {
    local part_num=$1
    local total_parts=$2
    local doc_name=$3

    if [ "$part_num" -lt "$total_parts" ]; then
        echo -e "\n[END OF PART $part_num - Continue reading ${doc_name}_part_$((part_num + 1))_of_${total_parts}.txt]"
    else
        echo -e "\n[END OF DOCUMENT - All $total_parts parts complete]"
    fi
}

# Function to estimate wrapper tokens for a part
estimate_wrapper_tokens() {
    local part_num=$1
    local total_parts=$2
    local doc_name="document"

    # Create wrapper and count actual tokens
    local prefix=$(create_prefix "$part_num" "$total_parts" "$doc_name")
    local postfix=$(create_postfix "$part_num" "$total_parts" "$doc_name")
    local markers="[START PART $part_num/$total_parts]"$'\n'"[END PART $part_num/$total_parts]"

    local wrapper="${prefix}"$'\n\n'"${markers}"$'\n'"${postfix}"
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
    # Use more robust extraction to handle edge cases
    awk '/\[START PART [0-9]+\/[0-9]+\]/ {flag=1; next} /\[END PART [0-9]+\/[0-9]+\]/ {flag=0} flag' "$file"
}

# Function to find all part files for a prefix
find_part_files() {
    local prefix="$1"
    # Use a more specific pattern to avoid matching backup directories
    # Handle both absolute and relative paths
    local dir=$(dirname "$prefix")
    local base=$(basename "$prefix")
    find "$dir" -maxdepth 1 -name "${base}_[0-9]*_of_[0-9]*.txt" -type f 2>/dev/null | sort -V
}

# Progress indicator with better formatting
show_progress() {
    local current=$1
    local total=$2
    if command -v bc >/dev/null 2>&1; then
        local percent=$(echo "scale=1; $current * 100 / $total" | bc)
    else
        local percent=$(( (current * 100) / total ))
    fi
    printf "\rProcessed %d/%d lines (%s%%)..." "$current" "$total" "$percent"
}

# Split command
cmd_split() {
    local input_file="$1"
    local output_prefix="${2:-$(basename "$input_file" | sed 's/\.[^.]*$//')_part}"

    if [ ! -f "$input_file" ]; then
        echo -e "${RED}Error: Input file '$input_file' not found${NC}"
        exit 1
    fi

    # Validate input file
    validate_input_file "$input_file"

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

    # Create output directory if it doesn't exist
    local output_dir=$(dirname "$output_prefix")
    if [ "$output_dir" != "." ] && [ ! -d "$output_dir" ]; then
        echo "Creating output directory: $output_dir"
        mkdir -p "$output_dir" || {
            echo -e "${RED}Error: Cannot create output directory${NC}"
            exit 1
        }
    fi

    split_file "$input_file" "$output_prefix"
}

# Main splitting logic
split_file() {
    local input_file="$1"
    local output_prefix="$2"

    # Count total lines for progress (handle files without final newline)
    echo "Counting total lines..."
    if [ -s "$input_file" ]; then
        total_lines=$(wc -l < "$input_file" | tr -d ' ')
        # Add 1 if file doesn't end with newline
        if [ -n "$(tail -c 1 "$input_file")" ]; then
            total_lines=$((total_lines + 1))
        fi
    else
        echo -e "${RED}Error: Input file is empty${NC}"
        exit 1
    fi
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
            current_part="${current_part}"$'\n'
            continue
        fi

        # Check for extremely long lines
        if [ ${#line} -gt 50000 ]; then
            echo -e "\n${YELLOW}Warning: Line $line_count is very long (${#line} chars)${NC}"
            # Handle potential single line exceeding limit after adding markers
            if [ -n "$current_part" ]; then
                # Check if we need to create a part with just this line
                single_line_with_wrapper_tokens=$((line_tokens + dummy_wrapper_tokens + TOKEN_BUFFER))
                if [ $single_line_with_wrapper_tokens -gt $MAX_TOKENS ]; then
                    echo -e "\n${RED}Error: Single line at line $line_count exceeds token limit even with wrapper!${NC}"
                    echo "Line tokens: $line_tokens, Total with wrapper: $single_line_with_wrapper_tokens"
                    echo "Maximum allowed: $MAX_TOKENS"
                    echo "Consider increasing MAX_TOKENS or splitting this line manually."
                    exit 1
                fi
                # Save current part if not empty
                temp_parts+=("$current_part")
            fi
        fi

        # Token checking logic
        if [ "$CHUNK_MODE" = "fast" ]; then
            # Fast mode: estimate tokens by character count (rough: 4 chars = 1 token)
            estimated_tokens=$((${#current_part} / 4))
            check_needed=$((estimated_tokens > (MAX_TOKENS - TOKEN_BUFFER - dummy_wrapper_tokens - 5000)))
        else
            # Safe mode: check periodically
            check_needed=$((line_count == 1 || line_count % 10 == 0 || current_tokens > (MAX_TOKENS - TOKEN_BUFFER - dummy_wrapper_tokens - 5000)))
        fi

        if [ "$check_needed" = "1" ]; then
            test_content="${current_part}${line}"$'\n'
            test_tokens=$(echo "$test_content" | "$TOKENCOUNT_CMD")

            [ "$DEBUG" = "true" ] && echo -e "\n[DEBUG] Line $line_count: $test_tokens tokens"

            if [ $test_tokens -gt $((MAX_TOKENS - TOKEN_BUFFER - dummy_wrapper_tokens)) ] && [ -n "$current_part" ]; then
                temp_parts+=("$current_part")
                current_part="${line}"$'\n'
                current_tokens=$(echo "$current_part" | "$TOKENCOUNT_CMD")
            else
                current_part="${test_content}"
                current_tokens=$test_tokens
            fi
        else
            current_part="${current_part}${line}"$'\n'
        fi

        # Progress indicator
        if [ $((line_count % 100)) -eq 0 ]; then
            show_progress "$line_count" "$total_lines"
        fi
    done < "$input_file"

    # Don't forget the last part
    if [ -n "$current_part" ]; then
        # Trim trailing newlines from last part to avoid empty parts
        current_part=$(printf "%s" "$current_part" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')
        if [ -n "$current_part" ]; then
            temp_parts+=("$current_part")
        fi
    fi

    echo -e "\nTotal parts needed: ${#temp_parts[@]}"

    # Validate we have parts to create
    if [ ${#temp_parts[@]} -eq 0 ]; then
        echo -e "${RED}Error: No parts to create. File may be empty or corrupted.${NC}"
        exit 1
    fi

    # Create the actual files
    total_parts=${#temp_parts[@]}

    for i in "${!temp_parts[@]}"; do
        part_num=$((i + 1))
        output_file="${output_prefix}_${part_num}_of_${total_parts}.txt"

        echo "Creating part $part_num/$total_parts: $output_file"

        # Get the base name for the document
        local doc_base_name=$(basename "$output_prefix")

        # Write content atomically (write to temp, then move)
        local temp_output="${output_file}.tmp"
        {
            create_prefix "$part_num" "$total_parts" "$doc_base_name"
            echo ""
            echo "[START PART $part_num/$total_parts]"
            printf "%s" "${temp_parts[$i]}"
            # Only add newline if content doesn't end with one
            [[ "${temp_parts[$i]}" != *$'\n' ]] && echo
            echo "[END PART $part_num/$total_parts]"
            create_postfix "$part_num" "$total_parts" "$doc_base_name"
        } > "$temp_output" || {
            echo -e "${RED}Error: Failed to write part $part_num${NC}"
            rm -f "$temp_output"
            exit 1
        }

        mv "$temp_output" "$output_file" || {
            echo -e "${RED}Error: Failed to create $output_file${NC}"
            rm -f "$temp_output"
            exit 1
        }

        # Verify token count
        final_tokens=$("$TOKENCOUNT_CMD" < "$output_file")
        echo "  Token count: $final_tokens"

        if [ $final_tokens -gt $MAX_TOKENS ]; then
            echo -e "${RED}  ERROR: Part $part_num exceeds $MAX_TOKENS tokens ($final_tokens)!${NC}"
            echo "  Consider using a smaller MAX_TOKENS value or splitting by paragraphs."
            exit 1
        fi
    done

    # Validate all parts were created successfully
    local created_parts=$(find_part_files "$output_prefix" | wc -l | tr -d ' ')
    if [ "$created_parts" -ne "$total_parts" ]; then
        echo -e "${RED}Error: Expected $total_parts parts but only created $created_parts${NC}"
        exit 1
    fi

    # Create documentation
    create_doc_readme "$output_prefix" "$total_parts" "$input_file"

    echo -e "\n${GREEN}Success!${NC}"
    echo "- Split '$input_file' into $total_parts parts"
    echo "- Output files: ${output_prefix}_*_of_${total_parts}.txt"
    echo "- Documentation: ${output_prefix}_README.md"
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
    temp_file=$(mktemp "${TMPDIR:-/tmp}/filesplitter.XXXXXX") || {
        echo -e "${RED}Error: Cannot create temporary file${NC}"
        exit 1
    }
    cmd_join "$prefix" > "$temp_file"

    # Get the current total parts number
    current_total=$(echo "$parts" | tail -1 | grep -oE '_[0-9]+_of_([0-9]+)\.txt$' | grep -oE 'of_[0-9]+' | cut -d_ -f2)

    if [ -z "$current_total" ]; then
        echo -e "${RED}Error: Could not determine total parts from existing files${NC}"
        echo "Files found: $parts"
        exit 1
    fi

    # Back up existing parts
    backup_dir="${prefix}_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Backing up existing parts to $backup_dir/"
    for part in $parts; do
        cp "$part" "$backup_dir/" || {
            echo -e "${RED}Error: Failed to backup $part${NC}"
            exit 1
        }
    done
    rm -f $parts

    # Re-split the file
    split_file "$temp_file" "$prefix"

    # Clean up
    rm -f "$temp_file"

    # Report changes
    new_parts=$(find_part_files "$prefix")
    if [ -z "$new_parts" ]; then
        echo -e "${RED}Error: No parts created after reprocessing${NC}"
        exit 1
    fi

    new_total=$(echo "$new_parts" | tail -1 | grep -oE '_[0-9]+_of_([0-9]+)\.txt$' | grep -oE 'of_[0-9]+' | cut -d_ -f2)

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
    temp_file=$(mktemp "${TMPDIR:-/tmp}/filesplitter.XXXXXX") || {
        echo -e "${RED}Error: Cannot create temporary file${NC}"
        exit 1
    }
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

# Create helper script for sending to Claude CLI
create_helper_script() {
    local prefix="$1"
    local total_parts="$2"

    # Only create for CLI format
    if [ "$OUTPUT_FORMAT" != "claude-cli" ]; then
        return
    fi

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

# Create README for documentation sets (Claude Code)
create_doc_readme() {
    local prefix="$1"
    local total_parts="$2"
    local source_file="$3"
    local readme_file="${prefix}_README.md"
    local doc_name=$(basename "$prefix")

    cat > "$readme_file" <<EOF
# $doc_name Documentation

This directory contains the $doc_name document split into $total_parts parts due to size constraints.

## Source
Original file: $source_file
Split date: $(date +"%Y-%m-%d %H:%M")

## Files
EOF

    for i in $(seq 1 $total_parts); do
        echo "- \`${doc_name}_part_${i}_of_${total_parts}.txt\` - Part $i of $total_parts" >> "$readme_file"
    done

    cat >> "$readme_file" <<EOF

## How to Read
These files form a single continuous document. When referencing this documentation, read all parts in sequence (part 1 through part $total_parts).

## Usage in Claude Code
To reference this document in conversation:
- "Please read the $doc_name documentation"
- "Refer to $doc_name part 3 for details on..."
- "The $doc_name explains the requirements"

## Document Structure
Each part is clearly marked with:
- \`[START PART X/$total_parts]\` - Beginning of content
- \`[END PART X/$total_parts]\` - End of content
- Navigation hints to the next part

## Notes
- Total token count: ~$(($total_parts * (MAX_TOKENS - TOKEN_BUFFER))) tokens
- Format: Claude Code optimized
- Do not edit these files directly - edit the source and re-split
EOF
}

# Index command - create overview of all split documents
cmd_index() {
    local directory="${1:-.}"
    local index_file="$directory/DOCUMENT_INDEX.md"

    echo "Creating document index for $directory..."

    cat > "$index_file" <<EOF
# Document Index

Generated: $(date +"%Y-%m-%d %H:%M")

## Split Documents in this Directory

EOF

    # Find all README files created by our tool
    local readme_count=0
    while IFS= read -r readme; do
        if [ -f "$readme" ] && grep -q "split into.*parts due to size constraints" "$readme" 2>/dev/null; then
            local dir=$(dirname "$readme")
            local base=$(basename "$dir")
            echo "### $base" >> "$index_file"
            echo "Location: \`$dir/\`" >> "$index_file"
            echo "" >> "$index_file"

            # Extract key info from README
            grep "^- \`.*\.txt\`" "$readme" >> "$index_file" 2>/dev/null || true
            echo "" >> "$index_file"
            readme_count=$((readme_count + 1))
        fi
    done < <(find "$directory" -name "*_README.md" -type f)

    if [ $readme_count -eq 0 ]; then
        echo "No split documents found in this directory tree." >> "$index_file"
    else
        cat >> "$index_file" <<EOF

## Usage Instructions

When asked to reference any of these documents:
1. Navigate to the appropriate directory
2. Read all parts in sequence (part 1 through part N)
3. Treat the content as a single continuous document

## Quick Commands

\`\`\`bash
# Check all documents
find . -name "*_part_*_of_*.txt" | xargs -I {} $0 check {}

# Reprocess all after updates
for prefix in \$(find . -name "*_part_1_of_*.txt" | sed 's/_part_1_of_.*//'); do
    $0 reprocess "\$prefix"
done
\`\`\`
EOF
    fi

    echo -e "${GREEN}Created index: $index_file${NC}"
    echo "Found $readme_count document sets"
}

# Main script logic
# Verify script integrity
if [ ! -f "$0" ]; then
    echo "Error: Cannot find script file"
    exit 1
fi

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
    index)
        [ $# -lt 1 ] && cmd_index "." || cmd_index "$1"
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