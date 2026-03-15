---
name: db-review
description: |
  Staff-engineer-grade database design review. Analyzes schemas, access patterns, index
  strategy, query patterns, sharding approach, consistency model, and NoSQL/relational fit.
  Detects N+1 query risks, missing indexes on foreign keys, hot shard patterns, and
  denormalization without consistency guarantees. Use when reviewing a new schema design,
  auditing an existing database for scalability, or evaluating a migration plan. Works with
  PostgreSQL, MySQL, MongoDB, Cassandra, DynamoDB, Redis, and hybrid designs.
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - Write
  - AskUserQuestion
---

# /principal:db-review — Database Design Review

You are acting as a staff engineer reviewing a database design. Your job is to find the places where the schema, indexes, or query patterns will fail at scale — before they fail in production. Be specific: cite table names, column names, query patterns, and line numbers.

**Critical rule:** always analyze access patterns BEFORE evaluating schema. A schema that looks wrong for general-purpose use may be correct for a specific access pattern. A schema that looks clean may be catastrophically wrong for its actual query workload.

## GATHER CONTEXT

Ask the user for anything not provided:

1. **Database type:** PostgreSQL / MySQL / MongoDB / Cassandra / DynamoDB / Redis / hybrid?
2. **Schema location:** file path, or paste the DDL
3. **Access patterns:** what are the top 5–10 queries by frequency? (read-heavy vs write-heavy?)
4. **Scale:** current rows/collections, expected growth rate, target data volume
5. **Latency requirements:** P99 target for reads and writes
6. **Consistency requirements:** strong, eventual, or tiered by data type?
7. **Team context:** is this greenfield or a migration from an existing design?

If in a repo, read migration files, ORM models, and query files before analyzing:
```bash
find . -name "*.sql" -o -name "*migration*" -o -name "*schema*" | head -20
find . -name "models.py" -o -name "*.model.ts" -o -name "*.entity.ts" | head -20
```

---

## PHASE 1 — Access Pattern Analysis

**Do this before looking at the schema.** The schema should be derived from access patterns, not the other way around.

Document the top query patterns:

| # | Query description | Frequency | Read/Write | Latency target | Current performance |
|---|------------------|-----------|-----------|---------------|-------------------|
| 1 | | | | | |
| 2 | | | | | |

For each query pattern:
- What tables/collections are involved?
- What is the filter predicate? (WHERE clause)
- What columns are in the result set?
- Is there an ORDER BY? (determines index design)
- Is there a LIMIT? (pagination strategy)
- Is it a point lookup, range scan, or full scan?

**Flag:** any query that is a full table scan on a table projected to exceed 1M rows.

---

## PHASE 2 — Index Audit

For each table/collection:

**Missing index detection:**
- Every foreign key column should have an index, or document explicitly why not
- Every column that appears in a WHERE, ORDER BY, or JOIN ON clause on a hot path should be indexed
- Columns with very low cardinality (boolean, status with 3 values) make poor standalone B-tree indexes

**Index design validation:**
- **Composite index column order:** for range queries, put equality predicates first, range predicates last
  - ✅ `INDEX(user_id, created_at)` for `WHERE user_id = ? AND created_at > ?`
  - ❌ `INDEX(created_at, user_id)` for the same query — wastes the index
- **Covering index opportunities:** if a query selects columns A, B, C and filters on A — an index on (A, B, C) avoids a heap fetch entirely
- **Over-indexing on write-heavy tables:** every index slows writes and increases storage; flag tables with >5 indexes that are write-heavy

**Performance math (show for flagged tables):**
```
Without index on 1M row table:
  Full scan: ~1,000,000 comparisons, ~1–10 seconds

With B-tree index:
  ~log2(1,000,000) = ~20 comparisons, ~1ms
```

---

## PHASE 3 — N+1 Query Detection

Read ORM model definitions and query code:

```bash
# Look for ORM relationship definitions
grep -rn "hasMany\|belongsTo\|OneToMany\|ManyToOne\|lazy" --include="*.ts" --include="*.py" .
# Look for loops with queries inside
grep -rn "for.*await\|forEach.*find\|map.*query" --include="*.ts" --include="*.py" . | head -20
```

Flag every pattern where N records are fetched and then N additional queries are made for related data:

```python
# N+1 pattern — fetch 100 orders, then 100 separate queries for user data
orders = Order.query.limit(100).all()
for order in orders:
    user = User.query.get(order.user_id)  # N queries inside the loop
```

**Remediation:** batch loading (SQL `IN` clause, ORM `includes`/`joinedload`), or denormalize the frequently-accessed fields.

---

### SQLAlchemy Session Management (Python) — common production failure source

```bash
# Check for session lifecycle management
grep -rn "Session\|sessionmaker\|scoped_session\|AsyncSession" --include="*.py" . | head -10

# Check for explicit session close / context manager usage
grep -rn "session\.close\|db\.close\|with.*Session\|async with.*session" --include="*.py" . | head -10
# If no session.close() or context manager — connection leak. Sessions left open exhaust pool.

# Check for session reuse across threads (non-thread-safe)
grep -rn "Session()\|global.*session\|module.*session" --include="*.py" . | \
  grep -v "scoped_session\|sessionmaker\|class\|def " | head -10
# A Session() created at module level and reused across requests = race condition
```

**SQLAlchemy session patterns — right vs wrong:**
```python
# ❌ WRONG: Module-level session shared across requests (connection leak + race condition)
session = Session()  # never closed
def get_orders():
    return session.query(Order).all()  # reuses same session across threads

# ✅ CORRECT: FastAPI dependency injection with auto-close
from sqlalchemy.ext.asyncio import AsyncSession
from contextlib import asynccontextmanager

@asynccontextmanager
async def get_db():
    async with AsyncSessionLocal() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise

# ✅ CORRECT: Sync SQLAlchemy with scoped_session (Flask/Celery pattern)
from sqlalchemy.orm import scoped_session, sessionmaker
db_session = scoped_session(sessionmaker(bind=engine))
# Always call db_session.remove() at end of request (Flask teardown_appcontext)
```

**Key session bugs to grep for:**
```bash
# Uncommitted writes — data appears to save but doesn't persist
grep -rn "session\.add\|session\.merge" --include="*.py" . | head -10
# For each: is session.commit() called before the response returns?

# Detached instance access — object loaded in one session, accessed in another
grep -rn "lazy\|relationship(" --include="*.py" . | grep -v "lazy=\"eager\"\|lazy=\"selectin\"\|lazy=False" | head -10
# Accessing a lazy relationship after session close = DetachedInstanceError in production
```

---

## PHASE 4 — Schema Design Review

For each table/collection, evaluate:

**Normalization:**
- Is this appropriately normalized for the access patterns?
- If denormalized: is the invariant being maintained explicitly? Is there a sync mechanism?
- Flag: data duplicated in multiple places with no clear source of truth

**Data types:**
- Are numeric IDs using appropriate types? (INT for <2B rows, BIGINT beyond; UUID adds 16 bytes per row — acceptable or not?)
- Are timestamps stored with timezone? (`TIMESTAMP WITH TIME ZONE` not `TIMESTAMP`)
- Are monetary values stored as `DECIMAL/NUMERIC`, never as `FLOAT`? (Float arithmetic causes rounding errors in financial calculations)
- Are strings bounded? (VARCHAR(255) everywhere is a code smell — it means nobody thought about the data)

**Nullability:**
- Unexpected NULL columns (nullable columns that are always populated in practice = implicit NOT NULL constraint not enforced)
- Columns that should be NULL but aren't (overuse of empty string as null proxy)

**Soft delete patterns:**
- `deleted_at` or `is_deleted` columns: do indexes include the `deleted_at IS NULL` predicate?
- Without it: all "active record" queries scan deleted rows too. At scale this becomes a full-table scan.
- Fix: partial index `WHERE deleted_at IS NULL`

