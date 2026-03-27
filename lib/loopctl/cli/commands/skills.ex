defmodule Loopctl.CLI.Commands.Skills do
  @moduledoc """
  CLI commands for skill management.

  Commands:
  - `loopctl skill list` -- list all skills
  - `loopctl skill get <name>` -- show current version prompt
  - `loopctl skill get <name> --version <N>` -- show specific version
  - `loopctl skill create --name <name> --file <path>` -- create from file
  - `loopctl skill update <name> --file <path>` -- new version from file
  - `loopctl skill stats <name>` -- performance stats by version
  - `loopctl skill history <name>` -- version history
  - `loopctl skill import <directory> --project <project>` -- bulk import
  - `loopctl skill archive <name>` -- archive skill
  """

  alias Loopctl.CLI.Client
  alias Loopctl.CLI.Output

  @usage "Usage: loopctl skill list|get|create|update|stats|history|import|archive"

  @doc """
  Dispatches skill subcommands.
  """
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run("skill", ["list" | rest], opts), do: list(rest, opts)
  def run("skill", ["get", name | rest], opts), do: get_skill(name, rest, opts)
  def run("skill", ["create" | rest], opts), do: create(rest, opts)
  def run("skill", ["update", name | rest], opts), do: update(name, rest, opts)
  def run("skill", ["stats", name], opts), do: stats(name, opts)
  def run("skill", ["history", name], opts), do: history(name, opts)
  def run("skill", ["import" | rest], opts), do: import_skills(rest, opts)
  def run("skill", ["archive", name], opts), do: archive(name, opts)
  def run("skill", _args, _opts), do: Output.error(@usage)
  def run(_command, _args, _opts), do: Output.error(@usage)

  defp list(args, opts) do
    parsed = parse_kv_args(args)
    params = build_list_params(parsed)

    case Client.get("/api/v1/skills", params: params) do
      {:ok, result} ->
        Output.render(result,
          format: Keyword.get(opts, :format),
          headers: ["id", "name", "current_version", "status"]
        )

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp get_skill(name, rest, opts) do
    parsed = parse_kv_args(rest)
    version = Map.get(parsed, "version")

    with_skill_id(name, fn skill_id ->
      if version do
        get_specific_version(skill_id, version, opts)
      else
        get_current_skill(skill_id, opts)
      end
    end)
  end

  defp get_current_skill(skill_id, opts) do
    case Client.get("/api/v1/skills/#{skill_id}") do
      {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
      {:error, reason} -> handle_error(reason)
    end
  end

  defp get_specific_version(skill_id, version, opts) do
    case Client.get("/api/v1/skills/#{skill_id}/versions/#{version}") do
      {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
      {:error, reason} -> handle_error(reason)
    end
  end

  defp create(args, opts) do
    parsed = parse_kv_args(args)
    name = Map.get(parsed, "name")
    file = Map.get(parsed, "file")
    description = Map.get(parsed, "description")

    if name && file do
      create_from_file(name, file, description, opts)
    else
      Output.error("Usage: loopctl skill create --name <name> --file <path>")
    end
  end

  defp create_from_file(name, file, description, opts) do
    case File.read(file) do
      {:ok, prompt_text} ->
        body =
          %{"name" => name, "prompt_text" => prompt_text}
          |> maybe_put("description", description)

        case Client.post("/api/v1/skills", body) do
          {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
          {:error, reason} -> handle_error(reason)
        end

      {:error, reason} ->
        Output.error("Failed to read file: #{inspect(reason)}")
    end
  end

  defp update(name, rest, opts) do
    parsed = parse_kv_args(rest)
    file = Map.get(parsed, "file")
    changelog = Map.get(parsed, "changelog")

    if file do
      case File.read(file) do
        {:ok, prompt_text} ->
          find_and_update_skill(name, prompt_text, changelog, opts)

        {:error, reason} ->
          Output.error("Failed to read file: #{inspect(reason)}")
      end
    else
      Output.error("Usage: loopctl skill update <name> --file <path> [--changelog <text>]")
    end
  end

  defp find_and_update_skill(name, prompt_text, changelog, opts) do
    with_skill_id(name, fn skill_id ->
      body =
        %{"prompt_text" => prompt_text}
        |> maybe_put("changelog", changelog)

      case Client.post("/api/v1/skills/#{skill_id}/versions", body) do
        {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
        {:error, reason} -> handle_error(reason)
      end
    end)
  end

  defp stats(name, opts) do
    with_skill_id(name, fn skill_id ->
      case Client.get("/api/v1/skills/#{skill_id}/stats") do
        {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
        {:error, reason} -> handle_error(reason)
      end
    end)
  end

  defp history(name, opts) do
    with_skill_id(name, fn skill_id ->
      case Client.get("/api/v1/skills/#{skill_id}/versions") do
        {:ok, result} ->
          Output.render(result,
            format: Keyword.get(opts, :format),
            headers: ["version", "changelog", "created_by", "inserted_at"]
          )

        {:error, reason} ->
          handle_error(reason)
      end
    end)
  end

  defp import_skills(args, opts) do
    parsed = parse_kv_args(args)
    dir = List.first(Enum.reject(args, &String.starts_with?(&1, "--")))
    project_id = Map.get(parsed, "project")

    if dir do
      do_import(dir, project_id, opts)
    else
      Output.error("Usage: loopctl skill import <directory> [--project <project_id>]")
    end
  end

  defp do_import(dir, project_id, opts) do
    case read_skill_files(dir) do
      {:ok, skills} ->
        body =
          %{"skills" => skills}
          |> maybe_put("project_id", project_id)

        case Client.post("/api/v1/skills/import", body) do
          {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
          {:error, reason} -> handle_error(reason)
        end

      {:error, reason} ->
        Output.error("Failed to read skills: #{inspect(reason)}")
    end
  end

  defp archive(name, opts) do
    with_skill_id(name, fn skill_id ->
      case Client.delete("/api/v1/skills/#{skill_id}") do
        {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
        {:error, reason} -> handle_error(reason)
      end
    end)
  end

  # Looks up a skill by name and calls the callback with its ID.
  defp with_skill_id(name, callback) do
    case Client.get("/api/v1/skills", params: [{"name", name}]) do
      {:ok, %{"data" => [skill | _]}} -> callback.(skill["id"])
      {:ok, _} -> Output.error("Skill '#{name}' not found")
      {:error, reason} -> handle_error(reason)
    end
  end

  defp read_skill_files(dir) do
    if File.dir?(dir) do
      skills =
        dir
        |> Path.join("**/*.md")
        |> Path.wildcard()
        |> Enum.flat_map(&parse_skill_file/1)

      {:ok, skills}
    else
      {:error, :not_a_directory}
    end
  end

  defp parse_skill_file(file) do
    name = file |> Path.basename(".md") |> String.replace("_", "-")

    case File.read(file) do
      {:ok, content} ->
        [%{"name" => name, "prompt_text" => content, "description" => "Imported from #{file}"}]

      _ ->
        []
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

  defp build_list_params(parsed) do
    []
    |> maybe_add_param("project_id", Map.get(parsed, "project"))
    |> maybe_add_param("status", Map.get(parsed, "status"))
    |> maybe_add_param("name", Map.get(parsed, "name"))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: params ++ [{key, value}]
end
