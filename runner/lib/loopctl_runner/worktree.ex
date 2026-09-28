defmodule LoopctlRunner.Worktree do
  @moduledoc """
  Creating and removing the git worktree a session runs in.

  The session's cwd must BE the worktree (design §8): `block-foreign-repo-write.sh`
  keys on `git rev-parse --git-common-dir`, so a session started elsewhere with the
  target passed through `--add-dir` has every write refused.

  A new branch is cut from `origin`'s copy of the base when a bounded fetch of it succeeded and the
  local base holds nothing it lacks, and from the base as given otherwise. Nothing here commits,
  pushes or merges. A branch is RETIRED when it holds nothing `origin`'s base lacks: no commit of
  its own, or commits `origin`'s base carries by history, by patch-id or by content (`shipped?/5`),
  which is how a squash-merged branch looks. Teardown retires such a branch by removing its tree and
  deleting it; `create/4` resets it to a fresh start inside the tree that is already there, so a
  re-dispatch never starts from work that shipped and never rebuilds what the tree ignores. Work a
  session committed and did not ship is kept and reported, never discarded, and so is a worktree
  holding a repository whose work its removal would lose. The fetch is the one network call here;
  when it fails, commits only it could vouch for are kept and the failure is named.
  """

  alias LoopctlRunner.ProcessGroup

  @worktrees_subdir ".claude/worktrees"
  @fetch_timeout_ms 30_000
  # A fetch error is shipped in a trace event, whose data loopctl caps.
  @fetch_error_chars 300
  # A ref lock is usually a concurrent fetch or gc in the same repository finishing: one retry.
  @lock_retry_ms 500
  # The squash search reads origin's history since the fork point, which on a busy base is large.
  @log_timeout_ms 30_000
  # Past this many paths the squash search is not run: the arguments would approach ARG_MAX.
  @max_squash_paths 1_000
  # The nested-repository scan walks the whole tree before a removal.
  @scan_timeout_ms 30_000
  # Directories that scan does not descend: build output and fetched dependencies, which the next
  # build or `deps.get` recreates, and which (node_modules) are large enough to take it past its bound.
  @unscanned ~w(deps _build node_modules .elixir_ls .lexical)

  # Variables that make git operate on a DIFFERENT repository, index or tree than the
  # directory it runs in. Git exports some of them to hooks, so a runner started from a
  # hook or another git process inherits them: an inherited GIT_INDEX_FILE made
  # `git worktree add` fail (measured, under the pre-commit gate), and an inherited GIT_DIR
  # would point a session's commits at another repo. Every git call here, and the session
  # environment, clears them.
  @repo_locating_env ~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
                        GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX)

  # The same diff whatever the operator's diff config says, so a branch's patch-id and a commit's
  # are computed from identically formatted text.
  @diff_opts ~w(--no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/)

  @doc "The git variables to unset in any process that should find its repository by cwd."
  @spec repo_locating_env() :: [String.t()]
  def repo_locating_env, do: @repo_locating_env

  @doc "How long `fetch_base/2` lets a fetch run before killing it."
  @spec fetch_timeout_ms() :: pos_integer()
  def fetch_timeout_ms, do: @fetch_timeout_ms

  @typedoc "What a worktree and its branch hold that the base does not (see `work_in/4`)."
  @type work :: :none | :dirty | :commits | :unknown
  @typedoc "What `work_in/4` read its answer from (see `fingerprint/4`)."
  @type fingerprint :: tuple()
  @typedoc "What happened to the fetch of `origin`'s base: `:skipped` when nothing asked for it."
  @type fetch :: :ok | {:error, String.t()} | :skipped
  @type created :: %{
          path: String.t(),
          branch: String.t(),
          base: String.t(),
          reused: boolean(),
          start: String.t() | nil,
          fetch: fetch()
        }
  @type removal :: %{
          worktree: :removed | :absent | {:kept, String.t()} | {:error, String.t()},
          branch: :deleted | :absent | {:kept, String.t()} | {:error, String.t()}
        }

  @spec path_for(String.t(), String.t()) :: String.t()
  def path_for(repo_path, story_id),
    do: Path.join([repo_path, @worktrees_subdir, "loop-" <> story_id])

  @doc """
  Creates the worktree, or adopts one already on disk for the same branch.

  Adoption is what makes the stage idempotent on replay (design §3): a crashed run's worktree
  that holds work is recognised rather than duplicated. A branch that exists WITHOUT the worktree
  and holds unshipped commits is refused — they may be an earlier story's. A branch holding
  nothing `origin`'s base lacks, by the same test teardown applies, starts again: inside the tree
  already at `path` its branch is reset to a fresh start, and with no tree it is deleted and cut
  anew. A re-dispatch never starts from work that already shipped, nor from a stale base.

  `start` is the revision a new branch was cut from (nil when adopted) and `fetch` whether the
  fetch of `origin`'s base worked, so a trace shows a branch cut from a stale local base.
  """
  @spec create(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, created()} | {:error, String.t()}
  def create(repo_path, path, branch, base) do
    # ONE bounded fetch, made only when this call needs origin's base: to ask whether an existing
    # branch shipped, or to cut a new branch from it. Create and teardown each fetch: they are
    # different moments in a run's life, and each needs origin's base as it is then.
    work = if branch_exists?(repo_path, branch), do: work_in(repo_path, path, branch, base)
    fetch = if fetch_to_create?(work, path), do: fetch_base(repo_path, base), else: :skipped
    retire? = work != nil and retirable?(repo_path, path, branch, base, work, fetch)

    with {:ok, created} <- cut(repo_path, path, branch, base, fetch, retire?) do
      {:ok, Map.put(created, :fetch, fetch)}
    end
  end

  # No branch: a new one is cut, from origin's base, unless a tree already sits at the path. A
  # branch that may be retired is followed by a new cut, and one with commits asks origin whether
  # they shipped; a tree holding uncommitted or uncountable work is adopted or refused unasked.
  defp fetch_to_create?(nil, path), do: not File.dir?(path)
  defp fetch_to_create?(work, _path), do: work == :none or asks_origin?(work)

  # A tree already on disk is never removed here. Removing and re-adding one that holds nothing
  # threw away what it ignores (`_build`, `deps`: a full rebuild), failed on a locked tree, and
  # could not proceed past repositories nested in it; resetting its branch inside it keeps all
  # three. A branch with no tree is deleted and cut again.
  defp cut(repo_path, path, branch, base, fetch, retire?) do
    cond do
      File.dir?(path) and retire? ->
        reset(repo_path, path, branch, base, fetch)

      File.dir?(path) ->
        adopt(path, branch, base)

      retire? ->
        recut(repo_path, path, branch, base, fetch)

      branch_exists?(repo_path, branch) ->
        {:error, "branch #{branch} already exists without a worktree"}

      true ->
        add(repo_path, path, branch, base, fetch)
    end
  end

  defp recut(repo_path, path, branch, base, fetch) do
    case retire(repo_path, path, branch) do
      %{branch: deleted} when deleted in [:deleted, :absent] ->
        add(repo_path, path, branch, base, fetch)

      outcome ->
        {:error,
         "branch #{branch} holds nothing origin's #{name(base)} lacks but could not be " <>
           "retired: " <> inspect(outcome)}
    end
  end

  # `checkout -B` moves the branch and HEAD to the start and leaves ignored and nested files where
  # they are; it refuses rather than overwrite a change made since the tree was read. `--no-track`
  # for the reason `add/5` gives.
  defp reset(repo_path, path, branch, base, fetch) do
    start = start(repo_path, base, fetch)

    with :ok <- own_tree(repo_path, path),
         {:ok, _} <- git(path, ["checkout", "-q", "--no-track", "-B", branch, start]) do
      {:ok, %{path: path, branch: branch, base: base, reused: false, start: start}}
    else
      {:error, out} -> {:error, "cannot reset #{path} to #{start}: #{out}"}
    end
  end

  # `path` is the top of a worktree of `repo_path`. Git reads a directory that is not as part of
  # whatever repository encloses it — the main tree, for a stray directory under `.claude/` — and
  # a checkout there would move the main tree's branch.
  defp own_tree(repo_path, path) do
    if git(path, ["rev-parse", "--show-prefix"]) == {:ok, ""} and
         common_dir(path) == common_dir(repo_path),
       do: :ok,
       else: {:error, "not the top of a worktree of #{repo_path}"}
  end

  defp common_dir(dir) do
    case git(dir, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) do
      {:ok, common} -> common
      {:error, _} -> nil
    end
  end

  defp adopt(path, branch, base) do
    case git(path, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, ^branch} -> {:ok, %{path: path, branch: branch, base: base, reused: true, start: nil}}
      {:ok, other} -> {:error, "#{path} exists on branch #{other}, not #{branch}"}
      {:error, out} -> {:error, "#{path} exists but is not a worktree: #{out}"}
    end
  end

  # `--no-track`: a branch cut from a remote-tracking ref would otherwise take origin's base as its
  # upstream, and a bare `git push` under `push.default = upstream` would push the session's work
  # to it.
  defp add(repo_path, path, branch, base, fetch) do
    start = start(repo_path, base, fetch)

    with {:ok, _} <- commit(repo_path, start),
         {:ok, _} <- git(repo_path, ["worktree", "add", "--no-track", "-b", branch, path, start]) do
      {:ok, %{path: path, branch: branch, base: base, reused: false, start: start}}
    else
      {:error, out} -> {:error, "cannot create worktree from #{start}: #{out}"}
    end
  end

  # The LOCAL base is usually behind what has shipped: nothing on a dev machine pulls it. Cut from
  # origin's copy when this call fetched it and the local base, if there is one, is behind it. Cut
  # from the base as given when the fetch did not work, origin's ref does not resolve, or the local
  # base holds commits origin's lacks — unpushed or diverged — which a cut from origin leaves out.
  defp start(repo_path, base, fetch) do
    remote = origin_ref(base)

    if fetch == :ok and resolves?(repo_path, remote) and
         (not resolves?(repo_path, base) or ancestor?(repo_path, base, remote)),
       do: remote,
       else: base
  end

  defp ancestor?(repo_path, commit, of),
    do: match?({:ok, _}, git(repo_path, ["merge-base", "--is-ancestor", commit, of]))

  defp resolves?(repo_path, ref), do: match?({:ok, _}, commit(repo_path, ref))

  defp commit(dir, ref), do: git(dir, ["rev-parse", "--verify", "--quiet", ref <> "^{commit}"])

  defp branch_exists?(repo_path, branch) do
    match?(
      {:ok, _},
      git(repo_path, ["rev-parse", "--verify", "--quiet", "refs/heads/" <> branch])
    )
  end

  @doc """
  Removes the worktree, and deletes its branch, only when they hold nothing `origin`'s base lacks:
  no uncommitted changes, and no commit beyond the base that `origin`'s base does not already
  carry. Otherwise both are kept, with the reason, so a re-run of the same story adopts the
  worktree (`create/4`) instead of being refused or discarding the work.

  Every removal the runner performs on a branch's worktree goes through here, teardown included:
  a worktree a re-run adopted may hold the crashed run's work, and a session that started nothing
  has no business discarding it.

  The four-argument form reads the tree and fetches when `asks_origin?/1` says so. A caller
  deciding several removals (the reaper) reads each tree once with `work_in/4`, fetches each base
  once, and passes both here.
  """
  @spec remove_if_clean(String.t(), String.t(), String.t(), String.t()) :: removal()
  def remove_if_clean(repo_path, path, branch, base) do
    work = work_in(repo_path, path, branch, base)
    fetch = if asks_origin?(work), do: fetch_base(repo_path, base), else: :skipped
    remove_if_clean(repo_path, path, branch, base, work, fetch)
  end

  @spec remove_if_clean(String.t(), String.t(), String.t(), String.t(), work(), fetch()) ::
          removal()
  def remove_if_clean(repo_path, path, branch, base, work, fetch) do
    if retirable?(repo_path, path, branch, base, work, fetch) do
      retire(repo_path, path, branch)
    else
      reason = describe(work, base, fetch)
      %{worktree: {:kept, reason}, branch: {:kept, reason}}
    end
  end

  @doc """
  Whether deciding this work's removal asks `origin`'s base: true only when committed work is all
  it holds, the one case `origin` can answer. Uncommitted changes, and commits that could not be
  counted, are kept without asking, so a reap of clean, dirty or held trees makes no network call.
  """
  @spec asks_origin?(work() | nil) :: boolean()
  def asks_origin?(:commits), do: true
  def asks_origin?(_work), do: false

  # The ONE decision create's reset and teardown share. `:none` needs no fetch: `work_in/4` says it
  # only where deleting the branch provably loses nothing, whatever origin says.
  defp retirable?(_repo_path, _path, _branch, _base, :none, _fetch), do: true

  defp retirable?(repo_path, path, branch, base, work, fetch),
    do: asks_origin?(work) and shipped?(repo_path, path, branch, base, fetch)

  defp describe(:dirty, _base, _fetch), do: "uncommitted changes"
  defp describe(:unknown, base, _fetch), do: "commits beyond #{base} could not be counted"

  defp describe(:commits, base, {:error, error}),
    do: "commits beyond #{base}; origin's #{name(base)} could not be fetched: #{error}"

  defp describe(:commits, base, _fetch), do: "commits beyond #{base}"

  # Every tip — the branch, and a HEAD that left it — carries nothing origin's base lacks, asked of
  # origin's base as this call's fetch left it. Only a fetch that worked counts: a remote-tracking
  # ref from an earlier fetch may predate a revert, and a failure answers no, keeping the work.
  defp shipped?(repo_path, path, branch, base, :ok) do
    remote = origin_ref(base)
    tips = tips(repo_path, path, branch)

    tips != [] and resolves?(repo_path, remote) and
      Enum.all?(tips, &tip_shipped?(repo_path, remote, &1))
  end

  defp shipped?(_repo_path, _path, _branch, _base, _fetch), do: false

  defp tip_shipped?(_repo_path, _remote, :unreadable), do: false

  # Cheapest first: the squash search reads origin's history since the fork point.
  defp tip_shipped?(repo_path, remote, tip),
    do:
      picked?(repo_path, remote, tip) or merges_to_nothing?(repo_path, remote, tip) or
        squashed?(repo_path, remote, tip)

  # Every commit the tip has is in origin's base by history (a merge or a fast-forward) or by its
  # own patch-id (a rebase merge): `git cherry` marks each such commit `-`, and lists none when
  # history already reaches the tip. It never lists a merge commit, so what a merge adds of its own
  # (a conflict resolution) is in no patch it compares: with a merge origin lacks, it is not asked.
  defp picked?(repo_path, remote, tip) do
    with {:ok, "0"} <- git(repo_path, ["rev-list", "--count", "--merges", tip, "^" <> remote]),
         {:ok, out} <- git(repo_path, ["cherry", remote, tip]) do
      out |> String.split("\n", trim: true) |> Enum.all?(&(&1 =~ ~r/^- /))
    else
      _ -> false
    end
  end

  # A squash merge: ONE commit since the fork point whose patch-id is that of everything the branch
  # changed. Unlike comparing content with origin's base as it is NOW, a later commit editing the
  # same lines does not hide it. The log is limited to the paths the branch changed, which are all a
  # squash of it touches, so it reads what the branch touched rather than all origin merged since.
  # `--full-history`: path limiting would otherwise simplify away side branches carrying the squash.
  defp squashed?(repo_path, remote, tip) do
    with {:ok, fork} <- git(repo_path, ["merge-base", tip, remote]),
         {:ok, paths} <- changed_paths(repo_path, fork, tip),
         [id] <- patch_ids(repo_path, ["diff" | @diff_opts] ++ [fork, tip]) do
      log =
        [
          "--literal-pathspecs",
          "log",
          "-p",
          "--no-merges",
          "--full-history",
          "--format=commit %H"
        ]

      id in patch_ids(repo_path, log ++ @diff_opts ++ [fork <> ".." <> remote, "--" | paths])
    else
      _ -> false
    end
  end

  # `--no-renames`: a rename names BOTH its paths, or the log would show the squash's half of it.
  defp changed_paths(repo_path, fork, tip) do
    args = ["diff", "--name-only", "-z", "--no-renames", fork, tip]

    with {:ok, out, 0} <- bounded_git(repo_path, args),
         paths when paths != [] and length(paths) <= @max_squash_paths <-
           String.split(out, <<0>>, trim: true) do
      {:ok, paths}
    else
      _ -> :error
    end
  end

  # Merged BY CONTENT: merging the tip into origin's base changes nothing. This is the one test that
  # recognises a squash whose conflicts were resolved in the branch's favour, whose patch-id is not
  # the branch's; a later edit to the same lines makes it conflict, and it then answers no.
  defp merges_to_nothing?(repo_path, remote, tip) do
    with {:ok, tree} <- git(repo_path, ["rev-parse", "--verify", "--quiet", remote <> "^{tree}"]),
         {:ok, out} <-
           git(repo_path, ["merge-tree", "--write-tree", "--no-messages", remote, tip]) do
      out |> String.split("\n", parts: 2) |> hd() == tree
    else
      _ -> false
    end
  end

  # One patch-id per patch in the output of `git <args>`, as `git patch-id --stable` computes it. A
  # timeout yields none, which answers "not squashed": the work is kept, never guessed away.
  defp patch_ids(repo_path, args) do
    script = ~s(dir=$1; shift; git -C "$dir" "$@" </dev/null 2>/dev/null | git patch-id --stable)

    case bounded(script, [repo_path | args], @log_timeout_ms) do
      {:ok, out, 0} ->
        out |> String.split("\n", trim: true) |> Enum.map(&hd(String.split(&1, " ")))

      _ ->
        []
    end
  end

  defp tips(repo_path, path, branch) do
    branch_tip =
      case git(repo_path, ["rev-parse", "--verify", "--quiet", "refs/heads/" <> branch]) do
        {:ok, sha} -> [sha]
        {:error, _} -> []
      end

    head =
      case File.dir?(path) && git(path, ["rev-parse", "--verify", "--quiet", "HEAD"]) do
        {:ok, sha} -> [sha]
        {:error, _} -> [:unreadable]
        false -> []
      end

    Enum.uniq(branch_tip ++ head)
  end

  defp origin_ref(base), do: "refs/remotes/origin/" <> name(base)

  defp name(base), do: String.replace_prefix(base, "origin/", "")

  @doc """
  Fetches `base` from `origin` into its remote-tracking ref: `:ok`, or `{:error, reason}` naming
  what git said or the timeout. Git itself strips the credentials from a URL it reports
  (measured, git 2.50: `https://user:secret@host/x.git` is reported as `https://host/x.git`).

  Bounded, because `System.cmd/3` is not: a hung remote must not hang a teardown. The explicit
  refspec updates origin's ref whatever the repo's fetch config says. It writes nothing else: no
  `FETCH_HEAD`, which a session's own `git pull` in the same repository reads, and no automatic
  maintenance. A ref another git process holds locked is retried once, within the same bound.

  This is the RUNNER's own fetch, never a session's, so it must never prompt: stdin is /dev/null,
  git's terminal prompt is off, no askpass program runs, a credential helper is told not to
  interact, and ssh runs in BatchMode.
  `ProcessGroup.run/4` supplies the rest — no controlling terminal, and the whole group killed on
  timeout.
  """
  @spec fetch_base(String.t(), String.t()) :: :ok | {:error, String.t()}
  def fetch_base(repo_path, base) do
    case System.find_executable("git") do
      nil ->
        {:error, "git is not on PATH"}

      git ->
        deadline = System.monotonic_time(:millisecond) + @fetch_timeout_ms
        attempt = fn -> fetch_once(git, repo_path, base, deadline) end
        attempt.() |> retry_if_locked(attempt) |> fetch_outcome()
    end
  end

  # `exec` keeps the pid, so the git ProcessGroup.run times out is still the group leader.
  #
  # No askpass program runs. Git falls through GIT_ASKPASS, then core.askPass, then SSH_ASKPASS, and
  # runs the first it finds even with its terminal prompt off (measured, git 2.50). The two
  # variables are unset (`bounded/3`), and an empty `core.askPass` on the command line outranks
  # any config file. ssh has a fallback of its own for an unset SSH_ASKPASS, a default askpass
  # binary it runs when DISPLAY is set; `SSH_ASKPASS_REQUIRE=never` turns that off (OpenSSH 8.4+).
  # Setting the variables EMPTY is not an option here: a Port drops an empty value, which is unset.
  #
  # A credential helper still runs, and one may open a window of its own: Git Credential Manager
  # does unless `credential.interactive` is false or GCM_INTERACTIVE is never, and reads either.
  defp fetch_once(git, repo_path, base, deadline) do
    args =
      [git, "-C", repo_path, "-c", "core.askPass=", "-c", "credential.interactive=false"] ++
        ["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--no-auto-maintenance"] ++
        ["origin", "+refs/heads/#{name(base)}:#{origin_ref(base)}"]

    remaining = max(deadline - System.monotonic_time(:millisecond), 1)

    env =
      [{"SSH_ASKPASS_REQUIRE", "never"}, {"GCM_INTERACTIVE", "never"} | batch_ssh(repo_path)] ++
        operator_auth_env()

    bounded(~s(exec "$@" </dev/null), args, remaining, env)
  end

  defp retry_if_locked({:ok, out, status} = result, attempt) when status != 0 do
    if out =~ "cannot lock ref" do
      Process.sleep(@lock_retry_ms)
      attempt.()
    else
      result
    end
  end

  defp retry_if_locked(result, _attempt), do: result

  defp fetch_outcome({:ok, _out, 0}), do: :ok
  defp fetch_outcome({:error, :timeout}), do: {:error, "timed out after #{@fetch_timeout_ms} ms"}

  defp fetch_outcome({:ok, out, status}) do
    said =
      out
      |> String.split()
      |> Enum.join(" ")
      |> String.slice(0, @fetch_error_chars)

    {:error, "git fetch exited #{status}: #{said}"}
  end

  # BatchMode added to whichever ssh command git would run, in git's own order — the environment's
  # GIT_SSH_COMMAND, then core.sshCommand, then GIT_SSH, then plain ssh — so the operator's key and
  # options are kept, not replaced. A GIT_SSH program takes no options, so it is left as it is: with
  # no controlling terminal it still has nowhere to prompt.
  defp batch_ssh(repo_path) do
    configured =
      case git(repo_path, ["config", "--get", "core.sshCommand"]) do
        {:ok, command} -> command
        {:error, _} -> ""
      end

    command =
      Enum.find([System.get_env("GIT_SSH_COMMAND", ""), configured], &(&1 != "")) ||
        if System.get_env("GIT_SSH", "") == "", do: "ssh"

    if command, do: [{"GIT_SSH_COMMAND", command <> " -o BatchMode=yes"}], else: []
  end

  # The operator's ssh agent and forge token, as the runner has them. `ProcessGroup.run/4` scrubs
  # the list a SESSION must not inherit, and that list names all four; this is the runner's own
  # fetch, which authenticates as the operator does. With BatchMode on, a passphrase-protected key
  # reachable only through the agent would otherwise fail every ssh fetch, and `gh`'s credential
  # helper reads GH_TOKEN or GITHUB_TOKEN for an https one. A name supplied here wins over the
  # scrub; an unset one stays unset.
  defp operator_auth_env,
    do:
      Enum.map(
        ~w(SSH_AUTH_SOCK SSH_AGENT_PID GH_TOKEN GITHUB_TOKEN),
        &{&1, System.get_env(&1)}
      )

  # The worktree removed, then the branch deleted, whatever commits it has: the caller has proven
  # none holds anything origin's base lacks.
  defp retire(repo_path, path, branch) do
    case remove_worktree(repo_path, path) do
      {:kept, _} = kept ->
        %{worktree: kept, branch: kept}

      worktree ->
        git(repo_path, ["worktree", "prune"])

        branch =
          if branch_exists?(repo_path, branch),
            do: delete_branch(repo_path, branch),
            else: :absent

        %{worktree: worktree, branch: branch}
    end
  end

  @doc """
  What the worktree at `path` and `branch` hold beyond `base` (or `origin`'s copy of it). Read once
  per decision and passed on: uncommitted changes first, then commits on a HEAD that left the
  branch, then commits on the branch.

  `:none` means deleting the branch loses nothing, whatever origin now says, so it is retired with
  no fetch. `:commits` means only origin can say whether they shipped, `:unknown` that nothing
  could be read, and `:dirty` that the tree has uncommitted changes.
  """
  @spec work_in(String.t(), String.t(), String.t(), String.t()) :: work()
  def work_in(repo_path, path, branch, base) do
    cond do
      not File.dir?(path) -> commits_ahead(repo_path, branch, base)
      dirty?(path) -> :dirty
      true -> head_or_branch(repo_path, path, branch, base)
    end
  end

  @doc """
  What `work_in/4` reads its answer from: the branch's tip, the tree's HEAD and whether it is
  dirty, and the local base's commit. An equal fingerprint read later means the answer still
  stands. Origin's remote-tracking ref is left out on purpose: the fetch that a removal is decided
  by moves it, which is not the tree changing.
  """
  @spec fingerprint(String.t(), String.t(), String.t(), String.t()) :: fingerprint()
  def fingerprint(repo_path, path, branch, base) do
    tree? = File.dir?(path)

    {commit(repo_path, "refs/heads/" <> branch), tree? and commit(path, "HEAD"),
     tree? and dirty?(path), local_ref?(repo_path, base) and commit(repo_path, base)}
  end

  # Commits can sit where HEAD points without being on the recorded branch: a detached
  # checkout, or a rebase the wall clock stopped. Both must be empty to count as clean.
  defp head_or_branch(repo_path, path, branch, base) do
    case beyond(repo_path, path, "HEAD", base) do
      :none -> commits_ahead(repo_path, branch, base)
      work -> work
    end
  end

  # `:none` only where deleting the branch provably loses nothing: the tip IS the commit the base or
  # origin's copy of it points at — a branch with no commit of its own, which is what an untouched
  # tree cut from either is — or a LOCAL ref of the base reaches it. A tip that only origin's
  # remote-tracking ref reaches is `:commits`: that ref is what the LAST fetch saw, origin may have
  # dropped those commits since, and only a fetch made for this decision may say they are there. A
  # tip, or a base, that resolves for neither is `:unknown`.
  defp beyond(repo_path, dir, tip, base) do
    refs = for ref <- [base, origin_ref(base)], {:ok, sha} <- [commit(repo_path, ref)], do: sha

    case {refs, commit(dir, tip)} do
      {[], _} ->
        :unknown

      {_, {:error, _}} ->
        :unknown

      {refs, {:ok, sha}} ->
        if sha in refs or (local_ref?(repo_path, base) and ancestor?(repo_path, sha, base)),
          do: :none,
          else: :commits
    end
  end

  # Whether `base` names a ref of this repository's own — a branch or a tag — rather than a
  # remote-tracking ref a fetch moves, or a bare commit, which keeps nothing reachable.
  defp local_ref?(repo_path, base) do
    case git(repo_path, ["rev-parse", "--symbolic-full-name", base]) do
      {:ok, "refs/remotes/" <> _} -> false
      {:ok, "refs/" <> _} -> true
      _ -> false
    end
  end

  # An unreadable status counts as dirty: the reaper must never guess work away. Untracked files
  # count whatever `status.showUntrackedFiles` says; `normal` names an untracked directory once
  # rather than every file in it, which is all this needs to know.
  defp dirty?(path) do
    case git(path, ["status", "--porcelain", "--untracked-files=normal"]) do
      {:ok, ""} -> false
      _ -> true
    end
  end

  defp commits_ahead(repo_path, branch, base) do
    if branch_exists?(repo_path, branch),
      do: beyond(repo_path, repo_path, "refs/heads/" <> branch, base),
      else: :none
  end

  @doc "The registry status a removal outcome leaves the worktree in."
  @spec status_after(removal()) :: String.t()
  def status_after(%{worktree: worktree}) when worktree in [:removed, :absent], do: "removed"
  def status_after(%{worktree: {:kept, _}}), do: "kept"
  def status_after(_), do: "remove_failed"

  # `--force` removes everything under the tree, and a session following the delivery loop cuts
  # worktrees of its own INSIDE it (`.claude/worktrees/<name>`, ignored, so the tree reads clean),
  # or clones a repository there. Work only they hold would go with it (`holds_work?/3`): such a
  # tree is kept, and so is its branch, which a nested repository does not hold but which is this
  # tree's.
  defp remove_worktree(repo_path, path) do
    cond do
      not File.dir?(path) ->
        :absent

      nested = nested_repositories(path) ->
        {:kept, "holds repositories of its own: " <> Enum.join(nested, ", ")}

      true ->
        case git(repo_path, ["worktree", "remove", "--force", path]) do
          {:ok, _} -> :removed
          {:error, out} -> {:error, out}
        end
    end
  end

  # Nil when nothing under `path` is a repository holding work, else those directories, relative to
  # it. Found on the filesystem, not in `git worktree list`: that list names a worktree whose
  # directory is gone, and never names a clone. What a scan could not read counts, unless it is only
  # a directory find may not enter: the reaper never guesses work away.
  defp nested_repositories(path) do
    case scan(path) do
      {:ok, gits} ->
        recorded = submodules(path)
        common = common_dir(path)

        gits
        |> Enum.map(&Path.relative_to(Path.dirname(&1), path))
        |> Enum.filter(&holds_work?(Path.join(path, &1), Map.get(recorded, &1), common))
        |> case do
          [] -> nil
          nested -> nested
        end

      {:error, reason} ->
        ["(unreadable: #{reason})"]
    end
  end

  # Every `.git` under `path` but the tree's own, bounded as every other read here is, not entering
  # `@unscanned`. A directory find may not enter is skipped: git cannot remove it either, so it fails
  # the removal instead of keeping the tree. Any other error — the tree vanishing, the bound — is
  # the scan's answer, and keeps the tree.
  # ANY error keeps the tree, an unreadable directory included: `worktree remove --force` on a
  # tree it cannot fully read fails part-way, after deleting what it could. Kept costs disk;
  # a partial removal costs work.
  defp scan(path) do
    names = @unscanned |> Enum.flat_map(&["-o", "-name", &1]) |> tl()

    args =
      [path, "(", "-type", "d", "(" | names] ++
        [")", ")", "-prune", "-o", "-name", ".git", "-prune", "-print0"]

    script = """
    exec 3>&1
    err=$(find "$@" 2>&1 1>&3 3>&-)
    [ -z "$err" ] || { printf '%s' "$err"; exit 2; }
    """

    case bounded(script, args, @scan_timeout_ms, [{"LC_ALL", "C"}]) do
      {:ok, out, 0} ->
        {:ok, out |> String.split(<<0>>, trim: true) |> Enum.reject(&(Path.dirname(&1) == path))}

      {:ok, out, _} ->
        {:error, out |> String.split(<<0>>) |> List.last() |> String.trim()}

      {:error, :timeout} ->
        {:error, "no answer within #{@scan_timeout_ms} ms"}
    end
  end

  # What removing the tree would lose of a repository nested in it: uncommitted changes, or commits
  # nothing that survives the removal reaches. A clone — a registered submodule's included — is an
  # object store of its own, so its HEAD and local branches are asked against the commit the tree
  # records for it, if any, and its own remote-tracking refs. A worktree of the story's OWN
  # repository shares that repository's refs, which outlive the tree, so its branches are never
  # lost and only a HEAD that no branch or remote-tracking ref reaches — commits on a detached
  # checkout — goes with it.
  defp holds_work?(dir, recorded, common) do
    unreached =
      if recorded == nil and common != nil and common_dir(dir) == common,
        do: ["HEAD", "--not", "--branches", "--remotes"],
        else: ["HEAD", "--branches", "--not" | List.wrap(recorded)] ++ ["--remotes"]

    dirty?(dir) or git(dir, ["rev-list", "--count" | unreached]) != {:ok, "0"}
  end

  # The submodules checked out under `path`, nested ones included, by path relative to it, each
  # with the commit `path`'s tree records for it. None when git cannot say: every nested repository
  # is then asked whether it holds work as any other is.
  defp submodules(path) do
    script = ~s(printf '%s %s\\n' "$sha1" "$displaypath")

    case git(path, ["submodule", "foreach", "--quiet", "--recursive", script]) do
      {:ok, out} ->
        for line <- String.split(out, "\n", trim: true),
            [sha, sub] <- [String.split(line, " ", parts: 2)],
            into: %{},
            do: {sub, sha}

      {:error, _} ->
        %{}
    end
  end

  # -D, not -d: `-d` asks whether the branch is merged into HEAD by HISTORY, which is the question
  # every caller has already answered better — no commits beyond the base, or none origin's base
  # lacks.
  defp delete_branch(repo_path, branch) do
    case git(repo_path, ["branch", "-D", branch]) do
      {:ok, _} -> :deleted
      {:error, out} -> {:error, out}
    end
  end

  defp clear_repo_env, do: Enum.map(@repo_locating_env, &{&1, nil})

  # `sh -c script` under a hard timeout, finding its repository by cwd, with git's terminal prompt
  # off. `ProcessGroup.run/4` unsets GIT_ASKPASS and SSH_ASKPASS with the other credential names.
  defp bounded(script, args, timeout_ms, env \\ []) do
    env = clear_repo_env() ++ [{"GIT_TERMINAL_PROMPT", "0"} | env]
    ProcessGroup.run("/bin/sh", ["-c", script, "sh" | args], timeout_ms, env)
  end

  # Git's stdout alone, untrimmed, under the same bound as the squash search.
  defp bounded_git(dir, args) do
    script = ~s(dir=$1; shift; exec git -C "$dir" "$@" </dev/null 2>/dev/null)
    bounded(script, [dir | args], @log_timeout_ms)
  end

  defp git(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true, env: clear_repo_env()) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, String.trim(out)}
    end
  end
end
