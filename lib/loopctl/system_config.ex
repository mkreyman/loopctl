defmodule Loopctl.SystemConfig do
  @moduledoc """
  DB-backed, live-tunable system configuration for operational knobs
  (timeout/retry budgets) that were previously hardcoded module attributes.

  Changing a value is now an `UPDATE` of a `system_configs` row — no code change,
  no redeploy. The change is picked up immediately on write (`put/2`), and by any
  other node within a minute via the `SystemConfigRefreshWorker` Oban cron.

  ## Hot-path read

  `get_int/2` reads from `:persistent_term` (a near-zero-cost VM-global read) and
  MUST NEVER raise — it is called on the ingestion/extraction hot path. A cache
  miss OR any error returns the caller-supplied default, so a missing DB row (or a
  DB the cache was never primed from) behaves exactly like the pre-existing
  in-code default.

  ## Refresh lifecycle

  The cache is (re)loaded from the DB via `Loopctl.AdminRepo`:

    * once at boot (`Loopctl.Application.start/2`, guarded), and
    * every minute by `Loopctl.Workers.SystemConfigRefreshWorker`, and
    * immediately for a single key on `put/2`.

  `refresh/0` is `try/rescue`-wrapped so a DB blip logs and no-ops — it never
  crashes boot or the cron worker; the previously-cached values simply persist.

  The `:persistent_term` key is `{__MODULE__, key_string}` — string keys are used
  verbatim (never `String.to_atom/1` on them).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.SystemConfig.Setting

  @doc """
  Reads an integer config value from the `:persistent_term` cache.

  Returns `default` on a cache miss, a non-integer cached value, or any error.
  Never raises — safe to call on the hot path.
  """
  @spec get_int(String.t(), integer()) :: integer()
  def get_int(key, default) when is_binary(key) and is_integer(default) do
    case :persistent_term.get(pt_key(key), :__miss__) do
      value when is_integer(value) -> value
      _ -> default
    end
  rescue
    _ -> default
  end

  @doc """
  Loads ALL settings from the DB (via `AdminRepo`) into `:persistent_term`.

  Wrapped in `try/rescue`: a DB error logs and no-ops (returns `:ok`) so it can
  never crash boot or the refresh cron. The existing cache is left untouched.
  """
  @spec refresh() :: :ok
  def refresh do
    Setting
    |> AdminRepo.all()
    |> Enum.each(fn %Setting{key: key, value: value} ->
      :persistent_term.put(pt_key(key), value)
    end)

    :ok
  rescue
    e ->
      Logger.warning(
        "Loopctl.SystemConfig.refresh/0 failed; keeping existing cache: " <>
          Exception.message(e)
      )

      :ok
  end

  @doc """
  Upserts a setting row (via `AdminRepo`) AND updates the `:persistent_term`
  cache immediately, so the new value is live on this node without waiting for the
  refresh cron. For a future admin API.
  """
  @spec put(String.t(), integer()) :: {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def put(key, value) when is_binary(key) and is_integer(value) do
    now = DateTime.utc_now()

    %Setting{}
    |> Setting.changeset(%{key: key, value: value})
    |> AdminRepo.insert(
      on_conflict: [set: [value: value, updated_at: now]],
      conflict_target: :key,
      returning: true
    )
    |> case do
      {:ok, setting} ->
        :persistent_term.put(pt_key(key), value)
        {:ok, setting}

      {:error, _changeset} = error ->
        error
    end
  end

  @doc """
  Lists all settings (via `AdminRepo`), ordered by key. For observability.
  """
  @spec all() :: [Setting.t()]
  def all do
    AdminRepo.all(from s in Setting, order_by: [asc: s.key])
  end

  defp pt_key(key), do: {__MODULE__, key}
end
