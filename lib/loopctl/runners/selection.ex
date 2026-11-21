defmodule Loopctl.Runners.Selection do
  @moduledoc """
  Which runners an UNATTENDED pass may hand a dispatch to — the one selection both
  `Loopctl.Delivery.DispatchDriver` (implement) and `Loopctl.Delivery.TriageDispatcher`
  (triage) make, so the two cannot drift apart.

  A runner is selected when it is

    * CONNECTED on exactly one socket (Phoenix Presence) — a machine with two live sockets on
      one credential is skipped rather than guessed at, since `Loopctl.Runners.dispatch/3`
      refuses it `:runner_ambiguous`;
    * accepting on its own declaration — not draining, the repository, the kind
      (`Loopctl.Runners.accepts?/5`, the same rule `dispatch/3` applies) — and not holding a
      configuration refusal of this kind for this repository from its live connection
      (#1020), which it would only repeat;
    * not revoked, with a FREE SLOT on its row (`in_flight < max_sessions`); and
    * its SUBSCRIPTION is not exhausted (US-44.6) — no same-tenant row, its own or one sharing
      its non-null `account_ref`, holds `usage_exhausted_until` in the future.

  The last three are ONE query. Exhaustion is a predicate on the rows the pass already reads
  for a free slot (`Loopctl.Runners.Usage.not_exhausted/2`, the same definition the pool and
  `Loopctl.Delivery.Placement` read), not a map read beside it and cached across the pass: a
  machine that runs dry between two stories of one pass is simply not selected by the second.
  One that runs dry between this read and the push is refused by the gate beside the push —
  `Placement.place/4` before it claims, `Runners.dispatch/3` before it records — and the pass
  treats that refusal as "no runner" for the story; the next pass selects again.
  """

  import Ecto.Query

  alias Loopctl.Runners
  alias Loopctl.Runners.Runner
  alias Loopctl.Runners.Usage

  require Logger

  @doc """
  The runners of `tenant_id` a `kind` dispatch for `repo` may be handed to right now, least
  loaded first (`in_flight`, then id): connected, accepting, not revoked, free and not
  exhausted — see the moduledoc. `[]` when there is none; an empty or non-accepting fleet costs
  no database read at all.
  """
  @spec runners(Ecto.UUID.t(), String.t(), String.t()) :: [Runner.t()]
  def runners(tenant_id, kind, repo)
      when is_binary(tenant_id) and is_binary(kind) and is_binary(repo) do
    case accepting_ids(tenant_id, kind, repo) do
      [] ->
        []

      ids ->
        from(r in Runner,
          as: :runner,
          where: r.tenant_id == ^tenant_id,
          where: is_nil(r.revoked_at),
          where: r.id in ^ids,
          where: r.in_flight < r.max_sessions,
          order_by: [asc: r.in_flight, asc: r.id]
        )
        |> Usage.not_exhausted(tenant_id)
        |> Loopctl.AdminRepo.all()
    end
  end

  # The connected runners whose OWN declaration admits the dispatch, read from the meta of the
  # sole socket a push would reach, less those holding a configuration refusal of this kind for
  # this repository from that connection (#1020). The declaration is judged in memory, apart
  # from `accepts?/5`'s ledger fallback for a runner that declared no kinds; the refusals are
  # ONE ledger read for the tenant (`Runners.config_refusals/1`), made only when some runner
  # is accepting.
  defp accepting_ids(tenant_id, kind, repo) do
    accepting =
      for {_name, %{metas: [meta]}} <- Runners.pool(tenant_id),
          runner_id = Map.get(meta, :runner_id),
          is_binary(runner_id),
          Runners.accepts?(tenant_id, runner_id, meta, kind, repo) == :ok,
          do: runner_id

    case accepting do
      [] ->
        []

      ids ->
        held = Runners.config_refusals(tenant_id)
        Enum.reject(ids, &held_out?(Map.get(held, &1, []), kind, repo))
    end
  end

  # Case-insensitive on the repository, the rule `accepts?/5` applies to a declared `repos`.
  defp held_out?(refusals, kind, repo) do
    wanted = String.downcase(repo)
    Enum.any?(refusals, &(&1.kind == kind and String.downcase(&1.repo) == wanted))
  end

  @doc """
  The note a pass logs when a story found no runner (AC-44.6.8), ONCE per tenant per pass —
  `cache` is the pass's own map, and the tenant is recorded in it whether or not anything was
  logged, so a pass reads at most once per tenant.

  A FACT about the tenant, not a diagnosis of the story: that it has exhausted runners, and the
  earliest instant one of them stops being exhausted. The resets are those of the tenant's
  exhausted runners that are NOT revoked (`Loopctl.Runners.Usage.exhausted_until_by_runner/1`,
  the pool's own read) — full or not, since a dry runner's full slots are held by sessions
  about to end `usage_exhausted`. It is not a promise that capacity returns then: the machine
  may still be full, draining or without the story's repository. Nothing is logged when the
  tenant has no exhausted runner.
  """
  @spec note_no_runner(map(), String.t(), %{tenant_id: Ecto.UUID.t(), story_id: Ecto.UUID.t()}) ::
          map()
  def note_no_runner(cache, label, %{tenant_id: tenant_id, story_id: story_id})
      when is_map(cache) and is_binary(label) do
    key = {:no_runner_noted, tenant_id}

    if Map.has_key?(cache, key) do
      cache
    else
      case note_resets(tenant_id) do
        [] ->
          :ok

        resets ->
          Logger.info(
            "#{label}: no runner for story_id=#{story_id}; #{length(resets)} exhausted " <>
              "runner(s) in tenant; earliest_usage_reset=" <>
              DateTime.to_iso8601(Enum.min(resets, DateTime)),
            tenant_id: tenant_id
          )
      end

      note_refusals(label, tenant_id, story_id)
      Map.put(cache, key, true)
    end
  end

  # #1020: a runner held out for a configuration refusal on its live connection is the one
  # no-runner cause a person must act on (fix the config, reconnect), so it is a WARNING and
  # names each pair. A FACT about the tenant, like the note above, not a diagnosis of this
  # story: a listed pair may be for another kind or repository. Once per tenant per pass,
  # under the same cache key.
  defp note_refusals(label, tenant_id, story_id) do
    case Runners.config_refusals(tenant_id) do
      refusals when map_size(refusals) == 0 ->
        :ok

      refusals ->
        pairs =
          for {runner_id, rows} <- Enum.sort(refusals), row <- rows do
            "runner_id=#{runner_id} kind=#{row.kind} repo=#{row.repo} reason=#{row.reason}"
          end

        Logger.warning(
          "#{label}: no runner for story_id=#{story_id}; the tenant has runner(s) held out of " <>
            "these (kind, repo) pairs until they reconnect, for a configuration refusal " <>
            "since joining: " <> Enum.join(pairs, "; "),
          tenant_id: tenant_id
        )
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "no-runner refusal note skipped, read failed: tenant_id=#{tenant_id} " <>
          "exception=#{inspect(error.__struct__)}"
      )
  end

  # The note is a diagnostic and must never change the candidate's outcome: a read that fails
  # is logged and the note is skipped, never raised into the pass as an `:errored` story.
  defp note_resets(tenant_id) do
    Map.values(Usage.exhausted_until_by_runner(tenant_id))
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "no-runner note skipped, reset read failed: tenant_id=#{tenant_id} " <>
          "exception=#{inspect(error.__struct__)}"
      )

      []
  end
end
