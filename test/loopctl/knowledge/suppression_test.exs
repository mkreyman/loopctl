defmodule Loopctl.Knowledge.SuppressionTest do
  @moduledoc """
  The reversible retrieval tombstone.

  Two properties carry the whole feature, and each is tested against the real surfaces
  rather than against the predicate:

    * a suppressed article is returned by NOTHING that ranks or lists, and
    * it is still returned by the ONE path that resolves it by id — because a suppression
      you cannot read is a suppression you cannot undo, which is the exact way `:archived`
      fails (#605/#606).

  The exclusion tests deliberately assert on `Knowledge` functions rather than on
  `Suppression.exclude/1`: the predicate being correct proves nothing about whether a given
  read path calls it, and that gap is what the drift guard in `suppression_guard_test.exs`
  and these tests together close.
  """
  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.OKF
  alias Loopctl.Knowledge.StreamingExport.OKFFormat
  alias Loopctl.StreamingExportHelper

  setup :verify_on_exit!

  defp published(tenant_id, attrs \\ %{}) do
    base = %{
      title: "Suppressible #{System.unique_integer([:positive])}",
      body: "A body about widget calibration and widget tolerances.",
      category: :pattern,
      status: :draft,
      tags: []
    }

    fixture(:article, base |> Map.merge(attrs) |> Map.put(:tenant_id, tenant_id))
    |> Ecto.Changeset.change(%{status: :published})
    |> AdminRepo.update!()
  end

  defp suppress!(tenant_id, article, opts \\ []) do
    {:ok, updated} =
      Knowledge.suppress_article(
        tenant_id,
        article.id,
        Keyword.merge([reason: "superseded by the calibration playbook"], opts)
      )

    updated
  end

  defp audit_rows(tenant_id, action) do
    from(a in AuditLog,
      where: a.tenant_id == ^tenant_id and a.entity_type == "article" and a.action == ^action
    )
    |> AdminRepo.all()
  end

  defp ids(list), do: list |> Enum.map(& &1.id) |> MapSet.new()

  describe "suppress_article/3 — the write" do
    setup do
      tenant = fixture(:tenant)
      %{tenant: tenant, article: published(tenant.id)}
    end

    test "records the tombstone without touching status, body or links", %{
      tenant: tenant,
      article: article
    } do
      suppressed = suppress!(tenant.id, article, reason: "noisy duplicate of the hub")

      assert %DateTime{} = suppressed.suppressed_at
      assert suppressed.suppression_reason == "noisy duplicate of the hub"
      assert is_binary(suppressed.suppressed_by)

      # The whole point of the primitive: nothing else moved, so nothing has to be rebuilt.
      assert suppressed.status == :published
      assert suppressed.body == article.body
      assert suppressed.title == article.title
    end

    test "writes an article.suppressed audit event carrying the reason", %{
      tenant: tenant,
      article: article
    } do
      suppress!(tenant.id, article, reason: "wrong retention number")

      assert [row] = audit_rows(tenant.id, "article.suppressed")
      assert row.entity_id == article.id
      assert row.new_state["suppression_reason"] == "wrong retention number"
      assert row.old_state["suppressed_at"] == nil
    end

    test "requires a reason, and a blank one is not a reason", %{
      tenant: tenant,
      article: article
    } do
      assert {:error, :unprocessable_entity, message} =
               Knowledge.suppress_article(tenant.id, article.id, [])

      assert message =~ "required"

      assert {:error, :unprocessable_entity, _} =
               Knowledge.suppress_article(tenant.id, article.id, reason: "   ")

      # Nothing was written on either refusal.
      assert AdminRepo.get!(Article, article.id).suppressed_at == nil
      assert audit_rows(tenant.id, "article.suppressed") == []
    end

    test "refuses a reason past the column bound", %{tenant: tenant, article: article} do
      over = String.duplicate("x", Article.max_suppression_reason_length() + 1)

      assert {:error, :unprocessable_entity, message} =
               Knowledge.suppress_article(tenant.id, article.id, reason: over)

      assert message =~ "at most"
    end

    test "re-suppressing keeps the FIRST actor and reason and writes no second event", %{
      tenant: tenant,
      article: article
    } do
      first = suppress!(tenant.id, article, reason: "first call", actor_label: "agent:alice")

      {:ok, second} =
        Knowledge.suppress_article(tenant.id, article.id,
          reason: "second call",
          actor_label: "agent:bob"
        )

      # The tombstone records who FIRST took the article out of retrieval. Letting a later
      # caller rewrite it would erase the only record of the original act.
      assert second.suppression_reason == "first call"
      assert second.suppressed_by == "agent:alice"
      assert second.suppressed_at == first.suppressed_at
      assert length(audit_rows(tenant.id, "article.suppressed")) == 1
    end

    test "a missing article is not_found", %{tenant: tenant} do
      assert {:error, :not_found} =
               Knowledge.suppress_article(tenant.id, Ecto.UUID.generate(), reason: "x")
    end
  end

  describe "unsuppress_article/2 — the undo" do
    setup do
      tenant = fixture(:tenant)
      article = published(tenant.id)
      %{tenant: tenant, article: suppress!(tenant.id, article)}
    end

    test "clears all three fields together", %{tenant: tenant, article: article} do
      {:ok, restored} = Knowledge.unsuppress_article(tenant.id, article.id)

      assert restored.suppressed_at == nil
      assert restored.suppressed_by == nil
      assert restored.suppression_reason == nil
    end

    test "writes an article.unsuppressed audit event carrying the lifted reason", %{
      tenant: tenant,
      article: article
    } do
      {:ok, _} = Knowledge.unsuppress_article(tenant.id, article.id)

      assert [row] = audit_rows(tenant.id, "article.unsuppressed")
      assert row.old_state["suppression_reason"] == article.suppression_reason
      assert row.new_state["suppressed_at"] == nil
    end

    test "is a no-op with no audit event on an article that is not suppressed", %{
      tenant: tenant
    } do
      live = published(tenant.id)

      assert {:ok, unchanged} = Knowledge.unsuppress_article(tenant.id, live.id)
      assert unchanged.id == live.id
      assert audit_rows(tenant.id, "article.unsuppressed") == []
    end
  end

  describe "tenant isolation" do
    test "tenant B cannot suppress, unsuppress, or observe tenant A's article" do
      a = fixture(:tenant)
      b = fixture(:tenant)
      article = published(a.id)

      assert {:error, :not_found} =
               Knowledge.suppress_article(b.id, article.id, reason: "not mine")

      assert AdminRepo.get!(Article, article.id).suppressed_at == nil

      suppress!(a.id, article)

      assert {:error, :not_found} = Knowledge.unsuppress_article(b.id, article.id)
      assert AdminRepo.get!(Article, article.id).suppressed_at != nil

      # And A's suppression never touches B's corpus.
      b_article = published(b.id)
      {:ok, %{results: results}} = Knowledge.search_keyword(b.id, "widget")
      assert MapSet.member?(ids(results), b_article.id)
    end
  end

  describe "agent visibility scope (#163/#331)" do
    setup do
      tenant = fixture(:tenant)

      private =
        published(tenant.id, %{
          metadata: %{"visibility" => "private", "agent_id" => "agent-owner"}
        })

      %{tenant: tenant, private: private}
    end

    test "an agent cannot suppress another agent's private memory", %{
      tenant: tenant,
      private: private
    } do
      assert {:error, :not_found} =
               Knowledge.suppress_article(tenant.id, private.id,
                 reason: "not visible to me",
                 visibility_agent_id: "agent-stranger"
               )

      assert AdminRepo.get!(Article, private.id).suppressed_at == nil
    end

    test "the owning agent can suppress and unsuppress its own memory", %{
      tenant: tenant,
      private: private
    } do
      assert {:ok, suppressed} =
               Knowledge.suppress_article(tenant.id, private.id,
                 reason: "stale observation",
                 visibility_agent_id: "agent-owner"
               )

      assert suppressed.suppressed_at != nil

      assert {:ok, restored} =
               Knowledge.unsuppress_article(tenant.id, private.id,
                 visibility_agent_id: "agent-owner"
               )

      assert restored.suppressed_at == nil
    end

    test "an agent cannot lift another agent's suppression", %{
      tenant: tenant,
      private: private
    } do
      suppress!(tenant.id, private, visibility_agent_id: "agent-owner")

      assert {:error, :not_found} =
               Knowledge.unsuppress_article(tenant.id, private.id,
                 visibility_agent_id: "agent-stranger"
               )

      assert AdminRepo.get!(Article, private.id).suppressed_at != nil
    end
  end

  describe "the by-id read path STILL returns it — the property archive lacks" do
    setup do
      tenant = fixture(:tenant)
      article = published(tenant.id)
      %{tenant: tenant, article: suppress!(tenant.id, article, reason: "under review")}
    end

    test "get_article/3 resolves it and renders the tombstone", %{
      tenant: tenant,
      article: article
    } do
      assert {:ok, found} = Knowledge.get_article(tenant.id, article.id)

      assert found.id == article.id
      assert found.status == :published
      assert found.suppression_reason == "under review"
      assert %DateTime{} = found.suppressed_at
    end
  end

  describe "every ranked read path excludes it" do
    setup do
      tenant = fixture(:tenant)
      kept = published(tenant.id, %{title: "Widget calibration kept"})
      gone = published(tenant.id, %{title: "Widget calibration gone"})

      %{tenant: tenant, kept: kept, gone: suppress!(tenant.id, gone)}
    end

    test "keyword search", %{tenant: tenant, kept: kept, gone: gone} do
      {:ok, %{results: results}} = Knowledge.search_keyword(tenant.id, "widget")

      assert MapSet.member?(ids(results), kept.id)
      refute MapSet.member?(ids(results), gone.id)
    end

    test "the knowledge index catalog", %{tenant: tenant, kept: kept, gone: gone} do
      {:ok, %{articles: grouped}} = Knowledge.list_index(tenant.id)
      listed = grouped |> Map.values() |> List.flatten() |> ids()

      assert MapSet.member?(listed, kept.id)
      refute MapSet.member?(listed, gone.id)
    end

    test "the index's cursor half agrees with its offset half", %{
      tenant: tenant,
      kept: kept,
      gone: gone
    } do
      {:ok, %{results: results}} = Knowledge.list_index_keyset(tenant.id, limit: 50)

      assert MapSet.member?(ids(results), kept.id)
      refute MapSet.member?(ids(results), gone.id)
    end

    test "the heat index, which takes no query at all", %{
      tenant: tenant,
      kept: kept,
      gone: gone
    } do
      # Heat ranks by DISTINCT READERS, so both articles need reads to be candidates —
      # otherwise the exclusion would pass vacuously on an empty index.
      for article <- [kept, gone] do
        for _ <- 1..2,
            do: fixture(:article_access_event, %{tenant_id: tenant.id, article_id: article.id})
      end

      {:ok, %{results: stubs}} = Knowledge.heat_index(tenant.id, limit: 50)

      assert MapSet.member?(ids(stubs), kept.id)
      refute MapSet.member?(ids(stubs), gone.id)
    end

    test "the progressive index", %{tenant: tenant, kept: kept, gone: gone} do
      {:ok, %{stubs: stubs}} = Knowledge.progressive_index(tenant.id, "widget calibration")

      assert MapSet.member?(ids(stubs), kept.id)
      refute MapSet.member?(ids(stubs), gone.id)
    end

    test "curated sources, so a suppressed article never wins the hybrid lane", %{
      tenant: tenant,
      kept: kept,
      gone: gone
    } do
      for article <- [kept, gone] do
        {:ok, _} = Knowledge.mark_curated(tenant.id, article.id, actor_label: "test")
      end

      curated = ids(Knowledge.list_curated_sources(tenant.id))

      assert MapSet.member?(curated, kept.id)
      refute MapSet.member?(curated, gone.id)
    end

    test "graph traversal — as a root and as a neighbour", %{
      tenant: tenant,
      kept: kept,
      gone: gone
    } do
      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: kept.id,
        target_article_id: gone.id,
        relationship_type: :relates_to
      })

      # A suppressed root is not an entry point: traversing from it is a read path into it
      # by another name.
      assert {:error, :not_found} = Knowledge.graph_traversal(tenant.id, gone.id)

      # And it is not reachable as a neighbour either.
      {:ok, %{nodes: nodes}} = Knowledge.graph_traversal(tenant.id, kept.id, depth: 2)
      refute MapSet.member?(ids(nodes), gone.id)
    end

    test "the traversal itself skips it, not just the hydration", ctx do
      %{tenant: tenant, kept: kept, gone: gone} = ctx
      # The traversal is raw SQL, invisible to the drift guard's scan. Filtering only at
      # hydration would still let a suppressed node reach a neighbour BEYOND it.
      beyond = published(tenant.id, %{title: "Widget calibration beyond"})

      for {src, tgt} <- [{kept.id, gone.id}, {gone.id, beyond.id}] do
        fixture(:article_link, %{
          tenant_id: tenant.id,
          source_article_id: src,
          target_article_id: tgt,
          relationship_type: :relates_to
        })
      end

      {:ok, %{nodes: nodes}} = Knowledge.graph_traversal(tenant.id, kept.id, depth: 3)

      refute MapSet.member?(ids(nodes), gone.id)

      refute MapSet.member?(ids(nodes), beyond.id),
             "the traversal bridged THROUGH a suppressed node — the predicate is missing " <>
               "from the recursive CTE, not just from the hydration."
    end

    test "the article enumeration endpoint, which parametrizes its status", ctx do
      %{tenant: tenant, kept: kept, gone: gone} = ctx
      # GET /api/v1/articles enumerates the same corpus as GET /knowledge/index; two
      # enumerations of one corpus must not disagree about what is in it.
      %{data: listed} = Knowledge.list_articles(tenant.id, limit: 100)

      assert MapSet.member?(ids(listed), kept.id)
      refute MapSet.member?(ids(listed), gone.id)

      assert Knowledge.count_articles(tenant.id) ==
               Knowledge.count_articles(tenant.id, suppressed: :include) - 1
    end

    test "a suppressed neighbour is not named in a context result's linked_articles", ctx do
      %{tenant: tenant, kept: kept, gone: gone} = ctx

      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: kept.id,
        target_article_id: gone.id,
        relationship_type: :relates_to
      })

      {:ok, %{results: results}} = Knowledge.get_context(tenant.id, "widget calibration")

      linked =
        results
        |> Enum.flat_map(&Map.get(&1, :linked_articles, []))
        |> MapSet.new(& &1.id)

      refute MapSet.member?(linked, gone.id),
             "the id and title of a suppressed article leaked through a neighbour's " <>
               "linked_articles."
    end

    test "the by-id read does not name it as a NEIGHBOUR of a live article", ctx do
      %{tenant: tenant, kept: kept, gone: gone} = ctx

      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: kept.id,
        target_article_id: gone.id,
        relationship_type: :relates_to
      })

      {:ok, article} = Knowledge.get_article(tenant.id, kept.id)

      refute Enum.any?(article.outgoing_links, &(&1.target_article_id == gone.id)),
             "knowledge_get named a suppressed neighbour by id and title. The by-id " <>
               "exemption covers resolving the SUPPRESSED article itself, not naming it " <>
               "as a neighbour of a live one."
    end

    test "the links listing does not name it as a far side", ctx do
      %{tenant: tenant, kept: kept, gone: gone} = ctx

      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: kept.id,
        target_article_id: gone.id,
        relationship_type: :relates_to
      })

      far_ids =
        tenant.id
        |> Knowledge.list_links_for_article(kept.id)
        |> MapSet.new(& &1.target_article_id)

      refute MapSet.member?(far_ids, gone.id),
             "GET /articles/:id/links named a suppressed far side by id and title."

      # ...and the suppressed article's OWN links still list, or the undo has no context.
      assert tenant.id |> Knowledge.list_links_for_article(gone.id) |> length() == 1
    end

    test "suggest_links refuses a suppressed anchor", %{tenant: tenant, gone: gone} do
      assert {:error, :not_found} = Knowledge.suggest_links(tenant.id, gone.id)
    end

    test "the random walk will not start from it", %{tenant: tenant, gone: gone} do
      assert {:error, :not_found} = Knowledge.random_walk(tenant.id, gone.id)
    end
  end

  describe "unsuppress restores it to those same paths" do
    test "an article suppressed and then restored is searchable and listable again" do
      tenant = fixture(:tenant)
      article = published(tenant.id, %{title: "Widget calibration restored"})

      suppress!(tenant.id, article)
      {:ok, %{results: while_gone}} = Knowledge.search_keyword(tenant.id, "widget")
      refute MapSet.member?(ids(while_gone), article.id)

      {:ok, _} = Knowledge.unsuppress_article(tenant.id, article.id)

      # Immediately, with no re-embedding and no re-linking — that is the difference from
      # `:archived`, which nothing automated brings back at all.
      {:ok, %{results: after_restore}} = Knowledge.search_keyword(tenant.id, "widget")
      assert MapSet.member?(ids(after_restore), article.id)

      {:ok, %{articles: grouped}} = Knowledge.list_index(tenant.id)
      assert grouped |> Map.values() |> List.flatten() |> ids() |> MapSet.member?(article.id)
    end
  end

  describe "the index's :suppressed mode — how an operator finds what to undo" do
    setup do
      tenant = fixture(:tenant)
      kept = published(tenant.id)
      gone = published(tenant.id)
      %{tenant: tenant, kept: kept, gone: suppress!(tenant.id, gone)}
    end

    defp index_ids(tenant_id, opts) do
      {:ok, %{articles: grouped}} = Knowledge.list_index(tenant_id, opts)
      grouped |> Map.values() |> List.flatten() |> ids()
    end

    test ":only lists nothing but the suppressed set", %{
      tenant: tenant,
      kept: kept,
      gone: gone
    } do
      listed = index_ids(tenant.id, suppressed: :only)

      assert MapSet.member?(listed, gone.id)
      refute MapSet.member?(listed, kept.id)
    end

    test ":include returns both", %{tenant: tenant, kept: kept, gone: gone} do
      listed = index_ids(tenant.id, suppressed: :include)

      assert MapSet.member?(listed, gone.id)
      assert MapSet.member?(listed, kept.id)
    end

    test ":only reaches a suppressed article of ANY status", %{tenant: tenant} do
      # suppress_article/3 takes no view of status, so a suppressed DRAFT would be listed
      # nowhere at all — and the undo needs an id from somewhere.
      draft = fixture(:article, %{tenant_id: tenant.id, status: :draft})
      suppressed_draft = suppress!(tenant.id, draft)

      assert MapSet.member?(index_ids(tenant.id, suppressed: :only), suppressed_draft.id)
    end

    test "an unrecognised mode fails CLOSED to :exclude", %{tenant: tenant, gone: gone} do
      # A typo in an opt must never open a suppressed article back onto a retrieval surface.
      refute MapSet.member?(index_ids(tenant.id, suppressed: :inclde), gone.id)
      refute MapSet.member?(index_ids(tenant.id, suppressed: nil), gone.id)
    end
  end

  describe "an IDENTITY lookup still sees it — the existence check create/3 dedups against" do
    test "list_articles by idempotency_key finds a suppressed row, and every other filter does not" do
      tenant = fixture(:tenant)
      key = "idem-suppressed-#{System.unique_integer([:positive])}"

      article =
        published(tenant.id, %{idempotency_key: key, tags: ["book-probe"]})
        |> then(&suppress!(tenant.id, &1))

      %{meta: %{total_count: by_key}} = Knowledge.list_articles(tenant.id, idempotency_key: key)
      %{meta: %{total_count: by_tag}} = Knowledge.list_articles(tenant.id, tags: ["book-probe"])

      assert by_key == 1,
             "the documented existence check reported \"never captured\" about the exact " <>
               "row create_article/3 dedups against — the caller's body is then discarded."

      assert by_tag == 0, "an ENUMERATION still excludes suppressed rows"

      # And the create it guards really would swallow a fresh body.
      assert {:ok, :deduplicated, %Article{id: same}} =
               Knowledge.create_article(tenant.id, %{
                 title: "A different article entirely",
                 body: "A different body entirely, long enough to be a real article body.",
                 category: :pattern,
                 idempotency_key: key
               })

      assert same == article.id
    end
  end

  describe "a malformed reason is refused, never raised" do
    test "invalid UTF-8 is an error tuple, not a charlist conversion error" do
      # No HTTP parser carries these bytes this far — Plug's urlencoded parser raises
      # BadEncodingError and Jason rejects them — but the length check must not be the thing
      # that decides, because `String.to_charlist/1` RAISES here and a raise out of a
      # context function is a 500 where the contract says 422.
      tenant = fixture(:tenant)
      article = published(tenant.id)

      assert {:error, :unprocessable_entity, "reason must be valid UTF-8"} =
               Knowledge.suppress_article(tenant.id, article.id, reason: <<0xED, 0xA0, 0x80>>)

      assert AdminRepo.get!(Article, article.id).suppressed_at == nil
    end
  end

  describe "OKF export is a BACKUP surface, not a retrieval one" do
    test "a suppressed article is exported, carrying its tombstone as frontmatter" do
      tenant = fixture(:tenant)
      article = published(tenant.id, %{title: "Exported while suppressed"})
      suppress!(tenant.id, article, reason: "retention figure is wrong")

      {:ok, %{files: files}} = OKF.build_bundle(tenant.id)

      concept =
        Enum.find(files, fn {path, _body} -> path =~ "exported-while-suppressed" end)

      # Dropping the row would make the bundle lossier than the corpus it came from; dropping
      # the tombstone would restore it as an ordinary live article with no record that anyone
      # had ever taken it out of retrieval.
      assert {_path, contents} = concept
      assert contents =~ "loopctl_suppressed_at"
      assert contents =~ "loopctl_suppression_reason"
      assert contents =~ "retention figure is wrong"
    end

    test "the STREAMED .tar.gz carries the same tombstone as the buffered bundle" do
      # The streamed path is the DEFAULT export and builds rows from an explicit projection,
      # not from %Article{}. A column missing from that select makes
      # OKF.suppression_frontmatter/1 hit its catch-all and emit nothing — silently.
      tenant = fixture(:tenant)
      article = published(tenant.id, %{title: "Streamed while suppressed"})
      suppress!(tenant.id, article, reason: "retention figure is wrong")

      {:ok, targz} = StreamingExportHelper.to_targz_binary(tenant.id, OKFFormat)
      {:ok, files} = StreamingExportHelper.extract(targz)

      {_path, contents} =
        Enum.find(files, fn {path, _body} -> path =~ "streamed-while-suppressed" end)

      assert contents =~ "loopctl_suppressed_at"
      assert contents =~ "loopctl_suppressed_by"
      assert contents =~ "loopctl_suppression_reason"
      assert contents =~ "retention figure is wrong"
    end

    test "a live article carries none of the three keys" do
      tenant = fixture(:tenant)
      published(tenant.id, %{title: "Exported while live"})

      {:ok, %{files: files}} = OKF.build_bundle(tenant.id)
      {_path, contents} = Enum.find(files, fn {path, _b} -> path =~ "exported-while-live" end)

      refute contents =~ "loopctl_suppressed"
    end
  end

  describe "the fields are not castable" do
    test "an ordinary update cannot set or clear the tombstone" do
      tenant = fixture(:tenant)
      article = published(tenant.id)
      suppress!(tenant.id, article, reason: "held")

      # `metadata` is cast and whole-map-replaced by PATCH, so if any of the three were
      # castable, one ordinary request would lift a suppression with no audit and no actor.
      {:ok, updated} =
        Knowledge.update_article(tenant.id, article.id, %{
          "title" => "Renamed",
          "suppressed_at" => nil,
          "suppressed_by" => "attacker",
          "suppression_reason" => "cleared"
        })

      assert updated.title == "Renamed"
      assert updated.suppressed_at != nil
      assert updated.suppression_reason == "held"
    end
  end
end
