defmodule Loopctl.Memory.PromotionIsolationTest do
  @moduledoc """
  US-29.6 terminal idempotency + cross-scope isolation (TC-29.6.2 / AC-29.6.4).

  Two epic-terminal guarantees proven together end-to-end:

  1. **Idempotency spine.** Re-running promotion for the SAME unchanged session —
     both the explicit `POST /api/v1/memory/promote` trigger AND the scheduled
     `MemoryPromotionSweepWorker` — yields NO net new rows, measured INCLUDING
     superseded rows (`superseded_by` NOT filtered). The count-including-superseded
     is the load-bearing measure: a naive live-only count would be fooled by a
     re-promote that supersedes-then-reinserts. The watermark skip means neither
     re-trigger even calls the LLM.

  2. **Cross-scope isolation on every surface.** A memory promoted under
     `(tenant T, subject A)` is NEVER visible to a DIFFERENT tenant U, NOR to a
     DIFFERENT subject B of the SAME tenant T — through the `Loopctl.Memory` context
     AND the HTTP API (recall, index `?source=promoted`, forget). The MCP surface (the
     "M" of context/API/MCP) is structurally cross-scope-blind — its `memory_promote`
     / `memory_recall` / `memory_list` inputSchemas expose NO `tenant_id`/`subject_id`/
     `project_id` and the handlers never forward a body scope — and is proven in
     `mcp-server/test/memory_tools.test.js` (US-29.4 AC-29.4.5); a cross-scope read is
     not even EXPRESSIBLE there, so it is asserted here by reference.

  Async: all Memory paths route through `Loopctl.AdminRepo` (BYPASSRLS, explicitly
  scoped by `(tenant_id, subject_id)`) / `Loopctl.HeavyRead`, sharing the one sandbox
  connection; Oban `:inline` runs the promotion worker synchronously inside the POST.
  """
  use LoopctlWeb.ConnCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  import Ecto.Query

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Memory
  alias Loopctl.Memory.Memory, as: MemorySchema
  alias Loopctl.Memory.Scope
  alias Loopctl.Workers.MemoryPromotionSweepWorker

  @durable_fact "the account owner signs off on refunds above five hundred dollars"

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp base_conn,
    do: put_req_header(build_conn(), "x-loopctl-last-known-sth", "0:AAAAAAAAAAAAAAAAAAAAAA")

  defp agent_key(tenant_id) do
    agent = fixture(:agent, %{tenant_id: tenant_id})
    {raw, key} = fixture(:api_key, %{tenant_id: tenant_id, role: :agent, agent_id: agent.id})
    {raw, key, agent}
  end

  # ALL promoted rows for a scope — INCLUDING superseded ones (no `superseded_by`
  # filter). This is the idempotency measure: a re-promote that supersedes then
  # re-inserts would pass a naive live-only count but bump THIS one.
  defp count_promoted_including_superseded(tenant_id, subject_id) do
    from(m in MemorySchema,
      where: m.tenant_id == ^tenant_id and m.subject_id == ^subject_id and m.source == :promoted
    )
    |> AdminRepo.aggregate(:count, :id)
  end

  defp stub_durable_candidate do
    json =
      JSON.encode!([
        %{
          "text" => @durable_fact,
          "when_to_apply" => "when relevant",
          "tags" => ["policy"],
          "confidence" => 0.92,
          "cross_links" => []
        }
      ])

    Mox.stub(Loopctl.MockPromoterLLM, :extract, fn _tenant_id, _content, _opts -> {:ok, json} end)
  end

  defp seed_session(tenant_id, subject_id, session_id, contents) do
    for content <- contents do
      fixture(:session_memory,
        tenant_id: tenant_id,
        subject_id: subject_id,
        session_id: session_id,
        role: :user,
        content: content
      )
    end
  end

  defp promote(conn, raw, session_id) do
    conn
    |> auth(raw)
    |> post(~p"/api/v1/memory/promote", %{"session_id" => session_id})
  end

  defp recall_texts(body), do: Enum.map(body["data"], & &1["memory"]["text"])

  test "re-promotion is a net-zero no-op (incl. superseded) and the promoted memory never crosses scope",
       %{conn: conn} do
    tenant_t = fixture(:tenant)
    tenant_u = fixture(:tenant)

    {raw_a, _key_a, agent_a} = agent_key(tenant_t.id)
    {raw_tb, _key_tb, agent_b} = agent_key(tenant_t.id)
    {raw_u, _key_u, agent_u} = agent_key(tenant_u.id)

    subject_a = to_string(agent_a.id)
    Knowledge.reset_circuit_breaker(tenant_t.id)
    Knowledge.reset_circuit_breaker(tenant_u.id)

    stub_durable_candidate()

    seed_session(tenant_t.id, subject_a, "s1", [
      "opened a refund dispute",
      "escalated to the owner"
    ])

    # --- First promotion via the endpoint (inline worker compiles + persists). ---
    assert %{"data" => %{"status" => "enqueued"}} =
             conn |> promote(raw_a, "s1") |> json_response(202)

    after_first = count_promoted_including_superseded(tenant_t.id, subject_a)
    assert after_first == 1

    # === Idempotency: re-promote the SAME unchanged session two ways ===========
    # (a) explicit re-trigger — watermark match → skip, no LLM, no new row.
    assert conn |> promote(raw_a, "s1") |> json_response(202)
    assert count_promoted_including_superseded(tenant_t.id, subject_a) == after_first

    # (b) scheduled sweep — watermark pre-filter skip → no new row.
    assert :ok = MemoryPromotionSweepWorker.perform(%Oban.Job{args: %{}})

    assert count_promoted_including_superseded(tenant_t.id, subject_a) == after_first,
           "re-promotion must add NO net rows counting superseded (watermark skip)"

    # === Cross-scope isolation ================================================
    scope_a = %Scope{tenant_id: tenant_t.id, subject_id: subject_a, project_id: nil}
    scope_b = %Scope{tenant_id: tenant_t.id, subject_id: to_string(agent_b.id), project_id: nil}
    scope_u = %Scope{tenant_id: tenant_u.id, subject_id: to_string(agent_u.id), project_id: nil}

    # Sanity: the OWNER can genuinely recall + list the promoted memory (so the
    # empties below are real ISOLATION, not a blanket no-op).
    assert %{results: [{owned, _} | _]} =
             Memory.recall(scope_a, query: "who approves refunds", limit: 5)

    assert owned.text == @durable_fact
    promoted_id = owned.id
    assert %{meta: %{total_count: 1}} = Memory.list(scope_a, source: :promoted)

    for {raw_other, scope_other, label} <- [
          {raw_tb, scope_b, "cross-subject B (same tenant T)"},
          {raw_u, scope_u, "cross-tenant U"}
        ] do
      # --- Context surface: recall/list empty, forget :not_found. ---
      assert %{results: []} =
               Memory.recall(scope_other, query: "who approves refunds", limit: 5),
             "context recall leaked to #{label}"

      assert %{results: [], meta: %{total_count: 0}} = Memory.list(scope_other, source: :promoted)
      assert {:error, :not_found} = Memory.forget(scope_other, promoted_id)

      # --- API surface: recall never surfaces it, index empty, forget 404s. ---
      recall_body =
        base_conn()
        |> auth(raw_other)
        |> post(~p"/api/v1/memory/recall", %{"query" => "who approves refunds"})
        |> json_response(200)

      refute @durable_fact in recall_texts(recall_body), "API recall leaked to #{label}"

      assert base_conn()
             |> auth(raw_other)
             |> get(~p"/api/v1/memory?source=promoted")
             |> json_response(200)
             |> Map.fetch!("data") == [],
             "API index leaked to #{label}"

      # No existence leak: forging the owner's promoted id 404s cross-scope.
      base_conn()
      |> auth(raw_other)
      |> delete(~p"/api/v1/memory/#{promoted_id}")
      |> json_response(404)
    end

    # Nothing was mutated by any cross-scope attempt: the owner still has exactly one.
    assert count_promoted_including_superseded(tenant_t.id, subject_a) == after_first
    assert %{meta: %{total_count: 1}} = Memory.list(scope_a, source: :promoted)
  end
end
