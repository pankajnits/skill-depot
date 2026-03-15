#!/usr/bin/env bash
# dep-audit.sh — Dependency supply chain risk audit
# Usage: bash dep-audit.sh [project-path]
# All operations are read-only.

set -euo pipefail

TARGET="${1:-.}"
cd "$TARGET"

echo "=== Dependency Supply Chain Audit ==="
echo "Path: $(pwd)"
echo ""

# Detect ecosystem (supported: node, python, java-maven, java-gradle)
ECOSYSTEM="unknown"
if [ -f "package.json" ]; then
  ECOSYSTEM="node"
elif [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || [ -f "setup.py" ] || [ -f "Pipfile" ]; then
  ECOSYSTEM="python"
elif [ -f "pom.xml" ]; then
  ECOSYSTEM="java-maven"
elif [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
  ECOSYSTEM="java-gradle"
elif [ -f "go.mod" ]; then
  ECOSYSTEM="go"
elif [ -f "Cargo.toml" ]; then
  ECOSYSTEM="rust"
fi

echo "Detected ecosystem: $ECOSYSTEM"
echo ""

# --- Vulnerability Scan ---
echo "--- Vulnerability Scan ---"
case "$ECOSYSTEM" in
  node)
    if command -v npm &>/dev/null; then
      echo "Running npm audit..."
      npm audit --json 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    vulns = data.get('vulnerabilities', {})
    if not vulns:
        print('No known vulnerabilities found.')
    else:
        print(f'Found {len(vulns)} vulnerable packages:')
        print(f'{\"Package\":<30} {\"Severity\":<12} {\"Fix Available\":<15}')
        print('-' * 57)
        for name, info in sorted(vulns.items(), key=lambda x: {'critical':0,'high':1,'moderate':2,'low':3}.get(x[1].get('severity','low'), 4)):
            sev = info.get('severity', 'unknown')
            fix = 'Yes' if info.get('fixAvailable') else 'No'
            print(f'{name:<30} {sev:<12} {fix:<15}')
except:
    print('Could not parse npm audit output.')
" 2>/dev/null || echo "npm audit failed or not available"
    fi
    ;;
  python)
    if command -v pip-audit &>/dev/null; then
      echo "Running pip-audit..."
      pip-audit 2>/dev/null || echo "pip-audit failed"
    elif command -v pip &>/dev/null; then
      echo "pip-audit not installed. Checking outdated packages..."
      pip list --outdated --format=columns 2>/dev/null | head -20
    fi
    ;;
  go)
    if command -v govulncheck &>/dev/null; then
      echo "Running govulncheck (Go vulnerability scanner)..."
      govulncheck ./... 2>/dev/null | head -40 || echo "govulncheck failed"
    else
      echo "govulncheck not installed. Install: go install golang.org/x/vuln/cmd/govulncheck@latest"
    fi
    echo ""
    echo "Checking for outdated Go modules..."
    go list -m -u -json all 2>/dev/null | python3 -c "
import sys, json
updates = []
decoder = json.JSONDecoder()
text = sys.stdin.read()
pos = 0
while pos < len(text):
  try:
    obj, idx = decoder.raw_decode(text, pos)
    if obj.get('Update'):
      updates.append({'module': obj['Path'], 'current': obj['Version'], 'latest': obj['Update']['Version']})
    pos = idx
    while pos < len(text) and text[pos] in ' \n\r\t': pos += 1
  except: break
if updates:
  print(f'Outdated modules: {len(updates)} found')
  for u in sorted(updates, key=lambda x: x['module'])[:20]:
    print(f'  {u["module"]:50s} {u["current"]:15s} -> {u["latest"]}')
else:
  print('All Go modules are up to date')
