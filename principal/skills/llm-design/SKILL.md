---
name: llm-design
description: |
  Design or review an LLM/AI system with staff-engineer rigor. Covers eval framework
  design (the foundation everything else depends on), prompt versioning strategy, model
  routing and fallback architecture, cost management and token budgeting, observability
  stack for probabilistic systems, RAG design, and multi-agent workflow architecture.
  Produces a design doc section or standalone LLM system design. Use when building any
  feature that calls an LLM API, a RAG pipeline, an agent system, or an AI-powered workflow.
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - Write
  - AskUserQuestion
---

# /principal:llm-design — LLM/AI System Design

You are acting as a staff engineer designing an LLM system. LLM system design differs from conventional system design in one fundamental way: **outputs are probabilistic, not deterministic.** You cannot assert correctness — you must measure it. This changes everything: evals replace unit tests, drift monitoring replaces error counting, and quality degradation replaces crashes as the primary failure mode.

**The most important principle in LLM system design:** build the eval framework before building the system. An LLM feature without evals is not an engineering artifact — it's a prototype.

## GATHER CONTEXT

Ask the user for anything not provided:

1. **What does this system do?** (one sentence — e.g., "summarize support tickets," "answer questions over a document corpus," "generate code from natural language")
2. **What defines success?** (What does a good output look like? What is clearly bad?)
3. **Who are the users?** (Internal tool vs customer-facing; technical vs non-technical; what's their tolerance for errors?)
4. **What is the expected volume?** (requests/day, peak RPS, expected growth)
5. **What is the latency requirement?** (real-time interactive vs async processing)
6. **What is the cost budget?** (monthly dollar budget or cost-per-request ceiling)
7. **Is there retrieval?** (RAG over documents, code, databases?)
8. **Is this a single LLM call or a multi-step agent?**

If in a codebase, read existing LLM integration code before designing:
```bash
grep -rn "openai\|anthropic\|langchain\|litellm\|claude\|gpt" --include="*.ts" --include="*.py" --include="*.java" . | grep -v "node_modules\|\.git" | head -20
```

---

## PHASE 1 — Eval Framework Design (Build This First)

Before designing any other component, define how you will measure system quality.

**The three types of evals — apply all three:**

**Type 1: Code-based evals (automated assertions)**
Use for structured or constrained outputs:
- JSON schema validation (output is well-formed)
- Regex pattern matching (phone number formats, date formats)
- Exact match against known-correct answers (Q&A over fixed dataset)
- Business rule verification (no PII in generated text, no SQL injection in generated SQL)
- Response time assertions (P99 < threshold)

**Type 2: LLM-as-judge evals**
Use for open-ended quality assessment:
- Define a rubric: [Relevance 1-5] [Accuracy 1-5] [Completeness 1-5] [Tone 1-5]
- Use a strong evaluator model (different from the generation model where possible)
- **Watch for bias:** position bias (prefers first answer), verbosity bias (prefers longer), self-enhancement bias (model prefers its own style)
- Mitigate: swap answer order across runs; use multiple judges; calibrate against human labels

**Type 3: Human-in-the-loop evals**
Use for ground-truth labeling on high-stakes outputs:
- Build a lightweight annotation interface or use existing tooling (Argilla, Label Studio)
- Sample 1–5% of production outputs for weekly human review
- This is your ground truth. Do not skip it for production systems that affect users.

**Eval dataset requirements:**
- Minimum: 50 representative inputs covering normal cases, edge cases, and adversarial inputs
- Include failure cases: inputs the system should refuse, inputs with ambiguous intent
- Version the eval dataset — as the system evolves, the dataset must evolve with it
- Track: accuracy/relevancy/quality score per prompt version, per model version

**Regression gate:**
- Any change to prompts or model version must pass the eval suite before deployment
- Define the acceptable regression threshold (e.g., quality score must not drop >2% from baseline)

---

## PHASE 2 — Prompt Architecture and Versioning

**Treat prompts as code. Version them.**

**Prompt versioning requirements:**
- Store prompts in a dedicated system (Langfuse, PromptLayer, internal CMS) — not hardcoded in application code
- Every prompt has a version identifier (semantic version or hash)
- Every production request logs: prompt_version, model_version, input_token_count, output_token_count, latency_ms, quality_signal
- Prompt changes require: eval run → compare to baseline → merge only if no regression

**Prompt structure:**
```
System prompt:        Role definition, constraints, output format, tone
User message:         The actual request (with dynamic content)
Few-shot examples:    2-5 examples of ideal input/output pairs (if needed)
Context injection:    Retrieved documents, conversation history, tool results
```

**Token budget allocation:**
```
Total context window:     [model max, e.g., 128k tokens]
  System prompt:          [X tokens — measure and minimize]
  Few-shot examples:      [Y tokens — only include if they improve eval scores]
  Dynamic context (RAG):  [Z tokens — set a hard ceiling]
  User input:             [A tokens — set a ceiling to prevent prompt injection at scale]
  Reserved for output:    [B tokens — set max_tokens explicitly, never leave unbounded]
```

**Hard limits:** set max_tokens for every call. An unbounded output is an unbounded cost and an unbounded latency.

**Token budget optimization (cite: TALE-EP research):**
- Measure current token usage per request type
- Remove filler phrases, redundant instructions, unnecessary context
- Run evals after each reduction to confirm quality holds
- Target: 15–25% cost reduction from waste elimination alone

---

## PHASE 3 — Model Routing and Fallback Architecture

**Never depend on a single model. Design a routing layer.**

**Routing tiers:**
```
Tier 1 (quality): Best model for the task (e.g., claude-opus, gpt-4o)
  → Use for: complex reasoning, high-stakes decisions, low-volume tasks

Tier 2 (balanced): Mid-range model (e.g., claude-sonnet, gpt-4o-mini)
  → Use for: most production tasks, moderate complexity

Tier 3 (economy): Fastest/cheapest model (e.g., claude-haiku, gpt-4o-mini)
  → Use for: classification, routing decisions, high-volume simple tasks

Fallback (degraded): Cached response, template-based output, or human routing
  → Use for: when all tiers fail or cost budget is exhausted
```

**Routing decision logic:**
- Route by task complexity (use a cheap classifier to score complexity, then route)
- Route by cost budget (track spend; downgrade tier when approaching monthly cap)
- Route by latency requirement (interactive UX → Tier 3 or 2; async → Tier 1)
- Route by model availability (circuit breaker per model; auto-failover to next tier)

**Cost routing example (show this math):**
```
Naive approach (all traffic to Tier 1):
  Cost = 1M requests × $5/M tokens (avg 500 tokens) = $2,500/month

Routed approach (70% Tier 3, 30% Tier 1):
  Cost = 700k × $0.50 + 300k × $5 = $350 + $1,500 = $1,850/month
  Savings: 26% cost reduction with no quality loss on simple tasks
```

**Circuit breaker per model:**
```
State: CLOSED → OPEN → HALF-OPEN → CLOSED
  CLOSED: normal operation, count failures
  OPEN: after N failures in T seconds, stop calling this model, use fallback
  HALF-OPEN: after recovery_timeout, probe with one request
  CLOSED: if probe succeeds, resume normal operation
```

---

## PHASE 4 — Cost Architecture

**Monthly budget management:**
```
Budget per model per team: set explicitly, not aspirationally
Alert at 70% of monthly budget (not 90% — you need time to act)
Hard cutoff: route to cheaper tier or block non-critical requests at 95%
Runaway protection: per-request cost ceiling (e.g., reject any request
  estimated to cost >$0.10 without explicit override)
```

**Cost observability (per request):**
- `input_tokens × input_price_per_token`
- `output_tokens × output_price_per_token`
- `cost_per_successful_task` (not just cost per token — include retry costs)
- Track cost trend week-over-week; a rising cost with flat quality = waste

**Caching strategy:**
- **Exact match cache:** hash(system_prompt + user_input) → cached response; safe for deterministic inputs
- **Prompt prefix caching:** use provider-level prompt caching (Anthropic, OpenAI) for static system prompts — reduces cost on repeated prefix by 70–90%
- **Semantic similarity cache:** use with caution; threshold-setting is hard; false hits silently return wrong answers
- **Pre-computed responses:** for bounded input spaces (classification tasks, template-based queries)

---

## PHASE 5 — Observability Stack

**Standard instrumentation baseline for any LLM system in production:**

**Per-request trace (must capture):**
```json
{
  "trace_id": "uuid",
  "request_id": "uuid",
  "timestamp": "ISO8601",
  "model_id": "claude-sonnet-4-5",
  "prompt_version": "v2.3.1",
  "input_tokens": 1240,
  "output_tokens": 380,
  "latency_ms": 1850,
  "cost_usd": 0.0042,
  "finish_reason": "stop | max_tokens | error",
  "tier_used": "tier2",
  "fallback_triggered": false,
  "quality_signal": null
}
```

**Metrics to alert on:**
- P99 latency spike (>2× baseline)
- Error rate >1% (model errors, not user errors)
- Cost per task rising >20% week-over-week
- Fallback trigger rate >10% (signals primary model instability)
- `finish_reason: max_tokens` rate >5% (means outputs are being truncated — a quality problem)

**Quality signals (collect these from users):**
- Thumbs up/down on generated outputs
- Acceptance rate for suggestions (code completions, draft emails)
- Edit distance from suggestion to accepted output (lower = better)
- Task completion rate (did the user accomplish what they tried to do?)

**Tooling recommendation:**
- Open-source: Langfuse (tracing + evals + prompt management + cost tracking — recommended default)
- Managed: LangSmith (LangChain ecosystem), Datadog LLM Observability
- Evaluation: Braintrust (evaluation-first, strong A/B testing)

**Multi-agent observability gap:**
Standard distributed tracing doesn't capture multi-step agent workflows. Require:
- Correlation ID that spans tool calls, sub-agent invocations, and RAG retrievals
- Each hop traced individually: latency, token cost, quality signal
- Full agent trace reconstructable from logs (input at each step, tool called, output, decision to continue/stop)

---

## PHASE 6 — RAG Design (if applicable)

**RAG system design questions — answer before choosing any component:**

1. What is the document corpus? (size, update frequency, access control requirements)
2. What is the query type? (factual lookup, summarization, reasoning over multiple documents?)
3. What latency is acceptable for retrieval? (synchronous user-facing vs async batch)
4. What is the accuracy floor? (how bad is a wrong retrieval?)

**Retrieval strategy:**
- **Hybrid retrieval** (recommended default): combine BM25 (keyword, good for exact terms) with semantic embeddings (good for conceptual queries); rerank results with a cross-encoder model
- **Pure semantic:** simpler, worse recall for keyword-heavy queries
- **Pure BM25:** fast, fails on paraphrase and conceptual queries

**Chunking design:**
```
Too small (< 100 tokens): loses context, fragments reasoning
Too large (> 1000 tokens): dilutes relevance, pushes toward irrelevant content
Recommended: 256–512 tokens with 20% overlap between chunks
Semantic chunking: split at paragraph/section boundaries, not fixed token counts
```

**Retrieval quality is the ceiling:**
- Measure retrieval precision and recall independently from generation quality
- A perfect LLM cannot compensate for poor retrieval
- Build retrieval evals first: given query Q, does the retrieval system return the documents a human annotator would select?

**Index selection:**
- HNSW (pgvector, Weaviate, Qdrant): best recall/performance tradeoff for most use cases
- IVF-Flat (FAISS): good for very large static corpora
- Approximate nearest neighbor is sufficient for most RAG; exact search is unnecessary and expensive

---

## PHASE 7 — Multi-Agent System Design (if applicable)

For systems with multiple LLM agents or tool-calling loops:

**Agent coordination patterns:**
- **Sequential:** Agent A → Agent B → Agent C (simple, predictable, no parallelism)
- **Parallel:** Agents A, B, C in parallel → aggregator (faster, more complex error handling)
- **Hierarchical:** Orchestrator agent delegates to specialist agents (flexible, harder to debug)
- **Reactive:** Agent responds to events, may spawn sub-agents (powerful, highest observability burden)

**Reliability requirements for agents:**
- Every agent invocation has a timeout
- Maximum depth/iteration limit (prevent infinite loops)
- Cost ceiling per agent run
- Human-in-the-loop escalation path for high-stakes decisions

**Prompt injection defense:**
- Agents that process user-provided or external content (web pages, documents, emails) must treat that content as untrusted data — not as instructions
- Validate and sanitize tool outputs before passing back to the LLM
- Never allow an agent to call destructive tools (delete, send, publish) without a human approval step

---

## PHASE 8 — Self-Review Checklist

Before presenting the design:

- [ ] Is the eval framework designed before any other component?
- [ ] Are all three eval types (code-based, LLM-as-judge, human) addressed?
- [ ] Is there a regression gate on prompt and model changes?
- [ ] Are prompts versioned and stored outside application code?
- [ ] Is there a fallback for every model call?
- [ ] Is there a circuit breaker per model/provider?
- [ ] Is there a monthly cost budget with alerts at 70%?
- [ ] Is per-request cost instrumented?
- [ ] Are all four LLM-specific metrics (latency, errors, cost, quality) covered?
- [ ] If RAG: is retrieval quality measured independently from generation quality?
- [ ] If multi-agent: are there depth limits, cost ceilings, and prompt injection defenses?

---

## OUTPUT

1. **System overview** (components, data flow, model routing diagram)
2. **Eval framework spec** (types, dataset requirements, regression gate definition)
3. **Prompt architecture** (structure, versioning strategy, token budget)
4. **Model routing and fallback design** (tier definitions, routing logic, circuit breaker config)
5. **Cost projection** (monthly estimate at current volume, at 10× volume, optimization opportunities)
6. **Observability spec** (per-request instrumentation schema, alert thresholds, tooling recommendation)
7. **RAG design** (if applicable: retrieval strategy, chunking config, index choice, eval plan)
8. **Open questions** (anything that must be resolved before implementation)

**Save:** use the Write tool to save this document to `docs/designs/[product-name]-llm-design.md` (or user-specified path).

**What to run next:**
- `/principal:api-design` — design the API contract for LLM-powered endpoints (prompt versioning, streaming, error taxonomy)
- `/principal:scale-review` — LLM systems have unusual scaling characteristics (token throughput, provider rate limits, cost superlinearity)
- `/principal:adr` — capture model selection decision, prompt architecture choice, eval framework design
