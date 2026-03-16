# Payment Gateway — High Level Design

**Status:** Draft
**Authors:** pankaj.pandey@1mg.com
**Last Updated:** 2026-03-16
**Reviewers:** Platform Eng Lead, Security/Compliance, Product (Payments), Finance Ops, DevOps
**Related:** PCI-DSS Level 1 SAQ, RBI Payment Aggregator Guidelines 2020, PSD2 (if EU expansion), Internal Auth Service ADR

---

## 1. Context and Scope

The organization currently has no in-house payment infrastructure. All payment collection runs through a single third-party PSP integration bolted onto the order service. This approach has reached its limits: the PSP charges 1.8–2.2% MDR with no room to negotiate at enterprise volume, the integration is untestable in isolation, reconciliation is a manual overnight job, and there is no ability to route intelligently across providers for cost or resilience.

At >500k transactions/day, payment infrastructure is a first-class product concern, not a vendor dependency. RBI's Payment Aggregator (PA) guidelines (2020) impose explicit requirements on entities that facilitate payment collection — data localisation, escrow accounts, system audit trails, and mandatory nodal account reconciliation. PCI-DSS Level 1 applies above 6M card transactions/year. Both are non-negotiable compliance frames for this design.

This document covers the design of an in-house Payment Gateway service: the orchestration layer that accepts a payment intent from an Order Service, routes it to one or more PSPs or acquirers, manages state through the payment lifecycle, and provides reconciliation and refund capability. It covers cards (debit/credit, 3DS2, tokenization), UPI (intent + collect), wallets (PhonePe, Google Pay, Paytm), net banking, COD reconciliation, and full/partial refunds.

**Out of scope for this document:** Merchant onboarding (PA licence), EMI/BNPL flows, international card acceptance (FX), fraud ML model training, customer-facing payment UI (handled by BFF/frontend teams).

---

## 2. Goals

- Handle **≥500k transactions/day** (≈6 TPS average, ≈60 TPS P99 peak during sales) with P99 payment initiation latency <300ms at the gateway layer (excluding PSP round-trip).
- Achieve **≥99.95% payment service availability** (≤4.4h downtime/year), with graceful degradation when any single PSP is unavailable.
- **Zero payment data loss**: every transaction state transition must be durably recorded before any external call returns a success response.
- **PCI-DSS Level 1** compliance: no raw PAN data stored or logged anywhere in the gateway; all card data tokenised at the point of entry.
- **RBI PA compliance**: maintain full audit trail per transaction, support nodal account reconciliation T+1, enforce data localisation (all payment data in GCP `asia-south1`).
- **Multi-PSP routing**: reduce blended MDR by ≥15% vs single-PSP baseline through intelligent routing within 12 months of GA.
- **Reconciliation automation**: reduce manual reconciliation effort from ~8 engineer-hours/day to <30 minutes/day via automated settlement matching.
- Support **idempotent payment creation**: duplicate order retries must never result in double charges.

---

## 3. Non-Goals

- **Issuing or acquiring bank licence**: this gateway routes to licensed acquirers/PSPs; we are not becoming an acquirer.
- **EMI / BNPL flows** (phase 2; requires separate lending partner integration and credit risk logic).
- **International payments / FX conversion** (domestic INR flows only at launch; forex deferred to Q3 roadmap).
- **Fraud ML scoring in-house** (phase 1 uses PSP-native fraud signals + Razorpay/Stripe fraud APIs; custom model training is a separate initiative).
- **Customer payment UI / checkout widget** (owned by the frontend/BFF team; gateway exposes APIs only).
- **PA licence application** (legal and compliance track running in parallel; this design assumes we operate under an existing licensed PA partner for phase 1 and transition to direct PA status in phase 2).
- **Real-time ledger / GL system** (finance uses an existing ERP; this gateway emits events for the ERP to consume — not replace it).

---

## 4. Design Overview

### 4.1 System Context Diagram