" 2>/dev/null || echo "Could not check Go module freshness (run inside a Go module directory)"
    ;;
  java-maven)
    echo "Running OWASP Dependency-Check for Maven..."
    if command -v mvn &>/dev/null; then
      mvn --quiet org.owasp:dependency-check-maven:check -DfailBuildOnCVSS=999 2>/dev/null |         grep -E "CVE|CVSS|vulnerability|One or more" | head -30 ||         echo "No vulnerabilities found or dependency-check not configured."
      echo ""
      echo "To add to pom.xml: <dependency-check.maven.plugin>..."
      echo "Full report: target/dependency-check-report.html"
    else
      echo "mvn not found. To check manually:"
      echo "  1. Add OWASP plugin to pom.xml"
      echo "  2. Or use: https://jeremylong.github.io/DependencyCheck/"
    fi
    echo ""
    echo "Checking for outdated Maven dependencies..."
    if command -v mvn &>/dev/null; then
      mvn --quiet versions:display-dependency-updates 2>/dev/null | grep "\->" | head -20 || true
    fi
    ;;
  java-gradle)
    echo "Running OWASP Dependency-Check for Gradle..."
    if [ -f "./gradlew" ]; then
      ./gradlew dependencyCheckAnalyze --quiet 2>/dev/null |         grep -E "CVE|CVSS|vulnerability|One or more" | head -30 ||         echo "No vulnerabilities found or dependency-check not configured."
      echo ""
      echo "Full report: build/reports/dependency-check-report.html"
    else
      echo "gradlew not found. Run: gradle dependencyCheckAnalyze"
      echo "Plugin: https://plugins.gradle.org/plugin/org.owasp.dependencycheck"
    fi
    echo ""
    echo "Checking for outdated Gradle dependencies..."
    if [ -f "./gradlew" ]; then
      ./gradlew dependencyUpdates --quiet 2>/dev/null | grep "The following" -A 30 | head -30 || true
    fi
    ;;
  rust)
    if command -v cargo-audit &>/dev/null; then
      echo "Running cargo audit..."
      cargo audit 2>/dev/null | head -30 || echo "cargo audit failed"
    else
      echo "cargo-audit not installed. Run: cargo install cargo-audit"
    fi
    ;;
  *)
    echo "Unknown ecosystem. Check for package manifests manually."
    echo "Supported: package.json (Node), requirements.txt/pyproject.toml (Python), pom.xml (Maven), build.gradle (Gradle)"
    ;;
esac

echo ""

# --- Freshness Check ---
echo "--- Dependency Freshness ---"
case "$ECOSYSTEM" in
  node)
    echo "Outdated packages:"
    npm outdated 2>/dev/null | head -20 || echo "All packages up to date"
    ;;
  python)
    pip list --outdated --format=columns 2>/dev/null | head -20 || echo "Could not check"
    ;;
  java-maven)
    echo "Checking Maven dependency versions..."
    if command -v mvn &>/dev/null; then
      mvn --quiet versions:display-dependency-updates 2>/dev/null | grep "\->" | head -20 || echo "All dependencies current or versions plugin not configured."
    else
      grep "<version>" pom.xml 2>/dev/null | head -20
    fi
    ;;
  java-gradle)
    echo "Checking Gradle dependency versions..."
    if [ -f "./gradlew" ]; then
      ./gradlew dependencyUpdates --quiet 2>/dev/null | head -30 || echo "ben-manes/versions plugin not configured."
    else
      grep "implementation\|compile\|api" build.gradle 2>/dev/null | head -20
    fi
    ;;
  *)
    echo "Skipped (unknown ecosystem)"
    ;;
esac

echo ""

# --- Dependency Count ---
echo "--- Dependency Count ---"
case "$ECOSYSTEM" in
  node)
    if [ -f "package.json" ]; then
      deps=$(python3 -c "import json; d=json.load(open('package.json')); print(len(d.get('dependencies',{})))" 2>/dev/null || echo "?")
      dev_deps=$(python3 -c "import json; d=json.load(open('package.json')); print(len(d.get('devDependencies',{})))" 2>/dev/null || echo "?")
      echo "Direct dependencies: $deps"
      echo "Dev dependencies: $dev_deps"
      if [ -f "node_modules/.package-lock.json" ] || [ -f "package-lock.json" ]; then
        total=$(python3 -c "import json; d=json.load(open('package-lock.json')); print(len(d.get('packages',d.get('dependencies',{}))))" 2>/dev/null || echo "?")
        echo "Total (including transitive): $total"
      fi
    fi
    ;;
  python)
    if [ -f "requirements.txt" ]; then
      echo "Direct dependencies: $(grep -v '^#\|^$\|^-' requirements.txt | wc -l | tr -d ' ')"
    fi
    ;;
  java-maven|java-gradle)
    if [ -f "pom.xml" ]; then
      dep_count=$(grep -c "<dependency>" pom.xml 2>/dev/null || echo "?")
      echo "Direct dependencies in pom.xml: $dep_count"
    elif [ -f "build.gradle" ]; then
      dep_count=$(grep -cE "implementation|compile|api|testImplementation" build.gradle 2>/dev/null || echo "?")
      echo "Dependency declarations in build.gradle: $dep_count"
    fi
    ;;
  *)
    echo "Skipped"
    ;;
esac

echo ""
echo "--- Audit Complete ---"
echo "Review findings above. For detailed CVE analysis, check:"
echo "  Node.js:  https://security.snyk.io/ | https://npmjs.com/advisories"
echo "  Python:   https://pypi.org/security/ | pip-audit"
echo "  Java:     https://nvd.nist.gov/ | OWASP Dependency-Check"
