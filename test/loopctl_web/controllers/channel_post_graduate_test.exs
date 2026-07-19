defmodule LoopctlWeb.ChannelPostGraduateTest do
  @moduledoc """
  US-40.E1 — `POST /api/v1/channel/posts/:id/graduate`.

  Graduating a coordination post into the durable Knowledge wiki: a CONTENT-
  SELECTIVE, one-call, agent-triggered promotion of a genuinely reusable finding.
  It reuses Knowledge's EXISTING guardrails — the semantic novelty gate + an
  explicit secret scan — and is tenant/project-membership scoped.

  Everything (auth resolution AND the graduate write) runs through
  `Loopctl.AdminRepo`, one sandbox connection, so this stays `async: true`.
  """
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  import Ecto.Query
  import Mox

  alias Loopctl.AdminRepo
  alias Loopctl.Coordination
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Knowledge

  @sth_header "0:AAAAAAAAAAAAAAAAAAAAAA"

  # A role:agent key whose api_key.agent_id points at a real agent in the tenant.
  defp agent_key(tenant, attrs \\ %{}) do
    agent = fixture(:agent, %{tenant_id: tenant.id})

    {raw, key} =
      fixture(
        :api_key,
        Map.merge(%{tenant_id: tenant.id, role: :agent, agent_id: agent.id}, attrs)
      )

    {raw, key, agent}
  end

  # A role:agent key whose agent is a WRITABLE MEMBER of `project` (US-40.D3):
  # graduate is project-scoped by membership (shared with the claim/write gate).
  # Assigning the agent a story in `project` admits its graduate through the gate.
  defp member_agent_key(tenant, project, attrs \\ %{}) do
    {raw, key, agent} = agent_key(tenant, attrs)

    fixture(:story, %{
      tenant_id: tenant.id,
      project_id: project.id,
      assigned_agent_id: agent.id,
      agent_status: :assigned
    })

    {raw, key, agent}
  end

  defp authed_conn(raw) do
    build_conn()
    |> put_req_header("x-loopctl-last-known-sth", @sth_header)
    |> put_req_header("authorization", "Bearer #{raw}")
  end

  defp graduate_path(id), do: "/api/v1/channel/posts/#{id}/graduate"

  defp create_post(tenant, project, agent, body) do
    {:ok, post} = Coordination.create_post(tenant.id, project.id, agent.id, %{"body" => body})
    post
  end

  # Force the assessor verdict for one test (the DataCase default stubs :novel).
  defp gate_verdict(verdict, neighbors) do
    stub(Loopctl.MockProposalAssessor, :assess, fn _t, _a, _o ->
      %{verdict: verdict, score: 0.98, neighbors: neighbors}
    end)
  end

  describe "POST /api/v1/channel/posts/:id/graduate" do
    # TC-40.E1.1 — a member agent graduates a post → a Knowledge article is created
    # from the post body with project_id carried over, and provenance references the
    # originating post (source_type + source_id) and passes source_type validation.
    test "graduates a post into a Knowledge article with channel provenance" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = member_agent_key(tenant, project)

      post = create_post(tenant, project, agent, "A reusable lesson worth keeping.")

      conn =
        authed_conn(raw)
        |> post(graduate_path(post.id), %{"title" => "Reusable Lesson", "tags" => ["ops"]})

      assert %{"data" => data} = json_response(conn, 201)
      assert data["title"] == "Reusable Lesson"
      assert data["source_type"] == "channel_graduation"
      assert data["source_id"] == post.id
      assert data["project_id"] == project.id

      # The durable article really landed, carrying the post body + provenance.
      assert {:ok, article} = Knowledge.get_article(tenant.id, data["id"])
      assert article.body == "A reusable lesson worth keeping."
      assert article.project_id == project.id
      assert article.source_type == "channel_graduation"
      assert article.source_id == post.id
      assert article.tags == ["ops"]

      # Promotion into the DISCOVERABLE durable plane: a graduated finding must be
      # PUBLISHED, not a draft — knowledge_search/knowledge_context return published
      # articles only and the novelty gate assesses only the published corpus, so a
      # draft graduation would be invisible AND would never dedup a sibling graduation.
      assert article.status == :published

      # And it is actually retrievable via the published-only keyword search surface,
      # proving the promotion reached the discoverable plane (not just the row).
      assert {:ok, %{results: results}} = Knowledge.search_keyword(tenant.id, "reusable")
      assert data["id"] in Enum.map(results, & &1.id)

      # The source post is KEPT (30-day TTL sweep reclaims it) — not force-graduated.
      assert {:ok, %ChannelPost{}} = Coordination.get_post(tenant.id, post.id)
    end

    # TC-40.E1.2 — the semantic novelty gate catches a near-duplicate: nothing is
    # created, the caller is pointed at the canonical existing article.
    test "a near-duplicate returns 200 deduplicated and creates nothing" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = member_agent_key(tenant, project)

      existing =
        fixture(:article, %{tenant_id: tenant.id, title: "Canonical", status: :published})

      gate_verdict(:duplicate, [
        %{id: existing.id, title: existing.title, similarity_score: 0.98}
      ])

      post = create_post(tenant, project, agent, "Same idea, reworded.")

      count_before = AdminRepo.aggregate(from(a in "articles"), :count)

      conn =
        authed_conn(raw)
        |> post(graduate_path(post.id), %{"title" => "Reworded canonical"})

      body = json_response(conn, 200)
      assert body["deduplicated"] == true
      assert body["data"]["id"] == existing.id

      # No wiki pollution: no new article row was inserted.
      assert AdminRepo.aggregate(from(a in "articles"), :count) == count_before
    end

    # TC-40.E1.3 — a post whose body carries a denylisted secret → 422, nothing
    # lands in Knowledge (the explicit secret scan runs BEFORE propose_article).
    test "a post body carrying a secret is rejected with 422 and nothing is graduated" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = member_agent_key(tenant, project)

      # Seed a benign post, then plant a secret directly (bypassing the write-path
      # denylist) to simulate a credential that slipped through / was regretted.
      post = create_post(tenant, project, agent, "placeholder")
      secret_body = "here is the leaked key sk-abcdefghijklmnopqrstuvwxyz0123"

      {1, _} =
        AdminRepo.update_all(
          from(p in ChannelPost, where: p.id == ^post.id),
          set: [body: secret_body]
        )

      count_before = AdminRepo.aggregate(from(a in "articles"), :count)

      conn =
        authed_conn(raw)
        |> post(graduate_path(post.id), %{"title" => "Should not land"})

      assert %{"error" => _} = json_response(conn, 422)
      assert AdminRepo.aggregate(from(a in "articles"), :count) == count_before
    end

    # A token-shaped TAG carries a denylisted secret → 422, nothing graduated. Tags are
    # caller-supplied and brand-new at graduation (channel_posts have no tags, so a tag
    # never passed the creation-path denylist) and land in the same durable, tenant-wide-
    # readable plane the scan protects. Regression for the tag smuggling vector.
    test "a token-shaped tag carrying a secret is rejected with 422 and nothing is graduated" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = member_agent_key(tenant, project)

      post = create_post(tenant, project, agent, "a perfectly benign finding")
      count_before = AdminRepo.aggregate(from(a in "articles"), :count)

      # A real GitHub PAT shape: fits Article's ^[A-Za-z0-9_-]+$ tag pattern AND fires
      # the SecretDenylist. Title + body are clean — only the tag smuggles the secret.
      conn =
        authed_conn(raw)
        |> post(graduate_path(post.id), %{
          "title" => "Clean title",
          "tags" => ["ops", "ghp_16C7e42F292c6912E7710c838347Ae178B4a"]
        })

      assert %{"error" => _} = json_response(conn, 422)
      assert AdminRepo.aggregate(from(a in "articles"), :count) == count_before
    end

    # #163 — an AGENT-role graduation must scope the novelty-gate dedup to the caller's
    # own visibility, or the near-neighbor pool (and a :duplicate re-fetch) can echo
    # ANOTHER agent's private/owner memory id/title/status. Assert the caller's
    # visibility_agent_id is threaded into the assessor opts.
    test "an agent graduation threads the caller's visibility_agent_id into the novelty gate" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = member_agent_key(tenant, project)

      test_pid = self()

      stub(Loopctl.MockProposalAssessor, :assess, fn _t, _a, opts ->
        send(test_pid, {:assess_opts, opts})
        %{verdict: :novel, score: 0.0, neighbors: []}
      end)

      post = create_post(tenant, project, agent, "A scoped reusable lesson.")

      conn =
        authed_conn(raw)
        |> post(graduate_path(post.id), %{"title" => "Scoped Lesson"})

      assert json_response(conn, 201)
      assert_received {:assess_opts, opts}
      assert Keyword.get(opts, :visibility_agent_id) == to_string(agent.id)
    end

    # Finding 3 — the embedding backend is down: the gate falls open (:unknown) and
    # `on_gate_unavailable: :skip` must short-circuit WITHOUT creating an un-deduplicated
    # article. 503 + nothing graduated (mirrors the reviewed Memory graduation posture).
    test "a fell-open novelty gate returns 503 and graduates nothing" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw, _key, agent} = member_agent_key(tenant, project)

      gate_verdict(:unknown, [])

      post = create_post(tenant, project, agent, "A lesson the gate cannot assess.")
      count_before = AdminRepo.aggregate(from(a in "articles"), :count)

      conn =
        authed_conn(raw)
        |> post(graduate_path(post.id), %{"title" => "Outage lesson"})

      assert %{"error" => %{"code" => "gate_unavailable"}} = json_response(conn, 503)
      assert AdminRepo.aggregate(from(a in "articles"), :count) == count_before
    end

    # TC-40.E1.4 (tenant isolation) — a post in ANOTHER tenant → 404, no article
    # created. get_post/2 is tenant-scoped, so there is no cross-tenant oracle.
    test "graduating another tenant's post returns 404 and creates no article" do
      tenant = fixture(:tenant)
      {raw, _key, _agent} = agent_key(tenant)

      other = fixture(:tenant)
      other_project = fixture(:project, %{tenant_id: other.id})
      other_agent = fixture(:agent, %{tenant_id: other.id})
      foreign = create_post(other, other_project, other_agent, "theirs")

      count_before = AdminRepo.aggregate(from(a in "articles"), :count)

      conn =
        authed_conn(raw)
        |> post(graduate_path(foreign.id), %{"title" => "Steal it"})

      assert json_response(conn, 404) == %{
               "error" => %{"status" => 404, "message" => "Not found"}
             }

      assert AdminRepo.aggregate(from(a in "articles"), :count) == count_before
    end

    # A non-member agent (no story assignment in the project) is denied identically
    # to a not-found — the shared membership gate (US-40.D3), no oracle.
    test "a non-member agent gets a byte-identical 404" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      # agent_key (NOT member_agent_key): no story assignment → not a member.
      {raw, _key, agent} = agent_key(tenant)
      author = fixture(:agent, %{tenant_id: tenant.id})
      post = create_post(tenant, project, author, "a finding")

      # Sanity: the caller is not the author and has no assignment.
      refute agent.id == author.id

      conn =
        authed_conn(raw)
        |> post(graduate_path(post.id), %{"title" => "Reusable"})

      assert json_response(conn, 404) == %{
               "error" => %{"status" => 404, "message" => "Not found"}
             }
    end

    # A key with no agent identity cannot graduate (parity with create/2).
    test "a key with no agent identity gets 403 agent_identity_required" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent = fixture(:agent, %{tenant_id: tenant.id})
      post = create_post(tenant, project, agent, "a finding")

      {raw, _key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: nil})

      conn =
        authed_conn(raw)
        |> post(graduate_path(post.id), %{"title" => "Reusable"})

      assert %{"error" => %{"code" => "agent_identity_required"}} = json_response(conn, 403)
    end
  end
end
