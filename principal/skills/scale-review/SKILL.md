---
name: scale-review
description: |
  Systematic scalability review of a system, design doc, or codebase. Analyzes traffic
  projections, identifies single points of failure, thundering herd risks, cascading failure
  paths, and capacity planning gaps. Produces back-of-envelope calculations for storage,
  compute, and network. Outputs a prioritized remediation roadmap. Use before a launch,
  after a significant traffic event, or as part of an HLD review. Covers distributed systems,
  cloud infrastructure, databases, caches, and queues.
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - Write
  - AskUserQuestion
---

# /principal:scale-review — Scalability Review

You are acting as a staff engineer conducting a scalability review. Your job is to find the places where the system breaks before production does — and to be specific about blast radius, timeline, and remediation cost.

## GATHER CONTEXT

Ask the user for anything not provided:

1. **What system are we reviewing?** (codebase path, design doc, or description)
2. **Current scale:** DAU, RPS, data volume, number of services
3. **Target scale:** expected load at 6 months and 2 years (or describe the event — product launch, geographic expansion, viral moment)
4. **Known pain points:** what's already slow, flaky, or expensive?
5. **Traffic pattern:** steady state, bursty, time-of-day peaks, write-heavy vs read-heavy?

If in a codebase, read architecture docs, service configs, database schemas, and infra configs before running any analysis.

---

## PHASE 1 — Traffic and Capacity Baseline

### Back-of-Envelope Calculations

Perform the following estimates. Show your work. Round aggressively — the goal is order-of-magnitude accuracy, not precision.

**Traffic estimates:**
```
Daily active users (DAU): [X]
Requests per user per day: [Y]
Total daily requests: X × Y = [Z]
Average RPS: Z / 86,400 = [R]
Peak RPS (apply peak factor):
  - Web/API: peak = R × 3–5
  - Real-time/streaming: peak = R × 5–10
  - Event-driven/batch: peak = R × 10–20
```

**Storage estimates:**
```
Data per user record: [bytes]
Total user data: users × bytes × replication_factor (≥3)
Write rate: [writes/sec] × [bytes/write]
Storage growth per year: write_rate × 86,400 × 365
Cost (hot): volume × $0.02–0.05/GB/month
Cost (cold): volume × $0.004/GB/month
```

**Compute estimates:**
```
App servers: peak_RPS / 5,000 requests_per_server (typical)
DB servers: total_storage / 10 TB per server
Cache hit ratio needed: (target DB RPS) / (current DB capacity)
```

**Apply safety factor:** multiply all capacity estimates by 1.5–2× before provisioning.

---

## PHASE 2 — Single Point of Failure (SPOF) Analysis

Enumerate every component in the system. For each, answer:

| Component | SPOF? | Redundancy | Failover type | RTO if it fails |
|-----------|-------|-----------|--------------|----------------|
| Primary DB | | Active-passive replica? | Manual / Auto | |
| Cache | | Cluster? Read replicas? | | |
| Message queue | | Multi-broker? | | |
| API gateway | | Load balanced? | | |
| Auth service | | Replicated? | | |
| Object storage | | Cross-region? | | |

**Flag immediately:** any component where the answer to "failover type" is "Manual" on a critical path. Manual failover is a SPOF under incident conditions.

**Deployment-time SPOF check:**
- Does any deployment step require downtime?
- Does any schema migration lock tables?
- Do all services restart simultaneously on deploy?

---

## PHASE 3 — Thundering Herd Analysis

Check each of the following patterns in the design or codebase:

**Cache stampede risk:**
- Do multiple cache keys share the same TTL? (Fix: add per-key jitter: `TTL + random(0, 300)`)
- On cache miss, do multiple requests hit the DB simultaneously for the same key? (Fix: request coalescing or distributed lock with early expiry recomputation)
- What is the DB load if the cache goes down entirely? Can the DB sustain it?

**Reconnect storm risk:**
- On service restart, do all clients reconnect simultaneously?
- Does the client SDK use exponential backoff with jitter? (Required: initial 100ms, multiplier 2×, max 5 retries, cap 30s, full jitter)
- Is there a connection pool size limit per downstream service?

