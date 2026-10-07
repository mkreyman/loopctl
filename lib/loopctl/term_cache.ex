defmodule Loopctl.TermCache do
  @moduledoc """
  A namespaced, read-mostly value store: `:persistent_term` for the node, or an ETS table
  a caller owns.

  A namespace that is any term but an ETS table — `Loopctl.SystemConfig`, `Loopctl.HeavyRead`,
  `Loopctl.Telemetry.ScaleMetrics`, the node-wide namespaces production uses — stores
  `key` under the `:persistent_term` key `{namespace, key}`, exactly the key each of those
  modules used before this existed, so a production read stays one `:persistent_term.get/2`.

  A namespace that IS an ETS table (`:ets.new/2` returns a reference) stores `key` in that
  table. That is the namespace a test hands the code under test: it holds only that test's
  values, costs no `:persistent_term` write (each of which copies the whole term table, and
  each overwrite or erase of which schedules a global GC), and is gone with no cleanup when
  the test process that owns it exits. A read from a table that is already gone answers the
  default, as a `:persistent_term` miss does.
  """

  @typedoc "A namespace: an ETS table a caller owns, or any other term (`:persistent_term`)."
  @type namespace :: :ets.tid() | term()

  @doc "The value under `key` in `namespace`, or `default`."
  @spec get(namespace(), term(), term()) :: term()
  def get(namespace, key, default) when is_reference(namespace) do
    case :ets.lookup(namespace, key) do
      [{^key, value}] -> value
      [] -> default
    end
  rescue
    ArgumentError -> default
  end

  def get(namespace, key, default), do: :persistent_term.get({namespace, key}, default)

  @doc "Stores `value` under `key` in `namespace`."
  @spec put(namespace(), term(), term()) :: :ok
  def put(namespace, key, value) when is_reference(namespace) do
    true = :ets.insert(namespace, {key, value})
    :ok
  end

  def put(namespace, key, value), do: :persistent_term.put({namespace, key}, value)

  @doc "Removes `key` from `namespace`."
  @spec erase(namespace(), term()) :: :ok
  def erase(namespace, key) when is_reference(namespace) do
    true = :ets.delete(namespace, key)
    :ok
  end

  def erase(namespace, key) do
    _ = :persistent_term.erase({namespace, key})
    :ok
  end
end
