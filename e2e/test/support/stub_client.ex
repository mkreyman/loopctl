defmodule LoopctlE2e.StubClient do
  @moduledoc """
  A scripted `LoopctlE2e.Client` for the unit tests. Each `{service, method, path}` holds a
  list of answers; a call takes the next one, and the last repeats, so "pending, pending,
  done" is three entries. A call with no script answers 404. Every call is recorded.
  """

  @behaviour LoopctlE2e.Client

  @doc "Starts a stub under the test's supervisor and returns the client tuple."
  def start(script) do
    {:ok, pid} = Agent.start_link(fn -> %{script: script, calls: []} end)
    {__MODULE__, pid}
  end

  @doc "The calls made, oldest first."
  def calls({__MODULE__, pid}), do: Agent.get(pid, &Enum.reverse(&1.calls))

  @impl true
  def get(pid, service, path, params), do: answer(pid, {service, :get, path}, params)

  @impl true
  def post(pid, service, path, body), do: answer(pid, {service, :post, path}, body)

  @impl true
  def put(pid, service, path, body), do: answer(pid, {service, :put, path}, body)

  defp answer(pid, key, arg) do
    Agent.get_and_update(pid, fn state ->
      {reply, rest} =
        case Map.get(state.script, key, []) do
          [] -> {{:ok, 404, %{}}, []}
          [last] -> {last, [last]}
          [next | rest] -> {next, rest}
        end

      {reply,
       %{state | script: Map.put(state.script, key, rest), calls: [{key, arg} | state.calls]}}
    end)
  end
end
