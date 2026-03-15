---
name: incident
description: |
  Incident response and blameless postmortem. Two modes: RESPOND (active incident — structured
  timeline, severity classification, communication templates, mitigation tracking) and POSTMORTEM
  (after resolution — contributing factor analysis using Five Whys, action item tracking with
  owners, recurrence prevention, executive summary). Produces documents that improve organizational
  learning, not blame assignments.
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - Write
  - AskUserQuestion
---

# /principal:incident — Incident Response & Postmortem

## MODE SELECTION

- **RESPOND** — active incident, need structured coordination
- **POSTMORTEM** — incident resolved, need analysis and action items

---

## MODE: RESPOND

> **⚡ ACTIVE INCIDENT PROTOCOL:** Do NOT ask context-gathering questions before outputting the timeline template. Time lost in setup costs real users. Start the document immediately using whatever information the user has provided, fill in `[UNKNOWN]` for missing fields, and ask follow-up questions at the bottom after the template is in place.

### STEP 1 — Severity Classification

| Severity | Criteria | Response |
|----------|---------|----------|
| SEV-1 | Revenue-impacting, data loss, or security breach affecting customers | All-hands, exec notification, 15-min update cadence |
| SEV-2 | Degraded service for >10% of users, SLO breach | On-call + backup, 30-min updates |
| SEV-3 | Degraded service for <10% of users, single component failure | On-call, hourly updates |
| SEV-4 | Internal tooling, no customer impact | Normal priority, next business day |

### STEP 1b — Escalation Criteria

| Condition | Escalation action | Timeline |
|-----------|------------------|----------|
| SEV-1 confirmed | Page incident commander + engineering lead | Immediately |
| Customer data exposure suspected | Page security team + legal | Within 5 minutes |
| Revenue impact >$X/minute | Notify VP Engineering + CTO | Within 10 minutes |
| SEV-1 not mitigated in 30 min | Escalate to secondary on-call + skip-level | At 30 min mark |
| SEV-2 not mitigated in 1 hour | Escalate to incident commander | At 1 hour mark |
| Multiple SEV-2+ incidents same week | Trigger engineering freeze review | End of week |

**Principal-level decision:** if the incident is caused by a recent deploy, the fastest mitigation is almost always **rollback first, investigate second**. Do not spend 30 minutes debugging when a 2-minute rollback restores service.

### STEP 2 — Incident Timeline

Start a running timeline. Every action, discovery, and decision gets a timestamped entry:

```markdown
## Incident Timeline: [Title]

**Severity:** SEV-[X]
**Incident Commander:** [name]
**Status:** Investigating | Identified | Mitigating | Resolved
**Impact:** [who is affected, what they see]
**Start Time:** YYYY-MM-DD HH:MM UTC

| Time (UTC) | Actor | Action / Discovery |
|------------|-------|--------------------|
| HH:MM | @name | Alert fired: [alert name] — [metric] exceeded threshold |
| HH:MM | @name | Confirmed customer impact: [description] |
| HH:MM | @name | Hypothesis: [what we think is wrong] |
| HH:MM | @name | Attempted mitigation: [action taken] |
| HH:MM | @name | Mitigation [succeeded/failed]: [result] |
| HH:MM | @name | Resolved: [what fixed it] |
```

### STEP 3 — Diagnostic Commands (Safe, Read-Only)

Suggest these read-only commands to help diagnose. **Never suggest destructive operations during an active incident.**

```bash
# Check service health
curl -s http://localhost:PORT/health | jq .

# Recent error logs (last 15 minutes)
journalctl -u SERVICE_NAME --since "15 min ago" --no-pager | tail -50

# Database connection count
psql -c "SELECT count(*) FROM pg_stat_activity WHERE state = 'active';"

# Container/pod status
kubectl get pods -n NAMESPACE --sort-by=.metadata.creationTimestamp | tail -20
kubectl describe pod POD_NAME -n NAMESPACE | grep -A5 "State:"

# Recent deployments (check if a deploy caused this)
git log --oneline --since="2 hours ago" origin/main

# Memory/CPU on the host
top -l 1 | head -10   # macOS
free -h && uptime      # Linux

# Docker container diagnostics
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | head -20
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" | head -20
docker logs --since 10m CONTAINER_NAME 2>&1 | grep -i "error\|fatal\|oom" | tail -20

# Kubernetes detailed diagnostics
kubectl top pods -n NAMESPACE --sort-by=memory | head -10
kubectl get events -n NAMESPACE --sort-by=.lastTimestamp | tail -20
kubectl logs -n NAMESPACE -l app=SERVICE --since=10m --tail=50 | grep -i error

# Network connectivity to dependency
curl -w "dns: %{time_namelookup}s, connect: %{time_connect}s, total: %{time_total}s\n" \
  -o /dev/null -s https://DEPENDENCY_HOST/health

# Queue depth (if using message queues)
# Redis: redis-cli llen QUEUE_NAME
# RabbitMQ: rabbitmqctl list_queues name messages
```

