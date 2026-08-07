# Forkensics V1 Database Baseline

**Status: FROZEN — approved 2026-08-07**
**Any subsequent database change must begin with V2.**

---

## Approval Chain

| Reviewer | Verdict | Date |
|---|---|---|
| Claude (author) | Submitted | 2026-08-07 |
| GPT/Codex (independent review) | APPROVED: Freeze Forkensics V1 Database Baseline | 2026-08-07 |
| Bill (product owner) | APPROVED: Freeze Forkensics V1 Database Baseline | 2026-08-07 |

---

## Artifacts

| File | SHA-256 |
|---|---|
| `08_Migration/V1__initial_schema.sql` | `2581412af146acdaaf9a7139c98a208fa4b1fe1a355ee14e043f9117b6f3afc3` |
| `08_Migration/tests/V1_acceptance_tests.sql` | `5d1e2e25ccfb232be985c2e08acfeda0966bedf9fee3c8921f58eda7aa8046c3` |
| `08_Migration/tests/test_alias_concurrency.sh` | `16aee2629cc176312a6f9325af1389dbde6c7500ed18fb09f7135c5884b5efca` |
| `08_Migration/tests/V1_FINAL_ALL_TESTS_PASSED.log` | clean run log — all steps exit 0 |
| `supabase/verification/prod_schema_verify.sql` | `a45ef7f788ca87eecdbb29b0d4151e54b9ac34a8e22fcee784b6369f00bdd36f` |

Test count: 242 assertions, all passing (240 in acceptance suite + 2 concurrency tests).

---

## What V1 Covers

### Schema objects
- `auth.users` (Supabase managed) → `public.profiles` (trigger-provisioned)
- `public.groups`, `public.group_members`
- `public.challenges`, `public.challenge_secrets`
- `public.challenge_answer_aliases`
- `public.guess_attempts`, `public.score_events` (view: `current_score_events`)
- `public.correction_events`
- `public.eligible_participants`, `public.exclusion_events`
- `public.media_objects`, `private.media_storage_keys`
- `public.comments`, `public.reactions`
- `public.clues`
- `public.rules_versions` (seed row: Forkensics v1)

### Roles
- `forkensics_executor` — NOLOGIN, BYPASSRLS; owns SECURITY DEFINER mutation functions
- `forkensics_rls_helper` — NOLOGIN, BYPASSRLS; owns SECURITY DEFINER RLS helpers
- `authenticated` — Supabase JWT role; all client traffic

### Key design decisions encoded in V1
- Dual-race scoring: **What?** (dish) and **Where?** (restaurant only — city is optional context, never scored)
- Ordinal ranking: points = eligible guessers − correct rank + 1, minimum 1
- City (`public_city_display`): optional poster-supplied context; normalized on INSERT and draft UPDATE (trim, whitespace → NULL); immutable after activation; never scored
- `private.auth_uid()` reads from GUC `request.jwt.claims.sub`; returns NULL when the claim is absent or empty (NULLIF guard)
- Challenge state machine: `draft → active → locked → revealed`; `cancelled` reachable from draft/active/locked; enforced by trigger
- GuessAttempts are immutable append-only
- EligibleParticipants snapshot is immutable; removals via ExclusionEvent
- Original photo never served to guessing players; re-encoded copy served via Edge Function proxy
- Account deletion: two-phase (prepare → complete); storage keys returned one row per physical file via `UNION` deduplication
- `protect_challenge_authority_fields` trigger blocks all direct client writes to authority columns; `forkensics_executor` bypasses
- Alias edits locked after first guess (`guard_alias_edits` trigger, SELECT FOR UPDATE serialization)
- ChallengeSecret RLS: readable only by poster and trusted server functions before reveal

### GPT review rounds
| Round | Verdict | Notable findings |
|---|---|---|
| Round 1 | BLOCKED | 6 schema defects |
| Round 2 | BLOCKED | 13 test and schema issues |
| Round 3 | BLOCKED | Coverage gaps, SQLSTATE specificity |
| Round 4 | BLOCKED | 8 blockers (auth_uid, reveal function, RLS gaps, etc.) |
| Round 5 | BLOCKED | Storage key fix + city redesign required |
| Round 6 | BLOCKED | Draft city normalization on UPDATE; UNION vs UNION ALL |
| Round 7 | **APPROVED** | Freeze granted |

---

## Constraints on Future Changes

- All changes to the database schema must be delivered as `V2__*.sql` migrations.
- V1 artifacts are read-only historical record — never edited.
- Any V2 proposal must follow the same governance cycle: written step proposal → three-party review → Bill's explicit APPROVED.
