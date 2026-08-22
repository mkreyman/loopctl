defmodule Loopctl.Knowledge.OKF do
  @moduledoc """
  OKF (Open Knowledge Format) v0.1 interchange for the knowledge wiki.

  OKF is Google Cloud's vendor-neutral spec for portable knowledge bundles: a
  directory tree of markdown files, each with a YAML frontmatter block whose only
  required field is `type`. See https://github.com/GoogleCloudPlatform/knowledge-catalog/tree/main/okf.

  This module is an **interchange adapter**, not a rearchitecture — loopctl stays
  DB-backed and API-served; OKF is only how knowledge enters and leaves as files.

  ## Mapping (loopctl <-> OKF)

  | OKF                          | loopctl                                  |
  |------------------------------|------------------------------------------|
  | `type` (required)            | article `category` (+ original preserved) |
  | `title` / `tags` / `timestamp` | direct                                 |
  | `resource` / `description`   | preserved under `metadata["okf"]`        |
  | `index.md` (per directory)   | generated progressive-disclosure listing |
  | `log.md`                     | date-grouped article history             |
  | cross-links (`# Related`)    | the `relates_to` article-link graph      |

  ## Round-trip fidelity

  Exported concept files carry loopctl-namespaced producer keys
  (`loopctl_id`, `loopctl_category`, `loopctl_status`) plus a marked `# Related`
  section, so a loopctl-origin bundle re-imports its content, category, tags, and
  `relates_to`/`derived_from` graph faithfully. Foreign bundles (no `loopctl_*`
  keys) import permissively: unknown frontmatter keys are preserved under
  `metadata["okf"]`, unknown `type` values fall back to the `reference` category,
  and bodies are stored verbatim — per the OKF §9 permissive-consumer rule, a
  bundle is never rejected for unknown types/keys.

  Import is deliberately conservative on anything that affects trust or
  lifecycle: every imported article lands as a `:draft` (publication is a
  separate, explicit step, so a forged `loopctl_status` can't auto-publish), and
  `:supersedes`/`:contradicts` edges are not reconstructed (they would retire a
  target article). A `loopctl_id` resolves a re-import only against an article we
  ourselves previously imported (its stored `loopctl_id`), never an arbitrary
  same-id row, so it can't be used as a cross-article overwrite primitive.

  The public surface works on a **files map** (`%{"path/to.md" => "content"}`)
  so the HTTP/MCP layers can choose zip or JSON transport without this module
  caring.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.ImportExport.DecompressionLimit
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.IdempotencyTag

  @okf_version "0.1"

  # IMPORT-side concept cap: a hostile/huge bundle can't create an unbounded number
  # of articles in one request. This is independent of EXPORT (US-27.16 removed the
  # export's article-count cap in favor of bounded-memory streaming); import is still
  # a synchronous, per-file mutation, so it keeps an explicit ceiling.
  @max_import_concepts 5_000

  # BUFFERED-EXPORT cap (`?format=json` ONLY): the JSON convenience path materializes
  # the WHOLE bundle in memory (it returns a `%{files: ...}` map), so it MUST keep a
  # count cap or a 76k-article KB would OOM the node. The BACKUP path — the default
  # streamed `.tar.gz` — has NO count cap (it is bounded-memory by construction);
  # callers above this bound are pointed there. Over the cap, `build_bundle/2`
  # returns `{:error, :payload_too_large}`. Runtime-configurable (so the over-cap
  # 413 is testable cheaply); defaults to 5,000.
  @max_buffered_export_articles 5_000

  @doc "The `?format=json` buffered-export article-count cap (config-tunable)."
  @spec max_buffered_export_articles() :: pos_integer()
  def max_buffered_export_articles,
    do:
      Application.get_env(
        :loopctl,
        :okf_max_buffered_export_articles,
        @max_buffered_export_articles
      )

  @categories Ecto.Enum.values(Article, :category)
  @category_strings Enum.map(@categories, &to_string/1)

  # Frontmatter keys this module owns; everything else is preserved verbatim.
  # Frontmatter keys THIS module owns (set on export, stripped from `extra` on
  # import so they don't survive as foreign metadata). `loopctl_links_truncated` is
  # the #7 marker the exporter emits on a capped link list; without it here, a
  # re-import would stash it under `metadata["okf"]["extra"]` and re-export it as
  # foreign frontmatter forever. The dead `loopctl_links` key (never produced) is
  # dropped.
  @reserved_fm_keys ~w(type title description resource tags timestamp
                       loopctl_id loopctl_category loopctl_status loopctl_links_truncated)

  @related_marker "<!-- okf:related -->"

  @typedoc "A bundle as an in-memory map of POSIX path -> file contents."
  @type files :: %{optional(String.t()) => String.t()}

  # ---------------------------------------------------------------------------
  # Export
  # ---------------------------------------------------------------------------

  @doc """
  Builds an OKF bundle (files map) from a tenant's published articles, fully in
  memory.

  This is the BUFFERED convenience used by the `?format=json` export path (tooling
  that writes the files itself). It materializes the whole bundle, so it is bounded
  by an article-count cap (#{@max_buffered_export_articles}) to avoid OOMing on a
  large KB. The DEFAULT/backup export path streams a `.tar.gz` with bounded memory
  via `Loopctl.Knowledge.StreamingExport` and has NO count cap; callers above the
  cap should use it.

  ## Options

  - `:project_id` — when set, includes tenant-wide (nil project) + project articles.
  - `:max_articles` — override the buffered-export count cap for THIS call (defaults
    to `max_buffered_export_articles/0`). The HTTP `?format=json` path uses the
    default; callers that legitimately need a different bound (e.g. re-export of an
    imported multi-article bundle in tests) pass it explicitly.

  ## Returns

  - `{:ok, %{files: files, meta: map}}`
  - `{:error, :payload_too_large}` when the published-article count exceeds the cap
    (use the streamed `.tar.gz` export instead).
  """
  @spec build_bundle(Ecto.UUID.t(), keyword()) ::
          {:ok, %{files: files(), meta: map()}} | {:error, :payload_too_large}
  def build_bundle(tenant_id, opts \\ []) do
    project_id = Keyword.get(opts, :project_id)
    cap = Keyword.get(opts, :max_articles, max_buffered_export_articles())

    # (#2) The cap is enforced on the ACTUAL MATERIALIZED set, not a separate COUNT.
    # Fetch `cap + 1` (peek): if we got more than `cap`, the bundle is over-cap →
    # reject (never silently TRUNCATE to `cap`, which would drop articles from the
    # json bundle). This closes the TOCTOU where rows published between a COUNT and
    # the fetch would otherwise materialize unbounded — the SQL LIMIT hard-bounds the
    # materialized rows at `cap + 1` regardless. The COUNT is gone; the LIMIT is the
    # gate.
    articles = fetch_published(tenant_id, project_id, cap + 1)

    if length(articles) > cap do
      {:error, :payload_too_large}
    else
      paths = assign_paths(articles)
      files = build_files(articles, paths)

      {:ok,
       %{
         files: files,
         meta: %{
           okf_version: @okf_version,
           article_count: length(articles)
         }
       }}
    end
  end

  # NB: build_bundle/2 reads via AdminRepo (NOT the HeavyRead structural tenant
  # guard). The tenant scope is enforced by `export_query/2`'s explicit
  # `a.tenant_id == ^tenant_id` predicate, and the SQL LIMIT (`limit_with_peek`)
  # hard-bounds the materialized row set so the buffered path can never OOM. The
  # streamed backup path DOES go through HeavyRead's guard; this buffered convenience
  # path is bounded + explicitly tenant-scoped here.
  defp fetch_published(tenant_id, project_id, limit_with_peek) do
    tenant_id
    |> export_query(project_id)
    |> preload(outgoing_links: :target_article)
    |> order_by([a], asc: a.category, asc: a.title, asc: a.id)
    |> limit(^limit_with_peek)
    |> AdminRepo.all()
  end

  defp export_query(tenant_id, project_id) do
    query = from(a in Article, where: a.tenant_id == ^tenant_id and a.status == :published)

    # Guard the :binary_id cast: a non-UUID project_id (malformed string, or a
    # non-string that is truthy) would CastError-500 on the `== ^project_id`
    # comparison — and for the ?format=json export path, AFTER the buffered
    # bundle build starts. A malformed value scopes to tenant-wide only.
    cond do
      is_nil(project_id) ->
        query

      valid_uuid?(project_id) ->
        where(query, [a], is_nil(a.project_id) or a.project_id == ^project_id)

      true ->
        where(query, [a], is_nil(a.project_id))
    end
  end

  # Deterministic, collision-free `<type>/<slug>.md` path per article.
  defp assign_paths(articles) do
    {paths, _used} =
      Enum.reduce(articles, {%{}, MapSet.new()}, fn article, {paths, used} ->
        base = "#{article.category}/#{Knowledge.slugify(article.title)}"
        unique = dedupe(base, used)
        {Map.put(paths, article.id, unique <> ".md"), MapSet.put(used, unique)}
      end)

    paths
  end

  defp dedupe(base, used) do
    if MapSet.member?(used, base), do: next_free(base, used, 2), else: base
  end

  defp next_free(base, used, n) do
    candidate = "#{base}-#{n}"
    if MapSet.member?(used, candidate), do: next_free(base, used, n + 1), else: candidate
  end

  defp build_files(articles, paths) do
    concept_files =
      Map.new(articles, fn article ->
        {Map.fetch!(paths, article.id), render_concept(article, paths)}
      end)

    grouped = Enum.group_by(articles, &to_string(&1.category))

    category_indexes =
      Map.new(grouped, fn {category, arts} ->
        {"#{category}/index.md", render_category_index(category, arts, paths)}
      end)

    concept_files
    |> Map.merge(category_indexes)
    |> Map.put("index.md", render_root_index(grouped))
    |> Map.put("log.md", render_log(articles))
  end

  defp render_concept(article, paths) do
    frontmatter = encode_frontmatter(concept_frontmatter(article))
    body = concept_body(article, paths)
    "---\n#{frontmatter}---\n\n#{body}"
  end

  defp concept_frontmatter(article) do
    okf = Map.get(article.metadata || %{}, "okf", %{})
    extra = Map.get(okf, "extra", %{})

    base = %{
      "type" => Map.get(okf, "type") || to_string(article.category),
      "title" => article.title,
      "description" => Map.get(okf, "description"),
      "resource" => Map.get(okf, "resource"),
      "tags" => Map.get(okf, "tags") || article.tags,
      "timestamp" => Map.get(okf, "timestamp") || DateTime.to_iso8601(article.updated_at),
      "loopctl_id" => article.id,
      "loopctl_category" => to_string(article.category),
      "loopctl_status" => to_string(article.status)
    }

    # Preserve foreign/unknown keys captured on import, lowest precedence.
    extra
    |> Map.merge(base)
    |> reject_empty()
  end

  # Body verbatim, plus a marked `# Related` section encoding the relates_to graph.
  defp concept_body(article, paths) do
    body = String.trim_trailing(article.body || "")

    case related_links(article, paths) do
      [] ->
        body <> "\n"

      links ->
        section = "# Related\n#{@related_marker}\n\n" <> Enum.join(links, "\n") <> "\n"
        prefix = if body == "", do: "", else: body <> "\n\n"
        prefix <> section
    end
  end

  defp related_links(article, paths) do
    (article.outgoing_links || [])
    |> Enum.map(fn link -> {link, link.target_article} end)
    |> Enum.filter(fn {_link, target} ->
      target != nil and target.status == :published and Map.has_key?(paths, target.id)
    end)
    |> Enum.map(fn {link, target} ->
      "- [#{escape_link_text(target.title)}](/#{Map.fetch!(paths, target.id)}) — #{link.relationship_type}"
    end)
  end

  defp escape_link_text(text), do: String.replace(text, "]", "\\]")

  defp render_category_index(category, articles, _paths) do
    heading = "# #{String.capitalize(category)}\n\n"

    items =
      articles
      |> Enum.sort_by(& &1.title)
      |> Enum.map_join("\n", fn article ->
        slug_path = "#{Knowledge.slugify(article.title)}.md"
        desc = derive_description(article)
        suffix = if desc == "", do: "", else: " - #{desc}"
        "* [#{article.title}](#{slug_path})#{suffix}"
      end)

    heading <> items <> "\n"
  end

  defp render_root_index(grouped) do
    front = "---\nokf_version: \"#{@okf_version}\"\n---\n\n"
    heading = "# Knowledge Bundle\n\n"

    items =
      grouped
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map_join("\n", fn category ->
        count = length(Map.fetch!(grouped, category))

        "* [#{String.capitalize(category)}](#{category}/index.md) - #{count} #{category} article(s)"
      end)

    front <> heading <> items <> "\n"
  end

  defp render_log(articles) do
    by_date =
      articles
      |> Enum.group_by(fn a -> a.updated_at |> DateTime.to_date() |> Date.to_iso8601() end)
      |> Enum.sort_by(fn {date, _} -> date end, :desc)

    body =
      Enum.map_join(by_date, "\n", fn {date, arts} ->
        entries =
          arts
          |> Enum.sort_by(& &1.title)
          |> Enum.map_join("\n", fn a ->
            "* **Update**: #{a.title} (#{a.category})"
          end)

        "## #{date}\n#{entries}"
      end)

    "# Knowledge Update Log\n\n" <> body <> "\n"
  end

  @doc """
  Derives a one-line, 160-byte-capped summary for an article.

  Public (extracted from the OKF index-file renderer, US-31.3 AC-31.3.1) so
  other progressive-disclosure surfaces (`Loopctl.Knowledge.progressive_index/3`)
  can build a compact stub without duplicating this logic. Prefers the
  round-tripped `metadata["okf"]["description"]` (set on OKF import) --
  returned AS-IS, untruncated, since it's an author-supplied one-liner, not
  body text that needs clipping -- and otherwise falls back to the first
  non-heading line of the body, truncated to 160 bytes (plus a 3-byte "…"
  suffix when truncation occurs).

  Takes anything with `:body`/`:metadata` fields (a full `%Article{}` or a bare
  projection map carrying just those two) — callers that only need the summary
  need not fetch/preload the rest of the article.
  """
  @spec derive_description(%{body: String.t() | nil, metadata: map() | nil}) :: String.t()
  def derive_description(article) do
    okf = Map.get(article.metadata || %{}, "okf", %{})

    case Map.get(okf, "description") do
      desc when is_binary(desc) and desc != "" ->
        desc

      _ ->
        article.body
        |> to_string()
        |> String.split("\n", trim: true)
        |> Enum.find("", fn line -> not String.starts_with?(String.trim(line), "#") end)
        |> String.trim()
        |> truncate(160)
    end
  end

  # Byte-bounded (not grapheme-bounded) truncation: `String.slice/3` counts
  # GRAPHEMES, so for multibyte text (accents, emoji) slicing to `max`
  # graphemes can produce a result several times larger than `max` BYTES --
  # exactly the opposite of what a byte cap promises. Walk graphemes and stop
  # accumulating the instant the NEXT one would push byte_size over `max`, so
  # the returned (pre-ellipsis) string never exceeds `max` bytes regardless of
  # encoding width.
  defp truncate(str, max) when byte_size(str) <= max, do: str

  defp truncate(str, max) do
    str
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {acc, size} ->
      new_size = size + byte_size(grapheme)

      if new_size > max do
        {:halt, {acc, size}}
      else
        {:cont, {[grapheme | acc], new_size}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
    |> Kernel.<>("…")
  end

  # ---------------------------------------------------------------------------
  # Import
  # ---------------------------------------------------------------------------

  @doc """
  Imports an OKF bundle (files map) into a tenant's wiki.

  Reserved files (`index.md`, `log.md`) are skipped. Each remaining `.md` is
  parsed as a concept and created (or, with `merge: true`, updated in place when
  an existing article matches by `loopctl_id`, or by the same title **and**
  category **and** project scope — never a merely same-titled but unrelated
  article). After concepts are upserted, the `relates_to`/`derived_from` graph is
  reconstructed from each concept's marked `# Related` section; `:supersedes`
  edges are intentionally NOT reconstructed (they would retire a target article
  as a side effect).

  Status handling: a concept's status is restored only when the bundle carries a
  `loopctl_id` producer key (a loopctl-origin bundle); foreign bundles always
  import as `:draft`, so a forged `loopctl_status` can't auto-publish content.

  Per OKF's permissive-consumer rule the import never aborts on a non-conformant
  or unknown-`type` document; per-file outcomes are returned in the report.
  Import is non-atomic (per-file); `report.partial?` is `true` if any file failed.

  ## Options

  - `:project_id` — assign imported articles to a project.
  - `:merge` (default `true`) — update existing articles instead of skipping them.
  - `:dry_run` (default `false`) — validate + plan only; write nothing.
  - `:actor_id` / `:actor_label` / `:actor_type` — audit attribution for the
    create/update/link writes.

  ## Returns

  `{:ok, report}` where report is a map with `:created`, `:updated`, `:skipped`,
  `:links_created`, `:partial?`, `:errors` (list of `%{path, reason}`), and
  `:conformance`. Returns `{:error, :too_many_concepts}` when the bundle exceeds
  #{@max_import_concepts} concepts (an import-side ceiling).

  The import is non-atomic (per-file) and runs synchronously; it is bounded by
  the concept cap above. Concurrent imports of the same bundle are serialized by
  `create_article`'s active-title conflict resolution: an identical-body race is
  absorbed idempotently (counted under `:skipped`), and a different-body title
  collision is reported (`:skipped` + an `errors` entry, `partial?: true`) — never
  a duplicate.
  """
  @spec import_files(Ecto.UUID.t(), files(), keyword()) ::
          {:ok, map()} | {:error, :too_many_concepts}
  def import_files(tenant_id, files, opts \\ []) when is_map(files) do
    merge? = Keyword.get(opts, :merge, true)
    dry_run? = Keyword.get(opts, :dry_run, false)
    project_id = Keyword.get(opts, :project_id)
    audit_opts = Keyword.take(opts, [:actor_id, :actor_label, :actor_type])

    conformance = validate_files(files)

    concepts =
      files
      |> Enum.reject(fn {path, _} -> reserved?(path) end)
      |> Enum.sort_by(fn {path, _} -> path end)

    if length(concepts) > @max_import_concepts do
      {:error, :too_many_concepts}
    else
      do_import(tenant_id, concepts, conformance, merge?, dry_run?, project_id, audit_opts)
    end
  end

  defp do_import(tenant_id, concepts, conformance, merge?, dry_run?, project_id, audit_opts) do
    initial = %{
      created: 0,
      updated: 0,
      skipped: 0,
      links_created: 0,
      errors: [],
      conformance: conformance,
      dry_run: dry_run?,
      # internal: path -> article_id (link reconstruction) and audit attribution
      path_index: %{},
      audit_opts: audit_opts
    }

    result =
      Enum.reduce(concepts, initial, fn {path, content}, acc ->
        import_concept(tenant_id, path, content, project_id, merge?, dry_run?, acc)
      end)

    result =
      if dry_run? do
        result
      else
        reconstruct_links(tenant_id, concepts, result)
      end

    # `partial?` tells callers some files failed without diffing counts.
    report = Map.put(result, :partial?, result.errors != [])
    {:ok, Map.drop(report, [:path_index, :audit_opts])}
  end

  @doc """
  Imports an OKF bundle delivered as an archive binary. Detects the archive
  format from its magic bytes — a streamed `.tar.gz` (gzip magic `1F 8B`, the
  US-27.16 export format) is extracted via `:erl_tar`; a legacy `.zip` (PK magic
  `50 4B`) via `:zip` — unpacks it in memory, then delegates to `import_files/3`.

  Keeping the `.zip` reader means a bundle produced by the OLD exporter (or any
  third-party OKF zip) still round-trips even though the exporter now emits tar.gz.
  """
  @spec import_zip(Ecto.UUID.t(), binary(), keyword()) ::
          {:ok, map()} | {:error, :invalid_zip | :too_many_concepts}
  def import_zip(tenant_id, archive_binary, opts \\ []) when is_binary(archive_binary) do
    case unpack_archive(archive_binary) do
      {:ok, files} -> import_files(tenant_id, files, opts)
      {:error, _} -> {:error, :invalid_zip}
    end
  end

  defp import_concept(tenant_id, path, content, project_id, merge?, dry_run?, acc) do
    case parse_concept(path, content) do
      {:ok, attrs} ->
        upsert_concept(tenant_id, path, attrs, project_id, merge?, dry_run?, acc)

      {:error, reason} ->
        record_error(acc, path, reason)
    end
  end

  defp upsert_concept(tenant_id, path, attrs, project_id, merge?, dry_run?, acc) do
    attrs = maybe_put_project(attrs, project_id)
    match = find_existing(tenant_id, attrs)

    cond do
      # Mirror the real create/update/skip/conflict decision so the preview is faithful.
      dry_run? -> bump(acc, dry_run_outcome(match, attrs, merge?))
      title_conflict?(match, attrs) -> record_conflict(acc, path, match)
      match && merge? -> do_update(tenant_id, path, elem(match, 1), attrs, acc)
      match -> bump(acc, :skipped)
      true -> do_create(tenant_id, path, attrs, acc)
    end
  end

  # A title-only match whose category or project scope differs from the concept
  # is NOT the same logical article — merging would clobber unrelated curated
  # content, and creating would hit the (tenant_id, title) active unique index.
  # Treat it as a reported skip instead. loopctl_id matches are our own prior
  # imports, so they never conflict.
  defp title_conflict?({:title, existing}, attrs) do
    existing.category != attrs.category or existing.project_id != attrs[:project_id]
  end

  defp title_conflict?(_match, _attrs), do: false

  defp dry_run_outcome(match, attrs, merge?) do
    cond do
      title_conflict?(match, attrs) -> :skipped
      is_nil(match) -> :created
      merge? -> :updated
      true -> :skipped
    end
  end

  defp record_conflict(acc, path, {:title, existing}) do
    record_error(
      acc,
      path,
      "title conflict: an active #{existing.category} article with this title " <>
        "already exists in a different category/project scope"
    )
  end

  defp do_create(tenant_id, path, attrs, acc) do
    case Knowledge.create_article(tenant_id, attrs, acc.audit_opts) do
      {:ok, article} ->
        acc |> bump(:created) |> index_path(path, article.id)

      # A concurrent create that resolved to an existing identical-body article —
      # a no-op; index it so link reconstruction resolves this path.
      {:ok, :deduplicated, existing} ->
        acc |> bump(:skipped) |> index_path(path, existing.id)

      # A concurrent/duplicate title with DIFFERENT content (the importer resolves
      # same-title merges up front, so this is a race or a foreign collision).
      # Report it as a conflict; do NOT index the unrelated existing article for
      # this path, which would mis-point link reconstruction.
      {:error, :duplicate_title, existing} ->
        record_error(acc, path, "title conflict with existing article #{existing.id}")

      {:error, changeset} ->
        record_error(acc, path, changeset_error(changeset))
    end
  end

  # Status is intentionally NOT updated on merge: lifecycle transitions go
  # through the publish/archive workflow, never a bulk import. Slug is
  # regenerated so a renamed (loopctl_id-matched) article keeps a valid slug.
  defp do_update(tenant_id, path, existing, attrs, acc) do
    update_attrs =
      attrs
      |> Map.take([:title, :body, :category, :tags, :metadata])
      |> put_slug(attrs[:title])

    case Knowledge.update_article(tenant_id, existing.id, update_attrs, acc.audit_opts) do
      {:ok, article} ->
        acc |> bump(:updated) |> index_path(path, article.id)

      {:error, changeset} ->
        record_error(acc, path, changeset_error(changeset))
    end
  end

  defp put_slug(attrs, nil), do: attrs
  defp put_slug(attrs, title), do: Map.put(attrs, :slug, Knowledge.slugify(title))

  # Resolve the merge target, returning `{:loopctl, article}` (an idempotent
  # re-import of a bundle we previously imported, matched by the stored
  # `loopctl_id`), `{:title, article}` (an active same-title article — the caller
  # then checks category/project scope before merging), or `nil`.
  #
  # NOTE: only the STORED `metadata["okf"]["loopctl_id"]` is matched — never a
  # raw `article.id == loopctl_id` lookup. A forged `loopctl_id` in a foreign
  # bundle therefore can't target a natively-created article (those carry no
  # stored loopctl_id), so it can't be used as an arbitrary-overwrite primitive.
  defp find_existing(tenant_id, attrs) do
    loopctl_id = get_in(attrs, [:metadata, "okf", "loopctl_id"])
    project_id = attrs[:project_id]

    case find_by_stored_loopctl_id(tenant_id, loopctl_id, project_id) do
      nil -> wrap(:title, get_active_article_by_title(tenant_id, attrs[:title]))
      article -> {:loopctl, article}
    end
  end

  defp wrap(_tag, nil), do: nil
  defp wrap(tag, article), do: {tag, article}

  defp find_by_stored_loopctl_id(_tenant_id, id, _project_id) when not is_binary(id), do: nil

  defp find_by_stored_loopctl_id(tenant_id, id, project_id) do
    from(a in Article,
      where:
        a.tenant_id == ^tenant_id and
          fragment("?->'okf'->>'loopctl_id' = ?", a.metadata, ^id),
      order_by: [asc: a.inserted_at],
      limit: 1
    )
    |> scope_project(project_id)
    |> AdminRepo.one()
  end

  # Title-only, mirroring the partial unique index (tenant_id, title) WHERE
  # status NOT IN ('archived','superseded') — this is exactly the row a create
  # would collide with. Category/project are checked by the caller.
  defp get_active_article_by_title(_tenant_id, nil), do: nil

  defp get_active_article_by_title(tenant_id, title) do
    AdminRepo.one(
      from(a in Article,
        where:
          a.tenant_id == ^tenant_id and a.title == ^title and
            a.status not in [:archived, :superseded],
        order_by: [asc: a.inserted_at],
        limit: 1
      )
    )
  end

  defp scope_project(query, nil), do: where(query, [a], is_nil(a.project_id))

  # Guard the :binary_id cast for the import loopctl_id lookup: a non-UUID
  # top-level project_id would CastError-500 on `== ^project_id`. A malformed
  # value matches nothing (no article belongs to a bogus project).
  defp scope_project(query, project_id) do
    if valid_uuid?(project_id) do
      where(query, [a], a.project_id == ^project_id)
    else
      where(query, [a], false)
    end
  end

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_uuid?(_), do: false

  # Parse one concept file into create_article attrs.
  defp parse_concept(path, content) do
    with {:ok, %{frontmatter: fm, body: raw_body}} <- parse_frontmatter(content),
         {:ok, type} <- fetch_type(fm) do
      {body, _related} = split_related(raw_body)
      title = concept_title(fm, path)
      raw_tags = parse_tags(fm)
      tags = sanitize_tags(raw_tags)

      {:ok,
       %{
         title: title,
         body: ensure_body(body, title, fm),
         category: category_for(fm, type),
         status: status_for(fm),
         tags: tags,
         metadata: %{"okf" => build_okf_metadata(fm, type, raw_tags, tags)}
       }}
    end
  end

  # loopctl tags must match ~r/\A[a-zA-Z0-9_-]+\z/ (<=50 tags, <=100 chars). OKF
  # tags are free strings, so sanitize foreign tags to fit; the originals are
  # preserved under metadata["okf"]["tags"] for lossless re-export.
  #
  # A foreign tag can sanitize INTO the reserved idempotency namespace (#583) —
  # "idem url 7ebe1ca33431" becomes "idem-url-7ebe1ca33431". Those are DROPPED:
  # an imported document must never GAIN a capture identity it did not write,
  # and this path coerces rather than fails (a whole import must not die on one
  # foreign tag). The drop is lossless — the original string is retained under
  # metadata["okf"]["tags"].
  #
  # The discriminator is whether sanitizing CHANGED the string, not whether the
  # result is reserved. A well-formed reserved tag that arrives byte-identical
  # is a capture identity the bundle already carries — that is every
  # loopctl-native bundle, whose frontmatter is this system's own tags — and
  # dropping it deleted the identity on cross-tenant import and, on the merge
  # path, off the LIVE row (do_update/5 replaces the whole tags array). The
  # "captured already?" query then missed and the corpus was re-extracted:
  # precisely the failure the reservation exists to prevent.
  defp sanitize_tags(tags) do
    tags
    |> Enum.map(fn tag -> {tag, sanitize_tag(tag)} end)
    |> Enum.reject(fn {raw, sanitized} -> drop_tag?(raw, sanitized) end)
    |> Enum.map(fn {_raw, sanitized} -> sanitized end)
    |> Enum.uniq()
    |> Enum.take(20)
  end

  defp drop_tag?(_raw, ""), do: true

  defp drop_tag?(raw, sanitized) do
    IdempotencyTag.reserved?(sanitized) and
      (raw != sanitized or not IdempotencyTag.well_formed?(sanitized))
  end

  defp sanitize_tag(tag) when is_binary(tag) do
    tag
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 100)
  end

  defp sanitize_tag(_), do: ""

  # ALL imported articles are created as drafts and never have their status
  # changed by an import — publication and lifecycle transitions go through the
  # explicit publish/archive workflow. A bundle's `loopctl_status` is therefore
  # advisory only: it can neither auto-publish unreviewed content nor demote a
  # curated article, regardless of forged producer keys.
  defp status_for(_fm), do: :draft

  defp fetch_type(fm) do
    case Map.get(fm, "type") do
      type when is_binary(type) and type != "" -> {:ok, type}
      _ -> {:error, :missing_type}
    end
  end

  # Titles that hundreds of unrelated documents all produce. A bundle carrying a bare
  # `CHANGELOG.md` with no frontmatter title used to import as the article "Changelog", and
  # three such documents then collided into a false duplicate group on the hosted corpus —
  # the class #617 traced back to title minting. The REST ingestion path was fixed by
  # showing its extractor the source; this importer derives titles itself, so it qualifies
  # them itself. Matched on the NORMALIZED derived title, so "change-log" and "CHANGELOG"
  # are both caught.
  #
  # Deliberately NOT `Consolidation.generic_title_pattern/0`: that one matches PLACEHOLDER
  # titles ("Untitled", "Draft") and is owned by a different proposal class. These are
  # perfectly good document names that are merely not unique.
  @generic_concept_titles ~w(
    changelog readme license contributing installation configuration
    overview index introduction usage reference api getting started
    quickstart quick start faq notes todo roadmap security upgrading
  )

  defp concept_title(fm, path) do
    case Map.get(fm, "title") do
      title when is_binary(title) and title != "" ->
        title

      _ ->
        path |> derived_title() |> qualify_generic(path)
    end
    |> String.slice(0, 500)
  end

  # Derive from the concept id (filename minus .md), de-slugified.
  defp derived_title(path) do
    path
    |> Path.basename(".md")
    |> String.replace(["-", "_"], " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # Qualify with the nearest enclosing directory, which in an OKF bundle names the concept
  # group the file belongs to. No directory (a file at the bundle root) means there is
  # nothing honest to qualify WITH, so the bare title stands rather than being padded with
  # an invented source — the same rule the extraction prompt follows.
  defp qualify_generic(title, path) do
    if String.downcase(title) in @generic_concept_titles do
      case qualifier(path) do
        nil -> title
        source -> "#{title} — #{source}"
      end
    else
      title
    end
  end

  defp qualifier(path) do
    case path |> Path.dirname() |> Path.basename() do
      dir when dir in [".", "/", "", "concepts"] -> nil
      dir -> dir |> String.replace(["-", "_"], " ") |> String.trim()
    end
  end

  defp category_for(fm, type) do
    cond do
      cat = valid_category(Map.get(fm, "loopctl_category")) -> cat
      cat = valid_category(type) -> cat
      true -> :reference
    end
  end

  defp valid_category(value) when is_binary(value) do
    down = String.downcase(value)
    if down in @category_strings, do: String.to_existing_atom(down), else: nil
  end

  defp valid_category(_), do: nil

  defp parse_tags(fm) do
    case Map.get(fm, "tags") do
      tags when is_list(tags) -> tags |> Enum.filter(&is_binary/1) |> Enum.take(50)
      tag when is_binary(tag) and tag != "" -> [tag]
      _ -> []
    end
  end

  # Capture original type + every non-loopctl, non-core key for lossless round-trip.
  defp build_okf_metadata(fm, type, raw_tags, sanitized_tags) do
    extra =
      fm
      |> Map.drop(@reserved_fm_keys)
      |> Map.new()

    %{"type" => type}
    |> maybe_put_string("description", Map.get(fm, "description"))
    |> maybe_put_string("resource", Map.get(fm, "resource"))
    |> maybe_put_string("timestamp", Map.get(fm, "timestamp"))
    # Stash the source loopctl_id so a re-import resolves the same row by identity
    # (it is NOT re-emitted on export, which always uses the live article.id).
    |> maybe_put_string("loopctl_id", Map.get(fm, "loopctl_id"))
    |> maybe_put_original_tags(raw_tags, sanitized_tags)
    |> put_extra(extra)
  end

  # Only stash originals when sanitizing actually changed them, so native loopctl
  # round-trips stay free of redundant metadata.
  defp maybe_put_original_tags(map, raw, sanitized) when raw != [] and raw != sanitized,
    do: Map.put(map, "tags", raw)

  defp maybe_put_original_tags(map, _raw, _sanitized), do: map

  defp put_extra(map, extra) when map_size(extra) == 0, do: map
  defp put_extra(map, extra), do: Map.put(map, "extra", extra)

  defp maybe_put_string(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put_string(map, key, value) when is_binary(value), do: Map.put(map, key, value)
  defp maybe_put_string(map, _key, _value), do: map

  defp ensure_body(body, title, fm) do
    trimmed = String.trim(body)

    cond do
      trimmed != "" ->
        body

      is_binary(Map.get(fm, "description")) and Map.get(fm, "description") != "" ->
        fm["description"]

      true ->
        title
    end
    |> String.slice(0, 100_000)
  end

  defp maybe_put_project(attrs, nil), do: attrs
  defp maybe_put_project(attrs, project_id), do: Map.put(attrs, :project_id, project_id)

  # --- relates_to reconstruction (second pass) ---

  defp reconstruct_links(tenant_id, concepts, %{path_index: index} = acc) do
    Enum.reduce(concepts, acc, fn {path, content}, acc ->
      with source_id when is_binary(source_id) <- Map.get(index, path),
           {:ok, %{body: body}} <- parse_frontmatter(content) do
        {_body, related} = split_related(body)
        create_related_links(tenant_id, source_id, related, index, acc)
      else
        _ -> acc
      end
    end)
  end

  # Relationship types that are safe to reconstruct on import. `:supersedes`
  # (and `:contradicts`) are deliberately excluded: re-creating a `:supersedes`
  # edge would flip a curated target article to `:superseded` as a side effect
  # (Knowledge.create_link -> maybe_supersede_target), an unadvertised
  # destructive mutation. The relates_to/derived_from graph round-trips; lifecycle
  # transitions do not.
  @reconstructable_rel_types [:relates_to, :derived_from]

  defp create_related_links(tenant_id, source_id, related, index, acc) do
    Enum.reduce(related, acc, fn {target_path, rel_type}, acc ->
      target_id = Map.get(index, normalize_bundle_path(target_path))

      cond do
        rel_type not in @reconstructable_rel_types -> acc
        is_nil(target_id) -> acc
        target_id == source_id -> acc
        true -> maybe_create_link(tenant_id, source_id, target_id, rel_type, acc)
      end
    end)
  end

  # Idempotent: a matching edge may already exist (a prior import, or loopctl's
  # automatic similarity-based `relates_to` linker), in which case the
  # relationship is already satisfied and we neither error nor re-count it.
  defp maybe_create_link(tenant_id, source_id, target_id, rel_type, acc) do
    if link_exists?(tenant_id, source_id, target_id, rel_type) do
      acc
    else
      attrs = %{
        source_article_id: source_id,
        target_article_id: target_id,
        relationship_type: rel_type
      }

      case Knowledge.create_link(tenant_id, attrs, Map.get(acc, :audit_opts, [])) do
        {:ok, _} -> bump(acc, :links_created)
        {:error, _} -> acc
      end
    end
  end

  defp link_exists?(tenant_id, source_id, target_id, rel_type) do
    AdminRepo.exists?(
      from(l in ArticleLink,
        where:
          l.tenant_id == ^tenant_id and l.source_article_id == ^source_id and
            l.target_article_id == ^target_id and l.relationship_type == ^rel_type
      )
    )
  end

  # Splits the marked `# Related` section off a body, returning {body, links}
  # where links is a list of {target_path, relationship_type}.
  defp split_related(body) do
    case String.split(body, "# Related\n#{@related_marker}", parts: 2) do
      [before, after_section] ->
        {String.trim_trailing(before), parse_related(after_section)}

      [_] ->
        {body, []}
    end
  end

  defp parse_related(section) do
    ~r/^\s*-\s*\[[^\]]*\]\(([^)]+)\)\s*(?:—\s*(\w+))?/mu
    |> Regex.scan(section)
    |> Enum.map(fn
      [_, target, rel] -> {target, parse_rel_type(rel)}
      [_, target] -> {target, :relates_to}
    end)
  end

  @rel_types ~w(relates_to derived_from contradicts supersedes)
  defp parse_rel_type(rel) when rel in @rel_types, do: String.to_existing_atom(rel)
  defp parse_rel_type(_), do: :relates_to

  defp normalize_bundle_path("/" <> rest), do: rest
  defp normalize_bundle_path("./" <> rest), do: rest
  defp normalize_bundle_path(path), do: path

  # ---------------------------------------------------------------------------
  # Validation (OKF §9 conformance)
  # ---------------------------------------------------------------------------

  @doc """
  Checks a files map against OKF v0.1 conformance (spec §9):

  1. every non-reserved `.md` has a parseable frontmatter block, and
  2. every such block has a non-empty `type`.

  Reserved-file structure (§6/§7) is checked as soft `warnings` only, since
  consumers must not reject on it. Returns
  `%{conformant: boolean, concept_count: n, errors: [...], warnings: [...]}`.
  """
  @spec validate_files(files()) :: %{
          conformant: boolean(),
          concept_count: non_neg_integer(),
          errors: [map()],
          warnings: [map()]
        }
  def validate_files(files) when is_map(files) do
    {errors, warnings, concept_count} =
      Enum.reduce(files, {[], [], 0}, fn {path, content}, acc ->
        classify_validation(path, content, acc)
      end)

    %{
      conformant: errors == [],
      concept_count: concept_count,
      errors: Enum.reverse(errors),
      warnings: Enum.reverse(warnings)
    }
  end

  defp classify_validation(path, content, {errs, warns, count}) do
    cond do
      not String.ends_with?(path, ".md") ->
        {errs, [%{path: path, message: "non-markdown file ignored"} | warns], count}

      reserved?(path) ->
        {errs, validate_reserved(path, content) ++ warns, count}

      true ->
        score_concept(path, content, errs, warns, count)
    end
  end

  defp score_concept(path, content, errs, warns, count) do
    case validate_concept(path, content) do
      :ok -> {errs, warns, count + 1}
      {:error, msg} -> {[%{path: path, message: msg} | errs], warns, count + 1}
    end
  end

  defp validate_concept(_path, content) do
    case parse_frontmatter(content) do
      {:ok, %{frontmatter: fm}} ->
        case fetch_type(fm) do
          {:ok, _} -> :ok
          {:error, :missing_type} -> {:error, "frontmatter missing non-empty `type`"}
        end

      {:error, :no_frontmatter} ->
        {:error, "missing YAML frontmatter block"}

      {:error, _} ->
        {:error, "unparseable YAML frontmatter"}
    end
  end

  defp validate_reserved(path, content) do
    if Path.basename(path) == "index.md" and path != "index.md" and has_frontmatter?(content) do
      [%{path: path, message: "non-root index.md should not carry frontmatter"}]
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Frontmatter codec
  # ---------------------------------------------------------------------------

  @doc """
  Parses a concept document into its frontmatter map and body.

  Returns `{:ok, %{frontmatter: map, body: binary}}` or
  `{:error, :no_frontmatter | :frontmatter_not_map | :invalid_yaml}`.
  """
  @spec parse_frontmatter(String.t()) ::
          {:ok, %{frontmatter: map(), body: String.t()}}
          | {:error, :no_frontmatter | :frontmatter_not_map | :invalid_yaml}
  def parse_frontmatter(content) when is_binary(content) do
    normalized = String.replace(content, "\r\n", "\n")

    case Regex.run(~r/\A---\n(.*?)\n---[ \t]*\n?(.*)\z/s, normalized) do
      [_, yaml, body] ->
        decode_yaml(yaml, body)

      _ ->
        {:error, :no_frontmatter}
    end
  end

  defp decode_yaml(yaml, body) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) -> {:ok, %{frontmatter: map, body: body}}
      {:ok, nil} -> {:ok, %{frontmatter: %{}, body: body}}
      {:ok, _other} -> {:error, :frontmatter_not_map}
      {:error, _} -> {:error, :invalid_yaml}
    end
  end

  @doc """
  Encodes a string-keyed map as a YAML frontmatter block (without the `---`
  fences). Keys are emitted in a stable order: known OKF keys first, then the
  rest sorted, so output is deterministic and round-trips through
  `parse_frontmatter/1`.
  """
  @spec encode_frontmatter(map()) :: String.t()
  def encode_frontmatter(map) when is_map(map) do
    ordered_keys =
      Enum.filter(@reserved_fm_keys, &Map.has_key?(map, &1)) ++
        (map |> Map.keys() |> Enum.reject(&(&1 in @reserved_fm_keys)) |> Enum.sort())

    Enum.map_join(ordered_keys, fn key -> encode_kv(key, Map.fetch!(map, key), 0) end)
  end

  defp encode_kv(key, value, indent) when is_list(value) do
    pad = String.duplicate("  ", indent)

    if value == [] do
      "#{pad}#{key}: []\n"
    else
      items = Enum.map_join(value, fn item -> "#{pad}- #{yaml_scalar(item)}\n" end)
      "#{pad}#{key}:\n#{items}"
    end
  end

  defp encode_kv(key, value, indent) when is_map(value) do
    pad = String.duplicate("  ", indent)

    if map_size(value) == 0 do
      "#{pad}#{key}: {}\n"
    else
      nested =
        value
        |> Enum.sort_by(fn {k, _} -> to_string(k) end)
        |> Enum.map_join(fn {k, v} -> encode_kv(to_string(k), v, indent + 1) end)

      "#{pad}#{key}:\n#{nested}"
    end
  end

  defp encode_kv(key, value, indent) do
    pad = String.duplicate("  ", indent)
    "#{pad}#{key}: #{yaml_scalar(value)}\n"
  end

  defp yaml_scalar(value) when is_binary(value) do
    if needs_quote?(value), do: ~s("#{escape_yaml(value)}"), else: value
  end

  defp yaml_scalar(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp yaml_scalar(true), do: "true"
  defp yaml_scalar(false), do: "false"
  defp yaml_scalar(nil), do: "null"
  defp yaml_scalar(value), do: ~s("#{escape_yaml(to_string(value))}")

  defp needs_quote?(""), do: true
  defp needs_quote?(str), do: String.contains?(str, "\n") or not safe_bare?(str)

  # Definitive ambiguity check: a bare scalar is safe only if YAML parses it back
  # to the IDENTICAL string. This catches every special-token class at once —
  # numbers, bools, null, YAML-1.1 specials (.inf/.nan/0x1F/octal), dates,
  # leading block/flow indicators (`- `, `? `, `---`), and embedded `: `/`#` —
  # without trying to enumerate them by hand.
  defp safe_bare?(str) do
    match?({:ok, ^str}, YamlElixir.read_from_string(str))
  rescue
    _ -> false
  end

  defp escape_yaml(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  defp reserved?(path) do
    Path.basename(path) in ["index.md", "log.md"]
  end

  defp has_frontmatter?(content) do
    content |> String.replace("\r\n", "\n") |> String.starts_with?("---\n")
  end

  defp reject_empty(map) do
    map
    |> Enum.reject(fn {_k, v} -> v in [nil, "", []] end)
    |> Map.new()
  end

  # Defense-in-depth caps for `import_zip/3`. These BOUND a decompression bomb (#3):
  # the tar.gz path stream-inflates with a running byte budget (aborts mid-bomb,
  # never materializing it), and BOTH paths reject an over-large COMPRESSED input up
  # front and enforce a total uncompressed-entry cap. So a 1KB→10GB bomb is rejected
  # before it can OOM the node — not "fully inflated then checked".
  @max_zip_entries 20_000
  @max_zip_bytes 50 * 1024 * 1024

  # Dispatch on the archive's magic bytes: gzip (`1F 8B`, the US-27.16 streamed
  # `.tar.gz`) → bounded streaming inflate; PK (`50 4B`, a legacy `.zip`) → `:zip`
  # behind a compressed-input cap. Both feed the same entry-collector (size/count caps).
  defp unpack_archive(<<0x1F, 0x8B, _rest::binary>> = bin), do: untar_gz(bin)
  defp unpack_archive(<<0x50, 0x4B, _rest::binary>> = bin), do: unzip(bin)
  # Unknown magic: try zip first (back-compat), then tar.gz, before giving up.
  defp unpack_archive(bin) do
    case unzip(bin) do
      {:ok, _} = ok -> ok
      {:error, _} -> untar_gz(bin)
    end
  end

  defp untar_gz(bin) do
    # AC-27.16.3 (#3): decompression-limited extraction — compressed-input cap +
    # streaming inflate with an uncompressed byte budget — so a gzip bomb aborts
    # mid-decompression instead of fully inflating to gigabytes.
    case DecompressionLimit.extract_tar_gz(bin) do
      {:ok, entries} -> collect_archive_entries(entries)
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :invalid_archive}
  end

  defp unzip(zip_binary) do
    # `:zip.extract([:memory])` has no streaming budget (it inflates fully), so the
    # bomb defense for the zip path is the COMPRESSED-input cap up front (#3) plus the
    # per-entry total-uncompressed cap in collect_archive_entries/1.
    with :ok <- DecompressionLimit.guard_compressed_size(zip_binary),
         {:ok, entries} <- safe_zip_extract(zip_binary) do
      collect_archive_entries(entries)
    end
  end

  defp safe_zip_extract(zip_binary) do
    case :zip.extract(zip_binary, [:memory]) do
      {:ok, entries} -> {:ok, entries}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :invalid_archive}
  end

  defp collect_archive_entries(entries) when length(entries) > @max_zip_entries,
    do: {:error, :too_many_entries}

  defp collect_archive_entries(entries) do
    total = Enum.reduce(entries, 0, fn {_name, content}, acc -> acc + byte_size(content) end)

    if total > @max_zip_bytes do
      {:error, :bundle_too_large}
    else
      {:ok, Map.new(entries, fn {name, content} -> {to_string(name), content} end)}
    end
  end

  defp bump(acc, key), do: Map.update!(acc, key, &(&1 + 1))

  defp record_error(acc, path, reason) do
    acc
    |> bump(:skipped)
    |> Map.update!(:errors, &[%{path: path, reason: to_string_reason(reason)} | &1])
  end

  defp index_path(acc, path, article_id) do
    Map.update!(acc, :path_index, &Map.put(&1, path, article_id))
  end

  defp to_string_reason(reason) when is_binary(reason), do: reason
  defp to_string_reason(reason) when is_atom(reason), do: to_string(reason)

  defp changeset_error(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string_safe(v))
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end

  defp to_string_safe(v) when is_binary(v), do: v
  defp to_string_safe(v), do: inspect(v)
end
