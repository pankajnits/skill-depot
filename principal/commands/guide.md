---
---
description: "What are you trying to do?" — routes you to the right skill(s) and workflow for your situation
---

Given the situation described in $ARGUMENTS (or ask if empty):

If $ARGUMENTS is empty, ask: "What are you working on right now?" and present these common scenarios:

1. Designing something new
2. Reviewing something existing
3. Dealing with an incident or outage
4. Performance or scaling problem
5. Security review
6. Technical debt or quarterly review
7. Migration or breaking change
8. Quick calculation or trade-off

---

Based on the user's situation, route them using the following map. Be direct — give the exact command(s) to run and in what order.

## Routing Map

### "I'm designing a new service / feature / system"

**Start here:** `/principal:hld` — high level design first
**Then:** `/principal:lld` — implementation contracts
**Then:** `/principal:api-design` — API spec if there's an external interface
**Then:** `/principal:db-review` — validate the data model
**Then:** `/principal:threat-model` — security analysis before launch
**Finally:** `/principal:adr` — record key decisions made during design

---

### "I'm reviewing an existing service / codebase"

**For quarterly review or before a major release:**
- `/principal:tech-debt` — full debt audit with economic framing (start here)
- `/principal:scale-review` — can it handle 3× current load?
- `/principal:db-review` — schema, index, and query patterns
- `/principal:threat-model` — STRIDE security analysis

**For a specific kind of review:**
- API consistency or breaking changes → `/principal:api-design` (REVIEW mode)
- Database / schema → `/principal:db-review`
- Frontend performance → `/principal:frontend-review`
- Security / secrets → `/principal:threat-model` + run `bash scripts/secret-scan.sh`
- Dependencies / CVEs → `/principal:dep-audit` + run `bash scripts/dep-audit.sh`

---

### "Something is broken right now (active incident)"

**Immediately:** `/principal:incident RESPOND` — start the incident timeline, get severity classification and diagnostic commands
**After resolution:** `/principal:incident POSTMORTEM` — blameless postmortem and action items
**After postmortem:** `/principal:adr` — record architecture decisions made under fire

**For specific debugging (not SEV-level):**
- Service returning errors or 5xx → `/principal:debug` (DISTRIBUTED mode)
- Memory leak or OOM → `/principal:debug` (MEMORY mode)
- Crash or panic on startup → `/principal:debug` (CRASH mode)
- Intermittent failures / race conditions → `/principal:debug` (FLAKY mode)

---

### "The service is slow / performance is degraded"

**Start here:** `/principal:perf-audit` — baseline measurement, latency breakdown, anti-pattern detection
**If DB queries are the bottleneck:** `/principal:db-review`
**If it's a scaling architecture problem (not code-level):** `/principal:scale-review`
**Scripts that help:**
- `bash scripts/otel-check.sh` — verify tracing is in place to diagnose the problem

---

### "We need a security review"

**Full threat model:** `/principal:threat-model` — STRIDE analysis with data flow diagram
**Automated scans to run first:**
```bash
bash principal/scripts/secret-scan.sh .          # Find leaked secrets/credentials
bash principal/scripts/dep-audit.sh .            # Find CVEs in dependencies
bash principal/scripts/env-drift.sh .            # Find undocumented env vars
```
**After scanning:** `/principal:adr` — record security decisions

---

### "We have technical debt / need sprint capacity for debt"

**Start here:** `/principal:tech-debt` — full audit with Fowler quadrant + economic framing (dollar cost per week)
**For specific debt categories found:**
- Performance debt → `/principal:perf-audit`
- Scalability debt → `/principal:scale-review`
- Database debt → `/principal:db-review`
- Dependency / CVE debt → run `bash scripts/dep-audit.sh`
- Dead code debt → run `bash scripts/dead-code.sh`

---

### "We're doing a migration / breaking change"

**Migration planning:** `/principal:migration` — Strangler Fig, Dual-Write, or Blue-Green pattern
**SQL schema changes:** run `bash principal/scripts/migration-safety.sh [dir]` before applying
**API changes:** `/principal:api-design` (REVIEW mode) — backward compatibility analysis
**After migration plan:** `/principal:adr` — record the migration pattern decision

---

### "I need to write a design doc / RFC / ADR"

| Document | When to use | Command |
|---------|------------|---------|
| HLD | Designing a system, needs stakeholder alignment | `/principal:hld` |
| LLD | Implementation blueprint after HLD is approved | `/principal:lld` |
| ADR | Recording a specific decision with confirmation criteria | `/principal:adr` |
| RFC | Proposing a change that needs org-wide review | `/principal:rfc` |

Use `/principal:adr` when: a single decision needs to be recorded.
Use `/principal:hld` when: a whole system needs to be designed.
Use `/principal:rfc` when: the change affects multiple teams and needs buy-in before execution.

---

### "Quick calculation / trade-off / everyday task"

| Task | Command |
|------|---------|
| Compare 2–4 options | `/principal:tradeoff [Option A vs Option B vs Option C]` |
| Estimate storage/RPS/cost | `/principal:estimate [describe the system]` |
| SLA/SLO/error budget | `/principal:sla-calc [uptime target and dependencies]` |
| Capacity planning math | `/principal:capacity-calc [DAU, request size, peak multiplier]` |
| DORA metrics classification | `/principal:dora-calc [deploy frequency, lead time, CFR, MTTR]` |
| Draw an architecture diagram | `/principal:diagram [describe the system]` |
| Generate a load test script | `/principal:load-test [endpoint URL and requirements]` |
| Generate an on-call handoff | `/principal:on-call-handoff [service name]` |
| Generate a runbook | `/principal:runbook-gen [service name and failure mode]` |
| Design a feature flag | `/principal:feature-flag [feature description]` |
| Assess blast radius of a change | `/principal:blast-radius [describe the change]` |
| Algorithm complexity analysis | `/principal:complexity [describe or paste the code]` |
| Generate a launch/deploy checklist | `/principal:checklist [launch or deploy or migration]` |

---

### "Cloud cost or infrastructure"

**Start here:** `/principal:cloud-design` — FinOps analysis, managed vs self-hosted, multi-AZ reliability
**For platform / developer experience:** `/principal:platform-engineering` — IDP maturity, golden paths, Backstage
**If building from scratch:** `/principal:hld` first, then `cloud-design` for infrastructure decisions

---

### "LLM / AI feature or system"

**Start here:** `/principal:llm-design` — eval framework, model routing, cost projection, RAG design, observability
**Then:** `/principal:api-design` — design the LLM-powered endpoint contract
**Then:** `/principal:scale-review` — LLM systems have non-linear cost and latency at scale

---

After routing, tell the user:
- The exact command to run first
- What to provide as input (or whether to be in the repo when running it)
- What comes next in the workflow

---
