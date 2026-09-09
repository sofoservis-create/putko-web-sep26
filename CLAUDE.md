# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A **ground-up rebuild** of Putko — a Slovak short-term accommodation rental
marketplace (Airbnb/Booking.com model). Operator: Putko s. r. o., IČO 57 329 206.

**Read this before touching anything:** the live putko.sk deploys from a
**different repository** that is not part of this session and must not be
modified. This repo is the replacement being built alongside it. The
`.migration-backup/` directory here is a **read-only snapshot** of the old
Express/MongoDB + Next.js code, kept as reference material — it is not
deployed, and changes to it do not reach production.

The goal is a standalone platform that stands on its own merits, not a
migration that touches the original system.

## Binding business rules

These come from the product owner, not from the code. The snapshot in
`.migration-backup/` actively contradicts several of them — where they
disagree, **these rules win**.

- **Legal position:** Putko is an intermediary (sprostredkovateľ). The rental
  contract is between guest and host; Putko is never a contracting party.
- **Payments:** Stripe Connect Express, *separate charges and transfers* (not
  destination charges). Commission is **6%**, deducted implicitly by
  transferring less than the charge — never a separate API call.
- **Putko is NOT a VAT payer.** No VAT line on the commission invoice.
  (§ 69 ods. 5 zákona č. 222/2004 Z. z.: stating VAT on an invoice makes you
  liable for it whether or not you collected it.)
- **Payout trigger:** nightly cron. Transfer at check-in + 24h *only if* there
  is no open complaint AND the host has ≥3 completed bookings. Otherwise
  check-out + 24h.
- **Cancellation policies:** exactly three fixed tiers — Flexible, Standard,
  Strict. **No custom policies.** The applicable policy must be snapshotted
  onto the booking row at booking time and refunds read from that snapshot —
  never JOINed back to the listing (a host editing their policy must not
  retroactively change existing bookings).
- **Host cancellation after payment:** full guest refund. Account deactivation
  after 3 cancellations in 12 months.
- **Hosts without Stripe onboarding:** "Request to book" only. No money may be
  taken until onboarding is complete and the host confirms.
- **Hosts** are businesses *or* private individuals; mandatory
  podnikateľ/nepodnikateľ declaration with a visible badge on the listing.
- **Invoicing:** hosts invoice guests themselves. Putko issues only a monthly
  aggregate commission invoice to hosts, via the SuperFaktúra API.
- **Local accommodation tax** is collected by hosts on site. The platform must
  not compute or collect it.
- **Guest minimum age 18.** Reservation data retention: 3 years.
- **Search ranking default:** availability → distance → price, unless the user
  picks another sort.
- **Analytics:** Google Analytics and Meta Pixel must be blocked until explicit
  cookie consent. Firing before opt-in is a GDPR violation, not a preference.

## Commands

Package manager is **pnpm** (enforced — a `preinstall` hook rejects npm/yarn).

```sh
pnpm install                      # workspace root
pnpm run typecheck                # all packages
pnpm run build                    # typecheck + build everything
```

Database (`lib/db`, package `@workspace/db`):

```sh
cd lib/db
pnpm run generate                 # generate a migration from the TS schema
pnpm run generate -- --custom --name <name>   # empty migration for hand-written SQL
pnpm run migrate                  # apply migrations (scripts/migrate.mjs)
pnpm run migrate:drizzle-kit      # the drizzle-kit equivalent; same ledger
bash ../../scripts/diagnose-db.sh # dump extensions, tables, migrations, columns
bash ../../scripts/reset-db.sh    # DESTRUCTIVE: drop all and rebuild (asks first)
# NEVER `pnpm run push` on this project — drizzle-kit push diffs the TS
# schema and would create every table WITHOUT listings.geog and
# destinations.centre (both hand-written; see the PostGIS gotcha below).
# The schema would look complete and every geographic query would fail.
pnpm run verify:no-double-booking # the overlap-constraint proof (see below)
pnpm run seed:destinations        # the "Obľúbené miesta" catalogue (idempotent)
pnpm run verify:destinations      # tile counts == page results (see below)
pnpm run seed:demo-listings       # 17 fictional listings, dev only
pnpm exec tsx scripts/seed-demo-accounts.ts   # demo login, dev only
pnpm exec tsx scripts/smoke-destination-queries.ts   # the exported query fns
```

Web app (`artifacts/web`, package `@workspace/web`):

```sh
cd artifacts/web
pnpm run dev                      # http://localhost:3000
pnpm run build && pnpm start
```

Both verify scripts write fixtures inside a transaction they always roll
back, so they are safe to re-run — but point `DATABASE_URL` at a throwaway
database anyway, never production.

All `lib/db` commands need `DATABASE_URL`. A local `.env.local` holds it
(gitignored); export it first: `export $(cat .env.local | xargs)`.