```
                         ┌─────────────────────────────────────────────────────┐
                         │                  GCP asia-south1                    │
                         │                                                     │
  ┌──────────┐  HTTPS    │  ┌────────────┐    ┌──────────────────────────────┐│
  │  Mobile  │──────────▶│  │  API GW    │───▶│   Payment Orchestrator       ││
  │  Web App │           │  │ (Cloud Run)│    │   (FastAPI / Cloud Run)      ││
  └──────────┘           │  └────────────┘    │                              ││
                         │        │           │  ┌──────────┐  ┌──────────┐  ││
  ┌──────────┐           │        │           │  │  Router  │  │  State   │  ││
  │  Order   │──────────▶│        │           │  │  Engine  │  │  Machine │  ││
  │  Service │  internal │        │           │  └────┬─────┘  └────┬─────┘  ││
  └──────────┘           │        │           │       │             │        ││
                         │        │           └───────┼─────────────┼────────┘│
                         │        │                   │             │         │
                         │  ┌─────▼──────┐    ┌───────▼─────┐ ┌────▼───────┐ │
                         │  │  Token     │    │  Cloud SQL  │ │  Pub/Sub   │ │
                         │  │  Vault     │    │  (Postgres) │ │  (Events)  │ │
                         │  │(Cloud Run) │    │             │ └────┬───────┘ │
                         │  └────────────┘    └─────────────┘      │        │
                         │                                          │        │
                         │  ┌───────────────────────────────────────▼──────┐ │
                         │  │           Reconciliation Service              │ │
                         │  │           (Cloud Run + Cloud Scheduler)       │ │
                         │  └───────────────────────────────────────────────┘ │
                         └─────────────────────────────────────────────────────┘
                                              │ PSP Adapter Layer
                          ┌──────────────────┼──────────────────────┐
                          ▼                  ▼                      ▼
                   ┌────────────┐   ┌──────────────┐      ┌──────────────────┐
                   │  Razorpay  │   │   PayU        │      │  NPCI / UPI      │
                   │  (Cards,   │   │   (NB, UPI)   │      │  (direct intent) │
                   │   Wallets) │   │               │      │                  │
                   └────────────┘   └──────────────┘       └──────────────────┘
```

**Webhook flows** (PSP → Gateway):
```
PSP ──HTTPS POST──▶ Webhook Receiver (Cloud Run, public endpoint)
                          │
                    signature verify
                          │
                    Pub/Sub topic: payment.webhook.inbound
                          │
                    Payment Orchestrator (subscriber) updates state machine
```

---

### 4.2 Key Design Decisions (Summary)

- **Saga pattern (orchestration-based)** governs cross-service payment flows — every step has a compensating transaction; no 2PC anywhere.
- **Outbox pattern** (write to DB + outbox in one local transaction) guarantees at-least-once event delivery to Pub/Sub without distributed locks.
- **Token Vault as a sidecar service** isolates all PAN/card data behind a separate trust boundary — the gateway core never sees raw card numbers.
- **PSP Adapter Layer** is pluggable: each PSP is a stateless adapter behind a common `PaymentProvider` interface, making PSP swap/addition a configuration change, not a code change.
- **State machine is the source of truth**: every payment is a state machine (`INITIATED → PROCESSING → AUTHORIZED → CAPTURED → SETTLED | FAILED | REFUNDED`); no payment status is derived from PSP callback alone.

---

### 4.3 APIs

#### Payment Initiation

```
POST /v1/payments
  Auth:     mTLS (service-to-service) + JWT (user session for web-initiated)
  Request:  {
              order_id,          // idempotency anchor
              amount_paise,      // always in paise (integer, no floats)
              currency: "INR",
              payment_method: {
                type: "card" | "upi" | "netbanking" | "wallet",
                // card: { token_id }   ← vault token, never raw PAN
                // upi:  { vpa } | { intent: true }
                // nb:   { bank_code }
                // wallet: { provider: "phonepe" | "gpay" | "paytm" }
              },
              customer: { id, email, phone },
              idempotency_key,   // UUID v4, client-generated
              metadata: {}
            }
  Response: {
              payment_id,
              status: "INITIATED" | "REDIRECT_REQUIRED",
              redirect_url?,     // for NB / wallet redirects
              upi_intent_url?,   // for UPI intent
              expires_at
            }
  Errors:   400 (invalid method/amount), 409 (duplicate idempotency_key),
            422 (token not found), 503 (all PSPs unavailable)
```

