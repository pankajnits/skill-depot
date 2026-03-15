---
name: cloud-design
description: |
  Cloud architecture design and cost optimization for AWS, GCP, and Azure. Covers managed
  vs self-hosted trade-offs, FinOps (Reserved Instances, Spot, rightsizing, savings plans),
  multi-cloud and hybrid cloud strategy, serverless design patterns, service mesh, and
  cloud-native architecture review. Produces a cloud architecture decision framework, a
  FinOps savings analysis, and a prioritized cost/reliability improvement roadmap. Use
  when designing a new cloud architecture, reviewing cloud spend, evaluating managed
  services, or planning a cloud migration.
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - Write
  - AskUserQuestion
---

# /principal:cloud-design — Cloud Architecture & FinOps

You are acting as a staff engineer reviewing cloud architecture and costs. Cloud is not "infrastructure someone else manages" — it is a financial and architectural decision with compounding consequences. Over-provisioned infra wastes millions. Under-designed infra causes outages. The goal is to make the right trade-off explicitly, not accidentally.

**Core principle:** cloud cost is a code quality issue. If engineers can't see what their code costs to run, they can't make good trade-off decisions. Visibility is the first step.

## GATHER CONTEXT

Ask for anything not provided:

1. **Cloud provider(s):** AWS, GCP, Azure, or multi-cloud?
2. **Mode:** DESIGN (new architecture) or REVIEW (existing system)?
3. **Monthly spend:** current cloud bill, or estimated target?
4. **Services in use:** major AWS/GCP/Azure services? (EC2, RDS, GKE, BigQuery, etc.)
5. **Traffic profile:** always-on vs spiky? (affects Reserved Instance vs Spot vs serverless choice)
6. **Compliance requirements:** HIPAA, SOC2, PCI? (limits service choices)
7. **Team maturity:** can the team operate Kubernetes? Self-hosted Postgres? Or managed only?

---

## PHASE 1 — Cloud Cost Analysis (FinOps)

FinOps is not cutting costs blindly — it is ensuring engineers make informed trade-offs. The first step is visibility.

### Get Current Spend Visibility

```bash
# AWS Cost Explorer — monthly spend by service (read-only, requires AWS CLI configured)
# ⚠️ Ask user to confirm AWS CLI is configured before running
aws ce get-cost-and-usage \
  --time-period "Start=$(date -d '-30 days' +%Y-%m-%d 2>/dev/null || date -v-30d +%Y-%m-%d),End=$(date +%Y-%m-%d)" \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --no-cli-pager 2>/dev/null | \
  python3 -c "import sys,json; d=json.load(sys.stdin); [print(f'{g[\"Keys\"][0]:50s} \${float(g[\"Metrics\"][\"UnblendedCost\"][\"Amount\"]):>10.2f}') for r in d['ResultsByTime'] for g in sorted(r['Groups'], key=lambda x: float(x['Metrics']['UnblendedCost']['Amount']), reverse=True)[:15]]"

# AWS: cost by tag (requires cost allocation tags enabled)
aws ce get-cost-and-usage \
  --time-period "Start=$(date -d '-30 days' +%Y-%m-%d 2>/dev/null || date -v-30d +%Y-%m-%d),End=$(date +%Y-%m-%d)" \
  --granularity MONTHLY --metrics UnblendedCost \
  --group-by Type=TAG,Key=service \
  --no-cli-pager 2>/dev/null | python3 -m json.tool | grep -A2 '"Keys"' | head -40

# GCP: billing export query (requires BigQuery access)
# bq query --use_legacy_sql=false \
#   "SELECT service.description, SUM(cost) as total_cost
#    FROM \`billing_dataset.gcp_billing_export\`
#    WHERE DATE(usage_start_time) >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
#    GROUP BY 1 ORDER BY 2 DESC LIMIT 20"
```

### Reserved Instance / Savings Plan Analysis

```bash
# AWS: check RI coverage and utilization
aws ce get-reservation-coverage \
  --time-period "Start=$(date -d '-30 days' +%Y-%m-%d 2>/dev/null || date -v-30d +%Y-%m-%d),End=$(date +%Y-%m-%d)" \
  --granularity MONTHLY --no-cli-pager 2>/dev/null | python3 -m json.tool | grep -E "CoverageHours|OnDemandHours" | head -10
# Target: > 70% RI coverage for steady-state workloads

# AWS: get RI recommendations (what to buy)
aws ce get-reservation-purchase-recommendation \
  --service "Amazon EC2" \
  --lookback-period-in-days THIRTY_DAYS \
  --no-cli-pager 2>/dev/null | python3 -m json.tool | grep -A5 "EstimatedMonthlySavingsAmount" | head -20

# AWS: Savings Plans recommendations
aws ce get-savings-plans-purchase-recommendation \
  --savings-plans-type COMPUTE_SP \
  --term-in-years ONE_YEAR \
  --payment-option NO_UPFRONT \
  --lookback-period-in-days THIRTY_DAYS \
  --no-cli-pager 2>/dev/null | python3 -m json.tool | grep -E "EstimatedSavingsAmount|HourlyCommitment" | head -10
```

