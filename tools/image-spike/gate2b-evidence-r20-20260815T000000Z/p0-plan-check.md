# P-0 — Plan Eligibility Check
**Date:** 2026-08-15
**Authorized by:** Gate 2B Rev 20 Phase 1 three-party sign-off (Claude ✅ Codex ✅ Bill ✅)
**Method:** Read-only Supabase MCP `get_project` + `get_organization` calls. No upgrade or configuration change made.

## Project
| Field | Value |
|-------|-------|
| Project ref | `hkfrbdpedrxmbsawnbpr` |
| Project name | forkensics-dev |
| Organization ID | `fdqiaekhhjlzioaltslc` |
| Region | us-east-1 |
| Status | ACTIVE_HEALTHY |

## Organization Plan
| Field | Value |
|-------|-------|
| Organization name | forkensics |
| **Plan** | **free** |
| opt_in_tags | (none) |

## MCP Response (verbatim)
```json
{"id":"fdqiaekhhjlzioaltslc","name":"forkensics","plan":"free","opt_in_tags":[],"allowed_release_channels":["ga","preview"]}
```

## Verdict
**P-0 BLOCKED**

Storage Image Transformations are documented by Supabase as available on Pro and above.
The forkensics organization is on the Free plan. An upgrade is required before any
transformation spike artifacts can be drafted or deployed.

No artifact drafting is authorized. Stop per Rev 20 §3.1:
> "full stop if upgrade required pending separate three-party approval"

## Next step
Obtain separate three-party approval to upgrade forkensics-dev to Supabase Pro
(or determine an alternative path per the Rev 20 §12 Fallback Ranking).
