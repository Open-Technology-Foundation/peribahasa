#!/bin/bash
set -euo pipefail
shopt -s inherit_errexit extglob nullglob

declare -r VERSION='1.0.0'
#shellcheck disable=SC2155
declare -r SCRIPT_PATH=$(realpath -- "$0")
declare -r SCRIPT_DIR=${SCRIPT_PATH%/*} SCRIPT_NAME=${SCRIPT_PATH##*/}
declare -r DB_PATH="$SCRIPT_DIR/peribahasa.db"
declare -r TEMP_DIR="/tmp/peribahasa-import-$$"

# Configuration
declare -r KATEGLO_API_BASE='http://kateglo.lostfocus.org/api.php'
declare -r KEMENDIKBUD_PDF_URL='https://repositori.kemendikdasmen.go.id/26906/1/500%20PEPATAH.pdf'
declare -r DETIK_URL='https://www.detik.com/jateng/berita/d-7516806/150-peribahasa-indonesia-terlengkap-dan-artinya-untuk-anak-sd-sma'
declare -r CNN_URL='https://www.cnnindonesia.com/edukasi/20230818132211-569-987557/100-contoh-peribahasa-indonesia-dan-artinya'
declare -r CLAUDE_API_URL='https://api.anthropic.com/v1/messages'

# Options
declare -i VERBOSE=0 DRY_RUN=0 CHECK_MODE=0 BATCH_SIZE=10
declare -- SOURCE='all'

# Statistics
declare -i IMPORTED=0 SKIPPED=0 FAILED=0
declare -i CHECKED=0 CORRECTED=0 CHECK_FAILED=0

# Color definitions
if [[ -t 1 && -t 2 ]]; then
  #shellcheck disable=SC2034
  declare -r RED=$'\033[0;31m' CYAN=$'\033[0;36m' GREEN=$'\033[0;32m' YELLOW=$'\033[0;33m' BOLD=$'\033[1m' NC=$'\033[0m'
else
  #shellcheck disable=SC2034
  declare -r RED='' CYAN='' GREEN='' YELLOW='' BOLD='' NC=''
fi

# Base messaging function
_msg() {
  local -- prefix="$SCRIPT_NAME:" msg
  case "${FUNCNAME[1]}" in
    info)    prefix+=" ${CYAN}◉${NC}" ;;
    warn)    prefix+=" ${YELLOW}▲${NC}" ;;
    success) prefix+=" ${GREEN}✓${NC}" ;;
    error)   prefix+=" ${RED}✗${NC}" ;;
    debug)   prefix+=" ${CYAN}⦿${NC}" ;;
  esac
  for msg in "$@"; do printf '%s %s\n' "$prefix" "$msg"; done
}

