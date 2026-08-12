defmodule Loopctl.Knowledge.SearchEventEnrichment do
  @moduledoc """
  Fills the `search_events` columns that no client can supply, by joining rows to the agent
  session transcripts that recorded them (#652 item 5).

  ## The three gaps, and why they need an offline join

  * **`client_model`** — no model variable exists in the MCP server's environment, so the
    client cannot send it. The transcript records it on every assistant entry.
  * **`client_effort`** — likewise absent. `CLAUDE_EFFORT` is set in the environment of
    Bash-tool invocations but NOT in the environment the MCP server is spawned with, so the
    column was permanently NULL before this filled it. The transcript records `effort`, and
    it carries real variance worth measuring (workflow agents run a mix of `high`,
    `medium` and `low`).
  * **`client_kind`** — the client reports the kind of the SESSION, which is not the kind of
    the CALLER. One MCP server process is spawned per session and serves the main session
    and every agent it dispatches, and its environment is frozen at spawn — so it reports
    `main` for every search, whoever made it. The transcript is the only source that can
    say which branch of the tree a row came from, and the split matters: measured failure
    rates were main 8.2% / workflow 6.0% / subagent 3.7%.

  ## Why the join key is (session, query) and not the session alone

  A subagent's transcript records its PARENT's `sessionId` — measured at 99.5% across this
  machine's corpus — so a session id maps to a whole tree, and on its own it can neither
  name the model a child ran on nor say which branch a row came from. What IS unambiguous is
  the tool call itself: a search made by a subagent appears in that subagent's transcript
  FILE, and the file's path says what it is (`.../subagents/...`, `.../workflows/...`, or
  the session's own `<uuid>.jsonl`).

  ## Why there is also a query-only fallback

  The pair key is right but it is not always available, because **a RESUMED session's MCP
  server reports a session id the transcript never records**. Measured directly: a session
  resumed on 2026-08-12 spawned an MCP server reporting `ff0b1491-…` while the transcript
  kept appending under its original `d73e6085-…`; that id appears as a `sessionId` in zero
  transcripts on the machine. Every search from a resumed session is therefore unjoinable on
  the pair alone — and resuming is routine here.

  So a pair miss falls back to the query alone, and only for a query that resolves to
  exactly ONE attribution across the entire tree. Measured: 96% of distinct queries (968 of
  1,007) appear exactly once, so the fallback recovers nearly all of it while still never
  guessing. The fallback is applied ONLY to rows that carry a `client_session_id`, i.e. rows
  that really came through the MCP client — hook and smoke traffic never reaches it, so a
  coincidental query match cannot attribute a machine-made search to an agent.

  ## Ambiguity is dropped, never guessed

  If one key appears in two files that disagree, it contributes NOTHING. That applies to
  both keys, and to a `path` classification contradicted by the entry's own `isSidechain`
  flag. An enrichment that guesses is worse than a null: the whole point of the columns is
  to support a comparison BETWEEN kinds, and a mis-attributed row moves the very number it
  exists to measure.

  Rows are only ever filled, never overwritten.
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

  @type attribution :: %{
          model: String.t() | nil,
          kind: String.t(),
          effort: String.t() | nil
        }

  @typedoc """
  The two indexes a scan produces. `by_pair` is the precise key; `by_query` is the fallback
  for a resumed session whose MCP-reported id the transcript never saw, and holds ONLY
  queries that are unambiguous across the whole tree.
  """
  @type t :: %__MODULE__{
          by_pair: %{{String.t(), String.t()} => attribution()},
          by_query: %{String.t() => attribution()}
        }

  defstruct by_pair: %{}, by_query: %{}

  @doc """
  Scans `root` for session transcripts and returns the two attribution indexes.

  Keys seen in files that disagree are omitted (see the moduledoc). Unreadable or malformed
  files are skipped with a warning rather than aborting the scan — a transcript tree is a
  historical record and a single bad line must not cost the batch.
  """
  @spec scan(Path.t()) :: t()
  def scan(root) do
    {pairs, queries} =
      root
      |> transcript_files()
      |> Enum.reduce({%{}, %{}}, &merge_file(&2, &1))

    %__MODULE__{by_pair: settled(pairs), by_query: settled(queries)}
  end

  @doc """
  Resolves an attribution for one recorded search, or `nil`.

  The precise `{session_id, query}` key wins. A miss falls back to the query alone, which is
  what recovers a resumed session — see the moduledoc for why that key goes missing and why
  the fallback cannot manufacture an attribution.

  Pass `query_fallback: false` to disable the fallback for a row this machine's transcripts
  cannot possibly explain. A session id is a UUID, so the PAIR key is safe to try against any
  row; a bare query is not. Two machines searching the same wording is ordinary, and their
  transcript trees never see each other — so an ungated fallback would answer another
  machine's row with this machine's model and kind. `same_machine?/1` is the intended gate.
  """
  @spec lookup(t(), String.t() | nil, String.t() | nil, keyword()) :: attribution() | nil
  def lookup(index, session_id, query, opts \\ [])

  def lookup(%__MODULE__{} = index, session_id, query, opts)
      when is_binary(session_id) and is_binary(query) do
    case Map.get(index.by_pair, {session_id, query}) do
      nil -> if Keyword.get(opts, :query_fallback, true), do: Map.get(index.by_query, query)
      attribution -> attribution
    end
  end

  def lookup(%__MODULE__{}, _session_id, _query, _opts), do: nil

  @doc """
  Whether `client_host` names the machine this is running on.

  Compared on the normalised first label rather than verbatim, because the two sides do not
  spell it the same way: the MCP client sends node's `os.hostname()`, which on macOS carries
  the mDNS suffix (`Marks-Mac-mini.local`), while the BEAM reports the bare name
  (`Marks-Mac-mini`). A strict comparison would therefore match on Linux and silently match
  NOTHING on a Mac — the worst shape of failure for a task whose output is a row count.
  """
  @spec same_machine?(String.t() | nil) :: boolean()
  def same_machine?(client_host) when is_binary(client_host) do
    host_label(client_host) == host_label(local_hostname())
  end

  def same_machine?(_client_host), do: false

  defp local_hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end

  defp host_label(host) do
    host |> String.split(".") |> hd() |> String.downcase()
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

  defp settled(map) do
    map
    |> Enum.reject(fn {_key, value} -> value == :ambiguous end)
    |> Map.new()
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
    |> Enum.reduce({acc, %{model: nil, effort: nil}}, fn line, {inner, carried} ->
      case decode(line) do
        nil -> {inner, carried}
        entry -> absorb(inner, entry, kind, carried)
      end
    end)
    |> elem(0)
  rescue
    error ->
      Logger.warning("skipping transcript #{path}: #{inspect(error.__struct__)}")
      acc
  end

  # Threads the last-seen model and effort forward: a transcript records both on assistant
  # entries, and a tool call sits between them, so the value in force is the most recent one
  # seen in the same file.
  defp absorb(acc, entry, kind, carried) do
    carried = %{
      model: entry_model(entry) || carried.model,
      effort: entry_effort(entry) || carried.effort
    }

    case entry_kind(entry, kind) do
      nil -> {acc, carried}
      resolved -> {index_queries(acc, entry, Map.put(carried, :kind, resolved)), carried}
    end
  end

  # `isSidechain` is a per-entry, first-party main-vs-child marker, and it agreed with the
  # path classification on every one of the 447k entries measured. It is read as a CHECK
  # rather than as the classifier because it cannot tell a workflow agent from a subagent —
  # so the path supplies the three-way value and this refuses the pair when they disagree.
  defp entry_kind(entry, kind) do
    case Map.get(entry, "isSidechain") do
      nil -> kind
      false -> if kind == "main", do: kind
      true -> if kind != "main", do: kind
      _other -> kind
    end
  end

  defp index_queries({pairs, queries}, entry, attribution) do
    session_id = session_id(entry)

    entry
    |> queries()
    |> Enum.reduce({pairs, queries}, fn query, {inner_pairs, inner_queries} ->
      {put_key(inner_pairs, session_id && {session_id, query}, attribution),
       put_key(inner_queries, query, attribution)}
    end)
  end

  defp put_key(acc, nil, _attribution), do: acc

  defp put_key(acc, key, attribution) do
    Map.update(acc, key, attribution, fn
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

  defp entry_effort(%{"effort" => effort}) when is_binary(effort) and effort != "", do: effort
  defp entry_effort(_entry), do: nil

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
