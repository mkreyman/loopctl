defmodule Mix.Tasks.Loopctl.EnrichSearchEvents do
  @shortdoc "Fills search_events.client_model / client_kind from local session transcripts"

  @moduledoc """
  Joins `search_events` rows to the agent session transcripts that produced them, filling
  the three columns no client can supply (#652 item 5).

  `client_model` and `client_effort` have no source in the MCP server's environment, and
  `client_kind` reports the kind of the SESSION rather than of the CALLER — one MCP process
  serves a session and every agent it dispatches, so it says `main` for every search. The
  transcript is the only source for all three. The kind split is worth having: measured
  failure rates were main 8.2% / workflow 6.0% / subagent 3.7%, a spread `main` flattens
  entirely.

  See `Loopctl.Knowledge.SearchEventEnrichment` for how the join is keyed, why a resumed
  session needs a query-only fallback, and why an ambiguous key is dropped rather than
  guessed.

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
    index = SearchEventEnrichment.scan(root)

    Mix.shell().info(
      "resolved #{map_size(index.by_pair)} (session, query) pairs, " <>
        "#{map_size(index.by_query)} unambiguous queries for the resumed-session fallback"
    )

    {examined, updated} = enrich(index, since_days, dry_run?)

    Mix.shell().info(
      "#{if dry_run?, do: "would update", else: "updated"} #{updated} of #{examined} " <>
        "unenriched rows from the last #{since_days} days"
    )
  end

  # A row is a candidate while ANY of the three columns is still fillable. Selecting on
  # `client_model IS NULL` alone left every row whose model was already filled stuck with the
  # session-level `main` the client reported, which is the value the kind split exists to
  # replace.
  #
  # `client_session_id` is still required: it is what says the row came through the MCP
  # client at all. Hook and smoke traffic never carries one — the UserPromptSubmit recall
  # hook and `scripts/smoke.sh` call the API directly — and attributing one of those to an
  # agent from a coincidental query match would corrupt the per-kind comparison.
  #
  # That refusal is held in TWO independent places: this predicate, and `lookup/3`'s
  # `is_binary(session_id)` guard, which is what stops the query-only fallback from firing
  # for a row that has no session at all. Verified by mutation: removing either one alone
  # leaves the test green because the other still catches it, and removing BOTH turns the
  # hook-traffic row red. Keep both — the fallback is exactly the mechanism that would make
  # a single missed check silently mislabel automation as agent traffic.
  defp enrich(index, since_days, dry_run?) do
    cutoff = DateTime.add(DateTime.utc_now(), -since_days * 24 * 60 * 60, :second)

    SearchEvent
    |> where([e], e.inserted_at > ^cutoff)
    |> where([e], not is_nil(e.client_session_id) and not is_nil(e.query))
    |> where(
      [e],
      is_nil(e.client_model) or is_nil(e.client_effort) or is_nil(e.client_kind) or
        e.client_kind == "main"
    )
    |> AdminRepo.all()
    |> Enum.reduce({0, 0}, &enrich_one(&1, &2, index, dry_run?))
  end

  defp enrich_one(event, {examined, updated}, index, dry_run?) do
    case SearchEventEnrichment.lookup(index, event.client_session_id, event.query) do
      nil -> {examined + 1, updated}
      attribution -> {examined + 1, updated + apply_one(event, attribution, dry_run?)}
    end
  end

  defp apply_one(event, attribution, dry_run?) do
    changes = changes_for(event, attribution)

    cond do
      changes == %{} -> 0
      dry_run? -> 1
      true -> write(event, changes)
    end
  end

  defp write(event, changes) do
    SearchEvent
    |> where([e], e.id == ^event.id)
    |> AdminRepo.update_all(set: Enum.to_list(changes))

    1
  end

  # `client_model` and `client_effort` are FILL-ONLY — a value a client actually sent is
  # never overwritten. `client_kind` is different, and deliberately so.
  #
  # This guard used to read `refined_kind("main", _) -> nil`, written so a mis-scan could
  # not relabel a parent session. It could not do that job: the client reports the kind of
  # the SESSION, and one MCP process serves the session AND every agent it dispatches with
  # an environment frozen at spawn — so it labels EVERY search `main`, whoever made it.
  # Refusing to move `main` therefore blocked essentially every correct relabel. Measured on
  # one machine's corpus: 74% of agent searches come from a workflow or subagent, so the
  # guard suppressed nearly all of the signal the column exists to carry.
  #
  # The transcript's kind is caller-level evidence and wins over the client's session-level
  # assertion. It is still never a guess: a key two transcripts disagree about, or a path
  # contradicted by the entry's own `isSidechain`, never reaches here at all.
  defp changes_for(event, %{model: model, kind: kind, effort: effort}) do
    %{}
    |> put_if(:client_model, fill_only(event.client_model, model))
    |> put_if(:client_effort, fill_only(event.client_effort, effort))
    |> put_if(:client_kind, corrected_kind(event.client_kind, kind))
  end

  defp fill_only(nil, value), do: value
  defp fill_only(_existing, _value), do: nil

  defp corrected_kind(same, same), do: nil
  defp corrected_kind(_client_kind, kind) when kind in ["workflow", "subagent", "main"], do: kind
  defp corrected_kind(_client_kind, _kind), do: nil

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
