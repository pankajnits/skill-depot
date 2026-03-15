---
---
description: Generate a contextual checklist (launch, deploy, review, or migration readiness)
---

Given the checklist type and context in $ARGUMENTS:

1. Determine the checklist type from the request:
   - **Launch readiness** — is this system ready for production traffic?
   - **Deploy checklist** — pre/post deployment verification
   - **Code review** — what to check before approving a PR
   - **Migration readiness** — is the migration plan complete?
   - **On-call handoff** — what the next on-call engineer needs to know

2. If in a codebase, read relevant files to make the checklist specific to this project (not generic).

3. Generate the checklist with three priority tiers:

   **Must Have (blocks proceeding):**
   - [ ] [specific, verifiable item]

   **Should Have (significant risk if skipped):**
   - [ ] [specific, verifiable item]

   **Nice to Have (best practice, not blocking):**
   - [ ] [specific, verifiable item]

4. For each item, include HOW to verify it (a command, a URL to check, or a question to answer — not just "ensure X is done").

5. Keep the checklist under 25 items. If you need more, the scope is too broad — split into multiple checklists.

---
