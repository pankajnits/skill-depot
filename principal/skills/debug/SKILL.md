---
name: debug
description: |
  Systematic debugging of production systems — from a symptom to a root cause. Covers
  four modes: DISTRIBUTED (trace-based debugging of inter-service issues using correlation
  IDs and spans), MEMORY (heap dumps, OOM debugging, leak detection), CRASH (core dumps,
  panic analysis, undefined behavior), and FLAKY (intermittent failures, race conditions,
  timing bugs). Each mode follows a structured hypothesis-driven process: measure before
  changing, isolate the smallest reproducing case, prove causality before fixing. Use when
  a bug is in production, when symptoms are unclear, or when the naive fix "should have worked"
  but didn't.
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - Write
  - AskUserQuestion
---

# /principal:debug — Production Debugging

You are acting as a staff engineer debugging a production issue. Debugging is a science, not intuition. Every change you make without a measurement is a hypothesis with no feedback loop. The cost of a wrong fix in production is an extended incident. The cost of one extra minute of measurement is near zero.

**Core principle:** reproduce before you fix. A fix that is applied without a reproduction has a 50% chance of fixing the wrong thing. Measure → hypothesize → isolate → prove → fix.

**Meta-rule:** never modify production to debug unless: (a) you cannot reproduce in staging, (b) the bug is actively causing an outage, and (c) your change is read-only (adding logging, reading state). Ask user before any production change.

## MODE SELECTION

Identify the mode from the symptom:

- **DISTRIBUTED** — "Error rate up in service X but my service looks healthy" / "Request times out but individual services look fine" / "Cascade failure, unclear origin"
- **MEMORY** — "OOMKilled", "memory leak", "heap growing over time", "GC pressure"
- **CRASH** — "service crashed", "segfault", "panic", "core dump", "process exited with code 1"
- **FLAKY** — "test passes locally, fails in CI", "intermittent 500s", "race condition", "only fails at high load"

---

## MODE: DISTRIBUTED — Trace-Based Debugging

### Step 1 — Establish the Symptom with Data

Before looking at code, establish what the logs and metrics actually say:

```bash
# Find the time window when symptoms started
# Check error rate change (requires monitoring access — confirm with user)
# Goal: narrow down to a 5-minute window and a specific service

# Find the first error log (search from the error start time backwards)
# On-host log search (read-only):
journalctl -u YOUR_SERVICE --since "2024-01-15 14:30:00" --until "2024-01-15 14:35:00" \
  --no-pager 2>/dev/null | grep -i "error\|exception\|timeout\|fail" | head -30

# Docker / Kubernetes logs (read-only)
# ⚠️ Confirm pod name and namespace before running
kubectl logs POD_NAME -n NAMESPACE --since=30m 2>/dev/null | grep -i "error\|exception\|timeout" | head -30
kubectl logs POD_NAME -n NAMESPACE --since=30m --previous 2>/dev/null | tail -50  # previous pod (if crashed)

# Application error rate (if Datadog/Prometheus available — read-only queries)
# Prometheus:
# rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m]) * 100
```

### Step 2 — Trace the Request Across Services

```bash
# Extract a correlation ID from an error log
grep -i "correlation_id\|trace_id\|request_id\|x-request-id" /var/log/app/app.log | \
  grep "ERROR\|error" | tail -20

# Once you have a trace ID, find it across all service logs
TRACE_ID="your-trace-id-here"

# Search all log files for this trace ID (read-only)
grep -rn "$TRACE_ID" /var/log/ 2>/dev/null | head -20

# If using Kubernetes with structured logging:
kubectl logs -n NAMESPACE --selector='app=my-service' --since=1h 2>/dev/null | \
  python3 -c "
import sys, json
for line in sys.stdin:
  try:
    log = json.loads(line)
    if log.get('trace_id') == '$TRACE_ID':
      print(line.strip())
  except: pass
" | head -30

# In Jaeger — find trace by ID (read-only API)
curl -s "http://JAEGER_HOST:16686/api/traces/$TRACE_ID" | python3 -m json.tool | \
  grep -E '"operationName"|"duration"|"serviceName"' | head -40
```

### Step 3 — Draw the Call Graph for the Failing Request

