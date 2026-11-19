# Epic 52: Factory control plane

`docs/factory/architecture.md` is the design (loopctl#1069); read it first. This file fixes the
story order, the names every story shares, what "done" means, and which test layer proves what.
Stories are numbered in the order they are built; never start a story before the ones in its
`dependencies` are pushed to the epic branch.

## Releases

The design's migration order (`docs/factory/architecture.md` section 8) is eleven releases, and
each ships alone, on its own epic branch, merged to master before the next release's branch is
cut. Every release's stories are written now, against today's code, so the whole epic can be
reviewed for contradictions at once (Mark, 2026-11-19). When a release's branch is cut, its
stories are re-grounded against the code the releases before it left behind: each `file:line`
is re-checked, and any story that a merged release made wrong is fixed before it is built.

Story ids are allocated in blocks per release; a release uses its block from the start, and an
unused tail stays unassigned.

| release | branch | PRD requirements | story block |
|---|---|---|---|
| 1 | `epic/factory-one-project-per-repo` | R5: one project and one channel per repo | 52.1-52.3 (below) |
| 2 | `epic/factory-r2-one-repo` | R10 part 1, R7, R4 self-modification: runner and chg in this repo, release manifest, end-to-end suite, no merge waits for a human | 52.4-52.12 |
| 3 | `epic/factory-r3-holders` | R1, R3 identity: work item, event log, holders | 52.13-52.20 |
| 4 | `epic/factory-r4-messaging` | R11: messaging and real-time delivery | 52.21-52.28 |
| 5 | `epic/factory-r5-visibility` | R4: visibility, intervention, no human waits | 52.29-52.35 |
| 6 | `epic/factory-r6-intake-recheck` | R6: intake re-check | 52.36-52.39 |
| 7 | `epic/factory-r7-move` | R1 checkpoints, R2, R3 move, host daemon | 52.40-52.49 |
| 8 | `epic/factory-r8-factory-pack` | R10 part 2: claude-config factory half, factory pack | 52.50-52.55 |
| 9 | `epic/factory-r9-fresh-ci` | R8: per-job scratch, warm snapshots | 52.56-52.59 |
| 10 | `epic/factory-r10-availability` | R9: second region, failover runbook | 52.60-52.63 |
| 11 | `epic/factory-r11-private` | R12: private repo, public MCP | 52.64-52.66 |

## Names every release from 2 on uses

These names cross releases. A story inside one release may add names of its own; those are
listed in that release's section below.

| thing | name | created by |
|---|---|---|
| runner source in this repo | `runner/` (the loopctl-runner mix project, history preserved) | release 2 |
| chg source in this repo | `chg/` (the Rust workspace `chg/cli` and the adapters `chg/adapters/*`, history preserved) | release 2 |
| release manifest | `release/manifest.toml`: one compatible version of server, runner, chg CLI, each chg adapter and MCP package; the factory pack joins it in release 8 | release 2 |
| end-to-end suite | `e2e/`, run by `mix e2e` against the sandbox repo `mkreyman/loopctl-e2e-sandbox`, nightly and on every factory release | release 2 |
| holder | table `holders`, schema `Loopctl.Holders.Holder`, context `Loopctl.Holders`: one row per session (`kind`: `runner_session`, `interactive`, `cloud`), with `agent_id`, `session_id`, `host`, `worktree`, `dispatch_id`, `lease_until`, `last_seen_at`, `ended_at`, `ended_reason` | release 3 |
| holder credential | an `api_keys` row at role `:agent` carrying `holder_id`, minted by `POST /api/v1/holders` (MCP `holder_register`); a runner session's holder is minted by placement instead, because the runner is the one server-attested source of its host. From release 4 the MCP server also writes it to `$HOME/.claude/loopctl-holders/<session_id>.key` (mode 0600) for the session's hooks | release 3, 4 |
| the claim's holder | `stories.assigned_holder_id`; a claim by any other holder is refused | release 3 |
| work-item event log | `story_stage_events`, extended with `actor_holder_id` and a required `reason`, and with event rows that are not stage changes (notes, moves, interventions) | release 3 |
| work-item notes | table `story_notes` (`section`: `plan`, `progress`, `decision`, `question`), written with work-item verbs, never with messages | release 3 |
| message | a `channel_posts` row with exactly one attachment: `story_id` (item thread), `to_holder_id` (DM) or `project_id` alone (channel) | release 4 |
| inbox cursor | `channel_cursors`, one row per holder and attachment | release 4 |
| messaging MCP tools | `message_send`, `inbox` | release 4 |
| visibility | `GET /api/v1/stories/:id/timeline` (MCP `work_item_timeline`), `GET /api/v1/factory/overview` (MCP `factory_overview`) | release 5 |
| intervention verbs | `POST /api/v1/stories/:id/{requeue,retriage,cancel,close}`, `POST /api/v1/projects/:id/intake/{pause,resume}`, each with an MCP tool `work_item_<verb>` / `intake_<verb>` | release 5 |
| checkpoint | table `story_checkpoints` (head, branch, bounded working-tree diff, fenced flag) | release 7 |
| move verb | `POST /api/v1/stories/:id/move` (MCP `work_item_move`) | release 7 |
| host daemon | the runner process (`runner/`), whose socket registration also reports capacity | releases 4, 7 |

## Epic-wide rules for releases 2-11

- **Refactor, never build beside** (PRD section 4). A story that adds a table, context, route or
  tool names the existing one that could not serve, and why. A story that replaces a mechanism
  deletes the old one in the same release, with its rows migrated, and lists the deleted
  modules in `technical_notes`.
- **Nothing waits for Mark** (PRD R4). No criterion may end in a state only a human leaves.
- **Every release extends the end-to-end suite** with the paths PRD R7 assigns it, in a story of
  that release.
- **Failure design for releases 2-11.** State lives in loopctl's Postgres (work items, the event
  log, notes, checkpoints, messages, cursors, holders); sessions, machines and git hold copies.
  Every write that can be retried carries an id and is idempotent. Holder claims are fenced by
  `claim_epoch`, as runner reports are today. A slow connection makes delivery late, never lost:
  reads are by cursor. Work runs in a holder's worktree, reached by holder identity through
  loopctl.