#### Payment Status

```
GET /v1/payments/{payment_id}
  Response: { payment_id, status, amount_paise, psp_reference,
              created_at, updated_at, failure_reason? }
```

#### Refund

```
POST /v1/payments/{payment_id}/refunds
  Request:  { amount_paise, reason, idempotency_key }
  Response: { refund_id, status: "PENDING", payment_id, amount_paise }
```

#### Webhook (inbound from PSPs)

```
POST /v1/webhooks/{psp_name}
  Auth:     HMAC signature verification (PSP-specific)
  Response: 200 OK immediately (async processing via Pub/Sub)
            — always ACK fast; never do DB writes in webhook handler
```

**Versioning strategy:** URI versioning (`/v1/`). Breaking changes increment major version; old versions maintained for 12 months with deprecation headers.

---

### 4.4 Data Model

**Data store:** Cloud SQL (PostgreSQL 15), `asia-south1`, HA with read replica. Separate schema for `payment_core` and `reconciliation`. Token Vault uses a separate Cloud SQL instance with stricter IAM — not shared with gateway core.

**Critical tables:**

```sql
-- Core payment record
CREATE TABLE payments (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id        TEXT NOT NULL,
  idempotency_key TEXT NOT NULL UNIQUE,
  status          payment_status NOT NULL DEFAULT 'INITIATED',
  amount_paise    BIGINT NOT NULL CHECK (amount_paise > 0),
  currency        CHAR(3) NOT NULL DEFAULT 'INR',
  payment_method  JSONB NOT NULL,       -- { type, masked_pan?, vpa?, bank_code? }
  psp_name        TEXT,                 -- assigned after routing
  psp_reference   TEXT,                 -- PSP transaction ID
  failure_reason  TEXT,
  metadata        JSONB,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  captured_at     TIMESTAMPTZ,
  settled_at      TIMESTAMPTZ
);
CREATE INDEX idx_payments_order_id ON payments(order_id);
CREATE INDEX idx_payments_psp_ref  ON payments(psp_name, psp_reference);

-- State machine transitions (append-only audit log)
CREATE TABLE payment_events (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id  UUID NOT NULL REFERENCES payments(id),
  from_status payment_status,
  to_status   payment_status NOT NULL,
  actor       TEXT NOT NULL,     -- 'system', 'psp_webhook', 'user_cancel'
  payload     JSONB,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Outbox for reliable event publishing
CREATE TABLE payment_outbox (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id    UUID NOT NULL,
  event_type    TEXT NOT NULL,
  payload       JSONB NOT NULL,
  published     BOOLEAN NOT NULL DEFAULT FALSE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  published_at  TIMESTAMPTZ
);
CREATE INDEX idx_outbox_unpublished ON payment_outbox(published, created_at)
  WHERE published = FALSE;

-- Refunds
CREATE TABLE refunds (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id      UUID NOT NULL REFERENCES payments(id),
  idempotency_key TEXT NOT NULL UNIQUE,
  amount_paise    BIGINT NOT NULL,
  status          refund_status NOT NULL DEFAULT 'PENDING',
  psp_refund_ref  TEXT,
  reason          TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Token Vault (separate DB instance)
CREATE TABLE card_tokens (
  token_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id     TEXT NOT NULL,
  encrypted_pan   BYTEA NOT NULL,   -- AES-256-GCM, key in Cloud KMS
  pan_hash        TEXT NOT NULL,    -- SHA-256 of PAN for duplicate detection
  masked_pan      CHAR(16) NOT NULL,-- last 4 only
  expiry_month    SMALLINT NOT NULL,
  expiry_year     SMALLINT NOT NULL,
  card_network    TEXT NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_used_at    TIMESTAMPTZ
);
```

