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
  scoping): runners holding a slot, or with an unreleased dispatch. Each is healed through
  `Loopctl.Runners.heal_capacity/2`, which re-decides everything on the RLS `Loopctl.Repo`
  under the runner's row lock with a bounded lock wait, so the read is advisory and two
  overlapping runs release nothing twice.

  Bounded at `@batch` runners per run, least recently updated first. A healed runner whose
  count changes moves to the back; one whose count was already right keeps its place, so a
  tenant with more than `@batch` busy runners would starve the rest — far above the pool
  this serves today.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Runners
  alias Loopctl.Runners.Capacity
  alias Loopctl.Runners.DispatchRecord
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
      if Capacity.lock_timeout?(error) do
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

  defp candidates do
    unreleased =
      from d in DispatchRecord,
        where: d.tenant_id == parent_as(:runner).tenant_id,
        where: d.runner_id == parent_as(:runner).id,
        where: is_nil(d.released_at),
        select: 1

    from(r in Runner,
      as: :runner,
      where: r.in_flight > 0 or exists(unreleased),
      order_by: [asc: r.updated_at],
      limit: @batch,
      select: %{id: r.id, tenant_id: r.tenant_id}
    )
    |> AdminRepo.all()
  end
end
