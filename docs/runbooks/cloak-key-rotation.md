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

`CLOAK_RETIRED_KEYS` must be in place **before or in the same command as** the `CLOAK_KEY`
swap. `fly secrets set A=… B=…` applies atomically and restarts once, so set all three
together. Setting the new `CLOAK_KEY` first and the retired list second means every row
written under the old key is unreadable for the window in between.

## Procedure

Throughout, `mix loopctl.reencrypt_secrets` is the local form. On a release there is no
Mix, so use the running node: `bin/loopctl rpc 'Loopctl.Vault.Rotation.reencrypt() |> IO.inspect()'`
(and `Loopctl.Vault.Rotation.census()` for `status`).

1. **Census first.** Record what is out there, so step 6 has something to compare against:

       mix loopctl.reencrypt_secrets status

   Every column should report a single tag — the current `CLOAK_KEY_TAG`, `AES.GCM.V1` on
   an install that has never rotated. `:untagged` counts are corrupt or foreign bytes and
   must be investigated before rotating; they will fail the pass.

2. **Generate the new key:**

       elixir -e ':crypto.strong_rand_bytes(32) |> Base.encode64() |> IO.puts()'

3. **Set all three secrets in one command**, bumping the tag and retiring the outgoing key
   under the tag it wrote:

       fly secrets set \
         CLOAK_KEY="NEW_BASE64_KEY" \
         CLOAK_KEY_TAG="AES.GCM.V2" \
         CLOAK_RETIRED_KEYS="AES.GCM.V1:OLD_BASE64_KEY"

   The app restarts. New writes now use the new key; old rows still decrypt through the
   retired entry. **The system is fully functional in this state** — step 4 can wait for a
   quiet window. If boot fails, the message names the offending entry by position and says
   what is wrong with it; nothing was written, so restoring the previous secrets is a
   complete rollback.

4. **Re-encrypt the stored rows.** Dry-run first to see the size of the job:

       mix loopctl.reencrypt_secrets --dry-run
       mix loopctl.reencrypt_secrets

   The pass is batched, idempotent and resumable: it skips rows already on the active
   cipher, so an interrupted run is resumed by re-running it, and it never needs a cursor.
   `--table` restricts it to one table and `--batch-size` tunes the round trips. It runs on
   `AdminRepo` and so occupies one of that pool's three connections while it works — prefer
   a quiet window, and `--table` if you want to spread it out.

   Read the counts. `reencrypted` + `skipped_active` + `skipped_null` +
   `skipped_concurrent` + `failed` equals `examined` — every row is accounted for. A
   non-zero `failed` exits non-zero and names the rows; the overwhelmingly likely cause is
   a retired key missing from `CLOAK_RETIRED_KEYS`. Fix the secret and re-run; the rows
   already converted are skipped.

5. **Drain the `:ingestion` queue.** Ingestion jobs carry their document encrypted inside
   `oban_jobs.args` (`Loopctl.Ingestion.ContentEnvelope`), which the pass does not touch —
   it walks schema columns. Those jobs live up to the 3600s uniqueness window, longer under
   snooze. Leave the retired key in place until the queue is empty, or in-flight jobs fail
   to decrypt and are discarded (`Loopctl.Workers.ContentIngestionWorker` logs a distinct
   warning on each, which is worth alerting on: the same signal also means tampering).

6. **Confirm, then drop the retired key.** Re-run the census; no column should still report
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
  worker holds would race it. Step 5 is how they are retired.
- **An encrypted value inside an array or map column** — none exists; `targets/0` raises
  rather than skipping one silently, so adding one forces a decision here.

## Recovering a mis-sequenced rotation

If rows became unreadable because the old key was dropped too early, put it back:

    fly secrets set CLOAK_RETIRED_KEYS="AES.GCM.V1:OLD_BASE64_KEY"

AES-GCM ciphertext is intact until it is overwritten, so as long as the old key material
still exists, restoring it restores the rows. Then resume at step 4. If the old key is
genuinely gone, the affected rows are unrecoverable — which is why step 6 comes after a
clean census, and why a malformed `CLOAK_RETIRED_KEYS` aborts boot instead of dropping an
entry.
