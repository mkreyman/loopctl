defmodule Mix.Tasks.Loopctl.EnrichSearchEvents do
  @shortdoc "Fills search_events.client_model / client_kind from local session transcripts"

  @moduledoc """
  Joins `search_events` rows to the agent session transcripts that produced them, filling
  the two columns no client can supply (#652 item 5).

  `client_model` has no source in the agent environment, and `client_kind` can only say
  `main` or `child` — splitting a WORKFLOW agent from an ordinary SUBAGENT needs the
  transcript. That split is worth having: measured failure rates were main 8.2% / workflow
  6.0% / subagent 3.7%, a spread `child` averages away.

  See `Loopctl.Knowledge.SearchEventEnrichment` for how the join is keyed and why an
  ambiguous pair is dropped rather than guessed.

  ## Usage

      # dry run against the default transcript root, last 30 days
      mix loopctl.enrich_search_events --dry-run

      # write, over a wider window, from an explicit root
      mix loopctl.enrich_search_events --transcripts ~/.claude/projects --since-days 90

  ## Options

    * `--transcripts` — transcript root (default `~/.claude/projects`)
    * `--since-days` — only consider rows inserted within this window (default 30)
    * `--dry-run` — report what would change and write nothing

  ## Where it runs

  Against whatever `DATABASE_URL` the environment points at, through `AdminRepo`. The
  transcripts are LOCAL to the machine that made the searches, so run it on that machine —
  a session's transcripts never leave it.

  Rows are only filled, never overwritten: a row that already carries a `client_model` is
  left alone, so re-running is safe and idempotent.
  """

  use Mix.Task

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.SearchEvent
  alias Loopctl.Knowledge.SearchEventEnrichment

  @switches [transcripts: :string, since_days: :integer, dry_run: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)

    Mix.Task.run("app.start")

    root = Keyword.get(opts, :transcripts, Path.expand("~/.claude/projects"))
    since_days = Keyword.get(opts, :since_days, 30)
    dry_run? = Keyword.get(opts, :dry_run, false)

    unless File.dir?(root) do
      Mix.raise("transcript root not found: #{root}")
    end

    Mix.shell().info("scanning transcripts in #{root} ...")
    attributions = SearchEventEnrichment.scan(root)
    Mix.shell().info("resolved #{map_size(attributions)} (session, query) pairs")

    {examined, updated} = enrich(attributions, since_days, dry_run?)

    Mix.shell().info(
      "#{if dry_run?, do: "would update", else: "updated"} #{updated} of #{examined} " <>
        "unenriched rows from the last #{since_days} days"
    )
  end

  defp enrich(attributions, since_days, dry_run?) do
    cutoff = DateTime.add(DateTime.utc_now(), -since_days * 24 * 60 * 60, :second)

    SearchEvent
    |> where([e], e.inserted_at > ^cutoff)
    |> where([e], is_nil(e.client_model))
    |> where([e], not is_nil(e.client_session_id) and not is_nil(e.query))
    |> AdminRepo.all()
    |> Enum.reduce({0, 0}, &enrich_one(&1, &2, attributions, dry_run?))
  end

  defp enrich_one(event, {examined, updated}, attributions, dry_run?) do
    case Map.get(attributions, {event.client_session_id, event.query}) do
      nil -> {examined + 1, updated}
      attribution -> {examined + 1, updated + apply_one(event, attribution, dry_run?)}
    end
  end

  defp apply_one(_event, _attribution, true), do: 1

  defp apply_one(event, attribution, false) do
    apply_attribution(event, attribution)
    1
  end

  # `client_kind` is REFINED, not replaced: `workflow` and `subagent` are both sub-classes
  # of the `child` the client reported, so nothing is lost — "not main" is still recoverable
  # — while the three-way comparison becomes possible. A row the client called `main` is
  # left alone unless the transcript agrees, so a mis-scan cannot relabel the parent.
  defp apply_attribution(event, %{model: model, kind: kind}) do
    changes =
      %{}
      |> put_if(:client_model, model)
      |> put_if(:client_kind, refined_kind(event.client_kind, kind))

    if changes == %{} do
      :ok
    else
      SearchEvent
      |> where([e], e.id == ^event.id)
      |> AdminRepo.update_all(set: Enum.to_list(changes))
    end
  end

  defp refined_kind("main", "main"), do: nil
  defp refined_kind("main", _other), do: nil
  defp refined_kind(_client_kind, kind) when kind in ["workflow", "subagent"], do: kind
  defp refined_kind(_client_kind, _kind), do: nil

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
