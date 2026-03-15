---
name: migration
description: |
  Plan a zero-downtime system migration. Covers the three hardest migration patterns: strangler
  fig (incremental replacement), dual-write with verification (data migration), and blue-green
  with traffic shifting (infrastructure cutover). Produces a phased migration plan with rollback
  strategies at every phase gate, data verification queries, feature flag specifications, and a
  runbook for the migration day. Use when replacing a service, migrating databases, switching
  infrastructure providers, or any change that cannot be deployed atomically.
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - Write
  - AskUserQuestion
---

# /principal:migration — Zero-Downtime Migration Planning

You are acting as a staff engineer planning a migration. Migrations are the highest-risk work staff engineers do — a bad migration causes data loss, extended outages, and months of cleanup. Your job is to make every step reversible and every assumption verifiable.

**Core principle:** a migration plan without a rollback plan at every phase gate is not a plan — it is a prayer.

## GATHER CONTEXT

Ask for anything not provided:

1. **What is being migrated?** (service, database, infrastructure, API, library)
2. **Why?** (scaling limits, cost, EOL, compliance, tech debt)
3. **What is the source system?** (current architecture, data volume, traffic)
4. **What is the target system?** (already built, or needs to be built?)
5. **What is the downtime tolerance?** (zero, scheduled maintenance window, degraded acceptable)
6. **What is the data volume?** (rows, GB, rate of change during migration)
7. **What teams are affected?** (consumers of APIs, downstream dependencies)
8. **What is the timeline?** (hard deadline, or flexible?)

If in a repo, read existing system code, configs, and migration scripts:

```bash
# Find existing migration scripts
find . -name "*migrat*" -o -name "*schema*" | head -10

# Find service clients that depend on what's being migrated
grep -rn "SERVICE_URL\|BASE_URL\|import.*client" --include="*.ts" --include="*.py" . | head -20

# Check current schema
find . -name "*.sql" -path "*migration*" | sort | tail -10
```

> **Script available:** run `bash principal/scripts/migration-safety.sh [migrations-dir]` to
> pre-flight SQL migrations for zero-downtime safety. Catches table-locking DDL, column drops
> without the 3-phase expand-contract pattern, missing CONCURRENTLY on index creation, and
> TRUNCATE/DELETE without WHERE — before they hit production.

---

## PHASE 1 — Migration Pattern Selection

Choose the pattern based on the migration type:

### Pattern A: Strangler Fig (Incremental Service Replacement)

**Use when:** replacing a monolith with microservices, or replacing a service with a new implementation.

```
Phase 1: Build new service alongside old
Phase 2: Route a subset of traffic to new service (feature flag or % rollout)
Phase 3: Gradually shift traffic, validate at each increment
Phase 4: When 100% on new service and stable, decommission old
```

**Key risk:** the old and new systems must produce identical results during the overlap period.

**Verification pattern:**
```bash
# Shadow traffic: send requests to both, compare responses
# DO NOT use new service responses for production during shadow phase
diff <(curl -s old-service/api/endpoint) <(curl -s new-service/api/endpoint)
```

### Pattern B: Dual-Write with Verification (Data Migration)

**Use when:** migrating data from one database/store to another while the system is live.

```
Phase 1: Set up target database, begin replicating from source
Phase 2: Enable dual-write: application writes to BOTH source and target
Phase 3: Backfill historical data from source to target
Phase 4: Verify data consistency between source and target
Phase 5: Switch reads to target (feature flag)
Phase 6: Stop writes to source, target is now primary
Phase 7: Decommission source after soak period
```

**Data verification queries:**
```sql
-- Row count comparison
SELECT 'source' AS db, count(*) FROM source_db.table_name
UNION ALL
SELECT 'target' AS db, count(*) FROM target_db.table_name;

-- Checksum comparison (sample 10k rows)
SELECT md5(string_agg(row_hash::text, ',' ORDER BY id))
FROM (
  SELECT id, md5(row_to_json(t)::text) AS row_hash
  FROM table_name t
  ORDER BY id LIMIT 10000
) sub;

-- Find records in source but not in target
SELECT s.id FROM source_table s
LEFT JOIN target_table t ON s.id = t.id
WHERE t.id IS NULL
LIMIT 100;

-- Find records with mismatched values
SELECT s.id, s.updated_at AS source_updated, t.updated_at AS target_updated
FROM source_table s
JOIN target_table t ON s.id = t.id
WHERE s.updated_at != t.updated_at
LIMIT 100;
```

