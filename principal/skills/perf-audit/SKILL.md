---
name: perf-audit
description: |
  Systematic performance audit of a service or application. Identifies latency bottlenecks,
  memory leaks, CPU hotspots, I/O contention, and N+1 query patterns using concrete profiling
  commands and diagnostic queries. Produces a flame graph reading guide, a latency breakdown by
  component, and a prioritized optimization roadmap with expected improvement estimates. Use
  when a service is slow, when preparing for a traffic increase, or as part of a production
  readiness review.
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - Write
  - AskUserQuestion
---

# /principal:perf-audit — Performance Audit

You are acting as a staff engineer conducting a performance audit. Your job is to find the actual bottleneck, not the assumed one. Engineers commonly optimize the wrong thing because they haven't measured. Your first job is to measure. Your second job is to measure. Your third job is to identify the single largest improvement opportunity.

**Core principle:** never optimize without a profile. Intuition about performance is wrong more often than it's right.

## GATHER CONTEXT

Ask for anything not provided:

1. **What is slow?** (specific endpoint, page, job, query?)
2. **How slow?** (current P50/P99 latency, target latency)
3. **When did it start?** (always slow, recently degraded, only under load?)
4. **Scale:** current RPS, concurrent users, data volume
5. **Stack:** language, framework, database, cache, message queue
6. **Environment:** where is this running? (container, VM, serverless)

---

## PHASE 1 — Baseline Measurement

Before changing anything, establish the current performance baseline:

### Application-Level Metrics

```bash
# HTTP endpoint latency (quick baseline with curl)
for i in {1..10}; do
  curl -w "HTTP %{http_code} | DNS: %{time_namelookup}s | Connect: %{time_connect}s | TTFB: %{time_starttransfer}s | Total: %{time_total}s\n" \
    -o /dev/null -s https://YOUR_SERVICE/api/endpoint
done

# Load test baseline (k6 — 1 minute, 10 virtual users)
# Install: brew install k6 (macOS) or snap install k6 (Linux)
cat > /tmp/loadtest.js << 'LOADTEST'
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  vus: 10,
  duration: '60s',
};

export default function () {
  const res = http.get('https://YOUR_SERVICE/api/endpoint');
  check(res, { 'status is 200': (r) => r.status === 200 });
}
LOADTEST
# k6 run /tmp/loadtest.js
```

### System-Level Metrics

```bash
# CPU usage by process (macOS)
top -l 1 -o cpu -n 10 | head -20

# CPU usage by process (Linux)
top -bn1 -o %CPU | head -20

# Memory usage
ps aux --sort=-rss | head -10   # Linux
ps -eo pid,rss,command | sort -nrk2 | head -10   # macOS

# Disk I/O
iostat -x 1 3 2>/dev/null || iostat 1 3   # Linux/macOS

# Network connections
ss -s 2>/dev/null || netstat -s | head -20   # connection stats
ss -tnp 2>/dev/null | wc -l   # total TCP connections
```

### Database Metrics

```sql
-- PostgreSQL: slow queries (currently running)
SELECT pid, now() - pg_stat_activity.query_start AS duration, query, state
FROM pg_stat_activity
WHERE (now() - pg_stat_activity.query_start) > interval '1 second'
  AND state != 'idle'
ORDER BY duration DESC
LIMIT 10;

-- PostgreSQL: most time-consuming queries (cumulative)
SELECT query,
  calls,
  round(total_exec_time::numeric, 2) AS total_ms,
  round(mean_exec_time::numeric, 2) AS mean_ms,
  round((100 * total_exec_time / sum(total_exec_time) OVER ())::numeric, 2) AS pct
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;

-- PostgreSQL: table sizes and bloat
SELECT relname AS table,
  pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
  pg_size_pretty(pg_relation_size(relid)) AS data_size,
  pg_size_pretty(pg_indexes_size(relid)) AS index_size,
  n_live_tup AS live_rows,
  n_dead_tup AS dead_rows,
  round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS dead_pct
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 15;

-- PostgreSQL: index usage (find unused indexes)
SELECT schemaname, relname AS table, indexrelname AS index,
  idx_scan AS times_used,
  pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
  AND indexrelname NOT LIKE '%pkey%'
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 10;

-- PostgreSQL: missing indexes (sequential scans on large tables)
SELECT relname AS table,
  seq_scan, seq_tup_read,
  idx_scan, idx_tup_fetch,
  n_live_tup AS rows,
  round(100.0 * idx_scan / NULLIF(seq_scan + idx_scan, 0), 1) AS idx_hit_pct
FROM pg_stat_user_tables
WHERE seq_scan > 100
  AND n_live_tup > 10000
ORDER BY seq_tup_read DESC
LIMIT 10;

-- PostgreSQL: lock contention
SELECT pid, mode, relation::regclass, query
FROM pg_locks
JOIN pg_stat_activity USING (pid)
WHERE NOT granted
ORDER BY query_start;

-- PostgreSQL: connection utilization
SELECT count(*), state
FROM pg_stat_activity
GROUP BY state;
```

