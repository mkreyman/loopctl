# Spec agent uses: process inventory and ranked candidates (US-48.15 research)

Window: 2026-10-08 .. 2026-11-07 (30 days), measured on minis unless noted. Every number is an aggregate; no ticket, PR-body or customer text was read into this file.

## Sources and how each was measured

| Source | What was taken | Quality |
|---|---|---|
| Session transcripts, `~/.claude/projects/*` on minis | 118 interactive workspace sessions touched in 30 days, 300.7 active hours (sum of gaps under 5 min between transcript entries), 923 short user turns (1,500 chars or less), of which 631 are distinct. Plus ~9,000 headless `-tmp-*` transcript dirs (plugin evals, hook children) and 499 courier runs, excluded. | Measured, minis only. Keyword-per-category attribution is unreliable: most sessions mention "PR", "CI" and "story" in the same turns, so per-process hours below are NOT split from this source. |
| GitHub merged PRs (`gh pr list`) | Titles classified by regex: home_care_billing 1,267 merged in 30 days (378 / 364 / 340 / 127 / 58 per week, newest first); loopctl 42; loopctl-runner 4; claude-config 139. | Measured. Title regex undercounts fixes (349 HCB titles fell in "other"). |
| GitHub issues by label (`gh issue list`) | Created in the window, with median open-to-close. | Measured. |
| loopctl channels | Last 40 HCB posts (2026-11-06 22:56 .. 11-07 13:43), last 25 on claude-config (10-28 .. 11-07) and loopctl (10-15 .. 11-07). Keys counted, bodies not used beyond the preview. | Measured sample, not a full 30-day count. |
| KB | `0f23eefd` (HCB pipeline wall-clock, measured 2026-10-02..16), `b00f57c6` (duplicated red-master fixes), `f496232f` (customer reply drafts must be fact-checked first), and the flaky-test / advisory clusters (`7c8a15d7` and siblings, `f07c9d2b`, `7209856a`, `7fcc62a6`, `3c205dc2`). | Prior decisions and measurements, cited per row. |
| Hooks, crons, timers | `crontab -l` (one entry: chg KB sync, daily 06:17), `systemctl --user list-timers` (fleet-orchestrator every 20 min, compact-window-report), `lib/loopctl/oban_config.ex` crontab, `~/workspace/claude-config/hooks/` and `bin/`, 42 `.github/workflows/*.yml` across repos. | Measured (inventory, not frequency). |

### Measured GitHub figures that drive the ranking

| Repo | Label / class | Created in 30 days | Closed | Median open-to-close |
|---|---|---|---|---|
| home_care_billing | `deferred-finding` | 118 | 116 | 4.9 h |
| home_care_billing | `test-flakiness` | 45 | 44 | 5.6 h |
| home_care_billing | `legacy-parity-review` | 98 | 98 | 9.7 h (a campaign, not a recurring process) |
| home_care_billing | `bug` | 24 | 24 | 5.2 h |
| home_care_billing | `master-red` | 6 | 6 | 1.5 h |
| home_care_billing | `hcb:via-mcp` + `hcb:reporter-unconfirmed` (support tickets) | 9 | 9 | 4.1 h |
| claude-config | `deferred-finding` | 20 | 8 | 1.4 h |
| loopctl | `deferred-finding` | 10 | 4 | 0.8 h |
| HCB / loopctl / runner / claude-config | merged PRs titled deps/bump/advisory | 6 / 6 / 1+ / 1 | | |

Per-PR cost of an agent-built change, from KB `0f23eefd` (HCB, 397 PRs): first commit to PR open median 50 min, last push to CI green median 10 min, pre-push `mix precommit` median 9 min (p90 20), local gates ~22 agent-hours a day, CI waits 6.9 agent-hours a day. I use **~1.2 agent-hours per small fix PR** as the estimate below; it is derived, not measured per process.

## 1. Process inventory

