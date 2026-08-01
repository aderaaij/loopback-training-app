# Per-Domain Data Consent — Server-Side Spec

The iOS app (from 2026-07-31) lets the athlete choose which categories of health
data the coach may see. It pushes that choice to the training API on every launch
and on every change.

## Status: shipped

**Server side landed in training-api 0.1.12 (2026-08-01).** Both halves are in —
the consent record and the MCP tool filtering that makes it mean something. The
contract below is what exists, not a request. iOS needed no changes; verified
that the app sends no trailing slash on any route, and that 0.1.12 evaluates
`.compatible` against the version gate.

Deviations from the original ask, all deliberate and all server-side:

- **Two timestamps, not one.** `updatedAt` moves only on a real change;
  `reportedAt` moves on every call. One stamp couldn't answer both "when did this
  change" and "has this athlete ever reported", and the second question is the
  one worth seeing — an athlete whose choice equals the permissive default would
  otherwise be indistinguishable from an app that has never reported at all.
- **Column filtering does the heavy lifting**, not tool omission — see *MCP Tool
  Filtering* below.
- Audit rows go to the existing `auth_events` trail, on change only. That
  endpoint prunes past 365 days, so it's a trail, not a permanent ledger.

**Read this before adding a route on either side:** FastAPI's automatic
slash-redirect never fires in this server. The SPA catch-all matches
`/{full_path:path}` first, finds a GET-only route, and answers any other method
with `405`. So a `405` does *not* reliably mean "not implemented" — it's also
what a correct route returns when the path spelling is off by a trailing slash.
Both spellings of `/api/me/data-consent` are registered.

---

## The Domains

Five domains. `training` is always present — an athlete who shares nothing else
still shares workouts, because without them there is no training history.

| Wire value  | Covers | Governs on the server |
|-------------|--------|-----------------------|
| `training`  | Workouts, routes, in-workout HR, effort scores | `/api/workouts*`, plans, queue, feedback |
| `recovery`  | Sleep, resting HR, HRV, respiratory rate, SpO2 | Sleep samples + those columns of the daily metrics table |
| `body`      | Weight, body fat, lean mass, VO₂ max | Those columns of the daily metrics table |
| `activity`  | Steps, active energy, basal energy | Those columns of the daily metrics table |
| `nutrition` | Logged food and drink | `/api/nutrition*` |

These strings are API surface. Renaming one silently revokes a domain, because
the server would stop recognising what the app sends. Source of truth is
`DataDomains.wireValue` in `OpenHealthSync/Models/DataDomains.swift`.

Note that `recovery`, `body` and `activity` all map onto *columns of the same
daily-metrics row*, not separate tables. The app already omits unconsented
columns from its uploads (they arrive `null`, which the existing upsert reads as
"not tracked"), so no server change is needed for writes. It matters for reads:
an MCP tool returning a whole metrics row would leak columns from unconsented
domains even though the app stopped sending new ones.

---

## `PUT /api/me/data-consent`

Authenticated like every other `/api/*` call (`Authorization: Bearer <token>`).
Operates on the token's own user — no user ID in the path.

**Request:**

```jsonc
{
  "domains": ["training", "recovery", "activity"]
}
```

**Field details:**

| Field     | Type       | Required | Description |
|-----------|------------|----------|-------------|
| `domains` | `string[]` | Yes      | The complete set the athlete shares. Not a delta — replaces the stored set wholesale. |

**Behaviour:**

- Idempotent. The app calls this on **every launch**, so it will be hit far more
  often than it changes. Keep it cheap; don't write history rows on every call
  unless an audit trail is wanted (it might be — see *Open questions*).
- Unknown strings in the array should be **ignored, not rejected**. A future app
  version may add a domain before the server knows it; a `400` there would break
  consent pushes for every older-server user.
- `training` should be forced into the stored set even if absent.
- `200` with the stored set echoed back, or `204`. The app ignores the body.