- **User journey for releases 2-11.** The one entry point for a session is the MCP tool set
  (its SessionStart hook reads the inbox); the one entry point for Mark is fleet_dash, which
  reads `factory_overview` and `work_item_timeline` and calls the intervention verbs with his
  user key. Every API operation has its MCP tool in the same commit.
- **Lanes for releases 2-11.** The shared-branch protocol below applies with that release's
  branch, except rule 4: from release 4 a keyed channel post is refused, so a lane reports its
  pushed story and SHA as a plain message on the loopctl channel (`message_send`), and before
  release 4 as an unkeyed `channel_post`.
- **Self-modification.** Every release from 2 on merges into loopctl itself, so release 2 deletes
  the self-deploy refusal and renames Gate B's `human_paths` to `independent_paths`, verified by a
  runner dispatch on another host. Every green merge still deploys (KB `4d3fd7bb`). No merge waits
  for a human from release 2 on.
- Each release's stories, names, hub files and API parity are in its own section after release 1's.

## Stories, in build order (release 1)

| # | story | depends on |
|---|---|---|
| 52.1 | A repo has one project: the server refuses a second | — |
| 52.2 | Merge a project into its repo's project | — |
| 52.3 | Delivery promotes the repo's project; the four duplicates are merged | 52.1, 52.2 |

Each story's `dependencies` field is the authority; this table mirrors it.

**Hub files**: each file many stories edit, with its owner story.

| hub file | owner story | other stories that edit it |
|---|---|---|
| `lib/loopctl/projects.ex` | 52.1 | 52.2 |
| `mcp-server/index.js`, `mcp-server/README.md` | 52.1 | 52.2 |
| `CHANGELOG.md` | 52.1 | 52.2, 52.3 |

## Lanes

From `lane_plan.py`: two lanes reach the critical path (52.1 or 52.2, then 52.3). 52.1 and 52.2
share no code, so they build side by side; 52.3 waits for both.

| lane | stories, in order | waits on another lane for |
|---|---|---|
| A: uniqueness | 52.1, 52.3 | 52.3 on 52.2 |
| B: merge | 52.2 | — |

How the lanes share one branch:

1. A story starts only when every story in its `dependencies` is on
   `origin/epic/factory-one-project-per-repo` (`git log --oneline origin/epic/<name> | grep -F
   " US-52.<n>: "`).
2. Commit the story with a subject that starts `US-52.<n>: `, then `git pull --no-rebase origin
   epic/factory-one-project-per-repo` before the push. A hub-file conflict keeps both sides'
   additions. Then compile and run the story's tests again, commit the merge, and push.
3. Name a migration only after `git fetch origin`, so two lanes never take one version.
4. After each push, post the story id and the pushed SHA on the loopctl channel under key
   `lane:loopctl:factory-r1-<lane>`.
5. A red push run is its pusher's to fix at once.

## Names every story uses