### STEP 4 — Diagnostic Decision Tree

Use this to narrow the failure mode in the first 5 minutes. Start at the top:

```
Is the service responding at all?
├── NO → Is the container/pod running?
│   ├── NO → Check: OOMKilled? CrashLoopBackOff? Image pull failure?
│   │   ├── OOMKilled → Recent memory-heavy change?
│   │   │   Check: kubectl describe pod POD | grep -A3 "Last State"
│   │   ├── CrashLoopBackOff → Check previous logs:
│   │   │   kubectl logs POD --previous | tail -50
│   │   └── ImagePullBackOff → Registry auth? Image tag exists?
│   └── YES → Port/network issue
│       ├── Connection refused → Process crashed after startup. Check logs.
│       └── Connection timeout → Network policy, security group, or DNS
│
├── YES but SLOW (>5× normal latency) →
│   ├── CPU > 90%? → Hot loop, runaway query, or GC storm
│   ├── Memory > 90%? → Memory leak, unbounded cache, connection pool leak
│   ├── DB connections maxed? → Long-running queries, pool exhaustion
│   │   Check: SELECT count(*), state FROM pg_stat_activity GROUP BY state;
│   └── External dependency slow? → Circuit breaker open?
│       Check: curl -w "dns:%{time_namelookup}s ttfb:%{time_starttransfer}s\n" -o /dev/null -s DEPENDENCY
│
└── YES but ERRORS →
    ├── 5xx errors → Check application logs for stack traces
    │   ├── NullPointer/TypeError → Recent deploy? git log --since="2h" origin/main
    │   ├── Connection refused to DB → pg_isready -h HOST
    │   └── Timeout → Downstream dependency slow (see above)
    ├── 4xx spike → API contract change? Rate limiting?
    └── Intermittent → One pod unhealthy? kubectl get pods (all Ready?)
```

**Deploy-correlation shortcut:** if the incident started within 30 minutes of a deploy, **rollback first, investigate second:**
```bash
# Check for recent deploys
git log --oneline --since="1 hour ago" origin/main | head -5
kubectl rollout history deployment/SERVICE -n NAMESPACE | tail -5

# Fast rollback (if confirmed with incident commander):
# ⚠️ DESTRUCTIVE — confirm with user before running
# kubectl rollout undo deployment/SERVICE -n NAMESPACE
```

### STEP 5 — Communication Template

```markdown
## Incident Update — [Title]

**Severity:** SEV-[X] | **Status:** [Investigating/Mitigating/Resolved]
**Duration:** [X minutes/hours]
**Customer Impact:** [what users are experiencing]

**What happened:** [1-2 sentences]
**Current status:** [what we're doing right now]
**Next update:** [time]

**For questions:** contact [incident commander] in [channel]
```

### STEP 6 — Mitigation Tracking

| Mitigation attempted | Time | Result | Rollback needed? |
|---------------------|------|--------|-----------------|
| | | | |

> **After outputting the above template**, ask the user these follow-up questions to fill in gaps:
> 1. What SEV level are you treating this as?
> 2. When did you first detect the problem? (alerts, user reports, monitoring)
> 3. Was there a recent deploy in the last 2 hours?
> 4. What services/components appear affected?
> 5. How many users are impacted?

---

## MODE: POSTMORTEM

### STEP 1 — Gather Facts

Ask for or read:
1. The incident timeline (from RESPOND mode or incident management tool)
2. Monitoring data (alerts, dashboards, metrics during the incident)
3. Deploy logs around the time of the incident
4. Customer reports or support tickets
5. Any chat logs from the incident channel

### STEP 2 — Produce the Postmortem Document

