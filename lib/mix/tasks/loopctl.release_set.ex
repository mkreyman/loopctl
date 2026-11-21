defmodule Mix.Tasks.Loopctl.ReleaseSet do
  @shortdoc "Checks or bumps release/manifest.toml against each component's version"

  @moduledoc """
  Keeps `release/manifest.toml` (US-52.7) in step with the versions its components declare.

      mix loopctl.release_set --check   # exit 1 naming each component that differs
      mix loopctl.release_set --bump    # next set when a component changed

  `--check` is a step of `mix precommit` and of ci.yml's lint job. `--bump` increments
  `set` and, for each component whose source version differs, sets its version to the
  source's and leaves its minimum (raising a minimum is a hand edit); with nothing different it prints
  `no component changed` and leaves the file untouched. `--root DIR` reads the manifest and
  the sources under DIR (the default is the current directory).
  """

  use Mix.Task

  alias Loopctl.ReleaseSet.Manifest

  @switches [check: :boolean, bump: :boolean, root: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    root = Keyword.get(opts, :root, File.cwd!())
    Mix.Task.run("compile", [])

    case {opts[:check], opts[:bump]} do
      {true, nil} -> report_check(check(root))
      {nil, true} -> report_bump(bump(root))
      _ -> Mix.raise("mix loopctl.release_set takes exactly one of --check or --bump")
    end
  end

  @doc """
  `:ok`, or `{:drift, messages}` with one message per component whose manifest version
  differs from its source's.
  """
  @spec check(String.t()) :: :ok | {:drift, [String.t()]} | {:error, String.t()}
  def check(root) do
    with {:ok, _manifest, drifted} <- load(root) do
      case drifted do
        [] ->
          :ok

        drifted ->
          {:drift,
           for {name, manifest_version, source_version} <- drifted do
             "#{name}: release/manifest.toml says #{manifest_version}, its source says " <>
               "#{source_version}; run mix loopctl.release_set --bump"
           end}
      end
    end
  end

  @doc """
  Writes the next set when a component changed (`{:bumped, set, names}`); `:unchanged`
  leaves the file as it is.
  """
  @spec bump(String.t()) ::
          :unchanged | {:bumped, pos_integer(), [String.t()]} | {:error, String.t()}
  def bump(root) do
    case load(root) do
      {:ok, _manifest, []} ->
        :unchanged

      {:ok, manifest, drifted} ->
        next = Manifest.bump(manifest, drifted)
        File.write!(manifest_path(root), Manifest.render(next))
        {:bumped, next.set, Enum.map(drifted, &elem(&1, 0))}

      {:error, _} = error ->
        error
    end
  end

  defp report_check(:ok),
    do: Mix.shell().info("release/manifest.toml matches every component's source")

  defp report_check({:error, message}), do: Mix.raise(message)

  defp report_check({:drift, messages}) do
    Enum.each(messages, fn message -> Mix.shell().error(message) end)
    exit({:shutdown, 1})
  end

  defp report_bump(:unchanged), do: Mix.shell().info("no component changed")
  defp report_bump({:error, message}), do: Mix.raise(message)

  defp report_bump({:bumped, set, names}),
    do: Mix.shell().info("release set #{set}: #{Enum.join(names, ", ")}")

  defp load(root) do
    path = manifest_path(root)

    with {:ok, text} <- read(path),
         {:ok, manifest} <- Manifest.parse(text, "release/manifest.toml"),
         {:ok, drifted} <- Manifest.drift(manifest, root) do
      {:ok, manifest, drifted}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  defp manifest_path(root), do: Path.join(root, "release/manifest.toml")
end
