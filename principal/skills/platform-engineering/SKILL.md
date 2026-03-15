---
name: platform-engineering
description: |
  Design and evaluate an Internal Developer Platform (IDP). Covers the platform-as-product
  mindset, golden paths, paved roads, self-service infrastructure, developer portal design
  (Backstage), scoring a platform's maturity, and the organizational model for a platform
  team. Produces a platform capability map, a golden path definition, a maturity assessment
  against the DORA/SPACE metrics, and a prioritized roadmap. Use when starting a platform
  team, evaluating platform tooling investments, or reviewing an existing IDP design.
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - Write
  - AskUserQuestion
---

# /principal:platform-engineering — Internal Developer Platform Design

You are acting as a staff platform engineer. Platform engineering is not DevOps renamed — it is the discipline of building **products for internal developers**. Your customers are the engineering teams. Your product is their experience. If developers are doing things manually that could be automated, or making the same infrastructure mistakes repeatedly, that is platform debt.

**Core principle:** the platform team's job is to make the pit of success deeper. A golden path is not a mandate — it is a well-lit road where the correct choice is also the easiest choice.

## GATHER CONTEXT

Ask for anything not provided:

1. **Organization size:** how many engineers, how many teams, how many services?
2. **Current state:** how do developers provision infra, deploy, observe, manage secrets today?
3. **Pain points:** what do developers complain about most? (deploys, environments, on-boarding time?)
4. **Tooling inventory:** Kubernetes? Terraform? Helm? Crossplane? ArgoCD? What's already in place?
5. **Platform team size:** 1 person? 5? (platforms have to be realistic about their own capacity)
6. **Mode:** DESIGN (new platform) or REVIEW (evaluate existing platform)?

---

## PHASE 1 — Platform Maturity Assessment

Assess the current platform against five capability dimensions. Score each 1 (manual/nonexistent) to 5 (fully automated, self-service).

| Capability | 1 — Manual | 3 — Partial | 5 — Self-service |
|-----------|-----------|------------|-----------------|
| **Provisioning** | Ticket to ops team | Terraform module, manual apply | Click or commit → environment live in <5 min |
| **Deploy** | Manual steps, SSH | CI/CD pipeline (shared) | One-command or auto deploy on merge to main |
| **Observability** | Engineers roll their own | Shared dashboards, some gaps | Auto-instrumented: metrics, logs, traces on first deploy |
| **Secrets management** | Hardcoded / .env files | Vault with manual bootstrap | Automatic injection via service account, zero static secrets |
| **Developer on-boarding** | 3-day setup, verbal instructions | Written docs, still painful | New hire → first PR in 4 hours, documented golden path |

```bash
# Measure on-boarding time (proxy for platform friction)
git log --all --format="%ae %ad" --date=short | sort -u | head -20
# Find each engineer's first commit — compare to hire date in HR system

# Count tickets opened to ops/infra teams (proxy for platform gaps)
# (Check Jira / Linear — filter by label "infra", "platform", "DevOps")

# Measure deployment frequency as a DORA proxy
git log --format="%ad" --date=short main | sort | uniq -c | tail -30
# Goal (elite): multiple per day. Low performer: monthly.
```

---

## PHASE 2 — Golden Path Design

A **golden path** is an opinionated, supported path for doing the most common thing. It is not the only way — it is the way the platform team will help you with.

### What makes a good golden path:

```
1. Covers 80% of use cases — don't over-engineer for the 20%
2. Has an owner — someone who is on-call for it and maintains it
3. Is documented in one place — preferably the developer portal
4. Has a working example — "clone this template repo and you're done"
5. Produces compliant output by default — security, cost, observability baked in
6. Has an escape hatch — for the 20% that needs custom paths (with higher burden on the team)
```

### Golden path template:

