defmodule Loopctl.Knowledge.SearchEventEnrichment do
  @moduledoc """
  Fills the two `search_events` columns that no client can supply, by joining rows to the
  agent session transcripts that recorded them (#652 item 5).

  ## The two gaps, and why they need an offline join

  * **`client_model`** — no model variable exists in the agent environment, so the MCP
    client cannot send it. The transcript records it.
  * **`client_kind`** — the client can only tell `main` from `child`. Splitting a WORKFLOW
    agent from an ordinary SUBAGENT needs the transcript too, and the split matters:
    measured failure rates were main 8.2% / workflow 6.0% / subagent 3.7%, which is a
    three-way spread that `child` averages away.

  ## Why the join key is (session, query) and not the session alone

  A subagent's transcript records its PARENT's `sessionId`, not its own. So a session id
  maps to a whole tree, and on its own it can neither name the model a child ran on nor say
  which branch of the tree a row came from. What IS unambiguous is the tool call itself: a
  search made by a subagent appears in that subagent's transcript FILE, and the file's path
  says what it is (`.../subagents/...`, `.../workflows/...`, or the session's own
  `<uuid>.jsonl`).

  So the unit of the join is `{session_id, query}`, resolved from the tool-call arguments,
  carrying the model recorded in that same file.

  ## Ambiguity is dropped, never guessed

  If one `{session_id, query}` pair appears in two files that disagree (the same query run
  by both a subagent and the main session, which happens with retry loops), the pair is
  marked ambiguous and contributes NOTHING. An enrichment that guesses is worse than a null:
  the whole point of the column is to support a comparison between kinds, and a
  mis-attributed row moves the number it exists to measure.

  Rows are only ever filled, never overwritten: a row that already has a `client_model`
  keeps it.
  """

  require Logger

  # The loopctl MCP tools whose arguments carry a search query. `topic` and `q` are the
  # historical spellings of `query` (#652 item 6) and both still reach the server, so all
  # three are read here — a transcript is a historical record and will carry them for as
  # long as it exists.
  @query_keys ~w(query q topic)
  @search_tools ~w(
    mcp__loopctl__knowledge_search
    mcp__loopctl__knowledge_hybrid_search
    mcp__loopctl__knowledge_context
    mcp__loopctl__knowledge_progressive_index
    mcp__loopctl__memory_recall
    mcp__loopctl__recall_context
  )

  @type attribution :: %{model: String.t() | nil, kind: String.t()}

  @doc """
  Scans `root` for session transcripts and returns `%{{session_id, query} => attribution}`.

  Pairs seen in files that disagree about kind or model are omitted (see the moduledoc).
  Unreadable or malformed files are skipped with a warning rather than aborting the scan —
  a transcript tree is other people's data and a single bad line must not cost the batch.
  """
  @spec scan(Path.t()) :: %{{String.t(), String.t()} => attribution()}
  def scan(root) do
    root
    |> transcript_files()
    |> Enum.reduce(%{}, fn path, acc -> merge_file(acc, path) end)
    |> Enum.reject(fn {_key, value} -> value == :ambiguous end)
    |> Map.new()
  end

  @doc """
  Classifies a transcript path.

  The directory is the evidence: a workflow agent's transcript lives under `workflows/`
  (or is named `wf_*`), a subagent's under `subagents/`, and a session's own transcript is
  the `<uuid>.jsonl` beside them.
  """
  @spec classify(Path.t()) :: String.t()
  def classify(path) do
    segments = Path.split(path)
    basename = Path.basename(path)

    cond do
      "workflows" in segments or String.starts_with?(basename, "wf_") -> "workflow"
      "subagents" in segments -> "subagent"
      true -> "main"
    end
  end

  defp transcript_files(root) do
    root
    |> Path.join("**/*.jsonl")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp merge_file(acc, path) do
    kind = classify(path)

    path
    |> File.stream!()
    |> Enum.reduce({acc, nil}, fn line, {inner, model} ->
      case decode(line) do
        nil -> {inner, model}
        entry -> absorb(inner, entry, kind, model)
      end
    end)
    |> elem(0)
  rescue
    error ->
      Logger.warning("skipping transcript #{path}: #{inspect(error.__struct__)}")
      acc
  end

  # Threads the last-seen model forward: a transcript records the model on assistant
  # entries, and a tool call sits between them, so the model in force is the most recent
  # one seen in the same file.
  defp absorb(acc, entry, kind, model) do
    model = entry_model(entry) || model
    session_id = session_id(entry)

    acc =
      entry
      |> queries()
      |> Enum.reduce(acc, fn query, inner ->
        put_attribution(inner, session_id, query, %{model: model, kind: kind})
      end)

    {acc, model}
  end

  defp put_attribution(acc, nil, _query, _attribution), do: acc

  defp put_attribution(acc, session_id, query, attribution) do
    Map.update(acc, {session_id, query}, attribution, fn
      :ambiguous -> :ambiguous
      ^attribution -> attribution
      _conflicting -> :ambiguous
    end)
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, %{} = entry} -> entry
      _ -> nil
    end
  end

  defp session_id(%{"sessionId" => id}) when is_binary(id), do: id
  defp session_id(_entry), do: nil

  defp entry_model(%{"message" => %{"model" => model}}) when is_binary(model), do: model
  defp entry_model(%{"model" => model}) when is_binary(model), do: model
  defp entry_model(_entry), do: nil

  # Tool-call entries nest their content under `message.content`, each item carrying a
  # `name` and an `input`. Anything else in the transcript contributes no queries.
  defp queries(%{"message" => %{"content" => content}}) when is_list(content) do
    content
    |> Enum.filter(&search_tool_use?/1)
    |> Enum.flat_map(&query_values/1)
  end

  defp queries(_entry), do: []

  defp search_tool_use?(%{"type" => "tool_use", "name" => name}), do: name in @search_tools
  defp search_tool_use?(_item), do: false

  defp query_values(%{"input" => %{} = input}) do
    @query_keys
    |> Enum.map(&Map.get(input, &1))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp query_values(_item), do: []
end
