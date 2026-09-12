# Agent Delivery Loop

**Status:** design. Not implemented.

This is the single current description of the loop. Git history is the record of how it got
here; the comments on loopctl#800-805 and loopctl-runner#1 carry the evidence behind individual
decisions. Where this and any issue comment disagree, this wins — fix the document rather than
adding a note to it.

## 1. What this is for

Larisa Frenkel, AVA's office manager, reports problems through the AI chat already inside
HomeCareBilling. That chat files a GitHub issue and a support row. Today the work waits for
Mark. This loop triages the issue with agents, implements it on a dev machine, and merges it
when the gates pass.

Mark is involved only when the *request* contradicts something or is a drastic change.
Otherwise, never.

**What Larisa can see matters for the design:** tenant-facing routes include `/billing`,
`/billing/denials`, `/batches`, `/remittances`. She cannot see claim-generation code but she sees
its output, so a substantial class of tickets are symptoms of claim output. **A ticket's wording
therefore says nothing about where its fix will land** — "the monthly total is wrong" may be a
billing-calculation fix, "this claim was denied" may be a UI validation fix. Risk is classified
from the diff, never from the report.

## 2. Three planes

| plane | where | owns |
|---|---|---|
| **Control** | loopctl on Fly | issues, triage queue, stories, claims, gates, machine registry, audit |
| **Runner** | a Phoenix app on each dev machine | local resources, worktrees, session lifecycle, liveness |
| **Session** | a `claude -p` process in a worktree | triage, and separately implementation |

A Claude Code session is an OS process with a unix socket, never a BEAM process. Everything here
wraps it; nothing supervises it directly.

### Transport: an authenticated Phoenix Channel, not a BEAM cluster

The runner connects **outbound** as a client. It does not join loopctl's cluster: a dev laptop
inside the production cluster means `:erpc` reaches everything, and home machines behind NAT
would need Fly WireGuard to join at all.

Consequences: `Phoenix.Presence` replaces `Group` for liveness; `SocketDist` is irrelevant (it
separates lanes *within* a cluster); trace contention is answered by a second socket, not a
second topic on the same one.

**The channel must not bypass loopctl's security pipeline.** Tenancy is RLS driven by
`SET LOCAL app.current_tenant_id` per request (`lib/loopctl/repo.ex:63,147-156`), with plugs for
`set_tenant`, `require_auth`, `require_role`, `check_custody_halt`, `resolve_api_key`,
`rate_limiter`, `validate_witness_header`. `join/3` resolves api key and tenant through the same
functions; every `handle_in` calls a context function that owns its transaction and sets the GUC.

## 3. Stage machine

**Postgres owns the state.** loopctl's `stories` table already is a state machine
(`agent_status` / `verified_status` with check constraints). A `DurableServer` per story is a
cache that reloads from Postgres on resume — not a second source of truth, because the audit
chain is the custody-bearing record and nothing transacts across both stores.

```
detected -> triaged -> queued -> claimed -> worktree -> implementing
         -> reviewing -> pr_open -> ci -> merged -> deployed -> verified -> done
```

Failure edges are part of the machine, not exceptions to it: CI red → implementing; review
findings → implementing; merge conflict or base moved → implementing; post-deploy verification
failing → escalated; budget exceeded → failed; runner lost → queued. `escalated` has an explicit
transition for Mark acting.

**Every stage is idempotent on replay.** A restored process re-enters its stage and would re-run
the side effect — a second worktree, a second PR, a second deploy. Each stage writes the identity
of its side effect (worktree path, PR number, merge SHA, release id) *before* acting and checks
for it on entry. Without this, durability turns one crash into duplicate outward actions.

Note the ordering: the PR opens on the first green commit, **before** review, so CI and review
run concurrently.

## 4. Triage

Three agents — `business-analyst`, `elixir-systems-architect`, and a senior-engineer lens —
dispatched concurrently in one message. They create and review the story in **one pass**.
Disagreement does not trigger another pass; it escalates.

**Triage runs as a `claude -p` session on a runner, not inside loopctl.** The agents are Claude
Code definitions in `~/.claude/agents/`; loopctl is an Elixir release on Fly with no Claude Code,
no `~/.claude` and no checkout. loopctl holds the queue, the gates and the state, and dispatches
triage the same way it dispatches implementation.

The triage session queries the database directly, the way anyone on that machine does — dev
machines already have full access. One correctness note: production mixes real agency billing
with demo and test rows, discriminated only by `batches.original_filename`.

Output contract:

```json
{
  "verdict": "story" | "escalate" | "reject",
  "story": { "title": "...", "acceptance_criteria": [...], "test_cases": [...],
             "touches": ["lib/..."], "domain_reference": "docs/domain/....md | N/A — <reason>" },
  "escalation_reasons": [...],
  "contradicts": [{"kind": "story"|"kb"|"code", "ref": "...", "why": "..."}],
  "confidence": 0.0
}
```

This contract does not exist yet. Neither agent definition emits a verdict, a confidence or any
JSON, neither has `Write` in its `tools:` line, and `--json-schema` constrains a run's final
result rather than a subagent's return. The contract has to be added to the agent bodies as a
required final fenced block, with the dispatching session re-emitting the merged object.

`reject` exists for the genuinely non-actionable. **It must not close the GitHub issue naively** —
see §9.

## 5. Two gates

These are two different gates. Collapsing them into one "escalation" concept produces a **54%
escalation rate**, measured on 80 first-parent commits — the outcome the calibration exists to
prevent.

### Gate A — "Mark decides." Request-shaped. Rare.

- the request **contradicts** an existing story, KB decision, or documented behaviour
- it **inverts or removes** behaviour a previous story deliberately added
- it is a workflow change rather than a defect fix
- the trio's `verdict` field disagrees across the three agents

**No file paths belong in Gate A.** An uncontested defect in the claims path is not something
Mark needs to decide. Gate A's rate is measured and reported; a rate resembling 54% is a design
failure, not a tuning question.

Do not gate on self-reported `confidence` — three independently-prompted agents disagreeing is a
comparison between separate judgements and a far better signal. Record it, rank on it, log the
soft triggers for a fortnight before any of them gate anything.

### Gate B — "a human confirms." Effect-shaped. Mechanical.

Fires when a change can cause an **irreversible external effect**: a claim submitted, money
moved, an EVV record sent, a payer artifact emitted. A revert does not un-submit an 837P.

Gate B does not mean Mark reads a diff. The change proves its effect:

1. deploy the branch to staging;
2. regenerate 837P output from a **fixed fixture set**;
3. the diff must be **non-empty exactly where the change intended, and empty everywhere else** —
   both halves, because "nothing changed" is not a pass for a change meant to alter billing;
4. clean result merges with no human. Anything else routes to Gate A.

Known limits, written in rather than discovered later: a golden-file oracle only detects changes
*to the golden*, so an untested path regresses silently; and a validator passing is not
correctness — a lenient one hid a spec violation in every claim file for eight months. **Fixture
coverage over service codes, modifiers and programs is itself an asserted test** that fails when
a new code appears without a fixture.

Paths that feed Gate B, read literally off the repo and asserted by a test that fails when one
stops existing: `priv/fee_schedules/**` (rate tables are CSV data, not code — a one-line edit is
a Medicaid rate change), `lib/home_care_billing/claims/**`, `lib/home_care_billing/edi/**`,
`work_orders/billing_codes.ex`, `payroll.ex`, `lib/mix/tasks/**` (24 tasks, several of which
rewrite fee schedules), `config/runtime.exs`, and anything loaded via `:code.priv_dir`.

Note `lib/home_care_billing/billing/` is **Stripe SaaS billing**, not the Medicaid path, and
`lib/home_care_billing/authorizations/` is **prior authorization**, not authZ. Globbing on the
words is wrong in both directions.

Human-gated outright, because they have no claim-output signature to prove: router pipelines
(`:require_tenant_admin` / `:require_tenant_member` are the real access control),
`lib/home_care_billing_web/plugs/*auth*`, and `lib/**/data_migrations/**` (12 modules that mutate
production data from outside `priv/repo/migrations/`).

### Both gates run twice

A single evaluation at triage runs over the trio's **predicted** touch list, and nothing binds
the implementing session to that prediction — so a gate that runs only there certifies a guess.

Run at triage over the predicted touches to decide whether to dispatch at all. Run again as a
**merge precondition** over the real `gh pr diff --name-only` plus the real diffstat, including
the 12-file / 1,000-line bound. The second run is the one that gates.

**Fail closed.** Trigger data lives in configuration; a missing, empty or misparsed config must
escalate unconditionally, not yield an empty trigger set that merges everything. That is a test
and a `bin/mutate.sh` case.

**"Agents may only add an escalation, never remove one" is a wiring property**, not a rule agents
follow: the gates compute their own triggers and OR them with the agents' signals, never reading
an agent's negative.

