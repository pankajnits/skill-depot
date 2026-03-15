#!/usr/bin/env bash
# otel-check.sh — OpenTelemetry instrumentation coverage audit
#
# Checks if a codebase has adequate OTel instrumentation:
#   - SDK/library present in dependencies
#   - Tracer initialized in application entry point
#   - Spans created on critical paths (HTTP handlers, DB calls, external calls)
#   - Service name and resource attributes configured
#   - Exporter configured (OTLP, Jaeger, Zipkin)
#
# Usage: ./otel-check.sh [directory]
# Exits 0 if coverage looks adequate, 1 if gaps found.
#
# Read-only: makes no changes to any files.

set -euo pipefail

DIR="${1:-.}"
PASS=0
WARN=0
FAIL=0

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'
BOLD='\033[1m'

pass() { echo -e "${GREEN}✅ PASS${RESET}  $1"; ((PASS++)); }
warn() { echo -e "${YELLOW}⚠️  WARN${RESET}  $1"; ((WARN++)); }
fail() { echo -e "${RED}❌ FAIL${RESET}  $1"; ((FAIL++)); }

echo ""
echo -e "${BOLD}OpenTelemetry Instrumentation Audit: ${DIR}${RESET}"
echo "════════════════════════════════════════════════════════════"
echo ""

# ── Detect language ──────────────────────────────────────────────
HAS_NODE=false
HAS_PYTHON=false
HAS_JAVA=false

[[ -f "$DIR/package.json" ]] && HAS_NODE=true
[[ -f "$DIR/requirements.txt" || -f "$DIR/pyproject.toml" ]] && HAS_PYTHON=true
[[ -f "$DIR/pom.xml" || -f "$DIR/build.gradle" ]] && HAS_JAVA=true

LANGUAGES=()
$HAS_NODE    && LANGUAGES+=("Node.js")
$HAS_PYTHON  && LANGUAGES+=("Python")
$HAS_JAVA    && LANGUAGES+=("Java")

echo -e "${BOLD}Detected languages:${RESET} ${LANGUAGES[*]:-unknown}"
echo ""

# ══ Section 1: SDK / Library Presence ══════════════════════════
echo -e "${BOLD}1. OTel SDK / Library Presence${RESET}"
echo "────────────────────────────────────────"

if $HAS_NODE; then
  if grep -q "@opentelemetry\|opentelemetry-sdk" "$DIR/package.json" 2>/dev/null; then
    pass "Node.js: @opentelemetry/* found in package.json"
    # Check which packages
    OTEL_PKGS=$(grep "@opentelemetry" "$DIR/package.json" 2>/dev/null | wc -l | tr -d ' ')
    echo "         Found ${OTEL_PKGS} @opentelemetry packages"
  else
    fail "Node.js: no @opentelemetry/* packages in package.json"
    echo "         Fix: npm install @opentelemetry/sdk-node @opentelemetry/auto-instrumentations-node"
  fi
fi

if $HAS_PYTHON; then
  PYFILE=""
  [[ -f "$DIR/requirements.txt" ]] && PYFILE="$DIR/requirements.txt"
  [[ -f "$DIR/pyproject.toml" ]] && PYFILE="$DIR/pyproject.toml"
  if grep -qi "opentelemetry" "$PYFILE" 2>/dev/null; then
    pass "Python: opentelemetry found in $(basename "$PYFILE")"
  else
    fail "Python: no opentelemetry in $(basename "$PYFILE")"
    echo "         Fix: pip install opentelemetry-sdk opentelemetry-instrumentation"
  fi
fi

if $HAS_GO; then
  if grep -q "go.opentelemetry.io" "$DIR/go.mod" 2>/dev/null; then
    pass "Go: go.opentelemetry.io found in go.mod"
    GO_OTEL_COUNT=$(grep -c "go.opentelemetry.io" "$DIR/go.mod" 2>/dev/null || echo 0)
    echo "         Found ${GO_OTEL_COUNT} OTel modules"
  else
    fail "Go: go.opentelemetry.io not in go.mod"
    echo "         Fix: go get go.opentelemetry.io/otel go.opentelemetry.io/otel/sdk"
  fi