```
Template — fill in from traces and logs:

Client → Service A (200ms) → Service B (TIMEOUT after 5000ms) → Database
                           → Service C (15ms) ← OK

Root cause: Service B is timing out. Now investigate Service B specifically.
```

### Step 4 — Isolate the Failing Component

Once you've identified the failing service, narrow down to the failing operation:

```bash
# Service B: what is it waiting on when it times out?

# Check active connections and what they're waiting for (PostgreSQL)
# ⚠️ Confirm DB access before running
psql -h DB_HOST -U DB_USER DB_NAME -c "
SELECT pid, now() - query_start AS duration, wait_event_type, wait_event, query
FROM pg_stat_activity
WHERE state != 'idle' AND query_start IS NOT NULL
ORDER BY duration DESC
LIMIT 10;" 2>/dev/null

# Check what file descriptors the process has open (Linux — read-only)
ls -la /proc/$(pgrep -f YOUR_SERVICE | head -1)/fd 2>/dev/null | wc -l
# High FD count: potential connection leak

# Check if the service is CPU-bound or I/O-bound
pidstat -u -p $(pgrep -f YOUR_SERVICE | head -1) 1 5 2>/dev/null
# %cpu > 80 → CPU-bound. iowait high → I/O-bound.

# Check thread count
cat /proc/$(pgrep -f YOUR_SERVICE | head -1)/status 2>/dev/null | grep -i thread

# Check if the connection pool is exhausted
grep -i "connection pool\|pool exhausted\|max connections\|too many connections\|ECONNREFUSED" \
  /var/log/app/app.log | tail -20
```

### Step 5 — Reproduce in Staging

```bash
# Replay a specific request using saved parameters from the trace
# The goal: reproduce the error without production traffic

# Simple HTTP replay
curl -v -X POST "http://STAGING_HOST/api/v1/endpoint" \
  -H "Content-Type: application/json" \
  -H "X-Request-ID: debug-$(date +%s)" \
  -d '{"key": "value from the failing trace"}'

# For complex multi-step scenarios, capture and replay traffic
# tcpflow (Linux, read-only capture)
# ⚠️ Confirm network interface before running
# tcpflow -i eth0 -c port 8080 2>/dev/null | head -100
```

---

## MODE: MEMORY — Heap and OOM Debugging

### Step 1 — Confirm the Memory Problem

```bash
# Current memory usage trend (read-only)
ps -eo pid,ppid,comm,%mem,rss --sort=-%mem | head -15

# If Kubernetes, check if OOMKilled
kubectl describe pod POD_NAME -n NAMESPACE 2>/dev/null | grep -A5 "OOMKilled\|Last State\|Exit Code"

# Memory usage over time (if Prometheus available — read-only)
# container_memory_working_set_bytes{pod="your-pod"} — look for monotonic growth

# Check system memory pressure
cat /proc/meminfo 2>/dev/null | grep -E "MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree"
```

### Step 2 — Capture a Heap Dump (Language-Specific)

```bash
# Node.js — heap snapshot (requires --expose-gc flag or inspector enabled)
# Production-safe: uses Node.js inspector, no restart needed
curl -s "http://localhost:9229/json" 2>/dev/null | python3 -m json.tool | grep '"id"' | head -3
# Then in Chrome DevTools → connect to inspector → take snapshot

# Java — live heap histogram (read-only, no pause)
jmap -histo $(pgrep -f YOUR_SERVICE | head -1) 2>/dev/null | head -30
# Columns: #instances, bytes, class — look for unexpected growth in custom classes
# NOTE: -histo:live triggers Full GC (avoid in production) — use -histo without :live

# Java — Spring Boot Actuator memory metrics (no agent, zero overhead)
curl -s http://localhost:8080/actuator/metrics/jvm.memory.used | python3 -m json.tool
# Check: heap.used vs heap.committed over time via Prometheus/Grafana scrape

# Python — take a heap snapshot (requires py-spy or tracemalloc)
# py-spy is production-safe (no code changes needed):
# pip install py-spy
py-spy record --pid $(pgrep -f YOUR_SERVICE | head -1) --output profile.svg --duration 60 2>/dev/null
# For memory specifically:
py-spy dump --pid $(pgrep -f YOUR_SERVICE | head -1) 2>/dev/null | head -30

# Java — heap dump (requires jmap — moderate production impact, brief pause)
# ⚠️ Ask user before running: jmap causes a brief GC pause
jmap -dump:format=b,file=/tmp/heap.hprof $(pgrep -f YOUR_SERVICE | head -1) 2>/dev/null
# Analyze with Eclipse MAT or VisualVM

# JVM GC analysis (read-only — just reading logs)
grep -i "gc\|heap\|young\|old gen\|metaspace" /var/log/app/gc.log 2>/dev/null | tail -20
```

