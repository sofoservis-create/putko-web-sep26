#!/bin/bash
# scripts/replit-start.sh — one command to get the app running on Replit.
#
#   bash scripts/replit-start.sh
#
# Deliberately does not depend on the Run button: if a workflow is cached or
# configured in Replit's UI, editing .replit may not change what Run does,
# and you are left staring at the old app with no clue why. This checks each
# prerequisite in turn and says which one is missing instead.

set -uo pipefail
cd "$(dirname "$0")/.."

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
bad()  { printf '  ✗ %s\n' "$*"; }

say "1/4  Is the new code actually here?"
if [ ! -f artifacts/web/app/page.tsx ]; then
  bad "artifacts/web is missing — the pull did not bring it."
  echo
  echo "     Run:  git fetch origin && git status"
  echo "     If it says you are behind, run:  git pull origin main"
  echo "     If it says you are on a different branch:  git checkout main && git pull"
  exit 1
fi
ok "artifacts/web present ($(git log -1 --format='%h %s' 2>/dev/null || echo 'no git info'))"

say "2/4  Dependencies"
if [ ! -d artifacts/web/node_modules ] || [ ! -d node_modules/.pnpm ]; then
  echo "  installing (this takes a minute the first time)…"
  pnpm install || { bad "pnpm install failed"; exit 1; }
fi
ok "installed"

say "3/4  Database"
if [ -z "${DATABASE_URL:-}" ]; then
  bad "DATABASE_URL is not set."
  echo
  echo "     On Replit: open the Database tab in the left sidebar and create a"
  echo "     PostgreSQL database. Replit sets DATABASE_URL automatically, and"
  echo "     that database supports PostGIS, which this app requires."
  echo
  echo "     Then run this script again."
  exit 1
fi

# Can we even reach it? Checked separately from "is it set up", because
# conflating the two makes an unreachable database report as an empty one —
# which is what this script did on its first run against a stopped Postgres,
# sending setup off to fail on a connection error while claiming the
# database was empty.
if ! conn_error=$(psql "$DATABASE_URL" -tAc "SELECT 1" 2>&1 >/dev/null); then
  bad "cannot connect to the database."
  echo
  echo "$conn_error" | sed 's/^/     /'
  echo
  echo "     Check DATABASE_URL, and that the database is running."
  exit 1
fi

# Set up already? Re-running setup-db.sh is safe either way, but skipping it
# when nothing is needed keeps this fast.
count=$(psql "$DATABASE_URL" -tAc "SELECT count(*) FROM destinations" 2>/dev/null || echo "0")

if [ "$count" = "0" ]; then
  echo "  database is empty — setting it up…"
  # No catch-all guess about the cause. setup-db.sh prints the real Postgres
  # error itself now; the previous version of this message blamed PostGIS for
  # every failure and sent someone chasing a problem that did not exist —
  # their extensions step had passed cleanly.
  bash scripts/setup-db.sh || {
    bad "Database setup failed — the reason is printed above."
    echo
    echo "     For the full picture:  bash scripts/diagnose-db.sh"
    exit 1
  }
else
  ok "$count destinations already seeded"
fi

say "4/4  Port 5000"

# EADDRINUSE is the most likely thing to go wrong here, and the message
# Next.js prints for it ("address already in use") does not say what has the
# port or what to do. Worse, on Replit Ctrl+C often does not kill the old
# server — the workflow keeps it alive — so the obvious remedy silently
# fails and you get the same error again.
# Try every tool and take the first that actually ANSWERS — not the first
# that happens to be installed. The previous version picked lsof whenever
# lsof existed, and in a container where lsof cannot see network sockets it
# returns empty and exits 0, so the script concluded the port was free and
# then failed with EADDRINUSE anyway. `fuser` found the pid immediately.
port_holder_pids() {
  local out
  if command -v lsof >/dev/null 2>&1; then
    out=$(lsof -t -i:5000 -sTCP:LISTEN 2>/dev/null)
    [ -n "$out" ] && { printf '%s' "$out"; return; }
  fi
  if command -v fuser >/dev/null 2>&1; then
    out=$(fuser 5000/tcp 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$')
    [ -n "$out" ] && { printf '%s' "$out" | tr '\n' ' '; return; }
  fi
  # Last resort: whatever is running `next dev` for this workspace.
  pgrep -f "next dev.*-p 5000" 2>/dev/null | tr '\n' ' '
}

# Whether the port is occupied is decided by trying to talk to it, not by
# whether a pid lookup succeeded — the two can disagree, and the connection
# is the thing that actually matters.
port_busy() {
  (exec 3<>/dev/tcp/127.0.0.1/5000) 2>/dev/null && exec 3>&- && return 0
  return 1
}

pids=$(port_holder_pids)
if port_busy; then
  # If what is already there is this app, serving it, there is nothing to
  # fix — say so and stop, rather than killing a working server and
  # starting an identical one.
  if curl -sf -o /dev/null --max-time 3 http://localhost:5000/ 2>/dev/null; then
    ok "the app is ALREADY RUNNING on port 5000"
    echo
    echo "     Open the webview, or the *.replit.dev URL. Nothing to do."
    echo "     To restart it anyway:  kill $pids  &&  bash scripts/replit-start.sh"
    exit 0
  fi

  # Something holds the port but is not serving. Free it.
  echo "  port 5000 is held${pids:+ by pid(s) $pids} but not serving — freeing it"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    sleep 1
    port_busy || break
  done
  if port_busy; then
    # shellcheck disable=SC2086
    kill -9 $(port_holder_pids) 2>/dev/null || true
    sleep 2
  fi
  if port_busy; then
    bad "could not free port 5000. Stop the Run workflow in Replit, then retry."
    exit 1
  fi
  ok "freed"
else
  ok "free"
fi

say "Starting the app"
echo "  Once it says Ready, open the webview — or the *.replit.dev URL."
echo "  Demo login: demo-hostka@putko.example / demo-host@putko.example"
echo "  Password:   putko-demo-2026"
echo

# -H 0.0.0.0 is not optional: Replit proxies in from outside the container,
# so a server bound to localhost is running and unreachable, which looks
# exactly like "nothing happened".
# Next.js phones home with anonymous build telemetry by default. This
# project's rules are explicit that nothing gets sent without consent; that
# rule is about guests, and holding to it for the developer's own machine
# costs one environment variable.
export NEXT_TELEMETRY_DISABLED=1

exec pnpm --filter @workspace/web exec next dev -H 0.0.0.0 -p 5000
