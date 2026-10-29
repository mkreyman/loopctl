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

  Test files compile alongside the tests. A worker compiling one names it in its
  `:elixir_compiler.file/2` call, and that call to its return is a window for the file
  like a test module's, so a Task or GenServer call the compile makes (a module attribute
  computed at compile time) is credited to it. The worker's own touches (a macro, an
  attribute) go to its file alone, never to the windows of tests running meanwhile.

  Files are recorded the same way. Every `:file` and `:prim_file` call that names a path
  (read, open, stat, list a directory, follow a link), which is every way `File` and
  `Path.wildcard/1` reach the disk, is a read of that path by whichever windows are open,
  whether it was found or not. So is starting an operating-system process
  (`:erlang.open_port/2` with a command: `System.cmd/3`, `:os.cmd/1`), recorded as
  `{:spawn, name}`, because what a subprocess reads is not traced. Sockets and the resolver's
  `inet_gethost` are ports too, and are not spawns. The file server, the code server and
  the prim loader touch files for others, so their calls are not reads: the caller's
  `:file` call is.

  Reads are attributed by process where they can be, since async neighbours would
  otherwise share every read and subprocess. A test module's runner process starts its
  tests and `setup_all`, and every process started from one of those, transitively,
  belongs to that module's file from the moment it starts (`:procs` tracing); so does
  every process a compiling worker starts. A read by any other process (the Repo pool, a
  server the app started) is attributed by time, like a touch.

  A read under the build (`Mix.Project.build_path/0` at record time, so `build_path` in
  mix.exs and `MIX_BUILD_PATH` count, inside the repo or not) is of something compiled
  from the project, so it is recorded as what it was compiled from, never dropped:
    * a project module's beam (`lib/<app>/ebin/<Mod>.beam`, which a guard test reads to
      scan compiled code without running it) counts as executing that module, so the
      test depends on its digest;
    * a file under the app's `priv` there (what `:code.priv_dir/1` resolves to) is a
      read of the same path under the project's `priv`;
    * a dependency's build (`lib/<dep>/...`) is read as its source: a path dependency or
      umbrella sibling in the repo as its directory, its `priv` as the same path under
      that directory; a fetched dependency (Hex, git) as `mix.lock`, which pins it;
    * a stat of a directory on the way to the app's build (`lib/<app>`, its `.mix`) and
      Mix's `.mix_test_failures`, which the run writes itself, are nothing compiled from
      the project and are not recorded;
    * anything else there (the ebin listing, the `.app` file, consolidated protocols, the
      compile manifests, a path dependency outside the repo), and anything under another
      build in `_build` than this run's, is derived from what the record cannot name: the
      test file's coverage is left out of the record, so selection always runs it, and
      outside every window every project module counts as global.
  Reads under `deps` are left out: a dependency changes only with `mix.lock`.

  Touches no window can own count for every test, and a change to such a module selects
  the whole suite:
    * before the first test module started (application start, `test_helper.exs`);
    * while no test module and no compile is open;
    * from a compiling process whose file is not known (a `Kernel.ParallelCompiler`
      task, which inherits the file without that call).
  """

  @started {ExUnit.EventManager, :module_started, 2}
  @finished {ExUnit.EventManager, :module_finished, 2}
  # The first call a `Kernel.ParallelCompiler` worker makes, and the call a worker
  # requiring a file then makes with it (Elixir 1.20.4).
  @compiler {Module.ParallelChecker, :put, 2}
  @compiling {:elixir_compiler, :file, 2}
  @file_arg [{[:"$1", :_], [], [{:message, :"$1"}, {:exception_trace}]}]
  @test_module [{[:_, %{name: :"$1", file: :"$2"}], [], [{:message, {{:"$1", :"$2"}}}]}]
  # Every call whose first argument names a path a test may read (Elixir 1.20.4, OTP 28).
  @path_calls [
    file: [
      read_file: 1,
      read_file: 2,
      read_file_info: 1,
      read_file_info: 2,
      read_link_info: 1,
      read_link_info: 2,
      read_link: 1,
      read_link_all: 1,
      list_dir: 1,
      list_dir_all: 1,
      open: 2,
      consult: 1,
      eval: 1,
      script: 1,
      copy: 2,
      copy: 3
    ],
    prim_file: [
      read_file: 1,
      read_file_info: 1,
      read_file_info: 2,
      read_link_info: 1,
      read_link_info: 2,
      read_link: 1,
      read_link_all: 1,
      list_dir: 1,
      list_dir_all: 1,
      open: 2
    ]
  ]
  @open_port {:erlang, :open_port, 2}
  @set_cwd {:file, :set_cwd, 1}

  # How long `stop/1` waits for the tracer to work through its queue.
  @stop_timeout :timer.minutes(10)

  @doc "Starts tracing calls into `modules`. Returns a handle for `stop/1`."
  def start(modules) do
    for {mod, fun, arity} = mfa <- [@compiler, @compiling] do
      unless Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity),
        do: raise("#{inspect(mfa)} is gone: compile-time calls cannot be told apart")
    end

    Code.ensure_all_loaded(modules)

    project = %{
      app: to_string(Mix.Project.config()[:app]),
      modules: Map.new(modules, &{Atom.to_string(&1), &1}),
      # Where this run's build is (`build_path` in mix.exs, or `MIX_BUILD_PATH`), and where
      # each dependency's source is.
      build: Path.expand(Mix.Project.build_path()),
      deps: deps()
    }

    tracer = spawn(fn -> loop(Map.put(new(), :project, project)) end)
    session = :trace.session_create(:chg_cover, tracer, [])
    send(tracer, {:session, session})

    for m <- modules, do: :trace.function(session, {m, :_, :_}, true, [:global])
    :trace.function(session, @compiler, true, [:global])
    :trace.function(session, @compiling, @file_arg, [:global])
    :trace.function(session, @started, @test_module, [:global])
    :trace.function(session, @finished, @test_module, [:global])

    for {mod, calls} <- @path_calls, {fun, arity} <- calls do
      kind = if fun in [:list_dir, :list_dir_all], do: :listed, else: :path
      ms = [{[:"$1" | List.duplicate(:_, arity - 1)], [], [{:message, {{kind, :"$1"}}}]}]
      :trace.function(session, {mod, fun, arity}, ms, [:global])
    end

    :trace.function(session, @set_cwd, [{[:"$1"], [], [{:message, {{:cwd, :"$1"}}}]}], [:global])

    :trace.function(session, @open_port, [{[:"$1", :_], [], [{:message, {{:port, :"$1"}}}]}], [
      :global
    ])

    :trace.process(session, :all, true, [:call, :procs, :arity, :monotonic_timestamp])
    {session, tracer}
  end

  @doc """
  Stops tracing and returns `%{cover: %{file => [module]}, global: [module], reads: %{file
  => [path]}, global_reads: [path]}`. Test files and read paths are relative to the
  working directory; reads outside it and under `deps` are left out, and reads under
  `_build` are recorded as what they were compiled from (see the moduledoc). A
  directory listed ends in `/` (the root is `./`), since what is under it decides what a
  listing returns; any other read is of the path alone. `{:spawn, name}` stands for a
  subprocess, named by its executable. A module still open (the run stopped at
  `--max-failures`) is closed with everything touched since it started.

  Raises when the tracer died or took longer than #{div(@stop_timeout, 60_000)} minutes,
  and when test modules ran but no process compiling a known test file was seen (the
  probes no longer fit this Elixir, so compile-time calls would be misattributed).
  """
  def stop({session, tracer}) do
    :trace.process(session, :all, false, [:call, :procs])
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

  defp check_compilers(%{cover: cover, compiling: n} = result) when map_size(cover) == 0 or n > 0,
    do: Map.delete(result, :compiling)

  defp check_compilers(_),
    do:
      raise(
        "no process compiling a known test file was seen; #{inspect(@compiler)} and " <>
          "#{inspect(@compiling)} no longer mark one"
      )

  defp new do
    %{
      session: nil,
      touched: :ets.new(:touched, [:set, :private]),
      read: :ets.new(:read, [:set, :private]),
      # pid => the test file whose module, or whose compile, it descends from
      owners: :ets.new(:owners, [:set, :private]),
      # module runner pid => the test file of the module it runs now
      running: %{},
      # the working directories tests set, newest first: `{trace timestamp, absolute dir}`;
      # before the first, `cwd`
      cwds: [],
      owned_reads: %{},
      global_reads: MapSet.new(),
      reads: %{},
      # Servers that touch files for a caller whose own `:file` call is traced.
      drivers: drivers(),
      servers:
        Enum.flat_map(
          [:file_server_2, :code_server, :erl_prim_loader],
          &List.wrap(Process.whereis(&1))
        ),
      first_start: nil,
      # pid => the file it compiles, or nil when not known (yet)
      compilers: %{},
      compiled: %{},
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
    do: %{s | compilers: Map.put_new(s.compilers, pid, nil)}

  defp handle({:trace_ts, pid, :call, @compiling, file, ts}, s) do
    %{
      s
      | compilers: Map.put(s.compilers, pid, file),
        open: Map.put(s.open, {:compile, pid}, {ts, file})
    }
  end

  defp handle({:trace_ts, pid, done, @compiling, _result, _ts}, s)
       when done in [:return_from, :exception_from],
       do: closing(s, {:compile, pid})

  defp handle({:trace_ts, pid, :call, @started, {name, file}, ts}, s) do
    first = if s.first_start, do: min(s.first_start, ts), else: ts

    %{
      s
      | first_start: first,
        open: Map.put(s.open, name, {ts, file}),
        running: Map.put(s.running, pid, file)
    }
  end

  # A process inherits its parent's owner when it starts, so a test's processes stay its
  # own after its runner has moved on to the next module.
  defp handle({:trace_ts, parent, :spawn, child, _mfa, _ts}, s) do
    if owner = owner(s, parent), do: :ets.insert(s.owners, {child, owner})
    s
  end

  # A process with a name can be reached by any test, so it is no one test's.
  defp handle({:trace_ts, pid, :register, _name, _ts}, s) do
    :ets.delete(s.owners, pid)
    s
  end

  # `File.cd/1`. The call is traced before it takes effect, so the process's own later
  # reads are stamped after it; a read another process makes at the same moment may be
  # resolved against either directory.
  defp handle({:trace_ts, _pid, :call, @set_cwd, {:cwd, dir}, ts}, s) do
    case path_name(dir, :path, s, ts) do
      {d, _} -> %{s | cwds: Enum.sort_by([{ts, d} | s.cwds], &elem(&1, 0), :desc)}
      nil -> s
    end
  end

  defp handle({:trace_ts, _pid, :call, @finished, {name, _file}, _ts}, s), do: closing(s, name)

  defp handle({:trace_ts, pid, :call, _mfa, {kind, name}, ts}, s) when kind in [:path, :listed] do
    if pid in s.servers, do: s, else: read(s, pid, path_name(name, kind, s, ts), ts)
  end

  defp handle({:trace_ts, pid, :call, @open_port, {:port, name}, ts}, s),
    do: read(s, pid, spawned(name, s.drivers), ts)

  # A compiling process's touch is its file's, never timed. Any other touch is timed; one
  # made before the first test module or while none is open is no test's, so it is global.
  defp handle({:trace_ts, pid, :call, {m, _f, _a}, ts}, s) do
    case s.compilers do
      %{^pid => nil} ->
        %{s | global: MapSet.put(s.global, m)}

      %{^pid => file} ->
        %{s | compiled: Map.update(s.compiled, file, MapSet.new([m]), &MapSet.put(&1, m))}

      _ ->
        :ets.insert(s.touched, {m, System.monotonic_time()})

        if s.first_start == nil or ts < s.first_start or map_size(s.open) == 0,
          do: %{s | global: MapSet.put(s.global, m)},
          else: s
    end
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

    rel = &(&1 |> Path.expand(s.cwd) |> Path.relative_to(s.cwd))

    cover =
      Enum.concat(s.cover, s.compiled)
      |> Enum.reduce(%{}, fn {file, mods}, acc ->
        Map.update(acc, rel.(file), MapSet.new(mods), &Enum.into(mods, &1))
      end)
      |> Map.new(fn {file, mods} -> {file, Enum.sort(mods)} end)

    built =
      Enum.concat(s.reads, s.owned_reads)
      |> Enum.reduce(%{}, fn {file, paths}, acc ->
        Map.update(acc, rel.(file), MapSet.new(paths), &Enum.into(paths, &1))
      end)
      |> Map.new(fn {file, paths} -> {file, kept(paths, s.cwd, s.project)} end)

    reads = Map.new(built, fn {file, {paths, _, _}} -> {file, paths} end)

    # A beam read counts as executing its module; a read derived from every module leaves
    # the file out of the coverage, so selection always runs it.
    cover =
      Enum.reduce(built, cover, fn
        {file, {_, _, true}}, acc ->
          Map.delete(acc, file)

        {_, {_, [], false}}, acc ->
          acc

        {file, {_, mods, false}}, acc ->
          Map.update(acc, file, Enum.sort(mods), &Enum.sort(Enum.uniq(&1 ++ mods)))
      end)

    {global_reads, global_mods, every?} = kept(s.global_reads, s.cwd, s.project)
    global_mods = if every?, do: Map.values(s.project.modules), else: global_mods

    {:reply, from, ref,
     %{
       cover: cover,
       global: s.global |> Enum.into(MapSet.new(global_mods)) |> Enum.sort(),
       reads: reads,
       global_reads: global_reads,
       compiling: Enum.count(s.compilers, fn {_, file} -> file != nil end)
     }}
  end

  defp handle(_other, s), do: s

  # A window closes once every trace message up to now has been handled.
  defp closing(s, name) do
    ref = :trace.delivered(s.session, :all)
    %{s | closing: Map.update(s.closing, ref, [name], &[name | &1])}
  end

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
        since = [{{:"$1", :"$2"}, [{:>=, :"$2", start}], [:"$1"]}]
        mods = :ets.select(s.touched, since)
        paths = :ets.select(s.read, since)
        cover = Map.update(s.cover, file, MapSet.new(mods), &Enum.into(mods, &1))
        reads = Map.update(s.reads, file, MapSet.new(paths), &Enum.into(paths, &1))
        %{s | open: open, cover: cover, reads: reads}
    end
  end

  # A read is the file's of the test module or compile its process descends from, while
  # that module or compile is open and the process has no name. Any other (a pool, a
  # server the app started, one a finished module left behind) is attributed like a
  # touch: by time, and outside every window to every test.
  defp read(s, _pid, nil, _ts), do: s

  defp read(s, pid, path, ts) do
    case {s.compilers, open_owner(s, pid)} do
      {%{^pid => nil}, _} ->
        %{s | global_reads: MapSet.put(s.global_reads, path)}

      {_, file} when file != nil ->
        %{
          s
          | owned_reads:
              Map.update(s.owned_reads, file, MapSet.new([path]), &MapSet.put(&1, path))
        }

      _ ->
        :ets.insert(s.read, {path, System.monotonic_time()})

        if s.first_start == nil or ts < s.first_start or map_size(s.open) == 0,
          do: %{s | global_reads: MapSet.put(s.global_reads, path)},
          else: s
    end
  end

  # The owner only while its module or compile is still open: afterwards a process it left
  # behind may be doing another test's work.
  defp open_owner(s, pid) do
    owner = owner(s, pid)
    if owner && Enum.any?(s.open, fn {_, {_, file}} -> file == owner end), do: owner
  end

  defp owner(s, pid) do
    case :ets.lookup(s.owners, pid) do
      [{_, file}] -> file
      [] -> Map.get(s.running, pid) || Map.get(s.compilers, pid)
    end
  end

  # The absolute path a call names, against the working directory at `ts`, and whether it
  # lists a directory; nil for a file descriptor or an unreadable name.
  defp path_name(name, kind, s, ts) when is_binary(name) do
    {_, cwd} = Enum.find(s.cwds, {nil, s.cwd}, fn {at, _} -> at <= ts end)
    {Path.expand(name, cwd), kind}
  end

  defp path_name({name, _modes}, kind, s, ts), do: path_name(name, kind, s, ts)

  defp path_name(name, kind, s, ts) when is_list(name) do
    path_name(IO.chardata_to_string(name), kind, s, ts)
  rescue
    _ -> nil
  end

  defp path_name(_, _, _, _), do: nil

  # `{:spawn, command}` for a port that runs a command, named by its executable's basename;
  # nil for a driver (a socket, `ram_file_drv`) and the resolver (`inet_gethost`).
  defp spawned({:spawn_executable, exe}, _drivers) do
    case exe |> to_string() |> Path.basename() do
      "inet_gethost" -> nil
      name -> {:spawn, name}
    end
  end

  defp spawned({:spawn, command}, drivers) do
    name = command |> to_string() |> String.split(" ", parts: 2) |> hd()
    if name in drivers, do: nil, else: {:spawn, Path.basename(name)}
  end

  defp spawned(_, _), do: nil

  defp drivers do
    {:ok, names} = :erl_ddll.loaded_drivers()
    Enum.map(names, &to_string/1)
  end

  # The paths kept as reads, the modules whose beams were read, and whether anything was
  # read that only every module accounts for.
  defp kept(paths, cwd, project) do
    {reads, mods, every?} =
      Enum.reduce(paths, {[], [], false}, fn
        {:spawn, _} = spawn, {r, m, e} ->
          {[spawn | r], m, e}

        {p, kind}, {r, m, e} ->
          rel = Path.relative_to(p, cwd)

          case kept_path(p, rel, kind, Map.put(project, :cwd, cwd)) do
            {:reads, more} -> {more ++ r, m, e}
            {:module, mod} -> {r, [mod | m], e}
            :every -> {r, m, true}
          end
      end)

    {reads |> Enum.uniq() |> Enum.sort(), Enum.uniq(mods), every?}
  end

  defp deps do
    scms = Mix.Project.deps_scms()

    Map.new(Mix.Project.deps_paths(), fn {dep, path} ->
      {to_string(dep), {scms[dep], Path.expand(path)}}
    end)
  end

  defp kept_path(path, rel, kind, project) do
    build = project.build

    cond do
      path == build or String.starts_with?(path, build <> "/") ->
        path |> Path.relative_to(build) |> parts() |> built(kind, project)

      # A stat of a directory on the way to the build says nothing about what is in it.
      kind == :path and rel != "." and String.starts_with?(build, path <> "/") ->
        {:reads, []}

      Path.type(rel) == :absolute ->
        {:reads, []}

      rel == "deps" or String.starts_with?(rel, "deps/") ->
        {:reads, []}

      # Another build than this run's (another env, or the default one beside a custom
      # build path): what it was compiled from is unknown.
      rel == "_build" or String.starts_with?(rel, "_build/") ->
        :every

      kind == :listed and rel == "." ->
        {:reads, ["./"]}

      kind == :listed ->
        {:reads, [rel <> "/"]}

      true ->
        {:reads, [rel]}
    end
  end

  defp parts("."), do: []
  defp parts(rel), do: Path.split(rel)

  # What a path under the build was compiled from, by its parts below the build path.
  defp built(["lib", app, "ebin", beam], :path, %{app: app} = project) do
    case Map.fetch(project.modules, Path.rootname(beam, ".beam")) do
      {:ok, mod} when beam != "" -> {:module, mod}
      _ -> :every
    end
  end

  defp built(["lib", app, "priv" | rest], kind, %{app: app}),
    do: {:reads, [listed(Path.join(["priv" | rest]), kind)]}

  # `.mix_test_failures` is the test run's own record of its failures (`--failed`),
  # written by this run, and the directories on the way say nothing of their contents.
  defp built(["lib", app, ".mix", ".mix_test_failures"], _kind, %{app: app}), do: {:reads, []}
  defp built(["lib", app, ".mix"], :path, %{app: app}), do: {:reads, []}
  defp built(["lib", app], :path, %{app: app}), do: {:reads, []}
  defp built(["lib"], :path, _project), do: {:reads, []}
  defp built([], :path, _project), do: {:reads, []}

  defp built(["lib", dep | rest], kind, %{app: app} = project) when dep != app,
    do: dep_source(dep, rest, kind, project)

  defp built(_parts, _kind, _project), do: :every

  # A dependency's build is read as its source. A path dependency or umbrella sibling in
  # the repo is read as its own directory (its priv by the same path under it); a fetched
  # one (Hex, git) is pinned by `mix.lock`, wherever `deps_path` puts it. A path
  # dependency outside the repo, or one Mix does not name, is unknown.
  defp dep_source(dep, rest, kind, project) do
    case Map.fetch(project.deps, dep) do
      {:ok, {Mix.SCM.Path, path}} ->
        rel = Path.relative_to(path, project.cwd)

        cond do
          Path.type(rel) == :absolute -> :every
          match?(["priv" | _], rest) -> {:reads, [listed(Path.join([rel | rest]), kind)]}
          true -> {:reads, [rel <> "/"]}
        end

      {:ok, _fetched} ->
        {:reads, ["mix.lock"]}

      :error ->
        :every
    end
  end

  defp listed(path, :listed), do: path <> "/"
  defp listed(path, _kind), do: path
end
