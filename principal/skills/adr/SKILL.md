---
name: adr
description: |
  Write an Architecture Decision Record (ADR) in MADR 4.0 format. Captures a significant
  architectural decision with full context, options considered with pros/cons, a justified
  decision outcome, and — critically — confirmation criteria so the decision becomes a
  testable hypothesis rather than a historical artifact. Use whenever a significant technical
  choice is made whose context will be unclear in 6 months. Produces a file ready for
  committing to the repo's /docs/adr/ directory.
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - Write
  - AskUserQuestion
---

# /principal:adr — Architecture Decision Record

You are a staff engineer capturing an architectural decision so future engineers can understand not just what was decided, but why — and specifically what would have to be true for a different decision to have been correct.

## WHEN TO WRITE AN ADR vs. A DESIGN DOC

Decide first:

| Signal | Write an ADR | Write a Design Doc (use /principal:hld) |
|--------|-------------|-----------------------------------|
| Scope | Single decision | Whole system or feature |
| Audience | Future engineers asking "why was it done this way?" | Current stakeholders deciding "should we do this?" |
| Trigger | A significant choice has been or is being made | Before coding a significant system |
| Length | Half a page to two pages | 1–20 pages |
| Lifecycle | Immutable record (never edited after acceptance) | Living document |

If the decision affects more than one team or will require organizational alignment, write a design doc first (use `/principal:hld`), then write an ADR to record the final decision.

---

## GATHER CONTEXT

Ask the user for anything not provided:

1. **What is the decision?** (one sentence)
2. **What forced this decision now?** (what changed, what problem triggered it)
3. **What options were on the table?** (at least two — if only one was considered, this isn't really an ADR)
4. **What was chosen, and why?** (the key reasoning)
5. **What are the consequences?** (positive and negative)
6. **Who made or should sign off on this decision?**

If in a codebase, read relevant files to understand context before writing.

---

## PHASE 1 — Find Existing ADRs

```bash
find . -name "*.md" -path "*/adr/*" | sort | tail -5
find . -name "*.md" -path "*/decisions/*" | sort | tail -5
```

- Check the numbering sequence (ADRs are numbered sequentially: 0001, 0002, ...)
- Check the existing format to maintain consistency
- Check for any superseded ADRs this new one replaces

---

## PHASE 2 — Write the ADR

Use MADR 4.0 format. File name: `NNNN-short-title-with-dashes.md` where NNNN is the next number in sequence.

---

```markdown
---
status: "proposed" | "accepted" | "deprecated" | "superseded by [ADR-NNNN](NNNN-title.md)"
date: YYYY-MM-DD
decision-makers: [list of people who made or approved this decision]
consulted: [people whose input was sought before deciding]
informed: [people notified after the decision]
---

# NNNN. [Short, problem-focused title — not the solution name]

## Context and Problem Statement

Two to four sentences describing the situation that required a decision. Explain:
- What is the problem or opportunity?
- What constraints exist (technical, organizational, timeline)?
- What happens if no decision is made?

**Do not describe the solution here. Describe the problem.**

## Decision Drivers

Bullet list of the forces that shaped the evaluation. These are the quality attributes, constraints, or values that a good solution must satisfy. Be specific.

Examples:
- Must support 50k concurrent connections without horizontal scaling complexity
- Team has no operational experience with distributed consensus protocols
- Decision must be reversible within 2 sprints if evidence contradicts our assumptions
- Cannot introduce a new external dependency without security review

## Considered Options

List each option that was seriously evaluated. Straw men and obvious non-starters do not belong here.

- Option A: [short name]
- Option B: [short name]
- Option C: [short name]

## Decision Outcome

**Chosen option: [Option X]**

Because: [one to three sentences naming the specific decision drivers this option satisfies and why the alternatives fail for this context — not in general, but for this specific situation with these constraints.]

### Positive Consequences

- [What this decision makes better, easier, or cheaper]
- [What risks it eliminates]

### Negative Consequences

- [What becomes harder, more expensive, or riskier as a result]
- [What we're knowingly trading away]
- [What debt we're incurring]

### Confirmation

**How will we know in [6 months / 1 year] that this was the right decision?**

Define the measurable signal that would confirm or refute the decision:

- ✓ Confirmed if: [specific, measurable outcome — e.g., "deploy frequency increases from weekly to daily within 3 months"]
- ✗ Revisit if: [specific signal to trigger reconsideration — e.g., "P99 latency exceeds 500ms under 10k RPS"]

Schedule a one-month review: [date]

---

## Pros and Cons of the Options

### Option A: [Name]

[One paragraph explaining what this option is and how it works. Assume a smart reader who hasn't researched this option.]

**Pros:**
- [Specific advantage in the context of the decision drivers above]

**Cons:**
- [Specific disadvantage or risk]

### Option B: [Name]

[One paragraph description]

**Pros:**
- [...]

**Cons:**
- [...]

### Option C: [Name]

[One paragraph description]

**Pros:**
- [...]

**Cons:**
- [...]

---

## More Information

- [Link to design doc, RFC, or HLD if this ADR follows from one]
- [Link to relevant research, benchmarks, or prior art]
- [Link to ticket or PR where this was discussed]
- Supersedes: [ADR-NNNN] (if applicable)
```

---

## PHASE 3 — Self-Review Checklist

Before finalizing:

- [ ] Is the title problem-focused, not solution-focused? ("Choose a message broker" not "Use Kafka")
- [ ] Does the Context section describe the problem without mentioning the solution?
- [ ] Are there at least two genuine options? (not straw men)
- [ ] Does the Decision Outcome name specific decision drivers, not generic trade-offs?
- [ ] Is the rejection reason for each option tied to THIS context, not general drawbacks?
- [ ] Is the Confirmation section specific and measurable, not "monitor and reassess"?
- [ ] Are negative consequences honestly listed? (an ADR without cons is not honest)
- [ ] Is a one-month review scheduled?

**Quality test for the Decision Outcome section:**

Read it aloud. If it sounds like: *"We chose X because it's reliable and our team knows it"* — rewrite it. That is wishy-washy.

It should sound like: *"We chose X because our access patterns are 90% single-tenant queries, Cassandra's eventual consistency model conflicts with our billing accuracy requirements, and our team lacks the operational expertise to run a distributed consensus protocol without significant toil."*

The difference: specific constraints, specific alternatives rejected, specific quality attribute being optimized.

---

## OUTPUT

1. The complete ADR as a Markdown file, ready to commit to `docs/adr/NNNN-title.md`
2. A one-sentence summary for the ADR index (to add to `docs/adr/README.md`)
3. A list of any follow-up ADRs this decision implies (e.g., choosing Kafka implies future ADRs on partition strategy, consumer group design, retention policy)

**Save:** use the Write tool to save this file to `docs/adr/NNNN-[short-title].md`. Check existing ADR numbering first with `find . -name "*.md" -path "*/adr/*" | sort | tail -3`.

**What to run next:**
- If the decision introduced a new system component: `/principal:lld` — produce the implementation blueprint
- If the decision was made during an incident: link this ADR in the postmortem action items
- Track the one-month review date from the Confirmation section — add it to the team calendar
