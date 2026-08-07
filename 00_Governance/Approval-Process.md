# Approval Process

## Gate 1 — Discovery agreement

The reviewers agree on the user problem, intended audience, and success criteria.

## Gate 2 — Product agreement

The reviewers approve the MVP boundary, core game loop, rules, scoring approach, privacy model, and major screens.

## Gate 3 — Technical agreement

The reviewers approve architecture, conceptual schema, authentication, photo storage, location handling, notifications, AI boundaries, and test strategy.

## Gate 4 — Step authorization

For every implementation step:

1. Codex prepares or reviews a written step proposal.
2. Bill shares it with Claude.
3. Claude returns feasibility notes, objections, and proposed changes.
4. Codex reconciles the feedback and identifies disagreements.
5. Bill resolves remaining product choices.
6. Bill states `APPROVED: Step <number and name>`.
7. Claude may then implement only that approved scope.

## Gate 5 — Completion review

Claude provides implementation evidence. Codex reviews it against the approved criteria. Bill accepts the result or sends it back for correction.

Silence, an informal conversation, or partial agreement is not approval.