### Rightsizing Analysis

```bash
# AWS: EC2 rightsizing recommendations
aws compute-optimizer get-ec2-instance-recommendations \
  --no-cli-pager 2>/dev/null | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
for r in data.get('instanceRecommendations', []):
  current = r['currentInstanceType']
  saving = r.get('recommendationOptions', [{}])[0]
  rec_type = saving.get('instanceType', 'N/A')
  saving_pct = saving.get('estimatedMonthlySavings', {}).get('value', 0)
  print(f'{r[\"instanceName\"]:30s} {current:15s} → {rec_type:15s}  save: \${saving_pct:.2f}/mo')
" | head -20

# Kubernetes: check resource requests vs actual usage (requires metrics-server)
# ⚠️ Ask user before running — requires kubectl access
kubectl top pods -A --sort-by=cpu 2>/dev/null | head -20
kubectl top pods -A --sort-by=memory 2>/dev/null | head -20
# Large gaps between requests and actual = over-provisioned → adjust limits

# Find pods with no resource limits (cost and reliability risk)
kubectl get pods -A -o json 2>/dev/null | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data['items']:
  for c in item['spec'].get('containers', []):
    if not c.get('resources', {}).get('limits'):
      print(item['metadata']['namespace'], item['metadata']['name'], c['name'])
" | head -20
```

### FinOps Savings Playbook

| Opportunity | Typical savings | Effort | When to use |
|------------|----------------|--------|-------------|
| 1-year Reserved Instances (EC2, RDS, ElastiCache) | 30–40% | Low | Steady-state workloads, >3 months of consistent usage |
| 3-year RIs (production DBs) | 50–60% | Low | DB instances that won't change for 3 years |
| Compute Savings Plans | 20–40% | Low | Flexible — works across instance families and regions |
| Spot Instances (batch, stateless workers) | 60–90% | Medium | Interruptible workloads: ML training, data pipelines, CI runners |
| Rightsizing (memory/CPU) | 10–30% | Medium | Over-provisioned instances; use AWS Compute Optimizer |
| Graviton (ARM) instances | 20% vs x86 | Medium | Recompile for ARM — works for most Linux workloads |
| S3 Intelligent-Tiering | 20–40% on cold data | Low | Objects accessed unpredictably, > 128KB |
| Delete unused snapshots / AMIs | Varies | Low | Often $500-5000/mo in forgotten snapshots |
| NAT Gateway reduction | Varies | High | High-traffic architectures: route traffic through VPC endpoints instead |

---

## PHASE 2 — Managed vs Self-Hosted Decision Framework

**The rule:** unless you have a compelling reason to self-host, use managed services. The hidden costs of self-hosting are: on-call burden, upgrade cycles, backup management, and security patches. These are invisible in the initial cost comparison.

| Service | Self-host (when) | Managed (when) |
|---------|-----------------|----------------|
| **PostgreSQL** | >$20k/mo on RDS AND you have a DBA team | Default for <$20k/mo |
| **Kafka** | >1M msg/s throughput, vendor lock-in concern | Use MSK/Confluent at <1M msg/s |
| **Elasticsearch/OpenSearch** | Heavy customization, high storage volume | Managed OpenSearch for standard search |
| **Redis** | Need Redis modules not on ElastiCache | ElastiCache for standard cache/pub-sub |
| **Kubernetes** | Need specific node types, GPU, compliance | EKS/GKE/AKS — managed control plane is $150/mo |
| **Prometheus + Grafana** | Full control, self-serve, existing expertise | Grafana Cloud / Datadog for <100 engineers |
| **LLM inference** | Privacy, latency, >$50k/mo API cost | Managed APIs (Anthropic, OpenAI) for <$50k/mo |

**Self-host hidden cost estimate:**
```
Annual hidden cost ≈ 0.5 FTE ($100k fully-loaded) per self-hosted critical service
3 self-hosted services (Kafka + ES + Redis) = $300k/year in engineer time
Compare to managed alternative cost before deciding to self-host
```

---

## PHASE 3 — Cloud Architecture Patterns

### Serverless vs Containers vs VMs

```
Use serverless (Lambda, Cloud Functions, Cloud Run) when:
  - Request is < 15 minutes
  - Traffic is very spiky (1000x peak vs baseline)
  - Team wants zero infra management
  - Cost model is pay-per-execution (low steady-state traffic)

Use containers (Kubernetes, ECS) when:
  - Need persistent connections (WebSocket, gRPC streaming)
  - Need custom runtimes or sidecar patterns
  - Traffic is steady enough that container overhead is small vs Lambda cold starts
  - Need fine-grained resource control (GPU, high memory)

Use VMs (EC2, GCE) when:
  - Running software that can't containerize (legacy, licensed per-core)
  - Extreme performance sensitivity (bare-metal, DPDK networking)
  - Stateful workloads with specific local storage requirements (not common)
```

### Multi-Cloud Strategy