### Local Postgres setup

There is **no Docker daemon** in the Claude Code sandbox — `docker` exists but
cannot run. Use the natively installed Postgres 16 instead:

```sh
apt-get install -y postgresql-16-postgis-3 postgresql-16-postgis-3-scripts
service postgresql start
su postgres -c "psql -c \"CREATE ROLE putko WITH LOGIN SUPERUSER PASSWORD 'putko';\""
su postgres -c "createdb -O putko putko"
psql "postgresql://putko:putko@localhost:5432/putko" \
  -c "CREATE EXTENSION postgis; CREATE EXTENSION unaccent;
      CREATE EXTENSION btree_gist; CREATE EXTENSION pg_trgm;"
```

All four extensions are required and all four exist on Render Postgres too —
`postgis` (distance search), `unaccent` ("Kosice" must find "Košice"),
`btree_gist` (required for the overlap constraint), `pg_trgm` (fuzzy name
search).

## Architecture

### The double-booking guarantee — the load-bearing design decision

`calendar_blocks` is the single availability model: confirmed bookings,
checkout holds, manual host blocks and imported iCal events all live in **one
table**, so search and booking cannot disagree about what "taken" means. The
guarantee is a database constraint, not application logic:

```sql
EXCLUDE USING gist (listing_id WITH =, stay WITH &&) WHERE (released_at IS NULL)
```

Postgres evaluates this inside the INSERT's own lock, so two concurrent
requests for the same dates cannot both succeed. **Never** reintroduce a
"check availability, then insert" pattern — a separate SELECT first re-opens
exactly the race this closes. Claim dates through `claimDates()` in
`lib/db/src/queries/availability.ts`; it returns
`{ ok: false, reason: "dates_unavailable" }` rather than throwing.

Proof and reproduction: `lib/db/PROOF-no-double-booking.md`.

### Destinations — counts that cannot lie

The "Obľúbené miesta na Slovensku" browse layer (`destinations`). A listing
belongs to a destination **by geography, not by a foreign key**: each
destination is a `centre geography(Point,4326)` plus `radius_m`, and
membership is `ST_DWithin(listings.geog, destinations.centre, radius_m)`.

There is no `destination_listings` join table and no tagging step, on
purpose. It means tile counts are a live `COUNT(*)`, so:

> **the number on a tile == the number of results you get when you click it**

That is the invariant, and it is held structurally: `MEMBERSHIP` in
`lib/db/src/queries/destinations.ts` is one SQL fragment, and both the
counting query and the listing query interpolate it. **Never** count
listings for a tile with a different predicate than its page uses — that is
audit finding D-01 (a hero reading "1433+ ubytovaní" above a catalogue of 6)
reintroduced.

Two consequences worth knowing before editing:

- Destinations **overlap by design**. A chata near Štrbské pleso is in
  Vysoké Tatry, Tatry, Spiš and Poprad simultaneously. That is the truth,
  not a data error.
- `parent_slug` is **navigation, not geometry**. A child's count comes from
  the child's own circle, so child counts do not sum to the parent's, and a
  child can even sit outside its parent's circle (Donovaly does). Never
  render them as a breakdown.

Known limitation, demonstrated: a circle cannot express a long valley.
Zuberec (Orava) is 20.7 km from Liptov's centre while Východná (Liptov) is
29.1 km, so no radius separates them — the fix is polygons for the valley
regions, which changes only `MEMBERSHIP`. Asserted in the verify script so
it stays visible. See `docs/DESTINATIONS.md`.

The catalogue itself is editorial and lives in
`lib/db/scripts/seed-destinations.mjs`, not in a migration — correcting a
radius means editing the array and re-running (idempotent upsert). After any
edit run `pnpm run verify:destinations`: it asserts the invariant and
carries an allowlist of every legitimate circle-overlaps-circle pair, so a
radius change that quietly starts pulling Liptov listings into Orava fails
the script instead of shipping.

### Accounts — identity comes from the server, never the client

`/ucet` (guest) and `/host` share one shell, one identity model and one set
of queries. `app/_lib/session.ts` resolves the caller from an **httpOnly**
session cookie joined to a session row; a page never handles a user id it
could substitute. The old system reads
`JSON.parse(localStorage.getItem("user"))._id` and sends it to the API as
the thing being asked about — which is audit finding C-01.

Three rules:

- **Auth is enforced in the layout** (`requireSession` / `requireHost`), so
  it covers every route added later without anyone remembering. Hiding a
  button in a client component is not authorization.
- **Every account query takes the caller's identity and filters in SQL**
  (`lib/db/src/queries/account.ts`). There is no "all reservations"
  function to call by accident. The old `/reservations` page fetches every
  booking on the platform and prints each guest's email and phone
  (`reservations/page.js:314–315`) behind a `useState(false)` gate — a
  personal-data breach, and the reason this rule exists.
