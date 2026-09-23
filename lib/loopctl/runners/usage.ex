defmodule Loopctl.Runners.Usage do
  @moduledoc """
  An exhausted subscription is not capacity (epic 44, US-44.6; runner contract 1.17.0).

  Eligibility used to be draining, repo, kind and a free slot. None of those sees the resource
  that actually runs out: the subscription window a runner's sessions are billed against. A
  machine whose account hit its usage limit still answers heartbeats, still declares a free
  slot, and fails every session it is handed — and since US-44.3 a `session_ended`
  `usage_exhausted` releases the story WITHOUT spending an attempt, so placement could hand it
  straight back to the same machine, unboundedly. This module is what closes that loop.

  ## The state, and where it lives

  Two columns on the `runners` row: `usage_exhausted_until` and `account_ref`. Postgres, not
  Presence meta, so it survives a node restart and reads the same from every node — a runner
  that reconnects elsewhere does not come back looking fresh.

  A runner is EXHAUSTED while its own row, or any row of the SAME TENANT carrying the same
  non-null `account_ref`, has `usage_exhausted_until` in the future (`exhausted_until/2`). A
  subscription belongs to an account, not a machine, so two machines on one login run dry
  together; `account_ref` is an opaque value the runner derives from that login. Revoked rows
  still count: revoking a machine does not refill the account it drew on.

  ## The writers

  - `record/3`, from a `status` message's `usage`. `exhausted: true` SETS this runner's value
    to `resets_at` CLAMPED to `[now + 60s, now + 8 days]`, and with no `resets_at` to the upper
    bound — never ignored, because ignoring fails open. It SETS rather than keeping the later
    value: the runner's own report is the freshest observation of the account there is, and it
    is what corrects the 8-day bound below downward. `exhausted: false` CLEARS every row in the
    tenant sharing the account (and this runner's own row) — the account has refilled, so
    every machine on it has.
  - `mark_session_exhausted/2`, from a `session_ended` `usage_exhausted`. Sets `now + 8 days`
    unless a LATER value is already stored. The upper bound because the session carries no
    reset time; the runner's next `status` carries the real one.

  ## Clock skew

  `resets_at` is the RUNNER's clock; the clamp is control's. A runner whose clock runs behind
  can send a reset that is already past — clamped up to `now + 60s`, so a declared exhaustion
  is never a no-op — and one whose clock runs ahead cannot hold a machine out for longer than
  8 days, which is the ceiling a stale or hostile timestamp can buy.

  ## Races, and which way each one fails

  Every write is ONE statement (or one transaction), so two writers interleave at row
  granularity and last-writer-wins. A `status exhausted: false` from one machine landing just
  before a `session_ended usage_exhausted` from another leaves the account exhausted for up to
  8 days until a runner reports again — the fail-CLOSED direction, bounded, and cleared by the
  next `status`. The opposite order clears an exhaustion a session just observed, and the next
  session on that account ends `usage_exhausted` again and re-marks it: one wasted placement,
  not a loop. A `session_ended` resend after the account was cleared must NOT re-exhaust it,
  which is why `Loopctl.Delivery.RunnerStages.end_session/3` re-drives the mark only while the
  session's claim is still the live one.

  Nothing sweeps an expired value and nothing schedules a wake-up at the reset (a non-goal of
  the story): every reader compares against now, so a value in the past is simply "not
  exhausted" and the next driver pass sees the machine again.
  """

  import Ecto.Query

  alias Loopctl.Repo
  alias Loopctl.Runners.Capacity
  alias Loopctl.Runners.Runner

  require Logger

  # The clamp on a declared reset. The floor keeps a declaration from being a no-op (a reset in
  # the past, or one second out, would put the machine back in the very next pass); the ceiling
  # is the longest a subscription window is — a weekly window plus a day of slack — and so the
  # most any timestamp, honest or not, can hold a machine out.
  @min_hold_seconds 60
  @max_hold_seconds 8 * 24 * 60 * 60

  @type usage :: %{
          required(:exhausted) => boolean(),
          optional(:resets_at) => DateTime.t() | nil,
          optional(:account_ref) => String.t() | nil
        }

  @doc "The shortest a declared exhaustion holds a runner out, in seconds."
  @spec min_hold_seconds() :: pos_integer()
  def min_hold_seconds, do: @min_hold_seconds

  @doc "The longest a declared exhaustion holds a runner out, in seconds."
  @spec max_hold_seconds() :: pos_integer()
  def max_hold_seconds, do: @max_hold_seconds

  @doc """
  The instant a declared reset is held to: `resets_at` clamped to
  `[now + min_hold_seconds, now + max_hold_seconds]`, or the upper bound when there is none.
  """
  @spec clamp(DateTime.t() | nil, DateTime.t()) :: DateTime.t()
  def clamp(nil, %DateTime{} = now), do: DateTime.add(now, @max_hold_seconds, :second)

  def clamp(%DateTime{} = resets_at, %DateTime{} = now) do
    floor = DateTime.add(now, @min_hold_seconds, :second)
    ceiling = DateTime.add(now, @max_hold_seconds, :second)

    cond do
      DateTime.compare(resets_at, floor) == :lt -> floor
      DateTime.compare(resets_at, ceiling) == :gt -> ceiling
      true -> resets_at
    end
  end

  @doc """
  Applies a `status` message's `usage` — already cast by
  `Loopctl.ApiSpec.RunnerContract.cast_status/1` — as `runner_id` in `tenant_id`. See the
  moduledoc for what each value does.

  `{:error, :busy}` when the write did not land for want of a lock or a connection: nothing was
  written and the same message is worth sending again. `{:error, :rejected_by_database}` when
  Postgres refused a value the contract let through.
  """
  @spec record(Ecto.UUID.t(), Ecto.UUID.t(), usage()) ::
          :ok | {:error, :busy | :rejected_by_database}
  def record(tenant_id, runner_id, %{exhausted: true} = usage)
      when is_binary(tenant_id) and is_binary(runner_id) do
    until = clamp(Map.get(usage, :resets_at), DateTime.utc_now())

    write(tenant_id, fn ->
      set_own(tenant_id, runner_id, [usage_exhausted_until: until] ++ account_ref_change(usage))
      :ok
    end)
  end

  def record(tenant_id, runner_id, %{exhausted: false} = usage)
      when is_binary(tenant_id) and is_binary(runner_id) do
    write(tenant_id, fn ->
      account_ref = Map.get(usage, :account_ref) || stored_account_ref(tenant_id, runner_id)

      case account_ref_change(usage) do
        [] -> :ok
        change -> set_own(tenant_id, runner_id, change)
      end

      from(r in Runner, where: r.tenant_id == ^tenant_id)
      |> same_account_or_self(runner_id, account_ref)
      |> Repo.update_all(set: [usage_exhausted_until: nil])

      :ok
    end)
  end

  @doc """
  Marks `runner_id` exhausted for the upper bound, `now + max_hold_seconds`, unless a later
  value is already stored — what a `session_ended` `usage_exhausted` does (AC-44.6.4). The
  session carries no reset time, so this holds for the bound; the runner's next `status` with a
  `usage.resets_at` corrects it.
  """
  @spec mark_session_exhausted(Ecto.UUID.t(), Ecto.UUID.t()) ::
          :ok | {:error, :busy | :rejected_by_database}
  def mark_session_exhausted(tenant_id, runner_id)
      when is_binary(tenant_id) and is_binary(runner_id) do
    until = clamp(nil, DateTime.utc_now())

    write(tenant_id, fn ->
      from(r in own_row(tenant_id, runner_id),
        update: [
          set: [
            usage_exhausted_until:
              fragment("GREATEST(COALESCE(?, ?), ?)", r.usage_exhausted_until, ^until, ^until)
          ]
        ]
      )
      |> Repo.update_all([])

      :ok
    end)
  end

  @doc """
  Until when `runner_id` is exhausted — the LATEST future `usage_exhausted_until` among its own
  row and every same-tenant row sharing its `account_ref` — or `nil` when it is not.
  """
  @spec exhausted_until(Ecto.UUID.t(), Ecto.UUID.t()) :: DateTime.t() | nil
  def exhausted_until(tenant_id, runner_id) when is_binary(tenant_id) and is_binary(runner_id) do
    # A runner id straight off an HTTP path may not be a UUID at all. That is not an exhausted
    # runner — it is no runner, which the caller's own row lookup answers — and it must not
    # raise a cast error out of an eligibility check.
    case Ecto.UUID.cast(runner_id) do
      {:ok, runner_id} -> effective_until(tenant_id, runner_id)
      :error -> nil
    end
  end

  defp effective_until(tenant_id, runner_id) do
    {:ok, until} =
      Repo.with_tenant(tenant_id, fn ->
        tenant_id
        |> effective_query(DateTime.utc_now())
        |> where([r], r.id == ^runner_id)
        |> select([_r, o], max(o.usage_exhausted_until))
        |> Repo.one()
      end)

    until
  end

  @doc """
  Every active runner of the tenant that is exhausted, mapped to the instant it stops being —
  the same effective value `exhausted_until/2` answers, for the whole tenant in one read. A
  runner that is not exhausted is absent.
  """
  @spec exhausted_until_by_runner(Ecto.UUID.t()) :: %{Ecto.UUID.t() => DateTime.t()}
  def exhausted_until_by_runner(tenant_id) when is_binary(tenant_id) do
    {:ok, rows} =
      Repo.with_tenant(tenant_id, fn ->
        tenant_id
        |> effective_query(DateTime.utc_now())
        |> where([r], is_nil(r.revoked_at))
        |> group_by([r], r.id)
        |> select([r, o], {r.id, max(o.usage_exhausted_until)})
        |> Repo.all()
      end)

    Map.new(rows)
  end

  @doc """
  The EARLIEST instant at which an exhausted active runner of the tenant stops being exhausted,
  or `nil` when none is. What a `:no_runner` pass reports, so an operator reading "nothing
  placed" can tell "nobody is connected" from "capacity returns at T".
  """
  @spec earliest_reset(Ecto.UUID.t()) :: DateTime.t() | nil
  def earliest_reset(tenant_id) when is_binary(tenant_id) do
    tenant_id
    |> exhausted_until_by_runner()
    |> Map.values()
    |> Enum.min(DateTime, fn -> nil end)
  end

  # THE ONE DEFINITION OF "EXHAUSTED", shared by the per-runner and the per-tenant read so the
  # pool cannot show one thing while placement decides another. An INNER join: a runner with
  # no future value on its own row or any same-account row yields no row, which is `nil` for
  # `exhausted_until/2` and absence for the map. Two runners that never sent an account are
  # NOT one account: `NULL = NULL` is not true in SQL, so a NULL `account_ref` joins its own
  # row alone.
  #
  # `o.tenant_id == r.tenant_id` is in the JOIN, not only in RLS: an account_ref is opaque and
  # two tenants may well derive the same one, and one tenant's exhausted login must never hold
  # another tenant's machine out (TC-44.6.8).
  defp effective_query(tenant_id, now) do
    from r in Runner,
      join: o in Runner,
      on:
        o.tenant_id == r.tenant_id and
          (o.id == r.id or o.account_ref == r.account_ref),
      where: r.tenant_id == ^tenant_id,
      where: o.usage_exhausted_until > ^now
  end

  defp own_row(tenant_id, runner_id),
    do: from(r in Runner, where: r.tenant_id == ^tenant_id and r.id == ^runner_id)

  defp same_account_or_self(query, runner_id, nil), do: where(query, [r], r.id == ^runner_id)

  defp same_account_or_self(query, runner_id, account_ref),
    do: where(query, [r], r.id == ^runner_id or r.account_ref == ^account_ref)

  defp stored_account_ref(tenant_id, runner_id) do
    Repo.one(from r in own_row(tenant_id, runner_id), select: r.account_ref)
  end

  defp set_own(tenant_id, runner_id, change),
    do: Repo.update_all(own_row(tenant_id, runner_id), set: change)

  # A runner that sends no `account_ref` keeps the one it sent before: omitting an optional
  # field is not a statement that the machine changed login.
  defp account_ref_change(%{account_ref: ref}) when is_binary(ref), do: [account_ref: ref]
  defp account_ref_change(_usage), do: []

  # Every write runs in the runner channel's process, where a raise takes down the socket every
  # session on the machine shares. Bounded like every other write to the runner row (it is the
  # row every reservation in the tenant contends on), and every database failure is answered
  # rather than raised: a refused VALUE is `:rejected_by_database` (SQLSTATE classes 22 and 23,
  # the contract's backstop), anything else — a lock, a connection, a restart — is `:busy`,
  # nothing written, send it again.
  defp write(tenant_id, fun) do
    {:ok, result} =
      Repo.with_tenant(tenant_id, fn ->
        Capacity.set_lock_timeout!(Repo)
        fun.()
      end)

    result
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning(
        "runner usage write did not land: tenant_id=#{tenant_id} " <>
          "#{inspect(error.__struct__)}: #{Exception.message(error)}"
      )

      if refused_value?(error), do: {:error, :rejected_by_database}, else: {:error, :busy}
  end

  defp refused_value?(%Postgrex.Error{
         postgres: %{pg_code: <<class::binary-size(2), _::binary>>}
       }),
       do: class in ["22", "23"]

  defp refused_value?(_error), do: false
end