"Hands-on" is split into agent-session time (interactive Claude sessions on Mark's subscription, which he starts, watches and nudges) and Mark's own attention. Mark's own attention is never measured anywhere in the fleet; every such figure is estimated.

| # | Process | Where seen | Frequency (30 days) | Hands-on cost | Who does it today |
|---|---|---|---|---|---|
| P1 | Fixing routed review findings (`deferred-finding` issues: pre-existing defects in files a PR did not change, SOUL rule 0) | GitHub labels; SOUL rule 0 | **148 measured** (HCB 118, claude-config 20, loopctl 10), ~35/week | ~1.2 agent-h each (estimated from `0f23eefd`) = ~175 agent-h/month; Mark: a decision-default post to read per PR (estimated 2-5 min) | Interactive sessions pick them up from the issue list or a handoff |
| P2 | Fixing flaky tests | `test-flakiness` label; chg master verifier files them and writes a KB finding each (`7c8a15d7` and 100+ siblings); channel claims (`test-flakes-load:ryzen:*`) | **45 measured** on HCB, ~10/week | ~1-2 agent-h each (estimated; a flake needs reproduction under load) = 45-90 agent-h/month; each unfixed flake also costs CI re-runs | Interactive sessions, coordinated by channel claims |
| P3 | Red master repair | `master-red` label (6), channel `master-fix:*` / `master-test-timeofday:*` posts, KB `b00f57c6` | **6 labelled, measured**; red master runs are more frequent than the label (estimated 2-3/week from channel posts) | Duplicated: on 2026-11-01 three sessions fixed the same failures twice, each duplicate a full CI run while beelink admission was closed (`b00f57c6`). Estimated 2-4 agent-h per incident including duplicates | Whichever session notices first; chg auto-revert names a culprit PR |
| P4 | Dependency advisory bumps | Merged PR titles; loopctl channel `decision-default:loopctl:pr981-*`, `pr1013-advisory-bumps`, `pr1015-prod-capacity` (carries advisory bumps); task list "Runner deps advisories"; KB `f07c9d2b`, `7209856a`, `7fcc62a6`, `3c205dc2`, `2c5ae474` | **~14 measured from titles** across four repos (lower bound: bumps also ride other PRs), ~1 per repo per 2 weeks | ~1-1.5 agent-h each (estimated); the KB holds five separate traps (false-positive CVE metadata, stale ignore after backport, ignore list drift between mix.exs and CI, old Hex archive exits 0, hex.audit exit code ends the precommit alias) that each cost a session a discovery | Interactive sessions, when CI's security job goes red |
| P5 | Reading and overruling decision defaults | `decision-default:<repo>:pr<N>-*` posts (CLAUDE.md "Post the defaults you chose") | **Sampled**: HCB 14 in 13.7 h on 11-07; claude-config 17 in 10 days; loopctl 13 in 23 days. Estimated ~250-450/month fleet-wide | Mark only. Estimated 1-2 min each to read and judge, so 4-15 h/month if he reads them all; whether he does is not measured | Mark, by reading three or more channels |
| P6 | Support tickets (HCB) | `hcb:via-mcp`, `hcb:reporter-unconfirmed` labels; loopctl intake `triage_requires_ticket` (loopctl channel `pr1018`, 5 of 211 waiting HCB stories were tickets); KB `f496232f` | **9 measured** | Reply drafting cost a full redo on 2026-11-04 when a draft was not fact-checked against the tenant's production data (`f496232f`); estimated 20-40 min of Mark's time per reply | Being automated: triage@1, implement@1, verify@1, `reply_draft@1` (US-48.9) |
| P7 | Code review round per PR | `/lean-review` on every PR (CLAUDE.md step 4); 593 `/code-review` rounds measured in `0f23eefd` at a median 226 s | One per PR: ~1,450 PRs/month across the four repos (measured PR count) | ~4 min model time per round (measured); fix time folded into P1 | Inside each implementing session, plus `release-area-review` per epic |
| P8 | Deploy verification and deploy breakage | `deploy.yml`, `verify-master.yml`; HCB channel `DEPLOY BLOCKED` / `DEPLOY UNBLOCKED` on 11-07 (a release migration loaded a schema mapping a later migration's column); `PostDeployVerificationWorker` (loop stories only); `nudge-deploy-after-merge.sh` | 9 HCB PR titles about release/deploy (measured); blocked deploys estimated 1-2/month | One incident on 11-07 held every master deploy ~1 h and a session (estimated 2 agent-h) | Interactive session; loopctl verifies only loop stories |
| P9 | KB capture, harvest and curation | `knowledge-capture.sh` hook, `/debrief` (12 invocations measured on minis), `second-brain:*` skills, `kb-review-drafts`, Oban `KnowledgeLintWorker` daily, `KnowledgeMocWorker` weekly, nightly consolidation, `chg-kb-sync.py` cron daily | Debrief 12/month measured on minis; draft-review queue size not measured | Estimated 15-30 min per `kb-review-drafts` pass | Sessions, hooks and Oban |
| P10 | Fleet upkeep: config sync, nudging stalled sessions, worktree and branch cleanup | `fleet-orchestrator.timer` (every 20 min), `bin/fleet-sync.sh`, `nudge-fleet-sync.sh`, `fleet-strays.sh`, `worktree-remove.sh`, `delete-merged-branch.sh`; claude-config 139 merged PRs each needing a sync | Sync after every claude-config merge: ~139/month (measured PR count) | Scripted; seconds of agent time each | Scripts and timers |
| P11 | Escalation handling | `EscalationDigestWorker` daily 14:00 UTC, escalation inbox (US-48.11), `resolve_escalation` | Loop just went live (first HCB ticket 2026-11-07); no volume yet | Mark (user key) per escalation | Mark |
| P12 | Release notes / CHANGELOG | 0 prompts in 30 days on minis; CHANGELOG is operator-facing only (CLAUDE.md) | ~0 | - | Folded into PRs |
| P13 | Handoffs between sessions and machines | `handoff:*` keys on every channel (HCB 4 in the 40-post sample) | Sampled ~1/day per busy repo | Writing + claiming, estimated 10 min each | Sessions |

## 2. Candidate uses

Every candidate dispatches through loopctl's existing custody: a `:build` run is verified by `verify@1` under a separately rooted dispatch on a different runner (US-48.18), merged only on the merge gate's `allow` (US-48.17), and a `:draft` reaches nobody until a human releases it.

| Candidate | Archetype | Trigger | Input | What a human still decides | Custody risk | US-48.12 outcome signal |
|---|---|---|---|---|---|---|
| C1 `finding_fix` (P1): route `deferred-finding` issues through the delivery loop | `:build` (reuses triage@1 + implement@1 + verify@1; the change is an intake admission rule, not a new spec) | Issue labelled `deferred-finding` on an enrolled repo | The finding and failure scenario as triage drafts them (reporter text never rides the dispatch) | Gate B human paths escalate (money, PHI, auth); `resolve_escalation`; the decision defaults the PR posts | Low. The filer is a reviewer, the implementer a fresh dispatch, the verifier another root. claude-config has no Gate B entry, so every change there escalates (agent-delivery-loop.md, "Gate B") | merged / reverted, merge gate decision, review finding counts, verify reject, triage human override |
| C2 `flake_fix@1` (P2) | `:build`, a second spec of the archetype (PRD: "a new agent is a new spec") | `test-flakiness` issue filed by chg's master verifier | The flaky test id, its failure record, the KB finding | Any change outside `test/**` escalates by spec; Gate B | Low: the verifier re-runs the test many times under load, which is L3 independent re-execution, not the implementer's word | merged / reverted, verify reject, plus recurrence: a new `test-flakiness` issue for the same test within 14 days |
| C3 `advisory_bump@1` (P4) | `:build` | An advisory intake source: `mix hex.audit` / `mix deps.audit` / `npm audit` failing on the default branch, or a scheduled sweep | The advisory id, affected package, fixed version, the repo's ignore list | Declined bumps (a fix that breaks an API) stay a human call: the spec escalates instead of adding an ignore; Gate B on lockfiles of money repos | Medium: a lockfile change is wide. Bounded by the merge gate's 12-file / 1,000-line cap and by one advisory per run | merged / reverted, CI result, gate decision, advisory cleared at the merge head |
| C4 `decision_digest@1` (P5) | `:draft` | Daily cron | `decision-default:*` posts across the tenant's channels since the last digest | Every overrule; the digest only ranks and groups | None on custody (stores a draft, sends nothing). Post bodies are untrusted agent text, so the injection screen applies | released / edited / discarded per digest |
| C5 `red_master_judge@1` (P3) | `:judge` | Master push CI red (verify-master conclusion) | The failing tests, the commits since the last green, existing channel claims | Revert vs fix-forward on money/PHI paths; whether to reopen a closed claim | Low: verdict only, control applies it (posts the claim on the channel, files one `master-red` issue that C1/C2's intake can take) | human override (a session or Mark fixes a different culprit than the verdict named), duplicate-fix count after the verdict |
| C6 `deploy_failure_judge@1` (P8) | `:judge` | `deploy.yml` failure on master | The release command's failure output, migrations in the deployed range | The fix | Low | human override |
| C7 `kb_draft_triage@1` (P9) | `:draft` | Weekly, or when held drafts pass a count | Held machine-extracted drafts | Publish / correct / delete stays with the curator | Low as a draft; see rejected R4 | released / edited / discarded |
| C8 `escalation_brief@1` (P11) | `:draft` | A story enters `escalated` | `escalation_reason` (untrusted), stage history, the PR | `resolve_escalation` (user key, never a dispatch-minted one) | Low as a draft; see R2 | released / edited / discarded, and whether the human's resolution matched the brief's recommendation |
| C9 epic area review as a loopctl-dispatched reviewer (P7) | needs `:assess` | Epic PR opened | The epic diff by area | Fix scope | The reviewer must be separately rooted from the implementer; today review runs inside the implement session (PRD: `:assess` waits until a repo needs a dispatched reviewer) | review finding counts by severity, findings later confirmed by a fix commit |
| C10 handoff writer (P13) | `:draft` | Session end with work left behind (`work_left_behind`, US-48.11 gap fix) | The session's stage events | Whether to post it | None | released / discarded |

## 3. Rejected candidates

| Rejected | Why |
|---|---|
| R1. An implement session that runs its own review and, on a clean review, reports the story verified | The agent would certify its own work. Verification must come from a separately rooted dispatch on another runner (verify@1, `validate_not_self_verify/4`); the in-session review counts as a review only, never as verification. |
| R2. An agent that resolves escalations (re-queues or closes `escalated` stories) | `resolve_escalation` needs a user key no dispatch minted, so that a session cannot clear its own parking. An agent resolving the loop's escalations would certify the loop's own output. Kept as C8, a draft a human acts on. |
| R3. An agent that merges or decides a merge | Control decides the merge (US-48.17) and an ungated merge escalates. A merge-deciding agent would be the implementer's peer approving the implementer's head. |
| R4. A KB curator that publishes or supersedes the drafts its own lineage extracted, or records `:high` supersede verdicts | Publishing a capture certifies it. CLAUDE.md caps a supersede's confidence by the recorder's role precisely so one key cannot arrange a conflict and certify its verdict. Kept as C7, a draft. |
| R5. An agent that accepts decision defaults on Mark's behalf | The defaults exist because only Mark holds the fact (SOUL rule 1). Accepting them would be the choosing session's peer approving its choice. Kept as C4, a digest that sends nothing. |
| R6. An agent that edits Gate B triggers, claude-config hooks or chg's gate | The loop must never change, unreviewed, the code that gates its own work (agent-delivery-loop.md, Gate B rule; issue #986). |
| R7. A flake "fixer" that may mark a test skipped or delete it | That passes the gate by removing the evidence. C2 refuses any `@tag :skip`, deletion or timeout raise without an accompanying cause, and escalates instead. |
| Not rejected on custody, dropped for value: release notes (P12, ~0/month), fleet sync and nudging (P10, already scripts with no judgment), `legacy-parity-review` (a finished campaign, 98 issues all closed) | |

## 4. Ranked top five

Score = frequency per month x agent-hours (or Mark-minutes) per instance x confidence in the numbers, minus risk. Mark's minutes are weighted above agent hours because he is the constraint the epic is for.

| Rank | Candidate | Frequency | Cost removed per month | Confidence | Risk | Why here |
|---|---|---|---|---|---|---|
| 1 | C1 finding_fix | 148 (measured) | ~175 agent-h (estimated per-PR cost) | High on volume, medium on cost | Low | Largest measured recurring stream, already well specified by the reviewer (finding + failure scenario), and needs no new spec: only an intake admission rule beside `triage_requires_ticket`. |
| 2 | C2 flake_fix@1 | 45 HCB (measured) | 45-90 agent-h plus CI re-runs | High on volume, low-medium on cost | Low | The input is machine-filed and structured (chg's record), the verifier criterion is mechanical (N green reruns under load), and it is the PRD's test of "a new agent is a new spec" with a narrower blast radius than advisories. |
| 3 | C3 advisory_bump@1 | ~14 (measured lower bound) | ~14-21 agent-h, plus five KB-documented traps a session rediscovers | Medium | Medium | The PRD already names it as the next `:build` spec; it waits on an advisory intake source, which this story supplies. |
| 4 | C4 decision_digest@1 | ~250-450 posts (sampled) | Estimated 4-15 h of Mark's reading | Low (whether he reads them is unmeasured) | None | The only candidate that removes Mark's own time; costs one `:draft` spec and a cron. |
| 5 | C5 red_master_judge@1 | 6 labelled, more unlabelled | 2-4 agent-h per incident, mostly duplicate fixes | Medium | Low | Turns the KB `b00f57c6` rule (read the channel for a claim first) into a mechanism: one claim posted by control before any session starts, and one issue that C1/C2 can take. |

Below the line: C6 (deploy failures, ~1-2/month), C8 (escalation briefs, no volume until the loop runs), C7, C10, C9 (blocked on `:assess`).

### The stories

The top five are stories US-49.1 to US-49.5 in `docs/user_stories/epic_49_spec_agent_uses/` (`us_49.N.json`). Each names the outcome signal US-48.12 records for it.

## Evidence quality

- Measured: issue and PR volumes per label and per week (GitHub), open-to-close medians, session count and active hours on minis, channel post samples, the cron/timer/hook inventory, and the per-PR pipeline medians already in KB `0f23eefd`.
- Estimated: every per-instance hands-on cost (derived from `0f23eefd`'s medians, not measured per process), every figure about Mark's own attention, red-master frequency beyond the label, and the fleet-wide decision-default rate (from three samples).
- Not measured, and what would settle it: per-process agent-hours (attribute session active time by branch name or issue number in the transcripts, as `track-time` does for tickets); whether Mark reads decision-default posts (ask him, or count channel_get reads by his user key); KB held-draft volume (`knowledge_drafts`); other machines' transcripts (minis only here).