**Consistency model:** Strong consistency within a single Cloud SQL instance (ACID). Cross-service consistency (Gateway ↔ Order Service ↔ Inventory) via Saga + compensating transactions — eventual consistency with guaranteed convergence.

**Estimated data volume:**

| Horizon | Transactions/day | payments rows | payment_events rows | Storage |
|---------|-----------------|---------------|---------------------|---------|
| Launch  | 500k            | 15M/month     | 75M/month           | ~50 GB/yr |
| 6 months| 800k            | 24M/month     | 120M/month          | ~80 GB/yr |
| 2 years | 1.5M            | 45M/month     | 225M/month          | ~300 GB/yr |

Partition `payment_events` by `created_at` (monthly) at 6-month mark. Archive to Cloud Storage (Parquet) after 13 months for compliance retention (RBI mandates 5 years).

---

### 4.5 Key Flows

#### Payment Initiation + Capture (Happy Path)

```
Client → POST /v1/payments
  │
  ├─ Idempotency check: SELECT payments WHERE idempotency_key = ?
  │    └─ if found AND status != FAILED → return existing payment (409 if CAPTURED)
  │
  ├─ BEGIN TRANSACTION
  │    ├─ INSERT payments (status=INITIATED)
  │    ├─ INSERT payment_outbox (event=PaymentInitiated)
  │    └─ COMMIT
  │
  ├─ Route: Router.select_psp(amount, method, customer_segment, psp_health)
  │
  ├─ Call PSP Adapter (async, timeout=5s, retry=2x with jitter)
  │    ├─ On success: UPDATE payments SET status=PROCESSING, psp_reference=?
  │    │              INSERT payment_events + outbox entry
  │    └─ On failure: UPDATE payments SET status=FAILED
  │                   INSERT compensating event → notify Order Service
  │
  └─ Return payment_id + status to client

PSP Webhook → POST /v1/webhooks/{psp}
  │
  ├─ Verify HMAC signature
  ├─ Publish to Pub/Sub: payment.webhook.inbound (ACK immediately → 200 OK)
  │
  └─ Subscriber (Payment Orchestrator):
       ├─ Dedup: check payment_events for psp_reference + event_type
       ├─ Validate state transition (PROCESSING → AUTHORIZED → CAPTURED)
       ├─ BEGIN TRANSACTION
       │    ├─ UPDATE payments SET status=CAPTURED
       │    ├─ INSERT payment_events
       │    ├─ INSERT payment_outbox (event=PaymentCaptured)
       │    └─ COMMIT
       └─ Outbox processor publishes PaymentCaptured → Order Service
```

#### Saga: Order → Payment → Fulfillment

```
Choreography-based saga:

Order Service   → emits OrderPlaced
Payment Gateway ← consumes OrderPlaced → initiates payment → emits PaymentCaptured | PaymentFailed
Order Service   ← consumes PaymentCaptured → confirms order → emits OrderConfirmed
Fulfillment     ← consumes OrderConfirmed → dispatches

Compensating transactions:
  PaymentFailed   → Order Service cancels order (compensate)
  FulfillmentFail → Payment Gateway issues refund → Order Service marks cancelled
```

#### PSP Routing Logic

```python
def select_psp(amount_paise, method, customer_segment, health_scores):
    candidates = [p for p in PSP_REGISTRY if method in p.supported_methods]
    candidates = [p for p in candidates if health_scores[p.name] > 0.95]  # circuit breaker

    if not candidates:
        raise AllPSPsUnavailableError()

    # Cost-optimised routing: lowest MDR for amount bracket
    # Override: sticky routing for retry (same PSP as original attempt)
    # Override: A/B bucket for new PSP onboarding
    return min(candidates, key=lambda p: p.mdr_for(amount_paise, customer_segment))
```

---

## 5. Alternatives Considered

### Alternative A: Continue using single PSP (Razorpay) with deeper integration

**What it is:** Expand the existing Razorpay integration — use their Route (split payments), Smart Collect, and reconciliation APIs rather than building in-house.

