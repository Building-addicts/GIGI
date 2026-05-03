# KILLSIRI — landing

Anti-Siri movement landing for **killsiri.xyz**. Static site, zero build step, deploys on Vercel in 30s.

## Stack
- HTML / CSS / vanilla JS — no framework, no bundler
- Supabase RPC (waitlist storage)
- Vercel hosting (static)

## Local dev
```bash
cd 04_LANDING_KILLSIRI
python3 -m http.server 8000
# open http://localhost:8000
```
Or use any static server (`npx serve`, `live-server`, etc).

## File map
| File | Role |
|---|---|
| `index.html` | Markup — hero / manifesto / versus / join / certificate / token / footer |
| `styles.css` | Brutalist B&W cult styling |
| `script.js` | Email submit, rebel name/ID/code generation, share, counter |
| `vercel.json` | Hosting config + security headers |
| `supabase-schema.sql` | DB schema (run later when activating Supabase) |

## Deploy on Vercel

**Production:** [killsiri.xyz](https://killsiri.xyz/) · [Manifesto anchor](https://killsiri.xyz/#manifesto)

The custom domain **`killsiri.xyz`** is attached to Vercel project **`gigi-killsiri`** (team: `leonardo-cortes-projects-9957039f`). Deploy **from this folder only** so the site root is these static files (`index.html`, `assets/`, …).

### CLI (from monorepo)

```bash
cd 04_LANDING_KILLSIRI
vercel link    # pick team + project "gigi-killsiri" (first time)
vercel deploy --prod --yes
```

Notes:

- **`vercel link`**: if you omit this, the CLI may create a new project name from the parent repo path and refuse invalid names (`---`).
- **`killsiri-landing`**: an extra test project may exist from a mistaken first link; delete it in the Vercel dashboard if unused.

### Dashboard (Git integration)

1. Import repo → set **Root Directory** = `04_LANDING_KILLSIRI`
2. Framework: **Other** (no build)
3. Attach domain `killsiri.xyz` **or** reuse project **gigi-killsiri** that already owns the domain

## Activate Supabase (do AFTER site is perfect)

1. Create project on supabase.com
2. SQL Editor → paste contents of `supabase-schema.sql` → run (or run the canonical `../supabase/migrations/202605030001_gigi_core.sql`)
3. Settings → API → copy `URL` and `anon public key`
4. Open the `SUPABASE CONFIG` block in `script.js` → replace placeholders:
   ```js
   const SUPABASE_URL = "https://xxx.supabase.co";
   const SUPABASE_ANON_KEY = "eyJhbG...";
   ```
5. Redeploy

Until step 4 is done, signups are stored in `localStorage` (browser-local fallback). Site works fully without Supabase. Once enabled, the landing calls `killsiri_join_waitlist` and `killsiri_rebel_count` RPCs instead of exposing raw waitlist rows.

## What's intentionally NOT here yet
- PDF certificate generation (placeholder visual only)
- Welcome email automation (Supabase Auth or Resend integration — TODO)
- GDPR / privacy policy page (TODO before EU launch)
- hCaptcha / spam protection
- Real Apple/Siri imagery (parody only — handled via typography)

## Notes for next iteration
- Counter has a `baseline = 1247` in `script.js:103` — feels less empty at launch
- Referral tracking: `?ref=SHARECODE` in URL, awards +20 to referrer via SQL trigger
- All copy is final per brief; tweak in `index.html` only

## Brand law (do not break)
- Pure `#000` and `#fff`. `#ff0000` reserved for KILL/DEAD/MUTINY words only.
- Uppercase brutalist headlines. No rounded corners. No drop shadows except on hover.
- All user-facing copy in English. Italian only in code comments / repo docs.
