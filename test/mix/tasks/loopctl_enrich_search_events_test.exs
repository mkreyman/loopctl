defmodule Mix.Tasks.Loopctl.EnrichSearchEventsTest do
  @moduledoc """
  Covers the half of the enrichment that decides WHICH rows to touch and WHAT to write.

  Both defects this test pins were in exactly that half, and neither was reachable from the
  scanner's own tests: the row-selection query skipped any row whose `client_model` was
  already filled, and the kind guard refused to move a row the client called `main` — which
  is every row, since the client reports the SESSION's kind, not the caller's.
  """
  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.SearchEvent
  alias Mix.Tasks.Loopctl.EnrichSearchEvents

  @session "49398c56-f49e-4508-acb4-0136e5e43429"

  setup do
    root = Path.join(System.tmp_dir!(), "enrich-task-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, tenant: fixture(:tenant)}
  end

  defp write_transcript(root, relative, model, query, extra \\ %{}) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))

    lines = [
      Map.merge(%{"sessionId" => @session, "message" => %{"model" => model}}, extra),
      %{
        "sessionId" => @session,
        "message" => %{
          "content" => [
            %{
              "type" => "tool_use",
              "name" => "mcp__loopctl__knowledge_search",
              "input" => %{"query" => query}
            }
          ]
        }
      }
    ]

    File.write!(path, Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n")
  end

  defp record(tenant, attrs) do
    AdminRepo.insert!(
      struct(
        SearchEvent,
        Map.merge(
          %{
            tenant_id: tenant.id,
            query: "q",
            tool: "knowledge_search",
            outcome: "ok",
            result_count: 3,
            client_session_id: @session,
            # A real row never has one without the other: the client sends session id and
            # host in the same payload, and the host is what licenses the query fallback.
            client_host: local_host(),
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          },
          attrs
        )
      )
    )
  end

  defp local_host do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end

  defp reload(event), do: AdminRepo.get!(SearchEvent, event.id)

  defp run(root, extra \\ []) do
    EnrichSearchEvents.run(["--transcripts", root] ++ extra)
  end

  describe "run/1" do
    test "corrects the session-level main a client asserts to the caller's real kind", %{
      root: root,
      tenant: tenant
    } do
      write_transcript(
        root,
        "p/#{@session}/workflows/wf_1/a.jsonl",
        "claude-opus-5",
        "wf query",
        %{
          "effort" => "medium"
        }
      )

      event = record(tenant, %{query: "wf query", client_kind: "main"})

      run(root)

      # The old guard read `refined_kind("main", _) -> nil` and would have left this row at
      # `main`. Since the MCP server labels EVERY search `main`, that suppressed the whole
      # three-way split — 74% of agent searches on the measured corpus.
      assert %{client_kind: "workflow", client_model: "claude-opus-5", client_effort: "medium"} =
               reload(event)
    end

    test "a row whose model is already filled is still eligible for the kind fix", %{
      root: root,
      tenant: tenant
    } do
      write_transcript(root, "p/#{@session}/subagents/a.jsonl", "claude-fable-5", "sub query")

      event =
        record(tenant, %{
          query: "sub query",
          client_kind: "main",
          client_model: "already-recorded"
        })

      run(root)

      # The selection query used to require `client_model IS NULL`, so a second pass could
      # never repair a kind — the row was filtered out before the decision ran.
      assert %{client_kind: "subagent", client_model: "already-recorded"} = reload(event)
    end

    test "recovers a resumed session by falling back to an unambiguous query", %{
      root: root,
      tenant: tenant
    } do
      write_transcript(root, "p/#{@session}/workflows/wf_1/a.jsonl", "claude-opus-5", "resumed q")

      # A resumed session's MCP server reports an id the transcript never records.
      event = record(tenant, %{query: "resumed q", client_session_id: Ecto.UUID.generate()})

      run(root)

      assert %{client_kind: "workflow", client_model: "claude-opus-5"} = reload(event)
    end

    test "never attributes a row that did not come through the MCP client", %{
      root: root,
      tenant: tenant
    } do
      write_transcript(root, "p/#{@session}/workflows/wf_1/a.jsonl", "claude-opus-5", "elixir")

      # Hook and smoke traffic carries no client_session_id. A coincidental query match must
      # not label a machine-made search as an agent's.
      event = record(tenant, %{query: "elixir", client_session_id: nil})

      run(root)

      assert %{client_kind: nil, client_model: nil} = reload(event)
    end

    test "will not answer another machine's row from this machine's transcripts", %{
      root: root,
      tenant: tenant
    } do
      write_transcript(root, "p/#{@session}/workflows/wf_1/a.jsonl", "claude-opus-5", "shared q")

      event =
        record(tenant, %{
          query: "shared q",
          client_session_id: Ecto.UUID.generate(),
          client_host: "Marks-Mac-mini.local"
        })

      run(root)

      assert %{client_kind: nil, client_model: nil} = reload(event)
    end

    test "still answers a row from this machine via the fallback", %{root: root, tenant: tenant} do
      write_transcript(root, "p/#{@session}/workflows/wf_1/a.jsonl", "claude-opus-5", "local q")

      event =
        record(tenant, %{
          query: "local q",
          client_session_id: Ecto.UUID.generate(),
          client_host: local_host()
        })

      run(root)

      assert %{client_kind: "workflow", client_model: "claude-opus-5"} = reload(event)
    end

    test "--dry-run writes nothing", %{root: root, tenant: tenant} do
      write_transcript(root, "p/#{@session}/workflows/wf_1/a.jsonl", "claude-opus-5", "dry q")

      event = record(tenant, %{query: "dry q", client_kind: "main"})

      run(root, ["--dry-run"])

      assert %{client_kind: "main", client_model: nil} = reload(event)
    end

    test "leaves a row outside the window alone", %{root: root, tenant: tenant} do
      write_transcript(root, "p/#{@session}/workflows/wf_1/a.jsonl", "claude-opus-5", "old q")

      stale = DateTime.add(DateTime.utc_now(), -60 * 24 * 60 * 60, :second)
      event = record(tenant, %{query: "old q", client_kind: "main", inserted_at: stale})

      run(root, ["--since-days", "30"])

      assert %{client_kind: "main"} = reload(event)
    end

    test "is idempotent — a second run changes nothing further", %{root: root, tenant: tenant} do
      write_transcript(root, "p/#{@session}/subagents/a.jsonl", "claude-opus-5", "twice q")

      event = record(tenant, %{query: "twice q", client_kind: "main"})

      run(root)
      first = reload(event)
      run(root)

      assert reload(event).client_kind == first.client_kind
      assert reload(event).client_model == first.client_model
    end

    test "an unmatched row is examined and left untouched", %{root: root, tenant: tenant} do
      File.mkdir_p!(root)
      event = record(tenant, %{query: "nothing knows this", client_kind: "main"})

      run(root)

      assert %{client_kind: "main", client_model: nil} = reload(event)
    end

    test "counts every eligible row it examined", %{root: root, tenant: tenant} do
      write_transcript(root, "p/#{@session}/workflows/wf_1/a.jsonl", "claude-opus-5", "counted")
      record(tenant, %{query: "counted", client_kind: "main"})

      run(root)

      assert AdminRepo.one(
               from(e in SearchEvent, where: e.client_kind == "workflow", select: count())
             ) == 1
    end
  end
end