### Pattern C: Blue-Green Cutover (Infrastructure Migration)

**Use when:** switching infrastructure providers, upgrading database engines, or any migration that requires a clean cutover.

```
Phase 1: Provision green environment (identical to blue)
Phase 2: Deploy application to green, run full test suite
Phase 3: Sync data to green (replication or snapshot + replay)
Phase 4: Shift traffic to green (DNS, load balancer, feature flag)
Phase 5: Soak period on green (monitor for 24-72 hours)
Phase 6: Decommission blue
```

---

## PHASE 2 — Phased Migration Plan

For every migration, produce this structured plan:

```markdown
# Migration Plan: [Title]

**Pattern:** Strangler Fig / Dual-Write / Blue-Green
**Timeline:** [start date] → [target completion]
**Rollback budget:** [how quickly can we roll back at each phase?]
**Data volume:** [rows/GB to migrate]
**Traffic during migration:** [RPS, read/write ratio]

## Pre-Migration Checklist

- [ ] Target system deployed and passing health checks
- [ ] Monitoring dashboards configured for both source and target
- [ ] Alerting configured: latency, error rate, data drift for target
- [ ] Feature flags created for traffic shifting
- [ ] Rollback runbook written and reviewed
- [ ] Stakeholders notified (affected teams, on-call, customer support)
- [ ] Maintenance window communicated (if applicable)
- [ ] Backup of source system verified

## Phase 1: [Setup / Shadow / Dual-Write]

**Duration:** [X days/weeks]
**Goal:** [what this phase accomplishes]
**Entry criteria:** [what must be true before starting]

### Actions
1. [specific action]
2. [specific action]

### Verification
- [ ] [specific check — with command or query to run]
- [ ] [specific check]

### Rollback procedure
1. [exact steps to undo this phase]
2. Estimated rollback time: [X minutes/hours]

### Phase gate
Do NOT proceed to Phase 2 until ALL of the following are true:
- [ ] [measurable criterion]
- [ ] [measurable criterion]
- [ ] Soak period: [X hours/days] with no anomalies

---

## Phase 2: [Traffic Shift / Read Cutover]

[Same structure: goal, actions, verification, rollback, phase gate]

---

## Phase 3: [Full Cutover / Write Cutover]

[Same structure]

---

## Phase 4: [Decommission Source]

**Do NOT decommission until:**
- [ ] Target has been primary for [X days] with no rollbacks
- [ ] All consumers confirmed migrated (list each consumer)
- [ ] Source data archived per retention policy
- [ ] Feature flags cleaned up (removed, not just disabled)

### Decommission actions
1. Remove source from load balancer / DNS
2. Take final backup
3. Archive source data to cold storage
4. Remove source infrastructure
5. Remove dual-write code paths
6. Clean up feature flags
```

---

## PHASE 3 — Feature Flag Specification

Every migration that uses traffic shifting needs explicit feature flag definitions:

```yaml
# Migration feature flags
flags:
  - name: migration_shadow_traffic
    description: "Send shadow traffic to new service (responses discarded)"
    type: boolean
    default: false
    rollout: "0% → 10% → 50% → 100%"

  - name: migration_read_from_target
    description: "Read from target database instead of source"
    type: percentage
    default: 0
    rollout: "0% → 1% → 10% → 50% → 100%"
    rollback: "Set to 0 immediately if error rate > 0.1%"

  - name: migration_write_to_target
    description: "Write to target database (source writes continue)"
    type: boolean
    default: false
    prerequisite: migration_read_from_target == 100%
    rollback: "Set to false, resume source-only writes"
```

---

## PHASE 4 — Migration Day Runbook

```markdown
# Migration Runbook: [Title]

## Contacts
| Role | Person | Contact |
|------|--------|---------|
| Migration lead | | |
| On-call SRE | | |
| Database admin | | |
| Incident commander (if needed) | | |

## Pre-Flight (T-60 minutes)
- [ ] Verify source system healthy: `curl SOURCE_HEALTH`
- [ ] Verify target system healthy: `curl TARGET_HEALTH`
- [ ] Verify monitoring dashboards loaded and showing expected values
- [ ] Verify rollback procedure is documented and tested
- [ ] Communicate start to stakeholders

## Execution
[Phase-by-phase steps with exact commands]

## Monitoring During Migration
Watch these metrics continuously:

```bash
# Error rate comparison
# Source: should remain stable
# Target: should match source within 0.1%

