#!/usr/bin/env bash
# api-diff.sh — Detect breaking API changes between git branches/commits
# Usage: bash api-diff.sh [base-ref] [head-ref]
#   base-ref: the base branch/commit (default: origin/main)
#   head-ref: the head branch/commit (default: HEAD)
# All operations are read-only (git diff + grep only).

set -euo pipefail

BASE="${1:-origin/main}"
HEAD="${2:-HEAD}"

echo "=== API Breaking Change Detection ==="
echo "Comparing: $BASE → $HEAD"
echo ""

# --- Find API-related file changes ---
echo "--- Changed API Files ---"
API_FILES=$(git diff --name-only "$BASE" "$HEAD" -- \
  '*.proto' \
  '*openapi*' '*swagger*' \
  '*routes*' '*router*' '*controller*' '*handler*' \
  '*.graphql' '*.gql' \
  '**/api/**' \
  2>/dev/null || true)

if [ -z "$API_FILES" ]; then
  echo "No API-related files changed."
  echo ""
  echo "=== Result: No breaking changes detected ==="
  exit 0
fi

echo "$API_FILES"
echo ""

# --- Check for removed endpoints/routes ---
echo "--- Removed Endpoints (BREAKING) ---"
REMOVED=$(git diff "$BASE" "$HEAD" -- $API_FILES 2>/dev/null | \
  grep -E "^-.*\b(GET|POST|PUT|DELETE|PATCH|router\.|app\.|@Get|@Post|@Put|@Delete|rpc )" | \
  grep -v "^---" | \
  grep -v "^-.*#\|^-.*//\|^-.*\*" || true)

if [ -n "$REMOVED" ]; then
  echo "⚠️  POTENTIAL BREAKING CHANGES:"
  echo "$REMOVED" | head -20
else
  echo "None found."
fi
echo ""

# --- Check for removed response fields ---
echo "--- Removed Response Fields (BREAKING) ---"
REMOVED_FIELDS=$(git diff "$BASE" "$HEAD" -- $API_FILES 2>/dev/null | \
  grep -E "^-.*\"[a-z_]+\":" | \
  grep -v "^---" | \
  grep -v "^-.*#\|^-.*//\|^-.*\*" || true)

if [ -n "$REMOVED_FIELDS" ]; then
  echo "⚠️  Fields removed from responses:"
  echo "$REMOVED_FIELDS" | head -20
else
  echo "None found."
fi
echo ""

# --- Check for type changes ---
echo "--- Type Changes (BREAKING) ---"
TYPE_CHANGES=$(git diff "$BASE" "$HEAD" -- $API_FILES 2>/dev/null | \
  grep -E "^[-+].*(string|number|boolean|integer|int32|int64|float|double|bytes)\b" | \
  grep -v "^---\|^+++" | head -20 || true)

if [ -n "$TYPE_CHANGES" ]; then
  echo "⚠️  Potential type changes:"
  echo "$TYPE_CHANGES"
else
  echo "None found."
fi
echo ""

# --- Check for new required fields ---
echo "--- New Required Fields (BREAKING) ---"
NEW_REQUIRED=$(git diff "$BASE" "$HEAD" -- $API_FILES 2>/dev/null | \
  grep -E "^\+.*(required|NOT NULL)" | \
  grep -v "^+++" || true)

if [ -n "$NEW_REQUIRED" ]; then
  echo "⚠️  New required fields added:"
  echo "$NEW_REQUIRED" | head -20
else
  echo "None found."
fi
echo ""

# --- Check for changed error codes ---
echo "--- Changed Error Codes (BREAKING) ---"
ERROR_CHANGES=$(git diff "$BASE" "$HEAD" -- $API_FILES 2>/dev/null | \
  grep -E "^[-+].*(status|error_code|http_code|StatusCode)" | \
  grep -v "^---\|^+++" | head -20 || true)

if [ -n "$ERROR_CHANGES" ]; then
  echo "⚠️  Error code changes:"
  echo "$ERROR_CHANGES"
else
  echo "None found."
fi
echo ""

# --- Protobuf-specific checks ---
PROTO_FILES=$(echo "$API_FILES" | grep '\.proto$' || true)
if [ -n "$PROTO_FILES" ]; then
  echo "--- Protobuf Breaking Changes ---"
  # Check for changed field numbers (critical protobuf break)
  FIELD_RENUMBER=$(git diff "$BASE" "$HEAD" -- $PROTO_FILES 2>/dev/null | \
    grep -E "^[-+].*=\s+[0-9]+\s*;" | \
    grep -v "^---\|^+++" | head -20 || true)

  if [ -n "$FIELD_RENUMBER" ]; then
    echo "🔴 CRITICAL: Field number changes detected (wire-format breaking):"
    echo "$FIELD_RENUMBER"
  else
    echo "No field number changes."
  fi
  echo ""

  echo "Recommendation: Use 'buf breaking --against .git#branch=$BASE' for comprehensive protobuf breaking change detection."
  echo ""
fi

# --- Summary ---
BREAKING_COUNT=0
[ -n "$REMOVED" ] && BREAKING_COUNT=$((BREAKING_COUNT + $(echo "$REMOVED" | wc -l)))
[ -n "$REMOVED_FIELDS" ] && BREAKING_COUNT=$((BREAKING_COUNT + $(echo "$REMOVED_FIELDS" | wc -l)))
[ -n "$NEW_REQUIRED" ] && BREAKING_COUNT=$((BREAKING_COUNT + $(echo "$NEW_REQUIRED" | wc -l)))

echo "=== Summary ==="
if [ "$BREAKING_COUNT" -gt 0 ]; then
  echo "⚠️  Found $BREAKING_COUNT potential breaking change(s). Review each before merging."
  echo "Recommendation: If breaking, consider /principal:api-design REVIEW mode or /principal:migration"
else
  echo "✅ No obvious breaking changes detected. Non-breaking additions are safe."
fi