```bash
# Redis: memory and hit rate
redis-cli info memory | grep -E "used_memory_human|maxmemory_human|mem_fragmentation"
redis-cli info stats | grep -E "keyspace_hits|keyspace_misses"

# Redis: slow log
redis-cli slowlog get 10
```

---

## PHASE 2 — Latency Breakdown

Decompose the end-to-end latency into components:

```
Total request time: [X]ms
├── Network (client → server): [A]ms
├── Auth middleware: [B]ms
├── Business logic: [C]ms
│   ├── Database query 1: [D]ms
│   ├── Database query 2: [E]ms
│   ├── Cache lookup: [F]ms
│   └── External API call: [G]ms
├── Serialization: [H]ms
└── Network (server → client): [I]ms
```

**Identify the dominant component.** If database queries are 80% of the total time, optimizing serialization is waste. Focus on the longest bar.

### Code-Level Profiling

```bash
# Node.js: built-in profiler
node --prof app.js
# Process the log:
node --prof-process isolate-*.log > profile.txt

# Python: cProfile
python -m cProfile -s cumulative app.py 2>&1 | head -30

# Java: async-profiler (non-intrusive, production-safe — no restart needed)
# Download: https://github.com/async-profiler/async-profiler/releases
./profiler.sh -d 30 -e cpu -f flamegraph.html $(pgrep -f java)
./profiler.sh -d 30 -e alloc -f alloc.html $(pgrep -f java)   # allocation profile

# Spring Boot Actuator — built-in metrics (read-only, no agent needed)
# Enable: management.endpoints.web.exposure.include=metrics,health,threaddump,heapdump
curl -s http://localhost:8080/actuator/metrics/jvm.memory.used | python3 -m json.tool
curl -s http://localhost:8080/actuator/metrics/http.server.requests | python3 -m json.tool
curl -s http://localhost:8080/actuator/metrics/jvm.gc.pause | python3 -m json.tool
```

### JVM Profiling (Java Services)

```bash
# 1. Thread dump — what is every thread doing right now?
# ⚠️ Ask user before running in production — read-only but outputs PID state
PID=$(pgrep -f "java.*your-app-name")
jstack $PID 2>/dev/null | head -100
# Look for: BLOCKED threads (lock contention), WAITING (deadlock candidates)

# Detect deadlock automatically
jstack $PID 2>/dev/null | grep -A20 "Found.*deadlock\|Java-level deadlock"

# 2. Heap analysis — memory usage and live objects
jmap -histo:live $PID 2>/dev/null | head -30
# Columns: #instances, bytes, class name
# ⚠️ -histo:live triggers Full GC — use with caution in production

# 3. GC log analysis — is GC the bottleneck?
# Enable GC logging in JVM args: -Xlog:gc*:file=/var/log/gc.log:time,uptime:filecount=5,filesize=20m
grep -E "GC\(|Pause|promotion failed" /var/log/gc.log 2>/dev/null | tail -30
# Warning signs: Stop-the-world > 200ms, GC > 10% of CPU time, frequent Full GC

# 4. JVM flags in use — check heap size and GC algorithm
ps aux | grep java | grep -oE '\-Xmx[0-9]+[gGmM]|\-Xms[0-9]+[gGmM]|\-XX:[A-Za-z+]+' | sort

# 5. Spring Boot Actuator thread dump (JSON, remote-safe)
curl -s http://localhost:8080/actuator/threaddump | python3 -c "
import json, sys, collections
data = json.load(sys.stdin)
states = collections.Counter(t['threadState'] for t in data['threads'])
print('Thread states:', dict(states))
blocked = [t['threadName'] for t in data['threads'] if t['threadState'] == 'BLOCKED']
if blocked:
    print('BLOCKED threads:', blocked[:10])
"
```

