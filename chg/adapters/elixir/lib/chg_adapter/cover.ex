defmodule ChgAdapter.Cover do
  @moduledoc """
  Records, during one `mix test` run, which project modules each test file executed: the
  coverage map that coverage selection (`ChgAdapter.Select.by_coverage/1`) reads.

  Every call into a project module from outside it is traced (`:global` patterns, in a
  trace session of its own, so a test that traces does not collide with it). Attribution
  is by time, not by process, so work a test hands to a GenServer, a Task, the Repo pool
  or a LiveView process is still counted: a test module owns every module touched between
  its `ExUnit.EventManager.module_started/2` call and its `module_finished/2` call. Async
  modules overlap, so a file is also credited with what its neighbours touched. That only
  ever selects more.

  The window is sound although trace messages from different processes arrive out of
  order: a window opens at the start call's own trace timestamp, a touch is stamped when
  the tracer handles it (never earlier than the call), and a window is closed only after
  `:trace.delivered/2` confirms every trace message up to its finish call was handled.

  Two kinds of touch count for every test, and a change to such a module selects the
  whole suite:
    * before the first test module started (application start, `test_helper.exs`);
    * from a process compiling a test file (a macro, a module attribute computed at
      compile time), which runs alongside tests and cannot be pinned to one file.
  """

  @started {ExUnit.EventManager, :module_started, 2}
  @finished {ExUnit.EventManager, :module_finished, 2}
  # The first call a `Kernel.ParallelCompiler` worker makes (Elixir 1.20.4).
  @compiler {Module.ParallelChecker, :put, 2}
  @test_module [{[:_, %{name: :"$1", file: :"$2"}], [], [{:message, {{:"$1", :"$2"}}}]}]

  # How long `stop/1` waits for the tracer to work through its queue.
  @stop_timeout :timer.minutes(10)

  @doc "Starts tracing calls into `modules`. Returns a handle for `stop/1`."
  def start(modules) do
    {mod, fun, arity} = @compiler

    unless Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity),
      do: raise("#{inspect(@compiler)} is gone: compile-time calls cannot be told apart")

    Code.ensure_all_loaded(modules)
    tracer = spawn(fn -> loop(new()) end)
    session = :trace.session_create(:chg_cover, tracer, [])
    send(tracer, {:session, session})

    for m <- modules, do: :trace.function(session, {m, :_, :_}, true, [:global])
    :trace.function(session, @compiler, true, [:global])
    :trace.function(session, @started, @test_module, [:global])
    :trace.function(session, @finished, @test_module, [:global])
    :trace.process(session, :all, true, [:call, :arity, :monotonic_timestamp])
    {session, tracer}
  end

  @doc """
  Stops tracing and returns `%{cover: %{file => [module]}, global: [module]}`. Files are
  relative to the working directory. A module still open (the run stopped at
  `--max-failures`) is closed with everything touched since it started.

  Raises when the tracer died or took longer than #{div(@stop_timeout, 60_000)} minutes,
  and when test modules ran but no process compiling a test file was seen (the probe for
  one no longer fits this Elixir, so compile-time calls would be misattributed).
  """
  def stop({session, tracer}) do
    :trace.process(session, :all, false, [:call])
    ref = make_ref()
    mon = Process.monitor(tracer)
    send(tracer, {:stop, self(), ref})

    receive do
      {^ref, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, _, _, why} ->
        raise "the coverage tracer died: #{inspect(why)}"
    after
      @stop_timeout ->
        Process.exit(tracer, :kill)
        raise "the coverage tracer did not finish in #{div(@stop_timeout, 60_000)} minutes"
    end
    |> check_compilers()
  after
    :trace.session_destroy(session)
  end

  defp check_compilers(%{cover: cover, compilers: n} = result) when map_size(cover) == 0 or n > 0,
    do: Map.delete(result, :compilers)

  defp check_compilers(_),
    do:
      raise(
        "no process compiling a test file was seen; #{inspect(@compiler)} no longer marks one"
      )

  defp new do
    %{
      session: nil,
      touched: :ets.new(:touched, [:set, :private]),
      first_start: nil,
      compilers: MapSet.new(),
      global: MapSet.new(),
      open: %{},
      closing: %{},
      cover: %{},
      cwd: File.cwd!()
    }
  end

  defp loop(s) do
    receive do
      msg -> msg |> handle(s) |> loop_or_reply()
    end
  end

  defp loop_or_reply({:reply, to, ref, result}), do: send(to, {ref, result})
  defp loop_or_reply(s), do: loop(s)

  defp handle({:session, session}, s), do: %{s | session: session}

  defp handle({:trace_ts, pid, :call, @compiler, _ts}, s),
    do: %{s | compilers: MapSet.put(s.compilers, pid)}

  defp handle({:trace_ts, _pid, :call, @started, {name, file}, ts}, s) do
    first = if s.first_start, do: min(s.first_start, ts), else: ts
    %{s | first_start: first, open: Map.put(s.open, name, {ts, file})}
  end

  defp handle({:trace_ts, _pid, :call, @finished, {name, _file}, _ts}, s) do
    ref = :trace.delivered(s.session, :all)
    %{s | closing: Map.update(s.closing, ref, [name], &[name | &1])}
  end

  defp handle({:trace_ts, pid, :call, {m, _f, _a}, ts}, s) do
    :ets.insert(s.touched, {m, System.monotonic_time()})

    if s.first_start == nil or ts < s.first_start or MapSet.member?(s.compilers, pid),
      do: %{s | global: MapSet.put(s.global, m)},
      else: s
  end

  defp handle({:trace_delivered, :all, ref}, s) do
    case Map.pop(s.closing, ref) do
      {nil, _} -> s
      {names, closing} -> Enum.reduce(names, %{s | closing: closing}, &close/2)
    end
  end

  defp handle({:stop, from, ref}, s) do
    delivered = :trace.delivered(s.session, :all)
    s = drain(s, delivered)
    s = Enum.reduce(Map.keys(s.open), s, &close/2)

    cover =
      Map.new(s.cover, fn {file, mods} -> {Path.relative_to(file, s.cwd), Enum.sort(mods)} end)

    {:reply, from, ref,
     %{cover: cover, global: Enum.sort(s.global), compilers: MapSet.size(s.compilers)}}
  end

  defp handle(_other, s), do: s

  # Handles everything up to `ref`'s confirmation, then every window still closing.
  defp drain(s, ref) do
    receive do
      {:trace_delivered, :all, ^ref} ->
        Enum.reduce(Map.values(s.closing), %{s | closing: %{}}, fn names, s ->
          Enum.reduce(names, s, &close/2)
        end)

      msg ->
        drain(handle(msg, s), ref)
    end
  end

  defp close(name, s) do
    case Map.pop(s.open, name) do
      {nil, _} ->
        s

      {{start, file}, open} ->
        mods = :ets.select(s.touched, [{{:"$1", :"$2"}, [{:>=, :"$2", start}], [:"$1"]}])
        cover = Map.update(s.cover, file, MapSet.new(mods), &Enum.into(mods, &1))
        %{s | open: open, cover: cover}
    end
  end
end
