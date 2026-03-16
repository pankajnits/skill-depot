# principal — Staff Engineer & Technical Architect Toolkit

Seventeen workflow skills, sixteen quick-trigger commands, and nine custom analysis scripts for staff engineers and technical architects. Covers the full design-and-operations lifecycle — from initial HLD through scalability reviews, incident response, zero-downtime migrations, and performance auditing — with opinionated, structured workflows grounded in real-world distributed systems practice.

## Skills

| Skill | What it does |
|-------|-------------|
| `/principal:hld` | High Level Design — context, goals, non-goals, system diagram, genuine alternatives with rejection reasoning, cross-cutting concerns, rollout plan |
| `/principal:lld` | Low Level Design — API contracts (REST/gRPC), full DDL with indexes, typed service interfaces, error taxonomy, edge cases inventory, test plan |
| `/principal:adr` | Architecture Decision Record (MADR 4.0) — decision drivers, options with pros/cons, justified outcome, confirmation criteria |
| `/principal:rfc` | RFC Writing & Design Review — write a full RFC or conduct a staff-level review with 7 organizational impact lenses and nemawashi checklist |
| `/principal:scale-review` | Scalability Review — SPOF analysis, thundering herd, cascading failures, chaos engineering verification, capacity math, cost scaling analysis, prioritized remediation |
| `/principal:tech-debt` | Tech Debt Audit — DORA signals, Fowler quadrant classification, blast radius prioritization, economic framing in dollars |
| `/principal:db-review` | Database Design Review — access pattern analysis, index audit, N+1 detection, SQLAlchemy session management, sharding strategy, consistency model, NoSQL fit matrix |
| `/principal:llm-design` | LLM/AI System Design — eval framework, prompt versioning, model routing/fallback tiers with cost math, RAG design, multi-agent architecture |
| `/principal:incident` | Incident Response & Postmortem — severity classification, escalation criteria, diagnostic decision tree, communication templates, Five Whys, blameless action items |
| `/principal:migration` | Zero-Downtime Migration Planning — Strangler Fig, Dual-Write, Blue-Green patterns, phased rollback gates, migration day runbook |
| `/principal:api-design` | API Design & Review — REST contract templates with prefixed IDs, cursor pagination, error taxonomy, rate limiting, versioning strategy |
| `/principal:threat-model` | Security Threat Modeling — data flow with trust boundaries, full STRIDE + Supply Chain analysis, severity matrix, mitigation controls (preventive/detective/corrective), compliance mapping |
| `/principal:perf-audit` | Performance Audit — baseline measurement, flame graph reading guide, vegeta/oha/k6 load testing, database diagnostics, Python GIL/asyncio patterns, anti-pattern detection |
| `/principal:platform-engineering` | Internal Developer Platform Design — platform maturity assessment, golden path design, Backstage developer portal, self-service infra patterns, platform team model |
| `/principal:cloud-design` | Cloud Architecture & FinOps — AWS/GCP/Azure managed vs self-hosted trade-offs, Reserved Instance/Spot/Savings Plan analysis, serverless design, multi-cloud strategy |
| `/principal:frontend-review` | Frontend Principal Review — Core Web Vitals audit, React/Next.js performance patterns, bundle analysis, accessibility (WCAG 2.1 AA), hydration strategy |
| `/principal:debug` | Production Debugging — four modes: distributed (trace-based), memory (heap/OOM), crash (panic/exit), flaky (race conditions/intermittent failures) |

## Commands

Quick-trigger commands for everyday staff engineer tasks:

| Command | What it does |
|---------|-------------|
| `/principal:guide` | "What are you trying to do?" — routes you to the right skill(s) and workflow for your situation |
| `/principal:estimate` | Back-of-envelope estimation — storage, bandwidth, QPS, cost |
| `/principal:tradeoff` | Trade-off analysis between 2–4 technical options with decision criteria |
| `/principal:diagram` | Architecture diagram generation in ASCII + Mermaid |
| `/principal:checklist` | Contextual checklist — launch, deploy, review, or migration readiness |
| `/principal:sla-calc` | SLA/SLO/error budget calculator with composite availability |
| `/principal:complexity` | Time and space complexity analysis with optimization suggestions |
| `/principal:blast-radius` | Assess change impact — affected downstream services, consumers, risk tier |
| `/principal:dep-audit` | Dependency supply chain risk — CVEs, staleness, single-maintainer packages (run `scripts/dep-audit.sh` for actual scan) |
| `/principal:bus-factor` | Code ownership concentration and knowledge silo analysis from git history (run `scripts/bus-factor.sh` for actual scan) |
| `/principal:capacity-calc` | System capacity calculator — RPS, servers, bandwidth, storage, cost |
| `/principal:dora-calc` | DORA metrics benchmarking — classify team performance, identify bottleneck |
| `/principal:runbook-gen` | Generate structured operational runbook for a service and failure mode |
| `/principal:load-test` | Generate production-grade load test script (k6 or vegeta) for an endpoint |
| `/principal:on-call-handoff` | Generate on-call handoff document with recent deploys, risks, and contacts |
| `/principal:feature-flag` | Design a feature flag specification with rollout stages and cleanup plan |

