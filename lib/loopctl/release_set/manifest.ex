defmodule Loopctl.ReleaseSet.Manifest do
  @moduledoc """
  `release/manifest.toml` (US-52.7) as data: parsing, the source-version comparison
  `mix loopctl.release_set` runs, the bump, and the canonical text the bump writes.

  Pure apart from `source_version/2` and `drift/2`, which read the component source files
  under a root, so a test runs them on a temporary copy.
  """

  @components ~w(server runner chg chg_adapter_elixir chg_adapter_typescript chg_adapter_generic mcp)
  @semver ~r/\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\z/
  @unreported "unreported"

  @header """
  # The factory release set (US-52.7): one compatible set of every component this repository
  # ships. A component is compatible from its minimum up. Each version is read from its source
  # file; `mix loopctl.release_set --check` fails when one differs, and `--bump` moves the set.
  # Written by `mix loopctl.release_set --bump`; edit by hand only to change a minimum.
  """

  @type component :: %{version: String.t(), minimum: String.t(), source: String.t()}
  @type t :: %{
          set: pos_integer(),
          components: %{String.t() => component()},
          retired: [String.t()]
        }

  @owner_repo ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/

  @doc "The component names, in the order the manifest lists them."
  @spec components() :: [String.t()]
  def components, do: @components

  @doc """
  Parses the manifest text. `file` names the file in every error, with the key at fault.
  """
  @spec parse(String.t(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(text, file) do
    with {:ok, doc} <- decode(text, file),
         {:ok, set} <- set(doc, file),
         {:ok, components} <- components(doc, file),
         {:ok, retired} <- retired(doc, file) do
      {:ok, %{set: set, components: components, retired: retired}}
    end
  end

  # US-52.11: the repositories folded into this one and archived. Each machine's install
  # drops their chg sources (release/install-machine.sh). Absent means none.
  defp retired(%{"retired" => %{"repos" => repos}}, file) when is_list(repos) do
    if Enum.all?(repos, &(is_binary(&1) and Regex.match?(@owner_repo, &1))),
      do: {:ok, repos},
      else: {:error, "#{file}: retired.repos must be a list of owner/name strings"}
  end

  defp retired(%{"retired" => _}, file),
    do: {:error, "#{file}: retired must be a table with a repos list"}

  defp retired(_doc, _file), do: {:ok, []}

  defp decode(text, file) do
    case Toml.decode(text) do
      {:ok, doc} -> {:ok, doc}
      {:error, reason} -> {:error, "#{file}: not TOML: #{inspect(reason)}"}
    end
  end

  defp set(%{"set" => n}, _file) when is_integer(n) and n > 0, do: {:ok, n}
  defp set(_doc, file), do: {:error, "#{file}: set must be a positive integer"}

  defp components(doc, file) do
    tables = Map.get(doc, "components", %{})

    Enum.reduce_while(@components, {:ok, %{}}, fn name, {:ok, acc} ->
      case component(tables, name, file) do
        {:ok, c} -> {:cont, {:ok, Map.put(acc, name, c)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp component(tables, name, file) do
    key = "components.#{name}"

    with {:ok, table} <- table(tables, name, file),
         {:ok, version} <- version(table, "version", key, file),
         {:ok, minimum} <- version(table, "minimum", key, file),
         {:ok, source} <- source(table, key, file) do
      {:ok, %{version: version, minimum: minimum, source: source}}
    end
  end

  defp table(tables, name, file) do
    case Map.get(tables, name) do
      %{} = table -> {:ok, table}
      _ -> {:error, "#{file}: components.#{name} is missing"}
    end
  end

  defp version(table, field, key, file) do
    value = Map.get(table, field)

    if is_binary(value) and valid_version?(value) do
      {:ok, value}
    else
      {:error,
       "#{file}: #{key}.#{field} must be a semver version or \"#{@unreported}\", got #{inspect(value)}"}
    end
  end

  defp source(table, key, file) do
    case Map.get(table, "source") do
      source when is_binary(source) and source != "" -> {:ok, source}
      other -> {:error, "#{file}: #{key}.source must name a file, got #{inspect(other)}"}
    end
  end

  @doc "Whether `value` is a semver version or the literal `\"unreported\"`."
  @spec valid_version?(String.t()) :: boolean()
  def valid_version?(@unreported), do: true
  def valid_version?(value), do: Regex.match?(@semver, value)

  @doc """
  The version a component's source file declares, read under `root`: `version:` in a
  mix.exs, the `[package]` version of a Cargo.toml, `"version"` of a package.json.
  """
  @spec source_version(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def source_version(root, source) do
    path = Path.join(root, source)

    case File.read(path) do
      {:ok, text} -> read_version(Path.basename(source), text, source)
      {:error, reason} -> {:error, "#{source}: #{:file.format_error(reason)}"}
    end
  end

  defp read_version("mix.exs", text, source),
    do: first_capture(~r/^\s*version:\s*"([^"]+)"/m, text, source)

  defp read_version("Cargo.toml", text, source) do
    case Toml.decode(text) do
      {:ok, %{"package" => %{"version" => v}}} when is_binary(v) -> {:ok, v}
      _ -> {:error, "#{source}: no [package] version"}
    end
  end

  defp read_version("package.json", text, source) do
    case Jason.decode(text) do
      {:ok, %{"version" => v}} when is_binary(v) -> {:ok, v}
      _ -> {:error, "#{source}: no \"version\""}
    end
  end

  defp read_version(_name, _text, source),
    do: {:error, "#{source}: not a mix.exs, Cargo.toml or package.json"}

  defp first_capture(regex, text, source) do
    case Regex.run(regex, text) do
      [_, v] -> {:ok, v}
      nil -> {:error, "#{source}: no version:"}
    end
  end

  @doc """
  Each component whose manifest version differs from its source's, as
  `{name, manifest_version, source_version}`, in manifest order; or the first source that
  cannot be read.
  """
  @spec drift(t(), String.t()) ::
          {:ok, [{String.t(), String.t(), String.t()}]} | {:error, String.t()}
  def drift(manifest, root) do
    Enum.reduce_while(@components, {:ok, []}, fn name, {:ok, acc} ->
      %{version: version, source: source} = manifest.components[name]

      case source_version(root, source) do
        {:ok, ^version} -> {:cont, {:ok, acc}}
        {:ok, other} -> {:cont, {:ok, [{name, version, other} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  @doc """
  The next set: `set` + 1, and each drifted component's version becomes the source's. No
  minimum moves: loopctl refuses a client below its component's minimum (426), and a session
  binds its MCP server at start, so raising the minimum on every bump cut off every session
  one release behind the moment the server deployed (set 7, 2026-11-21). Raising a minimum is
  a hand edit, made when an older client genuinely cannot work.
  """
  @spec bump(t(), [{String.t(), String.t(), String.t()}]) :: t()
  def bump(manifest, drifted) do
    components =
      Enum.reduce(drifted, manifest.components, fn {name, _previous, current}, acc ->
        Map.update!(acc, name, &%{&1 | version: current})
      end)

    %{manifest | set: manifest.set + 1, components: components}
  end

  @doc "The manifest as the text `--bump` writes."
  @spec render(t()) :: String.t()
  def render(manifest) do
    tables =
      Enum.map_join(@components, "\n", fn name ->
        c = manifest.components[name]

        """
        [components.#{name}]
        version = #{quote_toml(c.version)}
        minimum = #{quote_toml(c.minimum)}
        source = #{quote_toml(c.source)}
        """
      end)

    @header <>
      "\nset = #{manifest.set}\n\n" <> tables <> render_retired(Map.get(manifest, :retired, []))
  end

  defp render_retired([]), do: ""

  defp render_retired(repos),
    do: "\n[retired]\nrepos = [" <> Enum.map_join(repos, ", ", &quote_toml/1) <> "]\n"

  defp quote_toml(value), do: Jason.encode!(value)
end