fi

if $HAS_JAVA; then
  JAVA_OTEL=$(find "$DIR" -name "pom.xml" -o -name "build.gradle" 2>/dev/null | \
    xargs grep -l "opentelemetry\|io.opentelemetry" 2>/dev/null | wc -l | tr -d ' ')
  if [[ $JAVA_OTEL -gt 0 ]]; then
    pass "Java: opentelemetry dependency found in ${JAVA_OTEL} build file(s)"
  else
    fail "Java: no opentelemetry dependency in pom.xml / build.gradle"
    echo "         Fix: add io.opentelemetry:opentelemetry-sdk to dependencies"
  fi
fi

echo ""

# ══ Section 2: Tracer Initialization ══════════════════════════
echo -e "${BOLD}2. Tracer / SDK Initialization${RESET}"
echo "────────────────────────────────────────"

if $HAS_NODE; then
  INIT_FILES=$(grep -rln "NodeSDK\|opentelemetry.*init\|TraceExporter\|OTLPTraceExporter\|JaegerExporter" \
    "$DIR/src" "$DIR/lib" "$DIR" --include="*.ts" --include="*.js" 2>/dev/null | \
    grep -v "node_modules\|\.test\.\|\.spec\." | head -5)
  if [[ -n "$INIT_FILES" ]]; then
    pass "Node.js: OTel SDK initialization found"
    echo "$INIT_FILES" | while read -r f; do echo "         → $f"; done
  else
    fail "Node.js: no OTel SDK initialization found (NodeSDK, OTLPTraceExporter)"
    echo "         Fix: create instrumentation.ts with NodeSDK config, import before app starts"
  fi
fi

if $HAS_PYTHON; then
  INIT_FILES=$(grep -rln "TracerProvider\|configure_once\|opentelemetry.*init\|BatchSpanProcessor" \
    "$DIR" --include="*.py" 2>/dev/null | \
    grep -v "test_\|_test\|venv\|site-packages" | head -5)
  if [[ -n "$INIT_FILES" ]]; then
    pass "Python: TracerProvider / BatchSpanProcessor initialization found"
    echo "$INIT_FILES" | while read -r f; do echo "         → $f"; done
  else
    fail "Python: no TracerProvider initialization found"
    echo "         Fix: call TracerProvider().add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))"
  fi
fi

if $HAS_GO; then
  INIT_FILES=$(grep -rln "sdktrace.NewTracerProvider\|otel.SetTracerProvider\|NewBatchSpanProcessor" \
    "$DIR" --include="*.go" 2>/dev/null | \
    grep -v "_test.go" | head -5)
  if [[ -n "$INIT_FILES" ]]; then
    pass "Go: TracerProvider initialization found"
    echo "$INIT_FILES" | while read -r f; do echo "         → $f"; done
  else
    fail "Go: no sdktrace.NewTracerProvider or otel.SetTracerProvider found"
  fi
fi

echo ""

# ══ Section 3: Service Name Configuration ══════════════════════
echo -e "${BOLD}3. Service Name & Resource Attributes${RESET}"
echo "────────────────────────────────────────"

SERVICE_NAME_PATTERNS="service\.name\|OTEL_SERVICE_NAME\|serviceName.*=\|resource\.NewWithAttributes"
if grep -rn "$SERVICE_NAME_PATTERNS" "$DIR" \
    --include="*.ts" --include="*.js" --include="*.py" \
    --include="*.yaml" --include="*.yml" --include="*.env" 2>/dev/null | \
    grep -v "node_modules" | grep -q .; then
  pass "Service name configuration found"
else
  OTEL_SVC_IN_ENV=$(grep -rn "OTEL_SERVICE_NAME" "$DIR" 2>/dev/null | grep -v "node_modules" | head -3)
  if [[ -n "$OTEL_SVC_IN_ENV" ]]; then
    pass "Service name set via OTEL_SERVICE_NAME environment variable"
  else
    warn "No explicit service.name configuration found"
    echo "         Fix: set OTEL_SERVICE_NAME env var or configure Resource with service.name"
    echo "         Without this, traces appear as 'unknown_service' in your backend"
  fi
