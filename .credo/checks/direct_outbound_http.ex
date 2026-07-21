defmodule Loopctl.Credo.Check.DirectOutboundHttp do
  @moduledoc """
  Custom Credo check (US-41.4, AC-41.4.4): the egress-chokepoint guard.

  Every model-provider egress must route through `Loopctl.Provider.post/3`, the
  single mandatory chokepoint that applies the fail-closed `local_only` egress
  guard. This check makes "no new direct outbound HTTP call outside the wrapper's
  explicit allowlist" a STANDING CI property: if a future edit adds a raw
  `Req.post` (or `Finch.request`, `Mint.HTTP.*`, `:httpc.request`,
  `:gen_tcp.connect`, `:ssl.connect`, ...) somewhere new, `mix credo --strict`
  fails at PR time, not in prod.

  The detection logic and the module allowlist live in
  `Loopctl.Egress.ChokepointScan` — the ExUnit chokepoint test calls the SAME
  functions, so the lint and the test can never drift. `.credo.exs` `require`s
  that source (it is stdlib-only) so Credo can load it standalone; the check
  itself lives OUTSIDE `lib/` so `mix compile` never drags it into a release.

  RESIDUAL GAP (documented, not implied away): the check cannot see HTTP
  performed INSIDE a dependency, and it does not cover the separate `mcp-server/`
  codebase. Guarantee wording everywhere is therefore narrowed to "every outbound
  HTTP call made by loopctl application code".
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Direct outbound HTTP calls bypass the fail-closed egress guard.

      Route the call through `Loopctl.Provider.post/3`. If it is genuinely not
      tenant-content model-provider egress, register the module (with a written
      justification) in `Loopctl.Egress.ChokepointScan`.
      """
    ]

  @impl true
  def run(%SourceFile{} = source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    filename = source_file.filename

    if Loopctl.Egress.ChokepointScan.scanned?(filename) do
      run_scan(source_file, issue_meta, filename)
    else
      []
    end
  end

  # The scanned-path list is CONFIGURABLE (default `lib/`). Credo's own `included`
  # covers `test/` too, but the chokepoint guarantee is about APPLICATION code —
  # test helpers legitimately open raw sockets to exercise the endpoint. Honouring
  # the same path list the ExUnit scan uses keeps the two exactly in step.
  defp run_scan(source_file, issue_meta, filename) do
    source_file
    |> SourceFile.source()
    |> Loopctl.Egress.ChokepointScan.violations(filename)
    |> Enum.map(fn violation ->
      format_issue(issue_meta,
        message: Loopctl.Egress.ChokepointScan.message(violation),
        trigger: violation.call,
        line_no: violation.line
      )
    end)
  end
end