# Standard messaging functions
info() { ((VERBOSE)) || return 0; >&2 _msg "$@"; }
warn() { >&2 _msg "$@"; }
error() { >&2 _msg "$@"; }
success() { >&2 _msg "$@"; }
debug() { ((VERBOSE > 1)) || return 0; >&2 _msg "$@"; }
die() { (($# > 1)) && error "${@:2}"; exit "${1:-0}"; }

# Utility functions
noarg() { (($# > 1)) || die 2 "Option ${1@Q} requires an argument"; }

# Display usage information
usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Import Indonesian peribahasa from external sources into the database,
or check/correct existing entries using LLM.

OPTIONS:
  -s, --source SOURCE    Import source: kateglo|kemendikbud|detik|cnn|all (default: all)
  -c, --check [SOURCE]   Check entries for spelling/formatting using Claude API
  -b, --batch-size N     Batch size for --check mode (default: 10)
  -n, --dry-run          Preview without importing/updating
  -v, --verbose          Enable verbose output (repeatable: -vv)
  -q, --quiet            Suppress verbose output
  -V, --version          Display version information
  -h, --help             Display this help message

SOURCES:
  kateglo        Kateglo online dictionary API (~200 entries)
  kemendikbud    Kemendikbud 500 Pepatah PDF (432 entries)
  detik          Detik.com article (150 entries)
  cnn            CNN Indonesia article (100 entries)
  all            All sources (default)

CHECK MODE:
  Requires ANTHROPIC_API_KEY environment variable.
  Updates cek_peribahasa, cek_artinya, and cek (confidence) fields.
  Confidence scores: 1.0=correct, 0.8=minor fix, 0.5=spelling, <0.5=needs review

EXAMPLES:
  $SCRIPT_NAME                           # Import from all sources
  $SCRIPT_NAME --source kateglo          # Import from Kateglo only
  $SCRIPT_NAME --check                   # Check all unchecked entries
  $SCRIPT_NAME --check detik -v          # Check Detik entries verbosely
  $SCRIPT_NAME --check --batch-size 20   # Check with larger batches
EOF
}

# Check if peribahasa exists in database
check_duplicate() {
  local -- peribahasa="$1"
  local -i count
  # Use printf to properly escape single quotes for SQL
  peribahasa="${peribahasa//\'/\'\'}"
  count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM peribahasa WHERE peribahasa='$peribahasa';") || die 1 'Database query failed'
  ((count > 0))
}

# Insert peribahasa into database
insert_peribahasa() {
  local -- peribahasa="$1" artinya="$2" sumber="$3"

  # Validate inputs
  [[ -n "$peribahasa" && -n "$artinya" ]] || {
    warn "Skipping empty entry"
    SKIPPED+=1
    return 1
  }

  # Check for duplicates
  if check_duplicate "$peribahasa"; then
    debug "Skipping duplicate: ${peribahasa:0:50}..."
    SKIPPED+=1
    return 0
  fi

  # Dry run mode
  if ((DRY_RUN)); then
    info "Would import: ${peribahasa:0:50}..."
    IMPORTED+=1
    return 0
  fi

  # Insert into database
  # Escape single quotes for SQL
  local -- peribahasa_esc="${peribahasa//\'/\'\'}"
  local -- artinya_esc="${artinya//\'/\'\'}"

  if ! sqlite3 "$DB_PATH" <<EOF
INSERT INTO peribahasa (peribahasa, artinya, dipakai, sumber)
VALUES ('$peribahasa_esc', '$artinya_esc', 0, '$sumber');
EOF
  then
    error "Failed to insert: ${peribahasa:0:50}..."
    FAILED+=1
    return 1
  fi

  IMPORTED+=1
  return 0
}

# Import from Kateglo API
import_from_kateglo() {
  info 'Fetching from Kateglo API...'

  # Check dependencies
  command -v curl >/dev/null 2>&1 || die 1 'curl is required but not installed'
  command -v jq >/dev/null 2>&1 || die 1 'jq is required but not installed'

  local -- word response proverb meaning
  local -i total=0 fetched=0

  # List of common Indonesian words to query (peribahasa are associated with words)
  local -a query_words=(
    ada air anak angin api atas ayam bagai bagaikan bak baik banyak barat batu
    belajar benar beras besar burung cepat cinta daging dari daun dapat di
    dunia gajah gula hati hari hilang hidup hujan ikan jalan jauh jatuh kaki
    kalau kecil kepala kera kucing lain laut lebih ma main makan malam mata
    mati mau membawa mengambil orang padi pandai panjang pergi rumah
    saja sama sakit sayang seekor siapa sudah sungai takut tangan telur
    tempat tidak tikus tinggi udang ular untuk
  )

  # Query each word
  for word in "${query_words[@]}"; do
    debug "Querying peribahasa for word: $word"

    response=$(curl -s "${KATEGLO_API_BASE}?format=json&phrase=$word" 2>&1) || {
      warn "Failed to fetch data for word: $word"
      continue
    }

    fetched+=1

    # Parse JSON and extract proverbs
    # Kateglo structure: {"kateglo":{"proverbs":[{"proverb":"...","meaning":"..."}]}}
    while IFS='|' read -r proverb meaning; do
      [[ -n "$proverb" && -n "$meaning" ]] || continue
      insert_peribahasa "$proverb" "$meaning" 'kateglo'
      total+=1
    done < <(echo "$response" | jq -r '.kateglo.proverbs[]? | "\(.proverb)|\(.meaning)"' 2>/dev/null)

    # Rate limiting - be polite to the server
    sleep 0.2
  done

  info "Kateglo: Queried $fetched words, processed $total entries"
}

# Import from Kemendikbud PDF
import_from_kemendikbud() {
  info 'Downloading Kemendikbud PDF...'

  # Check dependencies
  command -v curl >/dev/null 2>&1 || die 1 'curl is required but not installed'
  command -v pdftotext >/dev/null 2>&1 || die 1 'pdftotext is required (install poppler-utils)'

  mkdir -p "$TEMP_DIR"
  local -- pdf_file="$TEMP_DIR/500-pepatah.pdf"
  local -- txt_file="$TEMP_DIR/500-pepatah.txt"

  # Download PDF
  curl -L -o "$pdf_file" "$KEMENDIKBUD_PDF_URL" >/dev/null 2>&1 || die 1 'Failed to download Kemendikbud PDF'

  info 'Parsing PDF content...'

  # Convert PDF to text
  pdftotext -layout "$pdf_file" "$txt_file" 2>/dev/null || die 1 'Failed to convert PDF to text'

  # Parse the text file
  # Expected format: numbered peribahasa entries (1. , 2. , etc.) followed by meanings
  local -- peribahasa='' artinya='' line clean_line
  local -i in_entry=0 total=0

  while IFS= read -r line; do
    # Skip empty lines
    [[ -n "${line// /}" ]] || continue

    # Skip page numbers and very short lines
    [[ "${#line}" -lt 5 ]] && continue

    # Detect peribahasa patterns: lines starting with "number. " (e.g., "1. ", "23. ")
    if [[ "$line" =~ ^[0-9]+\.\ +(.+)$ ]]; then
      # If we have a previous entry, save it
      if [[ -n "$peribahasa" && -n "$artinya" ]]; then
        insert_peribahasa "$peribahasa" "$artinya" 'kemendikbud'
        total+=1
      fi
      # Start new entry - remove the number prefix
      clean_line="${BASH_REMATCH[1]}"
      # Further clean: remove trailing dots and extra spaces
      clean_line="${clean_line%%...}"
      clean_line="${clean_line%.}"
      peribahasa="$clean_line"
      artinya=""
      in_entry=1
    elif ((in_entry)) && [[ ! "$line" =~ ^[0-9]+$ ]]; then
      # Continuation of meaning (but skip standalone numbers)
      # Skip lines that look like page numbers or section markers
      [[ "$line" =~ ^(500|Pepatah|Dengan|Peribahasa|Bahkan|Tetapi) ]] && continue
      artinya="${artinya:+$artinya }$line"
    fi
  done < "$txt_file"

  # Save last entry
  if [[ -n "$peribahasa" && -n "$artinya" ]]; then
    insert_peribahasa "$peribahasa" "$artinya" 'kemendikbud'
    total+=1
  fi

  info "Kemendikbud: Processed $total entries"
}

# Import from Detik.com
import_from_detik() {
  info 'Fetching from Detik.com...'

  # Check dependencies
  command -v curl >/dev/null 2>&1 || die 1 'curl is required but not installed'

  local -- html peribahasa artinya
  local -i total=0

  # Fetch HTML with timeout
  html=$(curl -s --max-time 30 "$DETIK_URL") || die 1 'Failed to fetch Detik.com'

  debug "Fetched HTML length: ${#html}"

  # Extract list items with peribahasa pattern, decode HTML entities, and parse
  while IFS=: read -r peribahasa artinya; do
    # Skip if either part is empty
    [[ -z "$peribahasa" || -z "$artinya" ]] && continue

    # Clean peribahasa: trim whitespace and remove trailing period
    peribahasa=$(echo "$peribahasa" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed 's/\.$//')

    # Clean artinya: trim whitespace and remove trailing period
    artinya=$(echo "$artinya" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed 's/\.$//')

    # Skip if either part is empty after cleaning
    [[ -z "$peribahasa" || -z "$artinya" ]] && continue

    insert_peribahasa "$peribahasa" "$artinya" 'detik'
    total+=1
  done < <(echo "$html" | grep -oP '<li>[^<]+:[^<]+</li>' | \
    sed 's/<[^>]*>//g' | \
    sed 's/&nbsp;/ /g' | \
    sed 's/&rsquo;/'"'"'/g' | \
    sed 's/&ldquo;/"/g' | \
    sed 's/&rdquo;/"/g' | \
    sed 's/&hellip;/.../g')

  info "Detik.com: Processed $total entries"
}

# Import from CNN Indonesia
import_from_cnn() {
  info 'Fetching from CNN Indonesia...'

  # Check dependencies
  command -v curl >/dev/null 2>&1 || die 1 'curl is required but not installed'

  local -- html peribahasa artinya
  local -i total=0

  # Fetch HTML with timeout
  html=$(curl -s --max-time 30 "$CNN_URL") || die 1 'Failed to fetch CNN Indonesia'

  debug "Fetched HTML length: ${#html}"

  # Extract list items with peribahasa pattern, decode HTML entities, and parse
  while IFS=: read -r peribahasa artinya; do
    # Skip if either part is empty
    [[ -z "$peribahasa" || -z "$artinya" ]] && continue

    # Clean peribahasa: trim whitespace and remove trailing period
    peribahasa=$(echo "$peribahasa" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed 's/\.$//')

    # Clean artinya: trim whitespace and remove trailing period
    artinya=$(echo "$artinya" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed 's/\.$//')

    # Skip if either part is empty after cleaning
    [[ -z "$peribahasa" || -z "$artinya" ]] && continue

    insert_peribahasa "$peribahasa" "$artinya" 'cnn'
    total+=1
  done < <(echo "$html" | grep -oP '<li>[^<]+:[^<]+</li>' | \
    sed 's/<[^>]*>//g' | \
    sed 's/&nbsp;/ /g' | \
    sed 's/&rsquo;/'"'"'/g' | \
    sed 's/&ldquo;/"/g' | \
    sed 's/&rdquo;/"/g' | \
    sed 's/&hellip;/.../g')

  info "CNN Indonesia: Processed $total entries"
}

# Build LLM prompt for checking Indonesian peribahasa
build_check_prompt() {
  cat <<'PROMPT'
You are reviewing Indonesian peribahasa (proverbs) for spelling and formatting errors.

For each entry, check:
1. Spelling errors in Indonesian words
2. Proper capitalization (first word capitalized, rest lowercase unless proper noun)
3. Punctuation consistency
4. Grammar and word order

IMPORTANT:
- Preserve archaic/traditional Indonesian spellings (e.g., "tiada" not "tidak")
- Preserve regional variations
- Do NOT modernize old forms
- If text is correct, return it unchanged

Return a JSON array with corrections. Include ALL entries, even if unchanged.

Confidence scores:
- 1.0: Text is correct, no changes needed
- 0.9: Minor punctuation/capitalization fix
- 0.7-0.8: Spelling correction
- 0.5-0.6: Grammar/word order fix
- 0.25-0.4: Significant changes needed
- <0.25: Major issues, needs human review

Output ONLY valid JSON in this exact format (no markdown, no explanation):
{"corrections":[{"id":N,"cek_peribahasa":"...","cek_artinya":"...","cek":0.95}]}
PROMPT
}

# Call Claude API with batch of entries
call_claude_api() {
  local -- entries_json="$1"
  local -- prompt response

  prompt=$(build_check_prompt)

  # Build API request
  local -- request_body
  request_body=$(jq -n \
    --arg prompt "$prompt" \
    --arg entries "$entries_json" \
    '{
      model: "claude-sonnet-4-20250514",
      max_tokens: 4096,
      messages: [{
        role: "user",
        content: ($prompt + "\n\nEntries to check:\n" + $entries)
      }]
    }')

  # Call API with retry
  local -i attempt=0 max_attempts=3
  while ((attempt < max_attempts)); do
    attempt+=1
    debug "API call attempt $attempt of $max_attempts"

    response=$(curl -s --max-time 60 \
      -H "Content-Type: application/json" \
      -H "x-api-key: $ANTHROPIC_API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -d "$request_body" \
      "$CLAUDE_API_URL" 2>&1) || {
        warn "API call failed (attempt $attempt)"
        sleep $((attempt * 2))
        continue
      }

    # Check for API error
    if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
      local -- error_msg
      error_msg=$(echo "$response" | jq -r '.error.message // "Unknown error"')
      warn "API error: $error_msg"
      sleep $((attempt * 2))
      continue
    fi

    # Extract content from response
    local -- content
    content=$(echo "$response" | jq -r '.content[0].text // empty')
    if [[ -n "$content" ]]; then
      echo "$content"
      return 0
    fi

    warn "Empty response from API (attempt $attempt)"
    sleep $((attempt * 2))
  done

  return 1
}

# Check entries for spelling/formatting using LLM
check_entries() {
  local -- source_filter=''
  local -i total_unchecked batch_num=0

  # Build source filter
  if [[ "$SOURCE" != 'all' ]]; then
    source_filter="AND sumber='$SOURCE'"
    info "Checking entries from source: $SOURCE"
  fi

  # Count unchecked entries
  total_unchecked=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM peribahasa WHERE cek IS NULL $source_filter;")
  info "Unchecked entries: $total_unchecked"

  ((total_unchecked > 0)) || {
    info "No entries to check"
    return 0
  }

  # Process in batches
  local -- entries_json api_response
  local -i processed=0

  while ((processed < total_unchecked)); do
    batch_num+=1
    info "Processing batch $batch_num (entries $((processed + 1))-$((processed + BATCH_SIZE)) of $total_unchecked)..."

    # Get batch of unchecked entries as JSON
    # In dry-run mode, use OFFSET to avoid infinite loop
    local -- offset_clause=''
    ((DRY_RUN)) && offset_clause="OFFSET $processed"
    entries_json=$(sqlite3 -json "$DB_PATH" \
      "SELECT id, cek_peribahasa as peribahasa, cek_artinya as artinya
       FROM peribahasa
       WHERE cek IS NULL $source_filter
       LIMIT $BATCH_SIZE $offset_clause;")

    # Check if we got any entries
    [[ -n "$entries_json" && "$entries_json" != '[]' ]] || break

    debug "Batch entries: $entries_json"

    # Dry run mode - just count
    if ((DRY_RUN)); then
      local -i batch_count
      batch_count=$(echo "$entries_json" | jq 'length')
      info "Would check $batch_count entries"
      CHECKED+=$batch_count
      processed+=$batch_count
      continue
    fi

    # Call Claude API
    api_response=$(call_claude_api "$entries_json") || {
      error "Failed to get API response for batch $batch_num"
      CHECK_FAILED+=1
      # Mark these entries as failed with cek=-1
      echo "$entries_json" | jq -r '.[].id' | while read -r id; do
        sqlite3 "$DB_PATH" "UPDATE peribahasa SET cek=-1 WHERE id=$id;"
      done
      processed+=$BATCH_SIZE
      continue
    }

    debug "API response: $api_response"

    # Parse and apply corrections
    if ! echo "$api_response" | jq -e '.corrections' >/dev/null 2>&1; then
      error "Invalid JSON response from API"
      CHECK_FAILED+=1
      processed+=$BATCH_SIZE
      continue
    fi

    # Process each correction
    echo "$api_response" | jq -c '.corrections[]' | while read -r correction; do
      local -i id
      local -- new_peribahasa new_artinya
      local -- confidence

      id=$(echo "$correction" | jq -r '.id')
      new_peribahasa=$(echo "$correction" | jq -r '.cek_peribahasa')
      new_artinya=$(echo "$correction" | jq -r '.cek_artinya')
      confidence=$(echo "$correction" | jq -r '.cek')

      # Escape for SQL
      new_peribahasa="${new_peribahasa//\'/\'\'}"
      new_artinya="${new_artinya//\'/\'\'}"

      # Update database
      sqlite3 "$DB_PATH" "UPDATE peribahasa SET cek_peribahasa='$new_peribahasa', cek_artinya='$new_artinya', cek=$confidence WHERE id=$id;"

      CHECKED+=1

      # Check if correction was made
      local -- orig_peribahasa
      orig_peribahasa=$(sqlite3 "$DB_PATH" "SELECT peribahasa FROM peribahasa WHERE id=$id;")
      if [[ "$new_peribahasa" != "$orig_peribahasa" ]] || [[ "$new_artinya" != "$(sqlite3 "$DB_PATH" "SELECT artinya FROM peribahasa WHERE id=$id;")" ]]; then
        CORRECTED+=1
        debug "Corrected id=$id (confidence=$confidence)"
      fi
    done

    processed+=$BATCH_SIZE

    # Rate limiting
    sleep 1
  done

  info "Check processing complete"
}

# Cleanup temporary files
cleanup() {
  #shellcheck disable=SC2015
  [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR" || true
}

# Main function
main() {
  # Parse command-line arguments
  while (($#)); do case $1 in
    -s|--source)    noarg "$@"; shift
                    SOURCE="$1"
                    [[ "$SOURCE" =~ ^(kateglo|kemendikbud|detik|cnn|all)$ ]] || \
                      die 22 "Invalid source ${SOURCE@Q} (use: kateglo|kemendikbud|detik|cnn|all)"
                    ;;
    -c|--check)     CHECK_MODE=1
                    # Optional source argument
                    if [[ "${2:-}" =~ ^(kateglo|kemendikbud|detik|cnn|all)$ ]]; then
                      SOURCE="$2"; shift
                    fi
                    ;;
    -b|--batch-size) noarg "$@"; shift
                    [[ "$1" =~ ^[0-9]+$ ]] || die 22 "Invalid batch size ${1@Q}"
                    BATCH_SIZE="$1"
                    ;;
    -n|--dry-run)   DRY_RUN=1 ;;
    -v|--verbose)   VERBOSE+=1 ;;
    -q|--quiet)     VERBOSE=0 ;;
    -V|--version)   echo "$SCRIPT_NAME $VERSION"; exit 0 ;;
    -h|--help)      usage; exit 0 ;;

    # Short option bundling support
    -[scbnvqVh]*)   #shellcheck disable=SC2046
                    set -- '' $(printf -- "-%c " $(grep -o . <<<"${1:1}")) "${@:2}" ;;
    -*)             die 22 "Invalid option ${1@Q}" ;;
    *)              die 2 "Unexpected argument ${1@Q}" ;;
  esac; shift; done

  # Setup cleanup trap
  trap cleanup EXIT

  # Validate database exists
  [[ -f "$DB_PATH" ]] || die 5 "Database not found ${DB_PATH@Q}"

  # Display mode
  ((DRY_RUN)) && warn 'DRY RUN MODE - No changes will be made'

  # Check mode or Import mode
  if ((CHECK_MODE)); then
    # Validate API key
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] || die 1 'ANTHROPIC_API_KEY environment variable required for --check mode'
    command -v jq >/dev/null 2>&1 || die 1 'jq is required for --check mode'

    info 'Starting check process...'
    check_entries

    # Display check statistics
    echo
    success "Check complete"
    info "Checked: $CHECKED"
    #shellcheck disable=SC2015
    ((CORRECTED > 0)) && info "Corrected: $CORRECTED" || true
    #shellcheck disable=SC2015
    ((CHECK_FAILED > 0)) && warn "Failed: $CHECK_FAILED" || true

    # Show entries needing review
    local -i needs_review
    needs_review=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM peribahasa WHERE cek IS NOT NULL AND cek < 0.5;")
    #shellcheck disable=SC2015
    ((needs_review > 0)) && warn "Entries needing review (cek < 0.5): $needs_review" || true
  else
    info 'Starting import process...'

    # Import from selected sources
    case "$SOURCE" in
      kateglo)
        import_from_kateglo
        ;;
      kemendikbud)
        import_from_kemendikbud
        ;;
      detik)
        import_from_detik
        ;;
      cnn)
        import_from_cnn
        ;;
      all)
        import_from_kateglo
        import_from_kemendikbud
        import_from_detik
        import_from_cnn
        ;;
    esac

    # Display import statistics
    echo
    success "Import complete"
    info "Imported: $IMPORTED"
    #shellcheck disable=SC2015
    ((SKIPPED > 0)) && info "Skipped (duplicates): $SKIPPED" || true
    #shellcheck disable=SC2015
    ((FAILED > 0)) && warn "Failed: $FAILED" || true
  fi

  # Show database totals
  local -i total
  total=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM peribahasa;")
  info "Total in database: $total peribahasa"
}

main "$@"

#fin