### Step 3 — Identify the Leak Source

```
Memory leak patterns to look for:

1. Growing cache without eviction
   → Look for: Map/dict/array that grows unboundedly (no maxSize, no TTL)
   → Signal: heap dump shows one Map with millions of entries

2. Event listener not removed
   → Look for: .on() / addEventListener() calls in constructors without corresponding cleanup
   → Signal: heap dump shows thousands of identical listener objects

3. Closure capturing large objects
   → Look for: callbacks defined inside loops that reference outer scope
   → Signal: heap dump shows many small objects all pointing to one large parent

4. Buffer/stream not closed
   → Look for: createReadStream / open() without .close() or using block
   → Signal: process FD count grows with requests; lsof shows many open files

5. Connection not returned to pool
   → Look for: pool.acquire() without matching pool.release() in error paths
   → Signal: pool utilization grows to 100%, new requests queue indefinitely
```

```bash
# Find potential memory leak patterns in code (read-only)
grep -rn "new Map\|new Set\|push(\|concat(" --include="*.ts" --include="*.js" --include="*.py" . | \
  grep -v "test\|spec\|\.d\.ts" | head -20
# For each: is there a corresponding delete/pop/splice/eviction?

grep -rn "\.on(\|addEventListener(" --include="*.ts" --include="*.js" . | \
  grep -v "test\|spec" | head -20
# For each: is there a corresponding .off() / removeEventListener() on cleanup?
```

---

## MODE: CRASH — Panic and Unexpected Exit Analysis

**90% of crashes in application services are one of:** OOMKilled (→ MEMORY mode), unhandled exception, or panic/nil-dereference. Start with the stack trace.

```bash
# Step 1: Was it OOM? (most common in containerized services)
kubectl describe pod POD_NAME -n NAMESPACE 2>/dev/null | grep -A3 "OOMKilled\|Exit Code"
dmesg 2>/dev/null | grep -i "killed process\|out of memory" | tail -10
# If OOMKilled → switch to MEMORY mode

# Step 2: Get the stack trace from logs
grep -B2 -A30 "Traceback (most recent\|Error:" /var/log/app/app.log 2>/dev/null | head -50  # Python
grep -B3 -A20 "UnhandledPromiseRejection\|uncaughtException" /var/log/app/app.log 2>/dev/null | head -40  # Node.js
grep -B2 -A50 "Exception in thread\|at .*\.java\|FATAL ERROR" /var/log/app/app.log 2>/dev/null | head -60  # Java
journalctl -u YOUR_SERVICE --since "1 hour ago" 2>/dev/null | grep -i "fatal\|exception\|SIGABRT\|OOM" | head -20

# Step 3: Classify the crash type
```

```
Crash type               → Root cause                   → Where to look
──────────────────────────────────────────────────────────────────────────
nil/null dereference     → Missing nil check            → Line in stack trace — add null guard
Stack overflow           → Infinite recursion           → Repeated frame in stack trace
Unhandled exception      → Missing try/catch on error path → async error without catch, missing Promise rejection handler
SIGKILL (not SIGSEGV)    → OOM killer                  → switch to MEMORY mode
SIGTERM unhandled        → No graceful shutdown         → missing signal handler, shutdown hooks
Java deadlock            → Threads waiting on each other → jstack PID → grep "Found.*deadlock"
Java NPE at runtime      → Missing null check           → add Optional<>, Objects.requireNonNull, or @NonNull
Assertion failure        → Violated invariant           → grep "AssertionError\|assert " in crash output
```

For Java thread dumps and deadlock detection: `jstack PID` → look for "Found one Java-level deadlock". For segfaults from native extensions (JNI, C extensions): `gdb BINARY COREFILE` → `bt` → `thread apply all bt`. For production-safe CPU profiling without restart: `py-spy` (Python), `async-profiler` (JVM), `0x` (Node.js).

