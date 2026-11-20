defmodule Loopctl.ReleaseSet do
  @moduledoc """
  The factory release set this server was built from (US-52.7): `release/manifest.toml`,
  read at compile time.

  A missing file, a missing component, or a version that is neither semver nor
  `"unreported"` fails compilation, naming the file and the key. The Dockerfile copies the
  manifest into the build stage before `mix compile`, so the deployed discovery document
  reports the set the release was built from.

  Read from the project root (`File.cwd!/0`), as the discovery controller reads
  `mcp-server/package.json`: `__DIR__` traversal resolves outside `/app` in the Docker build.
  """

  alias Loopctl.ReleaseSet.Manifest

  @path Path.join(File.cwd!(), "release/manifest.toml")
  @external_resource @path

  @manifest (case File.read(@path) do
               {:ok, text} ->
                 case Manifest.parse(text, "release/manifest.toml") do
                   {:ok, manifest} -> manifest
                   {:error, message} -> raise CompileError, description: message
                 end

               {:error, reason} ->
                 raise CompileError,
                   description: "release/manifest.toml: #{:file.format_error(reason)}"
             end)

  @doc "The release set number."
  @spec set() :: pos_integer()
  def set, do: @manifest.set

  @doc "One component's `%{version: v, minimum: m}`."
  @spec component(String.t()) :: %{version: String.t(), minimum: String.t()}
  def component(name) when is_map_key(@manifest.components, name) do
    Map.take(@manifest.components[name], [:version, :minimum])
  end

  @doc "Every component, name => `%{version: v, minimum: m}`."
  @spec components() :: %{String.t() => %{version: String.t(), minimum: String.t()}}
  def components do
    Map.new(Manifest.components(), &{&1, component(&1)})
  end

  @doc "The discovery document's `release` object."
  @spec discovery() :: %{set: pos_integer(), components: map()}
  def discovery, do: %{set: set(), components: components()}
end
