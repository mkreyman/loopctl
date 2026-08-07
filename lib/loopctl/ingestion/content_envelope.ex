defmodule Loopctl.Ingestion.ContentEnvelope do
  @moduledoc """
  #493 — encrypts ingestion document content AT REST inside Oban job args.

  Raw document `content` posted to `POST /api/v1/knowledge/ingest` used to sit as
  plaintext JSON in `oban_jobs.args` (including `retryable`/`discarded` rows) until
  pruning — the one at-rest exposure Epic 41 didn't cover. For a `local_only` scope
  the pipeline can be fully egress-free and the persisted article bodies handled by
  the US-41 work, while the RAWEST form of the document still sat unencrypted in a
  side table, undermining the private tier's "encrypted at rest" guarantee on a
  shared deployment.

  `wrap/1` encrypts the content with `Loopctl.Vault` (Cloak AES-256-GCM) and
  Base64-wraps it for JSON transport; `unwrap/1` reverses it. This mirrors
  `Loopctl.Workers.OrphanedSecretCleanupWorker`'s restore-value handling and the
  app's other Cloak-encrypted secrets (tenant LLM keys, webhook signing secrets) —
  the document `content` is never plaintext in `oban_jobs`, and when the job is
  pruned the ciphertext goes with it.

  Encryption is UNCONDITIONAL (every ingested inline document, not only private-tier
  scopes): the cost is negligible against a ~6-minute LLM ingestion job, and a
  uniform path is simpler and strictly safer than branching on the scope's marking.

  ## `content_hash` is a keyed blind index, not a plaintext fingerprint

  Uniqueness/fair-share key off `content_hash` and `tenant_id` (never the content),
  so the non-deterministic AES-GCM ciphertext does not perturb them. `content_hash`
  itself is a per-tenant HMAC-SHA256 blind index (see
  `LoopctlWeb.KnowledgeIngestionController.compute_content_hash/2`), NOT a bare
  SHA256 of the plaintext: a bare digest beside the ciphertext would be an offline
  confirmation oracle (a DB-read attacker could hash a known/guessable document and
  match). The HMAC keeps dedup deterministic while making the value uncomputable
  without the app secret, and its per-tenant key also prevents correlating identical
  documents across tenants.

  ## Decrypt failure: tamper OR key-config, fail closed + alert

  AES-GCM is AUTHENTICATED: a tampered, truncated, or non-Base64 envelope fails
  `unwrap/1` CLOSED with `{:error, :corrupt_content_envelope}` rather than yielding
  garbage plaintext, and the worker maps that to `{:discard, ...}` — consistent with
  its other discard-don't-crash-loop guards. AES-GCM CANNOT distinguish tampering
  from a wrong/rotated key, so this same failure also fires when `CLOAK_KEY` is
  rotated and the outgoing cipher is dropped while ingestion jobs are still queued
  (they live up to the 3600s unique window, longer under snooze). That case is
  RECOVERABLE — putting the prior key back in `CLOAK_RETIRED_KEYS` and restarting lets
  the queued jobs decrypt — so a decrypt failure is NOT unconditionally "a poison pill
  no retry can heal".

  OPERATIONAL RULE: when rotating `CLOAK_KEY`, keep the outgoing key in
  `CLOAK_RETIRED_KEYS` until the `:ingestion` queue has drained, or in-flight jobs will
  silently discard. These envelopes live in `oban_jobs.args`, so
  `mix loopctl.reencrypt_secrets` does NOT convert them — it walks schema columns only;
  draining the queue is what retires them (`docs/runbooks/cloak-key-rotation.md`).
  The worker logs a distinct `Logger.warning` on every decrypt
  failure (with tenant_id + content_hash, never the envelope) so a tampering or
  mis-sequenced-rotation incident is an alertable signal, not buried in
  `oban_jobs.errors`.
  """

  alias Loopctl.Vault

  @doc """
  Encrypts `content` and returns a Base64-wrapped, JSON-safe envelope string.

  Raises if the vault is misconfigured (no `CLOAK_KEY`) — a boot-level fault the
  caller should never mask, matching the app's other `Vault.encrypt!/1` sites.
  """
  @spec wrap(binary()) :: binary()
  def wrap(content) when is_binary(content) do
    content |> Vault.encrypt!() |> Base.encode64()
  end

  @doc """
  Probes the vault, raising the SAME boot-level fault `wrap/1` raises on a
  misconfiguration (missing/invalid `CLOAK_KEY`) — but without a document in hand.

  Callers that encrypt inline content inside a crash-isolated boundary — e.g. the
  batch ingest path's `Task.Supervisor.async_stream_nolink`, where a `wrap/1` raise
  is caught as an opaque per-item `{:exit, reason}` and would otherwise be flattened
  into a generic "validation_failed" per-item error — probe the vault ONCE up front
  so a real key-provisioning failure surfaces LOUDLY (propagating as a 500) instead
  of being masked behind a per-item result. The fault is global and deterministic,
  so one probe suffices for the whole batch.
  """
  @spec ensure_ready!() :: :ok
  def ensure_ready! do
    _ = Vault.encrypt!("")
    :ok
  end

  @doc """
  Decrypts an envelope produced by `wrap/1`.

  Returns `{:ok, content}` or, on ANY malformed/tampered input (bad Base64, wrong
  key, GCM auth failure, truncation), `{:error, :corrupt_content_envelope}` — never
  raises, so the worker can `{:discard}` a poison pill instead of crash-looping.
  """
  @spec unwrap(binary()) :: {:ok, binary()} | {:error, :corrupt_content_envelope}
  def unwrap(envelope) when is_binary(envelope) do
    with {:ok, ciphertext} <- Base.decode64(envelope),
         {:ok, content} <- safe_decrypt(ciphertext) do
      {:ok, content}
    else
      _ -> {:error, :corrupt_content_envelope}
    end
  end

  # Vault.decrypt!/1 does NOT uniformly raise: on an unrecognized Cloak cipher tag
  # (e.g. a byte flipped in the header) it returns the atom `:error` rather than a
  # binary. Accept ONLY a binary plaintext as success; every other outcome — an
  # `:error` return, a `{:error, _}`, or a GCM-auth raise — collapses to `:error`.
  defp safe_decrypt(ciphertext) do
    case Vault.decrypt!(ciphertext) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
