# Supabase — come applicare lo schema GIGI Core

## Cosa hai già fatto (va bene)

Hai eseguito:

```sql
create schema if not exists private;
grant usage on schema private to authenticated, service_role;
```

È compatibile col file completo: le stesse istruzioni compaiono all’inizio della migration, quindi **ripeterle non rompe nulla**.

## Passo unico importante

**Non** eseguire a pezzi (solo trigger, solo funzione, ecc.). Una migration è **una transazione ordinata**: estensioni, tabelle, funzioni, trigger, policy, grant.

### Opzione A — Supabase Dashboard (più semplice)

1. Nel repo apri **`supabase/migrations/202605030001_gigi_core.sql`**.
2. Seleziona **tutto il contenuto** (es. Cmd+A).
3. [Supabase](https://supabase.com/dashboard) → il tuo progetto → **SQL Editor** → **New query**.
4. Incolla e clicca **Run** (una sola volta).

Se qualcosa fallisce a metà, leggi il messaggio dall’**inizio** dello script nella stessa sessione o correggi e rilanci (alcune parti sono idempotenti con `if not exists` / `or replace`; altre no — meglio un DB fresh o rollback manuale se è un progetto vuoto).

### Opzione B — Supabase CLI (se il progetto è linkato)

Dalla root del repo (con `supabase link` già configurato):

```bash
supabase db push
```

(applica le migration nella cartella `supabase/migrations/`)

## Controllo veloce dopo il run

```sql
select tablename from pg_tables
where schemaname = 'public'
order by tablename;
```

Dovresti vedere tra le altre: `app_users`, `memory_items`, `waitlist_signups`, …

Verifica anche le RPC pubbliche:

```sql
select routine_name
from information_schema.routines
where specific_schema = 'public'
  and routine_name in (
    'gigi_memory_put', 'gigi_memory_query',
    'gigi_memory_delete', 'gigi_memory_all',
    'killsiri_join_waitlist', 'killsiri_rebel_count'
  );
```

---

**Canonical SQL:** solo `supabase/migrations/202605030001_gigi_core.sql` — non manteniamo una seconda copia per evitare divergenze.

## Errore `42P17` / «generation expression is not immutable»

Le colonne `GENERATED STORED` richiedono espressioni **IMMUTABLE**; `to_tsvector(...)` è solo **STABLE**, quindi falliva su Supabase/Postgres recenti.

La migration corretta aggiorna `memory_items.search_vector` e `waitlist_signups.email_normalized` con **trigger** `BEFORE INSERT/UPDATE` invece di `GENERATED`.

Se una run è fallita a metà: progetto solo dev → Database → Reset, oppure droppare a mano gli oggetti già creati, poi incollare **l’intero** file dall’ultima versione (da `begin;` fino a `commit;`).