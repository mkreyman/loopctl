defmodule Mix.Tasks.Loopctl.CheckEnvDocs do
  @moduledoc """
  Guards operator-facing environment variables against being shipped undocumented.

  An env var that exists only in our source is effectively invisible: the audience who
  needs it (someone deploying loopctl) is exactly the audience who cannot read our source
  tree. This failure is silent — nothing in review flags a `System.get_env/1` with no
  matching doc line — and it accumulated to 24 undocumented variables before anyone
  noticed, including the two self-hosting knobs (`SECRETS_ADAPTER`, `FTS_REGCONFIG`) that
  a self-hoster could not run the app without. Same guardrail idea as
  `mix loopctl.check_skill_citations`, applied to operator configuration.

  ## What is checked

  Every `System.get_env/1` / `System.fetch_env!/1` read of a LITERAL uppercase name, in
  every file matched by `sources/0` — `config/runtime.exs` **and** `lib/**/*.ex` — must
  have a table row in `deploy/FLY_SECRETS.md`.

  `lib/` is scanned because reading the config file alone left the `OBAN_*` family
  outside the guard (#566): `runtime.exs` does evaluate those at boot, but it does so by
  calling `Loopctl.ObanConfig`, so the literal name never appears in the scanned file.

  ### Why a table ROW, and not a mention

  `STH_SWEEP_CRON` passed a whole-word text match for months on the strength of one prose
  aside — "a deliberate choice after the `STH_SWEEP_CRON` incident" — which tells an
  operator neither its default nor what it does. Naming a variable while explaining
  something else is not documenting it, so the match is anchored to the name heading a
  markdown table row that also carries a NON-BLANK default and description cell.

  ### Limits of a textual scan

  The scan is textual, not an AST walk, so a name BUILT at runtime
  (`"OBAN_QUEUE_" <> queue`) cannot be resolved. Such a name is still an operator knob —
  `OBAN_QUEUE_<QUEUE>` and `OBAN_TENANT_FAIRSHARE_<QUEUE>` are retuned mid-incident — so a
  dynamic read is not ignored: its file must be listed in `@dynamic_read_sources` with a
  reason, and the family documented by hand.

  A literal read inside a `@moduledoc` IS detected (a docstring is not a comment), so name
  variables in prose or as `System.get_env/1` rather than writing a fake call with a
  placeholder name. Comments — whole-line and trailing alike — are stripped first, so the
  commented-out `phx.new` TLS boilerplate is not demanded.

  ## Adding a variable

  Give it a row in the appropriate table in `deploy/FLY_SECRETS.md` with its DEFAULT and
  what breaks if it is wrong. If a variable is genuinely internal (never set by an
  operator), add it to `@exempt` WITH a reason — an exemption without a rationale is how
  the undocumented set grew in the first place.

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
  # `lib/**/*.ex` glob at all: runtime.exs alone clears any sane threshold while the second
  # source silently contributes nothing — the vacuous-guard shape this task exists to
  # prevent, one level up. Each floor sits below its current count and far above zero.
  # Lowering one is legitimate in exactly one case: a change that deliberately MOVES reads
  # to another scanned source (`Loopctl.Config` blesses either placement now that both are
  # scanned) — then both floors move in that same commit. An unexplained drop is a break.
  @sources [
    {"config/runtime.exs", 20},
    {"lib/**/*.ex", 6}
  ]

  # Variables deliberately NOT in the operator docs. Each needs a reason.
  # (Empty today — every scanned variable is documented.)
  @exempt %{}

  # Files that read env by a name built at RUNTIME, which no textual scan can resolve. Not
  # a free pass: a built name is still an operator knob, so each entry says where the
  # FAMILY is documented. Any OTHER file's dynamic read FAILS the guard — #566, one down.
  @dynamic_read_sources %{
    "lib/loopctl/oban_config.ex" =>
      "OBAN_QUEUE_<QUEUE> / OBAN_TENANT_FAIRSHARE_<QUEUE> — documented as families",
    "lib/loopctl/secrets/fly_adapter.ex" =>
      "per-tenant audit key names the app itself mints; never an operator knob"
  }

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
        |> Enum.map(fn path ->
          source = File.read!(path)
          check_dynamic_reads(path, source)
          scan_env_vars(source)
        end)
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
  The env var names read (outside comments) in the given source text.

  Matched over the WHOLE source, not line by line: `mix format` wraps a long argument onto
  its own line, and a per-line match then sees no read at all — reporting a variable that
  is read at runtime, and absent from the docs, as fine.
  """
  @spec scan_env_vars(binary()) :: MapSet.t(binary())
  def scan_env_vars(source) do
    ~r/System\.(?:get_env|fetch_env!)\(\s*"([A-Z][A-Z0-9_]*)"/
    |> Regex.scan(strip_comments(source), capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  @doc """
  Whether `source` passes `System.get_env/1` a name the scan cannot resolve — a variable,
  a concatenation, or a literal carrying interpolation.
  """
  @spec dynamic_read?(binary()) :: boolean()
  def dynamic_read?(source) do
    # Anything that is not a complete uppercase literal argument. The `\s*` is atomic so
    # the engine cannot backtrack into a wrapped-but-literal call; `...` is prose.
    String.match?(
      strip_comments(source),
      ~r/System\.(?:get_env|fetch_env!)\((?>\s*)(?!(?:"[A-Z][A-Z0-9_]*"\s*[,)]|\.\.\.))/
    )
  end

  defp check_dynamic_reads(path, source) do
    if dynamic_read?(source) and not Map.has_key?(@dynamic_read_sources, path) do
      Mix.raise(
        "check_env_docs: #{path} reads an env var by a name built at runtime, which no " <>
          "textual scan can resolve — so the guard would pass over it in silence (#566). " <>
          "Document the FAMILY in #{@docs_file} (members and defaults), then add " <>
          "#{path} to @dynamic_read_sources with that reason."
      )
    end
  end

  defp check_not_vacuous(vars, pattern, min) do
    if MapSet.size(vars) < min do
      Mix.raise(
        "check_env_docs scanned #{pattern} and found only #{MapSet.size(vars)} env " <>
          "var(s), expected at least #{min}. Unless this change deliberately MOVED " <>
          "reads to another scanned source (lower both floors together, in this same " <>
          "commit), that source's scan is broken — fix it rather than lowering the " <>
          "floor, or this guard passes vacuously for #{pattern}."
      )
    end

    vars
  end

  # Everything from a `#` to end of line, EXCEPT interpolation. A TRAILING comment matters
  # as much as a whole-line one now that all of lib/ is scanned: an aside like
  # `cap = default() # override with System.get_env("EXAMPLE")` would otherwise fail the
  # build demanding a row for a variable nothing reads.
  defp strip_comments(source), do: String.replace(source, ~r/\#(?!\{)[^\n]*/, "")

  # The name must head a markdown table row whose next two cells are non-blank: the row
  # anchor keeps a passing mention from standing in for a default and a description (the
  # `STH_SWEEP_CRON` note in the moduledoc), and the cells having to carry something keeps
  # a bare `| `VAR` |  |  |` from being the cheapest way past a failing guard. Whole-word
  # anchoring also keeps `POOL_SIZE` off an unrelated `ADMIN_POOL_SIZE` row.
  defp documented?(docs, var) do
    String.match?(docs, ~r/^\|\s*`#{Regex.escape(var)}`\s*\|\s*[^|\s][^|]*\|\s*[^|\s]/m)
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
