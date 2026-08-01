defmodule Loopctl.LocalGuc do
  @moduledoc """
  `SET LOCAL` that does not LEAK past a committed savepoint.

  `SET LOCAL` is scoped to the TOP-LEVEL transaction, not to a savepoint. A nested
  `Repo.transaction/1` opens a savepoint, and a savepoint that COMMITS merges our override
  into the enclosing transaction — every later statement there (a plain INSERT, an
  inline-Oban write, another read) then silently inherits an aggressive
  `statement_timeout` and 57014s under load, far from the query that set it. Under
  `Ecto.Adapters.SQL.Sandbox` EVERY such transaction is nested inside the test's, which is
  where it bites hardest (a 250ms deadline armed over the rest of the test).

  `scoped/3` captures the prior values and puts them back on the way out, so the override
  is confined to the body that asked for it. Notes on the mechanics:

    * capture uses `current_setting(name, true)` (missing_ok), NOT `SHOW`: a pgvector
      custom GUC (`hnsw.*`) is unknown to a backend that has not loaded the extension yet,
      and `SHOW` RAISES there while `current_setting/2` returns NULL. A raise would abort
      the caller's transaction over a bookkeeping read.
    * restore is `set_config(name, value, true)` — transaction-local, so it cannot CLOBBER
      a deliberate outer `SET LOCAL` the way a session-level `RESET` would (e.g. a caller
      that wrapped several reads in one transaction under its own deadline).
    * a GUC captured as NULL is reset, NOT skipped. NULL from `current_setting(name, true)`
      means the GUC was UNKNOWN to that backend — a known GUC always reports its default
      rather than NULL — so by construction there is no outer value to clobber, and
      skipping it left exactly the leak this module exists to prevent: the pgvector `hnsw.*`
      knobs are unknown until the extension loads, so on a fresh backend EVERY `hnsw`
      override survived the savepoint. `set_config` with a NULL parameter resets to the
      default in the same single round trip as the valued ones (verified against PG 18:
      `hnsw.ef_search` "123" -> "" and `statement_timeout` restored, one statement).
    * restore runs in an `after` and capture BEFORE the `try`. Both are BEST-EFFORT and
      catch EXITs as well as raises (Postgrex EXITs when the pool is down or wedged), so
      neither can abort the caller's read, mask an error, or destroy a successful result.
  """

  require Logger

  @doc """
  Capture `names`, run `fun`, then restore the captured values. MUST be called inside a
  transaction on `repo`; `fun` issues its own `SET LOCAL`s.
  """
  @spec scoped(module(), [String.t()], (-> result)) :: result when result: var
  def scoped(repo, names, fun) when is_list(names) do
    # When capture FAILS we do not know the prior values — but we do know `fun` is about
    # to override these GUCs, and leaving that override in place is the leak. So fall back
    # to restoring them to their DEFAULTS (a nil value per name, which `restore/2` sends as
    # a NULL parameter). Previously a failed capture degraded to `[]`, `restore/2` then had
    # nothing to do, and the body's `SET LOCAL` survived the savepoint silently — the
    # module reverting to precisely the behaviour it was written to fix, in the one
    # situation where nothing was watching.
    #
    # Resetting to default is a strictly better wrong answer than leaving an aggressive
    # inner override in the enclosing transaction, and this stays best-effort: a failed
    # capture must not abort the caller's read.
    prior =
      case do_capture(repo, names) do
        {:ok, pairs} -> pairs
        :error -> Enum.map(names, &{&1, nil})
      end

    try do
      fun.()
    after
      restore(repo, prior)
    end
  end

  @doc """
  A `repo.transaction/2` whose body runs under `SET LOCAL statement_timeout = ms`, scoped
  so the override does not outlive the body (see the moduledoc).
  """
  @spec timed_transaction(module(), pos_integer(), (-> any()), keyword()) ::
          {:ok, any()} | {:error, any()}
  def timed_transaction(repo, ms, fun, opts \\ []) when is_integer(ms) and ms > 0 do
    repo.transaction(
      fn ->
        scoped(repo, ["statement_timeout"], fn ->
          repo.query!("SET LOCAL statement_timeout = #{ms}")
          fun.()
        end)
      end,
      opts
    )
  end

  @doc """
  The prior values of `names`, as `[{name, value_or_nil}]`. One round trip; never raises —
  a failure degrades to `[]`, which makes `restore/2` a no-op.
  """
  @spec capture(module(), [String.t()]) :: [{String.t(), String.t() | nil}]
  def capture(repo, names) do
    case do_capture(repo, names) do
      {:ok, pairs} -> pairs
      :error -> []
    end
  end

  # `{:ok, pairs} | :error`, so `scoped/3` can tell "nothing to capture" apart from "the
  # round trip failed" — two states the public `capture/2` collapses into `[]`, which is
  # what let a failed capture silently disable restoration.
  @spec do_capture(module(), [String.t()]) :: {:ok, [{String.t(), String.t() | nil}]} | :error
  defp do_capture(_repo, []), do: {:ok, []}

  defp do_capture(repo, names) do
    # Names are module-local literals from the callers below, never user input.
    selects = Enum.map_join(names, ", ", &"current_setting('#{&1}', true)")
    %{rows: [values]} = repo.query!("SELECT #{selects}")
    {:ok, Enum.zip(names, values)}
  rescue
    error -> capture_failed(names, error)
  catch
    :exit, reason -> capture_failed(names, reason)
  end

  # The unknown-GUC case cannot raise, but the ROUND TRIP can, before the `try` protects
  # it. The reason is logged as a stable TAG, never `inspect(reason)`: a `Postgrex.Error`
  # or `DBConnection.ConnectionError` carries the backend host, database and role, and
  # this line is reachable from any wedged-pool moment on an ordinary read path.
  defp capture_failed(names, reason) do
    Logger.warning("LocalGuc: could not capture #{inspect(names)} (#{failure_tag(reason)})")
    :error
  end

  @doc """
  Put back what `capture/2` read. Best-effort: a failure here never propagates.
  """
  @spec restore(module(), [{String.t(), String.t() | nil}]) :: :ok
  def restore(_repo, []), do: :ok

  def restore(repo, prior) do
    # A nil value is passed THROUGH as a NULL parameter, which resets the GUC to its
    # default. See the moduledoc: nil means "unknown to this backend", so resetting is
    # both correct and the only way the pgvector knobs get cleaned up at all.
    {names, values} = Enum.unzip(prior)

    sets =
      names
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {name, i} -> "set_config('#{name}', $#{i}, true)" end)

    repo.query!("SELECT #{sets}", values)
    :ok
  rescue
    error -> restore_failed(names_of(prior), error)
  catch
    :exit, reason -> restore_failed(names_of(prior), reason)
  end

  # Still best-effort — a restore failure must never destroy the caller's successful
  # result — but no longer SILENT. Swallowing this returned the caller to the exact
  # leaking behaviour the module exists to prevent, with nothing in the logs to say so, so
  # a reopened leak could only ever be diagnosed from its distant symptom (a stray
  # `statement_timeout` producing 57014s in an unrelated query). Logged as a stable tag,
  # never `inspect(reason)`: a Postgrex/DBConnection error carries the backend host,
  # database and role.
  defp restore_failed(names, reason) do
    Logger.warning(
      "LocalGuc: restore failed for #{inspect(names)} (#{failure_tag(reason)}) — " <>
        "those settings may leak past this transaction's savepoint"
    )

    :ok
  end

  defp names_of(prior), do: Enum.map(prior, fn {name, _value} -> name end)

  # A stable, low-cardinality classification. Deliberately NOT the raw error: see
  # `restore_failed/2`.
  defp failure_tag(%Postgrex.Error{postgres: %{code: code}}), do: "postgres_#{code}"
  defp failure_tag(%Postgrex.Error{}), do: "postgres_error"
  defp failure_tag(%DBConnection.ConnectionError{}), do: "connection_error"
  defp failure_tag(%DBConnection.OwnershipError{}), do: "ownership_error"
  defp failure_tag(%{__exception__: true} = e), do: "exception_#{inspect(e.__struct__)}"
  defp failure_tag(:noproc), do: "noproc"
  defp failure_tag(reason) when is_atom(reason), do: to_string(reason)
  defp failure_tag(_reason), do: "unknown"
end
