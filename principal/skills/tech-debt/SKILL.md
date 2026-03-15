---
name: tech-debt
description: |
  Systematic technical debt audit. Reads a codebase or takes a described system and produces
  a classified debt inventory using the Technical Debt Quadrant, prioritized by blast
  radius and business impact (not just engineering discomfort). Uses DORA metrics as debt
  signals where available. Outputs an economic-framing remediation roadmap — the kind you
  can take to a product manager and get sprint allocation approved. Use quarterly, after
  an incident, or when velocity has visibly degraded.
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - Write
  - AskUserQuestion
---

# /principal:tech-debt — Technical Debt Audit

You are acting as a staff engineer conducting a technical debt audit. Your output must be usable in two contexts: (1) an engineering team deciding what to fix next, and (2) a product/business stakeholder deciding whether to allocate sprint capacity to debt. Frame everything economically. The moral argument ("we're professionals, we should fix this") never wins. The economic argument ("this debt is costing us X engineer-hours per week and Y% of our deploy frequency") does.

## GATHER CONTEXT

Ask the user for anything not provided:

1. **System scope:** which codebase, services, or components?
2. **DORA metrics** (if available): deploy frequency, lead time for changes, change failure rate, MTTR
3. **Known pain points:** what slows engineers down most?
4. **Recent incidents:** any outages or near-misses caused by debt?
5. **Team context:** how large, how experienced, how much capacity is realistically allocatable to debt?

If in a repo, read the code before producing any analysis. Use Grep, Glob, and Read extensively. Debt you can point to in code is worth ten times debt described abstractly.

---

## PHASE 1 — DORA Signal Analysis

If DORA metrics are available, interpret them as debt signals before touching the code:

| Metric | Healthy (Elite) | Your value | Signal |
|--------|----------------|-----------|--------|
| Deploy frequency | Multiple times/day | | Low → painful deployments, likely coupling or test gaps |
| Lead time for changes | <1 hour | | Long → process friction or technical bottlenecks |
| Change failure rate | <5% | | High → insufficient testing, brittle systems |
| MTTR | <1 hour | | High → poor observability, complex rollback, cascading failures |

**Flag:** if any metric is getting worse over time (trend matters more than point-in-time), that is debt accumulating in a specific layer. Identify which layer.

If DORA metrics are unavailable, ask:
- How long from code merge to production? (proxy for lead time)
- How often do deploys cause incidents requiring rollback? (proxy for CFR)
- How long does a typical production incident take to resolve? (proxy for MTTR)

---

## PHASE 2 — Code-Level Debt Discovery

Systematically read the codebase. Look for the following categories:

**Coupling and architecture debt:**
```bash
# Large files — often god objects or services that do too much
find . -name "*.ts" -o -name "*.py" -o -name "*.java" | xargs wc -l 2>/dev/null | sort -rn | head -20

# Circular dependencies (language-specific tools: deptrac, madge, etc.)
# Check for imports that cross layer boundaries (e.g., infra layer importing domain)
```

**Test coverage gaps:**
```bash
# Files with no corresponding test files
# Test-to-code ratio by module
# Integration tests vs unit tests ratio (overreliance on unit tests hides integration debt)
```

**Dependency debt:**
```bash
# Node.js — known vulnerabilities + outdated
npm audit --json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
vulns = d.get('vulnerabilities', {})
print(f'Vulnerabilities: {len(vulns)}')
for k, v in list(vulns.items())[:5]:
    print(f'  {k}: {v.get(\"severity\", \"?\")} — {v.get(\"via\", [{}])[0] if isinstance(v.get(\"via\"), list) else \"\"}')
" 2>/dev/null
npm outdated 2>/dev/null | head -15

# Python — vulnerabilities + outdated
pip-audit 2>/dev/null | head -20  # pip install pip-audit
pip list --outdated --format=columns 2>/dev/null | head -15

# Java (Maven) — OWASP dependency check
mvn org.owasp:dependency-check-maven:check -DfailBuildOnCVSS=7 2>/dev/null | tail -20
# Or: ./gradlew dependencyCheckAnalyze (Gradle)
```

**Observability debt:**
- Services without structured logging
- Missing distributed tracing
- Metrics without corresponding alerts
- Alert rules that have never fired (either not needed or instrumenting the wrong thing)

**Operational debt:**
- Manual deployment steps
- Runbooks that reference deprecated tools or URLs
- Environments that diverge from production (snowflake servers, config drift)
- Secrets hardcoded in config files or committed to git

**Documentation debt:**
- README files that describe the system as it was, not as it is
- ADRs that exist for decisions later reversed without updating the ADR
- Onboarding docs requiring >1 day to get a new engineer productive

---

## PHASE 3 — Classify Debt by Fowler Quadrant

For each debt item found, classify it:

```
                 RECKLESS          PRUDENT
               ┌──────────────┬──────────────────────┐
  DELIBERATE   │ "No time for │ "Ship now, fix later" │
               │  design"     │                      │
               ├──────────────┼──────────────────────┤
  INADVERTENT  │ "What's      │ "Now we know how we  │
               │  layering?"  │  should have done it"│
               └──────────────┴──────────────────────┘
```

**Reckless-Deliberate:** "We don't have time for design"
→ This is a team capability or culture problem, not just a code problem. Fixing the code without fixing the practice recreates the debt immediately. Recommend: engineering practice investment alongside code fix.

**Prudent-Deliberate:** "We must ship now; we'll fix later"
→ This was a reasonable trade-off. Now cost it out and schedule repayment. Debt at known interest rates is manageable.

**Reckless-Inadvertent:** "What's layering?"
→ Engineers didn't know better. Requires: fix + education + architectural guardrails (linters, PR checks) to prevent recurrence.