**JVM performance signals:**

| Signal | Root Cause | Fix |
|--------|-----------|-----|
| High BLOCKED thread count | Lock contention | `synchronized` → `ReentrantLock`, concurrent collections |
| Frequent Full GC | Old gen exhaustion | Increase heap, fix memory leak, tune G1GC |
| GC pause > 200ms | Large heap, poor tuning | Switch to ZGC (`-XX:+UseZGC`) for low-latency |
| High allocation rate | Object churn | Object pooling, reduce temp object creation |
| Many WAITING threads | DB/external call blocking | Async patterns, virtual threads (Java 21+) |
| Old gen growing steadily | Memory leak | Heap dump + Eclipse MAT / VisualVM analysis |

```bash
# 6. Heap dump for memory leak analysis (⚠️ pauses JVM briefly — ask user first)
# jmap -dump:format=b,file=/tmp/heap.hprof $PID
# Then analyze with: Eclipse MAT (open source) or VisualVM
# Key reports: Dominator Tree (who holds most memory), Leak Suspects
```

### Database Query Analysis

```sql
-- EXPLAIN ANALYZE the slow query (PostgreSQL)
-- This runs the query and shows actual execution times
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT ... -- paste the slow query here;

-- What to look for:
-- Seq Scan on large tables → needs an index
-- Nested Loop with high row counts → consider Hash Join
-- Buffers: shared read (high) → data not cached, hitting disk
-- Rows estimated vs actual (10x off) → stale statistics, run ANALYZE
```

---

## PHASE 3 — Common Performance Anti-Patterns

Check the codebase for these patterns:

### N+1 Queries

```bash
# Find ORM lazy loading patterns
grep -rn "\.load(\|lazy.*true\|FetchType\.LAZY\|select_related\|prefetch_related" --include="*.ts" --include="*.py" --include="*.java" . | head -10

# Find loops with database calls inside (TypeScript/Node.js)
grep -rn "for.*await.*find\|for.*\.get(\|for.*\.query(" --include="*.ts" . | head -10

# Find SQLAlchemy lazy loading N+1 (Python) — common in FastAPI + SQLAlchemy setups
grep -rn "relationship(" --include="*.py" . | grep -v "lazy=\"joined\"\|lazy=\"selectin\"\|lazy=\"subquery\"" | head -10
# Each relationship() without lazy="selectin" or joined is a potential N+1
# Fix: use selectinload() or joinedload() in the query

# Java Spring/Hibernate: find @ManyToOne / @OneToMany without fetch strategy
grep -rn "@ManyToOne\|@OneToMany\|@ManyToMany" --include="*.java" . | grep -v "fetch\|FetchType\." | head -10
```

**SQLAlchemy N+1: detect and fix pattern**
```python
# ❌ N+1 — for 100 orders, this executes 101 queries
orders = session.query(Order).all()
for order in orders:
    print(order.user.email)  # LazyLoad fires per iteration

# ✅ Fix 1: selectinload (preferred for lists — separate IN query)
from sqlalchemy.orm import selectinload
orders = session.query(Order).options(selectinload(Order.user)).all()

# ✅ Fix 2: joinedload (JOIN — best for single object, watch for cartesian product on collections)
from sqlalchemy.orm import joinedload
orders = session.query(Order).options(joinedload(Order.user)).all()

# ✅ Fix 3: async SQLAlchemy (FastAPI pattern)
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select

async def get_orders_with_users(db: AsyncSession):
    result = await db.execute(
        select(Order).options(selectinload(Order.user))
    )
    return result.scalars().all()

# Enable SQLAlchemy query logging to catch N+1 in dev:
import logging
logging.getLogger("sqlalchemy.engine").setLevel(logging.INFO)
# Or use: echo=True on engine creation — prints every SQL statement
```

