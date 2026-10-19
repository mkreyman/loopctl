defmodule Loopctl.ProjectRootGuardTest do
  @moduledoc """
  #985: no module compiled from `lib/` or `test/support` bakes the tree's path
  into itself for use at run time.

  The project compiles with `check_cwd: false` (mix.exs), so chg can hydrate a
  check workspace from a snapshot built at another path and recompile only what
  a commit changed. A module that was NOT recompiled keeps every path it
  captured while compiling: `__DIR__` and `__ENV__.file` wherever they appear (a
  function body included, since both expand at compile time), and any
  `File.cwd!/0`, `Path.expand/1,2`, `:code.priv_dir/1`, `Application.app_dir/2`
  or `Mix.Project` path evaluated outside a function body (a module attribute, a
  module-level binding, a macro body outside `quote` or inside `unquote`, which
  run while the macro's caller compiles, and all of what `__using__` or a
  CaseTemplate's `using` quotes into the caller's module body). Read at run time, such a path names the snapshot's
  tree, which may be gone: home_care_billing's first chg shadow check failed
  exactly so while `mix precommit` passed (home_care_billing#2540). Ask at run
  time instead (`File.cwd!/0` inside the function, a cwd-relative path, or
  `Application.app_dir/2` inside the function).

  A path used only WHILE COMPILING is fine, and is listed in
  `@compile_time_only` with the reason. That list is also this guard's
  witness: each entry must still match, which proves the walk reaches real code.
  """
  use ExUnit.Case, async: true

  # {file, what the walk reports}: a capture used only during compilation.
  @compile_time_only [
    # Reads mcp-server/package.json into the literal @mcp_version while compiling;
    # nothing keeps the path. Mix records the @external_resource relative to the
    # project (Mix.Compilers.Elixir, process_external_resources/2), so a moved
    # build still recompiles this module when that file changes.
    {"lib/loopctl_web/controllers/well_known_controller.ex", "File.cwd!/0 at compile time"}
  ]

  @scanned_roots ["lib", "test/support"]

  # Bodies that run when called, not when the module compiles. A macro body
  # (defmacro, defmacrop, ExUnit.CaseTemplate's `using`) is not one: it runs
  # while its CALLER compiles, so what it evaluates outside `quote`, and what
  # `unquote` evaluates inside it, is baked into the caller. It is walked like
  # the module body around it. Quoted code is judged where it LANDS: the quote a
  # `__using__`/`using` body returns lands in the caller's module body (compile
  # time, #998); any other quote lands wherever its macro is called, which the
  # walk cannot see, so only `__DIR__`/`__ENV__.file` (which expand wherever they
  # land) are judged in it.
  @runtime_bodies [:def, :defp, :defguard, :defguardp]

  # Calls whose result is an absolute path of the tree or build they run in.
  @path_calls %{
    File => [:cwd, :cwd!],
    Path => [:expand, :absname],
    System => [:cwd, :cwd!],
    Application => [:app_dir],
    Mix.Project => [
      :app_path,
      :build_path,
      :compile_path,
      :consolidation_path,
      :deps_path,
      :deps_paths,
      :manifest_path,
      :project_file
    ],
    :code => [:priv_dir, :lib_dir]
  }

  test "no lib/ or test/support module captures the tree's path for run time" do
    files =
      for root <- @scanned_roots,
          file <- Path.wildcard(Path.join(root, "**/*.ex")),
          do: file

    # A guard over no files passes vacuously.
    for root <- @scanned_roots do
      assert Enum.any?(files, &String.starts_with?(&1, root <> "/")),
             "no .ex file under #{root}/ — run from the project root"
    end

    hits =
      for file <- files,
          {line, what} <- file |> File.read!() |> scan(file),
          do: {file, line, what}

    {allowed, offenders} =
      Enum.split_with(hits, fn {file, _line, what} -> {file, what} in @compile_time_only end)

    assert offenders == [],
           "resolve the path at run time instead (see this module's doc):\n" <>
             Enum.map_join(offenders, "\n", fn {f, l, w} -> "#{f}:#{l}: #{w}" end)

    matched = allowed |> Enum.map(fn {f, _l, w} -> {f, w} end) |> Enum.uniq() |> Enum.sort()

    assert matched == Enum.sort(@compile_time_only),
           "an @compile_time_only entry no longer matches; drop it, or fix the walk"
  end

  describe "the walk (positive and negative controls)" do
    test "__DIR__ in a module attribute" do
      assert [{3, "__DIR__"}] =
               scan!(~S"""
               defmodule M do
                 @moduledoc false
                 @root Path.join(__DIR__, "..")
               end
               """)
    end

    test "__DIR__ in a function body still expands at compile time" do
      assert [{2, "__DIR__"}] =
               scan!(~S"""
               defmodule M do
                 def root, do: __DIR__
               end
               """)
    end

    test "__ENV__.file and __CALLER__.file" do
      assert [{2, "__ENV__.file"}, {3, "__CALLER__.file"}] =
               scan!(~S"""
               defmodule M do
                 def here, do: __ENV__.file
                 defmacro there, do: __CALLER__.file
               end
               """)
    end

    test "a path call in a multi-line module attribute" do
      assert [{3, "Path.expand/2 at compile time"}] =
               scan!(~S"""
               defmodule M do
                 @root (
                   Path.expand("../..", "x")
                 )
               end
               """)
    end

    test "a path call in a module-level binding, and in an Erlang module" do
      assert [{2, "File.cwd!/0 at compile time"}, {3, ":code.priv_dir/1 at compile time"}] =
               scan!(~S"""
               defmodule M do
                 root = File.cwd!()
                 @priv :code.priv_dir(:loopctl)
                 def root, do: unquote(root)
               end
               """)
    end

    test "a path call inside a function body runs at run time and passes" do
      assert [] =
               scan!(~S"""
               defmodule M do
                 def root, do: File.cwd!()
                 defp priv, do: Application.app_dir(:loopctl, "priv")
               end
               """)
    end

    test "a quote __using__ injects runs at the caller's compile time, unquoted or not" do
      assert [{4, "__DIR__"}, {5, "__DIR__"}, {6, "File.cwd!/0 at compile time"}] =
               scan!(~S"""
               defmodule M do
                 defmacro __using__(_) do
                   quote do
                     @from_caller __DIR__
                     @baked_here unquote(__DIR__)
                     @root File.cwd!()
                   end
                 end
               end
               """)
    end

    test "a macro body runs at its caller's compile time, inside unquote and outside quote" do
      assert [{4, "File.cwd!/0 at compile time"}, {8, "Path.expand/1 at compile time"}] =
               scan!(~S"""
               defmodule M do
                 defmacro __using__(_) do
                   quote do
                     @root unquote(File.cwd!())
                   end
                 end

                 defmacro root, do: Path.expand("priv")
               end
               """)
    end

    test "a CaseTemplate's `using` body runs at its caller's compile time" do
      assert [{4, "Path.expand/1 at compile time"}] =
               scan!(~S"""
               defmodule M do
                 use ExUnit.CaseTemplate
                 using do
                   root = Path.expand("priv")
                   quote do: @root(unquote(root))
                 end
               end
               """)
    end

    test "a path call quoted, not unquoted, into a function body is not flagged" do
      assert [] =
               scan!(~S"""
               defmodule M do
                 defmacro __using__(_) do
                   quote do
                     def root, do: File.cwd!()
                   end
                 end

                 defmacrop priv, do: quote(do: Application.app_dir(:loopctl, "priv"))
               end
               """)
    end

    test "unquote inside a def inside a __using__ quote runs at the caller's compile time" do
      assert [{4, "File.cwd!/0 at compile time"}] =
               scan!(~S"""
               defmodule M do
                 defmacro __using__(_) do
                   quote do
                     def root, do: unquote(File.cwd!())
                   end
                 end
               end
               """)
    end

    test "a guarded __using__ head is judged the same way" do
      assert [{4, "File.cwd!/0 at compile time"}] =
               scan!(~S"""
               defmodule M do
                 defmacro __using__(opts) when is_list(opts) do
                   quote do
                     @root File.cwd!()
                   end
                 end
               end
               """)
    end

    test "a CaseTemplate `using` quote is the caller's module body" do
      assert [{4, "Path.expand/1 at compile time"}] =
               scan!(~S"""
               defmodule M do
                 use ExUnit.CaseTemplate
                 using do
                   quote do: @root(Path.expand("priv"))
                 end
               end
               """)
    end

    test "a quote bound in a __using__ body and spliced into a def is not module body" do
      assert [] =
               scan!(~S"""
               defmodule M do
                 defmacro __using__(_) do
                   body = quote do: File.cwd!()
                   quote do
                     def root, do: unquote(body)
                   end
                 end
               end
               """)
    end

    test "any macro's quoted __DIR__ expands where it lands, so it is flagged" do
      assert [{2, "__DIR__"}] =
               scan!(~S"""
               defmodule M do
                 defmacro root, do: quote(do: __DIR__)
               end
               """)
    end

    test "a `using` call inside a function body is not a CaseTemplate block" do
      assert [] =
               scan!(~S"""
               defmodule M do
                 def f, do: using(File.cwd!())
               end
               """)
    end

    test "a nested module is walked too" do
      assert [{3, "__DIR__"}] =
               scan!(~S"""
               defmodule M do
                 defmodule N do
                   @root __DIR__
                 end
               end
               """)
    end
  end

  defp scan!(source), do: scan(source, "nofile")

  # [{line, what}] for every capture in `source`, in source order. The top of a
  # file and a module body run at compile time; a function body at run time.
  defp scan(source, file) do
    source
    |> Code.string_to_quoted!(file: file)
    |> walk(:compile, [])
    |> Enum.sort()
  end

  defp walk({:__DIR__, meta, ctx}, _mode, acc) when is_atom(ctx),
    do: [{meta[:line], "__DIR__"} | acc]

  defp walk({{:., meta, [{env, _, ctx}, :file]}, _, []}, _mode, acc)
       when env in [:__ENV__, :__CALLER__] and is_atom(ctx),
       do: [{meta[:line], "#{env}.file"} | acc]

  # `__using__` (bare or guarded head) and a CaseTemplate's module-level `using`
  # block return a quote that lands in the CALLER's module body.
  defp walk({:defmacro, _, [head, body]}, :compile, acc) when is_list(body) do
    if using_head?(head),
      do: walk_using_body(body[:do], acc),
      else: walk([head, body], :compile, acc)
  end

  defp walk({:using, _, args}, :compile, acc) when is_list(args) and args != [] do
    case List.last(args) do
      [do: body] -> walk_using_body(body, walk(Enum.drop(args, -1), :compile, acc))
      _other -> walk(args, :compile, acc)
    end
  end

  # Any other quote lands where its macro is called.
  defp walk({:quote, _, args}, mode, acc), do: walk_quoted(args, :unknown, mode, acc)

  defp walk({kind, _, args}, _mode, acc) when kind in @runtime_bodies and is_list(args),
    do: walk(args, :runtime, acc)

  defp walk({{:., meta, [mod, fun]}, _, args} = call, :compile, acc) when is_list(args) do
    acc = walk(args, :compile, acc)

    case path_call(mod, fun) do
      nil -> walk(elem(call, 0), :compile, acc)
      name -> [{meta[:line], "#{name}/#{length(args)} at compile time"} | acc]
    end
  end

  defp walk({a, _meta, c}, mode, acc) when is_list(c), do: walk(c, mode, walk(a, mode, acc))
  defp walk({a, b}, mode, acc), do: walk(b, mode, walk(a, mode, acc))
  defp walk(list, mode, acc) when is_list(list), do: Enum.reduce(list, acc, &walk(&1, mode, &2))
  defp walk(_leaf, _mode, acc), do: acc

  defp using_head?({:when, _, [head | _]}), do: using_head?(head)
  defp using_head?({:__using__, _, _}), do: true
  defp using_head?(_head), do: false

  # The macro body runs at the caller's compile time; its RESULT is what lands in
  # the caller's module body. Only a quote in result position is judged as module
  # body: a quote bound earlier (`body = quote do: File.cwd!()`) is spliced
  # wherever its `unquote` puts it, often a function body.
  defp walk_using_body(body, acc) do
    {init, last} =
      case body do
        {:__block__, _, exprs} when exprs != [] -> {Enum.drop(exprs, -1), List.last(exprs)}
        expr -> {[], expr}
      end

    acc = walk(init, :compile, acc)

    case last do
      {:quote, _, args} -> walk_quoted(args, :compile, :compile, acc)
      other -> walk(other, :compile, acc)
    end
  end

  # Quoted code: `land` is the mode it runs in where it lands (`:unknown` when the
  # walk cannot tell), `outer` the mode of the code around the quote, in which an
  # `unquote` is evaluated whatever the quoted code around it does.
  defp walk_quoted({unq, _, [expr]}, _land, outer, acc) when unq in [:unquote, :unquote_splicing],
    do: walk(expr, outer, acc)

  defp walk_quoted({:__DIR__, meta, ctx}, _land, _outer, acc) when is_atom(ctx),
    do: [{meta[:line], "__DIR__"} | acc]

  defp walk_quoted({{:., meta, [{env, _, ctx}, :file]}, _, []}, _land, _outer, acc)
       when env in [:__ENV__, :__CALLER__] and is_atom(ctx),
       do: [{meta[:line], "#{env}.file"} | acc]

  defp walk_quoted({kind, _, args}, land, outer, acc)
       when kind in @runtime_bodies and is_list(args) do
    land = if land == :unknown, do: :unknown, else: :runtime
    walk_quoted(args, land, outer, acc)
  end

  defp walk_quoted({{:., meta, [mod, fun]}, _, args} = call, :compile, outer, acc)
       when is_list(args) do
    acc = walk_quoted(args, :compile, outer, acc)

    case path_call(mod, fun) do
      nil -> walk_quoted(elem(call, 0), :compile, outer, acc)
      name -> [{meta[:line], "#{name}/#{length(args)} at compile time"} | acc]
    end
  end

  defp walk_quoted({a, _meta, c}, land, outer, acc) when is_list(c),
    do: walk_quoted(c, land, outer, walk_quoted(a, land, outer, acc))

  defp walk_quoted({a, b}, land, outer, acc),
    do: walk_quoted(b, land, outer, walk_quoted(a, land, outer, acc))

  defp walk_quoted(list, land, outer, acc) when is_list(list),
    do: Enum.reduce(list, acc, &walk_quoted(&1, land, outer, &2))

  defp walk_quoted(_leaf, _land, _outer, acc), do: acc

  defp path_call({:__aliases__, _, parts}, fun) do
    mod = Module.concat(parts)
    if fun in Map.get(@path_calls, mod, []), do: inspect(mod) <> "." <> Atom.to_string(fun)
  end

  defp path_call(mod, fun) when is_atom(mod) do
    if fun in Map.get(@path_calls, mod, []), do: inspect(mod) <> "." <> Atom.to_string(fun)
  end

  defp path_call(_mod, _fun), do: nil
end
