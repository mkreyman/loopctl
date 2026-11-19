# Epic 52: Factory control plane

`docs/factory/architecture.md` is the design (loopctl#1069); read it first. This file fixes the
story order, the names every story shares, what "done" means, and which test layer proves what.
Stories are numbered in the order they are built; never start a story before the ones in its
`dependencies` are pushed to the epic branch.

## Releases

The design's migration order is eight steps, and each ships alone. Each step is a release of
this epic on its own epic branch, merged to master before the next release's branch is cut. A
release's stories are written when its branch is cut, because each release is grounded against
the code the one before it leaves behind.

| release | branch | design step | stories |
|---|---|---|---|
| 1 | `epic/factory-one-project-per-repo` | R5: one project and one channel per repo | 52.1-52.3 (below) |
| 2 | written at its cut | R1 + R4 data model: work item and event log | — |
| 3 | written at its cut | R4 views and intervention verbs, human-only gates removed | — |
| 4 | written at its cut | R6 intake re-check | — |
| 5 | written at its cut | R10 part 1 + R7: runner and chg in this repo, release set, end-to-end suite | — |
| 6 | written at its cut | R2 + R3: checkpoint, move verb, host agent | — |
| 7 | written at its cut | R10 part 2: claude-config factory pack, hooks from policy | — |
| 8 | written at its cut | R8 + R9: per-job scratch, second region, failover runbook | — |

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
6. No role gate is weakened (CLAUDE.md, Security & Trust Model).

## Which layer proves what

| what | layer |
|---|---|
| repo-key normalization | unit |
| uniqueness, merge, promotion, isolation, audit | context test (DataCase) |
| status codes, error bodies, role gates | controller test (ConnCase) |
| MCP tool request shape and wiring | `node --test` in `mcp-server/test` |