**Why it was considered:** Significantly lower engineering cost and time-to-market (weeks vs. months). Razorpay's API surface is mature, their webhook reliability is high, and they offer a managed reconciliation dashboard.

**Why it was rejected:** At 500k+ transactions/day, the blended MDR of 1.8–2.2% represents ₹1.8–2.2 crore in daily processing fees at ₹1000 average order value — the cost of an entire payments engineering team annually. More critically, single-PSP dependency means any Razorpay outage (they had a 4h outage in Nov 2023) takes down checkout entirely. RBI PA guidelines also require the PA to maintain escrow control — routing through a single external PA long-term puts us at regulatory risk if Razorpay's PA licence is ever suspended. Finally, reconciliation automation requires structured access to raw settlement files that Razorpay's API does not expose at the fidelity needed.

### Alternative B: Use a Payment Orchestration Platform (e.g., Juspay HyperCheckout, Stripe Radar + Treasury)

**What it is:** A third-party orchestration layer that provides multi-PSP routing, tokenisation, and reconciliation as a managed service, sitting between our Order Service and the PSPs.

**Why it was considered:** Juspay specifically has deep NPCI relationships and a proven UPI intent flow. It would give us multi-PSP routing in weeks, not months, and their tokenisation handles PCI scope reduction without us building a vault.

**Why it was rejected:** Juspay's orchestration pricing (0.05–0.08% per transaction) eliminates most of the MDR savings we'd gain from multi-PSP routing — the economics only work if we own the orchestration. More importantly, moving to a managed orchestration layer means a third party holds the payment state machine; when a discrepancy occurs (and they do, at scale), debugging requires Juspay's support involvement, which adds hours to incident resolution. Our RBI audit obligations require us to demonstrate control over payment data flows — a black-box managed service complicates this materially. Viable for phase 1 if timeline forces it, but the design should be in-house from the start.

### Alternative C: Event-sourced payment state (append-only, no mutable `payments` table)

**What it is:** Model the entire payment lifecycle as an immutable event stream (using Cloud Spanner or Kafka as the log), with payment state derived by replaying events rather than maintained in a mutable row.

**Why it was considered:** Event sourcing gives a perfect audit trail by design, makes temporal queries trivial (what was the state at time T?), and eliminates a class of update-race bugs.

**Why it was rejected:** The team has no production experience with event-sourced systems, and the operational complexity (event schema versioning, projection rebuilds, eventual read model staleness) would add 3–4 months to the delivery timeline. Our auditing requirement is met more simply by the append-only `payment_events` table alongside a mutable `payments` row — we get the audit trail without the full event-sourcing operational burden. This can be revisited at the 2-year mark when transaction volume justifies the investment.

---

## 6. Cross-Cutting Concerns

### 6.1 Security

**Authentication & authorisation:**
- Service-to-service: mTLS with client certificates issued by GCP Certificate Authority Service. Payment Orchestrator and Token Vault communicate only over mTLS.
- User-initiated flows: short-lived JWT (15min expiry) from the Auth Service. Payment initiation endpoints require both a valid JWT and an order ownership check.
- Webhook endpoints: HMAC-SHA256 signature verification per PSP spec. Reject any webhook that fails signature check before touching the DB.

**PAN data handling (PCI-DSS Level 1):**
- No raw PAN ever enters the Payment Orchestrator. Card collection happens via PSP-hosted fields (Razorpay/PayU JS SDK) or our Token Vault endpoint — the orchestrator receives only a `token_id`.
- Token Vault stores encrypted PAN using AES-256-GCM with Cloud KMS-managed keys. Key rotation every 90 days.
- All logs are scrubbed for card numbers (regex scan in the log pipeline); any log entry containing a 13–19 digit sequence is redacted and triggers an alert.
- Network segmentation: Token Vault Cloud Run service is not internet-accessible; only reachable from Payment Orchestrator via VPC Service Controls.

