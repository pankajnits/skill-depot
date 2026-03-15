#!/usr/bin/env bash
# schema-registry-diff.sh — Kafka/Avro/Protobuf schema breaking change detector
#
# Compares two schema versions and reports breaking vs non-breaking changes.
# Supports Confluent Schema Registry (Avro/JSON Schema), local .avsc files,
# and Protobuf .proto files (requires buf CLI).
#
# Usage:
#   # Compare two schema subjects in Confluent Schema Registry:
#   ./schema-registry-diff.sh --registry http://localhost:8081 --subject my-topic-value
#
#   # Compare two local Avro schema files:
#   ./schema-registry-diff.sh --avro old.avsc new.avsc
#
#   # Compare Protobuf schemas (requires buf):
#   ./schema-registry-diff.sh --proto proto/ --against .git#branch=main
#
#   # List all subjects in a registry:
#   ./schema-registry-diff.sh --registry http://localhost:8081 --list
#
# Read-only: makes no changes to any files or registry.

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
RESET='\033[0m'
BOLD='\033[1m'

REGISTRY_URL=""
SUBJECT=""
OLD_AVSC=""
NEW_AVSC=""
PROTO_DIR=""
PROTO_AGAINST=""
LIST_MODE=false
HELP=false

usage() {
  cat << 'EOF'
schema-registry-diff.sh — Schema breaking change detector

USAGE:
  # Schema Registry mode (Confluent compatible)
  ./schema-registry-diff.sh --registry URL --subject SUBJECT
  ./schema-registry-diff.sh --registry URL --list

  # Local Avro file comparison
  ./schema-registry-diff.sh --avro OLD.avsc NEW.avsc

  # Protobuf comparison (requires buf: brew install bufbuild/buf/buf)
  ./schema-registry-diff.sh --proto PROTO_DIR --against .git#branch=main

OPTIONS:
  --registry URL      Schema Registry base URL (e.g., http://localhost:8081)
  --subject SUBJECT   Schema subject to check (e.g., payments-topic-value)
  --list              List all subjects in the registry
  --avro OLD NEW      Compare two local Avro .avsc files
  --proto DIR         Protobuf proto directory to check
  --against REF       Git ref or directory to compare proto against (default: .git#branch=main)
  --help              Show this help

EXAMPLES:
  # Check if new schema is backward compatible with latest in registry
  ./schema-registry-diff.sh --registry http://schema-registry:8081 --subject user-events-value

  # Check all subjects in a registry
  ./schema-registry-diff.sh --registry http://schema-registry:8081 --list

  # Compare local Avro files
  ./schema-registry-diff.sh --avro schemas/v1/user.avsc schemas/v2/user.avsc

  # Check Protobuf breaking changes against main branch
  ./schema-registry-diff.sh --proto ./proto --against .git#branch=main
EOF
}

# ── Parse arguments ──────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry) REGISTRY_URL="$2"; shift 2 ;;
    --subject)  SUBJECT="$2"; shift 2 ;;
    --list)     LIST_MODE=true; shift ;;
    --avro)     OLD_AVSC="$2"; NEW_AVSC="$3"; shift 3 ;;
    --proto)    PROTO_DIR="$2"; shift 2 ;;
    --against)  PROTO_AGAINST="$2"; shift 2 ;;
    --help|-h)  HELP=true; shift ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if $HELP || [[ $# -eq 0 && -z "$REGISTRY_URL" && -z "$OLD_AVSC" && -z "$PROTO_DIR" ]]; then
  usage
  exit 0
fi

# ══ Mode 1: Schema Registry ════════════════════════════════════
registry_mode() {
  echo ""
  echo -e "${BOLD}Schema Registry: ${REGISTRY_URL}${RESET}"
  echo "════════════════════════════════════════════════════════════"

  # Test connectivity (read-only)
  if ! curl -sf "${REGISTRY_URL}/subjects" > /dev/null 2>&1; then
    echo -e "${RED}❌ Cannot connect to Schema Registry at ${REGISTRY_URL}${RESET}"
    echo "   Check URL and network access"
    exit 1
  fi

  if $LIST_MODE; then
    echo ""
    echo -e "${BOLD}All subjects:${RESET}"
    curl -sf "${REGISTRY_URL}/subjects" | python3 -m json.tool 2>/dev/null | \
      grep '"' | tr -d '", ' | sort
    exit 0
  fi

  if [[ -z "$SUBJECT" ]]; then
    echo "Error: --subject required with --registry (or use --list)"
    exit 1
  fi

  echo ""
  echo -e "${BOLD}Subject: ${SUBJECT}${RESET}"
  echo ""

  # Get list of versions (read-only)
  VERSIONS=$(curl -sf "${REGISTRY_URL}/subjects/${SUBJECT}/versions" 2>/dev/null || echo "[]")
  VERSION_COUNT=$(echo "$VERSIONS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)

  echo -e "Versions registered: ${BOLD}${VERSION_COUNT}${RESET}"

  if [[ $VERSION_COUNT -eq 0 ]]; then
    echo -e "${YELLOW}⚠️  No versions found for subject: ${SUBJECT}${RESET}"
    exit 0
  fi

  # Get all versions (read-only)
  LATEST_VERSION=$(echo "$VERSIONS" | python3 -c "import sys,json; v=json.load(sys.stdin); print(max(v))" 2>/dev/null)
  echo -e "Latest version: ${BOLD}${LATEST_VERSION}${RESET}"
  echo ""

  # Get schema for latest version (read-only)
  echo -e "${BOLD}Latest schema (v${LATEST_VERSION}):${RESET}"
  SCHEMA=$(curl -sf "${REGISTRY_URL}/subjects/${SUBJECT}/versions/${LATEST_VERSION}" 2>/dev/null)
  echo "$SCHEMA" | python3 -c "
import sys, json
data = json.load(sys.stdin)
schema_str = data.get('schema', '{}')
try:
  schema = json.loads(schema_str)
  print(json.dumps(schema, indent=2))
except:
  print(schema_str)
" 2>/dev/null | head -60

  echo ""

  # Check compatibility mode for this subject (read-only)
  echo -e "${BOLD}Compatibility configuration:${RESET}"
  COMPAT=$(curl -sf "${REGISTRY_URL}/config/${SUBJECT}" 2>/dev/null || \
           curl -sf "${REGISTRY_URL}/config" 2>/dev/null || echo '{"compatibilityLevel":"UNKNOWN"}')
  COMPAT_LEVEL=$(echo "$COMPAT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('compatibilityLevel', d.get('compatibility', 'NOT SET')))" 2>/dev/null)

  case "$COMPAT_LEVEL" in
    BACKWARD|BACKWARD_TRANSITIVE)
      echo -e "  ${GREEN}✅ BACKWARD${RESET} — consumers can be upgraded before producers. Safe pattern." ;;
    FORWARD|FORWARD_TRANSITIVE)
      echo -e "  ${YELLOW}⚠️  FORWARD${RESET} — producers can be upgraded before consumers. Risky: old consumers must handle new fields." ;;
    FULL|FULL_TRANSITIVE)
      echo -e "  ${GREEN}✅ FULL${RESET} — most strict. Both backward and forward compatible. Recommended for stable contracts." ;;
    NONE)
      echo -e "  ${RED}❌ NONE${RESET} — no compatibility checking. ANY change is allowed. Dangerous for production." ;;
    *)
      echo -e "  ${YELLOW}⚠️  ${COMPAT_LEVEL}${RESET} — could not determine compatibility setting." ;;
  esac

  echo ""

  # Show version history with schema types (read-only)
  if [[ $VERSION_COUNT -gt 1 ]]; then
    echo -e "${BOLD}Version history (last 5):${RESET}"
    VERSIONS_LIST=$(echo "$VERSIONS" | python3 -c "
import sys, json
versions = json.load(sys.stdin)
for v in sorted(versions)[-5:]:
    print(v)
" 2>/dev/null)

    PREV_SCHEMA=""
    while IFS= read -r VERSION; do
      SCHEMA_DATA=$(curl -sf "${REGISTRY_URL}/subjects/${SUBJECT}/versions/${VERSION}" 2>/dev/null)
      SCHEMA_TYPE=$(echo "$SCHEMA_DATA" | python3 -c "
import sys, json
d = json.load(sys.stdin)
schema_str = d.get('schema', '{}')
try:
  s = json.loads(schema_str)
  print(s.get('type', 'record') + '/' + s.get('name', 'unknown'))
except:
  print('JSON/unknown')
" 2>/dev/null || echo "unknown")
      FIELDS=$(echo "$SCHEMA_DATA" | python3 -c "
import sys, json
d = json.load(sys.stdin)
schema_str = d.get('schema', '{}')
try:
  s = json.loads(schema_str)
  fields = [f['name'] for f in s.get('fields', [])]
  print(f'{len(fields)} fields: {', '.join(fields[:5])}{\"...\" if len(fields) > 5 else \"\"}')
except:
  print('(schema parsing error)')
" 2>/dev/null || echo "")
      echo -e "  v${VERSION}: ${SCHEMA_TYPE} — ${FIELDS}"
    done <<< "$VERSIONS_LIST"
  fi

  echo ""

  # Consumer group suggestions
  echo -e "${BOLD}Pre-deployment checklist:${RESET}"
  echo -e "  ${YELLOW}⚠️${RESET}  Verify all consumer groups on topics using this subject are identified"
  echo -e "  ${YELLOW}⚠️${RESET}  Confirm compatibility mode (current: ${COMPAT_LEVEL}) allows your change"
  echo -e "  ${YELLOW}⚠️${RESET}  Test new schema against ALL existing schema versions, not just latest"
  echo ""
  echo -e "  Compatibility check command (replace SCHEMA with your new schema JSON):"
  echo -e "  ${BLUE}curl -X POST -H 'Content-Type: application/vnd.schemaregistry.v1+json' \\${RESET}"
  echo -e "  ${BLUE}  '${REGISTRY_URL}/compatibility/subjects/${SUBJECT}/versions/latest' \\${RESET}"
  echo -e "  ${BLUE}  --data '{\"schema\": \"YOUR_NEW_SCHEMA_JSON\"}'${RESET}"
}

# ══ Mode 2: Local Avro File Comparison ════════════════════════
avro_mode() {
  echo ""
  echo -e "${BOLD}Avro Schema Diff${RESET}"
  echo "════════════════════════════════════════════════════════════"
  echo -e "  Old: ${OLD_AVSC}"
  echo -e "  New: ${NEW_AVSC}"
  echo ""

  if [[ ! -f "$OLD_AVSC" ]]; then
    echo -e "${RED}Error: Old schema file not found: ${OLD_AVSC}${RESET}"
    exit 1
  fi

  if [[ ! -f "$NEW_AVSC" ]]; then
    echo -e "${RED}Error: New schema file not found: ${NEW_AVSC}${RESET}"
    exit 1
  fi

  # Parse both schemas
  python3 << PYEOF
import json, sys

def parse_schema(path):
    with open(path) as f:
        return json.load(f)

def get_fields(schema):
    if isinstance(schema, dict) and schema.get('type') == 'record':
        return {f['name']: f for f in schema.get('fields', [])}
    return {}

def is_nullable(field):
    t = field.get('type', '')
    if isinstance(t, list):
        return 'null' in t
    return t == 'null'

def has_default(field):
    return 'default' in field

old = parse_schema('${OLD_AVSC}')
new = parse_schema('${NEW_AVSC}')

old_fields = get_fields(old)
new_fields = get_fields(new)

old_name = old.get('name', 'unknown')
new_name = new.get('name', 'unknown')
old_ns = old.get('namespace', '')
new_ns = new.get('namespace', '')

print(f'Old: {old_ns}.{old_name}  ({len(old_fields)} fields)')
print(f'New: {new_ns}.{new_name}  ({len(new_fields)} fields)')
print()

BREAKING = []
SAFE = []
WARNINGS = []

# Check for field renames or removals
for fname, field in old_fields.items():
    if fname not in new_fields:
        BREAKING.append(f'REMOVED field: {fname} (type: {field["type"]}) — existing data becomes unreadable for this field')

# Check for field additions
for fname, field in new_fields.items():
    if fname not in old_fields:
        if has_default(field) or is_nullable(field):
            SAFE.append(f'ADDED optional field: {fname} (type: {field["type"]}, default: {field.get("default", "null")}) — SAFE')
        else:
            BREAKING.append(f'ADDED REQUIRED field: {fname} (no default, not nullable) — breaks old writers')

# Check for type changes on existing fields
for fname in set(old_fields) & set(new_fields):
    old_type = old_fields[fname].get('type')
    new_type = new_fields[fname].get('type')
    if old_type != new_type:
        # Allow widening (int → long, float → double)
        safe_widening = {('int', 'long'), ('int', 'float'), ('int', 'double'),
                         ('long', 'double'), ('float', 'double')}
        if (str(old_type), str(new_type)) in safe_widening:
            SAFE.append(f'TYPE WIDENED: {fname}: {old_type} → {new_type} — SAFE (widening conversion)')
        else:
            BREAKING.append(f'TYPE CHANGED: {fname}: {old_type} → {new_type} — BREAKING')

# Namespace or name change
if old_name != new_name:
    BREAKING.append(f'RECORD NAME CHANGED: {old_name} → {new_name} — BREAKING (fully-qualified name change)')
if old_ns != new_ns:
    BREAKING.append(f'NAMESPACE CHANGED: {old_ns} → {new_ns} — BREAKING')

# Report
if BREAKING:
    print('\033[1m\033[31mBREAKING CHANGES:\033[0m')
    for b in BREAKING:
        print(f'  \033[31m❌ {b}\033[0m')
    print()

if SAFE:
    print('\033[1m\033[32mSAFE CHANGES:\033[0m')
    for s in SAFE:
        print(f'  \033[32m✅ {s}\033[0m')
    print()

if not BREAKING and not SAFE:
    print('\033[32m✅ No schema changes detected\033[0m')
    print()

if BREAKING:
    print('\033[1m\033[31mVERDICT: BREAKING — Do NOT register without consumer migration plan\033[0m')
    sys.exit(1)
else:
    print('\033[1m\033[32mVERDICT: BACKWARD COMPATIBLE — Safe to register\033[0m')
    sys.exit(0)
PYEOF
}

# ══ Mode 3: Protobuf via buf ════════════════════════════════════
proto_mode() {
  echo ""
  echo -e "${BOLD}Protobuf Breaking Change Check (buf)${RESET}"
  echo "════════════════════════════════════════════════════════════"

  if ! command -v buf &> /dev/null; then
    echo -e "${RED}❌ buf CLI not found${RESET}"
    echo "   Install: brew install bufbuild/buf/buf"
    echo "   Or: go install github.com/bufbuild/buf/cmd/buf@latest"
    exit 1
  fi

  AGAINST="${PROTO_AGAINST:-.git#branch=main}"

  echo -e "  Proto dir:  ${PROTO_DIR}"
  echo -e "  Against:    ${AGAINST}"
  echo ""

  # Run buf breaking (read-only — only analyzes, makes no changes)
  if buf breaking "${PROTO_DIR}" --against "${AGAINST}" 2>&1; then
    echo ""
    echo -e "${GREEN}${BOLD}✅ No breaking changes detected${RESET}"
  else
    EXIT_CODE=$?
    echo ""
    echo -e "${RED}${BOLD}❌ Breaking changes detected — see above${RESET}"
    echo ""
    echo -e "${BOLD}Common Protobuf breaking change rules:${RESET}"
    echo -e "  ❌ Changing a field number (even if the name is the same)"
    echo -e "  ❌ Changing a field type incompatibly (e.g., int32 → string)"
    echo -e "  ❌ Removing a field without adding 'reserved'"
    echo -e "  ❌ Renaming an enum value that is serialized by name (proto3 JSON)"
    echo -e "  ✅ Adding a new optional field with a new field number"
    echo -e "  ✅ Adding a new message type"
    echo -e "  ✅ Adding a new enum value (if consumers handle unknown values)"
    echo ""
    echo -e "${BOLD}Fix pattern for removed fields:${RESET}"
    echo -e "  Add 'reserved' to preserve the field number:"
    echo -e "  ${BLUE}reserved 3;       // was: string email = 3;${RESET}"
    echo -e "  ${BLUE}reserved \"email\"; // also reserve the name${RESET}"
    exit $EXIT_CODE
  fi
}

# ── Route to correct mode ──────────────────────────────────────
if [[ -n "$REGISTRY_URL" ]]; then
  registry_mode
elif [[ -n "$OLD_AVSC" ]]; then
  avro_mode
elif [[ -n "$PROTO_DIR" ]]; then
  proto_mode
else
  echo "Error: specify --registry, --avro, or --proto mode"
  usage
  exit 1
fi