### Unbounded Operations

```bash
# Find queries without limits
grep -rn "findAll\|find(\|\.all()\|SELECT.*FROM" --include="*.ts" --include="*.py" . | grep -v "limit\|LIMIT\|take\|first\|top" | head -10

# Python SQLAlchemy unbounded queries
grep -rn "\.all()" --include="*.py" . | grep -v "test\|spec\|limit\|filter" | head -10
# .all() without .limit() on a table with millions of rows = full scan in memory

# Find unbounded loops
grep -rn "while.*true\|for.*in.*all\|\.map(\|\.forEach(" --include="*.ts" --include="*.py" . | head -10
```

### Missing Caching

```bash
# Find repeated expensive operations
grep -rn "fetch\|axios\|requests\.get\|http\.get\|httpx\." --include="*.ts" --include="*.py" . | head -10
# For each: is the result cached? Should it be?

# Check cache hit rates (if instrumented)
grep -rn "cache\.get\|cache\.hit\|cache\.miss\|redis\.get\|aiocache" --include="*.ts" --include="*.py" . | head -10
```

**Python: GIL impact on CPU-bound work** — critical for FastAPI/Django/Flask services
```bash
# Identify CPU-bound functions that block the event loop (FastAPI/asyncio)
grep -rn "def [a-z].*:" --include="*.py" . | grep -v "async def" | head -20
# In FastAPI: sync functions called from async routes block the thread pool
# Fix: either make them async, or run in executor:
# await asyncio.get_event_loop().run_in_executor(None, cpu_bound_function)

# Check if Celery workers are configured for CPU-bound vs I/O-bound work
grep -rn "concurrency\|worker_concurrency\|CELERYD_CONCURRENCY" --include="*.py" --include="*.cfg" --include="*.env" . | head -5
# I/O bound: concurrency = 2× CPU count (gevent/eventlet pool)
# CPU bound: concurrency = CPU count (prefork, default)
# Mixed: use separate queues with separate worker pools
```

### Synchronous Blocking

```bash
# Find synchronous I/O in async code
grep -rn "readFileSync\|writeFileSync\|execSync\|time\.sleep\|requests\.get" --include="*.ts" --include="*.py" . | head -10

# Python: blocking calls inside async functions (common FastAPI mistake)
grep -rn "requests\.get\|requests\.post\|time\.sleep\|open(" --include="*.py" . | \
  grep -v "test\|spec\|#\|if __name__" | head -10
# Fix: use httpx.AsyncClient, asyncio.sleep, aiofiles respectively

# Find serial awaits that could be parallel
grep -rn "await.*\nawait\|await.*;\s*await" --include="*.ts" . | head -10
# Pattern: const a = await foo(); const b = await bar();
# Fix: const [a, b] = await Promise.all([foo(), bar()]);
```

### Memory Issues

```bash
# Node.js: check heap usage
node -e "const used = process.memoryUsage(); console.log(JSON.stringify(used, null, 2))"

# Find potential memory leaks (event listeners, growing arrays)
grep -rn "addEventListener\|\.on(\|\.push(\|concat\|global\.\|module\.exports\." --include="*.ts" --include="*.js" . | head -15

# Python: object count by type (if accessible)
# python -c "import gc; gc.collect(); print(sorted([(type(o).__name__, 1) for o in gc.get_objects()], key=lambda x: x[0])[:20])"
```

---

## PHASE 4 — Optimization Opportunities

For each bottleneck found, provide a specific optimization with expected improvement:

