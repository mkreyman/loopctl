defmodule Mix.Tasks.Loopctl.CheckEnvDocs do
  @moduledoc """
  Guards operator-facing environment variables against being shipped undocumented.

  `config/runtime.exs` is where every operator-tunable knob is read, and an env var
  that exists only there is effectively invisible: the audience who needs it (someone
  deploying loopctl) is exactly the audience who cannot read our source tree. This
  failure is silent — nothing in review flags a `System.get_env/1` with no matching
  doc line — and it accumulated to 24 undocumented variables before anyone noticed,
  including the two self-hosting knobs (`SECRETS_ADAPTER`, `FTS_REGCONFIG`) that a
  self-hoster could not run the app without.

  Same guardrail idea as `mix loopctl.check_skill_citations` and
  `mix loopctl.check_wiki_links`, applied to operator configuration.

  ## What is checked

  Every `System.get_env("X")` / `System.fetch_env!("X")` read in `config/runtime.exs`
  must have its name documented in `deploy/FLY_SECRETS.md`.

  Lines that are entirely a `#` comment are skipped, so the commented-out `phx.new`
  TLS boilerplate (`SOME_APP_SSL_KEY_PATH`) is not demanded to be documented. The
  scan is textual, not an AST walk: a var name built by string interpolation is not
  detected. That is an accepted limit — operator knobs are read by literal name.

  ## Adding a variable

  Document it in the appropriate table in `deploy/FLY_SECRETS.md` with its DEFAULT
  and what breaks if it is wrong. If a variable is genuinely internal (never set by
  an operator), add it to `@exempt` WITH a reason — an exemption without a rationale
  is how the undocumented set grew in the first place.

  ## Usage

      mix loopctl.check_env_docs

  Exits non-zero listing every undocumented variable.
  """

  use Mix.Task

  @shortdoc "Check that runtime.exs env vars are documented for operators"

  @config_file "config/runtime.exs"
  @docs_file "deploy/FLY_SECRETS.md"

  # Variables deliberately NOT in the operator docs. Each needs a reason.
  # (Empty today — every runtime.exs variable is documented.)
  @exempt %{}

  # Vacuity guard: runtime.exs reads dozens of variables, so a scan returning
  # almost nothing means the regex or the file moved — a guard that silently
  # checks nothing is worse than no guard (the check_skill_citations lesson).
  @min_expected_vars 20

  @impl Mix.Task
  def run(_args) do
    for file <- [@config_file, @docs_file] do
      File.exists?(file) ||
        Mix.raise("check_env_docs: #{file} not found. Run from the repo root.")
    end

    vars = scan_env_vars(File.read!(@config_file))

    if MapSet.size(vars) < @min_expected_vars do
      Mix.raise(
        "check_env_docs scanned #{@config_file} and found only #{MapSet.size(vars)} " <>
          "env var(s), expected at least #{@min_expected_vars}. The scan is broken — " <>
          "fix it rather than lowering the floor, or this guard passes vacuously."
      )
    end

    report(undocumented(vars, File.read!(@docs_file)), MapSet.size(vars))
  end

  @doc """
  The scanned variables that are neither exempt nor named in `docs`, sorted.

  Public so the guard's FAILING behaviour is testable — a doc guard that has only
  ever been observed passing is indistinguishable from one that can never fail.
  """
  @spec undocumented(MapSet.t(binary()) | [binary()], binary()) :: [binary()]
  def undocumented(vars, docs) do
    vars
    |> Enum.reject(&(Map.has_key?(@exempt, &1) or documented?(docs, &1)))
    |> Enum.sort()
  end

  @doc """
  The env var names read (outside full-line comments) in the given source text.
  """
  @spec scan_env_vars(binary()) :: MapSet.t(binary())
  def scan_env_vars(source) do
    source
    |> String.split("\n")
    |> Enum.reject(&comment_line?/1)
    |> Enum.flat_map(fn line ->
      ~r/System\.(?:get_env|fetch_env!)\(\s*"([A-Z][A-Z0-9_]*)"/
      |> Regex.scan(line, capture: :all_but_first)
      |> List.flatten()
    end)
    |> MapSet.new()
  end

  defp comment_line?(line), do: String.match?(line, ~r/^\s*#/)

  # The name must appear as a whole word, so `POOL_SIZE` is not satisfied by an
  # unrelated `ADMIN_POOL_SIZE` row (substring matching is how a doc guard goes
  # quietly vacuous).
  defp documented?(docs, var) do
    String.match?(docs, ~r/(?<![A-Z0-9_])#{Regex.escape(var)}(?![A-Z0-9_])/)
  end

  defp report([], scanned) do
    Mix.shell().info("#{scanned} runtime env var(s) documented in #{@docs_file}")
  end

  defp report(undocumented, _scanned) do
    list = Enum.map_join(undocumented, "\n", &"  - #{&1}")

    Mix.raise("""
    Undocumented operator environment variable(s):

    #{list}

    Each is read in #{@config_file} but appears nowhere in #{@docs_file}, so an
    operator cannot discover it without reading our source.

    Document each in the appropriate table in #{@docs_file} — its DEFAULT and what
    breaks if it is wrong. If one is genuinely internal, add it to @exempt in
    #{__MODULE__ |> Module.split() |> Enum.join(".")} with a reason.
    """)
  end
end