**Attack surface changes:**
- New public endpoints: `POST /v1/payments`, `POST /v1/webhooks/{psp}` — both behind Cloud Armor (WAF) with rate limiting (100 req/min per IP for payment initiation).
- Webhook endpoint: public but authentication is HMAC, not session-based — no session fixation risk; however it is a potential DoS vector. Mitigate with Cloud Armor + Pub/Sub buffering (webhook handler is stateless, just enqueues).
- PAN-in-URL: enforced prohibition — any attempt to pass card data as a query parameter is rejected at the API Gateway with a 400 and alert fired.

### 6.2 Observability

**Four golden signals:**

| Signal | Target | Instrumentation |
|--------|--------|-----------------|
| **Latency** | P50 <80ms, P99 <300ms (gateway layer, ex-PSP) | Cloud Trace spans on every payment_id; histogram in Cloud Monitoring |
| **Traffic** | Baseline 6 TPS, peak 60 TPS; alert if >120 TPS (possible retry storm) | Cloud Run request metrics; Pub/Sub message rates |
| **Errors** | Error budget: 0.05% of transactions (≈250/day at 500k); page at 0.1% | payment_events WHERE to_status='FAILED' / total; alert in Cloud Monitoring |
| **Saturation** | DB connections (Cloud SQL max_connections=500; alert at 80%), Pub/Sub subscription lag >1000 messages | Cloud SQL metrics, Pub/Sub dashboards |

**First on-call runbook trigger — "Payment failure rate elevated":**
1. Check Cloud SQL connection pool exhaustion (most common cause at scale).
2. Check PSP health dashboard (Razorpay/PayU status pages); if PSP degraded, verify circuit breaker tripped and traffic rerouted.
3. Check Pub/Sub `payment.webhook.inbound` lag — if growing, outbox processor is behind; check Cloud Run replica count.
4. Check `payment_events` for a specific failure_reason concentration — if it's `3DS_TIMEOUT`, the issue is issuer-side, not ours.

**Business metrics (beyond golden signals):**
- Payment success rate by method (card/UPI/NB/wallet) — daily SLO report to Finance.
- Reconciliation match rate — alert if <99.5% same-day.
- MDR blended rate — weekly automated report to Finance.

### 6.3 Reliability

**SLO:** 99.95% payment service availability (measured as: successful `POST /v1/payments` responses / total attempts, excluding client errors). Error budget: 4.4h/year.

**Failure modes:**

| Dependency fails | Impact | Mitigation |
|----------------|--------|-----------|
| Primary PSP (e.g. Razorpay) | Payments for that method fail routing | Circuit breaker trips after 5 consecutive failures in 30s; router falls back to secondary PSP. Auto-recovery after 60s probe. |
| Cloud SQL primary | All writes fail | Cloud SQL HA automatic failover to standby (<30s). Outbox processor pauses; resumes after reconnect. |
| Pub/Sub | Events not published | Outbox persisted in DB; processor retries. Payment API is unaffected (writes DB-first). |
| Token Vault | Card payments fail; UPI/NB/wallets unaffected | Return 503 for card method only; other methods proceed normally. |
| All PSPs simultaneously | Full payment outage | 503 response with `Retry-After: 30`. Order Service holds order in `PAYMENT_PENDING` for 15 min before cancelling. |

**Rollback strategy:**
- Cloud Run revisions: traffic splitting allows instant rollback to previous revision (roll forward preferred; rollback if error rate >1% within 5min of deploy).
- DB migrations: all schema changes are additive-only during rollout. Non-additive changes (column removal) deferred until old code version is fully drained (two-phase migration).
- Feature flags: PSP routing weights configurable via Cloud Run env var (no redeploy required to shift 100% traffic away from a PSP).

### 6.3a Distributed Transactions

This system writes across Payment Gateway DB, Order Service, and PSP — all external. We use **choreography-based Saga** for the payment lifecycle and **Outbox pattern** for reliable event publishing.

The critical correctness invariant: **a charge must never be captured without a corresponding CAPTURED record in our DB.** This is achieved by:
1. The outbox entry for `PaymentCaptured` is only written after the DB `status=CAPTURED` update commits.
2. The Order Service only marks an order `CONFIRMED` after consuming `PaymentCaptured` from Pub/Sub.
3. If the Pub/Sub message is lost/delayed, the outbox processor retries indefinitely. The Order Service consumer is idempotent (checks existing order status before acting).

