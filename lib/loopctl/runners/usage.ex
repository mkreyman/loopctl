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

  Columns on the `runners` row: `usage_exhausted_until`, `usage_hold_provisional` and
  `account_ref`. Postgres, not
  Presence meta, so it survives a node restart and reads the same from every node — a runner
  that reconnects elsewhere does not come back looking fresh.

  A runner is EXHAUSTED while its own row, or any row of the SAME TENANT carrying the same
  non-null `account_ref`, has `usage_exhausted_until` in the future (`exhausted_until/2`). A
  subscription belongs to an account, not a machine, so two machines on one login run dry
  together; `account_ref` is an opaque value the runner derives from that login. Revoked rows
  still count: revoking a machine does not refill the account it drew on.

  ## The writers

  - `record/3`, from a `status` message's `usage`. The report is about the ACCOUNT, so both
    values act on every row of the tenant sharing the runner's `account_ref` (the one sent, or
    the one stored when none is) and on the runner's own row; with no account at all, on its
    own row alone. `exhausted: true` carries `resets_at` CLAMPED to `[now + 60s, now + 8 days]`,
    or the upper bound when there is none — never ignored, because ignoring fails open — and
    what it does depends on the `resets_at` it carries:
      - a `resets_at` STILL AHEAD beyond the floor: SETS the account's hold to it on every
        such row, as a REPORT (`usage_hold_provisional: false`). The latest observation of
        the account wins, later or earlier than what a row holds: it replaces the 8-day guess
        below, and it replaces an older report whether that was further out or nearer.
      - a `resets_at` already past, or inside the floor: clamped up to `now + 60s`, and written
        ONLY on a row with no live hold (none, or one already past). A reset that has been and
        gone is no evidence against a hold that is still live, so it neither shortens one nor
        rewrites rows on every status.
      - no `resets_at`: `now + 8 days`, PROVISIONAL, and again only on a row with no live hold
        — it knows no reset, so it cannot correct one.
    Only rows whose value or flag changes are written, so a runner repeating one report writes
    nothing (except a `resets_at` beyond the ceiling, whose clamp moves with the clock).
    `exhausted: false` CLEARS every such row holding a LIVE hold, and stamps `usage_cleared_at`
    on each one it clears — the account has refilled, so every machine on it has. A hold
    already past is left as it is and stamps nothing: it ended by itself, and the routine
    `exhausted: false` that follows a reset is no evidence of a refill after any session.
  - A runner that REPORTS A DIFFERENT `account_ref` first hands a future hold on its own row,
    provisional or not as it was, to the rows still on the old one (where theirs is earlier or
    absent), then switches: its move to another login does not refill the account it leaves.
  - `mark_session_exhausted/3`, from a `session_ended` `usage_exhausted`. Sets `now + 8 days`,
    PROVISIONAL, unless a LATER value is already stored. The upper bound because the session
    carries no reset time; the runner's next `status` with a future `resets_at` replaces it.

  ## Clock skew

  `resets_at` is the RUNNER's clock; the clamp is control's. A runner whose clock runs behind
  can send a reset that is already past. It is clamped up to `now + 60s` and written only
  where no hold is live, so a declared exhaustion is never a no-op on a machine that had none,
  and never shortens a live hold — a guess or a report — that a skewed clock is no evidence
  against. A runner whose clock runs ahead cannot hold a machine out for longer than 8 days,
  which is the ceiling a stale or hostile timestamp can buy; a FUTURE reset from a peer on the
  same account can lower it again, since the latest observation wins.

  ## Races, and which way each one fails

  Every write is ONE statement (or one transaction), so two writers interleave at row
  granularity and last-writer-wins. A `session_ended usage_exhausted` whose dispatch was
  accepted BEFORE the account was last cleared does not mark it: the session observed a fact
  the refill report has since overtaken (`usage_cleared_at`). A clear that found no LIVE hold
  stamps nothing — an expired one included — so a session end arriving after such a report
  still marks, for up to 8 days, until the next `status` with `usage` clears it: the
  fail-CLOSED direction, bounded. The one residual this accepts: an account refilled (a live
  hold cleared) and drained again within ONE session is not marked by that session's report,
  whose dispatch was accepted before the clear. The next session on that runner is accepted
  after the clear, so its report marks it — at most one wasted placement.
  The opposite order clears an exhaustion a session just observed, and the next session on
  that account ends `usage_exhausted` again and re-marks it: one wasted placement, not a loop.
  A `session_ended` resend after the claim ended must not re-exhaust the account either, which
  is why `Loopctl.Delivery.RunnerStages.end_session/3` re-drives the mark only while the
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
    now = DateTime.utc_now()
    resets_at = Map.get(usage, :resets_at)
    until = clamp(resets_at, now)

    write(tenant_id, fn ->
      account_ref = switch_account_ref(tenant_id, runner_id, usage)

      from(r in Runner, where: r.tenant_id == ^tenant_id)
      |> same_account_or_self(runner_id, account_ref)
      |> where(^rows_to_set(resets_at, until, now))
      |> Repo.update_all(
        set: [usage_exhausted_until: until, usage_hold_provisional: is_nil(resets_at)]
      )

      :ok
    end)
  end

  def record(tenant_id, runner_id, %{exhausted: false} = usage)
      when is_binary(tenant_id) and is_binary(runner_id) do
    now = DateTime.utc_now()

    write(tenant_id, fn ->
      account_ref = switch_account_ref(tenant_id, runner_id, usage)

      # Only a LIVE hold is cleared and stamped. A runner reporting `exhausted: false` on every
      # status would otherwise rewrite the whole account each time, on the row every
      # reservation in the tenant contends on — and stamping a hold that had already expired
      # made the routine report after a reset suppress the next genuine session mark.
      from(r in Runner, where: r.tenant_id == ^tenant_id and r.usage_exhausted_until > ^now)
      |> same_account_or_self(runner_id, account_ref)
      |> Repo.update_all(
        set: [usage_exhausted_until: nil, usage_hold_provisional: false, usage_cleared_at: now]
      )

      :ok
    end)
  end

  # The rows an `exhausted: true` report writes. A `resets_at` still ahead past the floor is
  # the account's CURRENT observation, so it sets every row it changes — a guess, an older
  # report later or earlier than it, or no hold — and a row already holding exactly this value
  # as a report is left alone. Anything else — no `resets_at`, or one already past or inside the
  # floor, clamped up to it — is no evidence against a hold that is still live, so it only
  # fills a row with none, and a repeat of it finds no such row.
  # A value within the floor of the stored one is the same observation: a reset beyond the
  # 8-day ceiling clamps to `now + ceiling`, which moves every second, and an exact `!=` made
  # every repeat of that report rewrite the account's rows — the rows every reservation locks.
  defp rows_to_set(resets_at, until, now) do
    if resets_at && DateTime.after?(resets_at, DateTime.add(now, @min_hold_seconds, :second)) do
      dynamic(
        [r],
        is_nil(r.usage_exhausted_until) or r.usage_hold_provisional or
          fragment(
            "abs(extract(epoch from (? - ?))) > ?",
            r.usage_exhausted_until,
            ^until,
            ^@min_hold_seconds
          )
      )
    else
      dynamic([r], is_nil(r.usage_exhausted_until) or r.usage_exhausted_until <= ^now)
    end
  end

  @doc """
  Marks `runner_id` exhausted for the upper bound, `now + max_hold_seconds`, unless a later
  value is already stored — what a `session_ended` `usage_exhausted` does (AC-44.6.4). The
  session carries no reset time, so this holds for the bound and marks it PROVISIONAL; the
  runner's next `status` with a future `usage.resets_at` replaces it.

  NOT when the account — every same-tenant row sharing the runner's `account_ref`, or its own
  row when it has none — was cleared AFTER `accepted_at`, the instant the session's dispatch
  was accepted: the session's exhaustion is older than the refill report that cleared it.
  """
  @spec mark_session_exhausted(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t() | nil) ::
          :ok | {:error, :busy | :rejected_by_database}
  def mark_session_exhausted(tenant_id, runner_id, accepted_at)
      when is_binary(tenant_id) and is_binary(runner_id) do
    until = clamp(nil, DateTime.utc_now())

    write(tenant_id, fn ->
      from(r in own_row(tenant_id, runner_id),
        as: :runner,
        update: [
          set: [
            usage_exhausted_until:
              fragment("GREATEST(COALESCE(?, ?), ?)", r.usage_exhausted_until, ^until, ^until),
            # Provisional exactly when the bound is what the row now holds.
            usage_hold_provisional:
              fragment(
                "? IS NULL OR ? <= ? OR ?",
                r.usage_exhausted_until,
                r.usage_exhausted_until,
                ^until,
                r.usage_hold_provisional
              )
          ]
        ]
      )
      |> not_cleared_since(tenant_id, accepted_at)
      |> Repo.update_all([])

      :ok
    end)
  end

  # No acceptance instant is no evidence either way, so the mark stands.
  defp not_cleared_since(query, _tenant_id, nil), do: query

  defp not_cleared_since(query, tenant_id, %DateTime{} = accepted_at) do
    cleared =
      from o in Runner,
        where: o.tenant_id == ^tenant_id,
        where: o.id == parent_as(:runner).id or o.account_ref == parent_as(:runner).account_ref,
        where: o.usage_cleared_at > ^accepted_at,
        select: 1

    where(query, [r], not exists(cleared))
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
  `query` narrowed to the runners that are NOT exhausted at this instant — the selectors'
  predicate (`Loopctl.Runners.Selection`), on the rows they already read for a free slot. The
  runner must be bound `as: :runner`. `NOT EXISTS` over the SAME definition
  `exhausted_until/2` and `exhausted_until_by_runner/1` read, so the pool, the placement gate
  and the selection cannot disagree about which machine is dry.
  """
  @spec not_exhausted(Ecto.Query.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def not_exhausted(query, tenant_id) when is_binary(tenant_id) do
    held =
      tenant_id
      |> effective_query(DateTime.utc_now())
      |> where([r], r.id == parent_as(:runner).id)
      |> select(1)

    where(query, not exists(held))
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

  # The runner's account after this report — the one it sent, or the one stored when it sent
  # none: omitting an optional field is not a statement that the machine changed login. Written
  # only when it CHANGED, and a change first hands a future hold on this row to the rows still
  # on the old account, where theirs is earlier or absent — otherwise the switch would take the
  # old account's only record of its exhaustion with it. The hold goes over as what it is, a
  # guess or a report, so a later report on the old account can still correct a guess.
  defp switch_account_ref(tenant_id, runner_id, usage) do
    sent = Map.get(usage, :account_ref)

    case Repo.one(
           from r in own_row(tenant_id, runner_id),
             select: {r.account_ref, r.usage_exhausted_until, r.usage_hold_provisional}
         ) do
      nil ->
        nil

      {stored, _hold, _provisional} when is_nil(sent) or sent == stored ->
        stored

      {stored, hold, provisional} ->
        hand_over_hold(tenant_id, runner_id, stored, hold, provisional)
        Repo.update_all(own_row(tenant_id, runner_id), set: [account_ref: sent])
        sent
    end
  end

  defp hand_over_hold(tenant_id, runner_id, old_ref, %DateTime{} = hold, provisional)
       when is_binary(old_ref) do
    if DateTime.after?(hold, DateTime.utc_now()) do
      from(r in Runner,
        where: r.tenant_id == ^tenant_id and r.account_ref == ^old_ref and r.id != ^runner_id,
        where: is_nil(r.usage_exhausted_until) or r.usage_exhausted_until < ^hold
      )
      |> Repo.update_all(set: [usage_exhausted_until: hold, usage_hold_provisional: provisional])
    end
  end

  defp hand_over_hold(_tenant_id, _runner_id, _old_ref, _hold, _provisional), do: nil

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
