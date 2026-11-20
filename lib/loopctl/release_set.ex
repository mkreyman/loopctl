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
  @clients ~w(runner chg mcp)

  @typedoc "A factory client's refusal: what it sent, and the set's floor and current version."
  @type incompatible :: %{
          component: String.t(),
          sent: String.t() | nil,
          minimum: String.t(),
          version: String.t()
        }

  @doc "The components a client may name in `x-loopctl-client` or a runner join."
  @spec clients() :: [String.t()]
  def clients, do: @clients

  @doc """
  Whether a factory client at version `sent` is compatible with this set (US-52.8).

  `:ok` for a semver at or above the component's minimum, newer than its version included,
  so clients may roll before or after the server. A version below the minimum, one that is not
  semver, or `nil` while the minimum is a version is refused. `nil` is admitted while the
  minimum is `"unreported"`: that component's clients predate reporting a version.

  `components` defaults to the compiled set; a test passes its own.
  """
  @spec check(atom() | String.t(), String.t() | nil, map()) ::
          :ok | {:error, {:incompatible_client_version, incompatible()}}
  def check(component, sent, components \\ components())

  def check(component, sent, components) when is_atom(component),
    do: check(Atom.to_string(component), sent, components)

  def check(component, sent, components) when component in @clients do
    %{minimum: minimum, version: version} = Map.fetch!(components, component)

    if compatible?(sent, minimum) do
      :ok
    else
      {:error,
       {:incompatible_client_version,
        %{component: component, sent: sent, minimum: minimum, version: version}}}
    end
  end

  defp compatible?(nil, "unreported"), do: true
  defp compatible?(nil, _minimum), do: false

  defp compatible?(sent, minimum) when is_binary(sent) do
    with true <- Manifest.valid_version?(sent) and sent != "unreported",
         {:ok, sent} <- Version.parse(sent) do
      at_least?(sent, minimum)
    else
      _ -> false
    end
  end

  defp compatible?(_sent, _minimum), do: false

  defp at_least?(_sent, "unreported"), do: true
  defp at_least?(sent, minimum), do: Version.compare(sent, Version.parse!(minimum)) != :lt
end