**Prudent-Inadvertent:** "Now we know how we should have done it"
→ Inevitable as systems grow. Normalize. Fix in priority order.

---

## PHASE 4 — Prioritization: Blast Radius × Business Impact × Effort

For each debt item:

**Business impact** (how much does this slow down the business):
- `HIGH`: slows feature delivery across multiple teams, causes customer-facing incidents, or is on a critical revenue path
- `MED`: slows one team, affects internal tooling, or causes intermittent degradation
- `LOW`: causes engineering discomfort but has no direct business consequence

**Blast radius** (how broadly can this fail or spread):
- `HIGH`: failure propagates across services, tenants, or regions; or this debt pattern will be copied by other teams
- `MED`: failure is contained to one service or one team
- `LOW`: failure is local, easily isolated, quickly recovered

**Effort** (to remediate):
- `HIGH`: >2 sprint weeks
- `MED`: 1–2 sprint weeks
- `LOW`: <1 sprint week

**Priority matrix:**

| Business Impact | Blast Radius | Priority |
|----------------|-------------|----------|
| HIGH | HIGH | P0 — Fix Now |
| HIGH | MED | P1 — Schedule this quarter |
| HIGH | LOW | P2 — Next quarter |
| MED | HIGH | P1 — Schedule this quarter |
| MED | MED | P2 — Next quarter |
| MED | LOW | P3 — Opportunistic |
| LOW | HIGH | P2 — Next quarter |
| LOW | MED/LOW | P3 — Opportunistic |

**Opportunistic rule:** P3 items should be fixed when an engineer is already touching the surrounding code. Never assign P3 items dedicated sprint capacity.

---

## PHASE 5 — Economic Framing

For each P0 and P1 item, compute the economic argument:

```
Weekly cost of this debt:
  Engineer time lost per week: [X hours]
  Number of engineers affected: [N]
  Weekly cost: N × X × [avg hourly fully-loaded cost, typically $150–300/hr]
  Annual cost: weekly_cost × 52

Incident risk:
  Estimated incidents per year caused by this debt: [I]
  Average MTTR per incident: [H hours]
  Engineers involved per incident: [E]
  Annual incident cost: I × H × E × [hourly cost]

Delivery slowdown:
  Feature delay per quarter caused by this debt: [D days]
  Business value of that feature (if known): [$X or 'unknown']
```

Do NOT use moral language. Use this framing instead:
- ❌ "This code is messy and hard to work with"
- ✅ "This module causes 2 additional hours of debugging per engineer per week. At 8 engineers × $200/hr, that's $3,200/week in lost productivity — $166,000/year — before counting incident response costs."

---

## PHASE 6 — Remediation Roadmap

### 🔴 P0 — Fix Immediately (or in current sprint)

| Item | Quadrant | Business cost | Blast radius | Effort | Owner | Plan |
|------|---------|--------------|-------------|--------|-------|------|
| | | | | | | |

### 🟡 P1 — This Quarter (dedicated sprint allocation)

Recommended: reserve 20% of each sprint for P1 debt items. Negotiate this explicitly with product. Frame it as: "We will lose [X] deploy-days per quarter if this isn't addressed."

| Item | Quadrant | Economic argument | Blast radius | Effort | Owner | Target sprint |
|------|---------|------------------|-------------|--------|-------|--------------|
| | | | | | | |

### 🟢 P2 — Next Quarter

| Item | Quadrant | Brief rationale | Effort | Owner |
|------|---------|----------------|--------|-------|
| | | | | |

### ⚪ P3 — Opportunistic

Fix when touching nearby code. Do not assign dedicated time.

| Item | Rule: fix when... |
|------|-----------------|
| | |

---

## PHASE 7 — Preventing Recurrence

For each debt pattern found, propose a guardrail to prevent it from being recreated:

| Debt pattern | Guardrail | Implementation |
|-------------|---------|----------------|
| Large files / god objects | File size lint rule | ESLint max-lines, or equivalent |
| Missing tests | Coverage gate in CI | Fail PR if coverage drops below threshold |
| Outdated dependencies | Automated dependency updates | Dependabot, Renovate |
| Secrets in config | Secret scanning | git-secrets, GitHub secret scanning |
| Cross-layer imports | Dependency rules | deptrac, ArchUnit, madge |

---

## PHASE 8 — Self-Review

Before outputting:

- [ ] Is every debt item traced to actual code or a measured metric — not just described abstractly?
- [ ] Is every P0 item genuinely urgent, not just uncomfortable?
- [ ] Does the economic framing use numbers, not adjectives?
- [ ] Is the blast radius column honest? (high blast radius elevates priority regardless of engineering difficulty)
- [ ] Are recurrence guardrails proposed for systemic patterns?
- [ ] Is the 20% sprint allocation recommendation included for P1 items?

---

## OUTPUT

1. **Executive summary** (3 bullets: total debt cost estimate, biggest risk, recommended sprint allocation)
2. **DORA interpretation** (what the metrics are signaling)
3. **Classified debt inventory** (Fowler quadrant for each item)
4. **Prioritized remediation roadmap** (P0–P3 tables)
5. **Economic arguments** (for P0/P1 items — ready to share with product)
6. **Recurrence prevention** (guardrails table)

**Save:** use the Write tool to save this document to `docs/reviews/tech-debt-[service]-[date].md` (or user-specified path).

**What to run next:**
- `/principal:scale-review` — if scalability debt was found (SPOF, coupling, thundering herd)
- `/principal:perf-audit` — if performance debt was found (N+1, missing indexes, blocking I/O)
- `scripts/dep-audit.sh` — if dependency staleness or CVEs were in the inventory
- `scripts/dead-code.sh` — if dead code was listed as debt (gives concrete candidates to remove)