## 6. Claiming

Extend `Progress.claim_story/3` (`lib/loopctl/progress.ex:155`). Do **not** open a second write
path to `stories`: `claimed_by` does not exist in that schema, and the existing function does the
audit-chain append, the webhook event, the `start_cap` mint deliberately inside the transaction,
the dependency check, the `lifecycle_entered_at` anti-launder marker and the dispatch lineage.

Add what it lacks: `claimed_until`, renewal from the runner, a reclaimer worker modelled on
`Dispatch.expires_at` + `RevokeExpiredDispatchesWorker`, and a **`claim_epoch`** bumped on
reclaim and echoed on every runner→control message so a resurrected zombie's writes are rejected.

The existing channel-claim mechanism is not exclusive on this fleet — every session
authenticates as one `agent_id`, so a second claimant gets the first claim back idempotently.
That is why story claims are a Postgres transaction.

## 7. The machine pool

`Phoenix.Presence` on the runner channel, topic `"runners"`, carrying cores, memory, repos,
`max_sessions`, `in_flight`, `draining`. Tracking dies with the socket, so a crashed runner
leaves the pool with no sweeper.

**Presence is a liveness hint, not a scheduler.** It is an eventually-consistent CRDT with no
compare-and-set, so two story processes both read `in_flight: 0` and both dispatch to the same
runner. Reserve capacity in Postgres —
`UPDATE runners SET in_flight = in_flight + 1 WHERE name = $1 AND in_flight < max_sessions
RETURNING` — and have the runner refuse an over-budget dispatch anyway.

**Presence also does not converge on loopctl as deployed.** `cluster_readiness.ex` states loopctl
runs single-node; `DNS_CLUSTER_QUERY` is unset so `DNSCluster` is `:ignore`; `fly.toml` has
`auto_start_machines = true`. The moment Fly starts a second machine, a runner tracked on node A
is invisible on node B — permanently. Either set `DNS_CLUSTER_QUERY`, pin the machine count, or
keep the pool in Postgres. **Decide this before step 5 of the build order.**

**"Connected" is not "able to build."** A wedged machine answers heartbeats while the box
thrashes. Publish a periodic self-measured sample — loadavg, free RAM, free disk, time of last
successful build — and treat a stale sample as a breached threshold. Absence is a negative.

Enrolled: **minis, mac-mini, blockit.** Not beelink (dedicated CI host; may be added later) and
not xps13 (4 threads, 8 GB soldered). Placement prefers a warm `_build`, then free capacity, then
lowest `in_flight` — with free disk as a precondition.

**The runner validates every dispatch against a local allow-list** (repos, branch prefixes, wall
clock, token budget) and refuses by default. The obvious threat is a compromised machine reaching
the control plane; the direction this design actually opens is the reverse, where a dispatch is
an arbitrary prompt executed as the user with that machine's credentials.

## 8. Unattended sessions

**Launch with `--permission-mode auto --permission-prompts none`.** That flag *removes*
`AskUserQuestion` from the tool list and cancels MCP elicitations — making the wrong thing
impossible rather than costly. Requires 2.1.259+. Add `--max-turns` as the hard stop.

Do not reach for a `PreToolUse` deny hook instead. That is one rung down and retryable: the retry
control lives on `PermissionDenied`, which does not fire for `PreToolUse` denials, so nothing
bounds an unattended session re-asking. And never pair it with `permissionDecision: "allow"` plus
`additionalContext` — `allow` means the tool *runs*, which is the hang the flag exists to prevent.

Keep a hook only for what the flag cannot do: emitting the **escalation** signal when the model
wanted to ask. Register it on `PermissionDenied`. Default that path to escalate, not deny — a
stateless hook cannot judge "can this be answered" over free text, and denying by default means
the session silently guesses. Log every suppressed question into the trace so "the answer is
already in the story" becomes measurable.

If a hook is used, it is **one script branching on `LOOP_MODE`**, not a sibling on the same
matcher as `gate-ask-user-question.sh` — two hooks denying the same call with contradictory
instructions is worse than either. The runner passes `LOOP_MODE=1 LOOP_STORY_FILE=...` in the
environment, which hooks inherit.

**Parking detection.** Do not use "no writes under `subagents/` in N minutes" — measured on
mac-mini, **0 of 1,543 project directories** contain one, because that directory exists only when
a session dispatches subagents, so it reports every healthy solo session as parked from second
zero. Use instead, ORed: bytes on the Port's stdout (strongest, needs no filesystem); mtime on
`~/.claude/projects/<slug>/<sessionId>.jsonl`; and `claude agents --json`. Keep `subagents/` only
as a suppressor meaning "legitimately waiting on a panel".