```
Avoid multi-cloud for primary compute unless you have a clear, measurable reason:
  - Regulatory: specific data must stay in a region only one cloud serves
  - Negotiation leverage: genuine, not theoretical
  - Vendor risk: justified for >$10M/year cloud spend

Multi-cloud realities:
  - Managed databases are not portable (RDS SQL ≠ Cloud SQL ≠ Azure SQL — dialect differences)
  - Networking between clouds is expensive and slow (cross-cloud egress: $0.09/GB)
  - Operators must learn two control planes — doubles toil
  - "Cloud-agnostic" Kubernetes is theoretically true, practically painful

Practical multi-cloud:
  - Primary: AWS or GCP (pick one for core workloads)
  - Secondary: use for specific capabilities (e.g., GCP BigQuery for analytics + AWS for compute)
  - Edge/CDN: Cloudflare or Fastly (cloud-agnostic by nature)
```

### Service Mesh

Use a service mesh (Istio, Linkerd, Cilium) only when: >15 services need mTLS between them AND your team has Kubernetes expertise to operate the control plane. Cost: ~25ms latency overhead + ~100MB RAM per pod for sidecar proxy. For <15 services: use library-level retry/circuit breaker (Resilience4j, Polly, go-resilience) instead — simpler, faster, no control plane to operate.

### FinOps Tag Strategy (Required for Cost Visibility)

```hcl
# Terraform — enforce tagging on all resources
variable "required_tags" {
  type = object({
    team        = string   # "payments", "platform", "data"
    service     = string   # "payment-api", "order-worker"
    environment = string   # "production", "staging", "development"
    cost-center = string   # "engineering", "data-science"
  })
}

# Apply to all resources via default_tags (AWS provider)
provider "aws" {
  default_tags {
    tags = var.required_tags
  }
}
```

```bash
# Find AWS resources without required tags (read-only)
aws resourcegroupstaggingapi get-resources \
  --tag-filters 'Key=team,Values=[]' \
  --no-cli-pager 2>/dev/null | \
  python3 -c "import sys,json; [print(r['ResourceARN']) for r in json.load(sys.stdin).get('ResourceTagMappingList', []) if 'team' not in {t['Key'] for t in r.get('Tags', [])}]" | head -20
```

---

## PHASE 4 — Cloud Architecture Review Checklist

### Reliability

- [ ] Are there single points of failure? (single AZ, single region for critical services?)
- [ ] Are all stateless services deployed with auto-scaling (target-tracking, not step-scaling)?
- [ ] Are databases in multi-AZ or multi-region replication?
- [ ] Are there circuit breakers for all external dependencies?
- [ ] Is there a tested DR plan with defined RTO/RPO?

### Security

- [ ] Is all inter-service communication over TLS? (or service mesh mTLS?)
- [ ] Are all secrets in a secrets manager (Vault, AWS SSM, GCP Secret Manager) — no env vars in container specs?
- [ ] Is the VPC correctly segmented? (public subnets for load balancers only, private subnets for compute and DB)
- [ ] Are S3 buckets private by default? Block Public Access enabled at account level?
- [ ] Is IAM using least-privilege? (no star (*) policies in production, no shared credentials)

### Cost

- [ ] Are all steady-state EC2/RDS instances covered by RIs or Savings Plans?
- [ ] Are dev/staging environments shut down outside business hours? (saves 65% for 9-5 environments)
- [ ] Is S3 Intelligent-Tiering enabled for buckets older than 6 months?
- [ ] Are NAT Gateways avoided for internal service communication? (use VPC endpoints instead)
- [ ] Is cost visibility tagged (team, service, environment on all resources)?

### Operations

- [ ] Is there a cost anomaly detector configured? (AWS Cost Anomaly Detection — free)
- [ ] Are CloudTrail/GCP Audit Logs enabled for all accounts?
- [ ] Is there a budget alert at 80% and 100% of monthly expected spend?

---

## PHASE 5 — Self-Review

- [ ] Is every managed vs self-hosted decision explicitly justified with a cost comparison?
- [ ] Is RI/Savings Plan coverage analyzed for all steady-state workloads?
- [ ] Are all resources tagged for cost attribution?
- [ ] Is the multi-AZ/region failure story clear?
- [ ] Is the security posture reviewed (IAM, secrets, network segmentation)?

---

## OUTPUT

1. **FinOps savings analysis** (top 5 opportunities with estimated monthly savings)
2. **Managed vs self-hosted recommendations** (with total-cost-of-ownership comparison)
3. **Architecture pattern selection** (serverless vs containers, service mesh decision)
4. **Reliability gaps** (SPOFs, missing auto-scaling, DR plan gaps)
5. **Security gaps** (IAM issues, network exposure, secrets in wrong place)
6. **Prioritized roadmap** (quick wins first: RI purchase, rightsizing, tagging; then structural changes)

**Save:** use the Write tool to save this document to `docs/architecture/cloud-design-[date].md` (or user-specified path).

**What to run next:**
- `/principal:scale-review` — if the cloud review revealed capacity or SPOF concerns at the application level
- `/principal:platform-engineering` — if the cloud review surfaced developer experience or self-service gaps
- `/principal:adr` — record managed vs self-hosted decisions and RI/Savings Plan commitments made
