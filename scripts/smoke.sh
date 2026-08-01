#!/usr/bin/env bash
#
# scripts/smoke.sh — post-deploy smoke test for loopctl (READ-ONLY).
#
# Runs a handful of fast, read-only checks against a LIVE loopctl deployment to
# prove the crown-jewel paths (KB retrieval + agent memory) still work after a
# deploy. It issues NO state-mutating writes. Intended to run in CI immediately
# after the Fly deploy job (see .github/workflows/ci.yml `smoke` job) and to be
# runnable by hand:
#
#   LOOPCTL_SMOKE_KEY=<low-priv read key> bash scripts/smoke.sh
#
# Env:
#   BASE_URL           Base URL to probe                    (default https://loopctl.com)
#   LOOPCTL_SMOKE_KEY  API key for authed checks            (REQUIRED — a low-privilege read key)
#   SMOKE_MAX_MS       Per-request latency budget           (default 5000)
#   SMOKE_EMBED_MAX_MS Latency budget for checks that do an on-the-fly LLM query
#                      embedding (semantic search + memory recall)  (default 8000)
#
# Exit code is non-zero if ANY check fails, so a smoke failure turns the CI run
# RED and the operator knows to roll back (see docs/runbooks/post-deploy-smoke.md).
#
# Dependencies: bash, curl, jq only.
#
# Witness header note: loopctl's /api/v1 authenticated pipeline enforces the
# chain-of-custody witness header (X-Loopctl-Last-Known-STH) in every non-test
# environment. This script first PRIMES the current STH via the one-time
# bootstrap-grace response header, then sends it on every authed check — without
# it, all authed requests would fail with 412 witness_header_missing.

set -euo pipefail

BASE_URL="${BASE_URL:-https://loopctl.com}"
SMOKE_MAX_MS="${SMOKE_MAX_MS:-5000}"
# Semantic search and memory recall each generate a query embedding on the fly
# (an outbound LLM call, ~1-3s), so they get a wider budget than the pure DB paths.
SMOKE_EMBED_MAX_MS="${SMOKE_EMBED_MAX_MS:-8000}"
KEY="${LOOPCTL_SMOKE_KEY:-}"

# ✓ / ⚠ / ✗ markers.
OK="✓"
WARN="⚠"
NO="✗"

FAILURES=0

# Hard ceiling for curl itself — a few seconds above the WIDEST per-check budget so
# a hung endpoint can't stall the run, while a legitimately slow embed check still
# completes and is judged against its own budget.
if [ "$SMOKE_EMBED_MAX_MS" -gt "$SMOKE_MAX_MS" ]; then
  CURL_MAX_SECS=$(( (SMOKE_EMBED_MAX_MS / 1000) + 5 ))
else
  CURL_MAX_SECS=$(( (SMOKE_MAX_MS / 1000) + 5 ))
fi

# --- Dependency + arg checks (fail fast) ---------------------------------------

for dep in curl jq awk; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "$NO smoke aborted — required dependency '$dep' is not installed" >&2
    exit 2
  fi
done

if [ -z "$KEY" ]; then
  echo "$NO smoke aborted — LOOPCTL_SMOKE_KEY is unset." >&2
  echo "  Set it to a low-privilege read API key, e.g.:" >&2
  echo "  LOOPCTL_SMOKE_KEY=... bash scripts/smoke.sh" >&2
  exit 2
fi

# Scratch space for response bodies/headers; cleaned up on exit.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BODY="$TMP/body"
HDRS="$TMP/hdrs"

# HTTP_CODE / TIME_MS are set by http() and read by the assert helpers.
HTTP_CODE=""
TIME_MS=""