fi

echo ""

# ══ Section 4: Exporter Configuration ══════════════════════════
echo -e "${BOLD}4. Exporter Configuration${RESET}"
echo "────────────────────────────────────────"

EXPORTER_PATTERNS="OTLPTraceExporter\|OTLPSpanExporter\|JaegerExporter\|ZipkinExporter\
\|ConsoleSpanExporter\|OTEL_EXPORTER_OTLP_ENDPOINT\|otlptracehttp\|otlptracegrpc"

EXPORTER_FILES=$(grep -rln "$EXPORTER_PATTERNS" "$DIR" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" \
  --include="*.yaml" --include="*.yml" --include="*.env" 2>/dev/null | \
  grep -v "node_modules\|\.test\.\|\.spec\._test" | head -5)

if [[ -n "$EXPORTER_FILES" ]]; then
  pass "Trace exporter configured"
  echo "$EXPORTER_FILES" | while read -r f; do echo "         → $f"; done

  # Warn if only console exporter (not suitable for production)
  if grep -rn "ConsoleSpanExporter" "$DIR" \
      --include="*.ts" --include="*.js" --include="*.py" 2>/dev/null | \
      grep -v "node_modules" | grep -q .; then
    warn "ConsoleSpanExporter detected — only suitable for local development"
    echo "         Production should use OTLPTraceExporter (sending to Jaeger/Tempo/Datadog)"
  fi
else
  fail "No trace exporter configured"
  echo "         Fix: configure OTLPTraceExporter pointing to your collector endpoint"
  echo "         Or set OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318"
fi

echo ""

# ══ Section 5: Span Coverage on Critical Paths ══════════════════
echo -e "${BOLD}5. Span Coverage on Critical Paths${RESET}"
echo "────────────────────────────────────────"

SPAN_CALL_PATTERNS="startSpan\|tracer\.start\|with_span\|span\.set_attribute\|tracer\.start_as_current_span\
\|otel\.trace\.get_current_span\|ctx\.WithValue.*span"

SPAN_CALL_COUNT=$(grep -rn "$SPAN_CALL_PATTERNS" "$DIR" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" 2>/dev/null | \
  grep -v "node_modules\|test\|spec" | wc -l | tr -d ' ')

if [[ $SPAN_CALL_COUNT -gt 20 ]]; then
  pass "Manual span creation found (${SPAN_CALL_COUNT} occurrences) — good coverage"
elif [[ $SPAN_CALL_COUNT -gt 5 ]]; then
  warn "Some manual spans found (${SPAN_CALL_COUNT} occurrences) — may be incomplete"
  echo "         Target: spans on every HTTP handler, DB call, external service call, and queue operation"
elif [[ $SPAN_CALL_COUNT -gt 0 ]]; then
  warn "Very few manual spans (${SPAN_CALL_COUNT}) — relying on auto-instrumentation only"
  echo "         Add custom spans for business-critical operations that aren't covered by auto-instrumentation"
else
  # Check if auto-instrumentation is used (Node.js specific)
  if $HAS_NODE && grep -rn "auto-instrumentations-node\|getNodeAutoInstrumentations" \
      "$DIR" --include="*.ts" --include="*.js" 2>/dev/null | grep -v node_modules | grep -q .; then
    pass "Auto-instrumentation detected (Node.js) — covers HTTP, DB, and common frameworks"
    warn "No custom spans found — add spans for business logic not covered by auto-instrumentation"
  else
    fail "No spans detected (no auto-instrumentation, no manual startSpan calls)"
    echo "         Fix: use auto-instrumentation for HTTP/DB, add manual spans for business logic"
  fi
fi

echo ""

# ══ Section 6: Uninstrumented External Calls ══════════════════
echo -e "${BOLD}6. Potentially Uninstrumented External Calls${RESET}"
echo "────────────────────────────────────────"

EXTERNAL_CALL_PATTERNS="fetch(\|axios\.\|requests\.get\|requests\.post\|httpx\.\|http\.get(\|grpc\.\|amqp\."
EXTERNAL_CALLS=$(grep -rn "$EXTERNAL_CALL_PATTERNS" "$DIR" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" 2>/dev/null | \
  grep -v "node_modules\|test\|spec\|\.d\.ts" | wc -l | tr -d ' ')

SPAN_WRAPPED=$(grep -rn "$EXTERNAL_CALL_PATTERNS" "$DIR" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.go" 2>/dev/null | \
  grep -v "node_modules\|test\|spec" | \
  python3 -c "
import sys
lines = sys.stdin.readlines()
wrapped = sum(1 for l in lines if 'span' in l.lower() or 'trace' in l.lower())
print(wrapped)
" 2>/dev/null || echo 0)

if [[ $EXTERNAL_CALLS -eq 0 ]]; then
  pass "No external HTTP/gRPC calls detected in source"
elif [[ $EXTERNAL_CALLS -gt 0 ]]; then
  if $HAS_NODE && grep -rqn "auto-instrumentations-node\|undici\|http.*instrumentation" \
      "$DIR" --include="*.ts" --include="*.js" 2>/dev/null | grep -v node_modules; then
    pass "${EXTERNAL_CALLS} external calls detected — auto-instrumentation should cover HTTP"
  else
    warn "${EXTERNAL_CALLS} external call sites detected — verify they produce spans"
    echo "         Use auto-instrumentation or wrap each with a span"
    echo "         Uninstrumented external calls = blind spot in your distributed traces"
  fi
fi

echo ""

# ══ Section 7: Kubernetes / Environment Variable Check ══════════
echo -e "${BOLD}7. Environment Variables & Deployment Config${RESET}"
echo "────────────────────────────────────────"

K8S_FILES=$(find "$DIR" -name "*.yaml" -o -name "*.yml" 2>/dev/null | \
  xargs grep -l "OTEL_\|opentelemetry" 2>/dev/null | head -5)

if [[ -n "$K8S_FILES" ]]; then
  pass "OTel environment variables found in deployment manifests"
  echo "$K8S_FILES" | while read -r f; do echo "         → $f"; done

  # Check for OTEL_ENDPOINT
  if grep -rqn "OTEL_EXPORTER_OTLP_ENDPOINT\|OTEL_COLLECTOR" "$DIR" \
      --include="*.yaml" --include="*.yml" --include="*.env" 2>/dev/null; then
    pass "OTLP exporter endpoint configured in deployment"
  else
    warn "No OTEL_EXPORTER_OTLP_ENDPOINT in deployment config — traces may not be exported"
  fi
else
  warn "No OTel environment variables in deployment manifests"
  echo "         Add to your Kubernetes deployment:"
  echo "           - name: OTEL_SERVICE_NAME"
  echo "             value: your-service-name"
  echo "           - name: OTEL_EXPORTER_OTLP_ENDPOINT"
  echo "             value: http://otel-collector:4318"
  echo "           - name: OTEL_RESOURCE_ATTRIBUTES"
  echo "             value: deployment.environment=production,team=your-team"
fi

echo ""

# ══ Summary ════════════════════════════════════════════════════
echo "════════════════════════════════════════════════════════════"
echo -e "${BOLD}Summary${RESET}"
echo -e "  ${GREEN}PASS${RESET}: $PASS"
echo -e "  ${YELLOW}WARN${RESET}: $WARN"
echo -e "  ${RED}FAIL${RESET}: $FAIL"
echo ""

TOTAL=$((PASS + WARN + FAIL))
if [[ $TOTAL -gt 0 ]]; then
  SCORE=$(( (PASS * 100) / TOTAL ))
  echo -e "  Coverage score: ${BOLD}${SCORE}%${RESET}"
  if [[ $SCORE -ge 80 ]]; then
    echo -e "  ${GREEN}Good OTel coverage — distributed traces should be reliable${RESET}"
  elif [[ $SCORE -ge 60 ]]; then
    echo -e "  ${YELLOW}Partial OTel coverage — some blind spots in distributed traces${RESET}"
  else
    echo -e "  ${RED}Insufficient OTel coverage — debugging distributed issues will be difficult${RESET}"
  fi
fi

echo ""
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
