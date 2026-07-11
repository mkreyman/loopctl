defmodule Loopctl.Knowledge.ProgressiveIndexTest do
  @moduledoc """
  US-31.3: Progressive disclosure — compact index (knowledge_index + article_link
  traversal) -> drill into articles.

  Covers `Knowledge.progressive_index/3` (a bounded, topic-scoped stub query
  composing `search_keyword/3`, `list_curated_sources/2` (US-31.1), a dedicated
  `:relates_to`-scoped hub-enrichment query, and `OKF.derive_description/1`) and
  the `Knowledge.progressive_drill/3` full-body fetch.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge

  # Creates a published tenant article and marks it curated via the governed path
  # (mirrors test/loopctl/knowledge_curated_test.exs / knowledge_hybrid_test.exs).
  defp curated_article(tenant_id, attrs) do
    article =
      fixture(:article, Map.merge(%{tenant_id: tenant_id, status: :published}, attrs))

    {:ok, marked} = Knowledge.mark_curated(tenant_id, article.id, actor_label: "user:admin")
    marked
  end

  defp relates_to(tenant_id, source, target) do
    fixture(:article_link, %{
      tenant_id: tenant_id,
      source_article_id: source.id,
      target_article_id: target.id,
      relationship_type: :relates_to
    })
  end

  # --- TC-31.3.1: index returns capped compact stubs then drill returns the body ---

  describe "progressive_index/3 - capped compact stubs then drill (TC-31.3.1)" do
    test "returns <= top-K stubs (id/title/category/summary, no bodies); drill returns the full body" do
      tenant = fixture(:tenant)
      topic = "ProgressiveHubTopicQZX"

      hub =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          title: "#{topic} Overview",
          body: "An overview article that links to many curated sources."
        })

      # top_k is configured to 3 in config/test.exs; 5 curated targets is > top-K,
      # and min_hub_relates_to is configured to 3, so 5 outgoing :relates_to links
      # makes `hub` an operational hub (AC-31.3.4).
      targets =
        for n <- 1..5 do
          target =
            curated_article(tenant.id, %{
              title: "Curated Target #{n} #{topic}",
              body: "# Curated Target #{n}\nThe curated body content for target #{n}."
            })

          relates_to(tenant.id, hub, target)
          target
        end

      assert Knowledge.progressive_top_k() == 3

      assert {:ok, %{stubs: stubs, meta: meta}} = Knowledge.progressive_index(tenant.id, topic)

      assert length(stubs) <= Knowledge.progressive_top_k()
      assert length(stubs) == 3
      assert meta.top_k == 3
      assert meta.truncated == true
      # Candidate pool (hub + 5 curated targets, deduped) is 6 — bigger than top_k.
      assert meta.candidate_count == 6

      # Stubs are compact: id/title/category/summary only, never a body.
      Enum.each(stubs, fn stub ->
        assert Map.has_key?(stub, :id)
        assert Map.has_key?(stub, :title)
        assert Map.has_key?(stub, :category)
        assert is_binary(stub.summary)
        refute Map.has_key?(stub, :body)
      end)

      # Curated targets are preferred over the (non-curated) hub itself (AC-31.3.4).
      target_ids = MapSet.new(targets, & &1.id)
      assert Enum.all?(stubs, fn stub -> MapSet.member?(target_ids, stub.id) end)

      # Drill into one returned stub: full body, scope-enforced.
      chosen = List.first(stubs)
      assert {:ok, drilled} = Knowledge.progressive_drill(tenant.id, chosen.id)
      assert drilled.id == chosen.id
      assert is_binary(drilled.body)
      assert String.contains?(drilled.body, "curated body content")
    end
  end

  # --- TC-31.3.2: index is tenant-isolated ---

  describe "progressive_index/3 - tenant isolation (TC-31.3.2)" do
    test "no tenant_a stubs appear when fetched as tenant_b" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      topic = "TenantIsolatedTopicABCD"

      hub_a =
        fixture(:article, %{
          tenant_id: tenant_a.id,
          status: :published,
          title: "#{topic} Hub"
        })

      target_a = curated_article(tenant_a.id, %{title: "#{topic} Curated Target"})
      relates_to(tenant_a.id, hub_a, target_a)

      assert {:ok, %{stubs: stubs_b}} = Knowledge.progressive_index(tenant_b.id, topic)
      assert stubs_b == []

      # Sanity: tenant_a genuinely sees its own stubs for the same topic.
      assert {:ok, %{stubs: stubs_a}} = Knowledge.progressive_index(tenant_a.id, topic)
      refute stubs_a == []
    end

    test "drill does not leak another tenant's article" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      article = fixture(:article, %{tenant_id: tenant_a.id, status: :published})

      assert {:error, :not_found} = Knowledge.progressive_drill(tenant_b.id, article.id)
      assert {:ok, _} = Knowledge.progressive_drill(tenant_a.id, article.id)
    end
  end

  # --- AC-31.3.4: prefers governed curated sources ---

  describe "progressive_index/3 - curated preference (AC-31.3.4)" do
    test "curated matches are ordered ahead of non-curated matches for the same topic" do
      tenant = fixture(:tenant)
      topic = "CuratedPreferenceTopicWXYZ"

      non_curated =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          title: "#{topic} Non-Curated"
        })

      curated = curated_article(tenant.id, %{title: "#{topic} Curated"})

      assert {:ok, %{stubs: stubs}} =
               Knowledge.progressive_index(tenant.id, topic, hub_enrich: false)

      ids = Enum.map(stubs, & &1.id)
      assert curated.id in ids
      assert non_curated.id in ids

      assert Enum.find_index(ids, &(&1 == curated.id)) <
               Enum.find_index(ids, &(&1 == non_curated.id))
    end

    test "system-scope curated sources may participate (US-31.1 AC-31.1.3)" do
      tenant = fixture(:tenant)
      topic = "SystemScopeTopicQRST"

      {:ok, system_article} =
        Knowledge.create_article(
          tenant.id,
          %{
            scope: :system,
            status: :published,
            category: :reference,
            title: "#{topic} System Canonical",
            body: "system body"
          }
        )

      {:ok, marked} =
        Knowledge.mark_curated(nil, system_article.id, actor_label: "superadmin", scope: :system)

      # System-scope articles have a nil tenant_id, so they aren't reachable via the
      # tenant-scoped search_keyword seed step directly — but they DO participate via
      # the curated-preference set when a tenant-owned seed hub links to them.
      hub =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          title: "#{topic} Hub"
        })

      relates_to(tenant.id, hub, marked)

      # min_hub_relates_to is configured to 3 in test.exs — pad two more outgoing
      # :relates_to links so `hub` clears the operational-hub threshold and
      # enrichment actually runs.
      for n <- 1..2 do
        padding = curated_article(tenant.id, %{title: "Padding Target #{n} #{topic}"})
        relates_to(tenant.id, hub, padding)
      end

      assert {:ok, %{stubs: stubs}} = Knowledge.progressive_index(tenant.id, topic)
      ids = Enum.map(stubs, & &1.id)
      assert marked.id in ids

      # AC-31.3.3 vs AC-31.3.4 consistency (review finding): a system-scope stub
      # the index surfaces must actually be openable by drill — a `tenant_id: nil`
      # system canonical must not fall through to a false {:error, :not_found}.
      assert {:ok, drilled} = Knowledge.progressive_drill(tenant.id, marked.id)
      assert drilled.id == marked.id
      assert drilled.body == "system body"
    end

    test "drill rejects a draft or archived system canonical by id (review finding, medium)" do
      tenant = fixture(:tenant)

      {:ok, draft_system} =
        Knowledge.create_article(
          tenant.id,
          %{
            scope: :system,
            status: :draft,
            category: :reference,
            title: "Draft System Canonical",
            body: "draft system body"
          }
        )

      {:ok, archived_system} =
        Knowledge.create_article(
          tenant.id,
          %{
            scope: :system,
            status: :archived,
            category: :reference,
            title: "Archived System Canonical",
            body: "archived system body"
          }
        )

      # Neither is reachable via the tenant-scoped get_article/3 path (nil
      # tenant_id), so the ONLY way to probe this is the system-canonical
      # fallback drill_system_canonical/3 exercises directly.
      assert {:error, :not_found} = Knowledge.progressive_drill(tenant.id, draft_system.id)
      assert {:error, :not_found} = Knowledge.progressive_drill(tenant.id, archived_system.id)
    end
  end

  # --- AC-31.3.2: the cap is configurable and documented ---

  describe "progressive_top_k/0 and min_hub_relates_to/0 (AC-31.3.2 / AC-31.3.4)" do
    test "read from application config, overridable in config/test.exs" do
      assert Knowledge.progressive_top_k() == 3
      assert Knowledge.min_hub_relates_to() == 3
    end

    test "an oversized :limit override is clamped to max_relevance_page_size/0 (review finding, low)" do
      tenant = fixture(:tenant)
      topic = "ClampedLimitTopicEFGHI"

      fixture(:article, %{tenant_id: tenant.id, status: :published, title: topic})

      assert {:ok, %{meta: meta}} =
               Knowledge.progressive_index(tenant.id, topic,
                 limit: 1_000_000,
                 hub_enrich: false
               )

      assert meta.top_k == Knowledge.max_relevance_page_size()
    end

    test "a :limit opt overrides the default top-K cap" do
      tenant = fixture(:tenant)
      topic = "CustomLimitTopicHJKL"

      for n <- 1..4 do
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          title: "#{topic} Match #{n}"
        })
      end

      assert {:ok, %{stubs: stubs, meta: meta}} =
               Knowledge.progressive_index(tenant.id, topic, limit: 2, hub_enrich: false)

      assert length(stubs) == 2
      assert meta.top_k == 2
      assert meta.truncated == true
    end

    test "per-hub :relates_to fan-out is capped at max_graph_neighbors_per_node/0, not the hub's full degree" do
      tenant = fixture(:tenant)
      topic = "FanoutCapTopicUVWXY"

      hub =
        fixture(:article, %{tenant_id: tenant.id, status: :published, title: "#{topic} Hub"})

      fanout_cap = Knowledge.max_graph_neighbors_per_node()
      # Degree well past the cap (and past min_hub_relates_to == 3) so the LIMIT
      # is actually exercised -- if it were removed, all of these would surface.
      extra = 5
      total_targets = fanout_cap + extra

      # Titles deliberately DO NOT contain `topic` -- only `hub` is a direct
      # search_keyword seed; every target is reachable ONLY via hub traversal,
      # isolating the fan-out cap from the unrelated top-K stub cap.
      targets =
        for n <- 1..total_targets do
          target = curated_article(tenant.id, %{title: "Fanout Target #{n}"})
          relates_to(tenant.id, hub, target)
          target
        end

      # Override :limit well above total_targets so the top-K cap cannot mask
      # the fan-out cap's effect.
      assert {:ok, %{stubs: stubs, meta: meta}} =
               Knowledge.progressive_index(tenant.id, topic, limit: total_targets + 5)

      # Candidate pool = 1 seed (hub) + fanout_cap neighbors -- never the full
      # degree of `total_targets` links.
      assert meta.candidate_count == 1 + fanout_cap
      assert length(stubs) == 1 + fanout_cap
      assert meta.truncated == false

      surfaced_target_ids = stubs |> Enum.map(& &1.id) |> MapSet.new() |> MapSet.delete(hub.id)
      all_target_ids = MapSet.new(targets, & &1.id)

      assert MapSet.size(surfaced_target_ids) == fanout_cap
      assert MapSet.subset?(surfaced_target_ids, all_target_ids)
    end
  end

  # --- hub_enrich: false disables :relates_to enrichment ---

  describe "progressive_index/3 - hub_enrich opt-out" do
    test "hub_enrich: false returns only direct topic matches, no traversal" do
      tenant = fixture(:tenant)
      topic = "NoEnrichTopicMNOP"

      hub =
        fixture(:article, %{tenant_id: tenant.id, status: :published, title: "#{topic} Hub"})

      for n <- 1..4 do
        target = curated_article(tenant.id, %{title: "Unrelated Curated #{n}"})
        relates_to(tenant.id, hub, target)
      end

      assert {:ok, %{stubs: stubs}} =
               Knowledge.progressive_index(tenant.id, topic, hub_enrich: false)

      assert Enum.map(stubs, & &1.id) == [hub.id]
    end
  end

  # --- #163 agent-visibility enforcement (review finding, high) ---

  describe "progressive_index/3 - agent visibility scope (#163)" do
    test "another agent's private/owner memory never surfaces as an index stub" do
      tenant = fixture(:tenant)
      owner_agent = fixture(:agent, %{tenant_id: tenant.id})
      other_agent = fixture(:agent, %{tenant_id: tenant.id})
      topic = "PrivateMemoryTopicLMNOP"

      private =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          title: "#{topic} Private Memory",
          body: "PRIVATE BODY — must not leak",
          metadata: %{"visibility" => "private", "agent_id" => to_string(owner_agent.id)}
        })

      shared =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          title: "#{topic} Shared"
        })

      # A caller with no visibility_agent_id (higher role) sees everything.
      assert {:ok, %{stubs: unscoped_stubs}} = Knowledge.progressive_index(tenant.id, topic)
      unscoped_ids = Enum.map(unscoped_stubs, & &1.id)
      assert private.id in unscoped_ids
      assert shared.id in unscoped_ids

      # The NON-owning agent must never see the private memory's stub -- no
      # title, no body-derived summary.
      assert {:ok, %{stubs: other_stubs}} =
               Knowledge.progressive_index(tenant.id, topic,
                 visibility_agent_id: to_string(other_agent.id)
               )

      other_ids = Enum.map(other_stubs, & &1.id)
      refute private.id in other_ids
      assert shared.id in other_ids
      refute Enum.any?(other_stubs, fn stub -> stub.title == "#{topic} Private Memory" end)

      # The OWNER, by contrast, does see its own private memory's stub.
      assert {:ok, %{stubs: owner_stubs}} =
               Knowledge.progressive_index(tenant.id, topic,
                 visibility_agent_id: to_string(owner_agent.id)
               )

      assert private.id in Enum.map(owner_stubs, & &1.id)
    end

    test "a private memory reachable only via hub :relates_to traversal is filtered for a non-owning agent" do
      tenant = fixture(:tenant)
      owner_agent = fixture(:agent, %{tenant_id: tenant.id})
      other_agent = fixture(:agent, %{tenant_id: tenant.id})
      topic = "HubPrivateNeighborTopicRSTU"

      hub =
        fixture(:article, %{
          tenant_id: tenant.id,
          status: :published,
          title: "#{topic} Hub"
        })

      private_neighbor =
        curated_article(tenant.id, %{
          title: "Private Neighbor #{topic}",
          metadata: %{"visibility" => "private", "agent_id" => to_string(owner_agent.id)}
        })

      relates_to(tenant.id, hub, private_neighbor)

      # min_hub_relates_to is configured to 3 in test.exs -- pad two more
      # outgoing :relates_to links so `hub` clears the operational-hub
      # threshold and enrichment actually runs.
      for n <- 1..2 do
        padding = curated_article(tenant.id, %{title: "Padding Target #{n} #{topic}"})
        relates_to(tenant.id, hub, padding)
      end

      assert {:ok, %{stubs: other_stubs}} =
               Knowledge.progressive_index(tenant.id, topic,
                 limit: 10,
                 visibility_agent_id: to_string(other_agent.id)
               )

      refute private_neighbor.id in Enum.map(other_stubs, & &1.id)

      assert {:ok, %{stubs: owner_stubs}} =
               Knowledge.progressive_index(tenant.id, topic,
                 limit: 10,
                 visibility_agent_id: to_string(owner_agent.id)
               )

      assert private_neighbor.id in Enum.map(owner_stubs, & &1.id)
    end
  end

  # --- Error propagation mirrors search_keyword/3 ---

  describe "progressive_index/3 - error propagation" do
    test "returns {:error, :empty_query} for an empty topic" do
      tenant = fixture(:tenant)
      assert {:error, :empty_query} = Knowledge.progressive_index(tenant.id, "")
    end

    test "returns {:error, :bad_request, _} for an over-long topic" do
      tenant = fixture(:tenant)
      too_long = String.duplicate("a", 501)
      assert {:error, :bad_request, _} = Knowledge.progressive_index(tenant.id, too_long)
    end
  end
end