| thing | name |
|---|---|
| repo identity column | `projects.repo_key` (52.1): lowercased `host/owner/repo` from `repo_url`, nil without one |
| uniqueness index | `projects_tenant_repo_key_active_uidx` (52.1), partial on `status = 'active' AND repo_key IS NOT NULL` |
| refusal | `{:error, {:repo_has_project, existing_project_id}}` (52.1); HTTP `409` code `repo_already_has_project` with `existing_project_id` |
| merge function | `Loopctl.Projects.Merge.merge_into/4` (52.2, `lib/loopctl/projects/merge.ex`) |
| merge route | `POST /api/v1/projects/:id/merge_into` (52.2) |
| MCP tool | `merge_project` (52.2) |
| merge refusal | `{:error, {:merge_conflicts, [conflict]}}`; HTTP `409` code `merge_conflicts` |
| audit actions | `merged_into` on the source, `kind_promoted` on a promoted project |
| runbook | `docs/factory/runbooks/merge-duplicate-projects.md` (52.3) |

## Failure design

1. **What happens during a partition?** Everything runs inside loopctl against its own
   Postgres. An MCP client that loses the connection mid-merge gets no answer; the merge is one
   transaction, so it either committed or wrote nothing, and a retry reads which.
2. **Where does the state live?** `projects` is the one record of which project owns a repo,
   decided by `repo_key` under a unique index; no client hook and no channel post holds it. A
   merged project's rows live under the target's id; the source row stays, archived, with
   `metadata.merged_into`.
3. **Can a retry do the same thing twice?** A retried create meets the unique index and gets the
   same 409 naming the existing project. A retried merge finds the source already archived with
   `merged_into` = target and answers the first merge's result without moving anything.
4. **What happens when the connection is slow?** A merge moves at most a few thousand rows per
   project today (chg-delivery is the largest); it runs on `AdminRepo` inside one transaction
   with the repo's default timeout, and a dry run reports the counts first.
5. **Where is our unit of work running, and how do we reach it?** Inline, in the request
   process; nothing is queued.

## User journey

1. **Start and end.** A session holds a repo URL (`git remote get-url origin`) and ends holding
   the one project id every tool uses for that repo.
2. **Old way vs new way.** Today a repo that needs delivery gets a second, `repo_url`-less work
   project beside its kb scope. After this release the kb scope itself becomes the work project
   when an intake source is enrolled on it (52.3), and creating a second project is refused with
   the first one's id (52.1). The one entry point stays `resolve_project({repo_url})`.
3. **Their words.** The 409 message names the existing project by slug and id, and says to use
   it.

**API parity.**