**Double-charge prevention:**
- Idempotency key on `POST /v1/payments` prevents duplicate payment creation from client retries.
- PSP calls include our `payment_id` as the PSP idempotency key — PSP deduplicates on their side.
- Webhook deduplication: `payment_events` unique constraint on `(payment_id, psp_reference, to_status)` prevents double-processing of duplicate webhook deliveries.

**Refund saga:**
```
POST /v1/payments/{id}/refunds
  → INSERT refunds (PENDING) + outbox(RefundInitiated)
  → Call PSP refund API
  → On PSP success: UPDATE refunds SET status=PROCESSING
  → PSP webhook: UPDATE refunds SET status=COMPLETED
  → Outbox: emit RefundCompleted → Order Service / Finance ERP

Compensating: if PSP refund fails after 3 retries → status=FAILED, alert Finance for manual processing
```

### 6.4 Scalability

**Bottleneck at 10x load (5M transactions/day, 600 TPS peak):**

Cloud Run auto-scales horizontally — the Payment Orchestrator itself is stateless and will scale. The first thing to fall over is **Cloud SQL connection pool**: Cloud SQL Postgres max_connections ≈ 500 for a db-n1-standard-8. At 600 TPS with P99 query time of 10ms, we need ~6 concurrent connections per instance — but connection pool exhaustion under retry storms is the #1 incident pattern for payment services. **Mitigation:** PgBouncer sidecar (transaction pooling mode) in front of Cloud SQL, targeting max 50 server connections per gateway replica. At 10x scale, evaluate move to Cloud Spanner for the `payments` table (horizontal scaling, no connection limits).

**UPI intent thundering herd:** Mobile app retries on UPI timeout (common, ~15% of UPI flows timeout at issuer side) can create 3–5x traffic spike in 30s windows. Rate-limit UPI retries per order at the API Gateway (max 3 retries per order_id in 2min).

**Single points of failure:**
- Cloud SQL primary → mitigated by HA standby.
- Token Vault service → mitigated by Cloud Run multi-region deploy (asia-south1 + asia-south2 failover, data replicated via Cloud SQL cross-region read replica promoted on failover).

**Back-of-envelope (peak day, 1.5M transactions):**
- Compute: 500k tx/day = ~6 TPS avg; peak 60 TPS. Cloud Run min 2 instances, max 20. Each instance handles ~10 concurrent requests. Cost: ~₹15k/month.
- DB: 1.5M writes/day = ~17 writes/sec avg to `payments` + `payment_events`. db-n1-standard-4 handles this comfortably; upgrade to db-n1-standard-8 at 5M/day.
- Storage: 300 GB/year (2-year horizon). Cloud SQL SSD: ~₹8k/month at scale.
- Pub/Sub: 1.5M messages/day = negligible cost (~₹200/month).

### 6.5 Cost

| Component | Launch (500k tx/day) | Scale (1.5M tx/day) |
|-----------|---------------------|---------------------|
| Cloud Run (Orchestrator + Vault + Recon) | ₹12k/month | ₹35k/month |
| Cloud SQL HA (2 instances) | ₹18k/month | ₹40k/month |
| Cloud KMS (key operations) | ₹3k/month | ₹8k/month |
| Cloud Armor + Load Balancer | ₹5k/month | ₹10k/month |
| Pub/Sub + Cloud Scheduler | ₹1k/month | ₹3k/month |
| **Total infra** | **~₹40k/month** | **~₹96k/month** |
| **MDR saving (15% reduction on ₹500M/day GMV × 2% blended)** | **—** | **₹1.5 crore/day saving** |

**Cost surprise to watch:** Cloud SQL egress from asia-south1 is ₹8/GB — if the reconciliation job pulls large settlement files daily, this adds up. Keep reconciliation processing co-located in the same region.

### 6.6 Operational Readiness