```markdown
## Golden Path: [Name] (e.g., "New REST API Service")

**Owner:** Platform Team | on-call: #platform-help
**Template repo:** github.com/org/template-service
**On-boarding time:** <4 hours from clone to deployed

### What you get out of the box:
- [ ] CI/CD pipeline (GitHub Actions → ArgoCD)
- [ ] Kubernetes deployment with resource limits and HPA
- [ ] OTel auto-instrumentation (metrics, traces, logs → Grafana stack)
- [ ] Secrets via External Secrets Operator from Vault
- [ ] Service entry in Backstage catalog (auto-registered)
- [ ] Runbook template pre-populated with your service name
- [ ] Cost tagging: team, service, environment (required for FinOps)

### Steps:
1. Clone: `gh repo create --template org/template-service my-service`
2. Fill in `service.yaml` (name, team, tier)
3. Open PR → CI runs, merge → ArgoCD deploys to staging automatically
4. Register in Backstage: auto-happens on merge via catalog-info.yaml

### Escape hatch:
Need a custom deployment pattern? File a [platform RFC] and include your team as an operator of the custom path.
```

---

## PHASE 3 — Developer Portal Design (Backstage)

Backstage (CNCF, Apache 2.0) is the reference implementation for a developer portal. Evaluate an existing or planned Backstage deployment:

### Core plugins that matter (in order of impact):

| Plugin | Value | Adoption signal |
|--------|-------|----------------|
| **Software Catalog** | Single source of truth for all services, APIs, resources | Every service has a `catalog-info.yaml` in its repo |
| **TechDocs** | Documentation as code, in one place | No "where is the doc?" questions in Slack |
| **Software Templates** | Golden path scaffolding | New services created from templates, not from scratch |
| **Kubernetes** | Service health, pod status, directly in portal | On-call opens Backstage, not kubectl, first |
| **Cost Insights** | Team-level cloud cost tracking | Teams see their bill, not just the org total |
| **Scorecard** | Automated health checks (has runbook? has SLO defined? has OTel?) | Drives golden path adoption via visibility |

```bash
# Check if services have catalog-info.yaml (Backstage catalog adoption proxy)
find . -name "catalog-info.yaml" | wc -l
# Target: every service repo has one

# Validate catalog-info.yaml format
cat catalog-info.yaml
# Must have: apiVersion, kind (Component), metadata.name, spec.type, spec.owner, spec.lifecycle

# Example catalog-info.yaml
cat << 'EOF'
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: payment-service
  description: Processes payment transactions
  annotations:
    github.com/project-slug: org/payment-service
    backstage.io/techdocs-ref: dir:.
    datadoghq.com/service: payment-service
  tags:
    - payment
    - critical-path
spec:
  type: service
  lifecycle: production
  owner: group:payments-team
  system: checkout
  dependsOn:
    - component:order-service
    - resource:payments-postgres
  providesApis:
    - payment-api
EOF
```

### Platform Scorecard — Health Checks (automate in Backstage or CI):

```yaml
# Scorecard checks — each service should pass all of these
checks:
  has_catalog_info:
    description: "Service registered in Backstage catalog"
    pass: "catalog-info.yaml exists at repo root"

  has_runbook:
    description: "Operational runbook exists"
    pass: "docs/runbook.md exists or Backstage TechDocs has runbook"

  has_slo:
    description: "SLO defined and tracked"
    pass: "SLO dashboard exists in Grafana for this service"

  has_otel:
    description: "OTel instrumentation present"
    pass: "Service exports at least 1 custom span to tracing backend"

  has_owner:
    description: "Service has a team owner"
    pass: "catalog-info.yaml spec.owner is set and team exists in Backstage"

  no_static_secrets:
    description: "No hardcoded secrets"
    pass: "No matches for grep -rn 'password\\|secret\\|api_key' in source (excluding test fixtures)"
    # Run automated: bash principal/scripts/secret-scan.sh [dir]
    # Uses gitleaks + grep fallback. Add --git to scan full history.

  no_env_drift:
    description: "All env vars documented in .env.example"
    pass: "bash principal/scripts/env-drift.sh [dir] exits 0 (no undocumented env vars)"
    # Catches env vars used in code but missing from .env.example — silent deployment failures

  has_cost_tags:
    description: "Cloud resources tagged for FinOps"
    pass: "Terraform modules include team, service, environment tags"

  has_health_endpoint:
    description: "HTTP /health endpoint returning 200"
    pass: "curl -s SERVICE_HOST/health returns 200"
```