# http METHOD URL [extra curl args...]
# Writes the response body to $BODY and response headers to $HDRS, and sets
# HTTP_CODE + TIME_MS (milliseconds). A hard curl failure (DNS/connect/timeout)
# is normalized to code 000 so the caller reports a clean ✗ rather than aborting
# under `set -e`.
http() {
  local method="$1"
  local url="$2"
  shift 2
  local out
  # --max-time gives curl a hard ceiling a few seconds above the widest per-check
  # latency budget so a hung endpoint can't stall the whole run.
  if out=$(curl -sS -X "$method" \
      -o "$BODY" -D "$HDRS" \
      -w '%{http_code} %{time_total}' \
      --max-time "$CURL_MAX_SECS" \
      "$@" \
      "$url" 2>/dev/null); then
    :
  else
    out="000 0"
  fi
  HTTP_CODE="${out%% *}"
  local secs="${out##* }"
  TIME_MS="$(awk -v t="$secs" 'BEGIN { printf "%d", t * 1000 }')"
}

pass() { printf '%s %s (%sms)\n' "$OK" "$1" "$TIME_MS"; }

warn() { printf '%s %s — %s\n' "$WARN" "$1" "$2"; }

fail() {
  printf '%s %s — %s\n' "$NO" "$1" "$2" >&2
  FAILURES=$((FAILURES + 1))
}

# assert NAME EXPECTED_CODE [JQ_FILTER] [JQ_DESC] [BUDGET_MS]
# Enforces (in order): HTTP status, latency budget, then an optional jq predicate
# on the body. BUDGET_MS defaults to SMOKE_MAX_MS; pass SMOKE_EMBED_MAX_MS for
# checks that trigger an on-the-fly LLM embedding. Reports one ✓/✗ line.
assert() {
  local name="$1"
  local expected="$2"
  local jqfilter="${3:-}"
  local jqdesc="${4:-}"
  local budget="${5:-$SMOKE_MAX_MS}"

  if [ "$HTTP_CODE" != "$expected" ]; then
    fail "$name" "expected HTTP $expected, got $HTTP_CODE ($(head -c 200 "$BODY" 2>/dev/null | tr '\n' ' '))"
    return
  fi

  if [ "$TIME_MS" -gt "$budget" ]; then
    fail "$name" "latency ${TIME_MS}ms exceeds budget ${budget}ms"
    return
  fi

  if [ -n "$jqfilter" ]; then
    if ! jq -e "$jqfilter" "$BODY" >/dev/null 2>&1; then
      fail "$name" "body assertion failed (${jqdesc:-$jqfilter})"
      return
    fi
  fi

  pass "$name"
}

# --- STH priming ---------------------------------------------------------------

# Fetch the tenant's current STH so authed checks satisfy ValidateWitnessHeader.
# We send X-Loopctl-STH-Bootstrap: true with NO last-known header. On a reused
# key the one-time grace is already spent and we get a 412 that STILL carries
# x-loopctl-current-sth; on a first-ever use we get 200 with the same header.
# Either way we capture the value. If the header is absent (e.g. witness
# enforcement is off, or a superadmin/public context), we proceed header-less.
STH=""
prime_sth() {
  curl -sS -o /dev/null -D "$HDRS" \
    -H "Authorization: Bearer $KEY" \
    -H "X-Loopctl-STH-Bootstrap: true" \
    --max-time "$CURL_MAX_SECS" \
    "$BASE_URL/api/v1/knowledge/stats" >/dev/null 2>&1 || true
  # `|| true` on the whole substitution: under `set -euo pipefail` a header-absent
  # pipeline exits non-zero and would abort the script before any check runs. This
  # keeps the "proceed header-less" contract when witness enforcement is off.
  STH="$(grep -i '^x-loopctl-current-sth:' "$HDRS" 2>/dev/null | tail -1 \
    | sed 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*$//' | tr -d '\r' || true)"
}

prime_sth

# Authed header set (Bearer + the primed witness header when available).
AUTH_HDRS=(-H "Authorization: Bearer $KEY")
if [ -n "$STH" ]; then
  AUTH_HDRS+=(-H "X-Loopctl-Last-Known-STH: $STH")
fi

echo "loopctl post-deploy smoke — ${BASE_URL} (budget ${SMOKE_MAX_MS}ms; embed ${SMOKE_EMBED_MAX_MS}ms)"

# --- Health poll (resilient to a just-deployed release) ------------------------

