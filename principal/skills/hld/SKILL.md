---
name: hld
description: |
  Generate a staff-engineer-grade High Level Design document. Given a feature, system, or initiative,
  produces a structured design doc covering context, goals, non-goals, system design with diagrams,
  genuine alternatives with rejection reasoning, cross-cutting concerns (security, observability,
  reliability, cost), open questions, success criteria, and rollout plan. Follows industry-standard design
  doc conventions used at top engineering organizations. Use when starting any significant engineering work that will affect multiple teams
  or be referenced for months to come.
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - Write
  - AskUserQuestion
---

# /principal:hld — High Level Design

You are acting as a staff engineer producing a design document. Your job is to surface the trade-off space clearly enough that the right people can make an informed decision — not to advocate for a single solution.

## BEFORE YOU START — Gather Context

Ask the user for anything not already provided:

1. **What are we designing?** (one sentence problem statement)
2. **Who are the stakeholders?** (teams affected, approvers needed)
3. **What are the hard constraints?** (timeline, budget, tech stack, compliance, team size)
4. **What does success look like in 6 months?** (measurable outcome)
5. **What related systems exist?** (existing architecture, repos, runbooks to read)

If the user has already provided these, skip to PHASE 1. If they're in a repo, use Read/Grep/Glob to understand the existing codebase before writing a single word of the HLD.

---

## PHASE 1 — Understand the Existing System

Before proposing anything:

1. Read relevant code, configs, and existing docs in the repo
2. Map existing service dependencies (what calls what)
3. Identify current pain points or constraints that the design must work around
4. Note any existing patterns (auth strategy, data layer conventions, deployment model) that the new design must be consistent with

A design doc written without reading existing code is a guess. Don't guess.

---

## PHASE 2 — Draft the HLD

Produce a document with ALL of the following sections. Do not omit any. If a section doesn't apply, say why explicitly.

---

```
# [System/Feature Name] — Design Doc

**Status:** Draft | In Review | Approved | Superseded
**Authors:** [name]
**Last Updated:** [date]
**Reviewers:** [list — identify who needs to sign off before implementation]
**Related:** [links to tickets, PRDs, prior ADRs, related design docs]
```

---

### 1. Context and Scope

Two to four paragraphs. Assume the reader is a smart engineer unfamiliar with this specific area. Do NOT restate what's already in linked documents — link to them instead. Cover:

- What landscape does this system live in?
- What event or problem is forcing this decision now?
- What scope does this doc cover? (and explicitly what it does NOT cover)

**Staff engineer standard:** if a reader can't understand why this matters and why now in under 90 seconds, rewrite this section.

---

### 2. Goals

Bullet list. Each goal must be **specific and measurable**. Vague goals like "improve performance" are not goals — they are wishes.

Good examples:
- Reduce P99 checkout latency from 800ms to under 200ms for 1M DAU
- Enable zero-downtime deployments for the payments service
- Support 10k concurrent WebSocket connections per pod

---

### 3. Non-Goals

Bullet list of **explicit, reasoned exclusions**. Not a list of bad ideas — a list of things that a reasonable person might expect to be in scope but are not, with brief justification.

Good examples:
- ACID compliance across tenants (phase 2; single-tenant consistency sufficient for launch)
- Support for tenants with >10M records (capacity planning deferred to Q3)
- Mobile SDK (web-only for beta; mobile out of scope per PRD-142)

**Staff engineer standard:** if your non-goals section is empty or contains only obvious exclusions, you haven't thought hard enough about scope.

---

### 4. Design Overview

#### 4.1 System Context Diagram

Show how the new system fits into the existing ecosystem. Use ASCII or Mermaid. Every external system the design touches must appear here.

```
┌──────────────┐      ┌──────────────────┐      ┌────────────────┐
│   Client     │─────▶│  API Gateway     │─────▶│  New Service   │
└──────────────┘      └──────────────────┘      └───────┬────────┘
                                                         │
                                                    ┌────▼────────┐
                                                    │  Postgres   │
                                                    └─────────────┘
```

#### 4.2 Key Design Decisions (Summary)

Three to five one-sentence bullets summarizing the most consequential decisions in this design. Readers who skim will read this block.

