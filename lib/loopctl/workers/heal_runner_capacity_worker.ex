defmodule Loopctl.Workers.HealRunnerCapacityWorker do
  @moduledoc """
  #803 — Gives back runner capacity slots whose dispatch can no longer be running, and
  recomputes each runner's `in_flight` from the reservations left. Runs every minute via
  Oban Cron. Modelled on `ReclaimExpiredClaimsWorker`.

  Every normal path releases a slot inline, exactly once (`Loopctl.Runners.Capacity`). This
  is the path for the ones nothing reports: a session that ended without a release, a
  runner revoked through its api key, a claim reclaimed by lease expiry, and a slot taken
  with `Loopctl.Runners.reserve_slot/2` that no dispatch holds. A leaked slot refuses
  admissions for the whole tenant, which is why this runs every minute rather than every
  five.

  The CANDIDATE read runs on AdminRepo (BYPASSRLS, so its explicit predicates are the only
  scoping) and selects by the LEAK ITSELF, fleet-wide: a runner holding a reservation that
  can no longer be running (`Capacity.dead_reservations/1`), or one whose `in_flight`
  disagrees with its unreleased rows. Every candidate therefore has work to do, and a healed
  one drops out of the next run's candidates. Selecting by `updated_at` instead let the
  busiest healthy runners fill every batch, so a leak on a newer runner was never reached.

  Each candidate is healed through `Loopctl.Runners.heal_capacity/2`, which re-decides
  everything on the RLS `Loopctl.Repo` under the runner's row lock with a bounded lock wait,
  so the read is advisory and two overlapping runs release nothing twice.

  Bounded at `@batch` runners per run, fleet-wide (not per tenant). A backlog past that
  drains over successive runs, a minute apart.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Runners
  alias Loopctl.Runners.Capacity
  alias Loopctl.Runners.Runner

  @batch 100

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    results = Enum.map(candidates(), &heal/1)

    released = results |> Enum.map(fn {_c, r} -> released(r) end) |> Enum.sum()
    failed = Enum.count(results, fn {_c, r} -> not match?({:ok, _}, r) end)

    if released > 0 or failed > 0 do
      Logger.info("HealRunnerCapacityWorker: released=#{released} failed=#{failed}")
    end

    :ok
  end

  # A lock wait that ran out is "not this time": the next run retries the runner.
  defp heal(candidate) do
    result = Runners.heal_capacity(candidate.tenant_id, candidate.id)
    log_candidate(candidate, result)
    {candidate, result}
  rescue
    error in Postgrex.Error ->
      if Capacity.retryable?(error) do
        log_candidate(candidate, {:error, :capacity_busy})
        {candidate, {:error, :capacity_busy}}
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp released({:ok, %{released: n}}), do: n
  defp released(_result), do: 0

  defp log_candidate(_candidate, {:ok, %{released: 0}}), do: :ok

  defp log_candidate(candidate, {:ok, %{released: released, in_flight: in_flight}}) do
    Logger.info(
      "HealRunnerCapacityWorker: released: tenant_id=#{candidate.tenant_id} " <>
        "runner_id=#{candidate.id} released=#{released} in_flight=#{inspect(in_flight)}",
      tenant_id: candidate.tenant_id,
      runner_id: candidate.id
    )
  end

  defp log_candidate(candidate, {:error, reason}) do
    Logger.warning(
      "HealRunnerCapacityWorker: heal failed: tenant_id=#{candidate.tenant_id} " <>
        "runner_id=#{candidate.id} reason=#{inspect(reason)}",
      tenant_id: candidate.tenant_id,
      runner_id: candidate.id
    )
  end

  @doc false
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch

  # Two leak shapes, each its own bounded query, merged: a reservation that can no longer be
  # running, and a counter that disagrees with the rows. Neither returns a healthy runner.
  defp candidates do
    (holders_of_dead_reservations() ++ counter_mismatches())
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(@batch)
  end

  defp holders_of_dead_reservations do
    DateTime.utc_now()
    |> Capacity.dead_reservations()
    |> exclude(:select)
    |> distinct(true)
    |> select([d], %{id: d.runner_id, tenant_id: d.tenant_id})
    |> limit(@batch)
    |> AdminRepo.all()
  end

  # `LEAST(count, max_sessions)` is what the heal writes, so a runner already at the value it
  # can hold is not a candidate forever.
  defp counter_mismatches do
    from(r in Runner,
      where:
        r.in_flight !=
          fragment(
            "LEAST((SELECT count(*) FROM runner_dispatches d WHERE d.tenant_id = ? AND d.runner_id = ? AND d.released_at IS NULL), ?)",
            r.tenant_id,
            r.id,
            r.max_sessions
          ),
      limit: @batch,
      select: %{id: r.id, tenant_id: r.tenant_id}
    )
    |> AdminRepo.all()
  end
end
