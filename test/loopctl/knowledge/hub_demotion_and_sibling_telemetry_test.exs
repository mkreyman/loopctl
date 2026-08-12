defmodule Loopctl.Knowledge.HubDemotionAndSiblingTelemetryTest do
  @moduledoc """
  #654 / #658 follow-ups: the two fixes that were applied on ONE surface and left the
  siblings behind.

  Both defects have the same shape and the same reason they survived review — the fix was
  verified on the surface it was written for, and the surfaces that share the underlying
  function were never exercised. So each test here pins a SIBLING, not the original:

    * hub demotion reaching `knowledge_context` and `Memory.recall_context/2`, which
      re-rank on their own score and never see `search_combined`'s fused `:final_score`
      (and `knowledge_context` returns FULL BODIES, so an undemoted hub costs more here);
    * `search_events` rows from recall and hybrid search, which were written with a NULL
      agent and mislabelled `tool = "knowledge_search"` — the one table built to tell the
      surfaces apart could not tell them apart;
    * and, on the third recurrence of the same shape, `progressive_index` and
      `knowledge_context`, which recorded NO attempt at all. Both suppress their inner
      search's recorder so a candidate-pool query is not counted as its own search, and
      neither then recorded the outer call — so on the surface whose documented weakness is
      a paraphrased miss, every miss was invisible.
  """
  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.SearchEvent
  alias Loopctl.Memory
  alias Loopctl.Memory.Scope

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant)
    Knowledge.reset_circuit_breaker(tenant.id)
    %{tenant: tenant}
  end

  # A hub and a real answer that BOTH match the marker, so ranking is the only thing
  # separating them. The hub carries the worker's real idempotency_key.
  defp hub_and_answer(tenant_id, marker) do
    hub =
      fixture(:article, %{
        tenant_id: tenant_id,
        status: :published,
        category: :reference,
        title: "Index: #{marker}",
        body: "#{marker} #{marker} #{marker} member titles listing for #{marker}",
        tags: ["hub", "moc", marker],
        idempotency_key: "moc:#{marker}"
      })

    answer =
      fixture(:article, %{
        tenant_id: tenant_id,
        status: :published,
        category: :reference,
        title: "#{marker} runbook",
        body: "#{marker} the actual answer about #{marker}",
        tags: [marker]
      })

    {hub, answer}
  end

  defp embed(tenant_id, article, vector) do
    {:ok, updated} = Knowledge.update_embedding(tenant_id, article.id, vector)
    updated
  end

  describe "hub demotion reaches knowledge_context (full-body surface)" do
    test "an index hub does not outrank a real answer in context results", %{tenant: tenant} do
      marker = "hubctx#{System.unique_integer([:positive])}"
      {hub, answer} = hub_and_answer(tenant.id, marker)

      {:ok, %{results: results}} = Knowledge.get_context(tenant.id, marker, limit: 10)

      ids = Enum.map(results, & &1.id)

      # NON-VACUITY: both must be in the candidate set, or the ordering assertion below
      # passes for the wrong reason (a filtered-out hub proves nothing about ranking).
      assert answer.id in ids, "the real answer must be present at all"
      assert hub.id in ids, "the hub must be RANKED, not excluded — demoted, not hidden"

      assert Enum.find_index(ids, &(&1 == answer.id)) <
               Enum.find_index(ids, &(&1 == hub.id)),
             "knowledge_context returns FULL BODIES — a hub above the answer is the " <>
               "most expensive place for this bug to survive"
    end
  end

  describe "hub demotion reaches Memory.recall_context/2" do
    test "an index hub is scored below a real answer on the merged recall list", %{
      tenant: tenant
    } do
      marker = "hubrec#{System.unique_integer([:positive])}"
      {hub, answer} = hub_and_answer(tenant.id, marker)

      # Identical embeddings: the semantic lane cannot separate them, so any ordering
      # difference comes from the demotion and nothing else.
      vector = List.duplicate(0.1, 1536)
      embed(tenant.id, hub, vector)
      embed(tenant.id, answer, vector)

      scope = %Scope{
        tenant_id: tenant.id,
        subject_id: "subject-#{System.unique_integer([:positive])}",
        project_id: nil
      }

      result = Memory.recall_context(scope, query: marker, limit: 20)

      scores =
        result.results
        |> Enum.filter(&(&1.source == :knowledge))
        |> Map.new(&{&1.article.id, &1.score})

      # NON-VACUITY: both scored, or the comparison below is not comparing anything.
      assert Map.has_key?(scores, hub.id), "the hub must be scored, not filtered out"
      assert Map.has_key?(scores, answer.id)

      assert scores[answer.id] > scores[hub.id],
             "recall merges knowledge against the agent's OWN memories on this one " <>
               "number, so an undemoted hub outranks the agent's memories too"
    end
  end

  describe "recall writes search_events rows that name their own surface" do
    setup %{tenant: tenant} do
      agent = fixture(:agent, %{tenant_id: tenant.id})

      {raw, api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      %{agent: agent, api_key: api_key, raw: raw}
    end

    test "a recall records tool=memory_recall, not knowledge_search", %{
      tenant: tenant,
      api_key: api_key,
      agent: agent,
      raw: raw
    } do
      marker = "recalltel#{System.unique_integer([:positive])}"

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{raw}")
        |> Plug.Conn.put_req_header("content-type", "application/json")

      Phoenix.ConnTest.post(conn, ~p"/api/v1/recall", %{"query" => marker, "limit" => 5})

      events = all_search_events(tenant.id)
      assert events != [], "recall must record its search attempt at all"

      [event | _] = events

      assert event.tool == "memory_recall",
             "recall traffic filed under knowledge_search makes the two surfaces " <>
               "indistinguishable in the table built to distinguish them"

      assert event.api_key_id == api_key.id
      assert event.agent_id == agent.id, "WHO recalled, not NULL"
      assert is_integer(event.duration_ms)
    end
  end

  describe "hybrid search records its attempts like every other search surface" do
    setup %{tenant: tenant} do
      agent = fixture(:agent, %{tenant_id: tenant.id})

      {raw, api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      %{agent: agent, api_key: api_key, raw: raw}
    end

    defp hybrid_post(raw, body) do
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer #{raw}")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Phoenix.ConnTest.post(~p"/api/v1/knowledge/hybrid_search", body)
    end

    test "a successful hybrid search names its tool, agent and duration", %{
      tenant: tenant,
      agent: agent,
      raw: raw
    } do
      marker = "hybtel#{System.unique_integer([:positive])}"

      fixture(:article, %{
        tenant_id: tenant.id,
        status: :published,
        title: "#{marker} note",
        body: "#{marker} body"
      })

      hybrid_post(raw, %{"query" => marker})

      [event | _] = all_search_events(tenant.id)
      assert event.tool == "knowledge_hybrid_search"
      assert event.mode_requested == "hybrid"
      assert event.agent_id == agent.id
      assert is_integer(event.duration_ms)
    end

    test "a REJECTED hybrid call is recorded — otherwise the surface reads as 0% failure",
         %{tenant: tenant, raw: raw} do
      conn = hybrid_post(raw, %{"query" => ""})
      assert conn.status == 400

      [event] = all_search_events(tenant.id)
      assert event.outcome == "rejected"
      assert event.tool == "knowledge_hybrid_search"
      assert event.rejection_reason == "missing_query"
    end
  end

  describe "progressive_index and knowledge_context record their attempts too" do
    setup %{tenant: tenant} do
      agent = fixture(:agent, %{tenant_id: tenant.id})

      {raw, api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      %{agent: agent, api_key: api_key, raw: raw}
    end

    defp authed_get(raw, path) do
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer #{raw}")
      |> Phoenix.ConnTest.get(path)
    end

    test "progressive_index records the OUTER attempt, not its seed search", %{
      tenant: tenant,
      agent: agent,
      raw: raw
    } do
      marker = "progtel#{System.unique_integer([:positive])}"

      fixture(:article, %{
        tenant_id: tenant.id,
        status: :published,
        title: "#{marker} note",
        body: "#{marker} body"
      })

      authed_get(raw, ~p"/api/v1/knowledge/progressive_index?topic=#{marker}")

      # Exactly ONE row for the call: the outer attempt, never the seed query as well.
      #
      # Two things independently keep the seed out, and mutation testing is what separated
      # them: removing `_skip_record_access: true` from the inner `search_keyword/3` call
      # changes nothing here, because that call also never threads an `api_key_id` and the
      # recorder skips a search without one. So this pins the COUNT, which is the property
      # that matters; it does not prove the flag is what enforces it.
      assert [event] = all_search_events(tenant.id)
      assert event.tool == "knowledge_progressive_index"
      assert event.agent_id == agent.id
      assert is_integer(event.duration_ms)
    end

    test "a progressive_index MISS is recorded as zero_results", %{tenant: tenant, raw: raw} do
      miss = "progmiss#{System.unique_integer([:positive])}"

      authed_get(raw, ~p"/api/v1/knowledge/progressive_index?topic=#{miss}")

      # This is the whole point of covering this surface: a paraphrased topic failing to
      # reach a lexically dissimilar article is progressive_index's documented weakness, and
      # it left no trace anywhere before.
      assert [event] = all_search_events(tenant.id)
      assert event.outcome == "zero_results"
      assert event.result_count == 0
    end

    test "knowledge_context records its attempt naming its own surface", %{
      tenant: tenant,
      agent: agent,
      raw: raw
    } do
      marker = "ctxtel#{System.unique_integer([:positive])}"

      fixture(:article, %{
        tenant_id: tenant.id,
        status: :published,
        title: "#{marker} note",
        body: "#{marker} body"
      })

      authed_get(raw, ~p"/api/v1/knowledge/context?query=#{marker}")

      assert [event] = all_search_events(tenant.id)
      assert event.tool == "knowledge_context"
      assert event.agent_id == agent.id
      assert is_integer(event.duration_ms)
    end

    test "a knowledge_context MISS is recorded as zero_results", %{tenant: tenant, raw: raw} do
      miss = "ctxmiss#{System.unique_integer([:positive])}"

      authed_get(raw, ~p"/api/v1/knowledge/context?query=#{miss}")

      assert [event] = all_search_events(tenant.id)
      assert event.outcome == "zero_results"
      assert event.result_count == 0
    end
  end

  defp all_search_events(tenant_id) do
    from(e in SearchEvent, where: e.tenant_id == ^tenant_id, order_by: e.inserted_at)
    |> Loopctl.AdminRepo.all()
  end
end
