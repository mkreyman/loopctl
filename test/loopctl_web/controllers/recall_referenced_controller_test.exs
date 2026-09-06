defmodule LoopctlWeb.RecallReferencedControllerTest do
  @moduledoc """
  `POST /api/v1/recall/:recall_id/referenced` — the third funnel stage.

  Surfaced and opened are both observations the server made. This one is a CLIENT
  ASSERTION, so most of what is pinned here is the bound on it: only articles the named
  recall actually surfaced, only inside the caller's own tenant, all-or-nothing, and never
  admitted to any ranking.
  """
  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.ArticleAccessEvent

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp base_conn,
    do: put_req_header(build_conn(), "x-loopctl-last-known-sth", "0:AAAAAAAAAAAAAAAAAAAAAA")

  defp agent_key(tenant_id) do
    agent = fixture(:agent, %{tenant_id: tenant_id})
    {raw, key} = fixture(:api_key, %{tenant_id: tenant_id, role: :agent, agent_id: agent.id})
    {raw, key, agent}
  end

  # The surfacing rows a recall writes: one per surfaced result, all sharing the recall's
  # id as their `search_id`. Seeded directly so the admission check is exercised without
  # depending on a live search's ranking.
  defp surfaced(tenant_id, api_key_id, articles, recall_id) do
    Enum.each(articles, fn article ->
      fixture(:article_access_event, %{
        tenant_id: tenant_id,
        api_key_id: api_key_id,
        article_id: article.id,
        access_type: "search",
        metadata: %{"search_id" => recall_id, "mode" => "combined", "results_returned" => 1}
      })
    end)

    recall_id
  end

  defp referenced_rows(tenant_id) do
    from(e in ArticleAccessEvent,
      where: e.tenant_id == ^tenant_id and e.access_type == "referenced"
    )
    |> AdminRepo.all()
  end

  defp article(tenant_id, title \\ "reshipment guide") do
    fixture(:article, %{tenant_id: tenant_id, status: :published, title: title})
  end

  describe "POST /api/v1/recall/:recall_id/referenced" do
    test "records a reference for an article the recall surfaced" do
      tenant = fixture(:tenant)
      {raw, key, _agent} = agent_key(tenant.id)
      a = article(tenant.id)
      recall_id = surfaced(tenant.id, key.id, [a], Ecto.UUID.generate())

      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall/#{recall_id}/referenced", %{"article_ids" => [a.id]})
        |> json_response(200)

      assert body["data"]["recall_id"] == recall_id
      assert body["data"]["article_ids"] == [a.id]
      assert body["data"]["recorded"] == 1

      assert [row] = referenced_rows(tenant.id)
      assert row.article_id == a.id
      assert row.access_type == "referenced"

      # The origin is stamped from the VERIFIED recall id — that is what ties the reference
      # back to the recall in `RetrievalMetrics`.
      assert row.origin_search_id == recall_id
      assert row.metadata["recall_id"] == recall_id

      # `origin_attribution`'s vocabulary describes how a server-side LOOKUP established an
      # origin. This one was asserted and checked, and leaving it NULL is also what keeps
      # `attributed_opens`/`direct_opens` counting reads only.
      assert is_nil(row.origin_attribution)

      # The recording key is the CALLER'S, resolved server-side.
      assert row.api_key_id == key.id
    end

    test "an id the recall did not surface fails the WHOLE call and writes nothing" do
      tenant = fixture(:tenant)
      {raw, key, _agent} = agent_key(tenant.id)
      surfaced_article = article(tenant.id, "surfaced")
      other = article(tenant.id, "never surfaced")
      recall_id = surfaced(tenant.id, key.id, [surfaced_article], Ecto.UUID.generate())

      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall/#{recall_id}/referenced", %{
          "article_ids" => [surfaced_article.id, other.id]
        })
        |> json_response(422)

      assert body["error"]["code"] == "not_surfaced"
      assert body["error"]["details"]["article_ids"] == [other.id]

      # All-or-nothing: the surfaced id in the same call is NOT recorded either. A partial
      # write would record a truth mixed with a rejection under one id.
      assert referenced_rows(tenant.id) == []
    end

    test "an unknown recall_id takes the same 422 — no existence oracle" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)
      a = article(tenant.id)

      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall/#{Ecto.UUID.generate()}/referenced", %{
          "article_ids" => [a.id]
        })
        |> json_response(422)

      assert body["error"]["code"] == "not_surfaced"
      assert referenced_rows(tenant.id) == []
    end

    test "tenant isolation: another tenant's recall_id surfaced nothing here" do
      # The surfacing lookup is tenant-scoped, so tenant B naming tenant A's recall gets the
      # ordinary `not_surfaced` refusal — it learns nothing about whether that recall or that
      # article exists, and nothing is written in EITHER tenant.
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {_raw_a, key_a, _agent_a} = agent_key(tenant_a.id)
      {raw_b, _key_b, _agent_b} = agent_key(tenant_b.id)

      a = article(tenant_a.id)
      recall_id = surfaced(tenant_a.id, key_a.id, [a], Ecto.UUID.generate())

      body =
        base_conn()
        |> auth(raw_b)
        |> post(~p"/api/v1/recall/#{recall_id}/referenced", %{"article_ids" => [a.id]})
        |> json_response(422)

      assert body["error"]["code"] == "not_surfaced"
      assert referenced_rows(tenant_a.id) == []
      assert referenced_rows(tenant_b.id) == []
    end

    test "a malformed recall_id is a 422 invalid_recall_id" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)
      a = article(tenant.id)

      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall/not-a-uuid/referenced", %{"article_ids" => [a.id]})
        |> json_response(422)

      assert body["error"]["code"] == "invalid_recall_id"
    end

    test "a missing, empty, non-list or non-UUID article_ids is a 422 invalid_article_ids" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)
      recall_id = Ecto.UUID.generate()

      for params <- [
            %{},
            %{"article_ids" => []},
            %{"article_ids" => "x"},
            %{"article_ids" => ["x"]}
          ] do
        body =
          base_conn()
          |> auth(raw)
          |> post(~p"/api/v1/recall/#{recall_id}/referenced", params)
          |> json_response(422)

        assert body["error"]["code"] == "invalid_article_ids"
      end
    end

    test "more than the cap is a 422 too_many_article_ids" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant.id)
      ids = for _ <- 1..51, do: Ecto.UUID.generate()

      body =
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall/#{Ecto.UUID.generate()}/referenced", %{"article_ids" => ids})
        |> json_response(422)

      assert body["error"]["code"] == "too_many_article_ids"
    end

    test "a reference does not enter the heat index" do
      # Heat ranks DELIBERATE reads. A `referenced` row is a client asserting it used an
      # article, so admitting it would let any agent pin its own article at rank 1 by
      # claiming to have used it — the self-inflation #567/#569 rebuilt heat around.
      tenant = fixture(:tenant)
      {raw, key, _agent} = agent_key(tenant.id)
      a = article(tenant.id)
      recall_id = surfaced(tenant.id, key.id, [a], Ecto.UUID.generate())

      # A genuinely-read article, so the index is NON-EMPTY and the comparison below is a
      # real one rather than two empty lists agreeing.
      hot = article(tenant.id, "actually read")

      fixture(:article_access_event, %{
        tenant_id: tenant.id,
        api_key_id: key.id,
        article_id: hot.id,
        access_type: "get"
      })

      {:ok, before} = Knowledge.heat_index(tenant.id, limit: 10)
      assert Enum.map(before.results, & &1.id) == [hot.id]

      base_conn()
      |> auth(raw)
      |> post(~p"/api/v1/recall/#{recall_id}/referenced", %{"article_ids" => [a.id]})
      |> json_response(200)

      assert [_row] = referenced_rows(tenant.id), "the check below is vacuous with no row"

      {:ok, later} = Knowledge.heat_index(tenant.id, limit: 10)

      assert Enum.map(before.results, & &1.id) == Enum.map(later.results, & &1.id)

      refute Enum.any?(later.results, &(&1.id == a.id)),
             "an asserted reference put an article into the heat ranking"

      assert Knowledge.Analytics.get_article_stats(tenant.id, a.id).total_reads == 0,
             "a reference counted as a READ; it is an assertion, not a delivery"
    end

    test "repeating a call records another row but cannot move the metric" do
      # The endpoint is safe to retry: `article_access_events` is an immutable log, so a
      # repeat writes another row, and `RetrievalMetrics` counts DISTINCT (recall, article)
      # pairs precisely so that the published figure cannot be moved by posting twice.
      tenant = fixture(:tenant)
      {raw, key, _agent} = agent_key(tenant.id)
      a = article(tenant.id)
      recall_id = surfaced(tenant.id, key.id, [a], Ecto.UUID.generate())

      for _ <- 1..2 do
        base_conn()
        |> auth(raw)
        |> post(~p"/api/v1/recall/#{recall_id}/referenced", %{"article_ids" => [a.id]})
        |> json_response(200)
      end

      assert length(referenced_rows(tenant.id)) == 2

      today = DateTime.utc_now() |> DateTime.to_date()
      assert Knowledge.RetrievalMetrics.compute(tenant.id, today, 1800).referenced == 1
    end

    test "the reference rate is computed over the same denominator as precision" do
      tenant = fixture(:tenant)
      {raw, key, _agent} = agent_key(tenant.id)
      used = article(tenant.id, "used")
      ignored = article(tenant.id, "ignored")
      recall_id = surfaced(tenant.id, key.id, [used, ignored], Ecto.UUID.generate())

      base_conn()
      |> auth(raw)
      |> post(~p"/api/v1/recall/#{recall_id}/referenced", %{"article_ids" => [used.id]})
      |> json_response(200)

      today = DateTime.utc_now() |> DateTime.to_date()
      m = Knowledge.RetrievalMetrics.compute(tenant.id, today, 1800)

      assert m.searched == 2
      assert m.referenced == 1
      assert m.reference_rate == 0.5
    end
  end
end