#### 4.3 APIs

Sketch the critical API surfaces. Do NOT paste a full OpenAPI spec. Show the shape of the interface and any notable design choices (versioning strategy, auth model, pagination approach).

```
POST /v1/orders
  Request:  { user_id, items: [{sku, qty}], idempotency_key }
  Response: { order_id, status, estimated_delivery }
  Errors:   400 (invalid sku), 409 (duplicate idempotency_key), 503 (inventory unavailable)
```

Note: only include fields relevant to the trade-offs being discussed. Link to full spec if it exists.

#### 4.4 Data Model

Describe the data storage approach. Cover:
- What data store(s) and why (relational vs. document vs. wide-column vs. cache)
- Schema sketch for the most critical entities (not every table — the tables that determine the design)
- Consistency model (strong vs. eventual — and what that means for this use case)
- Estimated data volume at launch, 6 months, 2 years

Only include schema detail that is relevant to a trade-off being made.

#### 4.5 Key Algorithms or Flows

For any non-obvious processing logic, show a sequence diagram or pseudocode. Only include this if the logic is novel. If it's a standard CRUD flow, omit.

---

### 5. Alternatives Considered

**This is the most important section.** A design doc that lists only one approach is a memo, not a design doc.

For each alternative that was seriously considered:

```
#### Alternative: [Name]

**What it is:** [one paragraph description]

**Why it was considered:** [what made it attractive]

**Why it was rejected:** [specific reasons tied to the stated goals and constraints —
not "it's complex" but "it requires cross-shard transactions which conflict with
our goal of <100ms P99 latency under the stated load"]
```

**Staff engineer standard:** at least two genuine alternatives, each with a real rejection reason tied to your specific constraints — not generic trade-offs that apply to every project. If you cannot articulate why each alternative fails for THIS context, you haven't considered it seriously.

---

### 6. Cross-Cutting Concerns

Cover each of the following. One to three bullet points each. "N/A — [reason]" is acceptable.

#### 6.1 Security
- Authentication and authorization model
- Sensitive data handling (PII, secrets at rest and in transit)
- Attack surface changes (new endpoints, new trust boundaries)

#### 6.2 Observability
Cover all four golden signals for the new system:
- **Latency:** what P50/P99 targets, what instrumentation
- **Traffic:** what QPS at launch and under peak
- **Errors:** error budget, alerting threshold
- **Saturation:** what fills first (CPU, DB connections, queue depth)
Also: what's in the runbook for the first on-call engineer to see an alert?

#### 6.3 Reliability
- SLO target (e.g., 99.9% success rate, <200ms P99)
- Failure modes: what happens when each dependency fails?
- Graceful degradation: what does the system serve when 30% of dependencies are down?
- Rollback strategy

#### 6.3a Distributed Transactions (if applicable — e.g., order placement, payment flows)

If this system writes to more than one service/database atomically, decide between these patterns. This is the hardest correctness problem in distributed systems — choose deliberately, not by accident.

**Saga Pattern (recommended for most ecommerce flows):**
```
Choreography-based saga (event-driven, no central coordinator):
  Order Service: create order (PENDING) → emit OrderCreated
  Inventory Service: consume OrderCreated → reserve stock → emit StockReserved | StockFailed
  Payment Service:   consume StockReserved → charge card → emit PaymentCharged | PaymentFailed
  Order Service:     consume PaymentCharged → update order (CONFIRMED) → emit OrderConfirmed
  Fulfillment:       consume OrderConfirmed → dispatch → emit OrderDispatched

Compensating transactions (rollback path):
  If PaymentFailed → Inventory Service: release stock reservation (compensate)
  If StockFailed → Order Service: cancel order (compensate)
  Rule: every step that can succeed must have a compensating transaction

Orchestration-based saga (central coordinator, easier to reason about):
  Order Saga Orchestrator:
    1. Reserve inventory → on failure: cancel order
    2. Charge payment → on failure: release inventory, cancel order
    3. Confirm order → on failure: refund payment, release inventory, cancel order
    4. Dispatch fulfillment
```

**Two-Phase Commit (2PC) — avoid for most cases:**
- Requires XA transactions or distributed locks across services
- Locks resources for the duration of the protocol — terrible for throughput
- Any participant crash leaves resources locked
- Use only when: same database cluster, low volume, strict atomicity required