## Custom Scripts

Run directly from your terminal for deeper automated analysis:

| Script | What it does |
|--------|-------------|
| `scripts/bus-factor.sh` | Per-directory ownership concentration from git log — identify knowledge silos (read-only) |
| `scripts/dep-audit.sh` | Wraps npm audit/pip-audit/OWASP with enriched supply chain risk output (read-only) |
| `scripts/api-diff.sh` | Detects breaking API changes between git branches — removed endpoints, field type changes (read-only) |
| `scripts/dead-code.sh` | Finds potentially dead code — unused exports, orphaned files across TypeScript, Python, Java (read-only) |
| `scripts/otel-check.sh` | Validates OpenTelemetry instrumentation — service name, exporter config, trace propagation, auto-instrumentation (read-only) |
| `scripts/schema-registry-diff.sh` | Detects breaking Kafka schema changes between registry versions (read-only) |
| `scripts/secret-scan.sh` | Secret and credential leak detection — uses gitleaks + grep fallback; supports `--git` for full history scan (read-only) |
| `scripts/migration-safety.sh` | Analyzes SQL migration files for zero-downtime safety — 10 rules: table locks, missing CONCURRENTLY, unsafe DROP/RENAME patterns (read-only) |
| `scripts/env-drift.sh` | Detects environment variable drift between `.env.example` and code — catches undocumented vars before deployment fails (read-only) |

## Workflow Chains

Skills chain naturally. Common sequences:

| Goal | Skill sequence |
|------|---------------|
| New service or feature | `hld` → `lld` → `api-design` → `db-review` → `threat-model` → `adr` |
| Quarterly service review | `tech-debt` → `scale-review` → `db-review` → `threat-model` |
| Post-incident | `incident` (POSTMORTEM) → `adr` (decisions made during incident) |
| Database migration | `migration` → `db-review` → run `migration-safety.sh` |
| Cloud cost spike | `cloud-design` → `scale-review` |
| Security review | `threat-model` → run `secret-scan.sh` → `dep-audit` |
| Slow service | `perf-audit` → `db-review` → `debug` |
| Platform investment | `platform-engineering` → `cloud-design` |

Not sure which to use? Run `/principal:guide` first.

## Design Philosophy

- **Read before writing** — every skill reads existing code and architecture before producing a document
- **Alternatives are mandatory** — a design doc without genuine alternatives is a memo
- **Economic framing, not moral framing** — tech debt arguments that win use numbers, not adjectives
- **18-month horizon** — every design considers what you'll wish you'd done differently in 18 months
- **Measure before optimizing** — systems are evaluated against access patterns and real metrics, not abstract best practices
- **Nemawashi before the room** — RFC reviews confirm consensus; they don't discover objections
- **Safe commands only** — all diagnostic commands and scripts are read-only; nothing modifies production state

## Installation

This plugin is part of [pankajnits/skill-depot](https://github.com/pankajnits/skill-depot).

**Via command line:**
```
/plugin marketplace add pankajnits/skill-depot
/plugin install principal@skill-depot
```

**Via Cowork UI:**
1. Click the **Cowork** tab → click **+** → click **Add plugin**
2. Select the **Personal** tab → click **+** → choose **Add marketplace from GitHub**
3. Enter `pankajnits/skill-depot` → confirm
4. Find **principal** → click **Install**

**Via chat `/plugin`:**
1. Type `/plugin` in the chat box → click **Add plugin**
2. Select the **Personal** tab → click **+** → choose **Add marketplace from GitHub**
3. Enter `pankajnits/skill-depot` → confirm
4. Find **principal** → click **Install**

## License

MIT. See [LICENSE](LICENSE).