| action | API operation | MCP tool | story |
|---|---|---|---|
| create a project / kb scope (refused on a taken repo) | `POST /api/v1/projects`, `POST /api/v1/kb-scopes` | `create_project`, `create_kb_scope` | 52.1 |
| change a project's repo (refused on a taken repo) | `PATCH /api/v1/projects/:id` | `update_project` | 52.1 |
| enrol an intake source (refused onto another repo's project; promotes a kb scope) | `POST /api/v1/intake/sources` | `intake_source_enroll` | 52.1, 52.3 |
| merge a project into another | `POST /api/v1/projects/:id/merge_into` | `merge_project` | 52.2 |

## Design coverage

No screen.

## What "done" means, for every story

1. Every acceptance criterion is named by a test case's `verifies`, and that test passes.
2. Every context test file has a tenant isolation case (CLAUDE.md, Test Conventions rule 8).
3. Every test file is `async: true`; no `Application.put_env`.
4. A new endpoint ships its MCP tool, its `mcp-server/README.md` row and a wiring test in the
   same commit (CLAUDE.md, "An operator-facing endpoint is NOT DONE until an MCP tool calls it").
5. A new 4xx is in the endpoint's `operation/2` spec, and in `CHANGELOG.md` when it changes an
   existing endpoint's behaviour.
6. No role gate is weakened (CLAUDE.md, Security & Trust Model), except where the PRD changes one
   on purpose (R4: resolve and the intervention verbs open to `role: :agent`); that story edits
   CLAUDE.md's trust-model section in the same commit.

## Which layer proves what

| what | layer |
|---|---|
| repo-key normalization | unit |
| uniqueness, merge, promotion, isolation, audit | context test (DataCase) |
| status codes, error bodies, role gates | controller test (ConnCase) |
| MCP tool request shape and wiring | `node --test` in `mcp-server/test` |

## Release 2: one repo for the factory

| # | story | depends on |
|---|---|---|
| 52.4 | loopctl-runner moves into runner/ with its history; reads the one runner contract | — |
| 52.5 | chg moves into chg/; everything that names chg's repo follows it | 52.4 |
| 52.6 | CI and the commit gate judge runner/ and chg/, each only when it changed | 52.4, 52.5 |
| 52.7 | The release manifest names one compatible set; each set is tagged and published | 52.4, 52.5 |
| 52.8 | Every factory client reports its version; loopctl refuses one older than the set allows | 52.7 |
| 52.9 | mix e2e drives one issue through the real factory on the sandbox repo, nightly | 52.6, 52.7 |
| 52.10 | One command rolls the fleet to the set, verifies each machine, rolls back on a red e2e | 52.8, 52.9 |
| 52.11 | The old repos are archived; their loopctl records move to the loopctl project | 52.4, 52.5, 52.10 |
| 52.12 | Gate B human_paths become independent_paths; the self-deploy refusal goes; a self-modifying merge is verified by a runner on another host and reconciled after the restart | 52.9 |

**Names it adds:**
- **Imports:** `release/import-history.sh` and `release/imports.toml`.
- **CI:** `.github/scripts/changed-areas.sh` (areas `server`, `runner`, `chg`, `e2e`) and the workflows `runner-ci.yml`, `chg-ci.yml`, `factory-release.yml` and `e2e.yml`.
- **Release set:**
  - `Loopctl.ReleaseSet` and `mix loopctl.release_set (--check|--bump)`;
  - the manifest table `[components.<name>]` (with `version`, `minimum` and `source`) and the `[retired]` repo list;
  - the tag `factory-<set>`.
- **Client versions:**
  - the header `x-loopctl-client: <component>/<version>`, read by `LoopctlWeb.Plugs.ClientVersion`;
  - the refusal `incompatible_client_version` (HTTP 426, and the join reason);
  - the join field `runner_version` (runner contract 1.34.0) and the join reply `release_set`.
- **Fleet rollout:** `release/install-machine.sh`, `release/rollout.sh`, `release/retire-repo.sh` and `~/.local/share/loopctl-factory/{sets/<n>,current}`.
- **E2E:** `e2e/sandbox/provision.sh`. `mix e2e` (black-box) is not the existing `mix test.e2e` alias (`mix.exs:273`, in-process).

**Hub files, with their owner story:**

| hub file | owner story | other stories that edit it |
|---|---|---|
| `priv/runner_contract/v1.json`, `runner_contract.ex` | 52.4 | 52.8 |
| `release/imports.toml` | 52.4 | 52.5, 52.11 |
| `release/manifest.toml` | 52.7 | 52.11 |
| `.github/workflows/ci.yml` | 52.6 | 52.7 |
| `.githooks/pre-commit` | 52.6 | — |
| `router.ex` | 52.8 | — |
| `well_known_controller.ex` | 52.7 | — |
| `mix.exs` aliases | 52.7 | 52.9 |
| `release/install-machine.sh` | 52.10 | 52.11 |

**API parity:**

| action | API | MCP tool | story |
|---|---|---|---|
| find a story by issue | GET /api/v1/projects/:id/stories?issue_number= | list_stories (issue_number) | 52.9 |
| see each runner's version | GET /api/v1/runners/pool (runner_version) | runner_pool | 52.8 |
| read the release set | GET /.well-known/loopctl (release) | mcp_version | 52.7 |

## Release 3: every session is a holder

| # | story | depends on |
|---|---|---|
| 52.13 | A session registers as a holder and gets its own credential | — |
| 52.14 | A claim names its holder; a second holder's claim is refused (closes loopctl#707) | 52.13 |
| 52.15 | Runner sessions are holders; verify separates holders, not agents | 52.13, 52.14 |
| 52.16 | Event log: every event names its holder and its reason | 52.13, 52.14 |
| 52.17 | Work item notes; orchestrator_state folded in and deleted | 52.13, 52.14, 52.16 |
| 52.18 | Interactive work on a branch becomes a work item | 52.13, 52.14, 52.16 |
| 52.19 | Session holder lease measured and set | 52.13, 52.14, 52.16 |
| 52.20 | E2E: two sessions on one machine and one repo never collide | 52.13-52.19 |

**Names it adds:**
- **Holders:**
  - columns `holders.dispatch_id`, `lease_until`, `ended_reason`;
  - `api_keys.holder_id`, with the index `api_keys_one_live_key_per_holder_idx`;
  - `stories.assigned_holder_id` and `channel_claims.claimant_holder_id`.

  Runner-session holders are created by placement (`placement.ex:1216`), not by `POST /api/v1/holders`, because the runner is the only server-attested source of a session's host.
- **Event log:**
  - `story_stage_events.actor_holder_id`, `.reason` and `.idempotency_key`;
  - the events `claimed`, `released` and `note_written`;
  - `Stages.record_item_event/4`.
- **Notes and work items:** `story_notes`, the context `Loopctl.WorkItems`, `Stories.next_number/2` and `Stages.open_started_in_tenant_transaction/4`.
- **Lease:** `HOLDER_HEARTBEAT_SECONDS`, `HOLDER_LEASE_SECONDS`, `mix loopctl.session_gaps` and `docs/factory/measurements/session-holder-lease.md`.
- **Error codes:** `held_by_other_holder`, `holder_lease_expired`, `branch_held`, `holder_credential_required` and `no_target_epic`.
- **Runner contract:** version 1.34.0.

**Hub files, with their owner story:**

| hub file | owner story | other stories that edit it |
|---|---|---|
| `progress.ex` | 52.14 | 52.15, 52.16, 52.19 |
| `stages.ex` | 52.16 | 52.18 |
| `placement.ex`, `runner_contract.ex` | 52.15 | — |
| `mcp-server/index.js` | 52.13 | 52.14, 52.17, 52.18, 52.19 |
| `router.ex` | 52.13 | 52.17, 52.18 |
| CLAUDE.md custody and role sections | 52.15, 52.17, 52.18 | — |

**API parity:**

| action | API | MCP tool | story |
|---|---|---|---|
| register | POST /api/v1/holders | holder_register | 52.13 |
| heartbeat | POST /api/v1/holders/:id/heartbeat | holder_heartbeat | 52.13 |
| end | POST /api/v1/holders/:id/end | holder_end | 52.13 |
| write a note | POST /api/v1/stories/:id/notes | work_item_note | 52.17 |
| list notes | GET /api/v1/stories/:id/notes | work_item_notes | 52.17 |
| open an ad-hoc item | POST /api/v1/work_items | work_item_open | 52.18 |
| (removed) | /api/v1/orchestrator/state (3 routes) | none existed | 52.17 |

## Release 4: messaging and real-time delivery

| # | story | depends on |
|---|---|---|
| 52.21 | Advisory soft-locks move out of channel_posts into channel_locks | — |
| 52.22 | A channel post becomes a message with exactly one attachment and retention by attachment | 52.21 |
| 52.23 | message_send: one write path for thread, DM and channel messages | 52.22 |
| 52.24 | inbox: a session reads its DMs, its items' threads and its channel by cursor | 52.22 |
| 52.25 | A DM never outlives its session | 52.23, 52.24 |
| 52.26 | No per-session rate cap; one tenant-wide, cluster-global limit | — |
| 52.27 | Real-time delivery: subscribers see a message on commit, and a machine's runner wakes its idle sessions | 52.23, 52.24 |
| 52.28 | Sessions read their inbox at start and at each tool round; the old cross-machine paths are deleted | 52.24, 52.25, 52.27 |

**Names it adds:**
- **Locks (52.21):** the table `channel_locks`, the schema `Loopctl.Coordination.ChannelLock` and the index `channel_locks_slot_uidx`.
- **Messages:** `Loopctl.Coordination.Messages`, with `insert/2`, `send/4`, `inbox/3`, `ack/3`, `items_held_by/2` and `on_holder_ended/3`.
- **channel_posts (52.22):** the columns `story_id`, `to_holder_id`, `author_holder_id` and `attachment_seq`; the check `channel_posts_one_attachment`; the index `channel_posts_attachment_seq_uidx`.
- **Cursors:** the schema `Loopctl.Coordination.InboxCursor` on the table `channel_cursors`, with the index `channel_cursors_holder_attachment_uidx`. The name `ChannelCursor` is already the keyset codec's.
- **Tenant settings:** `channel_message_retention_days` (default 7) and `rate_limit_tenant_requests_per_minute` (default 900).
- **Error codes:** `exactly_one_attachment`, `keyed_slot_retired`, `ack_beyond_end`, `not_in_inbox`, `holder_credential_required` and `session_ended` (with `held_items`).
- **Real-time:**
  - `LoopctlWeb.MessageSocket` at `/socket/messages`;
  - `LoopctlWeb.MessageChannel` on the topic `messages:tenant`;
  - the runner event `inbox_wake` and `LoopctlRunner.SessionWake`;
  - `docs/factory/measurements/idle-session-wake.md`.
- **Session side:** the hook `inbox-on-tool.sh`, `INBOX_POLL_SECONDS`, and the holder credential file `$HOME/.claude/loopctl-holders/<session_id>.key`.

**Hub files, with their owner story:**

| hub file | owner story | other stories that edit it |
|---|---|---|
| `coordination.ex` | 52.21 | 52.22, 52.23 |
| `projects/merge.ex` | 52.21 | 52.22, 52.24 |
| `channel_post_controller.ex` | 52.22 | 52.23, 52.26 |
| `mcp-server/index.js`, `mcp-server/README.md` | 52.23 | 52.24, 52.25, 52.28 |
| `router.ex` | 52.23 | 52.24 |
| `runner_contract.ex` | 52.27 | — |
| `CHANGELOG.md` | 52.21 | every other story |

**API parity:**

| action | API | MCP tool | story |
|---|---|---|---|
| send a message | POST /api/v1/messages | message_send | 52.23 |
| read the inbox | GET /api/v1/inbox | inbox | 52.24 |
| acknowledge what was read | POST /api/v1/inbox/ack | inbox (`ack` argument) | 52.24 |
| subscribe (fleet_dash) | /socket/messages, topic messages:tenant | none: a machine client | 52.27 |

## Release 5: visibility, interventions, holder-resolved escalation

| # | story | depends on |
|---|---|---|
| 52.29 | Work-item timeline | — |
| 52.30 | Factory overview | — |
| 52.31 | Holders resolve escalations; self-resolution is refused | — |
| 52.32 | Intervention verbs: requeue, retriage, cancel, close | 52.31 |
| 52.33 | Intake pause and resume | 52.30 |
| 52.34 | Stronger-holder escalation sweep | 52.31, 52.32 |
| 52.35 | E2E: an escalation is resolved by another holder | 52.29, 52.30, 52.31 |

**Names it adds:**
- **Modules:**
  - `Loopctl.Delivery.Timeline`, `Overview`, `Interventions` and `EscalationSweep`;
  - `Loopctl.Workers.EscalationSweepWorker`, which replaces `EscalationDigestWorker`.
- **Stage machine:**
  - the edges `:holder_resolution`, `:retriage`, `:cancelled`, `:closed` and `:holders_exhausted`;
  - the release cause `:intervention`.
- **Error codes:** `self_resolve_blocked`, `holder_required`, `review_missing_unreviewed`, `self_intervention_blocked`, `not_requeueable`, `already_landed`, `no_intake_source` and `independent_verification`.
- **Columns and indexes:**
  - `intake_sources.paused_at` and `paused_reason`;
  - `intervention_id`, with the index `story_stage_events_intervention_uidx`;
  - the index `story_stage_events_tenant_to_stage_inserted_idx`.
- **Config and payloads:** `STRONGER_HOLDER_MODEL`, Gate B document v2 (`independent_paths`, `independent_checks`), the Gate B outcome `:independent` and the dispatch payload field `model`.

**Deleted:** `StoryHistoryController` and the `/stories/:id/history` route, the digest functions in `EscalationInbox`, and `EscalationDigestWorker`.

**Hub files, with their owner story:**

| hub file | owner story | other stories that edit it |
|---|---|---|
| `router.ex` | 52.29 | 52.30, 52.32, 52.33 |
| `mcp-server/index.js`, `mcp-server/README.md` | 52.29 | 52.30-52.33 |
| `stage_machine.ex` | 52.31 | 52.32, 52.34 |
| `escalations.ex` | 52.31 | 52.32 |
| `CHANGELOG.md` | 52.31 | 52.32-52.34 |
| `docs/agent-delivery-loop.md` | 52.31 | 52.34 |
| `FLY_SECRETS.md` | 52.34 | — |

**API parity:**

| action | API | MCP tool | story |
|---|---|---|---|
| read a timeline | GET /api/v1/stories/:id/timeline | work_item_timeline | 52.29 |
| read the overview | GET /api/v1/factory/overview | factory_overview | 52.30 |
| resolve an escalation | POST /api/v1/stories/:id/stage/resolve | resolve_escalation | 52.31 |
| requeue, retriage, cancel or close | POST /api/v1/stories/:id/<verb> | work_item_<verb> | 52.32 |
| pause or resume intake | POST /api/v1/projects/:id/intake/<verb> | intake_<verb> | 52.33 |

## Release 6: intake re-check

| # | story | depends on |
|---|---|---|
| 52.36 | Intake re-check; an already-fixed issue closes with its evidence | 52.33 |
| 52.37 | Duplicate and stale reproductions | 52.36 |
| 52.38 | recheck@1, with its findings passed to triage | 52.29, 52.36, 52.37 |
| 52.39 | E2E: an already-fixed issue never reaches triage | 52.29, 52.33, 52.36 |

**Names it adds:**
- **Modules and events:** `Loopctl.Delivery.IntakeRecheck`, the event `rechecked`, and the candidate predicates `:rechecked` and `:intake_not_paused`.
- **Stage machine:** the edges `:recheck_fixed`, `:recheck_duplicate` and `:recheck_stale`; the verdicts `:already_fixed`, `:duplicate` and `:no_longer_reproduces`.
- **Evidence:** `issue_closures.evidence` and `PullRequestSource.closing_references/3`.
- **Dispatch:** the spec `recheck@1` (message `recheck_result`, payload `:recheck_payload`), with `RECHECK_WALL_CLOCK_SECONDS` and `RECHECK_MAX_TURNS`.

**Hub files, with their owner story:**

| hub file | owner story | other stories that edit it |
|---|---|---|
| `stage_machine.ex`, `resolution.ex` | 52.36 | 52.37 |
| `candidates.ex`, `triage_v1.ex` | 52.33 | 52.36 |
| `dispatcher.ex`, `spec.ex` | 52.38 | — |
| `issue_closer.ex` | 52.36 | — |

**API parity:** none new.

## Release 7: checkpoints, the move verb, the interactive boundary and the host daemon

| # | story | depends on |
|---|---|---|
| 52.40 | Measure the checkpoint diff bound and the interactive-move grant | — |
| 52.41 | A holder checkpoints its item: head, branch, bounded diff | 52.40 |
| 52.42 | A late holder's checkpoint is kept fenced | 52.41 |
| 52.43 | The move verb: checkpoint, release, reserve for the target | 52.41 |
| 52.44 | A runner session hands over mid-stage; the target machine resumes | 52.42, 52.43 |
| 52.45 | Only Mark crosses the interactive boundary (user key or one-shot grant) | 52.40, 52.43 |
| 52.46 | Interactive work is a work item: start, pull, never taken by the loop | 52.42, 52.44, 52.45 |
| 52.47 | Host daemon capacity reports; placement by readiness and load | — |
| 52.48 | The host daemon owns the GitHub Actions runner pool | 52.47 |
| 52.49 | Handoffs and channel_claims deleted; open rows become work items | 52.41, 52.45, 52.46 |

**Names it adds:**
- **Checkpoints:** `Loopctl.Delivery.Checkpoints`, the schema `StoryCheckpoint` on `story_checkpoints`, and `mcp-server/lib/worktree-diff.js`.
- **Moves:**
  - `Loopctl.Delivery.Moves`, `story_stages.pending_move` and `Loopctl.Workers.MoveDeadlineWorker`;
  - the stage-machine edge and release cause `:moved`, the candidate predicate `:not_move_reserved` and the refusal `reserved_for_move`;
  - `MOVE_RELEASE_SECONDS` (600) and `MOVE_PULL_SECONDS` (1800).
- **Interactive boundary:** the `capability_tokens` type `move_grant`, the hook `factory/hooks/work-item-move-grant.sh`, and the command `factory/commands/work-item-move.md`.
- **Host daemon:** `LoopctlRunner.HostReport`, `LoopctlRunner.CiPool`, `runner/ci/` and `PLACEMENT_MAX_LOAD_PER_CORE` (1.0).
- **Handoff migration:** `Loopctl.Factory.MigrateHandoffs`.
- **Measurements:** `docs/factory/measurements/release-7.md` (`bound_bytes`, `grant_rule`).

**Hub files, with their owner story:**

| hub file | owner story | other stories that edit it |
|---|---|---|
| `runner_contract.ex`, `runner_channel.ex` | 52.44 | 52.47 |
| `stages.ex`, `stage_machine.ex` | 52.43 | — |
| `progress.ex` (reclaim) | 52.46 | — |
| `selection.ex` | 52.47 | — |
| `mcp-server/index.js` | 52.41 | 52.42-52.46 add tools, 52.49 removes six |
| `router.ex` | 52.41 | 52.43, 52.45, 52.46, 52.49 |

**API parity:**

| action | API | MCP tool | story |
|---|---|---|---|
| write or list checkpoints | POST/GET /api/v1/stories/:id/checkpoints | work_item_checkpoint, work_item_checkpoints | 52.41 |
| resolve a fenced checkpoint | POST /api/v1/stories/:id/checkpoints/:id/resolve | work_item_checkpoint_resolve | 52.42 |
| move an item | POST /api/v1/stories/:id/move | work_item_move | 52.43 |
| mint a move grant | POST /api/v1/move_grants | none: its only caller is the hook | 52.45 |
| pull an item into a session | GET checkpoints, then claim | work_item_pull (client-side) | 52.46 |

## Release 8: claude-config's factory half and the factory pack

| # | story | depends on |
|---|---|---|
| 52.50 | claude-config's factory half moves into factory/ with its history, traced item by item | — |
| 52.51 | Factory policy: every delivery-loop rule value decided once, on the server | — |
| 52.52 | The factory pack: a plugin marketplace built from factory/src and the server policy | 52.50, 52.51 |
| 52.53 | Review rounds are counted on the work item; the counter plugin becomes a thin call | 52.50, 52.51 |
| 52.54 | claude-config installs the pack and deletes what moved and what retired | 52.52, 52.53 |
| 52.55 | The e2e suite runs on the pack alone and proves a rule change ships from this repo | 52.52, 52.53 |

**Names it adds:**
- **Inventory (52.50):** `factory/src/`, `factory/inventory.toml` (fates `pack`, `generated`, `thin_call`, `retired`) and `mix factory.inventory --check`.
- **Policy (52.51):** `factory/policy.toml`, `Loopctl.Factory.Policy` and `GET /api/v1/factory/policy`.
- **Pack (52.52):**
  - `mix factory.pack [--check]`;
  - `factory/pack/` (the plugin `loopctl-factory`) and `factory/pack-review-rounds/`;
  - the root `.claude-plugin/marketplace.json` (the marketplace `loopctl-factory`);
  - `hooks/lib/policy.sh` and `hooks/lib/loopctl.sh`;
  - the stable link `~/.claude/factory`.
- **Review rounds (52.53):** `Loopctl.Factory.ReviewRounds`, the routes `/api/v1/review_rounds` and `/api/v1/review_rounds/:round_id/void`, and the error codes `review_ceiling_reached`, `review_round_not_found`, `attestation_reason_required` and `work_item_not_found`.
- **E2E (52.55):** `E2E.ConfigDir`, `E2E.WriteScope` and `FACTORY_POLICY_PATH`.

**E2E paths:** `policy_change_ships`, `review_count_moves` and `previous_pack`. They are R10's done test.

**Hub files, with their owner story:**

| hub file | owner story | other stories that edit it |
|---|---|---|
| `mcp-server/index.js`, `mcp-server/README.md` | 52.51 | 52.53 |
| `.github/workflows/ci.yml` | 52.50 | 52.52 |
| `CHANGELOG.md` | 52.51 | 52.53 |

**API parity:**

| action | API | MCP tool | story |
|---|---|---|---|
| read the factory policy | GET /api/v1/factory/policy | factory_policy | 52.51 |
| open a review round | POST /api/v1/review_rounds | review_round_open | 52.53 |
| void a review round | POST /api/v1/review_rounds/:round_id/void | review_round_void | 52.53 |
| read review rounds | GET /api/v1/review_rounds | review_round_status | 52.53 |

## Release 9: fresh CI jobs and warm snapshots

| # | story | depends on |
|---|---|---|
| 52.56 | A content-addressed chg snapshot, built in the job's own tree | — |
| 52.57 | Any machine fetches a snapshot through URLs loopctl signs | 52.56 |
| 52.58 | Each self-hosted job gets a fresh tree, its own TMPDIR and its own database, warmed from the snapshot | 52.56, 52.57 |
| 52.59 | E2E: a killed job leaves nothing behind; a snapshot serves another host | 52.58 |

**Names it adds:**
- `chg snapshot key|build --here|push|fetch`;
- `POST /api/v1/projects/:id/snapshots/urls` (MCP `snapshot_urls`) and `Loopctl.Snapshots.Signer`;
- `SNAPSHOT_BUCKET`;
- the CI image `ghcr.io/mkreyman/loopctl-ci`;
- the per-job database `_ci_<run_id>_<run_attempt>_<job>`.

**E2E paths:** `ci_killed_job`, `ci_snapshot_unreachable` and `ci_cross_host_snapshot`.

**Hub file:** `ci.yml`, owned by 52.58.

## Release 10: availability

| # | story | depends on |
|---|---|---|
| 52.60 | lax plus den, every machine kept running | — |
| 52.61 | Offline events accepted by idempotent id, late ones fenced | — |
| 52.62 | A holder works through an outage and replays its journal | 52.61 |
| 52.63 | Weekly restore drill into den, failover runbook, external monitor | 52.60 |

**Names it adds:**
- `deploy/regions.txt` and `deploy/ensure-regions.sh`;
- `POST /api/v1/holders/:id/replay` (MCP `holder_replay`);
- the stage event `fenced_replay`;
- `mcp-server/lib/holder-journal.js`;
- `docs/factory/runbooks/failover.md`;
- the workflows `uptime.yml` and `restore-drill.yml`.

**E2E path:** "loopctl unreachable mid-run", tested by TC-52.62.6.

**Hub files:** `fly.toml` and `ci.yml`, both owned by 52.60.

## Release 11: private repo, public MCP

| # | story | depends on |
|---|---|---|
| 52.64 | Each GitHub-hosted job moved to fleet-ci or measured against the free allowance | — |
| 52.65 | The npm README carries MCP usage; the app serves its own docs | — |
| 52.66 | Installers fetch artifacts with a token; the repo is flipped private by a checked script | 52.64, 52.65 |

**Names it adds:** `release/fetch-artifact.sh`, `LOOPCTL_ARTIFACT_TOKEN`, `scripts/factory/go-private.sh` and `GET /docs/delivery-loop`.

It adds no `/api/v1` route and no e2e path.
