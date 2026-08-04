defmodule Mix.Tasks.Loopctl.CheckEnvDocs do
  @moduledoc """
  Guards operator-facing environment variables against being shipped undocumented.

  An env var that exists only in our source is effectively invisible: the audience who
  needs it (someone deploying loopctl) is exactly the audience who cannot read our
  source tree. This failure is silent — nothing in review flags a `System.get_env/1`
  with no matching doc line — and it accumulated to 24 undocumented variables before
  anyone noticed, including the two self-hosting knobs (`SECRETS_ADAPTER`,
  `FTS_REGCONFIG`) that a self-hoster could not run the app without.

  Same guardrail idea as `mix loopctl.check_skill_citations` and
  `mix loopctl.check_wiki_links`, applied to operator configuration.

  ## What is checked

  Every `System.get_env/1` / `System.fetch_env!/1` read of a LITERAL uppercase name, in
  every file matched by `sources/0` — `config/runtime.exs` **and** `lib/**/*.ex` — must
  have a table row in `deploy/FLY_SECRETS.md`.

  `lib/` is scanned because reading the config file alone left a blind spot the size of
  the whole `OBAN_*` family (#566): `runtime.exs` does evaluate those at boot, but it
  does so by calling `Loopctl.ObanConfig`, so the literal name never appears in the
  scanned file. The guard reported "42 runtime env var(s) documented" and exited 0
  while eight variables it had never looked at were undocumented.

  ### Why a table ROW, and not a mention

  `STH_SWEEP_CRON` passed a whole-word text match for months on the strength of one
  prose aside — "a deliberate choice after the `STH_SWEEP_CRON` incident" — which tells
  an operator neither its default nor what it does. Naming a variable while explaining
  something else is not documenting it, so the match is anchored to the name heading a
  markdown table row, where a default and a description are structurally adjacent.

  ### Limits of a textual scan

  The scan is textual, not an AST walk. Two consequences, both accepted:

    * a name built by interpolation is not detected — fine, because operator knobs are
      read by literal name;
    * a literal read written inside a `@moduledoc` is detected, because a docstring is
      not a comment line. Name variables in prose (or as `System.get_env/1`) rather
      than writing a fake call with a placeholder name, or the guard will demand that
      the placeholder be documented.

  Lines that are entirely a `#` comment are skipped, so the commented-out `phx.new` TLS
  boilerplate (`SOME_APP_SSL_KEY_PATH`) is not demanded to be documented.

  ## Adding a variable

  Give it a row in the appropriate table in `deploy/FLY_SECRETS.md` with its DEFAULT
  and what breaks if it is wrong. If a variable is genuinely internal (never set by an
  operator), add it to `@exempt` WITH a reason — an exemption without a rationale is
  how the undocumented set grew in the first place.

  ## Usage

      mix loopctl.check_env_docs

  Exits non-zero listing every undocumented variable.
  """

  use Mix.Task

  @shortdoc "Check that operator env vars are documented in deploy/FLY_SECRETS.md"

  @docs_file "deploy/FLY_SECRETS.md"

  # {wildcard, minimum vars expected from THAT wildcard}.
  #
  # The floor is per-source on purpose. One floor over the union cannot detect a broken
  # `lib/**/*.ex` glob at all: runtime.exs alone contributes ~42 vars, so the union
  # clears any sane threshold while the second source silently contributes nothing —
  # which is precisely the vacuous-guard shape this task exists to prevent, reintroduced
  # one level up. Each floor sits below its current count with room to delete a knob or
  # two, and far above zero.
  @sources [
    {"config/runtime.exs", 20},
    {"lib/**/*.ex", 6}
  ]

  # Variables deliberately NOT in the operator docs. Each needs a reason.
  # (Empty today — every scanned variable is documented.)
  @exempt %{}

  @impl Mix.Task
  def run(_args) do
    File.exists?(@docs_file) ||
      Mix.raise("check_env_docs: #{@docs_file} not found. Run from the repo root.")

    vars =
      Enum.reduce(@sources, MapSet.new(), fn {pattern, min}, acc ->
        pattern |> scan_paths() |> check_not_vacuous(pattern, min) |> MapSet.union(acc)
      end)

    report(undocumented(vars, File.read!(@docs_file)), MapSet.size(vars))
  end

  @doc """
  The scanned sources as `{wildcard, minimum expected vars}` pairs.

  Public so a test can assert over the SAME list the task scans — a test that re-lists
  the sources itself passes happily when a source is dropped from the task.
  """
  @spec sources() :: [{binary(), non_neg_integer()}]
  def sources, do: @sources

  @doc """
  The env var names read across every file matching `pattern`.

  Raises when the wildcard matches no file at all: an empty match would otherwise be
  reported as "this source contributes no variables", which is indistinguishable from
  a source that genuinely has none.
  """
  @spec scan_paths(binary()) :: MapSet.t(binary())
  def scan_paths(pattern) do
    case Path.wildcard(pattern) do
      [] ->
        Mix.raise("check_env_docs: #{pattern} matched no files. Run from the repo root.")

      files ->
        files
        |> Enum.map(&(&1 |> File.read!() |> scan_env_vars()))
        |> Enum.reduce(MapSet.new(), &MapSet.union/2)
    end
  end

  @doc """
  The scanned variables that are neither exempt nor documented in `docs`, sorted.

  Public so the guard's FAILING behaviour is testable — a doc guard that has only ever
  been observed passing is indistinguishable from one that can never fail.
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

  defp check_not_vacuous(vars, pattern, min) do
    if MapSet.size(vars) < min do
      Mix.raise(
        "check_env_docs scanned #{pattern} and found only #{MapSet.size(vars)} env " <>
          "var(s), expected at least #{min}. That source's scan is broken — fix it " <>
          "rather than lowering the floor, or this guard passes vacuously for #{pattern}."
      )
    end

    vars
  end

  defp comment_line?(line), do: String.match?(line, ~r/^\s*#/)

  # The name must head a markdown table row. Anchoring to the row (rather than to any
  # whole-word mention) is what keeps a passing mention from standing in for a default
  # and a description — see the `STH_SWEEP_CRON` note in the moduledoc. Anchoring to a
  # whole word within the row also keeps `POOL_SIZE` from being satisfied by an
  # unrelated `ADMIN_POOL_SIZE` row.
  defp documented?(docs, var) do
    String.match?(docs, ~r/^\|\s*`#{Regex.escape(var)}`/m)
  end

  defp report([], scanned) do
    Mix.shell().info("#{scanned} operator env var(s) documented in #{@docs_file}")
  end

  defp report(undocumented, _scanned) do
    list = Enum.map_join(undocumented, "\n", &"  - #{&1}")
    scanned = Enum.map_join(@sources, ", ", fn {pattern, _min} -> pattern end)

    Mix.raise("""
    Undocumented operator environment variable(s):

    #{list}

    Each is read in #{scanned} but has no table row in #{@docs_file}, so an operator
    cannot discover it without reading our source.

    Give each a row in the appropriate table in #{@docs_file} — its DEFAULT and what
    breaks if it is wrong. A passing mention in prose does not count. If one is
    genuinely internal, add it to @exempt in
    #{__MODULE__ |> Module.split() |> Enum.join(".")} with a reason.
    """)
  end
end
