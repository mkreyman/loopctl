defmodule LoopctlWeb.OKFController do
  @moduledoc """
  OKF (Open Knowledge Format) interchange endpoints.

  - `GET  /api/v1/knowledge/okf/export` — export the wiki as an OKF bundle.
  - `GET  /api/v1/projects/:project_id/knowledge/okf/export` — project-scoped export.
  - `POST /api/v1/knowledge/okf/import` — import an OKF bundle (files map).

  Export defaults to a `application/zip` archive; pass `?format=json` to get the
  bundle as a `%{files: %{path => content}, meta: ...}` JSON payload (convenient
  for tooling that writes the files out itself).

  Both routes require `role: :user`: export is a bulk knowledge egress (matching
  the Obsidian export), and import bulk-creates/updates articles — a mutation
  powerful enough to clobber curated content, so it stays above the orchestrator
  tier per the trust model in `CLAUDE.md`.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge.OKF
  alias Loopctl.Knowledge.StreamingExport.OKFFormat
  alias LoopctlWeb.Helpers.ProjectId

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :user

  tags(["Knowledge Wiki"])

  # Defensive caps so a hostile/huge import can't exhaust memory before the
  # per-article work even starts.
  @max_import_files 10_000
  @max_import_bytes 50 * 1024 * 1024

  operation(:export,
    summary: "Export knowledge as an OKF bundle (streamed .tar.gz)",
    description:
      "Exports published articles as an OKF v0.1 bundle. Defaults to a streamed " <>
        "gzipped tar archive (bounded memory, no article-count cap, fail-closed on " <>
        "mid-stream error); pass format=json for a `{files, meta}` JSON payload " <>
        "(buffered in memory — for tooling that writes the files itself — and so " <>
        "capped at export_max_buffered_export_articles, 413 over it). Each concept's " <>
        "`# Related` list is capped at export_max_links_per_article (default 100) per " <>
        "direction; a capped concept carries `loopctl_links_truncated: true` in " <>
        "frontmatter. When called via GET /projects/:project_id/knowledge/okf/export, " <>
        "includes tenant-wide + project articles. Role: user+.",
    parameters: [
      project_id: [in: :path, type: :string, required: false],
      format: [
        in: :query,
        type: :string,
        description: "tar.gz (default) or json",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"OKF bundle (.tar.gz, chunked)", "application/gzip",
         %OpenApiSpex.Schema{type: :string, format: :binary}},
      413 =>
        {"format=json bundle exceeds the buffered-export cap (use the streamed .tar.gz)",
         "application/json", Schemas.ErrorResponse},
      429 => {"Too many concurrent exports", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/okf/export"
  def export(conn, %{"format" => "json"} = params) do
    # The JSON convenience path is a BUFFERED, in-memory opt-in for tooling that
    # writes the files out itself. Because it materializes the whole bundle, it
    # keeps an article-count cap so a large KB can't OOM the node; over the cap it
    # 413s and points callers to the bounded-memory streamed `.tar.gz` (the backup
    # path, which has NO count cap).
    tenant_id = conn.assigns.current_api_key.tenant_id

    with :ok <- ProjectId.validate(params["project_id"]) do
      export_json(conn, tenant_id, params)
    end
  end

  def export(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    # Validate BEFORE streaming: send_chunked commits a 200 with no way back to an
    # error status, so a malformed project_id must be rejected up front.
    with :ok <- ProjectId.validate(params["project_id"]) do
      LoopctlWeb.StreamingExport.stream(
        conn,
        tenant_id,
        OKFFormat,
        "okf-bundle",
        export_opts(params)
      )
    end
  end

  defp export_json(conn, tenant_id, params) do
    case OKF.build_bundle(tenant_id, export_opts(params)) do
      {:ok, %{files: files, meta: meta}} ->
        json(conn, %{data: %{files: files, meta: meta}})

      {:error, :payload_too_large} ->
        conn
        |> put_status(413)
        |> json(%{
          error: %{
            status: 413,
            code: "payload_too_large",
            message:
              "format=json buffers the whole bundle in memory and is capped. " <>
                "Drop format=json to stream the full export as a bounded-memory " <>
                ".tar.gz (no article-count cap), or scope with a project_id."
          }
        })
    end
  end

  operation(:import,
    summary: "Import an OKF bundle",
    description:
      "Imports an OKF v0.1 bundle supplied as a `files` map (path => contents). " <>
        "Reserved files (index.md/log.md) are skipped; each concept is created, or " <>
        "(with merge=true, the default) updated in place when it matches an existing " <>
        "article by loopctl_id or title. Per OKF's permissive-consumer rule the " <>
        "import never aborts on unknown types/keys — per-file outcomes are reported. " <>
        "Role: user+.",
    request_body:
      {"OKF import request", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:files],
         properties: %{
           files: %OpenApiSpex.Schema{
             type: :object,
             description: "Map of bundle-relative path => file contents"
           },
           project_id: %OpenApiSpex.Schema{type: :string},
           merge: %OpenApiSpex.Schema{type: :boolean, description: "default true"},
           dry_run: %OpenApiSpex.Schema{type: :boolean, description: "default false"}
         }
       }},
    responses: %{
      200 =>
        {"Import report", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :object,
               description:
                 "Report with created/updated/skipped/links_created counts, errors, and conformance"
             }
           }
         }},
      400 => {"Bad request", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "POST /api/v1/knowledge/okf/import"
  def import(conn, params) do
    api_key = conn.assigns.current_api_key

    with :ok <- ProjectId.validate(params["project_id"]),
         {:ok, files} <- fetch_files(params),
         {:ok, report} <- OKF.import_files(api_key.tenant_id, files, import_opts(params, api_key)) do
      json(conn, %{data: report})
    else
      {:error, :too_many_concepts} ->
        {:error, :bad_request, "Bundle exceeds the maximum number of concepts; split it up."}

      other ->
        other
    end
  end

  # --- helpers ---

  defp export_opts(params) do
    case params["project_id"] do
      value when value in [nil, ""] -> []
      project_id -> [project_id: project_id]
    end
  end

  defp fetch_files(%{"files" => files}) when is_map(files) do
    cond do
      map_size(files) == 0 ->
        {:error, :bad_request, "`files` must contain at least one file"}

      map_size(files) > @max_import_files ->
        {:error, :bad_request, "`files` exceeds the #{@max_import_files}-file limit"}

      not valid_files?(files) ->
        {:error, :bad_request, "`files` must map string paths to string contents"}

      total_bytes(files) > @max_import_bytes ->
        {:error, :bad_request, "`files` exceeds the 50 MiB total-size limit"}

      true ->
        {:ok, files}
    end
  end

  defp fetch_files(_params) do
    {:error, :bad_request, "`files` (a map of path => contents) is required"}
  end

  defp valid_files?(files) do
    Enum.all?(files, fn {k, v} -> is_binary(k) and is_binary(v) end)
  end

  defp total_bytes(files) do
    Enum.reduce(files, 0, fn {k, v}, acc -> acc + byte_size(k) + byte_size(v) end)
  end

  defp import_opts(params, api_key) do
    []
    |> put_if_present(:project_id, params["project_id"])
    |> Keyword.put(:merge, parse_bool(params["merge"], true))
    |> Keyword.put(:dry_run, parse_bool(params["dry_run"], false))
    |> Keyword.put(:actor_id, api_key.id)
    |> Keyword.put(:actor_label, "okf_import")
  end

  defp put_if_present(opts, _key, nil), do: opts
  defp put_if_present(opts, _key, ""), do: opts
  defp put_if_present(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_bool(true, _default), do: true
  defp parse_bool(false, _default), do: false
  defp parse_bool("true", _default), do: true
  defp parse_bool("false", _default), do: false
  defp parse_bool(_other, default), do: default
end