**Response (suggested):**

```jsonc
{
  "domains": ["training", "recovery", "activity"],
  "updatedAt": "2026-07-31T17:40:21Z"
}
```

---

## Database Schema

Simplest form — one column on the user record:

```sql
ALTER TABLE users
  ADD COLUMN data_consent TEXT[] NOT NULL DEFAULT ARRAY['training'],
  ADD COLUMN data_consent_updated_at TIMESTAMPTZ;
```

A `TEXT[]` rather than five booleans so adding a domain doesn't need a migration,
and so unknown values can round-trip harmlessly.

### The default matters — read this before picking one

`DEFAULT ARRAY['training']` above is the *safe* default, but it is probably the
wrong one for this deployment. Consider what an absent record actually means:

- **An app that predates consent**, which had no way to restrict anything. Here
  "all domains" is the correct reading, and defaulting to training-only would
  silently strip a working coach of its context.
- **A current app whose push failed** (network, or the current 405). Here "all
  domains" leaks a domain the athlete may have turned off — but only until the
  next launch, since the app re-pushes every time.

Given the app pushes on launch, on onboarding completion, and on every change,
the second window is small and self-healing. **Recommendation: default to all
five domains**, and treat the absence of a record as "not yet reported" rather
than as a restriction:

```sql
ALTER TABLE users
  ADD COLUMN data_consent TEXT[]
    NOT NULL
    DEFAULT ARRAY['training','recovery','body','activity','nutrition'],
  ADD COLUMN data_consent_updated_at TIMESTAMPTZ;
```

Worth logging (or surfacing on the dashboard) which users have a `NULL`
`data_consent_updated_at`, so "never reported" stays visible rather than
disappearing behind a permissive default.

This mirrors what the iOS migration did: an existing install that had health
syncing on was migrated to all five domains, precisely so the upgrade didn't
revoke consent on the athlete's behalf. Both branches of that migration were
verified on-device.

---

## MCP Tool Filtering — the actual requirement

> **As shipped.** Tool-level filtering plus per-response column filtering. What
> the coach sees:
>
> | Tool | Needs | Notes |
> |---|---|---|
> | `get_health_metrics` | any of `recovery` / `body` / `activity` | columns filtered per response |
> | `get_nutrition`, `get_nutrition_summary` | `nutrition` | blocks filtered per response |
> | everything else | — | `training`, always available |
>
> Two findings from the implementation, both worth remembering:
>
> **There is no sleep tool to omit.** The backend has `/api/health/sleep/*` but
> the MCP never exposed it — sleep reaches the coach only as columns of
> `get_health_metrics`. So for three of the five domains, option 1 below isn't
> the preferred choice, it's the only one that does anything. Tool omission alone
> would have been a no-op for `recovery` unless all three metric domains were off.
>
> **`get_nutrition_summary` spans four domains despite its name.** It carries
> `body` (weight) and `expenditure` (active/basal energy) alongside the nutrition
> averages, and `protein_g_per_kg` is weight data wearing a nutrition name.
> Gating it on `nutrition` alone would have disclosed body and activity to a
> coach holding neither. **Derived fields crossing domain boundaries is the
> general trap** — worth auditing any new field that combines two sources.
>
> Unshared columns are **absent from the payload, not null**: null already means
> "not tracked" in these responses, so nulling them would have had the coach
> report a gap the athlete doesn't have.

**Filter the advertised tool list. Do not advertise a tool and then refuse the
call.**

A tool that is listed and then errors produces a coach that retries, apologises,
and tells the athlete to go enable sleep tracking — reintroducing in conversation
exactly the nagging the app's own surfaces were built to avoid. An unadvertised
tool is simply never reasoned about; the coach works with what it has.

FastMCP builds the tool list per session, so the filter belongs wherever the
session's authenticated user is resolved.

Map each existing tool to a required domain. Actual tool names in the
`training-api` repo will differ from these descriptions — this is the mapping by
capability:

| Tool capability | Required domain | If absent |
|---|---|---|
| Query workouts / runs / splits / HR | `training` | Always available |
| Create / update / queue plans and workouts | `training` | Always available |
| Read missed-workout feedback | `training` | Always available |
| Read sleep (samples or nightly rollups) | `recovery` | Omit tool |
| Read resting HR / HRV / respiratory / SpO2 | `recovery` | Omit tool |
| Read weight / body composition / VO₂ max | `body` | Omit tool |
| Read steps / active + basal energy | `activity` | Omit tool |
| Read nutrition / fuelling | `nutrition` | Omit tool |

### The mixed-row problem

Any tool that returns a whole daily-metrics row spans `recovery`, `body` **and**
`activity` at once. Three options, in order of preference:

1. **Filter the columns per response** against the user's domains. Keeps one
   tool, and the coach sees a row with fewer fields — which it already handles,
   since unrecorded metrics have always come back null.
2. Split into three tools, one per domain. Cleaner filtering, more tools.
3. Require all three domains to expose the tool at all. Simplest, and the worst
   outcome for the athlete who shares only steps.

Option 1 also handles historical data correctly: a domain switched off today
leaves rows already stored from when it was on, and column filtering hides them.
Tool-level filtering alone would too, but only if the tool is fully omitted.

### Tool descriptions

Don't mention the missing domains in the descriptions of the tools that remain.
"Sleep data is unavailable for this user" invites the coach to ask for it. The
absence should be silent.

---

## What the app does, precisely

Source: `startHealthPipeline()` in `OpenHealthSync/App/OpenHealthSyncApp.swift`.

The push fires:

- on launch, for an already-onboarded athlete, after HealthKit authorization
- on completion of onboarding
- on every consent change in Settings → Sync

Failure is logged (`AppLog.health`) and ignored — the app stays fully functional
against a server without the endpoint. Consent is stored locally regardless, so
the iOS surfaces respect it even if the push never lands.

The array always contains `training`. It never contains anything outside the five
values above.

---

## Not required yet

**Per-domain deletion.** The Settings copy currently promises only that syncing
stops: *"what's already on your server stays until you delete it there."* That's
honest, but a `DELETE /api/me/data/{domain}` would let the app offer removal at
the moment consent is withdrawn, which is the moment it's wanted. Worth doing
after the above, not instead of it.

---

## Open questions — answered

- **Audit?** Yes, on change only, via the existing `auth_events` trail
  (`data_consent_changed`). Pruned past 365 days.
- **Dashboard?** The admin Users screen shows what each athlete shares and flags
  **"not reported"** in amber.
- **Does anything bypass the filter?** Yes, and deliberately. The dashboard reads
  the same endpoints unfiltered, because consent governs disclosure *to the
  coach* and the dashboard is the athlete looking at their own data. The trigger
  is an `X-Consent-Scope` header the MCP sends; no header means the athlete is
  asking.

### The honest description of what this is

**A disclosure boundary, not access control.** Anyone holding the athlete's token
can call the REST API directly and get everything, consent record or not. Making
it enforceable would mean a `coach` scope on tokens — a bigger change, and
unnecessary for a self-hosted single-user deployment, but the distinction should
never be blurred in user-facing copy.

The app's copy currently stays on the right side of this: Settings says the coach
"can only see — and only reason about — the data you share here", which is true
of the coach specifically. Any future wording that generalises that to "nothing
else can read it" would be a claim the architecture doesn't support.

### Constraint worth knowing (server side)

MCP **server instructions cannot be built per session** — FastMCP snapshots them
when the connection opens, before middleware runs, and `on_initialize` looks like
the hook but isn't. Domain-specific guidance therefore lives on *tool*
descriptions, which ship only when their tool does. `mcp/tests/test_consent_filter.py`
asserts domain guidance stays out of the instructions.
