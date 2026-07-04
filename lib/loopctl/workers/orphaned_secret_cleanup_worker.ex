defmodule Loopctl.Workers.OrphanedSecretCleanupWorker do
  @moduledoc """
  US-26.7.1 (review #1/#2) — durable retry for a FAILED compensating
  audit-key secret operation.

  When `Loopctl.Tenants` rolls back a signup / bootstrap / rotate but the
  external `Loopctl.Secrets` compensation (delete or restore) itself fails,
  the failure must NOT be swallowed: it strands a private Ed25519 key in Fly
  (delete case) or leaves Fly holding a NEW key while the DB kept the OLD
  public key (rotate case → silent signature-verification breakage). The
  context enqueues this worker so cleanup actually happens rather than being
  best-effort-once, and emits a `[:loopctl, :secrets, :orphan_cleanup_failed]`
  telemetry event so monitoring can page.

  Two operations:

    * `%{"op" => "delete", "secret_name" => name}` — retries
      `Secrets.delete/1`. A `:not_found` is treated as success (the secret is
      already gone).
    * `%{"op" => "restore", "secret_name" => name, "value" => encoded}` —
      retries `Secrets.set/2` with the OLD private key. `value` is the old key
      **encrypted at rest via `Loopctl.Vault` (Cloak AES-256-GCM) then
      Base64-wrapped** for JSON — never plaintext in the `oban_jobs` table,
      consistent with the app's other Cloak-encrypted secrets (tenant LLM
      keys, webhook signing secrets).

  `max_attempts: 10` with Oban's default exponential backoff so a transient
  Fly outage is ridden out. Unique on `(op, secret_name)` so a burst of
  compensation failures for the same secret coalesces into one retry chain.
  """

  use Oban.Worker,
    queue: :cleanup,
    max_attempts: 10,
    unique: [keys: [:op, :secret_name], period: :infinity]

  require Logger

  alias Loopctl.Secrets
  alias Loopctl.Vault

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"op" => "delete", "secret_name" => secret_name}}) do
    case Secrets.delete(secret_name) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{
        args: %{"op" => "restore", "secret_name" => secret_name, "value" => encoded}
      }) do
    old_value = decode_secret_value(encoded)

    case Secrets.set(secret_name, old_value) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Encrypts a raw secret value for safe transport in Oban args
  (Cloak AES-256-GCM, then Base64). Used by `Loopctl.Tenants` when enqueuing a
  restore retry.
  """
  @spec encode_secret_value(binary()) :: String.t()
  def encode_secret_value(value) when is_binary(value) do
    value |> Vault.encrypt!() |> Base.encode64()
  end

  defp decode_secret_value(encoded) when is_binary(encoded) do
    encoded |> Base.decode64!() |> Vault.decrypt!()
  end
end