**Job/queue flood risk:**
- On queue consumer restart, does it process backlog at maximum concurrency?
- Is there a rate limit on batch job ingestion to avoid write hotspots?
- Does a cron job create a sudden spike at a fixed time?

**Retry amplification:**
- Do upstream services retry on timeout? Does the downstream service also retry?
- Retry multiplier: if 1,000 clients each retry 3×, the downstream sees 4,000 requests at peak, not 1,000
- Is there a retry budget at each layer?

---

## PHASE 4 — Cascading Failure Analysis

For each external dependency (database, cache, queue, downstream service):

**Simulate: what happens when [dependency] is slow (5× normal latency)?**
- Thread pools fill up waiting for responses
- If thread pools fill: new requests queue → queue fills → connection refused → upstream failure
- Is there a timeout on every network call? (No timeout = slow downstream kills the caller)
- Is there a circuit breaker? (Open after N failures, half-open probe after T seconds)

**Simulate: what happens when [dependency] is down?**
- Is there a fallback? (cached response, degraded mode, graceful denial)
- What does the user see? (error page vs. degraded feature vs. stale data)
- Does the system shed load or accept it and queue it?

**Bulkhead check:**
- Are thread pools or connection pools isolated per downstream dependency?
- If Service B is slow, does it exhaust the connection pool that Service C also uses?

**Backpressure check:**
- Does the system have explicit backpressure signaling (HTTP 429, queue depth limit)?
- Does load shedding protect the core user experience?

**Availability math:** if System A calls B calls C synchronously:
```
Availability(chain) = A × B × C
Three 99.9% services = 99.7% availability for the chain
```
Flag any synchronous call chains longer than 2 hops on critical paths.

---

## PHASE 5 — Database Scalability

**Read/write ratio analysis:**
- Estimated reads/sec vs. writes/sec
- Is read scaling needed? (Read replicas, CQRS, cache layer)
- Is write scaling needed? (Sharding, write-optimized storage engine)

**Hot shard / hot partition detection:**
- Does the data model create hotspots? (e.g., shard by user_id but 1% of users have 80% of traffic)
- Are time-series writes all going to the "current" partition?
- Does the shard key distribute load evenly at 10× current load?

