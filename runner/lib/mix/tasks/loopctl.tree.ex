defmodule Mix.Tasks.Loopctl.Tree do
  @shortdoc "Prints a run's trace as the agent tree its parent links describe"

  @moduledoc """
      mix loopctl.tree RUN_DIR_OR_TRACE_FILE

  Exits 1 when the trace does not parse or a `parent` link dangles.
  """

  use Mix.Task

  alias LoopctlRunner.Trace

  @impl Mix.Task
  def run([target]) do
    path = if File.dir?(target), do: Path.join(target, "trace.ndjson"), else: target

    with {:ok, events} <- Trace.read(path),
         {:ok, roots} <- Trace.tree(events) do
      Enum.each(roots, &print(&1, 0))
    else
      {:error, reason} ->
        Mix.shell().error("invalid trace #{path}: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  def run(_), do: Mix.raise("usage: mix loopctl.tree RUN_DIR_OR_TRACE_FILE")

  defp print(%{event: event, children: children}, depth) do
    Mix.shell().info([
      String.duplicate("  ", depth),
      "#{event["seq"]} ",
      event["type"],
      label(event["data"])
    ])

    Enum.each(children, &print(&1, depth + 1))
  end

  defp label(%{"name" => name}) when is_binary(name), do: " name=" <> name
  defp label(%{"reason" => reason}) when is_binary(reason), do: " reason=" <> reason
  defp label(_), do: ""
end
