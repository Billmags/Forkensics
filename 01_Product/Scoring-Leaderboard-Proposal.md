# FORKENSICS — SCORING AND LEADERBOARD PROPOSAL
**Status: Pending Bill–Claude–Codex Approval**

---

## OVERVIEW

Forkensics should maintain an all-time record, but all-time points should not be the primary leaderboard.

If lifetime points are the main ranking, newer players may never realistically catch people who have played for years.

The recommended system combines:

1. Fixed scoring for every mystery
2. A monthly group leaderboard
3. A secondary all-time Hall of Fame
4. Personal lifetime statistics

---

## SCORING

Every mystery contains two independent races:

**CRACK THE DISH**

and

**NAIL THE PLACE**

Recommended points for each race:

| Finish | Points |
|--------|--------|
| 1st correct | 5 points |
| 2nd correct | 4 points |
| 3rd correct | 3 points |
| 4th correct | 2 points |
| 5th and later correct | 1 point |
| Incorrect answer | 0 points |
| No answer | 0 points |

A player can earn a maximum of **10 points per mystery**.

The first correct player wins that race.

A player who wins both the Dish and Place races receives a special:

**CASE SWEEP**

The Case Sweep should produce a satisfying visual and haptic celebration.

---

## WHY FIXED SCORING IS BETTER

The current database formula calculates points using the number of eligible group members:

> eligible player count − rank + 1

That creates inconsistent results.

Example:

- Winning in a 20-person group could award 20 points even if only two people actually played.
- Winning in a five-person group would award only five points.

Fixed 5–4–3–2–1 scoring makes every mystery worth the same amount regardless of:

- Group size
- Number of eligible players
- Number of people who participate
- Number of inactive group members

This is easier to understand and fairer across different challenges.

---

## PRIMARY LEADERBOARD — THIS MONTH

Each group should have its own monthly leaderboard.

The default leaderboard should be: **THIS MONTH**

Benefits:

- Every month provides a fresh opportunity
- New members can become competitive quickly
- Longtime players retain their historical accomplishments
- Players are encouraged to return regularly
- Nobody becomes permanently impossible to catch

Only players who participate during the month should appear.

Recommended display:

```
THIS MONTH

1. Jeano — 47 points
2. Bill — 42 points
3. Tom — 36 points
```

Small secondary text may show the number of cases played:

```
Jeano
47 points
8 cases
```

Do not place accuracy percentages, streaks, win counts, and other statistics on the main leaderboard.

The main leaderboard should remain bold, clean, crisp, and immediately understandable.

---

## MONTHLY CELEBRATION

At the end of each month, Forkensics should recognize the group winner.

Example:

```
AUGUST'S TOP FORKENSIC

Jeano
47 points
```

This should feel celebratory without becoming childish or visually excessive.

A tasteful animation, subtle haptic feedback, and a shareable result could make this a memorable moment.

---

## SECONDARY LEADERBOARD — HALL OF FAME

Forkensics should also preserve an all-time leaderboard for each group.

Name: **HALL OF FAME**

Possible lifetime statistics:

- Lifetime points
- Dish wins
- Place wins
- Case Sweeps
- Mysteries played

The Hall of Fame is a historical record. It should be available but should not be the first leaderboard players see.

This rewards loyal, longtime participation without making newer players feel permanently behind.

---

## PERSONAL PROFILE STATISTICS

Each player may have private or profile-level lifetime statistics across their groups.

Possible statistics:

- Cases played
- Correct dish percentage
- Correct place percentage
- First-place Dish finishes
- First-place Place finishes
- Case Sweeps
- Current winning streak
- Longest winning streak

These statistics belong in the player profile — not on the main group leaderboard.

---

## IMPORTANT RULES

- **Leaderboards are per group, never global.** Different groups solve different mysteries, so their points are not directly comparable.
- A player's results in one group do not affect another group's leaderboard.
- **Posters do not compete in their own challenges.**
- **Posting a mystery does not award leaderboard points.** Awarding points for posting could encourage frequent, low-quality challenges.
- Only correct answers receive points.
- There is no partial credit.
- Players who do not participate receive zero points.
- A missed challenge does not count against a player's accuracy percentage.
- Former players remain anonymized according to the approved account-deletion rules.
- Tied monthly point totals may share the same leaderboard position. Forkensics should not invent an arbitrary tiebreaker merely to prevent a tie.

---

## OPTIONAL TIE PRESENTATION

If two players finish with the same monthly score:

```
1. Bill — 42 points
1. Jeano — 42 points
3. Tom — 36 points
```

The application can celebrate co-leaders.

---

## CLUES

Clue penalties should not be added until the complete clue system is approved.

For V1, the simplest approach is:

- Clues reveal information gradually
- Players still rank according to when they submit the first correct answer
- No complicated multipliers or hidden scoring formulas

If on-demand clues are later judged too advantageous, a simple one-point deduction can be considered in a future rules version.

---

## DESIGN DIRECTION

The leaderboard must not resemble a business dashboard.

**Avoid:**

- Dense statistics
- Multiple charts
- Tiny labels
- Excessive badges
- Large collections of trophies
- Complicated filters
- Too many leaderboard categories

**Use:**

- Large player names
- Clear rank
- Large point totals
- Generous spacing
- Restrained orange accents
- Subtle movement when rankings change
- One simple This Month / Hall of Fame selector

---

## RECOMMENDATION

**Approve:**

- Two independent races: Dish and Place
- Fixed 5–4–3–2–1 scoring for each race
- Maximum of 10 points per mystery
- Case Sweep recognition for winning both races
- Monthly group leaderboard as the default
- All-time Hall of Fame as the secondary leaderboard
- Personal lifetime statistics in the player profile
- Shared positions when monthly totals are tied
- No global leaderboard
- No posting points
- No partial credit

---

## DATABASE IMPACT

This is a genuine rules and database change.

The current scoring formula depends on the eligible participant count. If this proposal is approved, it should be incorporated and fully tested before V1 is frozen.

---

## NORTH-STAR PRINCIPLE

The monthly leaderboard tells players: **"You can win now."**

The Hall of Fame tells them: **"Your history here matters."**
