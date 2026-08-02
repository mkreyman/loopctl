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
      `hnsw.ef_search` "123" -> "" and `statement_timeout` restored, one statement). That
      proof comes from the capture; when the capture round trip itself FAILS we have no
      such proof, so the fallback RESETS every name this scope sets — and ABORTS instead when
      an enclosing `scoped/3` owns one, where reset clobbers and silence leaks (`active_names/0`).
    * GUC names cannot be bound as query parameters, so they are interpolated — and
      therefore validated against `@guc_name` first. Values always go through as parameters.
    * restore runs in an `after` and capture BEFORE the `try`. Both are BEST-EFFORT and
      catch EXITs as well as raises (Postgrex EXITs when the pool is down or wedged). The
      restore statement additionally runs `mode: :savepoint`, so a SERVER-side error is
      rolled back to its own savepoint instead of aborting the caller's transaction —
      rescuing the Elixir exception alone would leave a 25P02 that destroys an
      already-computed result at COMMIT.
  """

  require Logger

  @doc """
  Capture `names`, run `fun`, then restore the captured values. MUST be called inside a
  transaction on `repo`; `fun` issues its own `SET LOCAL`s.
  """
  @spec scoped(module(), [String.t()], (-> result)) :: result when result: var
  def scoped(repo, names, fun) when is_list(names) do
    validate_names!(names)
    enclosing = active_names()

    prior =
      case do_capture(repo, names) do
        {:ok, pairs} -> pairs
        :error -> capture_fallback!(names, enclosing)
      end

    put_active_names(enclosing ++ names)

    try do
      fun.()
    after
      # `restore/2` pops what `capture/2` pushed (the hand-paired form), so it runs FIRST and
      # the reset to `enclosing` is the final word — an inner pop must not erase an outer
      # scope's ownership of the same name.
      restore(repo, prior)
      put_active_names(enclosing)
    end
  end

  # A capture failure leaves us no prior values, so the fallback cannot RESTORE. For a name
  # nobody else owns, RESETTING it (`set_config(name, NULL, true)` → the backend default) is
  # sound. For a name an ENCLOSING scope owns it is not: we do not know the value that scope
  # set (its `fun` issued the `SET LOCAL`, not us), so a reset strips the outer read's
  # deliberate `statement_timeout` bound or its elevated `hnsw.ef_search`, while silence leaks
  # OUR value into the rest of its body — the 57014-far-from-the-query failure this module
  # exists to prevent. `capture_fallback!/2` takes neither branch: it aborts before the body
  # sets anything, and the rollback discards every `SET LOCAL` the transaction made. A wedged
  # capture means a wedged connection anyway; `Knowledge.BulkOps.timeout_multi/0` errs alike.
  # This stack records every name a LIVE scope holds: `scoped/3` pushes for its body; the
  # hand-paired form pushes in `capture/2` and pops in `restore/2` — or in `forget/1` on an
  # abort path `restore/2` can never reach, which is why `BulkOps` counts too. It is a
  # per-PROCESS approximation of a per-CONNECTION fact (a dynamic nesting through an opaque
  # `fun` can observe nothing finer) and diverges only CONSERVATIVELY or vanishingly rarely:
  # an owner on ANOTHER repo's connection makes us abort a read we could have reset (safe,
  # never a leak), and a sandbox-allowed `Task` sharing the owner's checkout sees an empty
  # stack (it would reset a name the owner holds — only if that Task's capture also fails).
  @active_names_key {__MODULE__, :active_names}

  defp active_names, do: Process.get(@active_names_key, [])
  defp put_active_names([]), do: Process.delete(@active_names_key)
  defp put_active_names(names), do: Process.put(@active_names_key, names)

  defp capture_fallback!(names, enclosing) do
    case Enum.filter(names, &(&1 in enclosing)) do
      [] ->
        Enum.map(names, &{&1, nil})

      owned ->
        # A `DBConnection.ConnectionError`, NOT a bare RuntimeError. This path fires only
        # when the capture round-trip itself failed, which means the connection is already
        # wedged — the same condition `Knowledge.BulkOps.timeout_multi/0` raises this exact
        # struct for, and which `LoopctlWeb.FallbackController` maps to the US-27.3 503 +
        # `Retry-After` rather than an unstructured 500. Two call sites reaching the same
        # conclusion about the same failure should not hand the client two different answers,
        # one of which tells it never to retry something that is purely transient.
        raise DBConnection.ConnectionError,
              "LocalGuc: could not capture #{inspect(owned)}, which an enclosing scope " <>
                "already overrode — refusing to set an override this transaction cannot " <>
                "take back (see the moduledoc)"
    end
  end

  # A GUC name is INTERPOLATED (Postgres will not bind an identifier as a parameter), so it
  # is checked against Postgres's own GUC shape first. Every caller passes a module-local
  # literal today, but nothing in the `[String.t()]` spec ENFORCED that.
  @guc_name ~r/\A[a-z_][a-z0-9_]*(\.[a-z_][a-z0-9_]*)?\z/

  defp validate_names!(names) do
    case Enum.reject(names, &valid_guc_name?/1) do
      [] -> :ok
      bad -> raise ArgumentError, "LocalGuc: invalid GUC name(s) #{inspect(bad)}"
    end
  end

  defp valid_guc_name?(name), do: is_binary(name) and Regex.match?(@guc_name, name)

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
  The prior values of `names`, as `[{name, value_or_nil}]`. MUST be called inside a
  transaction on `repo`: the round trip runs `mode: :savepoint`, which Postgrex refuses on
  an idle connection, so an out-of-transaction call degrades to `[]` like any other failure.
  One round trip; a BACKEND failure never raises, it degrades to `[]`, which makes `restore/2`
  a no-op. An invalid GUC name is a programmer error and DOES raise `ArgumentError`.

  A successful capture registers `names` on the active-scope stack, popped by `restore/2` or
  `forget/1` (see `active_names/0`), so a nested `scoped/3` sees this scope's overrides.

  Prefer `scoped/3`: a caller that pairs this with `restore/2` by hand gets NO restoration
  when the capture fails, which is the leak `scoped/3`'s fallback exists to close.
  """
  @spec capture(module(), [String.t()]) :: [{String.t(), String.t() | nil}]
  def capture(repo, names) do
    validate_names!(names)

    case do_capture(repo, names) do
      {:ok, pairs} ->
        put_active_names(active_names() ++ names)
        pairs

      :error ->
        []
    end
  end

  @doc """
  Drop `names` from the active-scope stack: no round trip, nothing restored, and a no-op for
  a name `restore/2` already popped.

  For the hand-paired form on an abort path `restore/2` can never reach (an `Ecto.Multi` whose
  restore step is skipped because an earlier one errored). The rollback already discarded every
  `SET LOCAL`, so only the bookkeeping is left — and it MUST be cleared, or a later `scoped/3`
  on that reused process sees a phantom owner and ABORTS a read it could safely have reset.
  """
  @spec forget([String.t()]) :: :ok
  def forget(names) when is_list(names) do
    put_active_names(active_names() -- names)
    :ok
  end

  # `{:ok, pairs} | :error`, so `scoped/3` can tell "nothing to capture" apart from "the
  # round trip failed" — two states the public `capture/2` collapses into `[]`, which is
  # what let a failed capture silently disable restoration.
  @spec do_capture(module(), [String.t()]) :: {:ok, [{String.t(), String.t() | nil}]} | :error
  defp do_capture(_repo, []), do: {:ok, []}

  defp do_capture(repo, names) do
    # Names are interpolated (an identifier cannot be bound), so both public entry points
    # ran them through `validate_names!/1` first.
    selects = Enum.map_join(names, ", ", &"current_setting('#{&1}', true)")

    # `mode: :savepoint`, matching `restore/2` and for the same reason, harder here because
    # this runs BEFORE the caller's work: without it a failure on this round trip leaves the
    # enclosing transaction aborted (25P02), so every later statement in the caller's Multi
    # fails over a query it never issued. With it, the failure rolls back to its own savepoint
    # and `capture_failed/2` returns `:error` to a transaction that is still usable.
    %{rows: [values]} = repo.query!("SELECT #{selects}", [], mode: :savepoint)
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
  Put back what `capture/2` read. Best-effort: a failure here never propagates — including
  an invalid GUC name, which is caught by the rescue below and logged rather than raised, so
  a bad name can neither reach the SQL nor destroy the caller's already-computed result.
  """
  @spec restore(module(), [{String.t(), String.t() | nil}]) :: :ok
  def restore(_repo, []), do: :ok

  def restore(repo, prior) do
    validate_names!(names_of(prior))
    put_active_names(active_names() -- names_of(prior))

    # A nil value is passed THROUGH as a NULL parameter, which resets the GUC to its
    # default. See the moduledoc: nil means "unknown to this backend", so resetting is
    # both correct and the only way the pgvector knobs get cleaned up at all. An EMPTY
    # STRING is normalised to nil (reset) for the same reason: that is how an
    # already-reset custom GUC reads back — `set_config(name, NULL, true)` leaves the
    # placeholder as "" — and writing "" BACK to a typed pgvector GUC raises
    # `invalid value for parameter "hnsw.iterative_scan"`.
    {names, values} = Enum.unzip(prior)
    values = Enum.map(values, fn value -> if value == "", do: nil, else: value end)

    sets =
      names
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {name, i} -> "set_config('#{name}', $#{i}, true)" end)

    # `mode: :savepoint`: a server-side error here rolls back to its own savepoint instead
    # of ABORTING the caller's transaction. The rescue below only unwinds the BEAM side —
    # a poisoned (25P02) transaction would still fail the caller's COMMIT and discard an
    # already-computed result, which is precisely what best-effort must not do.
    repo.query!("SELECT #{sets}", values, mode: :savepoint)
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
    case failure_tag(reason) do
      # 25P02 means the caller's transaction was ALREADY aborted when we got here (the body
      # raised — most often a 57014 cancel). Its rollback discards the body's `SET LOCAL`
      # anyway, so nothing can leak; warning about a leak on that path fires once per failed
      # read during a timeout storm and points a triaging operator at the wrong subsystem.
      "postgres_in_failed_sql_transaction" = tag ->
        Logger.debug("LocalGuc: restore skipped for #{inspect(names)} (#{tag})")

      tag ->
        Logger.warning(
          "LocalGuc: restore failed for #{inspect(names)} (#{tag}) — " <>
            "those settings may leak past this transaction's savepoint"
        )
    end

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
  defp failure_tag(reason) when is_atom(reason), do: to_string(reason)
  # DBConnection/Postgrex EXIT with a TUPLE — `{:timeout, {GenServer, :call, _}}` when the
  # pool is wedged, `{:noproc, _}` when it is not started — which IS the wedged-pool moment
  # this tag exists for. Without these the real shapes all degraded to "unknown". Mirrors
  # `HeavyRead.exit_tag/1`.
  defp failure_tag({reason, _details}) when is_atom(reason), do: to_string(reason)
  defp failure_tag(_reason), do: "unknown"
end
