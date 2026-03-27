defmodule Loopctl.CLI.Commands.Projects do
  @moduledoc """
  CLI commands for project management and import/export.

  Commands:
  - `loopctl project create <name> --repo <url>`
  - `loopctl project list`
  - `loopctl project info <project_id>`
  - `loopctl project archive <project_id>`
  - `loopctl import <path> --project <project_id>`
  - `loopctl export --project <project_id>`
  """

  alias Loopctl.CLI.Client
  alias Loopctl.CLI.Output

  @doc """
  Dispatches project and import/export subcommands.
  """
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run("project", args, opts) do
    case args do
      ["create" | rest] -> create(rest, opts)
      ["list"] -> list(opts)
      ["info", project_id] -> info(project_id, opts)
      ["archive", project_id] -> archive(project_id, opts)
      _ -> Output.error("Usage: loopctl project create|list|info|archive")
    end
  end

  def run("import", args, opts) do
    parsed = parse_kv_args(args)
    path = List.first(Enum.reject(args, &String.starts_with?(&1, "--")))
    project_id = Map.get(parsed, "project")

    if path && project_id do
      import_project(path, project_id, opts)
    else
      Output.error("Usage: loopctl import <path> --project <project_id>")
    end
  end

  def run("export", args, opts) do
    parsed = parse_kv_args(args)
    project_id = Map.get(parsed, "project")

    if project_id do
      export_project(project_id, opts)
    else
      Output.error("Usage: loopctl export --project <project_id>")
    end
  end

  def run(_command, _args, _opts) do
    Output.error("Usage: loopctl project create|list|info|archive")
  end

  defp create(args, opts) do
    parsed = parse_kv_args(args)
    name = List.first(Enum.reject(args, &String.starts_with?(&1, "--")))
    repo = Map.get(parsed, "repo")

    if name do
      body =
        %{"name" => name}
        |> maybe_put("repo_url", repo)
        |> maybe_put("slug", Map.get(parsed, "slug"))
        |> maybe_put("tech_stack", Map.get(parsed, "tech-stack"))

      case Client.post("/api/v1/projects", body) do
        {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
        {:error, reason} -> handle_error(reason)
      end
    else
      Output.error("Usage: loopctl project create <name> [--repo <url>]")
    end
  end

  defp list(opts) do
    case Client.get("/api/v1/projects") do
      {:ok, result} ->
        Output.render(result,
          format: Keyword.get(opts, :format),
          headers: ["id", "name", "slug", "status"]
        )

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp info(project_id, opts) do
    case Client.get("/api/v1/projects/#{project_id}") do
      {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
      {:error, reason} -> handle_error(reason)
    end
  end

  defp archive(project_id, opts) do
    case Client.delete("/api/v1/projects/#{project_id}") do
      {:ok, _} ->
        Output.render(%{"status" => "archived", "id" => project_id},
          format: Keyword.get(opts, :format)
        )

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp import_project(path, project_id, opts) do
    case read_import_data(path) do
      {:ok, data} ->
        case Client.post("/api/v1/projects/#{project_id}/import", data) do
          {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
          {:error, reason} -> handle_error(reason)
        end

      {:error, reason} ->
        Output.error("Failed to read import data: #{inspect(reason)}")
    end
  end

  defp export_project(project_id, opts) do
    case Client.get("/api/v1/projects/#{project_id}/export") do
      {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
      {:error, reason} -> handle_error(reason)
    end
  end

  defp read_import_data(path) do
    cond do
      File.dir?(path) ->
        read_directory_import(path)

      File.regular?(path) ->
        case File.read(path) do
          {:ok, contents} -> Jason.decode(contents)
          error -> error
        end

      true ->
        {:error, :file_not_found}
    end
  end

  defp read_directory_import(dir) do
    epics =
      dir
      |> Path.join("**/us_*.json")
      |> Path.wildcard()
      |> Enum.reduce(%{}, &accumulate_story/2)
      |> Enum.map(fn {_number, epic} -> epic end)

    {:ok, %{"epics" => epics}}
  end

  defp accumulate_story(file, acc) do
    case read_json_file(file) do
      {:ok, story_data} ->
        epic_number = extract_epic_number(file)
        existing = Map.get(acc, epic_number, %{"stories" => []})
        stories = existing["stories"] ++ [story_data]
        Map.put(acc, epic_number, Map.put(existing, "stories", stories))

      _ ->
        acc
    end
  end

  defp read_json_file(path) do
    with {:ok, contents} <- File.read(path) do
      Jason.decode(contents)
    end
  end

  defp extract_epic_number(file_path) do
    case Regex.run(~r/epic_(\d+)/, file_path) do
      [_, num] -> String.to_integer(num)
      _ -> 0
    end
  end

  defp handle_error(:no_server_configured) do
    Output.error("No server configured. Run: loopctl auth login --server <url> --key <key>")
  end

  defp handle_error({status, body}) do
    Output.error("Server returned #{status}: #{inspect(body)}")
  end

  defp parse_kv_args(args) do
    args
    |> Enum.chunk_every(2, 2, :discard)
    |> Enum.reduce(%{}, fn
      ["--" <> key, value], acc -> Map.put(acc, key, value)
      _, acc -> acc
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
