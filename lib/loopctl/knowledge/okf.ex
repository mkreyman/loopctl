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
  section, so a loopctl-origin bundle re-imports losslessly. Foreign bundles
  (no `loopctl_*` keys) import permissively: unknown frontmatter keys are
  preserved under `metadata["okf"]`, unknown `type` values fall back to the
  `reference` category, and bodies are stored verbatim — per the OKF §9
  permissive-consumer rule, a bundle is never rejected for unknown types/keys.

  The public surface works on a **files map** (`%{"path/to.md" => "content"}`)
  so the HTTP/MCP layers can choose zip or JSON transport without this module
  caring.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink

  @okf_version "0.1"

  # Mirror knowledge/export's egress guard so a bundle can't balloon unbounded.
  @max_articles 5_000

  @categories Ecto.Enum.values(Article, :category)
  @category_strings Enum.map(@categories, &to_string/1)

  # Frontmatter keys this module owns; everything else is preserved verbatim.
  @reserved_fm_keys ~w(type title description resource tags timestamp
                       loopctl_id loopctl_category loopctl_status loopctl_links)

  @related_marker "<!-- okf:related -->"

  @typedoc "A bundle as an in-memory map of POSIX path -> file contents."
  @type files :: %{optional(String.t()) => String.t()}

  # ---------------------------------------------------------------------------
  # Export
  # ---------------------------------------------------------------------------

  @doc """
  Builds an OKF bundle (files map) from a tenant's published articles.

  ## Options

  - `:project_id` — when set, includes tenant-wide (nil project) + project articles.

  ## Returns

  - `{:ok, %{files: files, meta: map}}`
  - `{:error, :payload_too_large}` when the article count exceeds #{@max_articles}.
  """
  @spec build_bundle(Ecto.UUID.t(), keyword()) ::
          {:ok, %{files: files(), meta: map()}} | {:error, :payload_too_large}
  def build_bundle(tenant_id, opts \\ []) do
    project_id = Keyword.get(opts, :project_id)

    if count_published(tenant_id, project_id) > @max_articles do
      {:error, :payload_too_large}
    else
      articles = fetch_published(tenant_id, project_id)
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

  @doc """
  Convenience wrapper: build a bundle and return it as a zip binary.
  """
  @spec export_zip(Ecto.UUID.t(), keyword()) :: {:ok, binary()} | {:error, :payload_too_large}
  def export_zip(tenant_id, opts \\ []) do
    with {:ok, %{files: files}} <- build_bundle(tenant_id, opts) do
      {:ok, to_zip(files)}
    end
  end

  @doc "Encodes a files map as an in-memory zip archive."
  @spec to_zip(files()) :: binary()
  def to_zip(files) do
    entries =
      files
      |> Enum.sort_by(fn {path, _} -> path end)
      |> Enum.map(fn {path, content} -> {String.to_charlist(path), content} end)

    {:ok, {_name, zip}} = :zip.create(~c"okf-bundle.zip", entries, [:memory])
    zip
  end

  defp count_published(tenant_id, project_id) do
    tenant_id |> export_query(project_id) |> AdminRepo.aggregate(:count, :id)
  end

  defp fetch_published(tenant_id, project_id) do
    tenant_id
    |> export_query(project_id)
    |> preload(outgoing_links: :target_article)
    |> order_by([a], asc: a.category, asc: a.title, asc: a.id)
    |> AdminRepo.all()
  end

  defp export_query(tenant_id, project_id) do
    query = from(a in Article, where: a.tenant_id == ^tenant_id and a.status == :published)

    if project_id do
      where(query, [a], is_nil(a.project_id) or a.project_id == ^project_id)
    else
      query
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

  defp derive_description(article) do
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

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max) <> "…"

  # ---------------------------------------------------------------------------
  # Import
  # ---------------------------------------------------------------------------

  @doc """
  Imports an OKF bundle (files map) into a tenant's wiki.

  Reserved files (`index.md`, `log.md`) are skipped. Each remaining `.md` is
  parsed as a concept and created (or, with `merge: true`, updated in place when
  an existing article matches by `loopctl_id` or title). After concepts are
  upserted, the `relates_to` graph is reconstructed from each concept's marked
  `# Related` section.

  Per OKF's permissive-consumer rule the import never aborts on a non-conformant
  or unknown-`type` document; per-file outcomes are returned in the report.

  ## Options

  - `:project_id` — assign imported articles to a project.
  - `:merge` (default `true`) — update existing articles instead of skipping them.
  - `:dry_run` (default `false`) — validate + plan only; write nothing.

  ## Returns

  `{:ok, report}` where report is a map with `:created`, `:updated`, `:skipped`,
  `:links_created`, `:errors` (list of `%{path, reason}`), and `:conformance`.
  """
  @spec import_files(Ecto.UUID.t(), files(), keyword()) :: {:ok, map()}
  def import_files(tenant_id, files, opts \\ []) when is_map(files) do
    merge? = Keyword.get(opts, :merge, true)
    dry_run? = Keyword.get(opts, :dry_run, false)
    project_id = Keyword.get(opts, :project_id)

    conformance = validate_files(files)

    concepts =
      files
      |> Enum.reject(fn {path, _} -> reserved?(path) end)
      |> Enum.sort_by(fn {path, _} -> path end)

    initial = %{
      created: 0,
      updated: 0,
      skipped: 0,
      links_created: 0,
      errors: [],
      conformance: conformance,
      dry_run: dry_run?,
      # internal: path -> article_id, for link reconstruction
      path_index: %{}
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

    {:ok, Map.delete(result, :path_index)}
  end

  @doc """
  Imports an OKF bundle delivered as a zip binary. Unzips in memory, then
  delegates to `import_files/3`.
  """
  @spec import_zip(Ecto.UUID.t(), binary(), keyword()) :: {:ok, map()} | {:error, :invalid_zip}
  def import_zip(tenant_id, zip_binary, opts \\ []) when is_binary(zip_binary) do
    case unzip(zip_binary) do
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
    existing = find_existing(tenant_id, attrs)

    cond do
      dry_run? ->
        bump(acc, if(existing, do: :updated, else: :created))

      existing && merge? ->
        do_update(tenant_id, path, existing, attrs, acc)

      existing ->
        bump(acc, :skipped)

      true ->
        do_create(tenant_id, path, attrs, acc)
    end
  end

  defp do_create(tenant_id, path, attrs, acc) do
    case Knowledge.create_article(tenant_id, attrs) do
      {:ok, article} ->
        acc |> bump(:created) |> index_path(path, article.id)

      {:error, changeset} ->
        record_error(acc, path, changeset_error(changeset))
    end
  end

  defp do_update(tenant_id, path, existing, attrs, acc) do
    update_attrs = Map.take(attrs, [:title, :body, :category, :tags, :metadata])

    case Knowledge.update_article(tenant_id, existing.id, update_attrs) do
      {:ok, article} ->
        acc |> bump(:updated) |> index_path(path, article.id)

      {:error, changeset} ->
        record_error(acc, path, changeset_error(changeset))
    end
  end

  # Resolve an existing article by loopctl_id first, then by (active) title.
  defp find_existing(tenant_id, attrs) do
    by_id =
      case get_in(attrs, [:metadata, "okf", "loopctl_id"]) do
        id when is_binary(id) -> get_article(tenant_id, id)
        _ -> nil
      end

    by_id || get_active_article_by_title(tenant_id, attrs[:title])
  end

  defp get_article(tenant_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> AdminRepo.get_by(Article, id: uuid, tenant_id: tenant_id)
      :error -> nil
    end
  end

  defp get_active_article_by_title(_tenant_id, nil), do: nil

  # Match the partial unique index (tenant_id, title) WHERE status NOT IN
  # ('archived', 'superseded'): that is exactly the row a create would collide
  # with, so it is the right merge target.
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

  # loopctl tags must match ~r/^[a-zA-Z0-9_-]+$/ (<=20 tags, <=100 chars). OKF
  # tags are free strings, so sanitize foreign tags to fit; the originals are
  # preserved under metadata["okf"]["tags"] for lossless re-export.
  defp sanitize_tags(tags) do
    tags
    |> Enum.map(&sanitize_tag/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(20)
  end

  defp sanitize_tag(tag) when is_binary(tag) do
    tag
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 100)
  end

  defp sanitize_tag(_), do: ""

  # loopctl-origin bundles restore their original status; foreign bundles import
  # as drafts so unvetted external knowledge isn't auto-published.
  @import_statuses ~w(draft published archived superseded)
  defp status_for(fm) do
    case Map.get(fm, "loopctl_status") do
      s when s in @import_statuses -> String.to_existing_atom(s)
      _ -> :draft
    end
  end

  defp fetch_type(fm) do
    case Map.get(fm, "type") do
      type when is_binary(type) and type != "" -> {:ok, type}
      _ -> {:error, :missing_type}
    end
  end

  defp concept_title(fm, path) do
    case Map.get(fm, "title") do
      title when is_binary(title) and title != "" ->
        title

      _ ->
        # Derive from the concept id (filename minus .md), de-slugified.
        path
        |> Path.basename(".md")
        |> String.replace(["-", "_"], " ")
        |> String.split()
        |> Enum.map_join(" ", &String.capitalize/1)
    end
    |> String.slice(0, 500)
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

  defp create_related_links(tenant_id, source_id, related, index, acc) do
    Enum.reduce(related, acc, fn {target_path, rel_type}, acc ->
      case Map.get(index, normalize_bundle_path(target_path)) do
        nil ->
          acc

        target_id when target_id == source_id ->
          acc

        target_id ->
          maybe_create_link(tenant_id, source_id, target_id, rel_type, acc)
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

      case Knowledge.create_link(tenant_id, attrs) do
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

  defp needs_quote?(str) do
    String.contains?(str, [
      ":",
      "#",
      "\"",
      "'",
      "\n",
      "[",
      "]",
      "{",
      "}",
      ",",
      "&",
      "*",
      "!",
      "|",
      ">",
      "%",
      "@",
      "`"
    ]) or
      str != String.trim(str) or
      looks_scalarish?(str)
  end

  defp looks_scalarish?(str) do
    down = String.downcase(str)

    down in ~w(true false null yes no ~) or match?({_, ""}, Integer.parse(str)) or
      match?({_, ""}, Float.parse(str))
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

  defp unzip(zip_binary) do
    case :zip.extract(zip_binary, [:memory]) do
      {:ok, entries} ->
        files =
          Map.new(entries, fn {name, content} ->
            {to_string(name), content}
          end)

        {:ok, files}

      {:error, reason} ->
        {:error, reason}
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