```markdown
# Postmortem: [Incident Title]

**Date:** YYYY-MM-DD
**Severity:** SEV-[X]
**Duration:** [start] to [end] ([total time])
**Authors:** [names]
**Status:** Draft | Reviewed | Complete

---

## Executive Summary

Three sentences maximum. What happened, what was the impact, what is the single
most important thing we're doing to prevent recurrence.

## Impact

- **Users affected:** [number or percentage]
- **Revenue impact:** [estimated, if calculable]
- **SLO impact:** [which SLO was breached, by how much]
- **Data impact:** [any data loss or corruption — state explicitly if none]

## Timeline

[Paste the incident timeline from RESPOND mode]

## Contributing Factor Analysis

**Do NOT write "Root Cause." Write "Contributing Factors."**

Most incidents have multiple contributing factors, not a single root cause.
Naming one root cause prematurely stops the analysis.

### Five Whys Analysis

Start from the observable symptom and ask "Why?" five times:

1. **Why did [symptom]?** → Because [factor A]
2. **Why did [factor A]?** → Because [factor B]
3. **Why did [factor B]?** → Because [factor C]
4. **Why did [factor C]?** → Because [factor D]
5. **Why did [factor D]?** → Because [systemic gap]

### Contributing Factors (categorized)

| Factor | Category | Was this a latent condition or a trigger? |
|--------|---------|----------------------------------------|
| | Code/Config | |
| | Process/Procedure | |
| | Monitoring/Alerting | |
| | Testing gap | |
| | Organizational | |

**Latent condition:** existed before the incident, waiting to be triggered
**Trigger:** the specific event that turned a latent condition into an incident

Understanding this distinction matters because fixing only the trigger
leaves the latent conditions in place for the next trigger to find.

## Detection

- **How was the incident detected?** [Alert / Customer report / Internal discovery]
- **Time to detect (TTD):** [time from start to first alert or report]
- **Was the alerting adequate?** [Yes / No — if no, what alert should exist?]

## Response

- **Time to acknowledge:** [time from alert to first human response]
- **Time to mitigate:** [time from acknowledgment to customer impact resolved]
- **Was the runbook adequate?** [Yes / No / No runbook existed]
- **What slowed the response?** [specific blockers]

## What Went Well

[At least two items. Blameless postmortems acknowledge what worked.]

## What Could Be Improved

[Specific, actionable items — not "be more careful"]

## Action Items

| # | Action | Owner | Priority | Due date | Status |
|---|--------|-------|----------|----------|--------|
| 1 | | @name | P0/P1/P2 | YYYY-MM-DD | Open |
| 2 | | @name | P0/P1/P2 | YYYY-MM-DD | Open |

**Action item quality check:**
- Every action item must have an owner and a due date
- "Be more careful" is not an action item
- "Add monitoring for X" is an action item
- "Improve testing" is not specific enough — "Add integration test for [scenario]" is

## Recurrence Prevention

For each contributing factor, what prevents it from contributing to a future incident?

| Contributing factor | Prevention mechanism | Type |
|-------------------|--------------------|------|
| | Code fix / Alert / Test / Process / Architecture | Detect / Prevent / Mitigate |
```

### STEP 3 — Self-Review

- [ ] Is the language blameless? (no "engineer X should have..." — only "the system allowed...")
- [ ] Are contributing factors categorized, not reduced to a single root cause?
- [ ] Does every action item have an owner and a due date?
- [ ] Are latent conditions distinguished from triggers?
- [ ] Is the executive summary ≤3 sentences?
- [ ] Does the "What Went Well" section have at least two items?

---

## OUTPUT

**RESPOND:** Incident timeline template, severity classification, diagnostic commands, communication template, mitigation tracker.

**POSTMORTEM:** Complete postmortem document ready for the review meeting, with Five Whys analysis, contributing factors, and action items with owners.

**Save:** use the Write tool to save the postmortem to `docs/postmortems/YYYY-MM-DD-[incident-title].md`. For RESPOND mode, save the live timeline to `incidents/[date]-[title]-timeline.md` so the team can collaboratively update it.

**What to run next (after POSTMORTEM):**
- `/principal:adr` — record any architectural decisions made during the incident (rollback strategy chosen, circuit breaker added, etc.)
- `/principal:threat-model` — if the incident revealed a security gap
- `/principal:scale-review` — if the incident was caused by capacity or cascading failure
