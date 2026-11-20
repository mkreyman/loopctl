defmodule ChgAdapter.AtomsTest do
  use ExUnit.Case, async: false

  alias ChgAdapter.Atoms

  setup do
    dir = Path.join(System.tmp_dir!(), "chg-atoms-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{tmp_dir: dir}
  end

  test "preload makes the file's atoms in its order, so map keys follow it", %{tmp_dir: dir} do
    file = Path.join(dir, "atoms.etf")
    File.write!(file, :erlang.term_to_binary(~w(zz_chg_preload aa_chg_preload)))
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    {:ok, peer, _} =
      :peer.start_link(%{
        connection: :standard_io,
        args: paths,
        env: [{~c"CHG_ATOMS", String.to_charlist(file)}]
      })

    try do
      assert :peer.call(peer, Atoms, :preload, []) == :ok

      keys =
        :peer.call(peer, :erlang, :binary_to_term, [
          :erlang.term_to_binary(%{aa_chg_preload: 1, zz_chg_preload: 2})
        ])
        |> then(&:peer.call(peer, :maps, :keys, [&1]))

      assert keys == [:zz_chg_preload, :aa_chg_preload]
    after
      :peer.stop(peer)
    end
  end

  # Atoms the VM makes while booting (`:state`, `:name`) get their indices in a different
  # order on every multi-scheduler boot, which reorders maps they key. Booted with
  # `boot_flags/1`, three VMs agree, and preload brings every scheduler back online.
  test "a VM booted with boot_flags orders boot atoms the same way and gets every scheduler back" do
    n = System.schedulers()
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    # As `env/0` passes them, in ERL_ZFLAGS, past an ERL_FLAGS like the CI runner pool's,
    # which the VM reads after the command line and would otherwise win.
    env = [
      {~c"ERL_FLAGS", ~c"+S #{n}:#{n}"},
      {~c"ERL_ZFLAGS", String.to_charlist(Atoms.boot_flags(n))}
    ]

    keys = ~w(id name email phone address city state zip country status type value key data
              error ok module function line file reason message source target count size
              length list map tuple atom binary integer float pid port ref node time date
              first last min max)a

    boot = fn ->
      {:ok, peer, _} = :peer.start_link(%{connection: :standard_io, args: paths, env: env})

      try do
        assert :peer.call(peer, :erlang, :system_info, [:schedulers_online]) == 1
        assert :peer.call(peer, :erlang, :system_info, [:dirty_io_schedulers]) == 1
        order = :peer.call(peer, :maps, :keys, [:peer.call(peer, :maps, :from_keys, [keys, 1])])
        assert :peer.call(peer, Atoms, :preload, []) == :ok
        assert :peer.call(peer, :erlang, :system_info, [:schedulers_online]) == n

        assert :peer.call(peer, :erlang, :system_info, [:dirty_cpu_schedulers_online]) ==
                 :peer.call(peer, :erlang, :system_info, [:dirty_cpu_schedulers])

        order
      after
        :peer.stop(peer)
      end
    end

    [first | rest] = for _ <- 1..3, do: boot.()
    assert Enum.all?(rest, &(&1 == first))
  end

  # The parallel compiler meets atoms in a different order on every build, and OTP 26+
  # iterates a map's atom keys in the order the VM made them: code a macro generates from
  # a map differs between two builds of one source, unless both VMs preloaded the atoms.
  test "code generated from a map compiles alike in VMs that met its atoms in other orders",
       %{tmp_dir: dir} do
    src = Path.join(dir, "fields.ex")

    File.write!(src, """
    defmodule ChgAtomsFields do
      @fields Map.keys(%{zz_chg_field: 1, aa_chg_field: 2, mm_chg_field: 3})
      def fields, do: @fields
    end
    """)

    keys = ~w(zz_chg_field aa_chg_field mm_chg_field)
    list = Path.join(dir, "atoms.etf")
    File.write!(list, :erlang.term_to_binary(Enum.sort(keys)))

    build = fn name, preload?, keys ->
      ebin = Path.join([dir, name])
      File.mkdir_p!(ebin)
      env = if preload?, do: [{~c"CHG_ATOMS", String.to_charlist(list)}], else: []
      paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
      {:ok, peer, _} = :peer.start_link(%{connection: :standard_io, args: paths, env: env})

      try do
        :ok = :peer.call(peer, Atoms, :preload, [])
        for k <- keys, do: :peer.call(peer, :erlang, :binary_to_atom, [k])
        {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:elixir])

        {:ok, _, _} =
          :peer.call(peer, Kernel.ParallelCompiler, :compile_to_path, [
            [src],
            ebin,
            [return_diagnostics: true]
          ])
      after
        :peer.stop(peer)
      end

      File.read!(Path.join(ebin, "Elixir.ChgAtomsFields.beam"))
    end

    refute build.("plain-a", false, keys) == build.("plain-b", false, Enum.reverse(keys))
    assert build.("pre-a", true, keys) == build.("pre-b", true, Enum.reverse(keys))
  end

  test "the list holds the sources' literal atoms and aliases, sorted", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(
      Path.join(dir, "lib/a.ex"),
      "defmodule ChgAtomsList.A, do: def(f, do: %{chg_listed_key: :chg_listed_value})"
    )

    File.write!(Path.join(dir, "lib/b.ex"), """
    defmodule ChgAtomsList.Outer do
      alias ChgAtomsList.Multi.{One, Two.Three}
      defmodule Inner, do: def(f, do: __MODULE__.Leaf)
      defmodule Elixir.ChgAtomsList.Rooted, do: nil
    end
    """)

    Mix.Project.in_project(
      :chg_atoms_list,
      dir,
      [app: :chg_atoms_list, elixirc_paths: ["lib"]],
      fn _ ->
        list = Atoms.list()
        assert "chg_listed_key" in list
        assert "chg_listed_value" in list
        assert "Elixir.ChgAtomsList.A" in list
        assert "Elixir.ChgAtomsList.Outer.Inner" in list
        assert "Elixir.ChgAtomsList.Outer.Inner.Leaf" in list
        assert "Elixir.ChgAtomsList.Multi.One" in list
        assert "Elixir.ChgAtomsList.Multi.Two.Three" in list
        assert "Elixir.ChgAtomsList.Rooted" in list
        refute "Elixir.ChgAtomsList.Outer.Elixir.ChgAtomsList.Rooted" in list
        assert list == Enum.sort(list)
      end
    )
  end

  test "a missing, corrupt or malformed file makes no atom and raises nothing", %{
    tmp_dir: dir
  } do
    on_exit(fn -> System.delete_env("CHG_ATOMS") end)
    System.put_env("CHG_ATOMS", "/nonexistent/chg_atoms.etf")
    assert Atoms.preload() == :ok

    corrupt = Path.join(dir, "corrupt.etf")
    File.write!(corrupt, <<131, 255, 0, 1>>)
    System.put_env("CHG_ATOMS", corrupt)
    assert Atoms.preload() == :ok

    # A good entry before a bad one is not made either: the list is checked first.
    for {name, term} <- [
          {"mixed", ["chg_never_made_mixed", 42]},
          {"not_list", %{"chg_never_made_map" => 1}}
        ] do
      file = Path.join(dir, name <> ".etf")
      File.write!(file, :erlang.term_to_binary(term))
      System.put_env("CHG_ATOMS", file)
      assert Atoms.preload() == :ok
    end

    for a <- ["chg_never_made_mixed", "chg_never_made_map"] do
      assert_raise ArgumentError, fn -> String.to_existing_atom(a) end
    end
  end
end
