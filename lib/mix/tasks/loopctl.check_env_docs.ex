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
  (`"OBAN_QUEUE_" <> queue`), or read through a captured getter, cannot be resolved. Such a
  name is still an operator knob, so a dynamic read is not ignored: its file must be listed
  in `@dynamic_read_sources` NAMING the knobs it reads, and those names go through the same
  doc check as a literal — a whitelist carrying only a prose promise is #566 again.

  A literal read inside a `@moduledoc` IS detected (a docstring is not a comment), so name
  variables in prose as `System.get_env/1`, not as a fake call; the DYNAMIC check skips
  heredocs. Comments are stripped first — whole-line and trailing alike — but a `#` inside
  a string literal is NOT one, or the rest of that line would go unscanned.

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
  @exempt %{
    # NOT an operator variable, and documenting it would be worse than leaving it out.
    # `config/runtime.exs` states in as many words that there is intentionally no global
    # ANTHROPIC_API_KEY path for tenant LLM work — that is mandatory BYO, per tenant, via
    # `Loopctl.Llm.resolve/2`. This read is in `mix loopctl.retrieval.eval --record-rerank`,
    # a developer-only tool that records a rerank fixture against a THROWAWAY eval tenant
    # which by construction has no stored LLM settings. A row in FLY_SECRETS.md would tell
    # an operator to set a production secret that does nothing in production.
    "ANTHROPIC_API_KEY" =>
      "developer-only: read by mix loopctl.retrieval.eval --record-rerank against the " <>
        "eval's throwaway tenant. Tenant LLM work is mandatory-BYO with no global key path."
  }

  # Files that read env by a name built at RUNTIME (or through a captured getter), which no
  # textual scan can resolve. `{names, reason}` — each entry NAMES the knobs it reads and
  # those go through `documented?/2` like any literal, since a whitelist whose only content
  # is a prose claim is the unenforced promise #566 was. Any OTHER file's read FAILS.
  @dynamic_read_sources %{
    "lib/loopctl/oban_config.ex" =>
      {["OBAN_QUEUE_<QUEUE>", "OBAN_TENANT_FAIRSHARE_<QUEUE>"], "per-queue families"},
    "lib/loopctl/cli/config.ex" =>
      {["LOOPCTL_SERVER", "LOOPCTL_API_KEY", "LOOPCTL_FORMAT"],
       "names live in @env_overrides, read through an injected getter capture"},
    "lib/loopctl/secrets/fly_adapter.ex" =>
      {[], "per-tenant audit key names the app itself mints; never an operator knob"}
  }

  @impl Mix.Task
  def run(_args) do
    File.exists?(@docs_file) ||
      Mix.raise("check_env_docs: #{@docs_file} not found. Run from the repo root.")

    vars =
      Enum.reduce(@sources, dynamic_families(), fn {pattern, min}, acc ->
        pattern |> scan_paths() |> check_not_vacuous(pattern, min) |> MapSet.union(acc)
      end)

    report(undocumented(vars, File.read!(@docs_file)), MapSet.size(vars))
  end

  @doc "Declared dynamic-read names, doc-checked like literals so deleting their row fails."
  @spec dynamic_families() :: MapSet.t(binary())
  def dynamic_families do
    @dynamic_read_sources
    |> Enum.flat_map(fn {_path, {names, _reason}} -> names end)
    |> MapSet.new()
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
  Whether `source` reads env by a name the scan cannot resolve — a variable, a
  concatenation, an interpolated literal, or a captured getter argued elsewhere. Heredocs
  are stripped: prose DESCRIBING a call is not one. A literal of ANY case resolves, matching
  `scan_env_vars/1` — the two must agree or the build names a cause that is untrue.
  """
  @spec dynamic_read?(binary()) :: boolean()
  def dynamic_read?(source) do
    # `\s*` is atomic so the engine cannot backtrack into a wrapped-but-literal call.
    # A bare `)` is the zero-arity whole-environment read, which names no knob.
    stripped = source |> strip_comments() |> String.replace(~r/"""[\s\S]*?"""/, "")

    String.match?(
      stripped,
      ~r/System\.(?:get_env|fetch_env!)\((?>\s*)(?!(?:"[A-Za-z][A-Za-z0-9_]*"\s*[,)]|\)))/
    ) or String.match?(stripped, ~r{&System\.(?:get_env|fetch_env!)/1})
  end

  @doc """
  Raises unless a file with a dynamic read is declared in `@dynamic_read_sources`. Public
  so the RAISE is exercised: every real file with one is declared, so a guard driven through
  `scan_paths/1` alone is never observed failing.
  """
  @spec check_dynamic_reads(binary(), binary()) :: :ok
  def check_dynamic_reads(path, source) do
    if dynamic_read?(source) and not Map.has_key?(@dynamic_read_sources, path) do
      Mix.raise(
        "check_env_docs: #{path} reads an env var by a name built at runtime, which no " <>
          "textual scan can resolve — so the guard would pass over it in silence (#566). " <>
          "Document the name(s) in #{@docs_file} (defaults and effect), then add " <>
          "#{path} to @dynamic_read_sources naming them."
      )
    end

    :ok
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

  # Everything from a comment `#` to end of line, TRAILING as well as whole-line. A blanket
  # `#`-to-EOL replace cuts a line short at a `#` inside a literal (`"https://x/#/app"`)
  # and hides any read AFTER it — a silent miss, the shape this task exists to prevent. So
  # a `#` is a comment only OUTSIDE a string and at a token boundary (sparing `~r/…#…/`).
  defp strip_comments(source) do
    source
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      if String.contains?(line, "#"), do: strip_line(line, false, ""), else: line
    end)
  end

  defp strip_line(<<>>, _in_string, acc), do: acc

  defp strip_line(<<"\\", c::utf8, rest::binary>>, true, acc),
    do: strip_line(rest, true, <<acc::binary, "\\", c::utf8>>)

  defp strip_line(<<"\"", rest::binary>>, in_str, acc),
    do: strip_line(rest, not in_str, <<acc::binary, "\"">>)

  defp strip_line(<<"#", rest::binary>>, false, acc) do
    if acc == "" or String.last(acc) in [" ", "\t"],
      do: acc,
      else: strip_line(rest, false, <<acc::binary, "#">>)
  end

  defp strip_line(<<c::utf8, rest::binary>>, in_string, acc),
    do: strip_line(rest, in_string, <<acc::binary, c::utf8>>)

  # The name must head a markdown table row whose next two cells are non-blank: the row
  # anchor keeps a passing mention from standing in for a default and a description (the
  # `STH_SWEEP_CRON` note in the moduledoc), and the cells having to carry something keeps
  # a bare `| `VAR` |  |  |` from being the cheapest way past a failing guard. Whole-word
  # anchoring also keeps `POOL_SIZE` off an unrelated `ADMIN_POOL_SIZE` row. Cells exclude
  # `\n`: `[^|]` crosses rows, letting a row with no description borrow the next row's.
  defp documented?(docs, var) do
    String.match?(docs, ~r/^\|\s*`#{Regex.escape(var)}`\s*\|\s*[^|\s][^|\n]*\|\s*[^|\s]/m)
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