**Exec `bin/claude-headless.sh`, never `claude`.** `ANTHROPIC_API_KEY` in the environment
silently outranks the claude.ai login; that incident cost ~USD 300 and reported a usage limit
rather than an auth error. The canary enforcing it only sees claude-config's own files, so this
repo needs its own copy or a release that refuses to build on a direct invocation.

**Closing a Port does not kill a process tree.** Use `setsid` plus `kill -TERM -<pgid>` on both
platforms; MuonTrap's containment is cgroup-based and two of three machines are macOS. Reap
orphans at runner boot, since teardown only runs on the happy path.

**The session's cwd must be the worktree** — `block-foreign-repo-write.sh` keys on
`git rev-parse --git-common-dir`, so `--add-dir` from elsewhere blocks every write.

**Not `--bare`** (it would strip the hooks, agents, MCP servers and CLAUDE.md the loop depends
on), which means every guard hook loads — including `gate-unmerged-pr.sh`, which blocks exactly
the "merging nothing" end state build-order step 1 prescribes. The runner sets a loop-mode
variable that gate exits 0 on.

## 9. Merge, and what Larisa sees

`required_approving_review_count` is **0** on both `master` and `staging` of home_care_billing,
so "merge on passed reviews" would mean agent-written code reviewed by agents and merged by
agents, with no human anywhere. **Raise it to 1 on the loop's target branches** and have the loop
request review for anything Gate B does not clear — branch protection is server-side and an agent
cannot talk around it.

`on: pull_request` runs the workflow file **from the PR's own head**, so a loop PR can edit the
CI that judges it. Required contexts must come from a workflow the PR under test cannot modify.

**The domain gate is a required check and no issue assigns it.** `governance_gate.ex` plus
`.github/workflows/domain-gate.yml` require every PR touching `lib/home_care_billing*` to name a
`docs/domain/*.md` artifact or an auditable `N/A — <reason>`. Without `domain_reference` in the
trio's verdict, **every loop PR stalls**.

**CI is a capacity-1 resource.** `test`, lint, security, dialyzer and scale-test all run on
`[self-hosted, beelink]` — the box excluded from the pool. Six concurrent implementations feed
one CI machine, so throughput is bounded by CI, not dev capacity. Model it as capacity-1 so
stories queue at the `ci` stage.

**Admission control**: three machines at `max_sessions: 2` is six concurrent sessions each
dispatching review panels, all against one Anthropic account, and the account rate limit is what
bites on parallel work. A control-plane token bucket over total in-flight sessions, checked
before a story is claimed.

**Exclude loopctl and claude-config from auto-merge.** loopctl deploys on every push to master
and *is* the control plane, so a story changing it restarts the node holding its own
DurableServer; claude-config is read every turn by every session on six machines. Target repos
are product repos only — the loop must not edit the guards that constrain it.

**The only independent reviewer must not be CI.** loopctl's founding thesis is that agents
self-approve, which is why stories carry `verified_status`, `verifier_dispatch_id` and
`verifier_needed`. Reuse it: merge requires `verified_status = :verified` set by a verifier
dispatch with a **different lineage**.

### Larisa's side

She is notified **when a change is deployed**, never of work in progress — no PR link, no branch,
no "an agent picked this up". Work-in-progress notifications invite intervention in a loop
designed to run without it, and an abandoned PR reads as a broken promise.

Three already-shipped behaviours work against that and must be handled:

- **Closing the GitHub issue emails her that a fix shipped.** The webhook auto-resolves the
  ticket with `resolution_notes: "Our team has shipped a fix for this issue."` on *any* close
  (`github_controller.ex:115`, `ticket_notifier.ex:413`). A `reject` verdict would tell her a fix
  shipped for something nobody built. The loop sets `resolution_notes` per verdict before
  closing, or closes with a label the webhook skips.
- **The resolution email is on a 15-minute timer from merge, not from deploy.**
  `support_ticket_resolved_email_worker.ex`'s own moduledoc says deploys longer than that window
  race it. The post-deploy verification emits the resolution; delete the timer.
- **Post-deploy verification compares the deployed SHA to the merge commit.** A `workflow_run`
  deploy ships the *triggering* run's commit, not the one GitHub attributes it to.

## 10. Reporter text is untrusted