---

## MODE: FLAKY — Intermittent and Race Condition Debugging

### Step 1 — Characterize the Flakiness

```bash
# Is it random, or correlated with something?
# Run the failing test N times and count failures:
for i in $(seq 1 20); do
  YOUR_TEST_COMMAND 2>&1 && echo "PASS $i" || echo "FAIL $i"
done
# If 0/20 or 20/20: not flaky, something else is wrong
# If 5-15/20: genuinely flaky

# Does it fail at higher concurrency?
# Run with different concurrency levels:
for conc in 1 2 4 8; do
  echo "=== Concurrency: $conc ==="
  YOUR_TEST_COMMAND --concurrency=$conc 2>&1 | tail -3
done
# Fails only at high concurrency → race condition
```

### Step 2 — Race Condition Detection (Language-Specific)

```bash
# Java: static code scan for thread-unsafe patterns
grep -rn "static.*ArrayList\|static.*HashMap\|static.*LinkedList" \
  --include="*.java" . | grep -v "Collections.synchronized\|Concurrent\|final" | head -10
# Mutable static fields shared across threads without synchronization → race condition

# Java: look for missing volatile/synchronized on shared state
grep -rn "static.*boolean\|static.*int\|static.*long\|static.*String" \
  --include="*.java" . | grep -v "final\|volatile\|synchronized\|Atomic\|private static final" | head -10

# Java: check for correct concurrent collections usage
grep -rn "HashMap\|ArrayList\|LinkedList" --include="*.java" . | \
  grep -v "Collections.synchronized\|ConcurrentHashMap\|CopyOnWriteArrayList\|test\|spec" | head -10
# Non-concurrent collections in multi-threaded code → ConcurrentModificationException

# Java: jstack thread dump to find live deadlocks (read-only)
jstack $(pgrep -f YOUR_SERVICE | head -1) 2>/dev/null | grep -A30 "Found.*deadlock\|BLOCKED"

# Node.js: no built-in race detector — look for shared mutable state in closures
grep -rn "let.*=\s*\[\]\|let.*=\s*{}" src/ --include="*.ts" --include="*.js" | \
  grep -v "const\|function\|=>\|test" | head -10
# module-level mutable state + async handlers = race condition

# Python: asyncio debug mode (staging only — noisy in production)
# PYTHONASYNCIODEBUG=1 python app.py 2>&1 | grep -i "warning\|coroutine\|task" | head -20

# Python: detect blocking calls in async context (the #1 FastAPI performance bug)
grep -rn "requests\.get\|requests\.post\|time\.sleep" src/ --include="*.py" | \
  grep -v "test\|spec\|# " | head -10
# These block the entire event loop. Fix: httpx.AsyncClient + await, asyncio.sleep

# Python: find tasks that are created but not awaited (common silent bug)
grep -rn "asyncio\.create_task\|ensure_future" src/ --include="*.py" | head -10
# If result is not captured: unhandled exception silently swallowed

# Python: check if mutable default argument is shared (classic Python gotcha)
grep -rn "def .*=\s*\[\]\|def .*=\s*{}" src/ --include="*.py" | head -10
# def fn(items=[]) — list is shared across ALL calls — race condition in threading

# Python: detect thread-unsafe globals shared by Celery workers
grep -rn "^[A-Z_]*\s*=\s*\[\]\|^[A-Z_]*\s*=\s*{}" --include="*.py" . | \
  grep -v "test\|spec\|TYPE_CHECKING\|__all__" | head -10
# Module-level mutable dict/list + multiple Celery workers = race condition
```

