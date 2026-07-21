defmodule Loopctl.Egress.ChokepointScan do
  @moduledoc """
  Static AST scan proving the egress chokepoint is MANDATORY, not conventional
  (US-41.4, AC-41.4.4).

  `Loopctl.Provider.Admission` was added site-by-site and is consequently missed
  at three outbound call sites today. A privacy guarantee enforced by per-call-site
  convention regresses the first time someone adds a `Req` call, so this scan is a
  STANDING CI property: `mix credo --strict` fails on any direct outbound HTTP
  call in the scanned paths outside the explicit allowlist below.

  This module is stdlib-only and deliberately dependency-free so `.credo.exs` can
  `require` its SOURCE and load it into Credo's VM standalone (the same mechanism
  `Loopctl.Knowledge.CosineLintExceptions` uses for the cosine check). The
  ExUnit test calls the very same functions, so the Credo check and the test can
  never drift.

  ## (i) Detected entry points

  `Req.post` / `Req.request` / `Req.get` / `Req.put` / `Req.patch` / `Req.delete`
  / `Req.new` **and their bang variants**, `Req.Request.run` /
  `Req.Request.run_request` (+ bang), `Finch.request` / `Finch.build` /
  `Finch.request!`, any `Mint.HTTP.*`, `:httpc.request`, `:gen_tcp.connect` and
  `:ssl.connect`.

  Alias heads are RESOLVED through the file's `alias` declarations before
  detection, so `alias Req, as: Http; Http.post(...)` and
  `alias Req.Request; Request.run(...)` are flagged, and a literal
  `apply(Req, :post, [...])` is flagged too. A detector that matched only literal
  alias heads would let the most idiomatic way of adding an HTTP call pass CI
  silently, which would reduce AC-41.4.4's "mandatory" to "conventional".

  ## (ii) The scanned path list is CONFIGURABLE

  Default `["lib"]`, overridable via `config :loopctl, :egress_scan_paths`. A
  negative-control fixture that lived OUTSIDE the scanned paths would make this
  control a no-op, so the test points the scan at
  `test/support/egress_fixtures`, where a module makes one raw call per detected
  entry point, and asserts every one is flagged.

  ## (iii) RESIDUAL GAP — documented, not papered over

  The scan cannot see HTTP performed inside a dependency (HTTP inside a dependency
  is invisible to an AST scan of this repo), and it does not cover
  the separate `mcp-server/` codebase. It also cannot see a call whose MODULE is
  computed at runtime (`mod = Req; mod.post(...)`, `apply(module_from_config(),
  :post, args)`) — alias resolution and literal `apply/3` are handled, a value
  flowing through a variable is not. Every guarantee statement in loopctl
  (docs, tool descriptions, posture report, the US-41.7 custody claim) is
  therefore narrowed to exactly what is proven:
  "every outbound HTTP call made by loopctl application code".

  ## Allowlist

  `Loopctl.Provider` is the wrapper itself. The remaining entries are the
  outbound calls that are NOT tenant-content model-provider egress; each carries
  its justification, and each is a known gap the epic addresses elsewhere.
  """

  # {module_name => justification}. An entry here exempts only the LINT; it does
  # NOT exempt the call from US-41.5's webhook guard or any future coverage.
  @allowed %{
    "Loopctl.Provider" =>
      "IS the chokepoint wrapper — the one sanctioned outbound provider call site.",
    "Loopctl.Webhooks.ReqDelivery" =>
      "Webhook delivery. Already SSRF-guarded (UrlGuard.pin + pinned_request_opts + " <>
        "redirect: false). Bringing it under the local_only guard is US-41.5, so this " <>
        "story's guarantee wording must NOT claim total egress control yet.",
    "Loopctl.Verification.GitHubActions" =>
      "Reads GitHub check-run status for verification. Operator-plane, fixed vendor " <>
        "host, carries no tenant content outbound.",
    "Loopctl.Secrets.FlyAdapter" =>
      "Operator-plane secret management against the Fly GraphQL API. Fixed host, not " <>
        "tenant-content egress, and never reachable from a tenant-supplied URL.",
    "Loopctl.CLI.Client" =>
      "The loopctl CLI talking to a loopctl server. Runs on the operator's machine, " <>
        "not in the server process, and sends no tenant KB content to a model provider."
  }

  # BANG variants are included deliberately. `Req.post!` / `Req.get!` are the
  # IDIOMATIC default, so a detection list of only the non-bang names would let the
  # single most likely way a future contributor adds a direct outbound call pass CI
  # silently — and this check is the only thing keeping the next call site from
  # regressing the AC-41.4.4 guarantee that the wrapper is MANDATORY rather than
  # per-call-site convention.
  @req_functions ~w(post request get put patch delete new post! request! get! put! patch! delete!)a
  @req_request_functions ~w(run run_request run! run_request!)a
  @finch_functions ~w(request build request!)a

  @type violation :: %{
          file: String.t(),
          line: non_neg_integer(),
          module: String.t(),
          call: String.t()
        }

  @doc "The module allowlist with justifications."
  @spec allowed() :: %{String.t() => String.t()}
  def allowed, do: @allowed

  @doc "The configurable scanned path list (default `[\"lib\"]`)."
  @spec default_paths() :: [String.t()]
  def default_paths do
    Application.get_env(:loopctl, :egress_scan_paths, ["lib"])
  end

  @doc """
  True when `file` lies under one of the configured scanned paths.

  The Credo check consults this so the lint covers exactly the same files the
  ExUnit scan does — Credo's own `included` list also covers `test/`, where a
  helper legitimately opens a raw socket to exercise the endpoint, and the
  chokepoint guarantee is about APPLICATION code.
  """
  @spec scanned?(String.t()) :: boolean()
  def scanned?(file) when is_binary(file) do
    normalized = Path.relative_to_cwd(file)
    Enum.any?(default_paths(), &String.starts_with?(normalized, Path.relative_to_cwd(&1) <> "/"))
  end

  @doc """
  Scans every `.ex` file under `paths` and returns the violations found.
  """
  @spec scan([String.t()] | nil) :: [violation()]
  def scan(paths \\ nil) do
    (paths || default_paths())
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
    |> Enum.uniq()
    |> Enum.flat_map(fn file ->
      case File.read(file) do
        {:ok, source} -> violations(source, file)
        {:error, _} -> []
      end
    end)
  end

  @doc """
  Returns the violations in `source` (attributed to `file`).

  Shared verbatim with the Credo check, so the lint and the test can never drift.
  """
  @spec violations(String.t(), String.t()) :: [violation()]
  def violations(source, file) do
    case Code.string_to_quoted(source, columns: true) do
      {:ok, ast} ->
        ast
        |> walk(nil, aliases(ast), [])
        |> Enum.reverse()
        |> Enum.map(&Map.put(&1, :file, file))

      {:error, _} ->
        []
    end
  end

  @doc """
  The file's `alias` declarations, as `local head => canonical parts`.

  Without this, `alias Req, as: Http; Http.post(...)` and
  `alias Req.Request; Request.run(...)` walk straight past a detector that matches
  only literal alias heads — and the idiomatic way to add an HTTP call to a module
  that already aliases things is exactly that. The map is FILE-scoped (a
  deliberate over-approximation for a lint: an alias in one module of a file is
  assumed for the rest of it, which can only ever over-report, never under-report).
  """
  @spec aliases(Macro.t()) :: %{atom() => [atom()]}
  def aliases(ast) do
    {_ast, collected} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, parts}, opts]} = node, acc when is_list(opts) ->
          {node, put_alias(acc, alias_as(opts) || List.last(parts), parts)}

        {:alias, _, [{:__aliases__, _, parts}]} = node, acc ->
          {node, put_alias(acc, List.last(parts), parts)}

        node, acc ->
          {node, acc}
      end)

    collected
  end

  defp put_alias(acc, nil, _parts), do: acc
  defp put_alias(acc, local, parts) when is_atom(local), do: Map.put(acc, local, parts)

  defp alias_as(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _, [name]} -> name
      _ -> nil
    end
  end

  @doc """
  The human-readable message for a violation — names the offending call and tells
  the author to route it through the wrapper.
  """
  @spec message(violation()) :: String.t()
  def message(%{call: call, module: module}) do
    "Direct outbound HTTP call `#{call}` in #{module}. Every model-provider egress " <>
      "must route through `Loopctl.Provider.post/3`, the single mandatory chokepoint " <>
      "that applies the fail-closed local_only egress guard (US-41.4). If this call is " <>
      "genuinely not tenant-content model-provider egress, register the module (with a " <>
      "justification) in `Loopctl.Egress.ChokepointScan`."
  end

  # --- AST walk -------------------------------------------------------------

  defp walk({:defmodule, _meta, [name_ast, body]}, module, aliases, acc) do
    inner = join_module(module, module_name(name_ast))
    walk(body, inner, aliases, acc)
  end

  # `apply(Req, :post, [...])` — a dynamic dispatch that names the module
  # literally is just as much a direct outbound call as `Req.post/1`.
  defp walk({:apply, meta, [target, fun, args]}, module, aliases, acc)
       when is_atom(fun) do
    acc =
      case detect(expand(target, aliases), fun) do
        nil -> acc
        call -> maybe_flag(module, "apply/3 -> " <> call, line(meta), acc)
      end

    walk(args, module, aliases, acc)
  end

  defp walk({{:., meta, [target, fun]}, _call_meta, args}, module, aliases, acc) do
    acc =
      case detect(expand(target, aliases), fun) do
        nil -> acc
        call -> maybe_flag(module, call, line(meta), acc)
      end

    walk(args, module, aliases, acc)
  end

  defp walk({form, _meta, args}, module, aliases, acc) do
    acc = walk(form, module, aliases, acc)
    walk(args, module, aliases, acc)
  end

  defp walk({left, right}, module, aliases, acc) do
    acc = walk(left, module, aliases, acc)
    walk(right, module, aliases, acc)
  end

  defp walk(list, module, aliases, acc) when is_list(list) do
    Enum.reduce(list, acc, &walk(&1, module, aliases, &2))
  end

  defp walk(_other, _module, _aliases, acc), do: acc

  # Rewrites an alias head through the file's `alias` declarations so the
  # detectors below only ever see CANONICAL parts.
  defp expand({:__aliases__, meta, [head | rest]}, aliases) when is_atom(head) do
    case Map.get(aliases, head) do
      nil -> {:__aliases__, meta, [head | rest]}
      parts -> {:__aliases__, meta, parts ++ rest}
    end
  end

  defp expand(other, _aliases), do: other

  defp maybe_flag(module, call, line, acc) do
    if is_binary(module) and Map.has_key?(@allowed, module) do
      acc
    else
      [%{line: line, module: module || "(unknown module)", call: call} | acc]
    end
  end

  # --- entry-point detection ------------------------------------------------

  defp detect({:__aliases__, _, [:Req]}, fun) when fun in @req_functions, do: "Req.#{fun}"

  defp detect({:__aliases__, _, [:Req, :Request]}, fun) when fun in @req_request_functions,
    do: "Req.Request.#{fun}"

  defp detect({:__aliases__, _, [:Finch]}, fun) when fun in @finch_functions, do: "Finch.#{fun}"

  defp detect({:__aliases__, _, [:Mint, :HTTP | _]}, fun), do: "Mint.HTTP.#{fun}"

  defp detect(:httpc, :request), do: ":httpc.request"
  defp detect(:gen_tcp, :connect), do: ":gen_tcp.connect"
  defp detect(:ssl, :connect), do: ":ssl.connect"
  defp detect(_target, _fun), do: nil

  # --- helpers --------------------------------------------------------------

  defp module_name({:__aliases__, _, parts}) do
    Enum.map_join(parts, ".", &to_string/1)
  end

  defp module_name(_other), do: nil

  defp join_module(nil, name), do: name
  defp join_module(outer, nil), do: outer
  defp join_module(outer, name), do: outer <> "." <> name

  defp line(meta) when is_list(meta), do: Keyword.get(meta, :line, 0)
  defp line(_meta), do: 0
end
