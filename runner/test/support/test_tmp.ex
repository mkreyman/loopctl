defmodule LoopctlRunner.TestTmp do
  @moduledoc """
  Where the suite's temporary files go: one root per test BEAM, `loopctl-runner-suite-<os pid>`
  under the system temp directory, made private to this user, removed by its own
  `ExUnit.after_suite/1` callback once the straggler sweep has run, and swept at the next start
  when the BEAM that owned it is gone — killed on a timeout, stopped with Ctrl-C twice — because a
  killed BEAM runs no callback.

  Every directory a test asks for is `uuid`-named inside the root, so two suites running at once
  (a mutation batch, parallel worktrees) never share one: `System.unique_integer/1` is unique only
  within a BEAM, and three fresh BEAMs were measured returning the same range (2026-09-29 UTC,
  Elixir 1.19.5, OTP 28). The suite's own files (the straggler ledger, sweep tree files) go in
  `.suite` inside the root, a name no test label produces.

  36,100 per-test directories left in /tmp filled minis' tmpfs inodes (measured 2026-09-29 UTC),
  after which every git in /tmp failed "No space left on device".

  Every function takes the temp directory as `base`, so the tests drive it on a directory of their
  own; the suite passes the system one.
  """

  alias LoopctlRunner.{Owner, Session}

  @prefix "loopctl-runner-suite-"
  @owner_file "owner.json"
  # What suites before roots left directly in the temp directory, swept once this old: per-test
  # directories, straggler ledgers, sweep tree files.
  @legacy ["loopctl-runner-test-", "loopctl-runner-stragglers-", "loopctl-runner-sweep-"]
  @legacy_after_s 3_600

  @doc """
  This BEAM's root: the one `arm/1` made, fixed then, so nothing a test does to `TMPDIR` moves it;
  under `base` when one is given.
  """
  @spec root() :: String.t()
  def root,
    do: Application.get_env(:loopctl_runner, :test_tmp_root) || root(System.tmp_dir!())

  @spec root(String.t()) :: String.t()
  def root(base), do: Path.join(base, @prefix <> System.pid())

  @doc "Where the suite's own files go, apart from every test's directories."
  @spec suite_dir() :: String.t()
  def suite_dir, do: Path.join(root(), ".suite")

  @doc """
  Sweeps what dead suites left under `base`, then makes this BEAM's root, private to this user,
  and records its owner in it. A root at that path owned by someone else is refused: its name is
  predictable, and the suite runs scripts it writes there.
  """
  @spec arm(String.t()) :: :ok
  def arm(base \\ System.tmp_dir!()) do
    sweep_stale(base)
    root = root(base)
    File.mkdir_p!(root)
    ours!(root)
    File.chmod!(root, 0o700)
    File.mkdir_p!(Path.join(root, ".suite"))
    # Recorded once, like the suite's env_ps probe, and never changed while it runs.
    if base == System.tmp_dir!(), do: Application.put_env(:loopctl_runner, :test_tmp_root, root)

    case Owner.current() do
      {:ok, owner} -> File.write!(Path.join(root, @owner_file), JSON.encode!(owner))
      {:error, :no_start} -> :ok
    end
  end

  # The path itself, never what a link there points at: a directory, this user's.
  defp ours!(root) do
    {uid, 0} = System.cmd("id", ["-u"])
    %File.Stat{uid: owner, type: type} = File.lstat!(root)

    unless type == :directory and Integer.to_string(owner) == String.trim(uid),
      do: raise("#{root} is a #{type} of uid #{owner}, not this user's directory: not written")
  end

  @doc """
  A new directory of this suite's, named after `label`, never shared with another suite. The root
  is `arm/1`'s: one that is gone is an error, never quietly made again without its owner.
  """
  @spec dir!(String.t()) :: String.t()
  def dir!(label) do
    dir = Path.join(root(), "#{label}-#{Session.uuid4()}")
    File.mkdir!(dir)
    dir
  end

  @doc """
  Removes the roots under `base` whose owning BEAM is gone, and what suites before roots left there
  once an hour old. Returns what it removed.
  """
  @spec sweep_stale(String.t()) :: [String.t()]
  def sweep_stale(base) do
    names =
      case File.ls(base) do
        {:ok, names} -> names
        {:error, _} -> []
      end

    stale =
      for name <- names,
          path = Path.join(base, name),
          (String.starts_with?(name, @prefix) and stale_root?(path)) or
            (Enum.any?(@legacy, &String.starts_with?(name, &1)) and
               older_than?(path, @legacy_after_s)),
          do: path

    for path <- stale, removed?(path), do: path
  end

  # A stale entry that will not go is said, since what is left keeps filling the tmpfs.
  defp removed?(path) do
    case File.rm_rf(path) do
      {:ok, _} ->
        true

      {:error, reason, at} ->
        IO.puts(:stderr, "could not sweep #{path}: #{at}: #{:file.format_error(reason)}")
        false
    end
  end

  # By its recorded owner; with none recorded, by whether the pid in its name still runs. Never by
  # age: a root's own mtime says nothing about the files a live suite writes below it.
  defp stale_root?(root) do
    with {:ok, raw} <- File.read(Path.join(root, @owner_file)),
         {:ok, %{} = owner} <- JSON.decode(raw) do
      not Owner.alive?(owner)
    else
      _ -> not pid_running?(String.replace_prefix(Path.basename(root), @prefix, ""))
    end
  end

  defp pid_running?(pid) do
    case Integer.parse(pid) do
      {n, ""} -> Owner.process_alive?(%{"beam_os_pid" => n})
      _ -> true
    end
  end

  defp older_than?(path, seconds) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> System.os_time(:second) - mtime > seconds
      {:error, _} -> false
    end
  end

  @doc """
  The `ExUnit.after_suite/1` callback: removes this BEAM's root under `base`, and says so loudly
  when it cannot, since a root left behind is what fills the tmpfs.
  """
  @spec sweep_suite(map(), String.t() | nil) :: :ok
  def sweep_suite(_results, base \\ nil) do
    root = if base, do: root(base), else: root()

    case File.rm_rf(root) do
      {:ok, _} ->
        :ok

      {:error, reason, path} ->
        IO.puts(:stderr, """

        THE SUITE COULD NOT REMOVE ITS TEMPORARY FILES: #{path}: #{:file.format_error(reason)}
        The next suite on this machine sweeps #{root} once this BEAM is gone.
        """)
    end
  end
end
