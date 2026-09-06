defmodule Loopctl.Knowledge.Suppression do
  @moduledoc """
  The ONE composable predicate that keeps a retrieval-suppressed article out of every ranked
  read path — plus the declared inventory the drift guard binds it to.

  ## The primitive

  Suppression is a REVERSIBLE retrieval tombstone. `articles.suppressed_at` is the whole
  predicate; `suppressed_by` and `suppression_reason` record who and why so the act is
  inspectable and undoable. It says nothing about `status`: a suppressed article stays
  `:published`, keeps its embedding, its links and its body, and stays resolvable by id.

  It exists because the two markers loopctl already had cannot say this. `:archived` is
  TERMINAL (#605/#606) — nothing automated restores it — and `unpublish` is undoable but
  claims the article is a DRAFT, which is an editorial statement rather than a retrieval one.
  That mismatch is why the nightly consolidation pass retracts a confirmed duplicate with
  `unpublish` (#608) rather than with the marker it actually wants.

  Written only by `Loopctl.Knowledge.suppress_article/3` and
  `Loopctl.Knowledge.unsuppress_article/2`, through
  `Loopctl.Knowledge.Article.suppression_changeset/2`. None of the three fields is castable
  anywhere.

  ## Why the predicate lives here and not at ~40 call sites

  `lib/` carries roughly forty places that filter articles to `:published`. Hand-editing each
  one is a one-time fix with no memory: the next read path added is written by someone who
  never saw this module, and a read path that forgets the predicate does not FAIL — it
  silently serves an article a caller asked the system to forget. So the predicate is one
  function here, and `test/loopctl/knowledge/suppression_guard_test.exs` scans `lib/` for
  published-status filter sites and fails on any that neither carries the predicate nor is
  named in `exempt_sites/0` with a reason. That guard is the durable half; these helpers are
  just what it checks for.

  ## What the guard can and cannot see

  It matches the LITERAL `<binding>.status == :published` form, because that is the form a
  new read path is written in. It is blind to a PARAMETRIZED status (`a.status == ^status`,
  `maybe_filter_by_status/2`) and to raw SQL, so the paths that take their status from the
  caller or write it as a string — `Loopctl.Knowledge.VectorSearch`'s two ANN branches, the
  RRF graph lane's hydration, `apply_search_filters/3`, `apply_article_filters/2`, and the
  recursive graph CTE and bridge fragments — are pinned by their own named assertions in
  that same test rather than by the scan. If you add another one, add the assertion with
  it; the scan will not catch it for you.

  ## Binding position

  Ecto positional bindings are not dynamic, so there are two entry points rather than one
  parameterised call: `exclude/1` for a query whose FIRST binding is the article, and
  `exclude_last/1` for one whose LAST binding is (the `[..., a]` form). A query where the
  article is neither first nor last writes `is_nil(<binding>.suppressed_at)` inline, which
  the guard's binding-agnostic marker recognises exactly as it recognises a call to this
  module.
  """

  import Ecto.Query

  @typedoc """
  How a query treats suppressed articles.

    * `:exclude` — the default everywhere. Suppressed articles are not returned.
    * `:include` — return them alongside live ones. For inspection surfaces only.
    * `:only` — return NOTHING BUT suppressed articles. This is the discovery path: an
      operator listing what there is to undo.
  """
  @type mode :: :exclude | :include | :only

  @doc """
  Excludes suppressed articles from a query whose FIRST binding is the article.

  This is the common case and the one to reach for by default.
  """
  @spec exclude(Ecto.Queryable.t()) :: Ecto.Query.t()
  def exclude(query), do: where(query, [a], is_nil(a.suppressed_at))

  @doc """
  Excludes suppressed articles from a query whose LAST binding is the article.

  For the joined shapes — the side-table ANN joins `articles` as its second binding.
  """
  @spec exclude_last(Ecto.Queryable.t()) :: Ecto.Query.t()
  def exclude_last(query), do: where(query, [..., a], is_nil(a.suppressed_at))

  @doc """
  Applies `mode` to a query whose FIRST binding is the article.

  `:exclude` (the default at every call site) is `exclude/1`; `:include` is the identity;
  `:only` inverts the predicate. An unrecognised value falls through to `:exclude` rather
  than to `:include` — a typo in an opt must fail CLOSED, never open a suppressed article
  back onto a retrieval surface.
  """
  @spec filter(Ecto.Queryable.t(), mode() | nil) :: Ecto.Query.t()
  def filter(query, :include), do: query
  def filter(query, :only), do: where(query, [a], not is_nil(a.suppressed_at))
  def filter(query, _exclude), do: exclude(query)

  @doc """
  Parses a caller-supplied `suppressed` parameter into a `t:mode/0`.

  Anything unrecognised — including `nil` and a misspelling — resolves to `:exclude`, for the
  fail-closed reason in `filter/2`.
  """
  @spec parse_mode(term()) :: mode()
  def parse_mode("include"), do: :include
  def parse_mode("only"), do: :only
  def parse_mode(:include), do: :include
  def parse_mode(:only), do: :only
  def parse_mode(_), do: :exclude

  @doc """
  Whether a struct or map carries the tombstone. Pure; no DB call.
  """
  @spec suppressed?(map()) :: boolean()
  def suppressed?(%{suppressed_at: %DateTime{}}), do: true
  def suppressed?(_), do: false

  # --- The drift-guard inventory (read by suppression_guard_test.exs) ---

  @doc """
  Source-text patterns that mean "this function applies the suppression predicate".

  A published-status filter site passes the guard when its enclosing function body matches
  any of these. The `is_nil(...)` pattern is BINDING-AGNOSTIC on purpose: joined queries
  write the predicate against `src`, `tgt`, `n`, `o` or `a2`, and a marker list that named
  bindings one by one would go stale the first time someone renamed one — silently, by
  reporting a covered site as uncovered and inviting the next person to exempt it.

  `filter/2` counts only when the mode is not the LITERAL `:include`: that arm returns
  suppressed rows, so matching it would let a call that deliberately opens the surface back
  up read as coverage. A mode read from an opt still counts, because `:exclude` is its
  default and a caller-supplied mode is the point of the surfaces that take one.

  These are matched against source with COMMENT LINES STRIPPED. This feature's explanations
  are written as `#` comments right next to the predicates, so a substring match over raw
  source would let a site be covered by its own prose — the failure loopctl has shipped once
  already, and the reason `body_has_filter_site?/1` strips comments on the detection side too.
  """
  @spec predicate_markers() :: [Regex.t()]
  def predicate_markers do
    [
      ~r/Suppression\.exclude/,
      ~r/Suppression\.filter\((?![^()]*:include[^()]*\))/,
      ~r/is_nil\([a-z_][a-zA-Z0-9_]*\.suppressed_at\)/,
      ~r/suppressed_at IS NULL/
    ]
  end

  @doc """
  Published-status filter sites that deliberately do NOT exclude suppressed articles, each
  with the reason it is exempt.

  Keyed `"path:function"`, valued with prose. Two rules make this list load-bearing rather
  than an escape hatch: the guard fails on an entry that no longer matches a real site (a
  stale exemption cannot accumulate), and every reason names which of the four categories
  below it falls into.

    * **inspect** — the by-id read path. A suppression that hides the article from its own
      undo endpoint is not reversible.
    * **backup** — export. Export is a backup surface, not a retrieval one: a suppressed
      article ships WITH its three tombstone fields, so a bundle is neither lossy about the
      row nor silent about the suppression.
    * **maintenance** — embedding, reclassification, tenant selection, corpus measurement.
      These keep a suppressed article's derived state current so `unsuppress` restores it
      instantly rather than leaving it unretrievable until the next nightly pass.
    * **system-scope** — the canonical wiki. Suppression is a per-tenant act and a system
      canonical has no `tenant_id` to suppress it under.
  """
  @spec exempt_sites() :: %{String.t() => String.t()}
  def exempt_sites do
    %{
      # --- inspect ---
      "lib/loopctl/knowledge.ex:visible_article_scope" =>
        "inspect — the by-id read path behind get_article/3 and knowledge_get. A suppressed " <>
          "article MUST stay resolvable by id, or the suppression can be neither inspected " <>
          "nor undone.",

      # --- backup ---
      "lib/loopctl/knowledge/okf.ex:export_query" =>
        "backup — the OKF bundle ships suppressed rows WITH loopctl_suppressed_at/by/reason " <>
          "(see OKF.suppression_frontmatter/1). Dropping the row would make the bundle " <>
          "lossier than the corpus; dropping the tombstone would restore it as an ordinary " <>
          "live article with no record that anyone had taken it out of retrieval.",
      "lib/loopctl/knowledge/okf.ex:related_links" =>
        "backup — the link half of the same export. Dropping links to a suppressed article " <>
          "would make the restored graph lossier than the one exported.",
      "lib/loopctl/knowledge/streaming_export.ex:base_query" =>
        "backup — the streamed .tar.gz row source, same contract as the OKF bundle, and the " <>
          "path an operator actually restores from.",
      "lib/loopctl/knowledge/streaming_export/okf_format.ex:related_links" =>
        "backup — link serialization inside the streamed OKF bundle.",
      "lib/loopctl/knowledge/streaming_export/obsidian_format.ex:build_related_section" =>
        "backup — link serialization inside the streamed Obsidian vault.",

      # --- maintenance ---
      "lib/loopctl/knowledge.ex:maybe_enqueue_embedding" =>
        "maintenance — a struct check on a WRITE path, not a query. A suppressed article " <>
          "keeps its embedding current so unsuppress restores it to search immediately " <>
          "instead of leaving it invisible until the next reconciliation pass.",
      "lib/loopctl/embeddings.ex:system_articles_query" =>
        "maintenance — enumerates system canonicals for embedding materialization; see the " <>
          "system-scope reason below.",
      "lib/loopctl/workers/embedding_reconciliation_worker.ex:tenant_ids" =>
        "maintenance — selects TENANTS holding published articles, never articles.",
      "lib/loopctl/workers/knowledge_reclassify_worker.ex:fetch_batch" =>
        "maintenance — re-derives categories. Letting a suppressed article's category go " <>
          "stale would surface a wrong category the moment it is unsuppressed.",
      "lib/loopctl/workers/structural_links_worker.ex:harvestable_tenants" =>
        "maintenance — selects TENANTS with a harvestable corpus, never articles.",
      "lib/loopctl/knowledge/analytics.ex:list_unused_articles" =>
        "maintenance — a corpus MEASUREMENT, not a read path. Excluding suppressed rows " <>
          "would hide them from the operator report that explains why reads dropped.",
      # --- system-scope ---
      "lib/loopctl/knowledge.ex:list_system_articles" =>
        "system-scope — system canonicals have a NULL tenant_id, and suppress_article/3 is " <>
          "tenant-scoped, so no tenant can suppress one.",
      "lib/loopctl_web/live/wiki_index_live.ex:handle_event" =>
        "system-scope — the public wiki browses system canonicals only.",
      "lib/mix/tasks/loopctl.check_wiki_links.ex:run" =>
        "system-scope — an operator link-checker over the system canon, run from a shell."
    }
  end
end
