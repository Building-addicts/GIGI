# GIGI Supabase database

Canonical database source for GIGI is `supabase/migrations/202605030001_gigi_core.sql`.

## What v1 covers

- **Identity**: users, trusted devices, channel identities, external accounts.
- **Conversation ledger**: sessions and messages for replay/audit.
- **Agentic execution**: delegated jobs, job events, permission gates for actions that can spend/send/book/order.
- **Memory**: SQL-native durable memories, tags, lifecycle, sensitivity, event audit, preferences.
- **KILLSIRI**: landing waitlist, first-batch governance power, referral events.

## Security model

- Every public table has RLS enabled.
- Browser/anon users do **not** read waitlist tables directly.
- Landing uses controlled RPCs only:
  - `killsiri_join_waitlist(...)`
  - `killsiri_rebel_count()`
- Harness server uses the Supabase **service role key** for memory RPCs:
  - `gigi_memory_put(...)`
  - `gigi_memory_query(...)`
  - `gigi_memory_delete(...)`
  - `gigi_memory_all(...)`
- App users authenticated through Supabase Auth can only access rows mapped to their own `app_users.id`.

## Apply from dashboard

1. Open Supabase SQL Editor.
2. Paste `supabase/migrations/202605030001_gigi_core.sql`.
3. Run it once. It is written to be rerunnable for functions/policies/indexes.

## Apply from CLI

```bash
supabase link --project-ref <your-project-ref>
supabase db push
```

Supabase's migration convention is `supabase/migrations/*.sql`, so the CLI will pick this file up directly.

## Harness env

In `03_HARNESS/server/.env`:

```bash
MEMORY_BACKEND=supabase
SUPABASE_URL=https://<project-ref>.supabase.co
SUPABASE_SERVICE_ROLE_KEY=<service-role-key-server-only>
```

Never put `SUPABASE_SERVICE_ROLE_KEY` in iOS, landing pages, or any client bundle.

## Landing env

The static landing only needs:

```js
const SUPABASE_URL = "https://<project-ref>.supabase.co";
const SUPABASE_ANON_KEY = "<anon-public-key>";
```

The anon key can execute the two KILLSIRI RPCs but cannot select raw waitlist rows.

## v2 intentionally deferred

- pgvector embeddings and HNSW indexes.
- Supabase Auth sign-in UX in the iOS app.
- Encrypted vault for external provider tokens.
- Data export/delete UI.
