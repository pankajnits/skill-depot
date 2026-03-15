---
name: rfc
description: |
  Write an RFC (Request for Comments) or conduct a staff-engineer-grade design review.
  Two modes: WRITE — drafts a complete RFC from a problem statement; REVIEW — reads an
  existing RFC/design doc and produces the staff-level questions and feedback a principal
  engineer would raise (organizational impact, trade-off completeness, 18-month horizon,
  Conway's Law, economic framing). Includes a nemawashi checklist — who to consult before
  the formal review meeting so the meeting confirms consensus rather than surfaces objections.
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - Write
  - AskUserQuestion
---

# /principal:rfc — RFC Writing & Design Review

## RFC vs. ADR — Decide Before Starting

These are complementary, not competing. Use both.

| Dimension | RFC (this skill) | ADR (`/principal:adr`) |
|-----------|-----------------|----------------------|
| **Purpose** | Propose and socialize a change | Record a decision that has been (or is being) made |
| **Timing** | Before the decision — builds alignment | After or at decision point — captures rationale |
| **Audience** | All stakeholders who need to agree | Future engineers who will maintain the system |
| **Mutability** | Lives document — evolves through review | Immutable once accepted — never edited |
| **Length** | 2–20 pages | Half a page to 2 pages |
| **Trigger** | "Should we do X?" | "We're doing X — why, and what alternatives were rejected?" |

**Rule of thumb:** Write an RFC to gain alignment. After the RFC is accepted, write an ADR to record the final decision. An accepted RFC + a closed ADR pointing to it = complete institutional knowledge.

**Skip the RFC when:**
- Decision affects only your team (write an ADR directly)
- Decision is reversible in <1 sprint (just do it, document in commit message)
- Decision is purely implementation detail, not architectural (comment in code)

**Skip the ADR when:**
- Decision is fully documented in an accepted RFC (link RFC from code, no duplicate ADR needed)
- Decision will be revisited in <3 months (document in ticket instead)

---

## MODE SELECTION

Ask the user which mode they need if not clear from context:

- **WRITE** — "I need to write an RFC for [X]"
- **REVIEW** — "Review this RFC / design doc" (provide the document or a path)

---

## MODE: WRITE

### GATHER CONTEXT

Before writing, ask or read for:

1. **Problem statement** — what is broken, missing, or suboptimal, and for whom?
2. **Proposed solution** (if the author already has one, or if they want help exploring options)
3. **Audience and approvers** — who needs to sign off, which teams are affected?
4. **Timeline pressure** — is there a deadline forcing this RFC?
5. **Prior art** — has this been tried before (internally or in the industry)?

Read the codebase if in a repo. An RFC written without understanding the existing system will be immediately credibility-damaged in review.

---

### RFC STRUCTURE

Produce a document with all sections below. Every section is mandatory; omit with explicit justification if truly not applicable.

---

```markdown
# RFC-[NUMBER]: [Short descriptive title]

**Status:** Draft | Proposed | Accepted | Rejected | Withdrawn | Superseded
**Author(s):** [names]
**Date:** YYYY-MM-DD
**Reviewers:** [required approvers — people whose sign-off unblocks implementation]
**Informed:** [stakeholders who should know but don't need to approve]
**Related:** [tickets, ADRs, design docs, prior RFCs]

---

## Summary

One paragraph. A reader unfamiliar with the area should understand the intent
after reading this. Include: what is being proposed, who it affects, and what
changes if accepted.

---

## Background

Two paragraphs minimum, up to one page. A random engineer should be able to
follow the links in this section and get complete context. Cover:

- What is the current state of the system?
- What specific gap, pain, or opportunity is driving this RFC?
- What have we already tried or ruled out informally?
- What organizational or technical context does the reviewer need?

---

## Problem Statement

State the problem clearly and separately from the solution. A good problem
statement can be evaluated independently of any proposed solution.

What is the impact of NOT solving this problem? Quantify where possible:
- "Engineers spend 4 hours per week on X"
- "The current system fails under Y load, causing Z customer impact"
- "Teams B, C, and D cannot ship feature E without this"

---

## Proposal

The proposed solution. Structure:

### Overview
One paragraph describing the solution at the conceptual level.

### Detailed Design
- API changes (request/response shapes, new endpoints, removed endpoints)
- Data model changes (schema, migrations, consistency model)
- Service changes (new services, modified interactions, removed dependencies)
- Configuration changes (feature flags, environment variables, infra changes)
- Sequence diagrams for non-obvious flows

### Failure Modes and Mitigations
For each way this proposal could go wrong:
- What fails?
- What is the blast radius?
- What is the recovery path?

### Migration and Rollout
- Is this backward compatible?
- What is the rollout sequence? (Phase 1, Phase 2, etc.)
- What is the rollback plan if phase 1 goes wrong?
- Are there any one-way doors in this proposal?

---

## Definition of Success

How will we know this RFC achieved its goal? Define measurable signals:

- [ ] [Specific metric] improves from [current] to [target] by [date]
- [ ] [Team/user] can do [X] without [current pain] by [date]

---

## Drawbacks and Risks

What are the strongest arguments AGAINST this proposal? This is not a formality
— it is the section that earns trust from skeptical reviewers.

- What does this make harder?
- What technical debt does this create?
- What teams will be negatively impacted?
- What could go wrong that the author hasn't fully solved?

---

## Alternatives Considered

For each rejected alternative:

### Alternative: [Name]
**What it is:** [description]
**Why attractive:** [what made it worth considering]
**Why rejected:** [specific reason tied to the problem constraints — not generic trade-offs]

---

## Prior Art

How has this problem been solved elsewhere?

- Internal: has this been attempted before in this org? What happened?
- External: how have leading engineering organizations approached this?
- Open source: what existing tools or patterns are relevant?

The goal is not to justify the proposal by precedent — it is to demonstrate that
the author has done the research and can explain why prior solutions don't fully
apply here.

---

## Unresolved Questions

What must be answered BEFORE this RFC can be accepted?

| Question | Proposed owner | Due |
|----------|---------------|-----|
| [Question] | @person | YYYY-MM-DD |

---

## Future Possibilities

What does accepting this RFC enable that is out of scope for this RFC but worth
noting for future planning?

---

## Nemawashi Checklist

List every stakeholder who should be consulted 1:1 BEFORE the formal review meeting.
The review meeting should confirm consensus, not surface objections for the first time.

| Stakeholder | Role / Why they matter | Consulted? | Outcome |
|-------------|----------------------|-----------|---------|
| [Name] | Owns affected service X | [ ] | |
| [Name] | Security — new external endpoint | [ ] | |
| [Name] | On-call — new operational complexity | [ ] | |
| [Name] | Data — schema change | [ ] | |
| [Name] | Platform — new infrastructure dependency | [ ] | |

**Do not schedule the formal review meeting until all rows are checked.**
```

---

### WRITE SELF-REVIEW

Before outputting:

- [ ] Problem statement is separate from and evaluable without the solution
- [ ] The "Drawbacks" section contains the strongest objections, not softened ones
- [ ] Each rejected alternative has a specific rejection reason (not "it's complex")
- [ ] Prior art is researched, not padded
- [ ] Unresolved questions have owners and dates
- [ ] Nemawashi table covers every team that will push back in the formal review

---

## MODE: REVIEW

You are acting as a staff engineer reviewing an RFC or design doc. Your job is to add the organizational and temporal dimensions that team-level reviewers miss.

### STEP 1 — Read the Document

Use Read tool on the provided file path, or ask the user to paste it.

### STEP 2 — Assess Completeness

Check each required section:

| Section | Present? | Adequate? | Issue |
|---------|----------|-----------|-------|
| Problem statement | | | |
| Goals / success criteria | | | |
| Alternatives considered | | | |
| Cross-cutting concerns | | | |
| Migration / rollback plan | | | |
| Unresolved questions | | | |

### STEP 3 — Apply Staff-Level Review Lenses

For each lens, identify specific issues in the document:

**Organizational impact (the lens most team-level reviewers miss):**
- Which teams will need to change their code when this interface evolves?
- What's the blast radius if this service goes down — which SLAs break?
- Does this proposal require alignment from teams not in the RFC's circulation list?
- Does this decision create a coupling that violates team boundaries?
- Does this align with the direction adjacent systems are going in the next 18 months?

**Trade-off completeness:**
- Are the alternatives genuine or straw men?
- Is the rejection reason for each alternative tied to this specific context?
- What is the strongest argument against the proposed solution that is not in the doc?
- What would have to be true for Alternative B to have been the right choice?

**Time horizon (18-month test):**
- What will the team wish they had done differently in 18 months?
- Are there one-way doors in this proposal? Are they justified?
- Is this the right time to build this, or will it be obsoleted by [adjacent initiative]?

**Conway's Law:**
- Do the proposed service/API boundaries match team communication patterns?
- Will this design require cross-team coordination for every future change?
- Is the ownership model clear?

**Economic framing:**
- Is the cost of implementation justified by the problem it solves?
- Is the operational cost (on-call burden, infra cost) acknowledged?
- Is tech debt being incurred explicitly or implicitly?

**Observability and operability:**
- Can an on-call engineer debug a production incident in this system at 3am?
- Are the four golden signals covered?
- Is there a runbook?

**Non-functional requirements:**
- Are latency, throughput, and availability targets stated and justified?
- Is the failure mode analysis complete?
- Is the security model stated?

### STEP 4 — Produce Review Output

Structure your review as follows:

```
## RFC Review: [Title]

### Must Resolve Before Acceptance

[Numbered list of blockers — issues that, if unaddressed, mean the RFC should not be accepted]

### Should Address Before Implementation

[Numbered list of significant gaps — not blockers, but things that will cause pain if ignored]

### Questions for the Author

[Staff-level questions that require answers before the formal review meeting]

### What's Well Done

[Specific strengths — at least two. Credible reviewers acknowledge what's good.]

### Nemawashi Gap

[Any stakeholders not in the circulation list who will object in the formal review meeting]
```

---

## OUTPUT

**WRITE mode:** Complete RFC document, ready for Confluence/Notion/GitHub, plus the nemawashi checklist.

**REVIEW mode:** Structured review with must-resolve items, should-address items, staff-level questions, and nemawashi gap analysis.

**Save:** use the Write tool to save this document to `docs/rfcs/[RFC-NNN]-[short-title].md` (or user-specified path).

**What to run next:**
- After RFC is approved: `/principal:adr` — capture the final decision as an immutable record
- If the RFC describes a new system: `/principal:hld` — produce the design document that implements the RFC's proposal
- If the RFC introduces API changes: `/principal:api-design` — spec the contract in detail
