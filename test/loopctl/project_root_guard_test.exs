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
  run while the macro's caller compiles). Read at run time, such a path names the snapshot's
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
  # the module body around it; only its quoted code is left to where it lands.
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

    test "inside quote only the unquoted part runs at the defining module's compile time" do
      assert [{5, "__DIR__"}] =
               scan!(~S"""
               defmodule M do
                 defmacro __using__(_) do
                   quote do
                     @from_caller __DIR__
                     @baked_here unquote(__DIR__)
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

  # Only what quote unquotes runs here, in the mode around the quote (a macro
  # body's: compile time); the rest runs wherever it is injected.
  defp walk({:quote, _, args}, mode, acc), do: args |> unquoted() |> walk(mode, acc)

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

  defp unquoted({:unquote, _, [expr]}), do: [expr]
  defp unquoted({a, _meta, c}) when is_list(c), do: unquoted(a) ++ unquoted(c)
  defp unquoted({a, b}), do: unquoted(a) ++ unquoted(b)
  defp unquoted(list) when is_list(list), do: Enum.flat_map(list, &unquoted/1)
  defp unquoted(_leaf), do: []

  defp path_call({:__aliases__, _, parts}, fun) do
    mod = Module.concat(parts)
    if fun in Map.get(@path_calls, mod, []), do: inspect(mod) <> "." <> Atom.to_string(fun)
  end

  defp path_call(mod, fun) when is_atom(mod) do
    if fun in Map.get(@path_calls, mod, []), do: inspect(mod) <> "." <> Atom.to_string(fun)
  end

  defp path_call(_mod, _fun), do: nil
end