| Bottleneck | Current | Optimization | Expected improvement | Effort |
|-----------|---------|-------------|---------------------|--------|
| N+1 on user lookup | 100 queries × 5ms = 500ms | Batch load with IN clause | 1 query × 10ms = 10ms (50× faster) | Low |
| Full table scan on orders | 800ms per query | Add composite index (user_id, created_at) | <5ms per query (160× faster) | Low |
| Serial API calls | 3 calls × 200ms = 600ms | Promise.all / asyncio.gather | max(200ms) = 200ms (3× faster) | Low |
| No caching on config | 50ms per request | Cache with 5-min TTL | <1ms per request (50× faster) | Low |
| Large JSON serialization | 100ms for 10MB response | Pagination (50 items per page) | <5ms per response | Medium |

**Prioritize by:** largest P99 impact × lowest effort = highest ROI optimization.

---

## PHASE 5 — Production Load Testing Tools

Use the right tool for the job. These are what production teams actually use:

```bash
# vegeta — constant-rate HTTP load generator (avoids coordinated omission bias)
# Install: go install github.com/tsenart/vegeta@latest (or brew install vegeta)
echo "GET https://YOUR_SERVICE/api/endpoint" | vegeta attack -rate=500/s -duration=30s | vegeta report
# Histogram output:
echo "GET https://YOUR_SERVICE/api/endpoint" | vegeta attack -rate=500/s -duration=30s | vegeta report -type=hist[0,5ms,10ms,25ms,50ms,100ms,500ms]
# Plot latency over time (HTML):
echo "GET https://YOUR_SERVICE/api/endpoint" | vegeta attack -rate=500/s -duration=30s | vegeta plot > latency.html

# oha — Rust HTTP load generator with live TUI (modern replacement for hey/ab)
# Install: brew install oha (or cargo install oha)
oha -z 30s -c 100 --latency-correction https://YOUR_SERVICE/api/endpoint

# hyperfine — statistical CLI benchmarking (compare two implementations)
# Install: brew install hyperfine (or cargo install hyperfine)
hyperfine --warmup 3 'curl -s http://localhost:8080/api/v1/endpoint' 'curl -s http://localhost:8080/api/v2/endpoint'
# Parameter scan (e.g., find optimal thread count):
hyperfine --parameter-scan threads 1 8 'wrk -t{threads} -c100 -d10s http://localhost:8080/api'

# wrk — raw throughput testing (generates ~5x traffic of k6 on same hardware)
# Install: brew install wrk
wrk -t12 -c400 -d30s http://localhost:8080/api/endpoint
```

**Tool selection guide:**
| Tool | Best for | Coordinated omission safe? |
|------|---------|---------------------------|
| vegeta | Constant-rate testing, API benchmarks | ✅ Yes |
| k6 | Scripted scenarios, CI integration | ⚠️ Partial |
| oha | Quick interactive testing, live TUI | ✅ Yes |
| wrk | Raw max throughput | ❌ No |
| hyperfine | Comparing two CLI commands statistically | N/A (not HTTP) |

**Coordinated omission** matters: most load testing tools (ab, wrk, hey) wait for a response before sending the next request. Under load, this artificially reduces measured latency because slow requests delay new requests. vegeta and oha avoid this by maintaining a constant request rate regardless of response time — giving you the real P99.

---

## PHASE 6 — Distributed Tracing Analysis

For services that participate in a distributed system, request-level profiling misses cross-service latency. Distributed tracing answers: **which service is responsible for the tail latency?**

### Instrumentation Check

```bash
# Verify OpenTelemetry SDK is present (Node.js)
grep -rn "@opentelemetry\|otel" package.json package-lock.json 2>/dev/null | head -5

# Python
grep -rn "opentelemetry\|otel" requirements.txt pyproject.toml 2>/dev/null | head -5

# Java
grep -rn "opentelemetry\|otel" pom.xml build.gradle 2>/dev/null | head -5

# Check if spans are created in critical paths
grep -rn "startSpan\|tracer\.start\|with_span\|otel\.trace\|ctx\.span" --include="*.ts" --include="*.py" --include="*.java" . | wc -l
# Target: every external call, DB query, and cache operation should have a span
```

### Finding Inter-Service Bottlenecks

**In Jaeger / Grafana Tempo / Datadog APM:**