**Audit and temporal data:**
- Is `created_at`/`updated_at` present on all mutable tables?
- Is there audit history for compliance-sensitive tables (user records, financial transactions)?

---

## PHASE 5 — Sharding and Partitioning Strategy

**Only applies if:** data volume exceeds single-server capacity, or write throughput exceeds single-server capacity.

**Shard key evaluation:**
- Does the shard key distribute data evenly? (High-cardinality shard keys distribute better)
- Does the shard key align with access patterns? (Queries that filter by shard key are single-shard; queries that don't require scatter-gather)
- Is there a hot shard risk? (e.g., sharding by user_id when 1% of users generate 80% of traffic → hash sharding avoids this)
- Is there a time-based hot partition? (e.g., sharding a time-series by month → current month becomes a hotspot)

**Sharding strategies:**
| Strategy | Best for | Risk |
|----------|---------|------|
| Hash sharding | Even distribution, KV access | Painful to rebalance; range queries require scatter-gather |
| Range sharding | Time-series, range queries | Hot partition at the "leading edge" |
| Directory sharding | Flexible remapping | Directory becomes critical path latency |
| Consistent hashing | Minimal movement on rebalance | Requires careful key design |

**Cross-shard join risk:** flag any schema design that requires JOINs across shard boundaries. These are O(n) scatter-gather operations — expensive at scale and often the first thing that causes a major performance cliff.

---

## PHASE 6 — Consistency and Isolation

**For relational databases:**
- What isolation level is being used? (default READ COMMITTED in PostgreSQL — is this sufficient?)
- Are there race conditions that require SERIALIZABLE isolation or explicit locking?
- Are there long-running transactions that hold locks and block concurrent writes?
- Are database-level foreign key constraints enabled? (ORM-only constraints are not enforced at the DB level and break on bulk imports/migrations)

**For distributed databases (Cassandra, DynamoDB, MongoDB):**
- What consistency level is configured? (QUORUM, ONE, EVENTUAL)
- Are there operations that require strong consistency but are using eventual consistency? (e.g., financial balance calculations)
- Is the application designed to handle stale reads?

**Write patterns:**
- Are upserts handled correctly? (check-then-insert has a TOCTOU race; use INSERT ... ON CONFLICT)
- Are bulk imports wrapped in transactions to allow rollback?

---

## PHASE 7 — NoSQL vs. Relational Fit Assessment

If the database technology choice is in question:

| Factor | Relational | Wide-column | Document | Key-value | Time-series |
|--------|-----------|------------|---------|----------|-------------|
| Complex queries | ✅ | ❌ | ⚠️ | ❌ | ❌ |
| Strong consistency | ✅ | ⚠️ | ⚠️ | ⚠️ | ⚠️ |
| High write throughput | ⚠️ | ✅ | ⚠️ | ✅ | ✅ |
| Flexible schema | ❌ | ⚠️ | ✅ | ✅ | ❌ |
| Operational simplicity | ✅ | ❌ | ⚠️ | ✅ | ⚠️ |
| Ad hoc reporting | ✅ | ❌ | ❌ | ❌ | ❌ |

**Default recommendation:** start relational. Migrate to NoSQL only when you have measured a specific bottleneck that a specific NoSQL technology solves. Premature NoSQL adoption is one of the most common sources of tech debt in distributed systems.

**Connection pool sizing and strategy:**

```
Max safe connections ≈ 100–200 before connection overhead dominates
App servers × pool_size_per_server must be < max_connections
At high app server count: use PgBouncer (transaction-mode pooling) in front of Postgres
```

| Pool mode | Best for | Caveat |
|-----------|---------|--------|
| Transaction pooling (PgBouncer) | High connection count, short queries | Cannot use prepared statements, session-level features |
| Session pooling | Applications using prepared statements, temp tables | Each session holds a connection — limits concurrency |
| Connection per request | Simple apps, low concurrency | Fails at scale — connection setup overhead dominates |

**Pool sizing formula:**
```
Optimal pool size ≈ (core_count × 2) + effective_spindle_count
For SSDs: pool_size ≈ core_count × 2 + 1
Example: 4 cores, SSD → pool_size = 9 per app server
```

**Diagnostic (PostgreSQL):**
```sql
-- Current connection usage
SELECT state, count(*) FROM pg_stat_activity GROUP BY state;

-- Long-running queries (potential connection hog)
SELECT pid, now() - pg_stat_activity.query_start AS duration, query
FROM pg_stat_activity
WHERE state = 'active' AND now() - pg_stat_activity.query_start > interval '30 seconds';
```

**Diagnostic (MySQL / Aurora MySQL — common in high-scale ecommerce and consumer platforms):**
```sql
-- Current connections by state
SELECT STATE, COUNT(*) as cnt FROM information_schema.PROCESSLIST GROUP BY STATE ORDER BY cnt DESC;

-- Long-running queries
SELECT ID, USER, HOST, DB, TIME, STATE, LEFT(INFO, 100) as query
FROM information_schema.PROCESSLIST
WHERE TIME > 30 AND COMMAND != 'Sleep'
ORDER BY TIME DESC;

-- Slow query log — check if enabled
SHOW VARIABLES LIKE 'slow_query_log%';
SHOW VARIABLES LIKE 'long_query_time';
-- Enable: SET GLOBAL slow_query_log = 'ON'; SET GLOBAL long_query_time = 1;

-- Query plan (MySQL equivalent of EXPLAIN ANALYZE)
EXPLAIN FORMAT=JSON SELECT * FROM orders WHERE user_id = 123 AND status = 'pending'\G
-- Key fields: type (ALL=full scan, ref=index, const=best), rows (estimated rows examined)
-- Red flags: type=ALL on large tables, key=NULL (no index used), Extra=Using filesort

-- Table sizes (find largest tables)
SELECT TABLE_NAME, TABLE_ROWS,
  ROUND(DATA_LENGTH/1024/1024, 2) AS data_MB,
  ROUND(INDEX_LENGTH/1024/1024, 2) AS index_MB
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE()
ORDER BY DATA_LENGTH + INDEX_LENGTH DESC LIMIT 20;

-- Index usage — find unused indexes (expensive to maintain, zero benefit)
SELECT OBJECT_SCHEMA, OBJECT_NAME, INDEX_NAME, COUNT_READ, COUNT_WRITE
FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE OBJECT_SCHEMA = DATABASE() AND INDEX_NAME IS NOT NULL
  AND COUNT_READ = 0
ORDER BY OBJECT_NAME;

-- InnoDB status — lock waits, deadlocks, buffer pool hit rate
SHOW ENGINE INNODB STATUS\G
-- Sections to check: TRANSACTIONS (lock wait), BUFFER POOL (pages read/written)

-- Buffer pool hit rate (should be > 99%)
SELECT (1 - (Innodb_buffer_pool_reads / Innodb_buffer_pool_read_requests)) * 100
  AS buffer_pool_hit_rate
FROM (
  SELECT VARIABLE_VALUE AS Innodb_buffer_pool_reads FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads'
) r, (
  SELECT VARIABLE_VALUE AS Innodb_buffer_pool_read_requests FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests'
) rr;
```

**MySQL-specific gotchas principal engineers must know:**

| Issue | Symptom | Fix |
|-------|---------|-----|
| Missing index on FK | JOIN is slow even with small tables | Add `INDEX` on FK column (MySQL doesn't auto-create) |
| `SELECT *` with `LIMIT` on large table | Full scan before limit | Use covering index + `WHERE id > last_seen_id` keyset pagination |
| `TEXT`/`BLOB` inline | Row bloat, I/O amplification | Store in separate table or object storage (S3) |
| No `innodb_buffer_pool_size` tuning | Hit rate < 99%, high disk I/O | Set to 70-80% of available RAM |
| DDL locks tables | ALTER TABLE blocks reads/writes | Use `gh-ost` or `pt-online-schema-change` for large tables |
| `utf8` instead of `utf8mb4` | Emojis stored as `?`, data corruption | Migrate charset: `ALTER TABLE t CONVERT TO CHARACTER SET utf8mb4` |
| Implicit type cast in WHERE | Index not used | Ensure column type matches query param type |

```bash
# Check MySQL version and key config (read-only)
mysql -e "SELECT VERSION();" 2>/dev/null
mysql -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';" 2>/dev/null
mysql -e "SHOW VARIABLES LIKE 'max_connections';" 2>/dev/null
mysql -e "SHOW VARIABLES LIKE 'default_storage_engine';" 2>/dev/null
```

**Temporal data modeling (soft deletes, audit trails, versioning):**

| Pattern | Use case | Implementation | Trade-off |
|---------|---------|---------------|-----------|
| Soft delete (`deleted_at`) | Recoverability, compliance | Add `deleted_at TIMESTAMP`, partial index `WHERE deleted_at IS NULL` | Bloats table, queries must filter |
| Event sourcing | Full audit trail, temporal queries | Append-only events table, materialized current state | Complex reads, storage growth |
| Temporal table (system-versioned) | Regulatory audit, point-in-time queries | `PERIOD FOR SYSTEM_TIME`, history table | Database-specific support |
| Tombstone + TTL | Distributed systems (Cassandra) | Mark deleted, compact after TTL | Eventual consistency of deletes |

**Soft delete gotchas:**
- Every query on the table must include `WHERE deleted_at IS NULL` — enforce via ORM default scope or database view
- Unique constraints must be partial: `UNIQUE(email) WHERE deleted_at IS NULL` — otherwise deleted records block re-creation
- Foreign keys to soft-deleted records become dangling — cascade soft-delete or check in application layer

---

## PHASE 7b — Cache Design Review

Caching is where most database performance problems get solved incorrectly. Adding a cache is easy; invalidating it correctly is the second hardest problem in computer science (after naming). A wrong invalidation strategy causes stale data in production — which for ecommerce means wrong prices, overselling, or wrong inventory counts.

### Cache Strategy Selection

| Strategy | How it works | When to use | Stale risk |
|----------|-------------|-------------|-----------|
| **TTL-only** | Data expires after fixed time, serve stale until then | Tolerable staleness OK (news feed, recommendations) | Guaranteed stale for TTL duration |
| **Cache-aside** (lazy loading) | Miss → load from DB → cache → return; Write → invalidate cache | Read-heavy, tolerate cold-start misses | Window between write and invalidation |
| **Write-through** | Write updates cache + DB simultaneously | Write-heavy that reads same data frequently | None (always consistent) |
| **Write-behind** (write-back) | Write to cache → async flush to DB | Highest write throughput; DB is not hot path | Data loss on cache failure |
| **Read-through** | Cache sits in front; always reads through cache | Simplify application code; cache manages loading | Same as cache-aside |

**Ecommerce-specific strategy decisions:**
```
Inventory count:       Cache-aside + short TTL (5s) — never write-behind (oversell risk)
Product catalog:       Write-through + CDN (Cloudflare/Fastly) — invalidate on publish
Price:                 TTL-only (30s) is acceptable for display; invalidate explicitly for checkout
Cart:                  Session store (Redis) — TTL = session duration; no DB fallback needed
User session/auth:     TTL-only — Redis with sliding TTL; no DB on hit
Order history:         No cache — consistency required; query DB
```

### Cache Invalidation Patterns

**Pattern 1: Key-based invalidation (most common)**
```python
# On write: delete the specific key
def update_product(product_id, data):
    db.update(product_id, data)
    cache.delete(f"product:{product_id}")           # invalidate main key
    cache.delete(f"product_list:category:{data.category_id}")  # invalidate list caches too
    # Warning: list caches with pagination are hard to invalidate — see pattern 3
```

**Pattern 2: Event-driven invalidation (for distributed systems)**
```
Producer: publishes ProductUpdated event to Kafka
Consumer (cache invalidator):
  ProductUpdated → cache.delete(product:{id})
  CategoryChanged → cache.delete(product_list:category:{old_id})
                  → cache.delete(product_list:category:{new_id})

Advantage: cache invalidation logic lives in one place, not scattered across services
Risk: event delivery lag = cache staleness window. Use event timestamp to detect.
```

**Pattern 3: Cache stampede prevention (high-traffic systems)**
```
Problem: Cache expires → 1000 simultaneous requests hit DB → DB overloads → cascade failure

Fix 1: Mutex lock (Redis SETNX) — only one request rebuilds cache, others wait
Fix 2: Probabilistic early expiration (PER) — randomly rebuild before expiry
Fix 3: Background refresh — separate process refreshes cache before TTL, never expires

# Redis mutex for cache stampede prevention
SETNX lock:product:{id} 1 EX 10  # 10-second lock
if (lock acquired):
  data = db.get(product_id)
  SETEX product:{id} 300 data
  DEL lock:product:{id}
else:
  wait/retry or serve stale
```

**Pattern 4: Cache warming (flash sales, new launches)**
```bash
# Pre-warm cache before high-traffic events
# Run before: product launch, flash sale, marketing campaign

# Warm top-N products by expected traffic (read-only analysis)
SELECT product_id, view_count
FROM product_analytics
WHERE date >= NOW() - INTERVAL '7 days'
ORDER BY view_count DESC
LIMIT 1000;
# Then: load each product into cache before traffic hits
# for product_id in top_1000: redis.setex(f"product:{product_id}", 3600, fetch_and_serialize(product_id))
```

### Cache Anti-Patterns to Flag

```bash
# Find cache keys built from user input (cache poisoning risk)
grep -rn "cache\.set\|redis\.set\|cache\.get" --include="*.ts" --include="*.py" . | \
  grep "req\.\|request\.\|user\.\|query\." | head -10
# Any cache key that includes unvalidated user input can be poisoned

# Find missing TTLs (indefinite cache growth)
grep -rn "cache\.set\|redis\.set\|HSET\|MSET" --include="*.ts" --include="*.py" . | \
  grep -v "EX \|expire\|TTL\|ttl\|timeout" | head -10
# Every cache entry MUST have a TTL — otherwise Redis hits maxmemory and evicts randomly

# Find caches keyed only on object ID without version/tenant
grep -rn "\"product:\"\|\"user:\"\|\"order:\"" --include="*.ts" --include="*.py" . | head -10
# Multi-tenant: cache key must include tenant_id: product:{tenant_id}:{product_id}
# Otherwise tenant A sees tenant B's data — security incident
```

### Cache Sizing

```
Redis memory per entry ≈ key_size + value_size + 64 bytes overhead
Example: product cache (1KB per product, 100k products, 2x overhead) = ~200MB

Redis maxmemory policy for application caches: allkeys-lru (evict least-recently-used)
Redis maxmemory policy for session stores: volatile-lru (evict only keys with TTL)

Warning: setting no maxmemory policy = Redis will crash the server on OOM
```

---

## PHASE 8 — Time-Series and Vector Database Review

### Time-Series Databases (ClickHouse, TimescaleDB, InfluxDB, Prometheus)

Time-series databases are specialized for append-only, time-ordered data with high write throughput and time-range aggregation queries. Using a general-purpose relational database for time-series workloads is one of the most common scaling mistakes.

**Signal that you need a time-series DB:**
- Writes are predominantly appends (metrics, events, IoT, logs)
- Queries are always time-range bounded (last 24h, last 7d)
- High cardinality (millions of unique tag combinations)
- Retention policies required (auto-expire data after N days)
- Aggregation queries: rate(), sum over time, percentile over time

**Technology selection:**

| Technology | Best for | Write throughput | Compression | SQL support |
|-----------|---------|-----------------|------------|-------------|
| ClickHouse | Analytics, high-cardinality events | Very high (millions/s) | Excellent (10–100×) | Yes (subset) |
| TimescaleDB | PostgreSQL-native time-series, mixed workloads | High | Good (8–10×) | Full PostgreSQL |
| InfluxDB | Metrics and monitoring, simple queries | High | Good | Flux/InfluxQL |
| Prometheus | Short-term metrics (15 days default), alerting | High | Good | PromQL |
| Apache Druid | Real-time OLAP, sub-second aggregations | Very high | Excellent | SQL |

**ClickHouse schema review:**
```sql
-- Good: Partition by time, order by (low-cardinality first, timestamp last)
CREATE TABLE events (
  timestamp DateTime,
  service LowCardinality(String),
  region LowCardinality(String),
  user_id UInt64,
  event_type LowCardinality(String),
  payload String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)   -- monthly partitions → efficient range deletes
ORDER BY (service, event_type, timestamp)  -- sort key: filter cols first, timestamp last
TTL timestamp + INTERVAL 90 DAY;   -- auto-expire after 90 days

-- Check current table size and compression ratio (read-only)
SELECT
  table,
  formatReadableSize(sum(data_compressed_bytes)) AS compressed,
  formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
  round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 2) AS ratio
FROM system.columns
WHERE database = currentDatabase()
GROUP BY table ORDER BY sum(data_compressed_bytes) DESC;
```

**TimescaleDB hypertable review:**
```sql
-- Check hypertable chunk size and compression
SELECT hypertable_name, chunk_name,
  pg_size_pretty(before_compression_total_bytes) AS before,
  pg_size_pretty(after_compression_total_bytes) AS after
FROM chunk_compression_stats('metrics')
ORDER BY chunk_name DESC LIMIT 10;

-- Check continuous aggregates (materialized rollups)
SELECT view_name, materialized_only FROM timescaledb_information.continuous_aggregates;

-- Performance: always use time_bucket(), not date_trunc(), for aggregations
-- date_trunc() bypasses TimescaleDB's query planner optimizations
```

**Common time-series mistakes:**
- Storing high-cardinality fields as Prometheus labels (Prometheus cardinality explosion — each unique label combination is a new time-series)
- Not using columnar compression in ClickHouse for string fields (use LowCardinality for fields with <10k unique values)
- Missing TTL policies — time-series data grows unboundedly without retention
- Using indexes on high-cardinality columns instead of ordering MergeTree by them
- Querying without time bounds (no `WHERE timestamp > now() - INTERVAL 7 DAY`) — full table scan

---

### Vector Databases (pgvector, Pinecone, Weaviate, Qdrant, Milvus)

Vector databases are specialized for similarity search (k-NN) on high-dimensional embedding vectors. Required for any LLM-backed retrieval, semantic search, recommendation, or multimodal system.

**Signal that you need a vector DB:**
- Storing ML model embeddings (text, image, audio)
- Semantic similarity search ("find documents similar to X")
- RAG (Retrieval-Augmented Generation) for LLM applications
- Recommendation systems based on content similarity
- Anomaly detection on vector representations

**Technology selection:**

| Technology | Best for | Max vectors | ANN algorithm | Metadata filtering |
|-----------|---------|------------|--------------|-------------------|
| pgvector | PostgreSQL-native, < 10M vectors, mixed workloads | ~10M | HNSW, IVFFlat | Full SQL |
| Pinecone | Managed, low-ops, production at scale | Billions | Proprietary | Basic |
| Qdrant | High filtering, on-prem/cloud, Rust-native | Billions | HNSW | Advanced |
| Weaviate | Multi-modal, GraphQL, auto-vectorization | Billions | HNSW | Advanced |
| Milvus | Billion-scale, GPU acceleration | Billions+ | IVFFlat, HNSW | SQL-like |

**pgvector schema review:**
```sql
-- Check index type and configuration
SELECT indexname, indexdef FROM pg_indexes
WHERE tablename = 'embeddings';

-- HNSW index (preferred for high recall, lower insert speed)
CREATE INDEX ON embeddings USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 64);
-- m: connections per node (higher = better recall, more memory)
-- ef_construction: search width during build (higher = better recall, slower build)

-- IVFFlat index (faster inserts, lower recall)
CREATE INDEX ON embeddings USING ivfflat (embedding vector_cosine_ops)
WITH (lists = 100);
-- lists ≈ sqrt(rows) — reindex when rows change significantly

-- Check query performance
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, content, embedding <=> '[0.1, 0.2, ...]'::vector AS distance
FROM embeddings
WHERE category = 'product'   -- metadata filter
ORDER BY distance LIMIT 10;
-- Warning: without proper index, this is O(n) — catastrophic at scale
```

**Vector DB review checklist:**
- [ ] Dimensionality consistent with embedding model (text-embedding-3-small = 1536d, ada-002 = 1536d, nomic-embed = 768d)
- [ ] Index type chosen based on write/read pattern (HNSW for read-heavy, IVFFlat for write-heavy)
- [ ] Metadata filtering plan — can filter predicates be applied BEFORE or AFTER ANN search? (pre-filtering is accurate but slow; post-filtering is fast but may return <k results)
- [ ] Embedding versioning — when embedding model changes, all existing vectors must be re-embedded and re-indexed
- [ ] Normalization — cosine similarity requires L2-normalized vectors; verify at ingestion time
- [ ] Chunking strategy for RAG — chunk size affects recall; 256–512 tokens with 50 token overlap is a common starting point

---

## PHASE 9 — Migration Plan Review (if applicable)

If a migration plan is provided:

- [ ] Are schema migrations backward compatible? (new columns nullable or with defaults; no column renames without alias period)
- [ ] Does any migration lock tables? (DDL locks in PostgreSQL; online DDL in MySQL with pt-online-schema-change or gh-ost)
- [ ] Is there a rollback script for every migration?
- [ ] What is the estimated migration duration at production data volume? (test on a copy first)
- [ ] Are large backfills batched? (update 1,000 rows at a time, not all rows in one transaction)

> **Script available:** run `bash principal/scripts/migration-safety.sh [migrations-dir]` to statically
> analyze SQL migration files for zero-downtime safety. Checks 10 rules: ADD COLUMN NOT NULL without
> DEFAULT, DROP COLUMN without 3-phase pattern, RENAME, ALTER TYPE, missing CONCURRENTLY on index
> creation, SET NOT NULL without NOT VALID, and TRUNCATE/DELETE without WHERE.

---

## PHASE 9 — Prioritized Findings

### 🔴 Critical — Fix Before Launch
Schema or index issues that will cause incorrect data, data loss, or service failure at scale.

### 🟡 High — Fix This Quarter
Performance issues that will cause degradation at 10× current load.

### 🟢 Medium — Next Quarter
Design improvements that reduce future operational burden.

---

## OUTPUT

1. **Access pattern summary** (the queries this schema is optimized for — and whether it's actually optimized for them)
2. **Critical findings** with specific table/column references
3. **Index audit results** (missing indexes, over-indexed tables, composite index corrections)
4. **N+1 risks** with code locations and recommended fixes
5. **Schema issues** (type mismatches, nullability, soft-delete patterns)
6. **Sharding/consistency assessment** (if applicable)
7. **Prioritized remediation table**

**Save:** use the Write tool to save this document to `docs/reviews/db-review-[service-name].md` (or user-specified path).

**What to run next:**
- `/principal:migration` — if schema changes are needed, plan the zero-downtime migration
- `scripts/migration-safety.sh [migrations-dir]` — pre-flight existing migration files for table-lock risks
- `/principal:perf-audit` — if slow queries were identified, do a full performance audit
- `/principal:scale-review` — if the schema review revealed scaling concerns
