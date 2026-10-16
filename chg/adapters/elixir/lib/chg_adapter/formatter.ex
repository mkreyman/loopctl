defmodule ChgAdapter.Formatter do
  @moduledoc """
  An ExUnit formatter that appends one JSON line per finished test to the file named by
  `CHG_RESULTS`. `mix chg.run` adds it next to the normal CLI formatter, and calls
  `sync/0` after the run, because ExUnit delivers events to formatters by cast.
  """
  use GenServer

  @impl true
  def init(_opts) do
    Process.register(self(), __MODULE__)
    path = System.fetch_env!("CHG_RESULTS")
    {:ok, File.open!(path, [:append, :utf8])}
  end

  @doc "Waits until every event cast so far is written. A no-op once the formatter stopped."
  def sync do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :sync, :infinity)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def handle_call(:sync, _from, io), do: {:reply, :ok, io}

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{} = test}, io) do
    IO.puts(io, JSON.encode!(result(test)))
    {:noreply, io}
  end

  def handle_cast({:suite_finished, _}, io) do
    if io, do: File.close(io)
    {:noreply, nil}
  end

  def handle_cast(_event, io), do: {:noreply, io}

  @doc false
  def result(%ExUnit.Test{} = t) do
    file = Path.relative_to_cwd(t.tags[:file] || "unknown")

    %{
      id: "#{file}:#{t.tags[:line]}",
      status: status(t.state),
      ms: System.convert_time_unit(t.time, :microsecond, :millisecond)
    }
  end

  defp status(nil), do: "pass"
  defp status({:failed, _}), do: "fail"
  defp status({:skipped, _}), do: "skip"
  defp status({:excluded, _}), do: "skip"
  defp status({:invalid, _}), do: "error"
end
