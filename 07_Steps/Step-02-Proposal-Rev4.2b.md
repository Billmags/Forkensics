# Step 2 Proposal — Revision 4.2b Completion

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Amends:** Rev 4.2a only — three targeted corrections
**Governance gate:** Bill must type `APPROVED: Step 2 — Supabase Project & Database Schema` before SQL is generated.

---

## Correction 1 — Draft-Safe `public_city_display` Constraint

Replace the Rev 4.2a constraint (which incorrectly required `public_city_display IS NOT NULL` the moment `city_revealed = true`) with:

```sql
CHECK (
  -- Unposted draft: public_city_display always NULL regardless of city_revealed setting
  (posted_at IS NULL AND public_city_display IS NULL)
  OR
  -- Posted challenge: enforce the correct city-revealed/display relationship
  (
    posted_at IS NOT NULL
    AND (
      (city_revealed = false AND public_city_display IS NULL)
      OR
      (city_revealed = true
       AND public_city_display IS NOT NULL
       AND length(trim(public_city_display)) BETWEEN 1 AND 100)
    )
  )
)
```

This supports:
- Draft with `city_revealed = true` selected but not yet activated (both NULL — valid)
- Draft cancelled before activation (no public city required)
- Activation atomically sets `posted_at` and `public_city_display` together, satisfying the posted branch

**`activate_challenge()` note:** The function updates the challenge row directly via SQL UPDATE (not via `NEW` in a trigger context), setting `posted_at`, `public_city_display`, and `state` in a single statement so the constraint is evaluated against the fully-updated row.

---

## Correction 2 — Alias Matching in Where? Scoring

Rev 4.2a's scoring pseudocode compared guesses only against canonical values. The approved alias system must be preserved. Replace with:

**Where? correctness evaluation (in `reveal_challenge()` and `apply_correction()`):**

```sql
-- Restaurant: canonical or any active restaurant alias
restaurant_correct :=
  normalized_restaurant_guess = canonical_restaurant
  OR EXISTS (
    SELECT 1 FROM challenge_answer_aliases
    WHERE challenge_id = p_challenge_id
      AND field = 'restaurant'
      AND is_active = true
      AND normalized_value = normalized_restaurant_guess
  );

-- City: only evaluated when city is hidden
IF challenge.city_revealed = false THEN
  city_correct :=
    normalized_city_guess = canonical_city
    OR EXISTS (
      SELECT 1 FROM challenge_answer_aliases
      WHERE challenge_id = p_challenge_id
        AND field = 'city'
        AND is_active = true
        AND normalized_value = normalized_city_guess
    );
  where_correct := restaurant_correct AND city_correct;
ELSE
  -- Revealed city: restaurant alone determines Where? correctness
  -- City aliases irrelevant; city_guess is NULL (forced by trigger)
  where_correct := restaurant_correct;
END IF;
```

**This alias logic applies identically during:**
- Initial reveal scoring
- Correction rescoring (alias added or removed)
- The immutable `city_revealed` flag on the challenge row is always the scoring authority

---

## Correction 3 — Trusted City Correction Updates `public_city_display`

`public_city_display` is immutable to clients after activation, but a post-reveal city-answer correction must be able to update it when `city_revealed = true`.

**Addition to `apply_correction()` transaction** (after updating `challenge_secrets.display_city`, before rescoring):

```sql
-- Only when correcting a city answer and city is currently revealed
IF p_action = 'answer_changed' AND p_target_field = 'city'
   AND challenge.city_revealed = true THEN
  UPDATE challenges
  SET public_city_display = p_new_display_value
  WHERE id = p_challenge_id;
  -- This UPDATE runs as forkensics_executor; authenticated direct UPDATE remains blocked
END IF;

-- Alias-only city corrections do NOT update public_city_display
-- (aliases affect matching only; the revealed display city is unchanged)
```

**Rollback:** The UPDATE is inside the same transaction as rescoring. Any failure rolls back the entire correction, including the `public_city_display` change.

**Privilege:** The UPDATE executes as `forkensics_executor` (SECURITY DEFINER). The `authenticated` role has no column UPDATE privilege on `public_city_display` — unchanged from Rev 4.2.

---

## Acceptance Tests — Additions for Rev 4.2b

- [ ] Draft with `city_revealed = true` and `public_city_display = NULL` passes the constraint
- [ ] Draft with `city_revealed = false` and `public_city_display = NULL` passes the constraint
- [ ] `activate_challenge()` atomically sets `posted_at` and `public_city_display` (revealed-city challenge); constraint passes on the committed row
- [ ] Cancelling a draft with `city_revealed = true` before activation succeeds without a public city
- [ ] Restaurant alias match counts as a correct Where? answer (hidden-city challenge)
- [ ] Restaurant alias match counts as a correct Where? answer (revealed-city challenge)
- [ ] City alias match counts as a correct Where? answer (hidden-city challenge)
- [ ] City alias is not evaluated on a revealed-city challenge (city not scored)
- [ ] `apply_correction()` with `action='answer_changed'` and `target_field='city'` on a revealed-city challenge updates `public_city_display` within the same transaction
- [ ] `apply_correction()` with `action='alias_added'` or `action='alias_removed'` on city does NOT update `public_city_display`
- [ ] Correction transaction failure rolls back `public_city_display` change along with all other steps
- [ ] `authenticated` client cannot directly UPDATE `challenges.public_city_display` after activation

---

## Review Checklist (for Codex/GPT — Rev 4.2b)

1. Is the draft-aware CHECK constraint correct for all challenge lifecycle states (draft, cancelled-before-activation, active, locked, revealed, cancelled-after-activation)?
2. Is the alias-inclusive Where? scoring logic correct for both revealed and hidden city paths?
3. Is the trusted `public_city_display` update inside `apply_correction()` correct, atomic, and correctly scoped to city-answer corrections only (not alias corrections)?
4. Is anything still missing before Bill may issue formal Step 2 approval?