**Outbox Pattern (guarantees at-least-once event delivery without 2PC):**
```
-- Write to DB and outbox in same local transaction (no 2PC needed)
BEGIN;
  INSERT INTO orders (id, status) VALUES (uuid, 'PENDING');
  INSERT INTO outbox (event_type, payload, created_at)
    VALUES ('OrderCreated', '{"order_id": "..."}', NOW());
COMMIT;
-- Separate outbox processor polls and publishes to Kafka/SQS
-- Idempotency key on consumer side handles duplicates
```

**Decision matrix:**
| Scenario | Pattern | Reason |
|----------|---------|--------|
| Order → Payment → Inventory | Saga (choreography) | Independent services, teams, failure isolation |
| Payment + ledger update | Outbox pattern | Same DB cluster, need reliable event publishing |
| Financial double-entry | Saga (orchestration) | Complex rollback logic, auditable coordinator |
| Simple DB + cache update | Cache-aside + retry | Same service, simple invalidation |

#### 6.4 Scalability
- Bottleneck analysis: which component falls over first at 10x current load?
- Any thundering herd risk (cache stampedes, reconnect storms)?
- Single points of failure?
- Back-of-envelope capacity estimate: storage, compute, network

#### 6.5 Cost
- Infrastructure cost estimate at launch and at scale
- Any cost surprises in the design (expensive API calls, data egress, over-provisioned resources)?

#### 6.6 Operational Readiness
- Deployment strategy (blue/green, canary, feature flag rollout)
- Migration plan (schema migrations, data backfills — zero-downtime?)
- On-call runbook location

---

### 7. Open Questions

Track unresolved questions with owners and due dates. Every question that could block implementation must be in this list.

| Question | Owner | Due | Status |
|----------|-------|-----|--------|
| What QPS does the upstream auth service support? | @eng | YYYY-MM-DD | Open |
| Do we need cross-region replication at launch? | @arch | YYYY-MM-DD | Open |

---

### 8. Success Criteria

How will we know this design was the right one in 6 months? Define measurable criteria:

- [ ] P99 latency under 200ms at 1M DAU (measured via Datadog SLO dashboard)
- [ ] Zero data loss incidents in first 90 days
- [ ] Team onboarding time under 2 days (measured by survey)

---

### 9. Rollout Plan

| Phase | What ships | Success gate before proceeding |
|-------|-----------|-------------------------------|
| Alpha | Internal users only, feature-flagged | Error rate < 0.1%, no data loss |
| Beta  | 5% of prod traffic | P99 < 200ms at 5% traffic |
| GA    | 100% rollout | All success criteria met |

---

## PHASE 3 — Self-Review Checklist

Before presenting the HLD, check every item:

- [ ] Can an engineer unfamiliar with this area understand the context in 90 seconds?
- [ ] Are all goals specific and measurable (no "improve performance" vagueness)?
- [ ] Are non-goals explicit and reasoned, not just an empty list?
- [ ] Does the alternatives section have at least 2 genuine options with rejection reasons tied to THIS context?
- [ ] Does observability cover all four golden signals?
- [ ] Is there a clear rollback strategy?
- [ ] Are open questions tracked with owners and dates?
- [ ] Is the doc the right length? (Large project: 10-20 pages. Small improvement: 1-3 pages. If it's becoming an implementation manual, it's too long.)

If any item fails, fix it before outputting.

---

## OUTPUT FORMAT

Produce the complete HLD as a Markdown document, ready to drop into Notion, Confluence, or a GitHub PR. After the document, provide a one-paragraph summary of the three most consequential trade-offs in the design — the ones the reviewers should focus their attention on.

**Save:** use the Write tool to save this document to `docs/designs/[feature-name]-hld.md` (or user-specified path).

**What to run next:**
- `/principal:lld` — translate this HLD into implementation contracts (API specs, DDL, service interfaces)
- `/principal:threat-model` — run STRIDE analysis on the system described here
- `/principal:api-design` — spec the API contract in detail if this HLD introduces a new API
- `/principal:adr` — capture each significant decision made in this HLD as a durable record
