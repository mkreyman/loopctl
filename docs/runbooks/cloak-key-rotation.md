# Rotating `CLOAK_KEY` (#622)

`CLOAK_KEY` is the AES-256-GCM key behind every field encrypted at rest — tenant LLM
credentials, webhook signing secrets, cached idempotent responses, and the ingestion
document envelopes carried in `oban_jobs.args`. Rotating it is a **secret update plus a
re-encryption pass**; it needs no code change and no redeploy.

Three env vars drive it (all documented in [`deploy/FLY_SECRETS.md`](../../deploy/FLY_SECRETS.md)):

| Variable | Role |
|----------|------|
| `CLOAK_KEY` | the ACTIVE key — every new write is encrypted with it |
| `CLOAK_KEY_TAG` | the tag stamped into the ciphertext header (default `AES.GCM.V1`) |
| `CLOAK_RETIRED_KEYS` | comma-separated `TAG:BASE64_KEY` entries, decrypt-only |

## Why the tag must be bumped

Cloak decides which cipher decrypts a value by matching the **tag** in the ciphertext
header, and takes the first cipher whose tag matches. Two ciphers sharing a tag are
indistinguishable, so rows written under the old key would be handed to the new key and
fail the GCM authentication check — indistinguishable, at that point, from tampering.

So a rotation bumps `CLOAK_KEY_TAG` in the same step that swaps `CLOAK_KEY`, and moves the
outgoing key into `CLOAK_RETIRED_KEYS` **under its old tag**. Boot refuses a config where a
retired entry reuses the active tag, or where any entry is malformed: a silently dropped
retired key means undecryptable rows, which is worse than a failed boot.

## Order (this is the part that loses data if you get it wrong)

Rotate in **two commands**, each with its own restart. `fly secrets set A=… B=…` is atomic
in the secret store but not in the fleet: it rolls the machines, so for a minute both
configs are live. Phase 1 publishes the new key DECRYPT-ONLY under its new tag; phase 2
promotes it and retires the outgoing key. After phase 1 every machine reads both tags, so
during phase 2's roll each machine can read whatever the other writes.

Doing it in one command leaves a window where a not-yet-restarted machine meets a new-tag
row it has no cipher for: encrypted columns raise on load, and an ingestion job a new
machine wrote is DISCARDED as corrupt by an old one — after the client already got its 202.
Setting the new `CLOAK_KEY` before the retired list is worse still: every row under the old
key is unreadable until the second command lands.

## Procedure

Throughout, `mix loopctl.reencrypt_secrets` is the local form. On a release there is no
Mix, so use the running node: `bin/loopctl rpc 'Loopctl.Vault.Rotation.reencrypt() |> IO.inspect()'`
(and `Loopctl.Vault.Rotation.census()` for `status`).

1. **Census first.** Record what is out there, so step 7 has something to compare against:

       mix loopctl.reencrypt_secrets status

   Every column should report a single tag — the current `CLOAK_KEY_TAG`, `AES.GCM.V1` on
   an install that has never rotated. `:untagged` counts are corrupt or foreign bytes and
   must be investigated before rotating; they will fail the pass.

2. **Generate the new key:**

       elixir -e ':crypto.strong_rand_bytes(32) |> Base.encode64() |> IO.puts()'

3. **Phase 1 — publish the new key decrypt-only**, under the tag it will write:

       fly secrets set CLOAK_RETIRED_KEYS="AES.GCM.V2:NEW_BASE64_KEY"

   The app restarts. Nothing writes the new key yet; every machine can now read it.

   `CLOAK_RETIRED_KEYS` is a LIST and `fly secrets set` REPLACES it — it does not append.
   If a previous rotation has not reached step 7, its key is still in there and still
   needed: read the current value first (`fly secrets list` shows only the digest, so take
   it from wherever you keep the key material) and list every entry you must keep alongside
   the new one, comma-separated — `"AES.GCM.V2:NEW_KEY,AES.GCM.V1:OLDER_KEY"`. Dropping an
   entry this way is well-formed config, so no boot guard fires; the rows it wrote simply
   stop decrypting. The same applies to phase 2 below.