**Deployment strategy:** Canary via Cloud Run traffic splitting. Every deploy starts at 5% traffic for 10 minutes. Automated rollback if error rate >0.5% or P99 >500ms during canary window.

**Migration plan (from existing PSP integration):**
- Phase 1 (Weeks 1–8): New gateway handles only new orders; existing Razorpay direct integration handles in-flight orders until they close.
- Phase 2 (Weeks 9–12): 100% new orders through gateway; old integration kept live for webhook processing of legacy orders.
- Phase 3 (Month 4): Decommission direct Razorpay integration.
- Zero downtime: no schema migration on Order Service DB; gateway is a new standalone service.

**Runbook location:** `docs/runbooks/payment-gateway/` (to be created before GA).

---

## 7. Open Questions

| Question | Owner | Due | Status |
|----------|-------|-----|--------|
| Which PSPs do we onboard at launch — Razorpay + PayU confirmed? Any others? | Product (Payments) | 2026-04-01 | Open |
| RBI PA licence timeline — are we operating as PA ourselves or under Razorpay's PA licence in phase 1? | Legal/Compliance | 2026-04-01 | Open |
| What is the Order Service's retry/timeout contract when payment initiation returns 503? | Order Service team | 2026-04-15 | Open |
| PCI-DSS Level 1 QSA engagement — which QSA firm, and what is the audit timeline? | Security/Compliance | 2026-04-01 | Open |
| COD reconciliation: what is the source of truth for COD delivery confirmation — OMS or logistics partner webhook? | Finance Ops + Logistics team | 2026-04-15 | Open |
| Token Vault: use PSP tokenisation (Razorpay TokenHQ / RBI CoFT mandate) vs. our own vault? | Platform Eng Lead | 2026-04-01 | Open — **RBI CoFT mandate (Oct 2022) requires card-on-file tokenisation through a TSP; our vault may need to integrate with Razorpay TokenHQ rather than storing encrypted PANs directly** |
| Settlement file format from each PSP — does PayU provide S3/SFTP or API? | Integrations team | 2026-04-15 | Open |

---

## 8. Success Criteria

- [ ] P99 payment initiation latency <300ms at 500k tx/day, measured in Cloud Monitoring for 30 consecutive days post-GA.
- [ ] Payment service availability ≥99.95% in first 90 days post-GA (Cloud Monitoring SLO dashboard).
- [ ] Zero double-charge incidents in first 180 days (Finance Ops reconciliation report).
- [ ] Zero PAN data in application logs (confirmed by quarterly log audit + automated regex scan).
- [ ] Reconciliation automation: <30 min manual effort/day by Month 2 post-GA (Finance Ops self-reported).
- [ ] Blended MDR reduction ≥15% vs single-PSP baseline within 6 months of multi-PSP routing GA (Finance monthly MDR report).
- [ ] All RBI PA audit findings resolved within 30 days of audit completion.

---

## 9. Rollout Plan

| Phase | What ships | Duration | Success gate before proceeding |
|-------|-----------|----------|-------------------------------|
| **Alpha** | Internal orders only (employee accounts), card + UPI, single PSP (Razorpay), feature-flagged | 2 weeks | Error rate <0.1%, zero data integrity issues, reconciliation matches 100% |
| **Beta** | 5% of production traffic, all payment methods, Razorpay only | 2 weeks | P99 <300ms at 5% load, success rate ≥99.5%, no PAN-in-log alerts |
| **Multi-PSP GA** | 100% traffic, Razorpay + PayU, routing engine live | Month 3 | All success criteria met, on-call runbooks tested in GameDay |
| **Recon Automation GA** | Automated settlement matching, MDR reporting | Month 4 | Reconciliation match rate ≥99.5%, Finance sign-off |
| **PA Compliance GA** | RBI audit-ready, QSA report clean | Month 6 | QSA report with no critical findings |

---

*Generated by `/principal:hld` · 2026-03-16*
*Next steps: `/principal:threat-model` (STRIDE on Token Vault + Webhook surface) · `/principal:lld` (DDL, API contracts, PSP adapter interface) · `/principal:api-design` (full payment API spec)*
