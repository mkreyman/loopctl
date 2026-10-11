defmodule Loopctl.Test.RowLock do
  @moduledoc """
  One COMMITTED row held `FOR UPDATE` by a SEPARATE database session, on its own raw Postgrex
  connection rather than a sandbox one: the sandbox owner's connection is the one the test
  process already runs on, and a lock cannot be held against yourself. The connection is
  linked to the caller, so it dies with the test even if `release/1` is never reached.

  The row must be committed, or the other session cannot see it to lock it.
  """

  alias Loopctl.AdminRepo

  @doc """
  Opens a transaction on a new connection and locks the row of `table` whose `id` is `id`.
  Returns the connection, to be passed to `release/1`.

  `num_rows` is asserted: a lock on nothing blocks nothing, and the code under test would then
  succeed for the ordinary reason and the test would prove nothing at all.

  RETRIED, up to five attempts a second apart: this asks the server for one more connection
  at the moment the suite holds the most, so `too_many_clients` is a property of WHEN the test
  runs, not of what it asserts. The failed connection is stopped before the retry: retrying
  while HOLDING one is the opposite of waiting for room.
  """
  @spec hold!(String.t(), Ecto.UUID.t()) :: pid()
  def hold!(table, id), do: hold!(table, id, 5)

  defp hold!(table, id, attempts_left) do
    config = Application.get_env(:loopctl, AdminRepo)

    {:ok, conn} =
      Postgrex.start_link(
        hostname: config[:hostname] || "127.0.0.1",
        port: config[:port] || 5432,
        username: config[:username],
        password: config[:password],
        database: config[:database],
        pool_size: 1
      )

    try do
      Postgrex.query!(conn, "BEGIN", [], timeout: 10_000)

      %Postgrex.Result{num_rows: 1} =
        Postgrex.query!(conn, "SELECT id FROM #{table} WHERE id = $1 FOR UPDATE", [
          Ecto.UUID.dump!(id)
        ])

      conn
    rescue
      error in [DBConnection.ConnectionError, Postgrex.Error] ->
        GenServer.stop(conn)

        if attempts_left > 1 do
          Process.sleep(1_000)
          hold!(table, id, attempts_left - 1)
        else
          reraise error, __STACKTRACE__
        end
    end
  end

  @doc "Rolls the holding transaction back, releasing the lock, and closes the connection."
  @spec release(pid()) :: :ok
  def release(conn) do
    Postgrex.query!(conn, "ROLLBACK", [])
    GenServer.stop(conn)
  end
end