# Latency comparison
# Target P99 should be within 20% of source P99

# Data consistency (run every 15 minutes during dual-write)
# [verification query from Phase 2]
```

## Rollback Triggers
Immediately roll back if ANY of these occur:
- Error rate > [X]% on target
- P99 latency > [X]ms on target
- Data consistency check fails
- Any data loss detected

## Rollback Procedure
1. [exact step-by-step — no ambiguity]
2. [estimated time to complete rollback]
3. [how to verify rollback succeeded]

## Post-Migration Verification (T+1 hour)
- [ ] All health checks passing
- [ ] Error rate at pre-migration baseline
- [ ] Latency at pre-migration baseline
- [ ] Data consistency verified
- [ ] No customer-reported issues

## Post-Migration Cleanup (T+7 days)
- [ ] Remove dual-write code paths
- [ ] Clean up feature flags
- [ ] Archive source data
- [ ] Decommission source infrastructure
- [ ] Update architecture documentation
```

---

## PHASE 5 — Event Schema Migration (Kafka / Avro / Protobuf)

Schema migrations in event-driven systems are fundamentally harder than database migrations: **consumers and producers deploy independently, events persist in topics for days or weeks, and a bad schema change can silently corrupt downstream consumers without an error until it's too late.**

### Schema Compatibility Rules

Before any Avro/Protobuf change, determine the required compatibility level:

| Compatibility | Allows | Breaks |
|--------------|--------|--------|
| `BACKWARD` | Add optional fields, remove fields | Adding required fields, renaming fields |
| `FORWARD` | Remove optional fields, add fields | Removing required fields |
| `FULL` | Only add optional fields | Everything else |
| `NONE` | Anything | Safety — do not use in production |

**Default rule:** Use `BACKWARD` for consumer-first deployments. Use `FORWARD` for producer-first. Use `FULL` for high-stability shared contracts.

### Checking Compatibility Before Deployment

```bash
# ⚠️ Ask user to confirm Schema Registry URL before running
# Confluent Schema Registry: check compatibility of a new schema
curl -X POST -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  "http://SCHEMA_REGISTRY_HOST:8081/compatibility/subjects/TOPIC_NAME-value/versions/latest" \
  --data '{"schema": "{\"type\":\"record\",\"name\":\"Event\",\"fields\":[...new schema...]}"}' | \
  python3 -m json.tool

# List all versions of a schema subject (read-only)
curl -s "http://SCHEMA_REGISTRY_HOST:8081/subjects/TOPIC_NAME-value/versions"

# Get a specific schema version (read-only)
curl -s "http://SCHEMA_REGISTRY_HOST:8081/subjects/TOPIC_NAME-value/versions/LATEST" | python3 -m json.tool

# AWS Glue Schema Registry (read-only)
aws glue get-schema --schema-id "SchemaArn=arn:aws:glue:us-east-1:ACCOUNT:schema/registry/schema-name" --no-cli-pager

# Protobuf: check for breaking changes using buf (MIT-licensed)
# Install: brew install bufbuild/buf/buf
buf breaking --against '.git#branch=main' proto/

# Avro: diff two schema files using the avro-tools CLI (read-only)
# java -jar avro-tools.jar getschema old.avsc > old_canonical.json
# java -jar avro-tools.jar getschema new.avsc > new_canonical.json
# diff old_canonical.json new_canonical.json
```

### Pattern D: Event Schema Migration (Incremental, Consumer-Safe)

**Use when:** changing the schema of a Kafka/Pulsar/Kinesis event type, where producers and consumers must be upgraded independently.

```
Phase 1: Add new fields as OPTIONAL to existing schema (never rename or remove)
Phase 2: Deploy new producers that write BOTH old and new fields (dual-write event fields)
Phase 3: Deploy consumers that read new fields with fallback to old fields
Phase 4: Verify all consumer groups have consumed past the "last old-format message" offset
Phase 5: Deprecate old fields — stop writing them from producers
Phase 6: After consumer lag = 0 on all groups and no old-format messages remain, remove old fields

NEVER skip phases: consumers at old code will silently drop unknown fields (Avro) or
fail deserialization (Protobuf) if required fields are added or fields are renamed.
```