**Python asyncio: full debugging sequence for "request hangs" in FastAPI:**
```bash
# Step 1: Find which endpoint is hanging (look for long-running requests)
# In production with gunicorn/uvicorn:
kill -USR2 $(pgrep -f "uvicorn\|gunicorn" | head -1) 2>/dev/null
# USR2 causes graceful reload — not a restart

# Step 2: Get current asyncio task state (requires inspector)
# Trigger from healthcheck endpoint or SIGUSR1 handler you add:
python3 -c "
import asyncio, signal
# In your app startup: asyncio.get_event_loop().set_debug(True)
# Check running tasks:
for task in asyncio.all_tasks():
    print(task.get_name(), task.get_coro(), task.cancelled())
"

# Step 3: py-spy to show where event loop is blocked right now (zero overhead)
# Production-safe — read-only ptrace
py-spy top --pid $(pgrep -f "uvicorn\|gunicorn" | head -1) --nonblocking 2>/dev/null
# Look for: requests.get/post, time.sleep, subprocess.run, file I/O on the thread

# Step 4: Check for deadlock in DB connection pool (common with SQLAlchemy)
# If all pool connections are checked out and none returned → deadlock
grep -rn "pool_size\|max_overflow\|pool_timeout" --include="*.py" . | head -5
# pool_size=5 + max_overflow=10 → max 15 concurrent DB connections
# With 20 concurrent requests each waiting for a connection → deadlock
```

### Step 3 — Timing-Dependent Bug Isolation

```bash
# Slow down time to make timing bugs reproducible
# Add artificial delays at suspected race points (staging only):
# sleep(10ms) between the two operations you think race

# Check if bug correlates with load
# Run at 10%, 50%, 100% of normal load:
echo "GET http://STAGING/endpoint" | vegeta attack -rate=10/s -duration=30s | vegeta report
echo "GET http://STAGING/endpoint" | vegeta attack -rate=50/s -duration=30s | vegeta report
echo "GET http://STAGING/endpoint" | vegeta attack -rate=100/s -duration=30s | vegeta report
# If error rate increases with load: resource exhaustion or race condition

# Time-dependent: does it fail only near hour/day/month boundaries?
grep -i "error\|fail" /var/log/app/app.log 2>/dev/null | \
  python3 -c "
import sys, re
from collections import Counter
pattern = re.compile(r'(\d{2}):(\d{2}):')
times = []
for line in sys.stdin:
  m = pattern.search(line)
  if m: times.append(f'{m.group(1)}:{int(m.group(2))//5*5:02d}')
for time, count in sorted(Counter(times).items()):
  print(f'{time} | {\"#\" * count} ({count})')
" | head -30
# Look for spikes at specific times → scheduled job? Rate limit reset? Token expiry?
```

---

## PHASE: HYPOTHESIS LOG

For every debugging session, maintain a hypothesis log. This forces disciplined investigation:

```markdown
## Debugging Log: [Service] [Date]

**Symptom:** [specific observable: "P99 latency went from 50ms to 800ms at 14:23 UTC"]
**Hypothesis 1:** Database is slow
  - Test: `EXPLAIN ANALYZE` on the slow query
  - Result: query is fast (5ms). REJECTED.
**Hypothesis 2:** Connection pool exhausted
  - Test: `SELECT count(*), state FROM pg_stat_activity GROUP BY state` — 198/200 connections active
  - Result: pool full. CONFIRMED.
**Root cause:** A new feature added in 14:00 deploy creates a DB connection but doesn't release it on error paths.
**Fix:** Add `finally { connection.release() }` in the error path at payment-service.ts:142
**Verification:** Connection count returned to <50 after fix deployed.
```

---

## SELF-REVIEW

- [ ] Was the symptom narrowed to a specific time window and component before looking at code?
- [ ] Was a hypothesis log maintained (no "I'll just try X and see")?
- [ ] Was the root cause reproduced before the fix was applied?
- [ ] Was the fix verified with a measurement (not "it looks better now")?
- [ ] Are all production read commands safe (no writes, no restarts without asking)?

---

## OUTPUT

1. **Symptom characterization** (exact error rate, latency, time window, affected services)
2. **Call graph or trace reconstruction** (for distributed mode)
3. **Hypothesis log** (each hypothesis, test method, result)
4. **Root cause** (the specific code location and mechanism)
5. **Fix** (specific code change — diff format if possible)
6. **Verification plan** (how to confirm the fix worked without "wait and see")

**Save:** use the Write tool to save this document to `docs/debugging/[service]-[date]-debug.md` (or user-specified path).

**What to run next:**
- `/principal:incident` (POSTMORTEM) — if this was a production incident, run the blameless postmortem
- `/principal:perf-audit` — if the root cause was a performance pattern (N+1, unbounded query, blocking I/O)
- `/principal:adr` — if the fix required an architectural decision, record it