- **Password and session primitives live in `lib/auth`, once.** Extracted
  from `artifacts/api-server/src/routes/test-auth.ts`, byte-compatible.
  Never add a second implementation of password verification.

Login must not distinguish "no such account" from "wrong password" — in the
message *or* in the timing. See `docs/ACCOUNTS.md`.

### Data conventions

- **Money is always integer cents.** Never float, never `numeric`.
- **Date ranges are half-open `[check_in, check_out)`.** The checkout day is
  free for the next guest. This matches iCal's DTEND and Postgres range
  semantics. (`daterange` is a discrete type — Postgres canonicalizes every
  value to `[)` automatically, so a closed range cannot be constructed.)
- **Calendar dates are `date`, not `timestamptz`.** A stay is a pair of
  calendar dates; there is no timezone to get wrong if the column can't hold
  one. Business-time decisions resolve in `Europe/Bratislava`.
- **One status column per aggregate**, with transitions enforced in one place.
  The old system spread booking state across `isApproved`/`paymentStatus`/
  `payoutStatus` with no guard, which permitted eight illegal transitions.
- `legacy_mongo_id` (unique, nullable) on migrated tables makes any ETL from
  the old MongoDB idempotent and re-runnable.

### Layout

- `artifacts/web/` — the Next.js 15 app (`@workspace/web`). Design tokens
  live in `app/globals.css` and **no hex value belongs anywhere else** —
  the current site accumulated ten near-identical greens exactly that way.
  Two gotchas cost real time there; see Gotchas below.
- `lib/db/` — Drizzle schema, migrations, queries (`@workspace/db`)
- `lib/api-spec/`, `lib/api-zod/`, `lib/api-client-react/` — OpenAPI spec and
  Orval-generated clients/schemas
- `artifacts/api-server/` — Express scaffold; `test-auth.ts` is a working auth
  prototype (scrypt, hashed session tokens, `timingSafeEqual`) worth building
  on rather than replacing
- `artifacts/putko/` — Vite/React app migrated from the original Next.js app
- `.migration-backup/` — **reference only**, see above
- `lib/auth/` — password + session primitives, the only copy (`@workspace/auth`)
- `render.yaml` — Render Blueprint (`putko-db`, `putko-kv`, Frankfurt/EU)
- `scripts/setup-db.sh` — empty Postgres → working database, idempotent.
  Extensions first (0002 needs postgis + btree_gist), then `migrate`, then
  seed. Verified end-to-end against a genuinely fresh database.

## Gotchas found the hard way

Each of these cost real debugging time. Don't rediscover them.

- **Pick the tool that ANSWERS, not the one that is installed.** A port
  check chose `lsof` whenever `lsof` existed; in a container where lsof
  cannot see network sockets it returns empty and exits 0, so the script
  declared the port free and then died with EADDRINUSE. `fuser` had the pid
  the whole time. Try each in turn and take the first non-empty result — and
  decide "is the port busy" by opening a connection, not by whether a pid
  lookup succeeded.
- **Do not conflate "cannot connect" with "empty".** The same script reported
  a stopped Postgres as an empty database and sent setup off to fail on a
  connection error. Probe reachability separately from contents.
- **`42P07` / `42710` on migrate means someone ran `drizzle-kit push`.** A
  table or type exists that no migration created, and there is no ledger.
  Never adopt that schema by skipping migrations: a pushed schema has no
  `listings.geog` and no `destinations.centre`, so it looks complete and
  every geographic query fails. On a dev database, `scripts/reset-db.sh`.
- **`drizzle-kit migrate` swallows the Postgres error.** A failing migration
  prints a spinner and exits 1 — no error code, no message, no filename, so
  the visible output is just `ERR_PNPM_RECURSIVE_RUN_FIRST_FAIL`. That cost a
  round of blaming PostGIS for a failure that was `42P07 relation already
  exists`. `pnpm run migrate` is now `scripts/migrate.mjs`, which prints the
  code, the message, the statement and the file. It is interchangeable with
  drizzle-kit — same ledger table, `hash` = SHA-256 of the file, `created_at`
  = the journal's `when`; verified in both directions.
- **The build must work without `DATABASE_URL`.** `next build` imports every
  page to collect its config, so anything that throws at module import time
  kills the build on every host. `lib/db/src/index.ts` creates the pool AND
  the Drizzle handle lazily — both, because `drizzle()` reads a property off
  the client while constructing, so making only the pool lazy just moved the
  error. Verify with `env -u DATABASE_URL pnpm build`.
