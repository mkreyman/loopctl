# The outbox to loopctl

loopctl holds chg's record (design §5; loopctl Epic 47 and Epic 50): the ledger of verdicts, review rounds and flaky tests from every machine, each change's event log, and review custody. Every machine sends its own part through a local outbox. loopctl receives and never calls back, so its being slow or down costs freshness and never a push.

## Setup, per machine

1. An operator enrolls the repo's loopctl intake source in `chg` mode (`intake_source_enroll`, loopctl US-47.2), which returns the source id and its `change_events_secret` once, and sets the source's `chg_root_dispatch_id`.
2. The secret goes in a file only its owner can read, and the source in `~/.chg/loopctl.toml`:

   ```toml
   # url = "https://loopctl.com"     # the default; CHG_LOOPCTL_URL overrides it
   [[source]]
   repo = "mkreyman/home_care_billing"
   source_id = "<uuid>"
   secret_file = "/home/mkreyman/.chg/secrets/home_care_billing"   # chmod 600
   ```

3. `bin/chg-outbox-cron.sh --install` adds a crontab line running `chg outbox send --quiet` every 10 minutes (`--remove`, `--show`).

With no `~/.chg/loopctl.toml` nothing is sent and nothing fails.

## What is sent

| file | rows | written by |
|---|---|---|
| `~/.chg/shadow/<key>.jsonl` | `chg` and `gate` rows (docs/shadow.md) | `chg check`, `chg shadow record` |
| `~/.chg/outbox/<key>.review_round.jsonl` | `review_round`: one per review launch on a branch linked to a PR, with `pr`, `branch`, `round_id`, `via`, `name`, `review_kind`, `head`; `review_round_void` when that launch was later voided | each `chg outbox send`, from review-round-counter's store (`~/.claude/plugins/store/review-round-counter_*.json`; `CHG_RRC_STORE` overrides) |
| `~/.chg/outbox/<key>.flaky.jsonl` | `flaky`: `test`, `run_id` | `chg flaky` |
| `refs/chg/<change>/events` on the remote | change events | `chg event emit` |

`<key>` is the repo's name (`home_care_billing`). Each ledger row is sent with `repo` set to the source's `owner/name`; loopctl rejects a row naming another repository. loopctl also refuses a row over 16 KB as `invalid_row`. A `chg` row that selected thousands of tests is that large, so on the wire its `selected` list becomes `selected_count`. loopctl does not read the list, and the shadow log keeps it. A row still over the cap (a run where thousands of tests failed) keeps on the wire the failure names loopctl's `Findings` keeps (non-empty names or `id`s, at most 200 characters, unique, sorted, the first 50), plus `failures_count` and `failures_sha256`. The second is the sha256 of the full list in the form loopctl's `failures_digest` hashes. loopctl fingerprints a selection miss on `failures_sha256` when a row carries it (loopctl#1055), so two such runs on one sha that differ only past the 50th failure stay two findings.

`chg outbox send` sends each file from the byte offset loopctl last answered for (`~/.chg/outbox/state.json`), in batches of up to 500 rows and 900 KB, at most 40 batches per file per run. The first send of a file is the backfill of everything already in it. A line still being written (no newline yet) waits for the next run. A row loopctl rejects (`invalid_row`, `repo_mismatch`), or one that is not JSON, is written to `~/.chg/outbox/rejected.jsonl` and never blocks the rows after it. loopctl keys a row on `(source, host, sha256 of the row)`, so resending is safe: a crash between loopctl's answer and the saved offset resends the batch, and loopctl counts it as duplicates.

A failure (network, 5xx, 429, a 401) stops that repo for the run and backs it off: 30 s, doubling to 1 h. `--force` ignores the backoff. `--from-start` sends every file again from its first byte, whole, in one run, without the batch cap. Use it after a sender fix, so rows loopctl refused before are offered again; loopctl counts the rest as duplicates. It never saves an offset below the one loopctl had already answered for, so a replay cut short leaves no delivered row counted as unsent. A 401 means the source id, the secret, the source's chg root or this machine's clock (5-minute window) is wrong.

Every writer starts a detached `chg outbox send --quiet` after writing (`CHG_OUTBOX_NO_KICK` turns that off); its output goes to `~/.chg/outbox/send.log`. One send runs at a time per machine; a second exits at once.

`chg outbox status` prints, per repo, the unsent rows, the oldest one's age, the changes with undelivered events and the backoff, and exits 1 when a row has waited over 24 hours. `chg doctor` prints the same line for its repo and fails on the same condition.

## Change events

loopctl applies a change's events in `event_seq` order, from 1 with no gaps, and holds any that arrive ahead of a gap. A change's events can come from different machines, so the seq is allocated on the remote: `refs/chg/<change>/events` is a chain of commits, one per event, each holding `event.json`, the exact body loopctl receives.

```
chg event emit --change C --kind submitted --revision 1 --sha <40 hex> [--data '{...}'] [--repo R] [--remote origin]
```

reads the remote tip, writes the next commit and pushes it without force. The push is accepted only as a fast-forward, so two machines racing for one seq cannot both win; the loser re-reads and takes the next (up to 8 tries). The push skips the repo's pre-push hook, because the ref holds an event record, not code. It prints `{change_id, event_seq, commit, repo}` and queues the change in `~/.chg/outbox/events/<key>/`.

The sender reads the change's cursor (`GET /api/v1/change_events/<source>/cursor`), then posts every event above `applied_through`, read from the chain, until loopctl has applied the tip. Because the events are on the remote, any clone can fill a gap: `chg event sync --change C` queues the change on this machine. That is the answer to loopctl's gap alert.

A change id is `[A-Za-z0-9._-]`, 1-128 bytes (it is a ref component and a file name).

## Review keys

```
chg review-dispatch --change C --revision N [--repo R]
```

asks loopctl (US-50.3) for the key a review of that revision records its verdict with, and prints `{dispatch_id, api_key, expires_at}`. The key is shown once; give it to the review job and nowhere else. A repeat before a verdict revokes the earlier key and mints a new one, so a lost answer is safe to retry. Exit 0 minted, 1 refused (409 `review_already_recorded`, 422 `revision_not_submitted`: the revision needs an applied `submitted` event first), 2 could not ask.

## Signing

Every request carries `X-Chg-Timestamp` (unix seconds) and `X-Chg-Signature: sha256=<hex HMAC-SHA256>` over `"<timestamp>.<raw body>"` for a POST, or `"<timestamp>.GET.<path>?<query>"` for a GET, keyed by the source's secret: loopctl's `Loopctl.Changes.Signature`. HTTP goes through `curl`; the secret stays in chg's process and never reaches an argument list.