**Index scalability:**
- For each index: what is the cardinality? What is the write amplification?
- At target data volume, do table scans still occur on common queries?
- Are there full-text search queries that will be slow at scale? (Postgres full-text doesn't scale like Elasticsearch)

**Connection pool sizing:**
- Max DB connections vs. app server count × pool size per server
- Postgres max_connections is typically 100–200 before connection overhead dominates → use PgBouncer or pgpool at scale

---

## PHASE 5a — Python/Node.js Runtime Scaling Constraints

These are runtime-specific limits that don't show up in architecture diagrams but cause production failures at scale.

### Python: GIL and Worker Model

```bash
# Detect what server is being used (critical — determines scaling model)
grep -rn "uvicorn\|gunicorn\|uwsgi\|flask run\|django.*runserver" \
  --include="*.py" --include="*.sh" --include="*.Dockerfile" . | head -5

# Check worker configuration
grep -rn "workers\|worker_class\|WORKERS\|WEB_CONCURRENCY" \
  --include="*.py" --include="*.sh" --include="*.env" . | head -5
```

**GIL impact decision matrix:**

| Workload type | Worker model | Concurrency |
|---------------|-------------|-------------|
| I/O bound (DB, HTTP calls) | `uvicorn` + `asyncio` | High — thousands of concurrent requests per process |
| I/O bound (sync code) | `gunicorn` with `gevent` or `eventlet` worker | Medium — coroutine-based, no GIL contention |
| CPU bound (ML inference, image processing) | `gunicorn` with `sync` worker, multiple processes | Low — 1 request per worker, scale by process count |
| Mixed | Separate services — don't mix CPU and I/O bound in same process | — |

**Background task workers (Celery/BullMQ/Spring @Async) — concept-level checks:**

```bash
# Are CPU-bound and I/O-bound tasks on separate queues/workers?
grep -rn "queue\|routing_key\|CELERY_ROUTES\|task_routes\|@Async\|BullModule" --include="*.py" --include="*.java" --include="*.ts" . | head -10
# Key principle: CPU-bound (ML, PDF, image processing) must not share a worker pool with I/O-bound tasks
# — one slow CPU task blocks all I/O tasks in the same pool

# Check for task result backends — are they needed?
grep -rn "result_backend\|CELERY_RESULT_BACKEND" --include="*.py" . | head -5
# If tasks don't return results, disable the result backend — significant Redis write reduction

# Check acknowledgment strategy for critical tasks
grep -rn "acks_late\|task_acks_late\|CELERY_ACKS_LATE" --include="*.py" . | head -5
# Payment/order tasks: acks_late=True ensures at-least-once delivery (correct)
# Report/analytics tasks: acks_late=False is fine (idempotency not needed)
```

**Concepts to verify for any background job system:**
- Pass IDs to tasks, not large objects (images, DataFrames) — message size limits exist
- Periodic schedulers (Celery beat, cron) are single points of failure — are they HA?
- Does task failure alert (not just log)? Failed payment processing tasks must not silently drop

### Node.js: Event Loop Saturation

```bash
# Check if CPU-heavy work is blocking the event loop
grep -rn "JSON\.parse\|JSON\.stringify\|crypto\.\|bcrypt\." --include="*.ts" --include="*.js" src/ | \
  grep -v "async\|worker_threads\|child_process" | head -10
# bcrypt is CPU-heavy — must use worker_threads or child_process

# Check event loop lag monitoring (should be instrumented)
grep -rn "eventLoopDelay\|event.*loop.*lag\|eventLoopUtilization" --include="*.ts" . | head -5
# If not monitored: blind to most common Node.js scaling failure

# Check worker_threads usage for CPU-bound work
grep -rn "worker_threads\|WorkerPool\|piscina" --include="*.ts" . | head -5
# piscina = production-grade thread pool for Node.js — strongly preferred over manual worker_threads
```

---

## PHASE 5b — Cost Scaling Analysis

**Does cost scale linearly, sublinearly, or superlinearly with load?**

| Component | Scaling behavior | Risk at 10× |
|-----------|-----------------|-------------|
| Compute (app servers) | Linear if stateless, superlinear if shared state | |
| Database (managed) | Superlinear — vertical scaling has a price cliff | |
| Egress bandwidth | Linear with traffic | |
| Cache (managed) | Step function — jumps at node size thresholds | |
| Third-party APIs | Per-call pricing — linear but can dominate costs | |
| Logging/observability | Often superlinear — log volume × retention | |

**Cost projection:**
```
Current monthly cost:     $[X]
At 3× load (6 months):   $[Y] — scaling factor: [Y/X]
At 10× load (2 years):   $[Z] — scaling factor: [Z/X]
```

If scaling factor > load factor → cost scales **superlinearly** → flag for architecture review.

**Common cost traps at scale:**
- Cross-AZ data transfer charges (hidden but significant)
- NAT gateway costs with many outbound connections
- Log storage growing faster than traffic (verbose logging in hot paths)
- Managed database pricing tiers with 5× price jumps between t-shirt sizes

**Geo-distributed latency (if multi-region or global):**
```
Reference latencies:
  Same region: ~1ms
  Cross-region (same continent): ~30–70ms
  Cross-continent: ~100–200ms
  Cross-ocean: ~200–300ms
```

If the system is or will be multi-region:
- Is data replicated across regions? What consistency model? (Async replication = stale reads)
- Is there a primary region for writes? (Write-anywhere is expensive and complex)
- Are users routed to the nearest region? (DNS-based, anycast, or CDN)
- What happens during a regional failover? (Is there a tested procedure?)

## PHASE 6 — Chaos Engineering Verification

Identifying risks on paper is necessary but insufficient. Verify critical findings with controlled fault injection:

**Principle:** if you haven't tested the failure mode, your mitigation is a hypothesis, not a control.

**Safe verification patterns (read-only investigation first):**

```bash
# Check if chaos engineering tooling is already in place
grep -rn "chaos\|litmus\|gremlin\|toxiproxy\|fault.inject" --include="*.yaml" --include="*.json" --include="*.toml" . | head -10

# Check for circuit breaker configuration
grep -rn "circuit.breaker\|CircuitBreaker\|hystrix\|resilience4j\|polly" --include="*.ts" --include="*.py" --include="*.java" . | head -10

# Check for timeout configuration on every network call
grep -rn "timeout\|Timeout\|TIMEOUT" --include="*.ts" --include="*.py" --include="*.java" --include="*.yaml" . | grep -v node_modules | head -15
```

**Chaos experiment template (for each SPOF found in Phase 2):**
```
Experiment: [name]
Hypothesis: "When [failure condition], the system [expected behavior]"
Blast radius: [which components affected]
Abort condition: [when to stop — e.g., error rate > 5%]
Duration: [how long to run]
Verification: [what metrics to watch]
Rollback: [how to undo the fault injection]
```

**Controlled fault injection tools (all require explicit user permission):**
| Tool | What it does | Safe for production? |
|------|-------------|---------------------|
| toxiproxy | Network proxy — inject latency, partition, bandwidth limits | ✅ Proxy-based, removable |
| stress-ng | CPU/memory/IO stress | ⚠️ Use on staging only |
| tc (traffic control) | Linux network delay/loss simulation | ⚠️ Requires root, reversible |
| Litmus (k8s) | Declarative chaos experiments for Kubernetes | ✅ With abort conditions |

**Prioritize experiments by SPOF findings from Phase 2.** Start with the single highest-blast-radius SPOF. Never run chaos experiments without:
1. Explicit user/team permission
2. Monitoring dashboards open
3. A one-command abort procedure

---

## PHASE 7 — Observability Gaps

The four golden signals must be covered for EVERY service in scope:

| Service | Latency P99 | Traffic (RPS) | Error rate | Saturation signal |
|---------|------------|--------------|-----------|------------------|
| [Service] | | | | |

**Alerting check:**
- Is there an alert before the SLO is breached (not just when it's already broken)?
- Are alerts actionable? (Does the runbook exist? Is it current?)

**Capacity alerting:**
- Is there an alert at 70% of max capacity? (Not 90% — you need time to act)
- Is there an alert if a cache hit rate drops below threshold?

---

## PHASE 8 — Prioritized Findings

Organize all findings into a remediation roadmap:

### 🔴 Critical — Fix Before Launch (or immediately if live)
Issues where the system will fail at [target scale] or where blast radius is company-wide.

| Finding | Impact | Blast radius | Effort | Recommended fix |
|---------|--------|-------------|--------|----------------|
| | | | | |

### 🟡 High — Fix Within 30 Days
Issues that will cause incidents at scale but won't immediately block launch.

| Finding | Impact | Trigger condition | Effort | Recommended fix |
|---------|--------|-----------------|--------|----------------|
| | | | | |

### 🟢 Medium — Next Quarter
Design improvements that improve resilience or reduce operational burden.

| Finding | Impact | Effort | Recommended fix |
|---------|--------|--------|----------------|
| | | | |

---

## PHASE 9 — Self-Review

Before outputting:

- [ ] Are all back-of-envelope calculations shown (not just conclusions)?
- [ ] Is every SPOF listed with its actual RTO, not a theoretical one?
- [ ] Is every thundering herd risk tied to specific code or design patterns?
- [ ] Is the cascading failure analysis specific to this system's dependency graph?
- [ ] Are all critical findings genuinely critical (not just nice-to-have)?
- [ ] Is the remediation roadmap ordered by blast radius, not effort?

---

## OUTPUT

1. **Executive summary** (3 bullets: biggest risk, timeline to hit the wall at current trajectory, one-line recommendation)
2. **Findings by phase** (detailed analysis)
3. **Prioritized remediation table** (Critical / High / Medium)
4. **Capacity projection** (table: current, 6-month, 2-year load with resource needs)

**Save:** use the Write tool to save this document to `docs/reviews/scale-review-[service]-[date].md` (or user-specified path).

**What to run next:**
- `/principal:db-review` — if database scalability was the primary bottleneck
- `/principal:cloud-design` — if the review revealed cost-scaling issues or infrastructure redesign needs
- `/principal:perf-audit` — if the capacity math showed headroom exists but latency is already degraded
- `/principal:adr` — capture the architectural decisions required to address Critical findings