```
1. Open a high-P99 trace (not average — you want the worst case)
2. Look at the waterfall diagram:
   - Long horizontal bars = slow operations
   - Gap between parent span end and child span start = serialization / scheduling overhead
   - Span with no children that takes >50ms = prime optimization candidate

3. Sort traces by duration descending. Open the slowest 10.
   Pattern: if the same service appears in 8/10 slow traces → that service is your bottleneck.
   Pattern: if DB spans are consistently 80%+ of total → database is the problem.
   Pattern: if spans are thin but there are hundreds → fan-out with no batching.

4. Use Jaeger dependency graph (or Datadog Service Map) to find unexpected service calls
   Missing span = uninstrumented code = blind spot in your analysis
```

### Reading OpenTelemetry Traces via CLI

```bash
# Jaeger: query traces for a service via HTTP API (read-only)
curl -s "http://JAEGER_HOST:16686/api/traces?service=YOUR_SERVICE&limit=20&lookback=1h" | \
  python3 -m json.tool | grep -E '"operationName"|"duration"' | head -40

# Tempo: query via Grafana HTTP API (read-only)
curl -s -H "Authorization: Bearer TOKEN" \
  "http://GRAFANA_HOST/api/datasources/proxy/UID/api/traces?service=YOUR_SERVICE" | \
  python3 -m json.tool 2>/dev/null | head -50

# Check OTel Collector health (are traces being exported?)
curl -s http://OTEL_COLLECTOR:8888/metrics | grep -E "otelcol_exporter_sent_spans|otelcol_receiver_accepted_spans"

# Datadog: list slow traces (requires DD_API_KEY and DD_APP_KEY — confirm before running)
# ⚠️ STOP — confirm API keys are set before running:
# curl -s -X GET "https://api.datadoghq.com/api/v1/query" \
#   -H "DD-API-KEY: ${DD_API_KEY}" -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
#   --data-urlencode "from=$(date -d '1 hour ago' +%s)" \
#   --data-urlencode "to=$(date +%s)" \
#   --data-urlencode "query=avg:trace.web.request.duration{env:production} by {service}"
```

### Span Coverage Audit