# Retry /health with capped exponential backoff so a smoke run kicked the instant
# a deploy finishes waits for the new release to accept traffic before the real
# assertions. Backoff is capped at 3s (worst case < 30s) — the happy path returns
# on the first attempt.
wait_for_health() {
  local attempt=1 max=10 delay=1
  while [ "$attempt" -le "$max" ]; do
    http GET "$BASE_URL/health"
    if [ "$HTTP_CODE" = "200" ]; then
      return 0
    fi
    sleep "$delay"
    attempt=$((attempt + 1))
    if [ "$delay" -lt 3 ]; then
      delay=$((delay * 2))
    fi
  done
  return 1
}

# /health JSON shape (Loopctl.HealthCheck.Default):
#   { "status": "ok"|"degraded", "ready": true|false,
#     "checks": { "database": "ok", "oban": "ok", "scale_alerts": "ok", "oban_orphans": "ok" } }
# (#461 item 5 removed the "version" field — the running build is deliberately not
#  disclosed on this unauthenticated endpoint.)
# It returns 503 "degraded" if EITHER db OR the Oban :default queue check fails. A
# transient Oban blip with a healthy DB+KB is NOT a rollback signal, so we HARD
# require HTTP 200 + database=="ok" and treat Oban-only degradation as a WARN (pass).
if wait_for_health; then
  # Cold-start tolerance: this smoke runs the instant a deploy finishes, so the
  # FIRST /health hit pays cold BEAM + cold DB-pool cost (multi-second) that is NOT
  # a latency regression — every subsequent request on the warmed pool is sub-second.
  # Judge the BEST (min) latency across a few probes: one warm response proves the
  # endpoint can serve fast; a genuine slowdown makes every probe slow. wait_for_health
  # already did one hit (warming the pool); best_ms starts from it and improves.
  best_ms="$TIME_MS"
  for _ in 1 2; do
    http GET "$BASE_URL/health"
    if [ "$HTTP_CODE" = "200" ] && [ "$TIME_MS" -lt "$best_ms" ]; then
      best_ms="$TIME_MS"
    fi
  done
  db_ok="$(jq -r '.checks.database // "missing"' "$BODY" 2>/dev/null || echo missing)"
  status="$(jq -r '.status // "missing"' "$BODY" 2>/dev/null || echo missing)"

  if [ "$best_ms" -gt "$SMOKE_MAX_MS" ]; then
    fail "health" "warm latency ${best_ms}ms exceeds budget ${SMOKE_MAX_MS}ms (cold-start-tolerant best-of-3)"
  elif [ "$db_ok" != "ok" ]; then
    fail "health" "database check is '${db_ok}' (expected ok)"
  elif [ "$status" = "ok" ]; then
    pass "health"
  else
    # DB healthy but overall status degraded (e.g. Oban queue check) — warn, not fail.
    oban="$(jq -r '.checks.oban // "missing"' "$BODY" 2>/dev/null || echo missing)"
    warn "health" "status='${status}' with database=ok (oban='${oban}') — not a rollback trigger"
  fi
else
  fail "health" "/health never returned 200 after 10 attempts"
fi

# --- Readiness poll (US-32.4 config-guard) -------------------------------------
#
# GET /health/ready additionally folds in the scale-alerts config-guard (scale
# alerts enabled but no SCALE_ALERT_WEBHOOK_URL configured) — see
# Loopctl.HealthCheck.Default's moduledoc. /health liveness above deliberately
# EXCLUDES this so a benign config-only issue never depools an otherwise-healthy
# node from Fly's load-balancer check.
#
# This was DOWNGRADED to a non-blocking WARN (#363) because prod sat in a state the
# guard flags permanently: scale alerts enabled with no SCALE_ALERT_WEBHOOK_URL. A
# check that is red on every single deploy trains everyone to ignore it, which is worse
# than not having it.
#
# #376 removed that state instead of tolerating it — prod now sets
# SCALE_ALERTS_ENABLED=false (fly.toml) while no receiver exists, so /health/ready is
# genuinely 200 and this is a HARD GATE again. A miss here now means a real
# misconfiguration introduced by the deploy under test (alerting switched on without a
# URL, or a broken guard), which is exactly what US-32.4 was built to catch.
http GET "$BASE_URL/health/ready"
assert "readiness (scale-alerts config-guard, US-32.4)" 200 \
  '.ready == true' 'ready is true'

