defmodule LoopctlWeb.OneSearchCommandTest do
  @moduledoc """
  `knowledge_search` can now produce all three response shapes, so an agent stops choosing
  between tools that run the same search.

  That choice was never just ergonomics. `progressive_index/3` calls `search_keyword/3` and
  caps-and-stubs; `get_context/3` is the combined search returning full bodies. Exposed as
  separate TOOLS they asked an agent to decide, per query, which door to knock on — and that
  decision is unobservable, so it confounds any measurement of the ranking behind them. A
  parameter is a variable we control; a tool choice is a confounder we do not.

  The sibling tools are NOT retired; they share this path.
  """
  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.SearchEvent

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant)
    agent = fixture(:agent, %{tenant_id: tenant.id})
    {raw, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})
    marker = "onecmd#{System.unique_integer([:positive])}"

    fixture(:article, %{
      tenant_id: tenant.id,
      status: :published,
      title: "#{marker} guide",
      body: "#{marker} the body of the one-command guide"
    })

    %{tenant: tenant, agent: agent, raw: raw, marker: marker}
  end

  defp search(raw, qs) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer #{raw}")
    |> Phoenix.ConnTest.get("/api/v1/knowledge/search?#{qs}")
  end

  defp events(tenant_id) do
    from(e in SearchEvent, where: e.tenant_id == ^tenant_id, order_by: e.inserted_at)
    |> AdminRepo.all()
  end

  describe "format parameter" do
    test "defaults to the ranked results shape", %{raw: raw, marker: marker} do
      body = json_response(search(raw, "q=#{marker}"), 200)

      assert is_list(body["data"])
      assert body["meta"]["search_mode"]
    end

    test "format=stubs returns the progressive shape", %{raw: raw, marker: marker} do
      body = json_response(search(raw, "q=#{marker}&format=stubs"), 200)

      assert is_list(body["data"])
      assert is_integer(body["meta"]["top_k"])
      assert Map.has_key?(body["meta"], "candidate_count")
    end

    test "format=bodies returns full bodies", %{raw: raw, marker: marker} do
      body = json_response(search(raw, "q=#{marker}&format=bodies"), 200)

      assert [%{"body" => article_body} | _] = body["data"]
      assert article_body =~ marker
    end

    test "an unknown format is refused rather than silently ranked", %{raw: raw, marker: marker} do
      conn = search(raw, "q=#{marker}&format=nonsense")
      assert conn.status == 400
    end

    test "a shaped format without a query is refused", %{raw: raw} do
      # These are relevance shapes; there is no stub rendering of an enumeration page, and
      # quietly returning the ranked shape would answer a different question.
      conn = search(raw, "tags=anything&format=stubs")
      assert conn.status == 400
    end
  end

  describe "telemetry attributes every shape to the one command" do
    test "a stubs search records tool=knowledge_search with the shape in mode_used", %{
      tenant: tenant,
      agent: agent,
      raw: raw,
      marker: marker
    } do
      search(raw, "q=#{marker}&format=stubs")

      # Recording it as the sibling tool would split one command's traffic across three
      # names and undo the comparability the parameter exists to create.
      assert [event] = events(tenant.id)
      assert event.tool == "knowledge_search"
      assert event.mode_used == "progressive"
      assert event.agent_id == agent.id
      assert is_integer(event.duration_ms)
    end

    test "a bodies search does the same", %{tenant: tenant, raw: raw, marker: marker} do
      search(raw, "q=#{marker}&format=bodies")

      assert [event] = events(tenant.id)
      assert event.tool == "knowledge_search"
      assert event.mode_used == "context"
    end

    test "a shaped miss is recorded as zero_results, not as nothing", %{
      tenant: tenant,
      raw: raw
    } do
      search(raw, "q=nothingmatchesthisatall#{System.unique_integer([:positive])}&format=stubs")

      assert [event] = events(tenant.id)
      assert event.outcome == "zero_results"
      assert event.result_count == 0
    end
  end
end
