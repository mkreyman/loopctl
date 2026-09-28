defmodule LoopctlRunner.GitGrant do
  @moduledoc """
  The subagent git grant: the file `block-subagent-git.sh` looks for, armed for a loop session,
  removed at its teardown, and swept by the reaper when its holders are gone.

  That hook is a PreToolUse hook in the operator's USER settings, so it is live in any session
  that loads them. Without the grant, the engineer agent a loop session dispatches — which this
  repo's CLAUDE.md tells a session to do — has its `git commit` refused, and the agent's REPORT
  then reads as having chosen not to commit rather than as having been blocked. A capability lost
  silently, wearing the shape of a judgement call. A session launched under `--setting-sources ""`
  loads no user hook and has no `Agent` tool, so there the grant is inert: it is armed regardless,
  so the grant does not wait on the launch posture and the posture does not wait on the grant.

  Scoped to the session's own uuid, which is the id the hook keys on: its payload's session id is
  the `--session-id` `LoopctlRunner.Session` generates. An orphan left by a hard kill authorises a
  session id nothing will ever hold again, so it is inert — unlike the UNSCOPED sentinel KB
  7a9afe2e measures, which disarmed a guard for every session on that machine for three days. It
  is removed at teardown regardless. The content must not begin with "auto-armed": the hook
  expires those the moment it judges their run over, and this one's life is the session's.

  THE FILE FORMAT. The first line is `<stamp> <session id> owner <os pid> <start>`: the BEAM that
  armed it, identified as `LoopctlRunner.Owner` identifies a run's (the start in that module's
  form for this kernel, which on macOS holds spaces and runs to the end of the line), so a reused
  pid cannot pass for it. The second line,
  `session <os pid> <start>`, names the session's launcher the same way; a start that could not be
  read leaves the line ending at the pid. Both lines are what the sweep keys on — see `sweep/1`.

  WRITTEN IN TWO STEPS, VISIBLE IN ONE. `prepare/2` writes the owner line to a PENDING name before
  the session's Port opens — only then is `LOOP_GIT_GRANT` handed to the session, so a grant that
  cannot even be prepared is never announced. `arm/2` adds the launcher's line once the Port is
  open and renames the pending file into place: the one rename carries both lines, so no reader
  ever sees a grant without the session it belongs to. A pending file left by a kill in between
  is swept once the BEAM its owner line names is gone, or once it is ten minutes old (`sweep/1`).

  THE FILE IS THE GRANT; `LOOP_GIT_GRANT` ONLY SAYS WHERE IT IS. The variable is fixed at the fork,
  which comes before `arm/2` can fail, so it names where this session's grant is when there is one
  — never that there is one. What reads the grant — `block-subagent-git.sh` — tests the FILE, so
  an arm that failed after the announcement leaves a session with no grant rather than a wrong
  one, and says so in the log. Making the variable a promise instead would need arming before the
  fork, which is the owner-only grant the two steps exist to prevent.

  EDITING THIS CODE FROM A DISPATCHED AGENT: the same hook refuses a Bash command whose text
  writes a grant path — correctly, since creating the file is a complete self-grant — so a heredoc
  that writes these lines is blocked. Use the Edit or Write tool, which the hook does not police.
  It reads as a tooling failure the first time and is not one.
  """

  require Logger

  alias LoopctlRunner.{Config, Owner}

  @prefix ".subagent-git-grant-"
  # A grant is written to this name first and renamed over the grant, so no reader — the hook, a
  # sweep — ever sees a half-written file. It must NOT begin with @prefix, or the sweep and the
  # hook would read it as a grant of its own.
  @pending_prefix ".loopctl-runner-pending-"
  # What every grant this runner writes begins with. A grant a HUMAN typed carries none of it and
  # is theirs to remove.
  @stamp "loopctl-runner session"

  # A start in one of `LoopctlRunner.Owner`'s forms: a boot-relative token, or a UTC `ps lstart`
  # (which holds spaces, so it runs to the end of the line).
  @start "(boot:[0-9a-f-]+:[0-9]+|utc:[A-Za-z0-9: ]+)"
  @owner_line ~r/\A#{@stamp} \S+ owner ([0-9]+)(?: #{@start})?\z/
  @session_line ~r/\Asession ([0-9]+)(?: #{@start})?\z/

  @doc "What every grant file's name begins with, whoever wrote it."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "What a grant's pending name begins with, before `arm/2` renames it into place."
  @spec pending_prefix() :: String.t()
  def pending_prefix, do: @pending_prefix

  @doc """
  Where a session's grant lives: the CONFIG's grant directory — nil when the config has none.

  The suite drives the production path, so a hardcoded home here means every test that runs a
  session writes into the operator's `~/.claude` — and two of them leaked there before this took
  the directory from the config (measured 2026-09-16). Production's config carries no `grant_dir`
  and `Config` fills in `Config.default_grant_dir/0`, which is where `block-subagent-git.sh` looks.
  A `Config` built without `Config.load/1` can still carry nil, and answers no path.
  """
  @spec path(Config.t(), String.t()) :: String.t() | nil
  def path(%Config{grant_dir: nil}, _session_id), do: nil
  def path(%Config{grant_dir: dir}, session_id), do: Path.join(dir, @prefix <> session_id)

  @doc """
  Readies `session_id`'s grant BEFORE its session launches: writes the owner line — this BEAM —
  to the grant's pending name and returns the path the grant will have, or an error, said out
  loud, when it cannot. Only a prepared grant is announced to the session (`LOOP_GIT_GRANT`), so a
  directory that cannot be written, or a BEAM whose own start cannot be read, arms nothing and
  announces nothing. The run goes ahead either way.
  """
  @spec prepare(Config.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def prepare(config, session_id) do
    case {path(config, session_id), Owner.current()} do
      {nil, _} ->
        refused(session_id, :no_grant_dir, "the config names no grant_dir")

      {_path, {:error, :no_start}} ->
        refused(session_id, :no_start, "this BEAM's own start time could not be read")

      {path, {:ok, owner}} ->
        File.mkdir_p(Path.dirname(path))

        case File.write(pending(path), line(session_id, owner)) do
          :ok ->
            {:ok, path}

          {:error, posix} ->
            File.rm(pending(path))
            refused(session_id, posix, :file.format_error(posix))
        end
    end
  end

  @doc """
  Arms the grant `prepare/2` readied at `path`, naming the session's `launcher`, and returns the
  path — or an error, said out loud, leaving no file behind.

  The launcher's line joins the owner's in the pending file, which is then renamed into place: a
  grant that named only its BEAM would outlive a session whose GenServer is killed outright (no
  terminate/2, and the daemon lives on), and nothing would sweep it until the daemon died. Nothing
  is armed without the owner line `prepare/2` wrote — the pending file is read back, not assumed.
  """
  @spec arm(String.t(), Owner.t()) :: {:ok, String.t()} | {:error, term()}
  def arm(path, launcher) do
    pending = pending(path)

    with {:ok, owner_line} <- File.read(pending),
         :ok <- File.write(pending, owner_line <> session_line(launcher)),
         :ok <- File.rename(pending, path) do
      {:ok, path}
    else
      {:error, posix} ->
        File.rm(pending)
        refused(session_of(path), posix, :file.format_error(posix))
    end
  end

  # Said out loud rather than swallowed: the run still happens, and its dispatched agent silently
  # cannot commit, which is the exact failure this exists to prevent.
  defp refused(session_id, reason, why) do
    Logger.warning(
      "could not arm the subagent git grant for session #{session_id} (#{why}); " <>
        "a dispatched agent's commit will be refused and its report will read as declining"
    )

    {:error, reason}
  end

  @doc """
  Removes the grant at `path`, and its pending file if `arm/2` never ran (nil: none was prepared).
  Answers for the grant.
  """
  @spec disarm(String.t() | nil) :: :ok | {:error, File.posix()}
  def disarm(nil), do: :ok

  def disarm(path) do
    File.rm(pending(path))
    File.rm(path)
  end

  @doc false
  @spec line(String.t(), Owner.t(), Owner.t() | nil) :: String.t()
  def line(session_id, owner, session \\ nil) do
    first = "#{@stamp} #{session_id} owner #{identity(owner)}\n"
    if session, do: first <> session_line(session), else: first
  end

  # The launcher's line, which `arm/2` appends and `line/3` writes: one spelling, so what the sweep
  # parses is what both write.
  defp session_line(launcher), do: "session #{identity(launcher)}\n"

  defp identity(%{"beam_os_pid" => pid, "beam_start_id" => nil}), do: "#{pid}"
  defp identity(%{"beam_os_pid" => pid, "beam_start_id" => started}), do: "#{pid} #{started}"

  defp pending(path), do: Path.join(Path.dirname(path), @pending_prefix <> session_of(path))

  defp session_of(path), do: String.replace_prefix(Path.basename(path), @prefix, "")

  @doc """
  Every grant file in `dir`, whoever wrote it; [] when `dir` cannot be listed.

  `File.ls/1` rather than `Path.wildcard/1`: every grant's name begins with a DOT, and the
  wildcard's `*` does not match a leading dot — it returned nothing here, which would have made
  the sweep a no-op that logs nothing and passes any test asserting "no grants left".
  """
  @spec list(String.t() | nil) :: [String.t()]
  def list(dir), do: dir |> names() |> grants(dir)

  defp names(nil), do: []

  defp names(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end

  defp grants(names, dir),
    do: for(name <- names, String.starts_with?(name, @prefix), do: Path.join(dir, name))

  @doc """
  Removes grants this runner wrote and did not clean up, and returns their paths.

  TEARDOWN ONLY RUNS ON THE HAPPY PATH — the reason `LoopctlRunner.Reaper` exists at all — so a
  halt or a hard kill leaks a grant. Measured on a dev
  machine, 2026-09-16: 125 of them in `~/.claude`, one per test run, the oldest eight hours old. Each is
  inert on its own — it authorises a uuid nothing will hold again — but `block-subagent-git.sh`
  walks every sentinel and forks a `find` per entry on each refusal.

  ONLY ORPHANS: a file is removed when its first line carries this runner's stamp AND either the
  owner BEAM it names is no longer running (`LoopctlRunner.Owner.alive?/1`), or the session
  launcher its second line names is not (`LoopctlRunner.Owner.process_alive?/1`: the launcher is a
  shell). This runs before EVERY run, from `mix loopctl.reap` too, and alongside a daemon whose
  sessions are live — a grant whose BEAM and session are both running is disarming a dispatch in
  flight, and the hook would begin refusing that session's subagent commits mid-run. A file with
  no stamp, or with an owner that does not parse (a grant a human typed, one overwritten by
  another hook), is left alone: whoever wrote it removes it. A config with no directory (nil) has
  nothing to sweep.
  """
  @spec sweep(String.t() | nil) :: [String.t()]
  def sweep(dir) do
    # Listed once: the pending files and the grants are both read off this one listing.
    names = names(dir)
    sweep_pending(names, dir)

    names
    |> grants(dir)
    # Every grant a daemon armed names the same BEAM, so its liveness is asked once a sweep.
    |> Enum.map_reduce(%{}, &orphaned?/2)
    |> elem(0)
    |> Enum.filter(&(&1 && File.rm(&1) == :ok))
  end

  # A pending file carries no grant prefix, so neither the hook nor the sweep above ever reads it;
  # only this removes it. `prepare/2` and `arm/2` straddle one Port.open, milliseconds apart, so a
  # pending file older than this is one whose Session was killed between the two, whoever its
  # owner is — and that owner, a daemon, may live for weeks. Younger, it is judged the way its
  # grant would be: removed once the BEAM that prepared it is gone, or the launcher a line
  # `arm/2` wrote names. One whose `arm/2` is stretched past this — a laptop suspended mid-launch
  # — finds its pending file gone and says so (`arm/2`), and its session runs without a grant.
  @pending_max_age_s 600

  defp sweep_pending(names, dir) do
    now = System.os_time(:second)

    for name <- names,
        String.starts_with?(name, @pending_prefix),
        path = Path.join(dir, name),
        pending_orphaned?(path, now),
        do: File.rm(path)

    :ok
  end

  defp pending_orphaned?(path, now) do
    stale? =
      match?(
        {:ok, %File.Stat{mtime: mtime}} when now - mtime > @pending_max_age_s,
        File.stat(path, time: :posix)
      )

    stale? or
      case holders(path) do
        {owner, session} -> not Owner.alive?(owner) or session_gone?(session)
        nil -> false
      end
  end

  # The path when it is an orphan, else false, threading the owner liveness already asked.
  defp orphaned?(path, seen) do
    case holders(path) do
      nil ->
        {false, seen}

      {owner, session} ->
        {owner_alive?, seen} = memo_alive(owner, seen)

        {(not owner_alive? or session_gone?(session)) && path, seen}
    end
  end

  # A grant with no session line is judged by its owner alone.
  defp session_gone?(nil), do: false
  defp session_gone?(session), do: not Owner.process_alive?(session)

  defp memo_alive(owner, seen) do
    case seen do
      %{^owner => alive?} ->
        {alive?, seen}

      _ ->
        alive? = Owner.alive?(owner)
        {alive?, Map.put(seen, owner, alive?)}
    end
  end

  @doc """
  The owner BEAM and the session launcher the grant at `path` records, as `LoopctlRunner.Owner`
  shapes them — the session nil when the file has no session line that parses — or nil when the
  file is unreadable, carries no stamp of this runner's, or names no owner that parses. A start is
  the string it was written as; one recorded by pid alone has a nil `beam_start_id`, and no line
  carries a `beam_started`.
  """
  @spec holders(String.t()) :: {Owner.t(), Owner.t() | nil} | nil
  def holders(path) do
    with {:ok, contents} <- File.read(path),
         [first | rest] = String.split(contents, "\n", parts: 3),
         %{} = owner <- identity_in(@owner_line, first) do
      {owner, identity_in(@session_line, List.first(rest, ""))}
    else
      _ -> nil
    end
  end

  defp identity_in(regex, line) do
    with [_, pid | started] <- Regex.run(regex, line) do
      Owner.of(String.to_integer(pid), List.first(started))
    end
  end
end