# --- KB retrieval crown jewels (authed, read-only) -----------------------------
#
# VISIBILITY INVARIANT the count/search thresholds rely on: LOOPCTL_SMOKE_KEY is
# an AGENT-role key in the tenant that OWNS the shared knowledge corpus. Corpus
# articles are `shared`-visibility (metadata.visibility defaults to "shared", which
# Visibility.scope_opts + Loopctl.Knowledge.maybe_filter_by_visibility make visible
# to agent callers), so a large `count` and non-empty search results are provably
# satisfied for THIS key. If the smoke key's tenant or the corpus visibility ever
# changes, `count > 1000` and the search floors below must be re-derived.

# Knowledge count — { "count": <int> }. Prod baseline is ~83k; assert > 1000 so a
# wiped/empty KB (a catastrophic regression) fails loudly.
http GET "$BASE_URL/api/v1/knowledge/count" "${AUTH_HDRS[@]}"
assert "knowledge count populated" 200 \
  '(.count | type) == "number" and .count > 1000' \
  'count is an integer > 1000'

# Knowledge search — { "data": [ ... ], "meta": {...} }. TWO checks, because
# combined mode silently falls back to keyword-only on an embedding-provider
# failure and STILL returns 200 + non-empty .data (flagging it only via
# meta.fallback) — a single combined check would stay green while semantic recall
# is 100% broken.
#
# (a) keyword floor: the deterministic DB/keyword path (no embedding call).
http GET "$BASE_URL/api/v1/knowledge/search?q=elixir&mode=keyword&limit=3" "${AUTH_HDRS[@]}"
assert "keyword retrieval floor" 200 \
  '(.data | type) == "array" and (.data | length) > 0' \
  '.data is a non-empty array'

# (b) semantic health: combined (default) mode, but REQUIRE meta.fallback != true.
# On success `fallback` is absent → null != true → passes; on embedding-provider
# failure it is true → FAILS (the point). Wider embed budget (does an LLM call).
http GET "$BASE_URL/api/v1/knowledge/search?q=elixir&limit=3" "${AUTH_HDRS[@]}"
assert "semantic retrieval healthy" 200 \
  '(.data | type) == "array" and (.data | length) > 0 and (.meta.fallback != true)' \
  '.data non-empty and meta.fallback != true' \
  "$SMOKE_EMBED_MAX_MS"

# Knowledge stats — { "total": <int>, "by_category": {...}, "by_status": {...} }.
http GET "$BASE_URL/api/v1/knowledge/stats" "${AUTH_HDRS[@]}"
assert "knowledge stats" 200 \
  '(.total | type) == "number"' \
  '.total is a number'

# --- Agent memory recall (authed, read-only) -----------------------------------

# POST /memory/recall is a READ (semantic search; no persistence — see
# memory_controller.ex). An empty result is a PASS: we assert the epic-28 endpoint
# is alive and shaped { "data": [...], "meta": {...} }, not that data exists. It
# generates a query embedding, so it gets the wider embed budget.
http POST "$BASE_URL/api/v1/memory/recall" \
  "${AUTH_HDRS[@]}" \
  -H "Content-Type: application/json" \
  --data '{"query":"smoke","limit":1}'
assert "memory recall alive" 200 \
  '(.data | type) == "array" and (.meta != null)' \
  '.data is an array with .meta' \
  "$SMOKE_EMBED_MAX_MS"

# --- Auth boundary negative check ----------------------------------------------

# No key at all → RequireAuth must 401 (it runs before the witness plug), proving
# the authentication boundary is intact on the freshly-deployed release.
http GET "$BASE_URL/api/v1/knowledge/search?q=x"
assert "auth boundary enforced (401 without key)" 401

# --- Summary -------------------------------------------------------------------

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "$OK all smoke checks passed"
  exit 0
else
  echo "$NO $FAILURES smoke check(s) failed"
  exit 1
fi