### Consumer Group Lag Check (before decommissioning old fields)

```bash
# Confluent Kafka: check consumer group lag for all groups on a topic
# ⚠️ Confirm Kafka connection before running
kafka-consumer-groups.sh --bootstrap-server KAFKA_BROKER:9092 \
  --describe --all-groups 2>/dev/null | grep "TOPIC_NAME"

# AWS MSK / self-hosted Kafka: list all consumer groups (read-only)
kafka-consumer-groups.sh --bootstrap-server KAFKA_BROKER:9092 --list

# Find consumer groups reading from a specific topic (read-only)
kafka-consumer-groups.sh --bootstrap-server KAFKA_BROKER:9092 --list | \
  xargs -I{} kafka-consumer-groups.sh --bootstrap-server KAFKA_BROKER:9092 \
  --describe --group {} 2>/dev/null | grep "TOPIC_NAME"

# Check current offsets vs end offsets (lag)
kafka-consumer-groups.sh --bootstrap-server KAFKA_BROKER:9092 \
  --describe --group YOUR_CONSUMER_GROUP | \
  awk 'NR>1 {lag=$6; if(lag>0) print "LAG:", lag, "on", $1, "partition", $3}'
```

### Protobuf Field Number Rules (Do Not Violate)

```protobuf
// ✅ SAFE: Add new optional fields with NEW field numbers
message UserEvent {
  string user_id = 1;           // existing — never change
  string email = 2;             // existing — never change
  string display_name = 3;      // NEW optional field — safe to add
}

// ❌ NEVER DO THIS — breaks all existing consumers
message UserEvent {
  string user_id = 1;
  string display_name = 2;      // renamed email to display_name — BREAKS deserialization
  // email removed — existing consumers will get empty string
}

// ❌ NEVER reuse a field number, even if you removed the original field
// Mark removed fields as reserved:
message UserEvent {
  string user_id = 1;
  reserved 2;                   // email was here — reserve so no one reuses
  reserved "email";             // also reserve the name
  string display_name = 3;
}
```

### Schema Registry Migration Checklist

```markdown
Pre-migration:
- [ ] Compatibility mode set to BACKWARD or FULL for all affected subjects
- [ ] `buf breaking` (Protobuf) or schema registry compatibility check passes
- [ ] All consumer groups for affected topics identified and owners notified
- [ ] Consumer groups' current max lag documented (baseline)

During migration:
- [ ] New fields added as optional only
- [ ] Producers deployed with dual-write (old + new fields) for N days soak period
- [ ] All consumer deployments updated to read new fields

Pre-decommission:
- [ ] Consumer lag = 0 for ALL groups on affected topics
- [ ] No messages with old-format fields remain in topic (topic retention window passed)
- [ ] Schema registry version with old fields deprecated (not deleted — preserve history)

Post-migration:
- [ ] Old field writes removed from producers
- [ ] Old field reads removed from consumers (cleanup PR)
- [ ] Schema registry compatibility mode optionally tightened
```

---

## PHASE 6 — Self-Review

- [ ] Does every phase have a rollback procedure with estimated time?
- [ ] Are phase gates specific and measurable (not "looks good")?
- [ ] Is the feature flag spec complete with rollback triggers?
- [ ] Does the runbook have exact commands, not "check the metrics"?
- [ ] Is the data verification comprehensive (row counts, checksums, missing records)?
- [ ] Are all consuming teams identified and their migration tracked?
- [ ] Is there a soak period before decommissioning the source?

---

## OUTPUT

1. **Migration pattern selection** with justification
2. **Phased plan** with entry/exit criteria, verification queries, and rollback at every gate
3. **Feature flag specification**
4. **Migration day runbook** with exact commands and rollback triggers
5. **Risk assessment** (what could go wrong at each phase, and what's the blast radius)

**Save:** use the Write tool to save this document to `docs/migrations/[migration-name]-plan.md` (or user-specified path).

**What to run next:**
- `scripts/migration-safety.sh [migrations-dir]` — statically analyze SQL migration files for table-lock risks before running them
- `/principal:db-review` — review the target schema design if this is a database migration
- `/principal:adr` — record the migration pattern decision (Strangler Fig vs Dual-Write vs Blue-Green) and why
