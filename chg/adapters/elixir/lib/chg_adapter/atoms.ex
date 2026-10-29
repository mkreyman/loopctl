defmodule ChgAdapter.Atoms do
  @moduledoc """
  Makes every compiling VM number the project's atoms the same way.

  OTP 26+ orders the atom keys of a map of up to 32 keys by atom index: the order the VM
  first saw each atom.
  The parallel compiler meets atoms in a different order on every build, so code a
  compile generates by iterating a map (struct field lists, encoder field orders, a
  LiveView's change tracking) comes out differently in two builds of one commit, and
  coverage selection counts each such module altered. On HomeCareBilling 467 of 2995
  modules differed between two clean builds.

  `mix chg.compile` therefore writes the atoms a compile will meet (every literal atom
  and alias in the project's sources, and every atom in its dependencies' and the
  toolchain's beams) to a file, sorted, and starts `mix compile` with `preload/0` run
  before anything else: each VM then makes those atoms first, in the same order, from the
  same starting table. Two atoms both on the list are ordered the same way in every
  build, even when the lists differ (a commit added a literal), so only atoms a compile
  invents (`:"\#{name}_id"`) still vary. A map of more than 32 keys is ordered by a hash
  that differs from one VM run to the next whatever the atoms' indices, so code generated
  from one still varies; coverage selection compares only the digests a change can reach.
  """

  @env "CHG_ATOMS"

  @doc """
  Makes the atoms in the file `CHG_ATOMS` names, in order. Run by the VM before Elixir
  starts (`-s Elixir.ChgAdapter.Atoms preload`), so it uses only Erlang, and never fails:
  a missing, unreadable or malformed file makes no atom and leaves the build as it would
  have been.
  """
  def preload do
    case :os.getenv(~c"CHG_ATOMS") do
      false ->
        :ok

      file ->
        # The whole list is checked before any atom is made, so a bad file makes none.
        try do
          {:ok, bin} = :file.read_file(file)
          list = :erlang.binary_to_term(bin)
          true = is_list(list) and :lists.all(&is_binary/1, list)
          :lists.foreach(&:erlang.binary_to_atom(&1, :utf8), list)
        catch
          _, _ -> :ok
        end
    end

    :ok
  end

  @doc """
  The environment for a `mix compile` that preloads this project's atoms: writes the list
  under the build path and returns `CHG_ATOMS` and an `ERL_AFLAGS` that runs `preload/0`.
  Empty when the adapter's own code sits at a path `ERL_AFLAGS` cannot carry (a space).
  """
  def env do
    ebin = :code.which(__MODULE__) |> to_string() |> Path.dirname()

    if String.contains?(ebin, " ") do
      []
    else
      file = Path.join(Mix.Project.build_path(), "chg_atoms.etf")
      File.mkdir_p!(Path.dirname(file))
      ChgAdapter.write_atomic!(file, :erlang.term_to_binary(list()))
      flags = "-pa #{ebin} -s Elixir.ChgAdapter.Atoms preload"
      [{@env, file}, {"ERL_AFLAGS", String.trim("#{System.get_env("ERL_AFLAGS")} #{flags}")}]
    end
  end

  @doc "The atoms to preload, as sorted binaries."
  def list do
    config = Mix.Project.config()

    sources =
      Mix.Utils.extract_files(Keyword.get(config, :elixirc_paths, ["lib"]) ++ ["config"], [
        :ex,
        :exs
      ])

    own = Path.join([Mix.Project.build_path(), "lib", to_string(config[:app]), "ebin"])
    elixir = :code.lib_dir(:elixir) |> to_string() |> Path.dirname()

    ebins =
      Path.wildcard(Path.join([Mix.Project.build_path(), "lib", "*", "ebin"])) --
        [own]

    ebins =
      ebins ++
        Path.wildcard(Path.join(elixir, "*/ebin")) ++
        Path.wildcard(Path.join(to_string(:code.root_dir()), "lib/*/ebin"))

    from_sources =
      sources
      |> Task.async_stream(&source_atoms/1, ordered: false, timeout: :infinity)
      |> Enum.flat_map(fn {:ok, l} -> l end)

    from_beams =
      ebins
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.beam")))
      |> Task.async_stream(&beam_atoms/1, ordered: false, timeout: :infinity)
      |> Enum.flat_map(fn {:ok, l} -> l end)

    (from_sources ++ from_beams) |> Enum.uniq() |> Enum.sort()
  end

  # Every literal atom and module name in a source file, without making any of them: the
  # aliases as written, a nested module under its full name (`defmodule A do defmodule B`
  # is `A.B`), each name of a multi-alias (`alias A.{B, C}`), and `__MODULE__.X`.
  defp source_atoms(file) do
    Process.put(:chg_atoms, [])

    encoder = fn s, _ ->
      Process.put(:chg_atoms, [s | Process.get(:chg_atoms)])
      {:ok, s}
    end

    with {:ok, bin} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(bin, static_atoms_encoder: encoder, file: file) do
      walk(ast, nil)
    end

    Process.get(:chg_atoms)
  rescue
    _ -> Process.get(:chg_atoms, [])
  end

  # The encoder leaves every source atom a binary: `defmodule` and `__MODULE__` included.
  defp walk({"defmodule", _, [{:__aliases__, _, parts} = name, body]}, outer) do
    walk(name, outer)

    inner =
      case module(parts, outer) do
        nil -> outer
        full -> if nested?(parts, outer), do: add(outer ++ parts), else: full
      end

    walk(body, inner)
  end

  defp walk({{:., _, [{:__aliases__, _, base}, multi]}, _, aliases}, outer)
       when multi in [:{}, "{}"] and is_list(aliases) do
    for {:__aliases__, _, parts} <- aliases do
      case module(base, outer) do
        nil -> :ok
        prefix -> add(prefix ++ parts)
      end
    end

    walk(base, outer)
  end

  defp walk({:__aliases__, _, parts}, outer) do
    case module(parts, outer) do
      nil -> :ok
      full -> add(full)
    end
  end

  defp walk({form, _, args}, outer) do
    walk(form, outer)
    walk(args, outer)
  end

  defp walk({a, b}, outer) do
    walk(a, outer)
    walk(b, outer)
  end

  defp walk(list, outer) when is_list(list), do: Enum.each(list, &walk(&1, outer))
  defp walk(_, _), do: :ok

  # The parts of the module an alias names, or nil when they are not all known.
  defp module([{"__MODULE__", _, _} | rest], outer) when is_list(outer), do: known(outer ++ rest)
  defp module(parts, _outer), do: known(parts)

  defp known(parts), do: if(Enum.all?(parts, &is_binary/1), do: parts)

  # `defmodule B` inside `A` names `A.B`, unless it is spelled from the root (`Elixir.B`).
  defp nested?(["Elixir" | _], _outer), do: false
  defp nested?(parts, outer), do: is_list(outer) and Enum.all?(parts, &is_binary/1)

  defp add(["Elixir" | parts]), do: add(parts)

  defp add(parts) do
    Process.put(:chg_atoms, ["Elixir." <> Enum.join(parts, ".") | Process.get(:chg_atoms)])
    parts
  end

  defp beam_atoms(path) do
    case :beam_lib.chunks(String.to_charlist(path), [:atoms]) do
      {:ok, {_, [atoms: atoms]}} -> for {_, a} <- atoms, do: Atom.to_string(a)
      _ -> []
    end
  end
end
