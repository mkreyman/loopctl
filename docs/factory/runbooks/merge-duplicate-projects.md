# Runbook: merge a repo's duplicate projects

A repo has one project (US-52.1). Before that rule, four repos grew a second one: a kb scope
that holds the `repo_url`, and a work project (`*-delivery`, `infra-pilot`) that carries the
intake source, the stories and the escalation handoffs. A session in the repo resolves to the
kb scope, so the work project's channel was one it could not claim on (loopctl#1067).

This runbook merges each work project INTO the kb scope with `merge_project` (US-52.2). The
kb scope keeps its id, which is the channel id sessions already read, and becomes a work
project because the source was one.

## Who runs it

A fleet session with `LOOPCTL_USER_KEY` (a `:user` key no dispatch minted) on the
human-anchored tenant. `merge_project` sends that key verbatim. The MCP package must be
3.19.0 or later (`mcp_version`).

## The four pairs (ids as of 2026-11-19)

| Repo | Source (merged away) | Target (kept) |
|------|----------------------|---------------|
| chg | `chg-delivery` b5343742 | `chg` eba0b4df |
| ads_for_care | `ads_for_care-delivery` 329be116 | `ads_for_care` 9fe72eaf |
| claude-config | `claude-config-delivery` 0fc4aa3c | `claude-config` 478f72ab |
| infra | `infra-pilot` 2b124878 | `infra` 0917eacf |

Read the full ids with `list_projects` before running; the table carries prefixes only.

## Steps, per pair

1. **Dry run.** `merge_project({project_id: <source>, target_project_id: <target>, dry_run: true})`.
   Read `counts` (rows that will move, by table) and `conflicts`.
2. **Conflicts.** Each conflict names a table, the unique index, and both row ids. Resolve it
   on the row the source holds (renumber a story or epic, release a claim, delete a duplicate
   orchestrator state), then dry-run again. Never merge with a conflict open: the call refuses
   409 `merge_conflicts` and moves nothing.
3. **Merge.** The same call without `dry_run`. The result carries `counts` and
   `promoted: true`.
4. **Checks.**
   - `resolve_project({repo_url})` for the repo returns the target, `kind: work`.
   - `intake_source_list` shows the repo's source with `project_id` = the target.
   - `list_projects` shows the source archived.
   - `channel_handoffs` on the target lists the open escalation handoffs. A handoff whose key
     still names the source's slug (`handoff:chg-delivery:...`) is closed and re-posted under
     the target's repo name by the next escalation sweep (within five minutes, US-52.3).
5. **Record** the result below: the date, the counts, and anything that needed resolving.

A repeat call on a merged pair answers `already_merged: true` and moves nothing, so a run
interrupted after the merge is safe to repeat.

## What a merge does not move

`audit_log` and `search_events` keep naming the source project: the audit log is append-only
and hash-chained, and search telemetry records where a search ran. The archived source row
stays, with `metadata.merged_into` naming the target.

## Results

| Pair | Date | Result |
|------|------|--------|
| chg-delivery into chg | | not yet run |
| ads_for_care-delivery into ads_for_care | | not yet run |
| claude-config-delivery into claude-config | | not yet run |
| infra-pilot into infra | | not yet run |