- **`drizzle.config.ts` paths must be relative.** drizzle-kit prefixes its own
  `./` onto `out`/`schema`, so `path.join(__dirname, ...)` produces a doubled,
  unresolvable path (`.//home/...`) and breaks `generate`/`migrate` entirely.
- **PostGIS `geography(Point, 4326)` cannot be declared via Drizzle
  `customType()`.** drizzle-kit quotes the whole type expression as an
  identifier and Postgres rejects it (`type "geography(Point, 4326)" does not
  exist`). Add such columns in a hand-written custom migration — drizzle-kit's
  documented pattern for features its schema builder doesn't model. Plain
  single-word types like `daterange` are fine.
- **Drizzle wraps Postgres errors.** The real error code is on
  `err.cause.code`, not `err.code`. Checking only the top level silently
  misses `23P01` (exclusion_violation) and `23514` (check_violation).
- **Testing constraint violations needs SAVEPOINTs.** A Postgres transaction
  aborts entirely after any error and rejects everything after it with
  `25P02`. Wrap each expected-to-fail assertion in `SAVEPOINT` /
  `ROLLBACK TO SAVEPOINT`.
- **Tailwind v4 `@theme` tree-shakes.** It emits only the variables some
  generated utility references, so a token used solely from hand-written
  CSS or an arbitrary `var()` silently resolves to nothing — the build
  stays clean and the page just looks slightly wrong. Use `@theme static`
  for a token file, and prefer the generated utilities (`font-display`,
  `text-ink`) over `text-[var(--color-ink)]`.
- **next/font variables must go on `<html>`, not `<body>`.** A token like
  `--font-display: var(--font-fraunces), serif` is declared at `:root`; if
  `--font-fraunces` only exists on `<body>`, that substitution fails at
  `:root`, the property becomes guaranteed-invalid, and every descendant
  inherits the invalid value. Fonts load, build passes, nothing uses them.
- **`typedRoutes` needs `href: Route`, not `string`.** With it on, a nav
  item pointing at a page nobody built is a build failure instead of a 404
  a user finds. Runtime values (a `?next=` param) need an explicit cast —
  the safety there comes from validating the value, not from the type.
- **A page file may only export the fields Next.js expects.** Exporting a
  helper from `page.tsx` fails the build (`"formatStay" is not a valid Page
  export field`). Shared helpers go in `app/_lib/`.
- **A verify script must not assume an empty table.** The destination
  membership assertions passed only while `listings` was empty; the moment
  demo data existed, eight of them were testing the database's contents
  rather than the rule. Scope fixtures explicitly (`slug LIKE 'fx-%'`).
- **`unaccent` is not IMMUTABLE** and cannot be indexed directly. Wrap it:
  `CREATE FUNCTION f_unaccent(text) ... IMMUTABLE ... $$ SELECT
  public.unaccent('public.unaccent', $1) $$;` then index on `f_unaccent(col)`.
- **Exclusion-constraint predicates must be IMMUTABLE**, so hold expiry
  (`now()`) cannot live in the `WHERE`. Expired holds are deleted inside the
  claiming transaction instead.

## Do not

- Modify anything under `.migration-backup/` expecting it to affect production.
- Reintroduce check-then-insert for availability.
- Add a `custom` cancellation policy tier.
- Add Elasticsearch/Meilisearch — Postgres FTS + `unaccent` + `pg_trgm` is
  sufficient well past current scale.
- Add a message queue — Render Cron Jobs (which guarantee at most one
  concurrent run per job) plus a Postgres table cover current needs.
- Keep MongoDB "for some things." One database.

## Reference documents

- `docs/DEPLOY.md` — how to get a public link (Replit / Vercel+Render / Render)
- `docs/REBUILD-PLAN.md` — phased roadmap, gates, and what's deliberately deferred
- `docs/DESTINATIONS.md` — the "Obľúbené miesta" catalogue, awaiting the owner's corrections
- `docs/ACCOUNTS.md` — guest account and host area: what the old ones do, what replaced them
- `audit/REPORT.md` — 63 findings against the old system, each with `file:line`
- `audit/DESIGN-AUDIT.md` — 22 design/UX findings, page by page
- `audit/DECISIONS-NEEDED.md` — 10 open product/legal decisions
- `audit/ARCHITECTURE.md` — Mermaid diagrams: components, booking state machine, payment lifecycle
- `audit/patches/` — 30 verified patches for the old system (applied here to the snapshot; **not** deployed anywhere)

## Note on `.agents/memory/`

Predates the current strategy and is partly stale. In particular,
`putko-legacy-backend-isolation.md` describes patching the live Render backend
from an `origin/main` worktree — that is **no longer the plan** and directly
contradicts the "do not touch the original repo" rule above.
`putko-rebuild-data-platform.md` (Postgres + PostGIS, preserve legacy payload
compatibility) remains accurate.
