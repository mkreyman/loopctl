defmodule Loopctl.Knowledge.SnippetBackfillTest do
  @moduledoc """
  Every search result explains itself, whichever lane found it.

  `snippet` is a `ts_headline` highlight and therefore comes only from the KEYWORD lane, so
  a result the query did not lexically match — precisely what the semantic lane is for —
  used to arrive as a bare title. An agent handed a bare title cannot judge it: it opens
  blindly or ignores the row, and both land in the follow-through metric as retrieval's
  fault.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article

  # The test-mode embedding mock returns a per-tenant CONSTANT vector, so the semantic lane
  # cannot discriminate on its own. Seed a known vector explicitly and query with it — the
  # same approach the retrieval eval takes, and it keeps these tests about the SNIPPET
  # rather than about ranking.
  # Every vector here — the stored embeddings AND the query — rides `test_vec/2`, so this
  # test's rows occupy its OWN sparse dimensions of the shared pgvector HNSW index
  # (`Process.put(:test_vec_axis, ...)` in DataCase.setup). The literal it replaced was
  # `[1.0 | zeros]`: dimension 0, shared by every test in this file and colliding with any
  # peer that also reached for the obvious vector.
  #
  # That literal is why this file hit #645 in CI on 2026-08-22 ("the canonical must be
  # retrievable for this assertion to mean anything", green on rerun). The sandbox rolls
  # each test back, a rolled-back INSERT leaves a dead entry in the graph, and a live row
  # that links only to dead neighbours becomes UNREACHABLE — so the ANN read returns nothing
  # while the row is demonstrably present. Sharing one axis is what puts this file's rows in
  # the same corner of the graph as everyone else's corpses.
  #
  # The alternative repair, `@moduletag :vacuum_vector_indexes`, works but is not free:
  # measured on this suite, adding it to this ONE module took the full run from 37.9s to
  # 56.2s (+50%), because the VACUUM contends with every other async worker rather than
  # costing anything much on its own. Prefer the axis; reach for the vacuum only where an
  # ANN assertion genuinely cannot be isolated onto one.
  defp query_vector, do: test_vec(1536, :primary)

  defp published(tenant_id, title, body) do
    {:ok, article} =
      Knowledge.create_article(tenant_id, %{
        title: title,
        body: body,
        category: :finding,
        tags: []
      })

    # `create_article/2` yields a DRAFT under the test config, and the semantic lane is
    # published-only — an unpublished article is simply not retrievable, which would make
    # every assertion below vacuous.
    article =
      article
      |> Ecto.Changeset.change(%{status: :published})
      |> AdminRepo.update!()

    {:ok, _} = Embeddings.upsert_article_embedding(tenant_id, article, query_vector())
    article
  end

  describe "lead extraction" do
    test "skips the auto-extraction banner that opens 99 articles in this corpus" do
      tenant = fixture(:tenant)

      body = """
      > Auto-extracted from a session transcript on 2026-08-12 and NOT verified by a human.
      > Verify anything load-bearing against the source before relying on it.

      The novelty gate dedups a proposal against the PUBLISHED corpus only, so a draft is
      invisible to it and a near-duplicate draft never trips the gate.
      """

      article =
        published(tenant.id, "Novelty gate scope #{System.unique_integer([:positive])}", body)

      {:ok, %{results: results}} =
        Knowledge.search_semantic(tenant.id, query_vector(), limit: 20)

      hit = Enum.find(results, &(&1.id == article.id))
      assert hit, "the seeded article must be retrievable to test its snippet"

      refute hit.snippet =~ "Auto-extracted",
             "a lead built from the banner explains nothing while looking like it does"

      refute hit.snippet =~ "NOT verified by a human"
      assert hit.snippet =~ "novelty gate", "the lead must be the article's first real prose"
      assert hit.snippet_source == "lead"
    end

    test "skips a leading heading, rule and bullet list" do
      tenant = fixture(:tenant)

      body = """
      # Title repeated as a heading

      ---

      - a bullet that is not the point
      - another bullet

      Dispatch lineage is resolved server side from the authenticating key and never
      supplied by the client.
      """

      article = published(tenant.id, "Lineage note #{System.unique_integer([:positive])}", body)

      {:ok, %{results: results}} =
        Knowledge.search_semantic(tenant.id, query_vector(), limit: 20)

      hit = Enum.find(results, &(&1.id == article.id))
      assert hit.snippet =~ "Dispatch lineage"
      refute hit.snippet =~ "Title repeated"
      refute hit.snippet =~ "bullet"
    end

    test "a body that is ONLY front matter still gets a snippet rather than an empty one" do
      tenant = fixture(:tenant)
      body = "> just a banner line\n> and another\n"
      article = published(tenant.id, "Banner only #{System.unique_integer([:positive])}", body)

      {:ok, %{results: results}} =
        Knowledge.search_semantic(tenant.id, query_vector(), limit: 20)

      hit = Enum.find(results, &(&1.id == article.id))

      assert is_binary(hit.snippet) and hit.snippet != "",
             "falling through to an empty snippet would be worse than the banner"
    end

    test "markup is stripped and the text is truncated on a word boundary" do
      tenant = fixture(:tenant)

      long =
        "The " <>
          String.duplicate(
            "consolidation pass retracts a confirmed duplicate with unpublish rather than archive ",
            8
          )

      body = "Some **bold** and `code` and a [link](https://example.com/x) then #{long}"
      article = published(tenant.id, "Long body #{System.unique_integer([:positive])}", body)

      {:ok, %{results: results}} =
        Knowledge.search_semantic(tenant.id, query_vector(), limit: 20)

      hit = Enum.find(results, &(&1.id == article.id))

      refute hit.snippet =~ "**"
      refute hit.snippet =~ "`"
      refute hit.snippet =~ "https://example.com"
      assert hit.snippet =~ "link", "link TEXT is kept; only the url is dropped"

      assert String.length(hit.snippet) <= Knowledge.max_snippet_length(),
             "the ellipsis fits INSIDE the cap — at cap+1 the renderer re-truncates and " <>
               "appends a second one"

      # The real check: the final token must be a WHOLE word of the source, not a fragment
      # of one. (An earlier version of this test asserted a regex that matched every
      # correctly-truncated snippet, so it could never fail — the shape of a vacuous test.)
      assert String.ends_with?(hit.snippet, "…")

      last_token =
        hit.snippet
        |> String.trim_trailing("…")
        |> String.trim()
        |> String.split(" ")
        |> List.last()

      assert String.match?(body, ~r/(^|\s)#{Regex.escape(last_token)}(\s|$)/),
             "snippet ended on #{inspect(last_token)}, which is not a whole word of the body"
    end

    test "an identifier's underscores and backticks survive the markup strip" do
      # An unanchored `[*_`]+` ate the underscores INSIDE identifiers, so `tenant_id` was
      # shown as `tenantid` — a snippet naming things the corpus does not contain is worse
      # than no snippet, and the reranker judges relevance on the same text.
      tenant = fixture(:tenant)

      body =
        "Every context function takes tenant_id first, and `__MODULE__` with an _unused " <>
          "arg wraps it in *emphasis* that must go."

      article = published(tenant.id, "Identifiers #{System.unique_integer([:positive])}", body)

      {:ok, %{results: results}} =
        Knowledge.search_semantic(tenant.id, query_vector(), limit: 20)

      hit = Enum.find(results, &(&1.id == article.id))

      assert hit.snippet =~ "tenant_id"
      # The EDGES too: a token-boundary rule protects only underscores flanked by
      # alphanumerics on both sides, so `__MODULE__` came back as `MODULE` and `_unused` as
      # `unused` — identifiers the corpus does not contain, which is the same defect one
      # character over.
      assert hit.snippet =~ "__MODULE__"
      assert hit.snippet =~ "_unused"
      refute hit.snippet =~ "`"
      refute hit.snippet =~ "*emphasis*"
      assert hit.snippet =~ "emphasis"
    end
  end

  describe "which results get filled" do
    test "a keyword hit keeps its highlight and is labelled as one" do
      tenant = fixture(:tenant)

      published(
        tenant.id,
        "Byzantine halt semantics #{System.unique_integer([:positive])}",
        "A divergent signed tree head escalates to a tenant wide custody halt."
      )

      {:ok, %{results: results}} =
        Knowledge.search_keyword(tenant.id, "divergent signed tree head")

      assert [hit | _] = results
      assert hit.snippet =~ "**", "a ts_headline highlight marks the matched terms"
    end

    test "the semantic-only hit is the one that gains a snippet it did not have" do
      tenant = fixture(:tenant)

      article =
        published(
          tenant.id,
          "Zero lexical overlap #{System.unique_integer([:positive])}",
          "Quiescent apparatus enumerates its own provenance without ceremony or fanfare."
        )

      {:ok, %{results: results}} =
        Knowledge.search_semantic(tenant.id, query_vector(), limit: 20)

      hit = Enum.find(results, &(&1.id == article.id))

      assert hit.snippet_source == "lead"
      assert hit.snippet =~ "Quiescent apparatus"
    end

    test "a system-scope canonical gets a lead too, not a bare title" do
      # Every search population here is the DISJUNCTIVE `tenant_id == ^t or scope ==
      # :system`, so a page can carry system canonicals — whose NULL `tenant_id` cannot
      # satisfy the heavy-read tenant guard. Filling only the tenant-scoped rows left the
      # shared canon as exactly the bare-title case this feature exists to remove, and made
      # one page inconsistent with itself.
      tenant = fixture(:tenant)
      stub(Loopctl.MockEmbeddingReadPath, :side_table_reads_enabled?, fn -> true end)

      canonical =
        %Article{tenant_id: nil, scope: :system}
        |> Article.create_changeset(%{
          title: "Shared canonical #{System.unique_integer([:positive])}",
          body: "Chain of custody separates the implementer from the verifier.",
          category: :reference,
          status: :published,
          scope: :system
        })
        |> AdminRepo.insert!()

      {:ok, _} =
        Embeddings.materialize_system_article_embedding(
          tenant.id,
          canonical,
          query_vector(),
          "sys",
          1536
        )

      {:ok, %{results: results}} =
        Knowledge.search_semantic(tenant.id, query_vector(), limit: 20)

      hit = Enum.find(results, &(&1.id == canonical.id))
      assert hit, "the canonical must be retrievable for this assertion to mean anything"
      assert hit.snippet_source == "lead"
      assert hit.snippet =~ "Chain of custody"
    end

    test "another tenant's body is never used to fill a snippet" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      published(
        tenant_b.id,
        "Tenant B secret #{System.unique_integer([:positive])}",
        "Tenant B body text."
      )

      a =
        published(
          tenant_a.id,
          "Tenant A doc #{System.unique_integer([:positive])}",
          "Tenant A body text."
        )

      {:ok, %{results: results}} =
        Knowledge.search_semantic(tenant_a.id, query_vector(), limit: 20)

      Enum.each(results, fn r ->
        refute r.snippet =~ "Tenant B", "a snippet is body text — cross-tenant fill is a leak"
      end)

      hit = Enum.find(results, &(&1.id == a.id))
      assert hit.snippet =~ "Tenant A"
    end
  end
end