4. **Phase 2 — promote it**, retiring the outgoing key under the tag it wrote:

       fly secrets set \
         CLOAK_KEY="NEW_BASE64_KEY" \
         CLOAK_KEY_TAG="AES.GCM.V2" \
         CLOAK_RETIRED_KEYS="AES.GCM.V1:OLD_BASE64_KEY"

   New writes now use the new key; old rows still decrypt through the retired entry. **The
   system is fully functional in this state** — step 5 can wait for a quiet window. Leaving
   the new key in the retired list here aborts boot (a retired entry may not reuse the
   active tag): the guard is telling you the promotion is half-done. If boot fails, the
   message names the offending entry by position and says what is wrong with it; nothing
   was written, so restoring the previous secrets is a complete rollback. Once the app has
   RUN on the new key that is no longer true — rows written since carry the new tag, so a
   revert must list the NEW key in `CLOAK_RETIRED_KEYS` under its new tag, or lose them.

5. **Re-encrypt the stored rows.** Dry-run first to see the size of the job:

       mix loopctl.reencrypt_secrets --dry-run
       mix loopctl.reencrypt_secrets

   The pass is batched, idempotent and resumable: it skips rows already on the active
   cipher, so an interrupted run is resumed by re-running it, and it never needs a cursor.
   `--table` restricts it to one table and `--batch-size` tunes the round trips. It runs on
   `AdminRepo` and so occupies one of that pool's three connections while it works — prefer
   a quiet window, and `--table` if you want to spread it out.

   Read the counts. `reencrypted` + `skipped_active` + `skipped_null` +
   `skipped_concurrent` + `skipped_unsettled` + `skipped_gone` + `failed` equals `examined`
   — every row is accounted for. A non-zero `failed` exits non-zero and names the rows; the
   overwhelmingly likely cause is a retired key missing from `CLOAK_RETIRED_KEYS`. Fix the
   secret and re-run; the rows already converted are skipped. A non-zero `skipped_unsettled`
   also exits non-zero: those rows were rewritten by the application twice under the pass and
   may still carry the retired tag, so re-run until the count is zero.

6. **Drain the `:ingestion` AND `:cleanup` queues.** Both carry Cloak-encrypted values
   inside `oban_jobs.args`, which the pass does not touch — it walks schema columns — and
   which the census cannot see either, so step 7 will look clean while these are pending.
   Ingestion jobs (`Loopctl.Ingestion.ContentEnvelope`) live up to the 3600s uniqueness
   window, longer under snooze; a `:cleanup` restore job
   (`Loopctl.Workers.OrphanedSecretCleanupWorker`) carries a tenant's OLD Ed25519 audit
   private key and retries up to 10 times with exponential backoff, so it can sit for
   hours. Leave the retired key in place until BOTH queues are empty, or those jobs fail to
   decrypt: ingestion is discarded (`Loopctl.Workers.ContentIngestionWorker` logs a distinct
   warning on each, which is worth alerting on: the same signal also means tampering) and
   the audit key is never restored — the exact breakage that worker exists to prevent.

7. **Confirm, then drop the retired key.** Re-run the census; no column should still report
   the retired tag:

       mix loopctl.reencrypt_secrets status

   Only then:

       fly secrets unset CLOAK_RETIRED_KEYS

   Dropping it earlier makes any row still on the old key unreadable. There is no rush —
   a retired key costs one extra tag comparison per decrypt.

## Which columns the pass covers

`Loopctl.Vault.Rotation.targets/0` derives them by reflecting over every Ecto schema in the
app and selecting fields whose type is backed by `Loopctl.Vault` — so a newly added
`Loopctl.Vault.Binary` field is covered with no change to the task or to this document.
`mix loopctl.reencrypt_secrets status` prints the list it found.

Two things are deliberately outside it:

- **Encrypted values inside `oban_jobs.args`** — transient, and rewriting a row an executing
  worker holds would race it. Step 6 is how they are retired, and `status` cannot see them.
- **An encrypted value inside an array or map column** — none exists; `targets/0` raises
  rather than skipping one silently, so adding one forces a decision here. It raises the
  same way on a Cloak field declaring a `:label`, which the application encrypts with that
  labelled cipher rather than the active one.

## Recovering a mis-sequenced rotation

If rows became unreadable because the old key was dropped too early, put it back:

    fly secrets set CLOAK_RETIRED_KEYS="AES.GCM.V1:OLD_BASE64_KEY"

AES-GCM ciphertext is intact until it is overwritten, so as long as the old key material
still exists, restoring it restores the rows. Then resume at step 5. The same move covers a
rollback in the other direction — reverting to the old `CLOAK_KEY`/`CLOAK_KEY_TAG` after
the app has run on the new one requires listing the NEW key here, under its new tag. If a
key is genuinely gone, the rows it wrote are unrecoverable — which is why step 7 comes
after a clean census and two drained queues, and why a `CLOAK_RETIRED_KEYS` that is
malformed, or set but naming no entries at all, aborts boot instead of dropping an entry.
