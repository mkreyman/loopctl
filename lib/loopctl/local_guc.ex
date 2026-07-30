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
    * restore is `SET LOCAL` (not `RESET`): `RESET` drops to the session/role default and
      would CLOBBER a deliberate outer `SET LOCAL` — e.g. a caller that wrapped several
      reads in one transaction under its own deadline. A GUC that had no value (NULL) is
      left alone.
    * restore runs in an `after`, and is BEST-EFFORT: on the failure path the transaction
      is already aborted (or rolling back, which restores the GUCs itself), so a failing
      restore must never mask the real error or destroy a successful result.
  """

  @doc """
  Capture `names`, run `fun`, then restore the captured values. MUST be called inside a
  transaction on `repo`; `fun` issues its own `SET LOCAL`s.
  """
  @spec scoped(module(), [String.t()], (-> result)) :: result when result: var
  def scoped(repo, names, fun) when is_list(names) do
    prior = capture(repo, names)

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
  The prior values of `names`, as `[{name, value_or_nil}]`. One round trip; never raises on
  an unknown GUC.
  """
  @spec capture(module(), [String.t()]) :: [{String.t(), String.t() | nil}]
  def capture(_repo, []), do: []

  def capture(repo, names) do
    # Names are module-local literals from the callers below, never user input.
    selects = Enum.map_join(names, ", ", &"current_setting('#{&1}', true)")
    %{rows: [values]} = repo.query!("SELECT #{selects}")
    Enum.zip(names, values)
  end

  @doc """
  Put back what `capture/2` read. Best-effort: a failure here never propagates.
  """
  @spec restore(module(), [{String.t(), String.t() | nil}]) :: :ok
  def restore(repo, prior) do
    case Enum.reject(prior, fn {_name, value} -> is_nil(value) end) do
      [] ->
        :ok

      pairs ->
        {names, values} = Enum.unzip(pairs)

        sets =
          names
          |> Enum.with_index(1)
          |> Enum.map_join(", ", fn {name, i} -> "set_config('#{name}', $#{i}, true)" end)

        repo.query!("SELECT #{sets}", values)
        :ok
    end
  rescue
    _ -> :ok
  end
end
