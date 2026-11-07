defmodule Loopctl.Workers.EscalationDigestWorker do
  @moduledoc """
  Posts the daily escalation digest (US-48.11, AC-48.11.5): for every tenant holding an
  escalated story, one post on each project's coordination channel that has
  `budget_exhausted` rows older than an hour — count, story ids, `work_left_behind`. The
  selection, the body and the idempotency are `Loopctl.Delivery.EscalationInbox.post_digest/2`'s.

  Mark, 2026-11-07: "make sure that implementations that timed out can be found and surfaced
  to be worked on again." The inbox makes them findable; this makes them SEEN, by whoever reads
  the repo's channel, without anybody having to ask.

  ## Scheduling

  DAILY and HARDCODED (no env var), like `IngestionHealthWorker` and
  `LegacyEmbeddingRetirementWorker`: the schedule is a latency knob on a once-a-day notice, and
  app boot must not gain a dependency on a new env var for it. Not behind
  `:dispatch_driver_enabled`: it starts nothing and spends nothing — it reports stories that
  are already parked, which matters most on a fleet where the driver has been turned off.

  ## Retries cannot post twice

  Each post's key carries the project and the UTC date of the run (`digest_key/2`), and the
  channel's session-key unique index makes a second insert of the same slot a refusal that
  `post_digest/2` reads as `:already_posted`. A retried job, or a second node's run on the same
  day, therefore posts nothing new. `now` is read once per run, so every tenant's posts in
  one run carry the same date.

  ## One tenant may not stop the rest

  Each tenant's digest runs on its own, and a raise is logged and counted. The job fails only
  when EVERY tenant errored — the rule the other delivery sweeps apply, so a systemic failure
  is not reported as a clean run.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 3_600, states: [:available, :scheduled, :executing, :retryable]]

  alias Loopctl.Delivery.EscalationInbox

  require Logger

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, {:all_tenants_errored, pos_integer()}}
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    EscalationInbox.all_digest_tenants()
    |> Enum.map(&digest(&1, now))
    |> run_result()
  end

  @doc """
  The job's result for a run whose tenants produced `outcomes` (`:ok` or `:errored` each). An
  empty run is `:ok`; a run where every tenant errored is an error.
  """
  @spec run_result([:ok | :errored]) :: :ok | {:error, {:all_tenants_errored, pos_integer()}}
  def run_result([]), do: :ok

  def run_result(outcomes) do
    errored = Enum.count(outcomes, &(&1 == :errored))

    if errored == length(outcomes),
      do: {:error, {:all_tenants_errored, errored}},
      else: :ok
  end

  @doc """
  One tenant's digest as of `now`: `:ok` when every project it posted to (or found already
  posted) succeeded, `:errored` otherwise. Never raises.
  """
  @spec digest(Ecto.UUID.t(), DateTime.t()) :: :ok | :errored
  def digest(tenant_id, %DateTime{} = now) do
    outcomes = EscalationInbox.post_digest(tenant_id, now)

    case for({:error, project_id, reason} <- outcomes, do: {project_id, reason}) do
      [] ->
        :ok

      failures ->
        Logger.error(
          "EscalationDigestWorker: digest post refused: tenant_id=#{tenant_id} " <>
            "failures=#{inspect(failures)}",
          tenant_id: tenant_id
        )

        :errored
    end
  rescue
    error -> errored(tenant_id, Exception.format(:error, error, __STACKTRACE__))
  catch
    kind, value -> errored(tenant_id, Exception.format(kind, value, __STACKTRACE__))
  end

  defp errored(tenant_id, detail) do
    Logger.error(
      "EscalationDigestWorker: tenant failed, continuing with the rest: " <>
        "tenant_id=#{tenant_id} detail=#{detail}",
      tenant_id: tenant_id
    )

    :errored
  end
end