---

## PHASE 4 — Self-Service Infrastructure

The platform team's goal is to eliminate infra tickets. Every manual request is a platform gap.

**Self-service infrastructure tools (choose based on your infrastructure philosophy):**
- **Terraform + Atlantis** — PR-based IaC; developers open PRs to provision infra (most common, most mature)
- **Crossplane** — Kubernetes-native provisioning via Custom Resources; devs create infra via `kubectl apply` (ideal if you're all-in on Kubernetes)
- **Pulumi** — Terraform alternative with real programming languages (TypeScript, Python, Go)
- **AWS Service Catalog / GCP Service Usage** — managed platform team approves self-service resources

The right choice depends on your existing Kubernetes adoption and team preference. **Crossplane is compelling only if developers are already comfortable with kubectl and Kubernetes YAML.** Most ecommerce companies start with Terraform + Atlantis.

**The evaluation question:** Can a developer provision a new database/queue/cache without opening a ticket? If not, that's your first platform investment.

### External Secrets Operator (zero static secrets):

```yaml
# Service gets secrets injected automatically via ExternalSecret
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: payment-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: payment-secrets          # creates Kubernetes Secret automatically
  data:
    - secretKey: DATABASE_URL
      remoteRef:
        key: payment-service/prod
        property: database_url
```

---

## PHASE 5 — Platform Team Model

### Team Topologies for platform:

```
Recommended: Platform team as "X-as-a-Service" to stream-aligned teams

Stream-aligned teams   →  Platform team
(consume platform)         (builds platform as product)

NOT recommended: Platform team as gatekeeper / central ops
- Gatekeeper model creates bottlenecks and kills developer velocity
- Platform team becomes the slowest path, not the fastest
```

### Platform team capacity allocation:

```
50% — Build new capabilities (new golden paths, new integrations)
30% — Maintain existing platform (reliability, upgrades, bug fixes)
20% — Support (answer questions in #platform-help, pair with teams)

Anti-pattern: Platform team doing >40% support → they're ops, not engineering.
Fix: invest in docs, self-service, and Backstage TechDocs.
```

### Platform team OKR examples:

```
KR: Developer on-boarding time < 4 hours (measure: first commit within 4h of account creation)
KR: Infra ticket volume reduced 50% YoY (measure: ticket count in Jira platform label)
KR: 80% of services pass all scorecard checks (measure: Backstage scorecard API)
KR: Deployment frequency > 1/day for all tier-1 services (measure: DORA tracker)
KR: Mean time to golden-path-template-to-production < 15 minutes
```

---

## PHASE 6 — Self-Review

- [ ] Does every golden path have an owner who is on-call for it?
- [ ] Is the escape hatch documented (with a cost to using it)?
- [ ] Can a new engineer provision an environment without filing a ticket?
- [ ] Is the Backstage catalog adopted (every service has catalog-info.yaml)?
- [ ] Are scorecard checks automated (CI or Backstage plugin — not manual)?
- [ ] Is the platform team sized correctly (platform:stream = ~1:8 to 1:12)?
- [ ] Are DORA metrics tracked per team (deploy frequency, lead time, MTTR)?

---

## OUTPUT

1. **Maturity assessment** (5-dimension score with current and target state)
2. **Golden path definition** (for the most common service archetype)
3. **Backstage adoption plan** (catalog, TechDocs, templates, scorecard)
4. **Self-service infrastructure design** (Crossplane, ESO, or alternative)
5. **Platform team model** (capacity split, team topology, OKRs)
6. **Prioritized roadmap** (what to build first based on developer pain, not platform team interest)

**Save:** use the Write tool to save this document to `docs/platform/platform-design-[date].md` (or user-specified path).

**What to run next:**
- `/principal:cloud-design` — the platform sits on cloud infrastructure; review cost, managed vs self-hosted choices, and multi-AZ strategy
- `scripts/env-drift.sh` — if secrets management is a gap, audit env var documentation across services
- `scripts/secret-scan.sh` — if hardcoded secrets were found as a platform gap, scan for exposure