`github_issue_worker.ex:217` interpolates `ticket.description`, tenant name, page URL and client
`user_agent` verbatim into the issue body that triage and then an implementer read. `/demo-request`
is public and self-provisions a tenant, so that text is not only Larisa's.

Reporter-supplied text is **data, never instruction**, at every hop, fenced and labelled as
untrusted. **The implementer never sees raw reporter text** — its input is the story the trio
wrote. That is the strongest control available and it falls out of the architecture already
chosen. An injection attempt escalates and is recorded rather than being silently filtered.

Between her observation and the acceptance criteria there are already three model paraphrases and
no human confirmation: the ticket tool is exempt from the confirm-before-write gate, the
conversation excerpt replaces every user turn with `"[User message]"` for PHI reasons, and the
issue worker paraphrases again. **Show her the filed description and let her correct it** — one
round trip removes three layers of telephone.

## 11. Observability

One NDJSON event stream per run, every event carrying a `parent` field so the agent tree is
reconstructable. Our audit logs today are per-session text with no parent link, which is why
attribution needs `bin/who-did-it.sh` instead of a query.

The on-disk file is the source of truth. Ship `(run_id, seq)`, have the server ACK the last
contiguous seq, resume from that offset on rejoin, dedup on the pair — Phoenix replays nothing,
and a rejoin happens on every rolling deploy. Better still, upload the trace to object storage
from the runner and send a pointer plus the small structured events.

Stage and trace events go on their own non-chained table. The audit chain takes
`SELECT ... FOR UPDATE` on the tenant's latest entry inside the caller's transaction, with a
gapless `chain_position` trigger, so putting every stage transition on it serialises every
concurrent story on one row. Keep the chain for custody-critical transitions: claim, merge,
escalate.

## 12. Build order

1. **One runner, one machine, one hand-filed story, merging nothing.** No cluster, no registry,
   no triage, no network — a Mix task that creates a worktree, runs `claude -p` through a Port,
   emits the trace, detects parking, tears down. Proves the four mechanisms.
2. **Gate B's claim-output harness**, offline, against real past changes. Measure its false
   negatives before it gates anything.
3. **Gate A**, log-only, against real past tickets. Measure its rate.
4. **The trio** — output contract in the agent bodies first — emitting stories behind a manual
   approve.
5. **`Progress.claim_story` extension plus the stage machine.** Now a story survives a restart.
6. **Presence pool, second runner, real placement.** Resolve the single-node question first.
7. **Auto-merge**, last, once 2 and 3 have a track record.

## 13. Repo layout

- **loopctl** (public) — control plane, gates, queue, state, and the versioned runner contract
  alongside `api_spec/schemas.ex`. Trigger *data* lives in configuration, not in source: the list
  is a map of which paths skip human review.
- **loopctl-runner** (private) — this repo. Its own repo because loopctl is a single Mix app with
  one release, so runner code would be loaded in the BEAM of a multi-tenant production app, and
  its deps would enter loopctl's `mix.lock` and `hex.audit` surface. Private because it encodes
  fleet topology and channel-token handling. Keep topology and trigger lists in configuration and
  going public later is deleting a directory.
- **claude-config** — the loop-mode launch flags and any `PermissionDenied` hook.

*(Note for anyone re-examining the split: loopctl's `ci.yml` has no paths-filter and no
path-probe job, and `test` carries no path condition, so CI coupling is not an argument either
way. The split stands on one-app-one-release alone.)*

## 14. Packaging

`mix release` built on each target machine — all three have a full asdf toolchain and BEAM
releases are not portable across OS or arch. Not Burrito (its value is machines *without* a
toolchain). `systemd --user` on Linux, launchd `LaunchAgent` on macOS, user-scoped in both cases
because the runner must reach `~/.claude`, `~/workspace`, asdf shims and GitHub credentials.

Three traps: `ExecStart=.../bin/<app> foreground` is Distillery and yields a systemd restart loop
— use `start`; do **not** copy `DynamicUser=true` from the standard hardened BEAM unit (it gives
an ephemeral user and read-only system, fatal here) though `PrivateDevices=true` and
`ERL_CRASH_DUMP_SECONDS=0` are worth keeping; a release in daemon mode logs to
`tmp/log/erlang.log.1`, not journald.

## 15. Still open

- Whether loopctl runs single-node or clusters — decides whether Presence is viable at all (§7).
- Raising `required_approving_review_count` to 1 on the target branches (§9) — Mark's call.
- Gate A's measured rate and Gate B's false-negative rate, from steps 2 and 3.
