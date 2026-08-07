# Changelog

All notable changes to loopctl are documented here.

## [Unreleased] — 2026-08-07 — Story lifecycle capability delivery

### Fixed

- **The story lifecycle is completable again for tenants with an audit signing key (#621).**
  Every tenant created through the current signup flow has one, and for those tenants the
  capability layer rejected start/report/verify because NO client-facing path ever handed the
  caller a capability token: the tokens were minted at each transition and discarded. The
  lifecycle has been unusable over the API since 2026-04-12; it went unnoticed because recent
  work flowed through pull requests rather than the story lifecycle, and because the test
  suite only exercised the keyless path, where capabilities are not enforced.
  **What changed for clients:** the `claim` response now carries a `capability` object whose
  `cap_id` must be presented as the `capability` field on `start`. That is the ONLY capability
  a client ever has to carry. A new `GET /api/v1/stories/:id/capabilities` returns the live
  tokens already issued to the caller for a story — the recovery path when the claim response
  is lost to a crash or timeout; it never mints. `loopctl-mcp-server` handles all of this
  automatically; upgrade it rather than plumbing tokens by hand. Claiming with a
  dispatch-minted key now also records `implementer_dispatch_id`, without which every
  downstream lineage check silently degraded to plain agent-id equality.

- **`report` and `verify` no longer require a capability token, and no `report_cap` or
  `verify_cap` is minted.** Neither could have worked. A capability binds to exactly one
  dispatch lineage, but both transitions exist precisely so that a DIFFERENT principal
  performs them: the `report_cap` authorized the one principal forbidden to report, and the
  `verify_cap` was bound to whichever dispatch loopctl selected as verifier — which may be an
  `:agent`-role dispatch that the `exact_role: :orchestrator` verify endpoint rejects, or
  nothing at all in a tenant whose dispatches share one root, and which a legacy env-var
  orchestrator key (lineage `[]`) can never hold. The bulk `verify-all` path never sent a cap
  at all and silently returned `verified_count: 0`. Both transitions are gated by structural
  lineage separation plus the `exact_role` plugs: `verify` now compares the CALLER's
  server-resolved dispatch lineage against the implementer's, exactly as `report` does, so an
  orchestrator key inside the implementer's own dispatch chain is refused with `409
  self_verify_blocked` even when its `agent_id` differs. That check runs on every path,
  including the common one where the optional `request-review` was never called; the
  loopctl-selected verifier is still recorded and compared in addition whenever it exists.
  See `docs/chain-of-custody-v2.md` §5.2.

- **An unusable capability no longer halts the whole tenant.** Any rejected token produced
  `{:cap_rejected, _}`, which custody-halts the tenant and 503s every subsequent request from
  it — so one agent letting a token pass its 1-hour TTL took down every other agent in the
  tenant. **No capability rejection halts a tenant any more** — not a forged signature, not a
  double-spent token (see the 2026-07-24 entry below, which supersedes an earlier draft of
  this line). Every one of them is an ordinary 403; expiry and lineage drift are additionally
  recorded in the audit chain as `capability_refused` (with the `cap_id`, api key and agent).
  Alert on the RATE of the `[:loopctl, :custody, :cap_rejected]` telemetry event — that is now
  the only signal for a forged or replayed token, and a single occurrence is not one.
  Relatedly, **rotating a tenant's audit signing key no longer invalidates outstanding
  capability tokens**: verification now also accepts the historical key whose
  `[rotated_in, rotated_out)` window covers the token's `issued_at`. Without that, a routine
  rotation made every live token `invalid_signature` — which IS byzantine, so a documented
  operator action custody-halted the tenant.

- **Capability refusals return their documented 403 instead of a 500.** The controllers had no
  clause for the capability layer's own error shapes, so a missing or rejected token raised a
  CaseClauseError — making a correct refusal indistinguishable from a crash in logs and alerts.
  A non-UUID `capability` value likewise 500'd (`Ecto.Query.CastError`) instead of 403ing.

- **A dispatch may now only be minted inside the caller's own lineage.** `POST
  /api/v1/dispatches` accepted a parentless request from any orchestrator-or-above key, and
  accepted any active dispatch in the tenant as `parent_dispatch_id`. Both let a caller place
  itself in a lineage unrelated to its own, which is the separation the L4 custody gates read
  as "an independent principal". Two new 403s: `root_dispatch_forbidden` when a key that was
  itself minted by a dispatch sends no `parent_dispatch_id` (only a key no dispatch minted —
  the tenant's operator key, rooted in the human anchor — may start a lineage tree), and
  `parent_outside_caller_lineage` when the named parent is not the caller's own dispatch or a
  descendant of it. "Operator key" is decided POSITIVELY — `role: :user` AND not minted by a
  dispatch — because an absent lineage also describes a legacy long-lived key. **What changed
  for clients:** a sub-agent that used to mint a fresh root must now pass its own dispatch id as
  `parent_dispatch_id` (the 403 body returns it as `remediation.your_dispatch_id`); a legacy
  `LOOPCTL_ORCH_KEY` can no longer mint a root at all — use the tenant's `user`-role operator
  key. **Operators must mint at least two roots**: verification is root-separated, so a tenant
  whose dispatches all descend from one root has no principal that can verify — selection
  reports `no_independent_root` and the verify gate answers `self_verify_blocked`. Both refusals
  are logged as `lineage_ceiling_refused` and emit
  `[:loopctl, :custody, :lineage_ceiling_refused]`.

- **Verifier selection is seeded from a server-side secret.** The rotating verifier's index was
  derived from the tenant's audit signing PUBLIC key, which `/.well-known/loopctl` serves
  unauthenticated, while the candidate pool is listable by any agent key — so the choice was
  reproducible by the parties it chooses between. It is now an HMAC keyed by the tenant's audit
  signing PRIVATE key, domain-separated and bound to the tenant and story. **Operator impact:**
  a tenant whose audit signing key is not provisioned (or an unreachable secret store) now has
  no seed and none is invented — selection fails closed, the story is flagged `verifier_needed`,
  and a `verifier_not_assigned` entry with reason `verifier_seed_unavailable` is written to the
  audit chain plus an `audit_chain_append_failed`-style error log and a
  `[:loopctl, :custody, :verifier_seed_unavailable]` telemetry counter — alert on it, since a
  secret-store outage fires it on every request-review deployment-wide. Verification itself is
  unaffected: the verify gate enforces lineage separation independently, and now refuses an
  unlineaged caller outright on a dispatch-minted story rather than falling back to agent-id
  inequality. Provision the tenant's audit key to restore automatic selection.

- **Backfill can no longer be used to certify work that ran inside loopctl.** `POST
  /stories/:id/backfill` (and the bulk `mark-complete`) refused stories carrying dispatch
  markers, but `force-unclaim` clears `assigned_agent_id`, and a story claimed with a key that
  no dispatch minted never records an implementer dispatch — so a worked story could be
  returned to a state indistinguishable from pre-loopctl work and then marked verified with no
  report, review record or independent verifier. Unclaim and force-unclaim now stamp a durable
  `metadata.lifecycle_entered_at` on the story, and both paths refuse a story carrying it — or
  a lifecycle entry in the audit log — with a new 422 (`story_entered_lifecycle`). The row stamp
  is the durable half deliberately: `audit_log` is partitioned and pruned at
  `AUDIT_RETENTION_DAYS` (default 90), so an audit-only guard would have reopened this path on a
  timer. Imported and never-dispatched work — the case backfill exists for — is unaffected.
  Backfill is additionally mounted on the LCP-1 signed-claim gate, so under the `signed` custody
  profile an enrolled caller must sign it exactly as for `verify`, and the verified claim is
  recorded in the hash-chained audit log (§9.4) as it is for `verify`.

- **The caller's dispatch lineage is now compared on every custody path, not just single-story
  verify.** `POST /epics/:id/verify-all`, `POST /stories/:id/reject` and the bulk verify/reject
  endpoints reached the same terminal states while comparing only story fields, so an
  orchestrator dispatched inside the implementer's own lineage cleared them where
  `POST /stories/:id/verify` returned `409 self_verify_blocked`. All four now resolve the
  caller's lineage server-side from the authenticating key. **What changed for clients:** calls
  that were previously accepted from inside the implementer's lineage now return
  `409 self_verify_blocked` (bulk: a per-story error entry) — use an independently-rooted
  verifier dispatch.

## [Unreleased] — 2026-07-24 — Self-hosting: fresh-install fixes, multilingual search, at-rest ingestion encryption

Operator-facing changes for deployments outside the hosted instance.

### Changed

- **A custody halt now requires a repeated pattern, and it no longer freezes the whole API.**
  Two behaviour changes an operator will notice.

  **When a halt fires.** Previously a SINGLE chain-of-custody refusal halted the tenant, and
  clearing a halt requires a human WebAuthn break-glass ceremony. A halt now requires
  **3 self-report / self-review / self-verify violations within 1 hour** (tunable with
  `config :loopctl, :custody_halt_threshold` and `:custody_halt_window_seconds`; a value that
  is not a positive integer is refused back to the default with a warning, since `0` would
  halt on the first violation and a string from an env var would halt nobody, ever); below the
  threshold the offending operation is refused exactly as before, with the same 409 — only the
  escalation changed. The `self_review_blocked` 409 body now carries `code` and
  `remediation.learn_more` like its two sibling gates, so all three are machine-dispatchable. Capability-token rejections no longer contribute to a halt at all: a
  capability is single-use with a bounded TTL, so a plain client retry, a resumed agent or an
  audit-key rotation all produce one, and none of those is evidence of anything. They are now
  reported as `[:loopctl, :custody, :cap_rejected]` telemetry plus a warning log — **alert on
  the rate**, not on single events. Halts themselves emit `[:loopctl, :custody, :halt]`
  telemetry and a `custody_halted` **error** log carrying the tenant, the reason and the count,
  so a halt reaches your alerting immediately; each halt is also recorded in the hash-chained
  audit log. Violations are retained in a new `custody_violations` table (tenant-scoped, RLS)
  as the forensic record behind a halt. New migrations, no manual steps.

  **What a halt blocks.** A halt used to 503 EVERY authenticated request for the tenant,
  including all reads. It now suspends only the custody surface: story-lifecycle writes,
  bulk story operations and epic verify-all, dispatch minting, and agent-memory writes.
  Reads are never blocked on any surface, and knowledge-wiki and coordination writes keep
  working — a halted tenant retains the audit log, change feed and KB access needed to
  investigate the halt. Root-of-trust rotation (`POST /tenants/me/custody-owner-key`,
  `POST /tenants/:id/rotate-audit-key`) also stays reachable, since it is a remediation path.
  The 503 body now carries `scope: "custody_operations_only"` so a client can tell a scoped
  halt from an outage. If you have monitoring that treats any 503 `tenant_halted` as
  "tenant is down", it will now see the halt only on custody calls.

- **`POST /tenants/me/custody-owner-key` is rate limited per tenant (#624).** Registering or
  rotating the custody owner key now shares the shape of the WebAuthn enrollment ceremony's
  limiter: an hourly per-tenant budget that **fails closed** — if the rate-limiter store is
  unavailable the request is refused with `429 rate_limited` rather than allowed through.
  Rotation was, and remains, additionally gated by proof of possession of the outgoing owner
  key; this is defence in depth for an expensive verification path.

- **Ingestion now mints self-qualifying article titles (#617).** The extractor was shown only
  a coarse `source_type` ("web_article"), never which document it was reading — so a CHANGELOG
  file could only be titled "Changelog". On the hosted corpus three unrelated documents (a
  WordPress SEO plugin, the Elixir oauth2 library, a WordPress theme) each produced exactly
  that, and the nightly consolidation pass then proposed them for auto-unpublish as "the same
  capture". The specific source is now passed to the extractor, and the prompt asks for a
  title that stands alone in a shared corpus — qualified by its source when the natural title
  is generic ("Changelog — Platinum SEO Pack WordPress plugin"), left alone when it is already
  specific. **What this sends:** for a URL ingest the scheme+host+path of the ingest URL is
  included in the extraction prompt POSTed to your configured LLM provider; userinfo and the
  query string are stripped first, so credentials and query-string signatures are not
  transmitted — the host and PATH are, so a share link that carries its token in a path
  segment (`/s/<token>/file.pdf`, `/document/d/<id>/edit`) still sends it. Name the source
  explicitly with `metadata.source_ref` (an inline `content` ingest has no other way to be
  named, and it OVERRIDES the URL-derived name, which matters when a URL's identity lives in
  its stripped query string); it is reduced exactly the same way. Without it the source line
  is omitted entirely, never sent as a placeholder. This affects NEWLY ingested content only; existing articles are untouched. It
  is the root cause behind the duplicate-capture class the previous entries bound and gate.

- **The consolidation drain caps AND the duplicate-similarity threshold are now live-tunable
  without a deploy (#617).** `knowledge_consolidation_max_applies`,
  `knowledge_consolidation_max_unpublishes`, `knowledge_consolidation_max_per_class` and
  `knowledge_consolidation_min_duplicate_similarity_pct` (an INTEGER percent — `80` means
  0.80 — which is the threshold a title collision's members must corroborate at in content
  before the nightly may unpublish one; only **1..99** is accepted, because `0` on this knob
  would satisfy the corroboration check for every pair rather than disabling it, and any
  other value falls back to the config layer) are read from `SystemConfig` DB rows first,
  falling back to the compile-time application config and then to the built-in default. The
  drain caps still read `0` as "halt", which this threshold deliberately does not. Setting
  `knowledge_consolidation_max_unpublishes` to **0** halts the auto-unpublish drain, and that
  halt now takes effect on the next nightly rather than on the next deploy — which is the
  whole point, since the caps are the only lever an operator has while an apply is going
  wrong. The existing config values keep working unchanged; nothing needs to be set.

- **An over-long input no longer permanently strands a row un-embedded (#617).** #615 added
  the byte budget and shrink ladder to the two article-embedding workers. The same rejection
  on the re-embed, system-corpus, agent-memory and novelty-gate paths still mapped to a
  permanent 4xx and DISCARDED the job — so a single over-long article could wedge a whole
  tenant re-embed mid-run (leaving recall pinned at the old dimension), and an over-long
  memory was permanently absent from semantic recall. All four now walk the same ladder,
  embedding a prefix rather than nothing. Array calls bisect first, so only the member that
  actually overflows is truncated. No configuration change; the effect is fewer rows silently
  missing from semantic search. A vector that covers only a prefix is MARKED where it is
  stored, and the three readers that compare vectors treat it accordingly: the novelty gate
  will not call a proposal a duplicate on one, the nightly will not corroborate a title
  collision on one, and agent-memory promotion will not retire a memory on one.

- **The nightly re-checks that a confirmed duplicate group still COLLIDES before unpublishing
  it (#617).** The apply path previously re-checked only that the group's members were still
  published. Retitling the articles is the remedy for a false grouping, and a retitled group
  passed that check — it was saved only because a fresh derivation happened to drop the group
  first. The grouping signal (normalized title, or normalized idempotency key, whichever
  formed the group) is now re-evaluated at apply time; a group that no longer collides as one
  whole — dissolved, split, or any live member dropped — is skipped and re-derived. The same
  holds when the group is SHRUNK rather than split: if a confirmed member was archived,
  deleted or made private, the survivors are a set no report ever confirmed and the pass
  skips them (its own part-drain, which leaves the member a shared draft, still converges). A
  duplicate group also carries at most 50 members onto one proposal. The remainder is
  re-derived on the next run and applies the run AFTER that: the survivors are a different id
  set, so their fingerprint has to appear in two consecutive reports before the agreement gate
  will confirm it. A very large group therefore drains 50 members every two nights.

- **The nightly consolidation drain rates are raised so the duplicate backlog converges to
  zero instead of to a floor (#611).** Three settings, all previously pinned to module
  defaults sized for a class that had never applied anything in production:
  `knowledge_consolidation_max_per_class` (100 → **500**, the existing hard ceiling),
  `knowledge_consolidation_max_applies` (**new**, default 500) and
  `knowledge_consolidation_max_unpublishes` (**new**, default 500).

  The per-class cap is the one that mattered. Auto-apply requires a proposal in **both** of
  the last two reports, so a standing backlog larger than the report cap could never drain
  however long the pass ran — the hosted corpus sat at 290 proposals with 100 visible, a
  queue converging to a floor rather than to zero. The two apply caps were additionally
  UNREACHABLE: `apply_confirmed_duplicates/2` accepted them as options and the worker passed
  none, so operator configuration had no effect and draining a backlog required calling the
  context directly.

  The bounds themselves stay — a bug that mis-picks winners must be visible after one night
  rather than after the whole corpus — and unpublish being reversible by publishing is what
  licenses a bound this size. Evidence for the new sizing: on 2026-08-06 (UTC) the class unpublished
  112 loser articles on the hosted corpus, and **all 112 were verified to still have a
  surviving published twin**, with zero private articles touched.

  Both apply caps are clamped to **0..500**: 500 is a hard ceiling, so raising a value above
  it has no effect, and a non-integer value is ignored in favour of the built-in default.
  Setting either to **0 pauses the auto-unpublish drain** — nothing is applied and the audit
  event records `duplicate_apply_gate=drain_disabled`, so a paused night is distinguishable
  from a clean one. That is the supported way to halt the drain during an incident. A
  duplicate group with more losers than the cap is now drained as far as the cap allows
  (the surviving winner is never touched) instead of being skipped whole, which had made any
  group larger than the cap permanently unappliable.

- **The nightly knowledge pass now PRUNES the `relates_to` graph to a bounded degree, which
  DELETES rows (#611 stage 0).** Read this before upgrading if you run a large corpus: on
  first run the pass will delete a large number of `article_links` rows, and it is the only
  step in that worker that deletes anything.

  Why: a similarity threshold was never a bound. Above `article_link_threshold` (0.6) the
  linking worker created a `relates_to` edge for *every* kNN candidate — up to
  `article_link_max_comparisons` (50) outbound per article, plus one inbound from every other
  article that reached it. On the hosted corpus that produced **1,402,699 edges over 79,276
  published articles**, with 56% of articles carrying 21+ and 59% of edges sitting between
  0.60 and 0.70. At that density a traversal from any article reaches most of the corpus in
  two hops, so the graph asserts a relationship between nearly everything and distinguishes
  nothing — which also means the one-hop enrichment in progressive disclosure was spending
  its budget on noise.

  What changes: `ArticleLinkingWorker` now writes `relates_to` edges only up to
  `article_max_relates_to_links` (**new setting, default 10**) minus the prunable edges an
  article already holds — a re-link tops it up to that number rather than adding that many
  more. That bounds what the worker writes for the article it is linking; edges other articles
  write INTO it are bounded by the prune below, not by this setting.
  `Loopctl.Knowledge.LinkPruning` drains
  the existing backlog at up to `knowledge_link_prune_max_per_run` (**new setting, default
  250,000**) edges per nightly run, worst-first, reporting the remainder on the
  `knowledge.lint_completed` audit event as `links_pruned` / `links_prunable_remaining`.
  On the hosted corpus the target state is 499,058 edges (~12.6 average degree).

  What is NOT touched: `potential_conflict` edges (own threshold, own draining consumer),
  any `relates_to` link without `auto_generated: true`, any link without a recorded
  `similarity_score`, and any `relates_to` edge at or above `knowledge_conflict_threshold`
  whose pair the conflict promoter has not flagged yet (those rows are the promoter's only
  input, and it drains them far slower than the prune would delete them; once a pair is
  flagged it is no longer promoter input and the edge is prunable like any other). A hand-made
  link is structurally out of reach, and an edge that cannot be ranked cannot be shown to be
  prunable.

  Why deleting is safe unattended, when every other automated step in that worker is gated on
  reversibility: an auto-generated edge is a *derived artifact*, not a record — a pure
  function of two embeddings and a threshold, which the linking worker recomputes from the
  same vectors. Pruning uses **union-kNN** (an edge survives if it is in *either* endpoint's
  top-K), which guarantees every article keeps its own K nearest and therefore **cannot create
  an orphan**. No migration, no manual step; the pass is idempotent and converges.

### Added

- **`GET /api/v1/knowledge/consolidation` — the nightly consolidation ("dream") report
  (#584, #605, #606, #608).** The existing nightly knowledge pass (04:00 UTC,
  `KnowledgeLintWorker`) now also reconciles the tenant's published corpus and emits numbered
  proposals, each naming the articles involved and quoting an excerpt from each as evidence:
  duplicate captures from title/idempotency-tag format drift, and placeholder titles.
  **Operators should know the pass now writes to `articles`, in exactly one way:** it
  UNPUBLISHES the losers of each duplicate group that two consecutive nightly reports both
  propose (bounded at 25 groups per run, winner recomputed at apply time against the live
  corpus). It is an unpublish and never an archive — `archived` is terminal for an article,
  so an unattended pass may not take that one-way door, while unpublish is undone by
  publishing. Nothing else is written: no `article_links`, no `conflict_resolutions`. There
  is no approve/reject surface and there will not be one; `review_status` persists but
  decides nothing. Two proposal classes were retired before ever reaching a release:
  `contradiction_candidate` (the same nightly run's lint judges those pairs itself, so
  consolidation was reporting a pile another writer already drains) and `stale_entry` (age is
  not a defect signal — use `GET /api/v1/knowledge/lint`, which computes staleness with a
  caller-chosen `stale_days`). Both values still load from stored rows and are still accepted
  by the `class` filter. Deliberately NOT a second scheduler: it runs inside the existing
  nightly job, so there is still one pass per tenant over the corpus. Migration
  `20260805140000_create_consolidation_reports.exs` adds `consolidation_reports` and
  `consolidation_proposals` (both RLS-enabled, tenant-scoped, cascading on tenant delete); no
  manual step. Note for operators: proposal rows persist a 240-character excerpt of each
  cited article body alongside the article ids, so the report inherits the sensitivity of the
  articles it cites — it is tenant-scoped and orchestrator-gated like every other knowledge
  read. That inheritance does NOT outlive the article: evidence is re-checked against the live
  corpus on every read, and an entry whose article has since been hard-deleted or
  archived comes back redacted (title null, empty excerpt, `redacted: true`),
  including in prior-day reports read via `?day=`. A draft is still live — the pass's own
  unpublish must not blank the evidence for the action it took. The response `meta` carries NO `applied`
  flag: a report records what was PROPOSED, and the apply tally rides the worker's
  `knowledge.lint_completed` audit event as `consolidation.duplicates_unpublished` /
  `consolidation.duplicate_groups_skipped` / `consolidation.duplicates_unpublish_failed`
  (plus `consolidation.apply_error` when the apply could not run at all) — the failure keys
  are what separate a night where every write was rejected from a night with nothing to apply. Per-class proposal cap is configurable via `:knowledge_consolidation_max_per_class`
  (default 100, hard max 500); over-cap is logged with the true total, never silently dropped.

### Changed

- **BREAKING (tags): the `idem-` tag prefix is now RESERVED for per-source idempotency keys
  (#583).** A tag starting with `idem-` must be `idem-<family>-<digest>` where `<digest>` is a
  12- or 40-character lowercase hex digest (e.g. `idem-url-7ebe1ca33431`); both digest lengths
  are accepted because the harvest sourcers' suffix used to be a full sha1 and is now
  truncated. Anything else claiming the prefix — `idem-design`, `idem-url-notahex` — is now
  rejected `422` on `POST /api/v1/articles` and `PATCH /api/v1/articles/:id`, and by the
  changeset underneath every other writer, so nothing is ever silently re-prefixed and a
  caller always knows what was stored. **The MACHINE paths drop the tag instead of failing**, on
  purpose: OKF import drops a foreign tag that sanitizes into the reserved namespace (the
  original string is preserved under `metadata["okf"]["tags"]`, and a well-formed reserved tag
  that arrives unchanged — every loopctl-native bundle — round-trips intact), the review worker
  and the content-ingestion worker strip a malformed reserved tag out of extractor output before
  insert (all of a review's extracted articles share one transaction, and an ingested article
  whose changeset is invalid is dropped whole, body included), and memory graduation filters one
  out of a memory's tags so a hot memory can never burn its one-shot graduation on an article
  that fails to insert. Script against a `422` only on the two
  API endpoints. Topical tags outside the prefix are unaffected, and the bare pre-reservation
  form (`url-<hex>`) is still accepted so existing sourcers keep working. For
  server-guaranteed idempotency prefer the `idempotency_key` field, which has a per-tenant
  unique index — a tag is caller-controlled data.
- **Manual step (optional, operator-run): `mix loopctl.reserve_idempotency_tags` (#583).**
  Promotes pre-reservation `<family>-<digest>` tags to their reserved counterpart across the
  corpus. Dry-run by default; `--apply` writes, `--tenant <uuid>` restricts scope. The first
  pass ADDS `idem-url-<hex>` alongside the existing `url-<hex>` so current dedup reads keep
  working; run it again with `--drop-legacy` to remove the bare form only after every client
  has switched to the reserved tag. Re-running is a no-op — a tag is never double-prefixed.
  Promotion requires BOTH halves of the shape: a known source family (`url`, `doc`, `book`,
  `yt`, `repo`, `img`, `file`, `vid`, `web`) AND a 12- or 40-char lowercase hex digest. So
  `url-design` is left alone (no digest), and so is `commit-<sha>` or `release-202604150930`
  (not a source family) — an unknown family is never promoted, because promoting it would
  fabricate a capture identity and `--drop-legacy` would then delete the original tag. An
  unrecognised switch aborts the run rather than being ignored.
- **`GET /api/v1/knowledge/analytics/retrieval-metrics` gained four fields and a stated
  denominator (#582).** `precision` and its `searched` denominator are UNCHANGED — `searched`
  has always counted RECORDED SURFACED RESULTS (one `article_access_events` row per result a
  search put in front of an agent, capped at the first 20 results of each call), so
  `precision` has always been "the share of the recorded surfaced results that were opened",
  i.e. precision@20: a call returning more results contributes only 20 to `searched`, and an
  open of a result ranked beyond the cap appears in neither term. What changed is that the
  payload now says so and reports the per-CALL quantity separately, because the field name
  reads like a count of searches and was consumed that way. New fields: `results_recorded`
  (same number as `searched`, named for its unit), `searches`, `searches_with_follow_through`,
  `search_follow_through` (the share of QUERY-BEARING search CALLS that led to an open), and
  `results_returned` (the true un-truncated result count for those same calls, so it exceeds
  the rows those calls wrote whenever a page hit that cap). The four call-level fields are filtered per ROW, not per day: a row counts
  only if it carries a search identity (nothing recorded before this release does) and is not
  a query-less enumeration page (`list` / `list_keyset`, written by the browse endpoints —
  browsing is not searching). So a day that MIXES qualifying and non-qualifying rows reports a
  PARTIAL figure rather than `0`, and `results_returned` must NOT be compared against
  `searched`: they aggregate different row populations. Migration
  `20260805130000_add_call_level_columns_to_retrieval_metric_snapshots.exs` adds the four
  backing columns with `default 0`; no manual step, and no backfill is possible — snapshots
  recorded before this release read `0` because their source events carry no search identity.
  Both ratios are UPPER BOUNDS: zero-result and keyless searches cannot be recorded and sit in
  no denominator; and both rise if a search simply returns fewer results, so pair them with
  the absolute `followed_through` rather than optimising either alone. `search_follow_through`
  carries two further biases pointing OPPOSITE ways: the 20-row recording cap hides opens of
  results ranked beyond it (biases it DOWN on large pages), while one open credits EVERY
  search in the window that surfaced that article, not just the preceding one (biases it UP
  when an agent refines and re-searches).

- **The legacy `articles_embedding_hnsw_idx` is retired on installs whose reads are cut over
  to the embedding side table, and reverting `embedding_side_table_reads` to `0` there is now
  an UNINDEXED read path (#578).** Measured on the hosted instance 2026-08-04
  (`pg_stat_user_indexes` / `pg_stat_statements`): the legacy index held 657 MB for 26 scans
  while the live `article_embeddings_hnsw_dim_1536_idx` held 658 MB for 1,695 — and with
  `shared_buffers` at 1536 MB the two evicted each other, so a cold vector search took
  8,044 ms of which 7,926 ms (98.5%) was `blk_read_time` against 0 ms warm. Dropping the
  legacy index frees roughly that 657 MB and leaves the live index resident.
  `migrations/20260805120000_drop_legacy_articles_embedding_hnsw_index.exs` performs the drop
  **only when `system_configs.embedding_side_table_reads` is `1`**; the flag defaults to `0`
  (= the legacy `articles.embedding` column) and no migration seeds it, so a fresh install and
  any install that has not cut over KEEP the index and are unaffected. **On a cut-over
  install** you may run `DROP INDEX CONCURRENTLY articles_embedding_hnsw_idx` out-of-band
  ahead of the deploy if you want the space back without waiting on the migrator — `IF EXISTS`
  makes the migration a no-op afterwards. Do NOT run that by hand on an install that has not
  cut over: it destroys the index serving your live read path, and the migration only ever
  drops, so it cannot give it back. **Operator consequence:** on an install where the drop has
  run, setting the flag back to `0` puts every semantic read on an unindexed column (seq scan +
  top-N sort). That trips the heavy-read `statement_timeout`, and the cancel surfaces as a hard
  `504`/`db_statement_timeout` — NOT `503`/`heavy_read_overloaded`, which only the per-tenant
  concurrency shed produces, and NOT the labelled keyword fall-back, which matches that shed
  alone. There is no graceful degrade on this path today: semantic search returns no results.
  Rebuild the index FIRST with an explicit
  `CREATE INDEX CONCURRENTLY articles_embedding_hnsw_idx ON articles USING hnsw (embedding vector_cosine_ops)`
  plus the same `WITH (m, ef_construction)` the migration builds with, and raise
  `maintenance_work_mem` well above the 64 MB default or the ~657 MB HNSW build silently falls
  back to the slow on-disk path.
  `mix loopctl.embeddings revert` now REFUSES while that index is absent (detected by
  capability, not by name) and prints the rebuild above; `mix loopctl.embeddings revert
  --force` overrides the refusal, and `mix loopctl.embeddings status` reports the index as
  `legacy articles.embedding HNSW index:`. **That refusal only protects installs that run
  from source** — a release ships no `mix`, so if you revert with `bin/loopctl eval` or a
  `psql` UPDATE, nothing checks the index for you and the rebuild-first ordering below is
  the only guard. The retirement procedure — the out-of-band drop,
  the baseline above as a fixed point, and the `pg_stat_statements` query that takes the
  matching AFTER reading — is `docs/runbooks/embedding-dimension-cutover.md` (Retiring the
  legacy articles ANN index); the revert procedure is the Reverting section of the same file. A rollback rebuilds it too —
  `bin/loopctl eval "Loopctl.Release.rollback(20260805120000)"` (there is no `mix` in a
  release) — but Ecto's `:to` is INCLUSIVE, so that reverts every migration at or after that
  version; once anything newer has shipped, use the explicit `CREATE INDEX`. If you do roll
  back, flip `embedding_side_table_reads` to `0` BEFORE the next
  `bin/loopctl eval "Loopctl.Release.migrate()"`: the rollback makes the migration PENDING
  again, and a deploy in that gap re-runs it and re-drops the index you just rebuilt. The
  `articles.embedding` **column is unchanged**: still dual-written, still the
  backfill/reconciliation source. `memories` keeps both of its legacy-column indexes
  (deliberate — one serves `include_superseded: true` recall, the other default live recall).
  No new environment variables.

- **`loopctl.oban.poll.error.count` label values changed — re-point any Prometheus selector
  or Grafana panel (#558).** The `error_class` label moved from a bare `exit` / `throw` to the
  kind-prefixed, closed set produced by `Loopctl.ExitClass` — `exit:noproc`, `exit:timeout`,
  `exit:Postgrex.Error`, `throw:other`, and so on. A selector matching the old bare values
  **silently stops firing** rather than erroring, which is the worst failure mode an alert
  has. The same vocabulary is now shared by the ingestion backlog-gate and vector-search
  under-fill counters, so one query shape works across all three.

- **`loopctl.ingestion.backlog_gate.failed_open.*` gained an `:outcome` label, and a `jobs`
  sum alongside the counter.** The event now fires on refusals as well as admissions, so a
  dashboard reading the counter alone over-reports admissions during exactly the sustained
  incident it is alerted on; slice by `outcome` (`admitted` / `unmetered` / `exhausted`). The
  `jobs` series is job-denominated — one 50-item batch is one check but fifty jobs.

- **A DB pool fault that arrives as an EXIT now renders the pinned 503/504 instead of a bare
  500, and counts in `loopctl.db.error.count`.** Crash propagation from a pooled process is an
  exit, not a raise, so it previously escaped the endpoint backstop untranslated: no
  structured SQLSTATE line, no counter increment (the aggregate under-counted DB faults during
  exactly the pool wedge it is read in), and the raw reason — the failing statement plus the
  call's bound parameters — reached the web-server crash log. Exits the backstop cannot place
  in the pool are still re-exited untouched.

- **The ingestion fail-open allowance is metered on the node-local limiter even under
  `RATE_LIMITER=postgres`.** The Postgres limiter store is `AdminRepo` — the same pool whose
  exhaustion makes the backlog unmeasurable — so the allowance was unconsultable for exactly
  the fault it bounds and admission stayed unbounded during a sustained wedge. Every other
  limiter bucket still follows `RATE_LIMITER`.

- **`POST /knowledge/ingest[/batch]` can now answer `503 ingestion_gate_unavailable` where it
  previously answered `429 ingestion_backlog_exceeded`.** Only for the refusals that are NOT
  backlog pressure: the gate could not MEASURE the backlog because of a driver/config fault or
  a defect in the counting code, and the bounded allowance for admitting unmeasured work is
  spent. The 429 asserted a backlog nobody counted and advised waiting for a drain that a
  deterministic fault never reaches. `Retry-After` is set on both; a client branching on
  `error.code` needs no change, one branching on the status does.

- **Tightening `OBAN_INGEST_BACKLOG_MAX` now tightens the ingest fail-open allowance with it
  (#564).** That allowance — how many jobs a tenant may have admitted while the gate cannot
  MEASURE its backlog — is `max(1, OBAN_INGEST_BACKLOG_MAX / 10)` per web node, sized so a
  10-node fleet stays at or under one threshold per hour. A floor at one full batch (50)
  previously took over for any threshold below 500, so lowering the knob to e.g. `100` left
  the allowance pinned at 50/node — a fleet admitting 500/hour against a threshold of 100,
  silently, and in the direction an operator assumes is the safer one. Effect at the default
  of 500 is unchanged. Below a threshold of 10 the allowance floors at 1 rather than 0, so a
  transient blip cannot refuse EVERY request — but a request asking for more items than one
  window's allowance still cannot fit it, and is refused after a single token rather than
  burning the remainder on jobs it will not enqueue. `OBAN_INGEST_BACKLOG_MAX` and
  `OBAN_INGEST_BACKLOG_RETRY_AFTER` are now documented in `deploy/FLY_SECRETS.md`, where
  they should have been all along.

- **`POST /knowledge/ingest[/batch]` can answer `503 ingestion_gate_unavailable` for a
  `db_error` too (#564).** It was the last unmeasurable-count class still admitting
  UNCONDITIONALLY — on the reasoning that a broken count query is our defect, not the
  tenant's backlog. That is a correct argument about the error CODE (and is kept: the refusal
  is the 503, never a backlog 429) but it left the class unbounded, and a deterministic
  query-shape fault recurs on every request — so the backpressure valve was simply OFF for as
  long as the bug existed. Every class is now metered. Operator-visible as ingest requests
  that previously succeeded during a counting-code fault now being refused once the hourly
  allowance is spent; the `loopctl.ingestion.backlog_gate.failed_open.*` series with
  `error_class="db_error"` is the signal to fix the query.

- **Which ingest fail-open refusals carry `429` vs `503` changed again, and the `Retry-After`
  on them is now window-scaled but capped (#565, #566).** `429 ingestion_backlog_exceeded` is
  now reserved for a fault that is demonstrable pool pressure: the SQLSTATE/exception classes
  `connection`, `timeout`, `db_pressure`, `guc_capture_abort`, plus any EXIT the driver's own
  pool raised. Pool-ness of an exit is decided from the raw exit reason
  (`ExitClass.pool_exit?/1`), not from its metric label, so a foreign `{:timeout, {GenServer,
  :call, _}}` escaping the counter takes the `503 ingestion_gate_unavailable` while a
  `{:noproc, {DBConnection, :execute, []}}` keeps the 429 — the label alone cannot tell them
  apart. A `throw:*` and every exit the gate cannot place at the pool answer the 503, like
  `db_error` and `driver_fault` already did, because none of them is evidence that the refused
  tenant has a backlog. In the other direction, the CONTENTION SQLSTATEs (40001, 40P01
  deadlock_detected, 55P03 lock_not_available) now classify as `db_pressure` rather than
  `db_error`, so heavy `oban_jobs` churn reads as load on the dashboard instead of as a defect
  in the counting query; the rest of classes 40 and 55 (55P02 cant_change_runtime_param and
  friends) stay `db_error`, since a deterministic config fault never drains. The `Retry-After`
  on an allowance-exhausted refusal now advises the time left in the hourly allowance window
  instead of `OBAN_INGEST_BACKLOG_RETRY_AFTER` (~60s) — which had a compliant client re-running
  the backlog count ~60 times per window against the pool the gate is protecting — capped at 5x
  that variable so a cleared blip cannot stall a client for a whole window. The fail-open
  allowance is also now metered in two per-tenant lanes (pressure vs non-pressure), so a
  counting-code defect can no longer spend the tokens a genuine pool fault is then refused on.
  The lanes SPLIT one threshold's worth rather than each getting one — the per-lane allowance
  is `max(1, OBAN_INGEST_BACKLOG_MAX / 20)` per web node (10 nodes x 2 lanes), so the total a
  tenant can have admitted while unmeasured stays at one `OBAN_INGEST_BACKLOG_MAX` per hour and
  there is **no multiplier to apply on top**. At the default of 500 the per-lane allowance is
  25/node.

- **New `article_access_events.access_type` value: `drill` (#569).** `GET
  /api/v1/knowledge/progressive/:id` records `drill` instead of `get`, at EVERY scope — the
  canonical carve-out this entry originally described was reversed by #572 below before
  release, so no drill records `get`. No request
  parameter is involved — the server derives it from the read path, so every client is
  covered. Operator-visible in
  two places. **Analytics filters on `access_type=get` will stop seeing those reads** —
  `GET /api/v1/knowledge/analytics/*` and anything grouping by access type must add `drill` to
  keep the same population. And the value set that column can hold has grown, though there is
  no DB CHECK to migrate: the allowlists are `ArticleAccessEvent.@access_types` and
  `Analytics.@valid_access_types`.

  Why: `heat_index` ranks on `get`, and the drill tool its own `meta.drill` payload tells
  callers to use recorded a `get` — so an article gained heat from having been *shown* by the
  index. Visibility produced reads, reads produced rank, rank produced visibility, and
  material that never surfaced could not overtake material that already had. #572 gave the
  canon a `knowledge_get` read path instead of exempting its drill, so no scope is exempt.
  Retrieval
  follow-through (`RetrievalMetrics`) deliberately DOES count `drill`, so precision figures
  are unaffected by the split.

  Nothing is back-filled: reads taken before this deploy are `get` rows and keep feeding heat
  until they age out of the window (90 days by default, up to 365 with `since`), so heat
  rankings stay partly loop-contaminated for one window after the upgrade.

- **`GET /api/v1/knowledge/heat_index` ranks by DISTINCT READERS, not by read count (#567).**
  Heat was `count(*)` over access-event rows, so any agent could pin its own article at rank 1 by
  calling `knowledge_get` on it in a loop — and because this index is meant to be pasted into a
  cached prefix, that ranking then propagated into every other agent's context. A signal the
  ranked party controls is not a signal. A reader is `coalesce(agent_id, api_key_id)` of the key
  that read — NOT the key row, since v2 mints a fresh ephemeral key per dispatch and counting
  keys would count dispatches — so one agent now contributes at most 1 however many times, and
  from however many dispatches, it reads; ties break on distinct read DAYS before the article id
  does, never on raw read count — that counter is the one a loop inflates.
  Existing `heat` values will DROP (they become readership size, not traffic) and the
  ordering will change wherever traffic and readership disagreed. Two further contract fixes on
  the same route: `meta.heat_window`'s system-derived bounds sit at the start of today
  (an explicit `since` is served verbatim, per #572 below), so two calls with no intervening
  read return a byte-identical payload (it previously carried a microsecond timestamp, making the
  "cacheable prefix" a guaranteed cache miss); and a FUTURE `since` is clamped to now instead of
  returning 200 with an empty list and a window that has not happened yet. `meta.chars` is now
  measured off the ENCODED stub, so escape-heavy titles no longer under-report the wire size a
  caller budgets against. No migration and no index change: the route's published-id subquery
  was suspected of scanning the corpus, and `EXPLAIN (ANALYZE, BUFFERS)` on production
  disproved it — the planner drives from the windowed event index and probes `articles_pkey`
  per distinct article read, 11 ms against a 79,025-article corpus.

### Added

- **`knowledge_get` now resolves published SYSTEM CANONICALS, and drilling never adds heat at
  any scope (#572).** #569 stopped `knowledge_heat_index` ranking on its own drill hop, but for
  tenant-owned articles only: a canonical's drill stayed counted, because `get_article/3`
  filtered on `tenant_id` and the drill was therefore the sole path to its body. That left the
  index ranking a counted class against an uncounted one on one `heat` number, and since
  drilling is the path the payload itself recommends, following the documentation drove the
  ranking monotonically toward the shared canon. Fixed by giving the canon the read path it
  lacked rather than counting the one it had. **Operator-visible effects:** a canon stub is now
  openable with `knowledge_get` instead of 404ing, and **no backfill runs** — measured on the
  hosted deployment before deciding, not assumed: across 56,033 access events and 23 published
  canonicals there are ZERO `get` (and zero `drill`) rows against a system-scoped article, so
  the migration would have had an empty subject. Before this change the DRILL was the only path
  that could emit a `get` for a canonical, which makes any such row you DO find on your own
  deployment drill-origin and safe to relabel; the rolling window (90 days by default) ages the
  rest out.

- **`meta.chars` / `meta.char_budget` on `heat_index` are BYTES of the encoded stub array**,
  array framing included. They were graphemes summed per stub, so a CJK or emoji payload was
  under-reported several-fold and the brackets and commas were omitted — both in the unsafe
  direction for the one number callers are told to size a cached prefix against. A client that
  sized a buffer off the old figure should re-check it.

- **An explicit `since` on `heat_index` is served verbatim**, where it was rounded up to the
  next UTC day boundary and silently dropped up to 24h of requested reads. The system-derived
  default is still day-snapped, which is what keeps the payload byte-identical between
  refreshes.

- **A heat-projection fault no longer logs raw DB fault text, and only a demonstrable pool exit
  degrades to 429.** The log carried the backend host/port and the failing statement's bound
  parameters; the blanket exit handler reported a node shutdown or any foreign timeout as
  "this tenant is reading too much". Saturation now fails soft as the documented 429 — a pool
  checkout that waited past its deadline, plus the server-side statement timeout (`57014`),
  an exhausted backend (`53xxx`) and one going away or refusing the connection (`57P0x`,
  `08xxx`, including the `08P01` pgbouncer rejects with). Everything else surfaces as what it
  is: a deterministic query fault as a 500, an unreachable database as the 503
  `db_unavailable` every other route already returns. `GET /knowledge/heat_index` documents
  all three.

- **Operator knobs that were live but undiscoverable are now documented (#566):**
  `EXPECTED_APP_NODES`, `STH_SWEEP_CRON`, the fair-share snooze pair
  (`OBAN_TENANT_FAIRSHARE_SNOOZE_SECONDS` / `_JITTER`), the per-queue families
  `OBAN_QUEUE_<QUEUE>` and `OBAN_TENANT_FAIRSHARE_<QUEUE>`, `GITHUB_TOKEN`, and the Fly
  secrets-adapter pair `FLY_APP_NAME` / `FLY_API_TOKEN`. Nothing about their behaviour
  changed — they simply could not be found without reading our source. The two that most
  affect a self-hosted install: **`FLY_API_TOKEN` is not injected by anything**, and
  without it (or off Fly entirely) the default secrets adapter refuses every write, which
  fails tenant signup — use `SECRETS_ADAPTER=local_file`; and `GITHUB_TOKEN` left unset
  caps CI-status lookups at GitHub's 60/hour anonymous limit, past which story
  verification reports an API error rather than a CI verdict (set it, or leave it unset —
  a BLANK value 401s every lookup).

  `mix loopctl.check_env_docs` now scans `lib/**/*.ex` alongside `config/runtime.exs` and
  requires a documentation table ROW rather than any mention, so the next such knob cannot
  ship undiscoverable. A name the code BUILDS at runtime still cannot be resolved by a
  textual scan, so the guard now fails on an undeclared dynamic read instead of passing
  over it: those families are documented by hand.

- **A retirement trigger for the US-41.1 legacy embedding columns (#551).** New migration
  (`embedding_retirement_observations`, a global non-tenant table) and a new daily job at
  03:40 UTC. It records one observation per UTC day — the read flag, which legacy columns
  survive, and the cumulative `idx_scan` of every index over them — and once retirement is
  owed it logs at `error` every run and enqueues an operator alert
  (`embeddings.legacy_retirement_due`) through the existing `SCALE_ALERT_WEBHOOK_URL`
  channel, which stays a no-op when that is unset. A passed deadline that a revert in
  progress is BLOCKING alerts on the same channel under `embeddings.legacy_retirement_blocked`
  — it names a condition to resolve, not a column to drop.

  **It drops nothing.** Dropping `articles.embedding` / `memories.embedding` remains a
  deliberate, reviewed migration; this only decides when the system starts asking for one.
  Two triggers, both requiring the columns to still exist: 30 consecutive clear days
  (`embedding_side_table_reads = 1`, no movement on any legacy index), or the `review_by`
  date passing — `2027-01-22`, six months after the cutover. The deadline is what keeps
  the check honest: a probe that errors forever looks exactly like a probe that keeps
  finding nothing. Both values are `config :loopctl, :embedding_legacy_retirement` — no
  new environment variable, and moving the date out is a supported operator decision.

- **`GET /enroll` — a browser page that anchors an EXISTING tenant (#541).** The API
  advertised an `enrollment_upgrade` path out of `agent_rooted`, but nobody could walk it:
  `navigator.credentials.create()` needs a browser, and the only page running a WebAuthn
  ceremony was `/signup`, which creates a NEW tenant. Every tenant predating the signup
  ceremony was therefore permanently locked out of chain-of-custody, work-breakdown,
  dispatch, and token-budget writes. Paste a `user`-role API key, touch an authenticator,
  and the tier flips in place. The key is sent only as a bearer token from your browser to
  the same API you would curl — the page holds no server-side state and enforces nothing;
  every gate stays in `TenantAuthenticatorController`. `GET /api/v1/tenants/me` now names
  the page in `remediation.enrollment_upgrade.enrollment_page` (relative, since a
  self-hosted instance serves its own).

### Fixed

- **WebAuthn registration rejected hardware security keys.** Both browser hooks requested
  `attestation: "direct"` while the server built its challenge with Wax's default of
  `"none"`, so `Wax.register/3` refused any real attestation statement with
  `:invalid_attestation_conveyance_preference`. This was invisible on laptops — Touch ID
  and Windows Hello return `fmt: "none"` regardless — and broke exactly the roaming keys
  (YubiKey and similar) that the signup page recommends. Affects `/signup` as well as the
  new `/enroll`. No configuration change is needed; existing enrolled authenticators are
  unaffected.

- **`WEBAUTHN_RP_ID` / `WEBAUTHN_ORIGIN` / `WEBAUTHN_RP_NAME` — WebAuthn on a self-hosted
  domain (#511, contributed by @FinanceAlex; refs #494).** `config.exs` hardcoded the
  relying party to `loopctl.com`, and the WebAuthn spec requires `rp_id` to be a
  registrable domain suffix of the page's origin — so on any other domain the browser
  refused the enrollment ceremony. Since enrollment is the only way a tenant becomes
  `human_anchored`, a self-hosted deployment could never reach the chain-of-custody
  surface at all. `dev.exs`/`test.exs` already overrode this for localhost; only a prod
  release had no way to. Unset, the hosted deployment is byte-for-byte unchanged.
  Each var applies independently. `WEBAUTHN_ORIGIN` defaults to `https://$PHX_HOST` whenever
  `PHX_HOST` is set — the page host, not the `rp_id`, since `rp_id` may legally be a
  registrable parent domain of it — and must be set explicitly for localhost or a
  non-standard port, since WebAuthn runs only in a secure context (localhost being the one
  `http://` exception). A blank, non-host-shaped `WEBAUTHN_RP_ID` or a `WEBAUTHN_ORIGIN`
  that is not `scheme://host[:port]` is named in the boot log and ignored rather than
  applied; an `rp_id` that is not a registrable suffix of the origin is warned about too.
  Set `WEBAUTHN_RP_ID`
  before the first enrollment: credentials are bound to it, so changing it later
  invalidates every enrolled authenticator.
- **`SCALE_ALERTS_ENABLED` — off switch for a deployment with no alert receiver (#376).**
  Defaults to `true`, so an existing deployment is unchanged. The parse is deliberately
  opt-OUT and asymmetric with loopctl's other boolean env vars: only `false` or `0`
  disable (trimmed, case-insensitive), so a typo leaves alerting **on**, where its guard
  is still watching, rather than silently off. **Disabled stops the whole checker** — the
  supervised `ScaleAlerts` child is not started, so nothing is evaluated, logged *or*
  POSTed; the Prometheus series on `METRICS_PORT` are unaffected and remain the
  degradation signal. Enabling alerting is now a two-part change (`SCALE_ALERT_WEBHOOK_URL`
  **and** this flag) and `/health/ready` reports `checks.scale_alerts: "error"` for either
  half-done direction, naming the setting to fix. The hosted deployment ships this `false`
  via `fly.toml` until an operator webhook receiver exists.
- **`FTS_REGCONFIG` — per-deployment keyword-search language (#492).** Keyword FTS
  was hardwired to the `english` stemmer, so a non-English corpus silently degraded
  (Russian «отчёты» never matched «отчёт»). `Loopctl.Search.Regconfig` is now the
  single source of truth, set from `FTS_REGCONFIG` (default `english`, so the hosted
  instance is unchanged). **Set it before the first `migrate`** — the
  `apply_fts_regconfig` migration bakes the value into the stored `search_vector`s
  and is a no-op on the default. A well-formed but uninstalled config (e.g.
  `ukrainian`) fails the migration loudly rather than building an unusable index.
- **`SECRETS_ADAPTER=local_file` + `SECRETS_FILE` — signup off Fly (#496).** Tenant
  signup stores a per-tenant Ed25519 audit key via `Loopctl.Secrets`, which defaulted
  to the Fly secrets API — so signup was impossible on any other host. The local
  adapter writes `0600` with fsync and atomic tmp+rename under a write lock. Put
  `SECRETS_FILE` on a persistent volume and back it up with the database.
- **Browser signup mints a usable root API key (#500).** The HTML signup ceremony
  previously completed without issuing credentials, leaving a browser-onboarded
  tenant with no authenticated path forward. The key is surfaced exactly once, in
  LiveView memory only — never in a URL, session, or persisted record.

### Changed

- **`GET /api/v1/articles/:id` link payload trimmed, ranked and capped (#538) — BREAKING
  for anything reading `source_article` / `target_article`.** Each link object now carries
  only its FAR side, as `article: {id, title}`. The near side was a constant echo of the
  id already in the request URL, and — because only the far side is preloaded — its
  `title` was always `null`; it cost 14% of a typical response and carried nothing.
  Direction is unchanged and still given by which array the link is in. Links now also
  carry `similarity` when the auto-linker recorded one.
  Both arrays are **ranked** (open `potential_conflict` first, then descending similarity,
  then oldest-first for links with no recorded score — only the auto-linker records one,
  so a hand-created or imported corpus ranks entirely on that fallback) and **capped at 25
  per direction**, with new `links_total` and `links_truncated` fields
  reporting the true size. Use `knowledge_graph` to traverse the whole graph.
  A new `links` query parameter selects the detail level — `full` (default, so an
  untouched caller keeps working), `count` (`links_total` + `links_truncated`, so one
  cheap call answers whether the full fetch is capped), `none` (no link fields).
  An unrecognized value degrades to `full` rather than 422-ing a read.
  `potential_conflicts` is returned in **all three** modes, so a cheaper read never
  silently turns off conflict discovery; it is itself capped at 25 (highest similarity
  first) with `conflicts_total` / `conflicts_truncated`, so a conflict-heavy hub cannot
  make a cheap mode expensive.
  `GET /articles/:id` now also reads the `project_id` / `story_id` query params the MCP
  tool has always advertised, so article-access events are attributed instead of nil.
  As on every sibling knowledge read, a malformed `project_id` there returns **422**
  rather than silently discarding the attribution, and an empty one counts as absent.
  Why: agents are instructed to open every search hit with `knowledge_get`, so this
  response is paid on essentially every wiki read in every session. On a measured hub
  article the links were 12,564 of 16,189 bytes — about 4,000 tokens to read 735 tokens
  of body.
- **Ingestion document content is encrypted at rest (#493).** Raw `content` posted to
  `POST /api/v1/knowledge/ingest` was persisted as plaintext JSON in `oban_jobs.args`
  (including `retryable`/`discarded` rows) until pruning — the one at-rest exposure
  Epic 41 did not cover. It is now Cloak AES-256-GCM encrypted via
  `Loopctl.Ingestion.ContentEnvelope`. `url`, `source_type`, and `metadata` are **not**
  encrypted. Inline `content` is capped at 1,000,000 bytes (`422` over cap).
  `content_hash` changed from `sha256(plaintext)` to a per-tenant HMAC blind index —
  still an opaque deterministic string (dedup unaffected), but no longer an offline
  confirmation oracle for a DB-read attacker.
  **Operational:** when rotating `CLOAK_KEY`, keep the outgoing cipher in
  `retired_ciphers` until the `:ingestion` queue drains, or in-flight jobs discard.

### Fixed

- **Fresh installs no longer break in the Epic-41 migrations (#495).** The pgvector
  guard silently skipped embedding columns that a later migration then required. The
  migration now tolerates and heals the skipped state (idempotent, `IF NOT EXISTS`).
- **`/signup` rendered unstyled and non-functional on a fresh self-hosted install
  (#494)** — the browser pipeline was missing `put_root_layout`. Fixed at the
  `live_session` level so the `layout: false` marketing pages do not double-wrap.

> **Scope of this file.** loopctl's changelog records **operator-facing** changes
> only: environment variables, deploy ordering, migrations with manual steps,
> breaking or behaviour-changing API changes, and security-relevant changes to how
> data is stored. Refactors, test fixes, internal hardening, and dependency bumps
> are deliberately out of scope — `git log --first-parent` is the complete history.
> The trigger is narrow on purpose: a changelog that tries to record every merge
> is the kind that stops being written, which is what happened to the stretch of
> entries between this line and the one below it. See `CONTRIBUTING.md`.

## [Earlier] — 2026-07-16 — Agent-memory substrate: project scope, merged recall, graduation (#411)

### Added

- **Gap 1 — cheap repo → `project_id` resolution.**
  `Loopctl.Projects.resolve_project/2` (`GET /api/v1/projects/resolve`, MCP tool
  `resolve_project`) maps a `repo_url` / `slug` / `name` to a project in one call
  (precedence `slug > repo_url > name`; `repo_url` accepts SSH, HTTPS, and bare
  `owner/repo`). `404` `not_found`, `422` `no_identifier`, `409`
  `ambiguous_resolution` (a fuzzy identifier matched >1 active project).
- **Gap 2 — the `project_id` partition key + merged recall.** Long-term memories
  carry an optional `project_id` that PARTITIONS a subject's memories into a
  `global` (NULL) bucket and one per project — a partition key, NOT the isolation
  boundary (`(tenant_id, subject_id)` remains that, always key-derived). Write
  tenant-validates `project_id` (`422 invalid_project_id`); recall merges
  `global ∪ active-project` and treats an unowned id as an empty partition
  (global-only, no error). `Loopctl.Memory.recall_context/2`
  (`POST /api/v1/recall`, MCP tool `recall_context`) returns ONE re-ranked
  `global ∪ active-project` union of long-term MEMORY *and* KNOWLEDGE (combined
  search summaries), each result tagged `source: memory|knowledge`, plus the
  untouched per-source envelopes. A blank/over-500-char query is a `422` up front;
  a one-sided degrade returns the other side with `meta.degraded?: true` (never a
  500). Agent role is forced to published articles + own/`shared` memories (#163).
- **Gap 3 — recall-count graduation (HOT memory → durable knowledge).** Recall now
  bumps a `recall_count`/`last_recalled_at` hotness signal off the hot path
  (relevance floor `memory_recall_bump_min_score` = 0.6, cooldown
  `memory_recall_bump_cooldown_seconds` = 3600 s, fan-out cap
  `memory_recall_bump_max_tasks` = 200). The hourly
  `Loopctl.Workers.MemoryGraduationSweepWorker` graduates not-yet-graduated
  memories at/above `memory_graduation_recall_threshold` = 3 recalls into curated
  knowledge articles via the novelty gate (per-run budget
  `memory_graduation_max_per_run` = 50, scan fan-out
  `memory_graduation_scan_limit` = 500), stamping `graduated_at` on any durable
  verdict (a fell-open gate is not stamped — it re-graduates once embeddings
  recover).
- **Gap 3 surface — explicit, on-demand graduation.**
  `Loopctl.Memory.graduate_memory/3` is now reachable over HTTP + MCP:
  `POST /api/v1/memory/graduate` `{memory_id, re_scope?}` (MCP tool
  `memory_graduate`). Scope is key-derived (a foreign/unknown `memory_id` → `404`,
  no cross-subject oracle; malformed → `422 invalid_memory_id`). The novelty-gate
  verdict drives the status: `created`/`gated_to_draft` → `201` with a new
  article, `duplicate`/`deduplicated` → `200` (canonical article, nothing
  created). `re_scope: "global"` promotes a PROJECT memory to a tenant-wide
  article on its FIRST graduation only (`409 already_graduated` otherwise); a
  fell-open gate returns `503 gate_unavailable`. Allowlisted as an agent-reachable
  write in the default-deny custody classification (alongside `memory_promote` /
  `knowledge_create`).
- **Docs** — [`docs/agent-memory.md`](docs/agent-memory.md) extended with the
  project-scope partition model, `resolve_project`, merged `recall_context`, the
  recall-count graduation cadence, and `memory_graduate` + local→global re-scope;
  `mcp-server/README.md`, `AGENTS.md`, and both changelogs updated. The
  MCP server publishes these three new tools at `loopctl-mcp-server` **2.42.0**.

## [Unreleased] — 2026-07-11 — OKF-curated + RAG Hybrid Knowledge Retrieval (Epic 31)

### Added

- **Hybrid knowledge retrieval** — `Loopctl.Knowledge.hybrid_search/3`
  (`POST /api/v1/knowledge/hybrid_search`, MCP tool `knowledge_hybrid_search`)
  composes the already-shipped retrieval (`search_combined/3`) and curated-source
  identification (`list_curated_sources/2`, US-31.1) subsystems into a single
  resolution layer: `:curated` wins ONLY when a governed curated source's
  ABSOLUTE (never pool-relative, min-max-normalized) confidence score clears a
  scale-matched threshold AND beats the best retrieved candidate by a margin AND
  is authoritative (published, not superseded, not in an open
  `:potential_conflict`); otherwise `:retrieved`. Both branches return an
  identical `results`/`meta` key shape carrying `meta.provenance`
  (`:curated`/`:retrieved`), `meta.confidence`, and `meta.curated_article_id` — a
  caller branches on `meta.provenance` alone, never on which subsystem answered.
  See [`docs/knowledge-hybrid-retrieval.md`](docs/knowledge-hybrid-retrieval.md).
  - **Curated-source identification** (US-31.1) — a GOVERNED, non-self-assignable
    `articles.curated_at`/`curated_by` marker (excluded from `@cast_fields`),
    written only by `Knowledge.mark_curated/3` / `unmark_curated/3` (audited).
    Content edits (title/body/publish) invalidate the marker, forcing
    re-curation. `list_curated_sources/2` applies system-scope precedence (a
    tenant's own curated answer always wins over a `scope: :system` canonical on
    the same topic) and excludes superseded/conflicted articles.
  - **Progressive disclosure** (US-31.3) — `Knowledge.progressive_index/3` /
    `progressive_drill/3` (`GET /api/v1/knowledge/progressive_index` /
    `GET /api/v1/knowledge/progressive/:id`, MCP tools
    `knowledge_progressive_index` / `knowledge_progressive_drill`): a bounded,
    top-K-capped topic index of compact stubs (curated-preferred, one hop of
    `:relates_to` hub enrichment), then a full-body drill.
- **Docs** — new
  [`docs/knowledge-hybrid-retrieval.md`](docs/knowledge-hybrid-retrieval.md) (the
  resolution rule, provenance contract, progressive disclosure, and the
  three-layer model positioning hybrid retrieval within the Knowledge Wiki
  alongside Agent Memory and the Context Retriever); README/CLAUDE.md/AGENTS.md
  extended. **#305 and #306 describe the same feature** — recommend closing one
  as a duplicate rather than tracking separately; the "#305 reconcile
  `docs/cole-medin-self-evolving-wiki.md`" item is already satisfied by the
  epics 28–30 reconciliation (KB hub `fb9abd73`/`3ee5f890`).

### Verification

- **Terminal e2e + negative control** (US-31.5,
  `test/loopctl/knowledge/hybrid_e2e_test.exs`) — a governed curated
  refund-policy article suppresses an unrelated fuzzy chunk (`:curated`, hoisted
  first); archiving that curated article (removed from the published search
  pool, unrelated chunk unchanged) flips the result to `:retrieved` and surfaces
  the previously-suppressed chunk, proving causation; a niche non-curated topic
  falls to `:retrieved`; a near-but-wrong curated doc is never mislabeled
  `:curated`; `:curated`/`:retrieved` meta share an identical key shape. Tenant isolation is proven across the resolver, progressive index/drill,
  and the HTTP API; a system-scoped curated article participates without
  overriding a tenant's own; a superseded/conflicted curated article is never
  authoritative without the conflict surfaced.

## [Unreleased] — 2026-07-10 — Context Retriever (Epic 30)

### Added

- **Context Retriever** — a governed, auto-generated agent query surface over
  loopctl's own STRUCTURED records (`projects`/`stories`/`epics`), the third of
  loopctl's three agent information layers (Knowledge Wiki / Agent Memory /
  Context Retriever). See [`docs/context-retriever.md`](docs/context-retriever.md).
  - **Entity registry** (`Loopctl.ContextRetriever.Entity`/`Registry`, table
    `entity_definitions`) — a tenant admin declares a named **entity** (typed
    `fields` + a backing source) over `POST/PATCH/DELETE /api/v1/entities`. The
    definition IS the executor's field allowlist, bounded by a SERVER per-source
    column allowlist that excludes `tenant_id`/`metadata`/custody columns. Defining
    requires role ≥ `user` + a human-anchored tenant; per-tenant entity count and
    fields-per-entity are capped. Relationships/joins are out of scope for v1.
  - **Tool generator** (`ToolGenerator`) — emits per-entity `cr_filter_<entity>_by_<field>`
    tools (one per filterable field) and a `cr_search_<entity>` tool when a declared
    searchable TEXT field is covered by the source's `search_vector`; served at
    `GET /api/v1/retrieve/tools`.
  - **Executor** (`Executor.run/3`, the security boundary) — `POST /api/v1/retrieve/:entity`
    runs a filter/search parameterized (Ecto-pinned values / `websearch_to_tsquery`
    — never model SQL), dual tenant-scoped (RLS `loopctl_app` role + explicit
    predicate), execute-time allowlist-rechecked, shaped to declared columns only,
    audited fail-closed (`audit_log` `entity_type: "context_retrieval"`; no rows
    without a persisted audit trail), and per-tenant rate-limited (429 over-limit,
    unexecuted). Injection payloads match literally; pagination size + offset are
    capped.
- **MCP dynamic tool listing** — `mcp-server/lib/generated-tools.js` fetches the
  tenant's `cr_*` specs, appends them to ListTools (TTL-cached, negative-cached on
  outage, non-`cr_`/static-colliding specs dropped), and dispatches a `cr_*` call
  to `POST /api/v1/retrieve/:entity` under the same agent key as static reads.
- **Docs** — new [`docs/context-retriever.md`](docs/context-retriever.md) (the
  three-layer model, architecture, security model, surfaces); README/CLAUDE.md/AGENTS.md
  extended to a three-way `retrieve_*` vs `knowledge_*` vs `memory_*` decision
  guide. The #309 "reconcile `docs/cole-medin-self-evolving-wiki.md`" item was
  already satisfied (removed PR #310; content in KB hub `fb9abd73`); the epic folder
  is `epic_30`.

### Verification

- **Terminal e2e + security** (US-30.7) — `Loopctl.E2E.ContextRetrieverJourneyTest`
  (define → ListTools → filter + search via API and the MCP-derived body agree,
  tenant-scoped) and `Loopctl.E2E.ContextRetrieverSecurityTest` (injection in
  filter + search match literally; non-allowlist rejected on every surface;
  cross-tenant define/list/query isolation via context/API/MCP with a positive
  control; no undeclared-column leak; an audit record per execution; `/retrieve`
  429 over-limit) — both run under the non-owner app role. All Context Retriever
  endpoints render at `/swaggerui`.

## [Unreleased] — 2026-07-10 — Agent Memory auto-promotion (Epic 29, Part 2)

### Added

- **Memory promotion pipeline** — compiles a session's short-term turns into durable
  long-term `:promoted` memories without an explicit agent write. Triggered explicitly
  (`POST /api/v1/memory/promote {session_id}` → `Loopctl.Memory.promote_session/1`) or
  by the all-tenants cron `Loopctl.Workers.MemoryPromotionSweepWorker`; both enqueue the
  per-session `Loopctl.Workers.MemoryPromotionWorker` (unique per
  `(tenant_id, subject_id, session_id)`).
  - **Idempotency spine** — a `session_promotions` watermark (session content hash) skips
    an unchanged session WITHOUT an LLM call; re-running promotion adds no net rows
    (measured including superseded).
  - **Confidence gate + hash dedupe/supersede** — survivors above the confidence
    threshold are written with their `confidence`, embedded synchronously at write time,
    exact-deduped on `embedding_content_hash`, and near-dup superseded (source-scoped to
    `:promoted`, never clobbering an `:explicit` memory).
  - **Per-tenant budget** — a compiles/hour cap (atomic reservation incl. in-flight jobs)
    returns HTTP 429 with NO LLM call when exceeded.
  - **TTL-window invariant** — `sweep_interval < sweep_window < session_ttl`, sweep
    promotes oldest-active-first to bound the golden-nugget-loss window.
  - **Prompt-injection resistance** — session content is scope-enforced (the LLM never
    sees foreign turns) and `cross_links` are tenant + visibility validated, so a
    compromised model's foreign/fabricated article link is stripped before write.
- **MCP tool** — `memory_promote` (compile a session; caller's own sessions only; scope
  key-derived). The `/api/v1/memory/promote` endpoint renders at `/swaggerui`.
- **Promotion-quality eval (US-29.5)** — `Loopctl.Memory.PromotionEval` scores the
  compiler's precision/recall against a committed labeled dataset under a reserved,
  structurally-excluded eval subject; calibration only, never gates promotion.
- **Telemetry** — `[:loopctl, :memory_promotion, *]` events (`:swept` `:skipped`
  `:compiled` `:gated_out` `:promoted` `:superseded` `:degraded` `:quota_exceeded`
  `:budget_exceeded` `:failed` `:eval`) so a failing/budget-walled/degraded sweep is
  observable, not silent.
- **Docs** — [`docs/agent-memory.md`](docs/agent-memory.md) extended with the full
  promotion lifecycle, the watermark/budget/TTL invariants, the confidence + eval story,
  the prompt-injection stance, and the Claude Code Stop-hook recipe (cross-ref
  `mkreyman/claude-config#85`, not implemented here);
  [`docs/observability/promotion.md`](docs/observability/promotion.md) documents the
  pipeline metrics.

### Verified (US-29.6, terminal)

- **Promotion e2e** (`Loopctl.Memory.PromotionE2ETest`) — a session promoted via
  `POST /api/v1/memory/promote` is recall-able through BOTH the context and the API with
  `source: :promoted`, `source_session_id`, and `confidence`.
- **Idempotency + cross-scope** (`Loopctl.Memory.PromotionIsolationTest`) — re-promotion
  (explicit + sweep) adds no net rows counting superseded (watermark skip); a promoted
  `(tenant T, subject A)` memory is invisible to tenant U AND subject B via context, API
  (recall / index / forget), with MCP scope-blindness proven in
  `mcp-server/test/memory_tools.test.js`.
- **Unattended safety** (`Loopctl.Memory.PromotionSafetyTest`) — injection produces no
  cross-tenant-linked memory; an over-budget promote is 429 with no LLM call; a compile
  failure emits `:failed` telemetry.

## [Unreleased] — 2026-07-09 — Agent Memory (Epic 28, Part 1)

### Added

- **Agent memory subsystem** — a per-agent PRIVATE working memory, isolated per
  `(tenant_id, subject_id)` and kept strictly separate from the shared Knowledge
  Wiki. Two tiers:
  - **Session memory** (`session_memories`) — short-term, append-only, chronological
    turns/facts with a required `expires_at`, pruned by
    `Loopctl.Workers.SessionMemoryPruneWorker`. No embedding.
  - **Long-term memory** (`memories`) — durable facts embedded as `vector(1536)`
    (populated asynchronously by `Loopctl.Workers.MemoryEmbeddingWorker`) and
    recalled by HNSW cosine similarity, with a supersede/forget lifecycle and a
    per-`(tenant, subject)` live-row quota.
- **HTTP API** — `POST /api/v1/memory` (remember), `POST /api/v1/memory/recall`
  (semantic recall; degrades to a scoped text match, never a silent empty),
  `GET /api/v1/memory` (list; superadmin `?all_subjects=true` oversight), and
  `DELETE /api/v1/memory/:id` (forget). Scope is derived from the API key, never the
  body; the endpoints render at `/swaggerui`.
- **MCP tools** — `memory_remember`, `memory_recall`, `memory_list`, `memory_forget`
  (four tools; scope key-derived, no `tenant_id`/`subject_id` surface).
- **Docs** — [`docs/agent-memory.md`](docs/agent-memory.md): architecture, the two
  tiers + session TTL/pruning, the `subject_id` derivation + BYPASSRLS heavy-read
  structural guard, when to use memory vs knowledge (vs the future context
  retriever), the PII/secret (BYO-embedding) stance, and the auto-promotion (#308) /
  skills-consumer (`claude-config#85`) seams.

### Verified (US-28.5, terminal)

- End-to-end (write via API → recall via context AND API), cross-surface isolation
  (cross-tenant AND cross-subject invisible/immutable across context, API, and MCP,
  on both the semantic and fallback paths), and an `@tag :scale` recall gate proving
  a needle subject recalls its own top-k among an ~80k multi-subject corpus (the
  over-fetch pool + outer subject filter does not starve a subject at scale).

## [Unreleased] — 2026-07-03 — per-tenant BYO Anthropic LLM config + usage (Epic 28, #179)

### Added

- **Per-tenant BYO Anthropic config** — `GET` / `PATCH /api/v1/tenants/me/llm-config`
  (role `:user`): each tenant supplies its OWN Anthropic API key (encrypted at rest,
  never returned — only `has_api_key` + a last-4 hint) and picks a model per operation
  (`extraction_model` / `classification_model` / `merge_model`). loopctl fronts no LLM
  cost. Setting/rotating a key writes an audit event (without the value).
- **Per-tenant LLM usage tracking** — `GET /api/v1/knowledge/llm-usage`
  (role `:orchestrator`): token usage grouped by operation + model + source_type + day
  over an optional date range, with offset/limit pagination (default 90-day lookback).
  Record-only — no budget enforcement.

### Changed — BREAKING (mandatory BYO)

- **Tenant knowledge-LLM work now REQUIRES a per-tenant Anthropic key.** Content
  ingestion, category classification, article merge, and review-finding extraction all
  resolve the tenant's OWN key via `Loopctl.Llm.resolve/2` — there is **no**
  global-system-key fallback. The global `ANTHROPIC_API_KEY` / `:anthropic_provider`
  config path was removed.
- With no key configured, `POST /knowledge/ingest[/batch]` returns **422** with
  `code: "no_api_key"` and a remediation hint; the Oban workers `{:discard}` cleanly
  (no crash, no retry loop). A `[:loopctl, :llm, :blocked]` telemetry event and an
  `llm.blocked_no_api_key` audit entry are emitted when a tenant is blocked.
  (Single-tenant today; no grace period — the operator sets a key.)

## [Unreleased] — 2026-06-30 — docs sync + agents'-KB endpoints backfill

### Added

- **KB conflict resolution API** — `GET /api/v1/knowledge/conflicts` (list potential-conflict
  article pairs the auto-linker/nightly lint flagged as too-similar-to-coexist) and
  `POST /api/v1/knowledge/conflicts/resolve` (record a `dismiss`/`supersede`/`merge` verdict;
  the nightly executor acts on `supersede`/`merge` only at `confidence: high`, and `merge`
  LLM-synthesizes both sources into one new draft, never auto-published). Role: agent.
  MCP tools `knowledge_conflicts`, `knowledge_resolve_conflict` (MCP 2.26–2.28).
- **`GET /api/v1/knowledge/analytics/retrieval-metrics`** — daily retrieval-precision time
  series (share of search results the agent then opened). Role: orchestrator. MCP tool
  `knowledge_retrieval_metrics` (MCP 2.29).
- **`GET /api/v1/knowledge/curation-log`** — human-readable feed of KB curation adjustments
  (novelty-gate `gate_duplicate`/`gate_draft`; conflict `supersede`/`merge`/`dismiss`),
  recorded only while a tenant has `settings.kb_curation_log` enabled (default off).
  Role: orchestrator. MCP tool `knowledge_curation_log` (MCP 2.30).
- **Creativity primitives** — `POST /api/v1/knowledge/novelty`, distant-pairs, random-walk,
  and suggested-links endpoints (MCP `knowledge_novelty`, `knowledge_distant_pairs`,
  `knowledge_random_walk`, `knowledge_suggest_links`).
- **API root discovery links** — `GET /api/v1/` now also returns `discovery`, `routes`, `wiki`,
  and `mcp_server` pointers so agents hitting the root have a path to the MCP server and
  discovery documents instead of dead-ending.

### Docs

- Corrected the MCP tool count to **69** (was 57/65) across the README, `mcp-server/README.md`,
  the landing/docs pages, and `CLAUDE.md`, and documented the 4 previously-undocumented tools.
- Fixed drifted docs: UI-test endpoints are nested under `/projects/:project_id/ui-tests`
  (README); `verified_status` values are `unverified`/`verified`/`rejected` (not `pass`/`fail`),
  and `initial_verified_status` on import is honored only for a superadmin caller
  (orchestration guide); `knowledge_export` has no `obsidian` format and its download needs a
  user key (`mcp-server/README.md`); `GET /` serves the HTML landing page (it does not redirect).
- `GET /api/v1/routes` is now described as a curated index (not the exhaustive surface), points
  to the OpenAPI spec, and lists the CoC v2 dispatch routes, `recover-cap`, `acceptance_criteria`,
  and the new knowledge endpoints.
- Refreshed `model_name` examples (OpenAPI schema, MCP tool descriptions, PRD) to the current
  `claude-sonnet-5` id. `model_name` remains a free-form string and cost is caller-reported, so
  no code change is needed to record a new model.

## [Unreleased] — 2026-06-25 — heavy-read pgbouncer outage fix (US-27.13)

### Fixed

- **HeavyReadRepo pgbouncer `08P01` outage (US-27.13):** the dedicated heavy-read pool
  carried a `statement_timeout` connection STARTUP parameter (`parameters:` in
  `config/runtime.exs`), which Fly MPG's pgbouncer rejects with
  `FATAL 08P01 unsupported startup parameter`, crash-looping the pool so it never
  established a connection — every heavy vector/enumeration endpoint (`suggested_links`,
  semantic search, `distant_pairs`, `novelty`, heavy enumeration) hung then `503/504`'d.
  It was invisible to CI because the suite connects to direct Postgres (which accepts the
  startup param) and aliases heavy reads to `AdminRepo`. The server-side `statement_timeout`
  is now applied per-read via `SET LOCAL` inside a transaction (the pgbouncer-safe mechanism).

### Changed

- **Heavy-read `statement_timeout` configuration:** set via `HEAVY_READ_STATEMENT_TIMEOUT_MS`
  (default 10s) and the per-endpoint `:heavy_read_statement_timeout_overrides` map, applied
  per-read via `SET LOCAL` — **NOT** a connection startup `:parameters` value
  (pgbouncer-incompatible). A server GUC that must persist at connect is set via `ALTER ROLE`
  (the documented `hnsw.ef_search` lever), never a startup parameter.

### Added

- **Recurrence guards:** `config_pgbouncer_safe_parameters_test.exs` (scans the config
  source — incl. `runtime.exs` — and fails on any pgbouncer-incompatible repo `:parameters`)
  and a pgbouncer-layer e2e (`pgbouncer_startup_params_test.exs` + a CI `pgbouncer-e2e` job
  that gates deploy) which reproduces the `08P01` rejection and proves `SET LOCAL` enforces
  through the proxy.

## [Unreleased] — 2026-06-22 — knowledge wiki harvest-hardening (#132–#138)

A batch of Knowledge Wiki API changes for reliable agent/harvest workflows.
(Supersedes the #120 draft-by-default + orchestrator-publish-gate notes below.)

### Added

- **Idempotency_key (#137):** `POST /api/v1/articles` accepts `idempotency_key`
  (per-article, max 255). Re-creating with the same key is a no-op that returns
  a reference to the existing article (`deduplicated: true`, id only — no body),
  preventing partial duplicates on re-capture. Distinct from
  `source_type`/`source_id` (a shared source identifier).
- **Lag-free enumeration (#134/#135):** `GET /api/v1/articles` filters by
  `source_type`, `source_id`, and `idempotency_key`; new MCP `knowledge_list`
  wraps it. This is the lag-free, all-status read of record for
  dedup/idempotency/repair — vs `knowledge_search`, which is ranked,
  published-only, and lags writes.
- **Bulk delete (#136):** `POST /api/v1/knowledge/bulk-delete` (role user) —
  partial-success soft-delete by `article_ids`, `source_type`+`source_id`, or
  `tag`+`confirm:true` (exactly one selector). MCP `knowledge_bulk_delete`.
- **Ingest publish opt-in (#133):** `POST /api/v1/knowledge/ingest` + `/batch`
  accept `publish: true`; extracted articles stay **draft by default**
  (lower-trust LLM output) but can be published in one step.

### Changed

- **Publish-on-create is the default for every role, including agent (#133)** —
  `POST /api/v1/articles` publishes immediately; draft is now the opt-in
  (`draft: true` / `status: "draft"`). The orchestrator-only publish gate is
  removed on the create path (publishing a wiki article is neither destructive
  nor story chain-of-custody); the standalone publish endpoint and system-scope
  gate are unchanged.
- **Bulk-publish is partial-success + uncapped (#132, #138.3):** publishes every
  valid draft and returns per-id outcomes (published/skipped/not_found/errored)
  in `meta.results` instead of failing the whole call; already-published ids are
  skipped (idempotent); the 100-id cap is gone (auto-chunked, ≤5000).
- **Tag cap raised 20 → 50 (#138.2).**

### Fixed

- **Invalid `?status=`/`?category=` → 400 with allowed values (#138.1)** on
  `GET /api/v1/articles` (was a 404/500 from an `Ecto.Enum` cast); malformed
  list/map query params no longer 500.
- **429 `Retry-After` is always ≥ 1s (#136)** (was `reset_at - now`, which could
  be ≤ 0 at a window boundary); rate limits documented on `RateLimitError`.

### Docs

- Documented the witness/STH request-header workflow for non-MCP clients (#138.4)
  and the search-vs-list distinction.

## [Unreleased] — 2026-06-19 — create-and-publish + draft note (#120)

### Added

- `POST /api/v1/articles` accepts `publish: true` to create-and-publish in one
  call. This is gated at **orchestrator+** (mirrors `POST /articles/:id/publish`);
  an agent requesting publish gets `403 publish_requires_orchestrator`.

### Changed

- The create response now carries a `note` making the lifecycle explicit —
  articles are created as **draft** (not visible in search/index/context) unless
  published, which the two-step flow made easy to miss (#120).

### Security

- The initial article status is now set **server-side** on create; a
  caller-supplied `status` is ignored except that `status: "published"` is
  treated as `publish: true` (and gated the same way). This closes a gap where
  an agent could self-publish — or set `archived`/`superseded` — by passing
  `status` directly in the create payload, bypassing the orchestrator publish
  gate.

## [Unreleased] — 2026-06-19 — search total_count semantics (#119)

### Changed

- `GET /api/v1/knowledge/search` now returns `meta.total_count_scope` (and
  `meta.search_mode`) so callers can tell what `meta.total_count` counts in the
  active mode: `keyword_matches` (stop-word-filtered tsquery matches),
  `ranked_corpus` (semantic ranks all embedded published articles — that
  embedded set's size, not a match count, and ≤ the published count),
  `merged_candidates` (combined: deduped union of a keyword and a semantic
  sub-search, each capped at 50, so up to ~100), or `filtered_set` (list mode:
  complete set). The
  OpenAPI description and MCP tool docs now spell out the per-mode semantics and
  stop-word behavior, and direct corpus-sizing to list mode or
  `GET /knowledge/stats` (#119). No value changed — `total_count` was already
  uncapped per mode; this makes its meaning explicit.

## [Unreleased] — 2026-06-19 — knowledge stats endpoint (#118)

### Added

- `GET /api/v1/knowledge/stats` (and `GET /api/v1/projects/:project_id/knowledge/stats`)
  — aggregate article counts (`total`, `by_category`, `by_status`) via cheap
  `COUNT(*) GROUP BY` with no article metadata loaded. Answers "how many
  articles are here?" without paging the index. Counts span all statuses;
  `by_status` shows the published/draft/archived/superseded split. Role: agent+.
  Exposed via the MCP `knowledge_stats` tool.

## [Unreleased] — 2026-06-19 — knowledge_index field projection (PR #126)

### Added

- `GET /api/v1/knowledge/index` accepts a `fields` query param — a
  comma-separated projection of `id, title, category, tags, status,
  updated_at`. `id` and `category` (the grouping key) are always included;
  unknown fields return `400` (matching the existing `category` validation).
  `meta` now echoes the applied `fields` and adds `has_more` (a synonym for the
  existing `truncated`). The MCP `knowledge_index` tool gains a matching
  `fields` parameter (array or csv). Non-string `fields`/`category`/`tags`/
  `limit`/`offset` params now return `400`/are ignored rather than raising a
  `500`.

### Changed

- **Default response shape changed** (intentional): without `fields`, each
  article object now includes only `id, title, category` instead of all six
  metadata fields. This shrinks the catalog payload dramatically — previously
  the index serialized every field (including the full `tags` array) for up to
  1000 articles per page, producing ~545 KB responses that overflowed MCP
  clients' token limits (#117). Callers that need `tags`/`status`/`updated_at`
  must now request them explicitly via `fields`.

## [Unreleased] — 2026-06-18 — Concurrent article create (PR #116)

### Changed

- `POST /api/v1/articles` (and MCP `knowledge_create`) is now concurrency-safe.
  A create that races/retries into the `(tenant_id, title)` active unique index
  no longer returns a spurious `422 "tenant_id has already been taken"`: an
  **identical-body** collision returns the existing article idempotently as
  **HTTP 200**, and a **different-body** collision returns **`409 title_conflict`**
  (with `existing_article_id`) instead of a 422 the client retries into. The
  unique-violation is attributed to `title` rather than the misleading
  `tenant_id`. Fixes #113/#114.

## [Unreleased] — 2026-04-17 — Import merge + agent ergonomics (PR #105)

### Added

- `POST /api/v1/projects/:project_id/stories` — create a single story by
  epic number (agent-friendly alternative to the UUID-based
  `POST /epics/:epic_id/stories`). Role: `:orchestrator`.
- `POST /api/v1/stories/:id/backfill` — mark a story as verified when the
  work was completed outside loopctl. Records provenance in
  `metadata.backfill` plus an `action: "backfilled"` audit entry and a
  `story.backfilled` webhook. Refused for any story with dispatch lineage
  (non-pending `agent_status`, `assigned_agent_id`,
  `implementer_dispatch_id`, or `verifier_dispatch_id` set) — this is the
  structural guard that makes backfill safe regardless of role. Role:
  `:orchestrator`.
- `story.backfilled` added to the webhook event allowlist.

### Fixed

- `POST /api/v1/projects/:id/import?merge=true` no longer returns
  `epics[0].tenant_id: has already been taken for this project` when
  clients serialize epic numbers as strings. Epic numbers are normalized
  to integers (and story numbers to strings) before validation and DB
  lookups.
- Fallback changeset rendering translates Epic/Story unique-number
  violations into `"Epic 72 already exists in this project. Use
  merge=true..."` regardless of which controller surfaced the error.

### Changed

- Data-op roles: create/update for epics, stories, and dependencies
  lowered from `:user` to `:orchestrator`. DELETE stays at `:user` per
  the destructive-op rule. CLAUDE.md Security section clarified.
- `/loopctl:orchestrate` skill carves out "data operations" (imports,
  creates, backfills, dispatches, reads) as operations the orchestrator
  can perform directly without dispatching a sub-agent. Sub-agents are
  only required for editing application code.

### Security

- `unique_constraint` error translation now scopes to the `_number_`
  index specifically, so future unique constraints (external_id, slug,
  etc.) on Epic/Story schemas won't be mis-reported as "X already
  exists."

## [1.0.0] — 2026-04-12 — Chain of Custody v2

27 stories across 7 phases implementing a six-layer trust model for
AI agent development loops. Full spec: `docs/chain-of-custody-v2.md`.

### Added — Chain of Custody v2 / US-26.0.1

- **Tenant signup ceremony with WebAuthn enrollment**.
  - New public LiveView at `/signup` that collects tenant metadata and
    initiates a FIDO2 registration ceremony via `navigator.credentials.create()`.
    Supports both cross-platform authenticators (YubiKey, etc.) and platform
    authenticators (Touch ID, Windows Hello).
  - `tenant_root_authenticators` table storing `credential_id`, COSE public
    key, attestation format, sign counter, and friendly label per enrolled
    key. One-to-many from tenant to authenticator, unique on
    `(tenant_id, credential_id)`, RLS-enabled.
  - `tenants.status` gains a `:pending_enrollment` value; an Oban cron
    worker (`PendingEnrollmentCleanupWorker`, every 5 minutes) deletes
    tenants stuck in that state past the 15-minute TTL.
  - `Loopctl.WebAuthn.Behaviour` + `Loopctl.WebAuthn.Wax` adapter, wired
    via config-based DI so tests can swap in `Loopctl.MockWebAuthn`.
  - `Loopctl.Tenants.signup/1` atomically creates the tenant, persists
    every verified authenticator, flips the status to `:active`, and
    writes the audit log genesis entry in a single `Ecto.Multi`.
  - OpenAPI schemas: `TenantSignupRequest`, `WebAuthnChallenge`,
    `WebAuthnAttestation`; `TenantResponse` updated to surface the new
    `pending_enrollment` status.
  - New post-signup onboarding LiveView at `/tenants/:id/onboarding`
    that scaffolds the four-step operator checklist (audit key
    generation, system article tour, first project, first agent).
  - JavaScript `WebAuthn` hook in `assets/js/hooks/webauthn.js`.
  - `CoreComponents` module providing `<.input>`, `<.icon>`, and
    `<.flash_group>` in the design-system palette.

### Removed

- `POST /api/v1/tenants/register` and the `Loopctl.Auth.register_tenant/1`
  helper it called. Chain of Custody v2 requires a WebAuthn-gated signup
  ceremony; the legacy unauthenticated tenant creation path has no
  replacement and any request to it now 404s. This enforces AC-26.0.1.7.
