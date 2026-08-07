# Step 2 Proposal — Revision 4.2a Completion

**Status:** Pending review (Claude → Codex/GPT → Bill approval)
**Amends:** Rev 4.2 only — three targeted completions for city-visibility
**Governance gate:** Bill must type `APPROVED: Step 2 — Supabase Project & Database Schema` before SQL is generated.

The Clues rename and city-visibility product decision are approved. This completion adds the three remaining items needed before full approval: a safe city display field, a relaxed Where? constraint, and expanded tests.

---

## Completion 1 — `public_city_display` on `challenges`

The city text lives in `challenge_secrets`, which non-posters cannot read before reveal. When `city_revealed = true`, the app needs a safe, client-readable field to display the clue.

**New column on `challenges`:**

```sql
public_city_display text
```

**Constraint:**
```sql
CHECK (
  (city_revealed = false AND public_city_display IS NULL)
  OR
  (city_revealed = true  AND public_city_display IS NOT NULL
                          AND length(trim(public_city_display)) BETWEEN 1 AND 100)
)
```

**Behavior:**
- Set exclusively by `activate_challenge()` — never by client
- When `city_revealed = true`: copied from `challenge_secrets.display_city` atomically during activation
- When `city_revealed = false`: always NULL; not returned to client
- Immutable after activation (protected by `protect_challenge_authority_fields` trigger — `public_city_display` added to the blocked-update list)
- Exposes display city only — no canonical city, dish, restaurant, story, or aliases

**`activate_challenge()` addition (step inserted between eligibility snapshot and state transition):**
```sql
IF NEW.city_revealed = true THEN
  SELECT display_city INTO v_display_city
  FROM challenge_secrets WHERE challenge_id = p_challenge_id;
  NEW.public_city_display := v_display_city;
ELSE
  NEW.public_city_display := NULL;
END IF;
```

**Column grant:**
```sql
-- public_city_display is readable via the existing challenges SELECT grant
-- No UPDATE grant to authenticated (immutable after activation)
```

---

## Completion 2 — Relaxed `guess_attempts` Where? Constraint

The existing CHECK requires `city_guess IS NOT NULL` for every Where? attempt. This conflicts with revealed-city gameplay where city is already known and not scored.

**Replace existing Where? branch in the race CHECK:**

```sql
-- OLD (Rev 4):
(race = 'where' AND dish_guess IS NULL
                AND restaurant_guess IS NOT NULL AND length(trim(restaurant_guess)) > 0
                AND city_guess IS NOT NULL AND length(trim(city_guess)) > 0)

-- NEW (Rev 4.2a):
(race = 'where' AND dish_guess IS NULL
                AND restaurant_guess IS NOT NULL AND length(trim(restaurant_guess)) > 0
                AND (city_guess IS NULL OR length(trim(city_guess)) > 0))
-- city_guess may be NULL (revealed city) or nonblank text (hidden city)
-- Empty/whitespace-only city_guess is still rejected
```

**`set_guess_receipt_fields` trigger addition:**

A table CHECK cannot reference `challenges.city_revealed`, so the trigger enforces the city rule:

```sql
-- Fetch city_revealed for this challenge
SELECT city_revealed INTO v_city_revealed
FROM challenges WHERE id = NEW.challenge_id;

IF NEW.race = 'where' THEN
  IF v_city_revealed = false AND (NEW.city_guess IS NULL OR trim(NEW.city_guess) = '') THEN
    RAISE EXCEPTION 'city_guess required when city is not revealed';
  END IF;
  -- When city_revealed = true: ignore any supplied city_guess; set to NULL
  IF v_city_revealed = true THEN
    NEW.city_guess := NULL;
  END IF;
END IF;
```

**Scoring behavior (in `reveal_challenge()` and `apply_correction()`):**

```sql
-- Where? correctness evaluation
IF challenge.city_revealed = true THEN
  -- Restaurant-only matching
  where_correct := (normalized_restaurant_guess = canonical_restaurant);
ELSE
  -- Both must match
  where_correct := (normalized_restaurant_guess = canonical_restaurant
               AND normalized_city_guess = canonical_city);
END IF;
```

The `city_revealed` value used for scoring is always read from the immutable `challenges` row — never from client input.

---

## Completion 3 — Expanded Acceptance Tests

Add to the Rev 4.2 acceptance criteria:

**`public_city_display` field:**
- [ ] `public_city_display` is NULL when `city_revealed = false`
- [ ] `public_city_display` is set correctly when `city_revealed = true` (matches `display_city`)
- [ ] `activate_challenge()` sets `public_city_display` and state transition atomically
- [ ] `authenticated` client cannot UPDATE `public_city_display`
- [ ] `public_city_display` cannot be changed after activation
- [ ] A revealed-city `public_city_display` does not make any other `challenge_secrets` field readable

**City-visibility guessing:**
- [ ] Hidden-city Where? attempt with `city_guess = NULL` is rejected by trigger
- [ ] Hidden-city Where? attempt with whitespace-only `city_guess` is rejected
- [ ] Revealed-city Where? attempt with `city_guess = NULL` is accepted
- [ ] Revealed-city Where? attempt has any supplied `city_guess` overwritten to NULL by trigger
- [ ] Hidden-city scoring requires exact match on both restaurant and city
- [ ] Revealed-city scoring requires exact match on restaurant only; city is not evaluated
- [ ] Corrections and rescoring use the immutable `city_revealed` value from `challenges`; client cannot alter it

**Security:**
- [ ] `SELECT public_city_display FROM challenges` returns NULL for hidden-city challenges
- [ ] Non-poster cannot read `canonical_city` from `challenge_secrets` before reveal regardless of `city_revealed`

---

## Review Checklist (for Codex/GPT — Rev 4.2a)

1. Is `public_city_display` on `challenges` (server-set, immutable, NULL-when-hidden) the correct location for the safe city display field?
2. Is the relaxed Where? CHECK constraint correct? Does allowing `city_guess IS NULL` in the table constraint while enforcing the rule in the trigger provide sufficient safety?
3. Is the trigger's forced `city_guess := NULL` on revealed-city submissions correct and sufficient to prevent city data from being stored or evaluated?
4. Is the scoring branch (`city_revealed` flag read from immutable challenges row) correct for both initial reveal and correction rescoring?
5. Are the acceptance tests complete for city-visibility security and correctness?
6. Is anything else missing before Bill may issue formal Step 2 approval?