Critical paths that MUST have spans (if they don't, your traces are misleading):

| Operation | Expected span attribute |
|-----------|------------------------|
| Every outbound HTTP call | `http.method`, `http.url`, `http.status_code` |
| Every DB query | `db.system`, `db.statement` (sanitized), `db.name` |
| Every cache operation | `db.system: redis`, `db.operation: GET/SET` |
| Every message queue publish | `messaging.system`, `messaging.destination` |
| Every message queue consume | `messaging.system`, `messaging.operation: process` |
| Background jobs | `job.name`, `job.id` |

```bash
# Find uninstrumented DB calls (no span wrapping)
grep -rn "query\|execute\|findOne\|findAll\|save\|insert\|update\|delete" \
  --include="*.ts" --include="*.py" --include="*.java" . | \
  grep -v "span\|trace\|otel" | head -20
# Each result is a potential blind spot in your distributed traces
```

### Trace-Based Performance Analysis

```
Signal                          → Root Cause                    → Fix
────────────────────────────────────────────────────────────────────────────────
Parent span waits on child      → Synchronous fan-out           → Parallelize calls with Promise.all / asyncio.gather
Many child spans, same service  → N+1 pattern across services   → Batch API, GraphQL DataLoader, or denormalize
Large gap in waterfall          → Thread pool exhaustion        → Increase pool size or use async I/O
Span starts late, not slow      → Queue saturation              → Scale consumers, increase concurrency
DB span > 80% of total          → DB bottleneck                 → Profile query, add index, cache result
External API span dominant      → Third-party latency           → Circuit breaker, cache, async + callback
```

---

## PHASE 7 — Flame Graph Reading Guide

Flame graphs are the single most effective visualization for finding CPU hotspots. Learn to read them:

```bash
# Generate flame graph — Java (async-profiler, production-safe, no restart needed)
# Download: https://github.com/async-profiler/async-profiler/releases
./profiler.sh -d 30 -f flamegraph.html PID
# CPU: -e cpu  |  Allocation: -e alloc  |  Wall clock: -e wall

# Generate flame graph — Node.js
node --prof app.js
node --prof-process isolate-*.log > profile.txt
# Or use 0x for interactive flame graphs:
# npx 0x app.js

# Generate flame graph — Python
pip install py-spy
py-spy record -o profile.svg -- python app.py
# Production-safe (no restart needed):
py-spy record -o profile.svg --pid PID

# Generate flame graph — Java (async-profiler, production-safe)
# ./profiler.sh -d 30 -f flamegraph.html PID
```

**How to read a flame graph:**
```
Reading direction:
  - X-axis: NOT time. Width = proportion of total CPU time in that function.
  - Y-axis: Stack depth. Bottom = entry point, top = leaf function.
  - Wide bars at the TOP = where CPU time is actually spent.
  - Wide bars at the BOTTOM = common callers (less interesting).

What to look for:
  1. Wide plateaus at the top → CPU hotspot, optimize this function
  2. Many thin towers → deep call stacks, consider reducing abstraction layers
  3. Flat bars taking >10% width → dominant function, investigate
  4. Unexpected functions (GC, serialization, logging) taking >5% → quick win

Common findings and fixes:
  - JSON.stringify/parse wide → consider binary serialization (protobuf, msgpack)
  - GC/malloc wide → object allocation in hot loop, pool or reuse objects
  - regex/match wide → precompile regex outside the loop
  - sort wide → check if O(n log n) sort is needed, or if data is already partially sorted
  - hash/crypto wide → check if you're hashing unnecessarily (e.g., on every request)
```

---

## PHASE 8 — Benchmark Plan

After optimizations, verify with benchmarks:

```bash
# Before/after comparison using vegeta (preferred)
echo "GET https://YOUR_SERVICE/api/endpoint" | vegeta attack -rate=200/s -duration=60s | vegeta report | tee before.txt
# [apply optimization]
echo "GET https://YOUR_SERVICE/api/endpoint" | vegeta attack -rate=200/s -duration=60s | vegeta report | tee after.txt

# Compare results
diff before.txt after.txt

# Before/after with hyperfine (for CLI/script comparisons)
hyperfine 'curl -s http://localhost:8080/api/old' 'curl -s http://localhost:8080/api/new' --export-markdown comparison.md
```

**Benchmark requirements:**
- Same data volume as production (or at least same order of magnitude)
- Run for at least 60 seconds to capture steady-state, not cold start
- Report P50, P95, P99, and max — averages hide tail latency
- Run multiple times to confirm consistency (variance < 10%)
- Use constant-rate tools (vegeta, oha) to avoid coordinated omission bias

---

## PHASE 9 — Self-Review

- [ ] Was every claim backed by a measurement (no "this should be faster")?
- [ ] Is the latency breakdown complete (all time is accounted for)?
- [ ] Is distributed tracing coverage audited (every DB call, HTTP call, queue operation has a span)?
- [ ] Are all diagnostic commands safe (read-only, no modifications)?
- [ ] Does each optimization have an expected improvement estimate?
- [ ] Is the optimization prioritized by ROI (impact × 1/effort)?
- [ ] Does the benchmark plan use production-representative data volumes?

---

## OUTPUT

1. **Baseline measurements** (current P50/P99, system metrics, slow query report)
2. **Latency breakdown** (component-by-component time accounting)
3. **Anti-pattern findings** (N+1, unbounded queries, missing caching, blocking I/O)
4. **Prioritized optimization roadmap** (sorted by ROI)
5. **Benchmark plan** (how to verify each optimization's impact)

**Save:** use the Write tool to save this document to `docs/reviews/perf-audit-[service]-[date].md` (or user-specified path).

**What to run next:**
- `/principal:db-review` — if slow queries or N+1 patterns dominated the audit
- `/principal:scale-review` — if the audit revealed capacity or architectural limits, not just code-level anti-patterns
- `scripts/otel-check.sh` — verify OpenTelemetry instrumentation is in place to validate optimizations
