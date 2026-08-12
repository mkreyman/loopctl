defmodule Loopctl.Knowledge.SearchEventEnrichmentTest do
  use ExUnit.Case, async: true

  alias Loopctl.Knowledge.SearchEventEnrichment

  @session "49398c56-f49e-4508-acb4-0136e5e43429"

  setup do
    root = Path.join(System.tmp_dir!(), "enrich-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp write_transcript(root, relative, lines) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n")
    path
  end

  defp assistant(model, extra \\ %{}) do
    Map.merge(%{"sessionId" => @session, "message" => %{"model" => model}}, extra)
  end

  defp search(query, tool \\ "mcp__loopctl__knowledge_search", key \\ "query") do
    %{
      "sessionId" => @session,
      "message" => %{
        "content" => [%{"type" => "tool_use", "name" => tool, "input" => %{key => query}}]
      }
    }
  end

  describe "classify/1" do
    test "reads the kind off the transcript's directory" do
      assert SearchEventEnrichment.classify("/p/#{@session}.jsonl") == "main"

      assert SearchEventEnrichment.classify("/p/#{@session}/subagents/agent-x.jsonl") ==
               "subagent"

      assert SearchEventEnrichment.classify("/p/#{@session}/workflows/wf_a/agent-1.jsonl") ==
               "workflow"

      assert SearchEventEnrichment.classify("/p/#{@session}/wf_abc.jsonl") == "workflow"
    end
  end

  describe "scan/1" do
    test "attributes a query to the file that made it, with that file's model", %{root: root} do
      write_transcript(root, "proj/#{@session}.jsonl", [
        assistant("claude-opus-4-8"),
        search("rls tenant scoping")
      ])

      write_transcript(root, "proj/#{@session}/subagents/agent-a.jsonl", [
        assistant("claude-fable-5"),
        search("dispatch lineage")
      ])

      write_transcript(root, "proj/#{@session}/workflows/wf_1/agent-1.jsonl", [
        assistant("claude-sonnet-5"),
        search("capability token replay")
      ])

      index = SearchEventEnrichment.scan(root)

      assert index.by_pair[{@session, "rls tenant scoping"}] ==
               %{model: "claude-opus-4-8", kind: "main", effort: nil}

      assert index.by_pair[{@session, "dispatch lineage"}].kind == "subagent"
      assert index.by_pair[{@session, "capability token replay"}].kind == "workflow"
    end

    test "carries the effort recorded on the transcript", %{root: root} do
      write_transcript(root, "proj/#{@session}/workflows/wf_1/agent-1.jsonl", [
        assistant("claude-opus-5", %{"effort" => "medium"}),
        search("hnsw dead entries")
      ])

      index = SearchEventEnrichment.scan(root)

      # The column this fills was permanently NULL before: CLAUDE_EFFORT is absent from the
      # environment the MCP server is spawned with, so no client could ever have sent it.
      assert index.by_pair[{@session, "hnsw dead entries"}] ==
               %{model: "claude-opus-5", kind: "workflow", effort: "medium"}
    end

    test "reads the historical q and topic spellings too", %{root: root} do
      write_transcript(root, "proj/#{@session}.jsonl", [
        assistant("claude-opus-4-8"),
        search("legacy q spelling", "mcp__loopctl__knowledge_search", "q"),
        search("legacy topic spelling", "mcp__loopctl__knowledge_progressive_index", "topic")
      ])

      index = SearchEventEnrichment.scan(root)

      assert index.by_pair[{@session, "legacy q spelling"}].kind == "main"
      assert index.by_pair[{@session, "legacy topic spelling"}].kind == "main"
    end

    test "drops a pair two files disagree about rather than guessing", %{root: root} do
      write_transcript(root, "proj/#{@session}.jsonl", [
        assistant("claude-opus-4-8"),
        search("shared query")
      ])

      write_transcript(root, "proj/#{@session}/subagents/agent-a.jsonl", [
        assistant("claude-fable-5"),
        search("shared query")
      ])

      index = SearchEventEnrichment.scan(root)

      # An enrichment that guessed here would move the very number the column exists to
      # measure — the per-kind failure rate.
      refute Map.has_key?(index.by_pair, {@session, "shared query"})
      refute Map.has_key?(index.by_query, "shared query")
    end

    test "the same pair recorded identically twice is not ambiguous", %{root: root} do
      write_transcript(root, "proj/#{@session}.jsonl", [
        assistant("claude-opus-4-8"),
        search("repeated query"),
        search("repeated query")
      ])

      index = SearchEventEnrichment.scan(root)

      assert index.by_pair[{@session, "repeated query"}].model == "claude-opus-4-8"
    end

    test "refuses a path the entry's own isSidechain flag contradicts", %{root: root} do
      # A `main` transcript whose entries claim to be a sidechain is evidence the path
      # classification is wrong, not evidence to file the row under.
      write_transcript(root, "proj/#{@session}.jsonl", [
        assistant("claude-opus-5"),
        Map.put(search("contradicted"), "isSidechain", true)
      ])

      index = SearchEventEnrichment.scan(root)

      refute Map.has_key?(index.by_pair, {@session, "contradicted"})
    end

    test "an agreeing isSidechain flag leaves the path classification intact", %{root: root} do
      write_transcript(root, "proj/#{@session}/subagents/agent-a.jsonl", [
        assistant("claude-opus-5"),
        Map.put(search("agreeing"), "isSidechain", true)
      ])

      index = SearchEventEnrichment.scan(root)

      assert index.by_pair[{@session, "agreeing"}].kind == "subagent"
    end

    test "ignores non-search tool calls and unparseable lines", %{root: root} do
      path =
        write_transcript(root, "proj/#{@session}.jsonl", [
          assistant("claude-opus-4-8"),
          %{
            "sessionId" => @session,
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "name" => "mcp__loopctl__knowledge_create",
                  "input" => %{"query" => "not a search"}
                }
              ]
            }
          }
        ])

      File.write!(path, File.read!(path) <> "this is not json\n")

      assert SearchEventEnrichment.scan(root) == %SearchEventEnrichment{}
    end

    test "an entry with no sessionId still indexes by query", %{root: root} do
      write_transcript(root, "proj/orphan.jsonl", [
        %{"message" => %{"model" => "claude-opus-4-8"}},
        %{
          "message" => %{
            "content" => [
              %{
                "type" => "tool_use",
                "name" => "mcp__loopctl__knowledge_search",
                "input" => %{"query" => "unattributable"}
              }
            ]
          }
        }
      ])

      index = SearchEventEnrichment.scan(root)

      assert index.by_pair == %{}
      assert index.by_query["unattributable"].model == "claude-opus-4-8"
    end

    test "an empty root is an empty index, not a crash", %{root: root} do
      File.mkdir_p!(root)
      assert SearchEventEnrichment.scan(root) == %SearchEventEnrichment{}
    end
  end

  describe "lookup/3" do
    setup %{root: root} do
      write_transcript(root, "proj/#{@session}/workflows/wf_1/agent-1.jsonl", [
        assistant("claude-opus-5", %{"effort" => "high"}),
        search("only in one place")
      ])

      %{index: SearchEventEnrichment.scan(root)}
    end

    test "the precise pair wins", %{index: index} do
      assert SearchEventEnrichment.lookup(index, @session, "only in one place").kind ==
               "workflow"
    end

    test "a session id the transcript never recorded falls back to the query", %{index: index} do
      # This is the RESUMED-session case, measured live: the MCP server reports a fresh
      # session id while the transcript keeps appending under the original, so the pair key
      # can never match and every search from a resumed session was unjoinable.
      assert SearchEventEnrichment.lookup(index, Ecto.UUID.generate(), "only in one place") ==
               %{model: "claude-opus-5", kind: "workflow", effort: "high"}
    end

    test "an unknown query resolves to nothing on either key", %{index: index} do
      assert SearchEventEnrichment.lookup(index, @session, "never searched") == nil
    end

    test "a missing session id or query is not a lookup", %{index: index} do
      assert SearchEventEnrichment.lookup(index, nil, "only in one place") == nil
      assert SearchEventEnrichment.lookup(index, @session, nil) == nil
    end
  end
end
