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
  holding a repository whose work its removal would lose.

  The network is reached in two places, both bounded and neither fatal. The fetch of `origin`'s base
  is one; when it fails, commits only it could vouch for are kept and the failure is named. The
  other is a triage tree's submodules: they are cloned from the checkout's own clones of them, but a
  submodule the checkout has never cloned is fetched from its URL (`sync_submodules/2`).
  """

  require Logger

  alias LoopctlRunner.FetchLock
  alias LoopctlRunner.ProcessGroup

  @worktrees_subdir ".claude/worktrees"
  # A dot-directory, so no `<runs_dir>/*` glob over run directories (the reaper's, `RunState.all/1`)
  # ever walks into a tree. It is still a sibling of the run directories and their verdict tokens:
  # Claude Code's file tools are bounded by the session's path RULES (`Read(./**)`, which a `../`
  # path leaves), not by where a directory sits, and a stronger boundary than that is an OS one this
  # runner does not have (CLAUDE.md, "The Bash allow-list is not a sandbox").
  @triage_trees_subdir ".triage-trees"
  # Written into a triage tree's private git directory when the runner cuts it; `refresh_detached/2`
  # resets nothing that does not carry it.
  @marker "loopctl-runner-triage"
  @fetch_timeout_ms 30_000
  # A fetch error is shipped in a trace event, whose data loopctl caps.
  @fetch_error_chars 300
  # How long a fetch waits for a ref another git holds locked (the operator's own fetch or gc in
  # the same repository finishing): git waits itself, 100 ms by default, per ref backend
  # (`core.filesRefLockTimeout`, `reftable.lockTimeout`), per locked ref. Kept short: the fetch's
  # bound kills git with SIGKILL, and a kill landing while git holds one ref's lock and waits on
  # another's leaves the first behind.
  @ref_lock_wait_ms 1_000
  # What else a fetch needs, beyond git's own lock wait, before it is worth starting.
  @min_git_ms 2_000
  # The `LoopctlRunner.FetchLock` server that serialises this BEAM's fetches of one repository.
  @fetch_locks LoopctlRunner.FetchLocks
  # The short git reads around a fetch (its common directory, its refs' values).
  @git_probe_ms 5_000
  # A fetch that outlives its bound is sent TERM and given this long to remove its lock files
  # before KILL, which would leave them behind.
  @fetch_term_grace_ms 1_000
  # The squash search reads origin's history since the fork point, which on a busy base is large.
  @log_timeout_ms 30_000
  # Past this many paths the squash search is not run: the arguments would approach ARG_MAX.
  @max_squash_paths 1_000
  # The nested-repository scan walks the whole tree before a removal.
  @scan_timeout_ms 30_000
  # Directories that scan does not descend: build output and fetched dependencies, which the next
  # build or `deps.get` recreates, and which (node_modules) are large enough to take it past its bound.
  @unscanned ~w(deps _build node_modules .elixir_ls .lexical)
  # The operator's ssh agent and forge token, as the runner has them. `ProcessGroup.run/5` scrubs
  # credentials from the runner's own commands, and its list (`ProcessGroup.scrubbed_env/0`) names
  # all four; `fetch_base/3` is the
  # runner's own fetch, which authenticates as the operator does, so it INHERITS them — the
  # runner's own values, never ones a caller chose, and an unset one stays unset. With BatchMode on,
  # a passphrase-protected key reachable only through the agent would otherwise fail every ssh
  # fetch, and `gh`'s credential helper reads GH_TOKEN or GITHUB_TOKEN for an https one.
  @operator_auth_env ~w(SSH_AUTH_SOCK SSH_AGENT_PID GH_TOKEN GITHUB_TOKEN)

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

  @doc "How long `fetch_base/3` lets a fetch run before killing it."
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
          fetch: fetch(),
          cut_from: String.t()
        }
  @type removal :: %{
          worktree: :removed | :absent | {:kept, String.t()} | {:error, String.t()},
          branch: :deleted | :absent | {:kept, String.t()} | {:error, String.t()}
        }

  @spec path_for(String.t(), String.t()) :: String.t()
  def path_for(repo_path, story_id),
    do: Path.join([repo_path, @worktrees_subdir, "loop-" <> story_id])

  @doc """
  Where a repo's REUSED triage tree goes: one per repository, refreshed for each run that holds its
  `WorktreeLock`, so the session's cwd — and so its Claude project directory — is stable.

  Under the runner's own `runs_dir`, never in the operator's checkout: it is still a worktree of his
  repository, since `git worktree add` takes any path, but his checkout gains nothing and no
  worktree of his can share its name. Keyed by a digest of the checkout's path, so two repos never
  share one.
  """
  @spec triage_tree_path(String.t(), String.t()) :: String.t()
  def triage_tree_path(runs_dir, repo_path),
    do: Path.join([runs_dir, @triage_trees_subdir, repo_key(repo_path)])

  @doc """
  Where a triage run's OWN detached worktree goes, cut when another live run holds the reused one:
  one per run, removed at its teardown, never adopted.
  """
  @spec triage_tree_path(String.t(), String.t(), String.t()) :: String.t()
  def triage_tree_path(runs_dir, repo_path, run_id),
    do: Path.join([runs_dir, @triage_trees_subdir, repo_key(repo_path) <> "-" <> run_id])

  defp repo_key(repo_path) do
    :crypto.hash(:sha256, Path.expand(repo_path))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc """
  Cuts a DETACHED worktree at the commit `repo_path` has checked out, and returns that commit.
  No branch, so nothing a session commits there lands anywhere; `remove/4` with an empty branch
  removes it. Submodules are not touched here: `sync_submodules/3` does that, once the caller has
  recorded that the tree exists.

  `{:unreadable, _}` when the checkout cannot be judged — git will not read it as a repository, or
  it has no commit checked out — with git's own words; `{:error, _}` when it has one and the tree
  could not be cut, which is a local failure and says nothing about the checkout.
  """
  @spec create_detached(String.t(), String.t()) ::
          {:ok, String.t()} | {:unreadable, String.t()} | {:error, String.t()}
  def create_detached(repo_path, path) do
    with {:ok, sha} <- head_commit(repo_path), do: add_detached(repo_path, path, sha)
  end

  @doc """
  Cuts a DETACHED worktree at `commit` — which `locate_checkpoint/4` has already found in
  `repo_path` — for a review run, and returns that commit. The same tree `create_detached/2` cuts,
  marked the same way and removed the same way (`remove/4` with an empty branch), at a commit
  loopctl named rather than the one the checkout has out.
  """
  @spec create_detached_at(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()} | {:error, String.t(), :tree_left}
  def create_detached_at(repo_path, path, commit), do: add_detached(repo_path, path, commit)

  @doc """
  Finds `commit` in `repo_path` and fetches `base` from `origin`, as a review needs both: it reads
  a checkpoint another machine pushed to the story's branch, which this checkout has usually
  never fetched, and names the base its change is measured against (`locate_base/3`).

  When the checkout lacks the commit, the story's `branch` and the `base` come in ONE fetch. Git
  fetches nothing at all when one ref of a fetch is missing on origin (measured, git 2.50: "fatal:
  couldn't find remote ref"), so when that fetch fails — the branch merged and deleted, most
  often — the base is fetched alone. Only when the commit is STILL missing is it fetched by its
  id. Every fetch is `fetch_base/3`'s: bounded and never prompting, writing only origin's
  remote-tracking refs for those branches, and the fetch by id no ref at all.

  `{:ok, sha, base_fetched}`, where `base_fetched` is how the base's fetch went, for
  `locate_base/3`; `{:unreadable, _}` when git will not read the checkout at all; `{:error, _}`
  when no fetch brought the commit, naming each fetch's own failure.
  """
  @spec locate_checkpoint(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t(), :ok | {:error, String.t()}}
          | {:unreadable, String.t()}
          | {:error, String.t()}
  def locate_checkpoint(repo_path, commit, branch, base) do
    with :ok <- readable(repo_path) do
      case commit(repo_path, commit) do
        {:ok, sha} -> {:ok, sha, fetch_base(repo_path, base)}
        {:error, _} -> fetch_checkpoint(repo_path, commit, branch, base)
      end
    end
  end

  defp fetch_checkpoint(repo_path, commit, branch, base) do
    together = fetch(repo_path, [branch_refspec(branch), branch_refspec(base)])
    base_fetched = if together == :ok, do: :ok, else: fetch_base(repo_path, base)

    case commit(repo_path, commit) do
      {:ok, sha} -> {:ok, sha, base_fetched}
      {:error, _} -> fetch_by_id(repo_path, commit, branch, together, base_fetched)
    end
  end

  defp fetch_by_id(repo_path, commit, branch, by_branch, base_fetched) do
    by_id = fetch(repo_path, [commit])

    case commit(repo_path, commit) do
      {:ok, sha} ->
        {:ok, sha, base_fetched}

      {:error, _} ->
        {:error,
         "commit #{commit} is not in #{repo_path}: origin's #{branch} " <>
           fetched(by_branch, "does not carry it") <>
           ", and origin " <> fetched(by_id, "would not give it by its id")}
    end
  end

  defp fetched(:ok, said), do: said
  defp fetched({:error, why}, _said), do: "could not be fetched (#{why})"

  @doc """
  The ref that names `base` in `repo_path`, given how its fetch from origin went (`fetch_base/3`,
  or `locate_checkpoint/4`'s): `origin/<base>` once fetched, the local `base` when that fetch
  failed and the checkout has one, and `:none` when neither resolves. A review names it to the
  session as the ref its change is measured against, so it must be one that resolves in the
  scratch tree, which shares these refs.
  """
  @spec locate_base(String.t(), String.t(), :ok | {:error, String.t()}) ::
          {:ok, String.t()} | :none
  def locate_base(repo_path, base, fetched) do
    candidates = if fetched == :ok, do: ["origin/" <> name(base), base], else: [base]

    case Enum.find(candidates, &match?({:ok, _}, commit(repo_path, &1))) do
      nil -> :none
      ref -> {:ok, ref}
    end
  end

  @doc "The tree `commit` records in `repo_path`, or `{:error, git's words}`."
  @spec commit_tree(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def commit_tree(repo_path, commit),
    do: git(repo_path, ["rev-parse", "--verify", "--quiet", commit <> "^{tree}"])

  defp readable(repo_path) do
    case git(repo_path, ["rev-parse", "--git-dir"]) do
      {:ok, _} -> :ok
      {:error, out} -> {:unreadable, "git will not read #{repo_path} as a repository: #{out}"}
    end
  end

  # Ends with the tree MARKED, or with no tree, or — when the tree that could not be marked could
  # not be removed either — `{:error, _, :tree_left}`, so the caller records a tree that exists
  # rather than one that was never cut.
  #
  # `--force` once, for one thing: a registration of THIS path whose directory is gone (a tree set
  # aside, or deleted by hand), which `add` otherwise refuses. It drops that one entry. Never a
  # repository-wide `worktree prune`, which drops the entry of every worktree of the operator's
  # whose directory is missing at that moment — one on an unmounted volume included.
  defp add_detached(repo_path, path, sha) do
    case tree_git(repo_path, ["worktree", "add", "--force", "--detach", path, sha]) do
      {:ok, _} -> mark(repo_path, path, sha)
      {:error, out} -> {:error, "cannot cut a detached worktree from #{repo_path}: #{out}"}
    end
  end

  # The marker lives in the tree's PRIVATE git directory (`<common>/worktrees/<name>`), which only
  # `git worktree add` makes and which `worktree remove` and `prune` delete with the tree, so it
  # cannot outlive the tree it vouches for.
  defp mark(repo_path, path, sha) do
    with {:ok, gitdir} <- git(path, ["rev-parse", "--absolute-git-dir"]),
         :ok <- File.write(Path.join(gitdir, @marker), "loopctl-runner triage tree\n") do
      {:ok, sha}
    else
      failure ->
        why = "cannot mark #{path} as the runner's triage tree: #{inspect(failure)}"

        case git(repo_path, ["worktree", "remove", "--force", "--force", path]) do
          {:ok, _} -> {:error, why}
          {:error, out} -> {:error, "#{why}; and it could not be removed: #{out}", :tree_left}
        end
    end
  end

  @doc """
  Brings the reused triage tree at `path` to the commit `repo_path` has out, as a clean checkout:
  tracked changes discarded, untracked AND ignored files removed. Cut fresh when nothing is there.

  Every destructive command runs only after `own_worktree?/2` has seen that `path` is the runner's
  own triage tree of `repo_path`: a linked worktree in its own right, detached, carrying the
  runner's marker. Without the first, a directory whose `.git` file is gone would have git walk UP
  to whatever repository encloses it, and `checkout --force` plus `clean -ffdx` would wipe it.

  Anything else at `path` is never reset, never removed — a worktree of this repository without
  the marker may hold someone's uncommitted edits — and never a permanent refusal either, since
  every later run on this repo would find it too: it is moved aside under `.triage-trees/set-aside`,
  logged, and the tree is cut again. The runner's own tree, when it will not reset, is removed (it
  is scratch), and moved aside only when git will not remove it.
  """
  @spec refresh_detached(String.t(), String.t()) ::
          {:ok, String.t()}
          | {:unreadable, String.t()}
          | {:error, String.t()}
          | {:error, String.t(), :tree_left}
  def refresh_detached(repo_path, path) do
    with {:ok, sha} <- head_commit(repo_path) do
      cond do
        not present?(path) ->
          add_detached(repo_path, path, sha)

        own_worktree?(repo_path, path) ->
          reset_or_recut(repo_path, path, sha)

        true ->
          recut_detached(
            repo_path,
            path,
            sha,
            :foreign,
            "is not recognisably the runner's triage tree"
          )
      end
    end
  end

  defp reset_or_recut(repo_path, path, sha) do
    case reset_detached(path, sha) do
      :ok ->
        {:ok, sha}

      {:error, out} ->
        recut_detached(repo_path, path, sha, :own, "would not reset to #{sha}: #{out}")
    end
  end

  # lstat, not exists?: a dangling symlink is something in the way too.
  defp present?(path), do: match?({:ok, _}, File.lstat(path))

  defp reset_detached(path, sha) do
    with {:ok, _} <- tree_git(path, ["checkout", "--quiet", "--force", "--detach", sha]),
         {:ok, _} <- tree_git(path, ["clean", "-ffdxq"]) do
      :ok
    end
  end

  # Four conditions, all needed: `.git` a FILE in `path` itself, so git's discovery stops there
  # rather than walking up; that file's repository the same one `repo_path` belongs to; HEAD
  # detached, as only the runner leaves it; and the runner's marker in its private git directory.
  defp own_worktree?(repo_path, path) do
    File.regular?(Path.join(path, ".git")) and
      same_repository?(path, repo_path) and
      git(path, ["rev-parse", "--abbrev-ref", "HEAD"]) == {:ok, "HEAD"} and
      marked?(path)
  end

  defp same_repository?(path, repo_path) do
    case common_dir(path) do
      nil -> false
      common -> common == common_dir(repo_path)
    end
  end

  defp marked?(path) do
    case git(path, ["rev-parse", "--absolute-git-dir"]) do
      {:ok, gitdir} -> File.regular?(Path.join(gitdir, @marker))
      {:error, _} -> false
    end
  end

  defp recut_detached(repo_path, path, sha, owner, why) do
    with :ok <- clear(repo_path, path, owner, why), do: add_detached(repo_path, path, sha)
  end

  # The runner's own tree is scratch, so it is removed: `--force` twice, once for a tree with
  # changes or submodules, once for a locked one.
  defp clear(repo_path, path, :own, why) do
    case git(repo_path, ["worktree", "remove", "--force", "--force", path]) do
      {:ok, _} ->
        Logger.warning("the triage tree #{path} #{why}; removed it and cut it again")
        :ok

      {:error, out} ->
        set_aside(path, why, "git would not remove it (#{out})")
    end
  end

  # Anything else is not the runner's to discard, whatever repository it belongs to.
  defp clear(_repo_path, path, :foreign, why),
    do: set_aside(path, why, "it is not the runner's to remove")

  defp set_aside(path, why, because) do
    aside =
      Path.join([
        Path.dirname(path),
        "set-aside",
        "#{Path.basename(path)}-#{System.os_time(:second)}-#{System.unique_integer([:positive])}"
      ])

    with :ok <- File.mkdir_p(Path.dirname(aside)),
         :ok <- File.rename(path, aside) do
      relink(aside)

      Logger.warning(
        "the triage tree #{path} #{why}, and #{because}; moved it to #{aside} and cut it again"
      )

      :ok
    else
      {:error, reason} ->
        {:error, "#{path} #{why}, and it could not be moved aside: #{:file.format_error(reason)}"}
    end
  end

  # A worktree moved aside is re-registered at its new place by its own repository, whichever that
  # is, so its edits stay usable there and its old registration stops naming `path`. Only where its
  # `.git` is a file: git run in a directory without one walks UP to whatever repository encloses
  # it, and `worktree repair` there would act on that one.
  defp relink(aside) do
    if File.regular?(Path.join(aside, ".git")), do: git(aside, ["worktree", "repair"])
  end

  # Two different failures, told apart because they send whoever reads them to different places: a
  # directory git will not read AS a repository (not one, or refused — dubious ownership), and a
  # repository with nothing checked out. Both carry git's own words.
  defp head_commit(repo_path) do
    with :ok <- readable(repo_path) do
      case git(repo_path, ["rev-parse", "--verify", "HEAD^{commit}"]) do
        {:ok, sha} -> {:ok, sha}
        {:error, out} -> {:unreadable, "#{repo_path} has no commit checked out: #{out}"}
      end
    end
  end

  # One budget for the whole submodule step, not one per command, and every command bounded by
  # what is left of it (`ProcessGroup.run_group/4` kills the command's whole process group on
  # expiry), with prompts off: a submodule URL may need credentials no one is there to type, and a
  # hung clone must not become a hung dispatch.
  @submodule_timeout_ms 120_000

  # Run by `git submodule foreach` inside every submodule, recursively: the superproject's own
  # `clean -ffdx` stops at a submodule's boundary.
  @submodule_clean "git reset --quiet --hard && git clean -ffdxq"

  @doc false
  def submodule_timeout_ms, do: @submodule_timeout_ms

  @doc """
  Brings the submodules of the tree at `path` to the commits it records, as clean checkouts:
  initialised, checked out with `--force`, then reset and cleaned inside each one, recursively —
  the superproject's `clean -ffdx` never enters a submodule.

  Each submodule the operator's checkout of `repo_path` has already cloned is cloned from THAT
  clone rather than from its URL: this runner's git runs with the operator's credentials scrubbed
  (`ProcessGroup.run/5`), so a private submodule's remote is out of its reach, and the checkout's
  clone is also the one place that holds the commit it records without a fetch. A local clone is
  copied, not borrowed, so a tree that outlives an operator's `gc` loses nothing. Only a submodule
  the checkout has never cloned is fetched from its URL, and a nested submodule is always.

  A tree with no `.gitmodules` pays for nothing. A failure is LOGGED and the tree still used — a
  session judges the superproject without them, which is less than it could have, not a reason to
  judge nothing — and returned as `{:missing, paths, detail}`, every submodule path the tree
  declares, so the session can be told which directories may be empty or at the wrong commit.
  """
  @spec sync_submodules(String.t(), String.t()) :: :ok | {:missing, [String.t()], String.t()}
  def sync_submodules(repo_path, path) do
    if File.exists?(Path.join(path, ".gitmodules")) do
      deadline = System.monotonic_time(:millisecond) + @submodule_timeout_ms
      declared = declared_submodules(path)

      update =
        local_clones(repo_path, declared) ++ ~w(submodule update --init --recursive --force)

      with :ok <- submodule_git(path, update, deadline),
           :ok <-
             submodule_git(
               path,
               ["submodule", "foreach", "--quiet", "--recursive", @submodule_clean],
               deadline
             ) do
        :ok
      else
        {:error, detail} ->
          Logger.error("submodules of #{path} were not initialised: #{detail}")
          {:missing, Enum.map(declared, &elem(&1, 1)), detail}
      end
    else
      :ok
    end
  end

  # `-c` settings pointing each submodule the checkout has cloned at that clone, found where git
  # keeps them for THAT checkout (`--git-path modules`: `<common>/modules` for a main checkout,
  # `<common>/worktrees/<id>/modules` for a linked one). Given on the command line, so the operator's
  # config is never written, and inherited by the helper processes git starts.
  #
  # `protocol.file.allow=always` because git refuses a submodule clone over a local path by default
  # (CVE-2022-39253, a hostile repository naming a victim's local files as its submodule). These
  # URLs are the operator's own clones, on his own disk.
  defp local_clones(repo_path, declared) do
    with {:ok, modules} <-
           git(repo_path, ["rev-parse", "--path-format=absolute", "--git-path", "modules"]),
         [_ | _] = urls <-
           for(
             {name, _} <- declared,
             # `-c` splits at the first `=`, so a name holding one cannot be addressed this way.
             not String.contains?(name, "="),
             clone = Path.join(modules, name),
             File.dir?(clone),
             do: ["-c", "submodule.#{name}.url=#{clone}"]
           ) do
      ["-c", "protocol.file.allow=always" | Enum.concat(urls)]
    else
      _ -> []
    end
  end

  # `{name, path}` for every submodule `.gitmodules` declares, NUL-separated so a name or path
  # holding a space or a newline is read whole.
  defp declared_submodules(path) do
    file = Path.join(path, ".gitmodules")

    case git(path, ["config", "--file", file, "-z", "--get-regexp", ~S"^submodule\..*\.path$"]) do
      {:ok, out} ->
        for record <- String.split(out, <<0>>, trim: true),
            [key, sub_path] <- [String.split(record, "\n", parts: 2)],
            do: {submodule_name(key), sub_path}

      {:error, _} ->
        []
    end
  end

  defp submodule_name(key),
    do: key |> String.replace_prefix("submodule.", "") |> String.replace_suffix(".path", "")

  defp submodule_git(path, args, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, "the time allowed ran out"}
    else
      case hookless_git(path, args, remaining) do
        {:ok, _} -> :ok
        {:error, detail} -> {:error, detail}
      end
    end
  end

  # How long one command that checks a triage tree's files out, or deletes them, may take.
  @tree_git_timeout_ms 300_000

  # The commands that write a triage tree's files: `worktree add`, `checkout`, `clean`.
  defp tree_git(dir, args), do: hookless_git(dir, args, @tree_git_timeout_ms)

  # With the operator's hooks OFF: `worktree add` and `checkout` run his post-checkout hook, which is
  # his to run in his checkout, not the runner's to run unattended in a scratch tree. And bounded
  # (`ProcessGroup.run_group/4` kills the command's whole process group on expiry), with prompts
  # off: a filter or a remote waiting on a terminal no one is at must not become a hung dispatch.
  defp hookless_git(dir, args, timeout_ms) do
    env = [{"GIT_TERMINAL_PROMPT", "0"} | Enum.map(@repo_locating_env, &{&1, nil})]
    argv = ["-C", dir, "-c", "core.hooksPath=/dev/null" | args]
    command = subcommand(args)

    case ProcessGroup.run_group(git_executable(), argv, timeout_ms, env) do
      {:ok, out, 0} -> {:ok, String.trim(out)}
      {:ok, out, status} -> {:error, "git #{command} exited #{status}: #{String.trim(out)}"}
      {:error, :timeout} -> {:error, "git #{command} did not finish within the time allowed"}
    end
  end

  # The words naming the command, past any `-c name=value` pairs in front of it.
  defp subcommand(["-c", _ | rest]), do: subcommand(rest)

  defp subcommand([command, sub | _]) when command in ~w(submodule worktree),
    do: "#{command} #{sub}"

  defp subcommand([command | _]), do: command

  defp git_executable, do: System.find_executable("git") || "git"

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

  `cut_from` is the commit the tree holds from its base and no session wrote, read from the tree
  itself on every path: a new or reset tree's HEAD, read before any session runs in it, and for an
  adopted tree the merge base of its HEAD and the base — local and `origin`'s, whichever resolve,
  since the branch may have been cut from either. Its HEAD may carry an earlier session's commits;
  a merge base is a commit of the base's own history that the tree also holds.
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
      cut_from(path, %{path: path, branch: branch, base: base, reused: false, start: start})
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
      {:ok, ^branch} ->
        cut_from(path, %{path: path, branch: branch, base: base, reused: true, start: nil})

      {:ok, other} ->
        {:error, "#{path} exists on branch #{other}, not #{branch}"}

      {:error, out} ->
        {:error, "#{path} exists but is not a worktree: #{out}"}
    end
  end

  # `--no-track`: a branch cut from a remote-tracking ref would otherwise take origin's base as its
  # upstream, and a bare `git push` under `push.default = upstream` would push the session's work
  # to it.
  defp add(repo_path, path, branch, base, fetch) do
    start = start(repo_path, base, fetch)

    with {:ok, _} <- commit(repo_path, start),
         {:ok, _} <- git(repo_path, ["worktree", "add", "--no-track", "-b", branch, path, start]) do
      case cut_from(path, %{path: path, branch: branch, base: base, reused: false, start: start}) do
        {:ok, created} -> {:ok, created}
        {:error, why} -> {:error, undo_add(repo_path, path, branch, why)}
      end
    else
      {:error, out} -> {:error, "cannot create worktree from #{start}: #{out}"}
    end
  end

  # The caller owns nothing an error returns, so a tree and branch this call just added are removed
  # here, and the error says whether that worked: one left behind is named, never silently kept.
  # `retire/3`, not `remove/4`: a branch just cut from origin's base is ahead of a stale local
  # base, and `remove/4` keeps a branch with commits beyond the base it is given.
  defp undo_add(repo_path, path, branch, why) do
    case retire(repo_path, path, branch) do
      %{worktree: :removed, branch: :deleted} ->
        why <> "; the new worktree and branch were removed"

      removal ->
        why <>
          "; removing the new worktree #{path} and branch #{branch} failed: " <>
          inspect(removal)
    end
  end

  # A tree the runner just cut or reset starts at its HEAD. An adopted one started at the fork of
  # its HEAD from the base; which copy of the base it forked from is not recorded, so both that
  # resolve are given and git answers with the later fork (`merge-base A B C` is the merge base of
  # A and a merge of B and C).
  defp cut_from(path, %{reused: false} = created),
    do: cut_from(path, created, ["rev-parse", "--verify", "HEAD^{commit}"])

  defp cut_from(path, %{reused: true, base: base} = created) do
    case Enum.filter([base, origin_ref(base)], &resolves?(path, &1)) do
      [] -> {:error, "cannot tell which commit #{path} was cut from: #{base} does not resolve"}
      bases -> cut_from(path, created, ["merge-base", "HEAD" | Enum.uniq(bases)])
    end
  end

  defp cut_from(path, created, args) do
    case git_stdout(path, args) do
      {:ok, commit} -> {:ok, Map.put(created, :cut_from, String.trim(commit))}
      {:error, why} -> {:error, "cannot tell which commit #{path} was cut from: #{why}"}
    end
  end

  @doc """
  `file` as `commit` holds it — never a working tree's, which the session can write:
  `{:ok, content}`, `:absent` when the commit has no such path, or `{:error, reason}`.

  The read is bounded: the entry must be a regular file in the tree (a symlink, a directory or a
  submodule is an error, and nothing on disk is opened, so a FIFO cannot block it), and its size
  is checked before its bytes are read. Only git's stdout is read as the answer; its stderr is
  kept apart and only ever quoted in an error.
  """
  @spec commit_file(String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, binary()} | :absent | {:error, String.t()}
  def commit_file(repo_path, commit, file, max_bytes) do
    with {:ok, oid} <- tree_entry(repo_path, commit, file),
         :ok <- blob_size(repo_path, oid, file, max_bytes) do
      case git_stdout(repo_path, ["cat-file", "blob", oid]) do
        {:ok, content} -> {:ok, content}
        {:error, why} -> {:error, "cannot read #{file} at #{commit}: #{why}"}
      end
    end
  end

  defp tree_entry(repo_path, commit, file) do
    case git_stdout(repo_path, ["ls-tree", commit, "--", file]) do
      {:ok, ""} ->
        :absent

      {:ok, line} ->
        case line |> String.trim_trailing("\n") |> String.split(["\s", "\t"], parts: 4) do
          [mode, "blob", oid, ^file] when mode in ["100644", "100755"] -> {:ok, oid}
          _ -> {:error, "#{file} is not a regular file at #{commit}"}
        end

      {:error, why} ->
        {:error, "cannot list #{file} at #{commit}: #{why}"}
    end
  end

  defp blob_size(repo_path, oid, file, max_bytes) do
    with {:ok, size} <- git_stdout(repo_path, ["cat-file", "-s", oid]),
         {size, ""} when size <= max_bytes <- size |> String.trim() |> Integer.parse() do
      :ok
    else
      {:error, why} -> {:error, "cannot size #{file}: #{why}"}
      _ -> {:error, "#{file} is larger than #{max_bytes} bytes"}
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
  maintenance.

  Fetches of one repository made in this BEAM run one at a time (a unique `Registry` key on the
  repository's git common directory, which its holder's death releases), so the daemon's own
  fetches never race for its refs; a `mix` task is another BEAM and is not serialised with them.
  Waiting for another counts against the same bound, and git is started only with room left for
  its own lock wait. A ref another git holds locked (the operator's own fetch or gc, or a `mix`
  task) is waited for by git itself, up to `@ref_lock_wait_ms`, whatever its version or locale. A
  fetch git refused a ref update in (exit status 1: a lock held past that wait, or a ref another git
  moved meanwhile, "incorrect old value provided" on git 2.53.0) is made once more, reading the
  ref afresh, with the same room; a refusal that would repeat costs that second fetch too. A lock
  on a ref the fetch writes, older than a live fetch can hold one, explains the refusal instead:
  it is not retried, and the lock is named in the error with its age. `:timeout_ms` replaces
  `fetch_timeout_ms/0` as the bound, and `:fetch_locks` names the registry that serialises.

  This is the RUNNER's own fetch, never a session's, so it must never prompt: stdin is /dev/null,
  git's terminal prompt is off, no askpass program runs, a credential helper is told not to
  interact, and ssh runs in BatchMode.
  `ProcessGroup.run/5` supplies the rest — no controlling terminal, and the whole group killed on
  timeout.
  """
  @spec fetch_base(String.t(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def fetch_base(repo_path, base, opts \\ []),
    do: fetch(repo_path, [branch_refspec(base)], opts)

  @doc """
  `fetch_base/3` for several bases of one repository, in one fetch. Git fetches nothing when one of
  them is missing on origin, so a caller that must tell them apart fetches each after a failure.
  """
  @spec fetch_bases(String.t(), [String.t()], keyword()) :: :ok | {:error, String.t()}
  def fetch_bases(repo_path, bases, opts \\ []),
    do: fetch(repo_path, Enum.map(bases, &branch_refspec/1), opts)

  @doc "Whether a fetch's error is its bound running out, which fetching again would only repeat."
  @spec fetch_timed_out?(String.t()) :: boolean()
  def fetch_timed_out?(reason), do: String.starts_with?(reason, "timed out after ")

  defp branch_refspec(branch), do: "+refs/heads/#{name(branch)}:#{origin_ref(branch)}"

  # `refspecs` from origin, in one fetch. A bare commit id (`fetch_by_id/5`) has no destination,
  # so no ref is written: the commit lands in the object store, where a detached worktree can be
  # cut at it.
  defp fetch(repo_path, refspecs, opts \\ []) do
    case System.find_executable("git") do
      nil ->
        {:error, "git is not on PATH"}

      git ->
        timeout_ms = Keyword.get(opts, :timeout_ms, @fetch_timeout_ms)
        started = System.monotonic_time(:millisecond)
        deadline = started + timeout_ms
        # Read once: the lock key and the stale-lock check both need it.
        common = common_dir_bounded(repo_path)
        attempt = fn -> fetch_once(git, repo_path, refspecs, deadline) end
        locks = Keyword.get(opts, :fetch_locks, @fetch_locks)
        fetch = %{repo: repo_path, common: common, refspecs: refspecs, timeout_ms: timeout_ms}

        common
        |> with_fetch_lock(locks, deadline, fn -> fetch_with_room(attempt, deadline, fetch) end)
        |> fetch_outcome(timeout_ms, System.monotonic_time(:millisecond) - started)
        |> cap_error()
    end
  end

  defp fetch_with_room(attempt, deadline, fetch) do
    if room?(deadline) do
      before = ref_values(fetch.repo, fetch.refspecs)
      attempt.() |> retry_moved(attempt, deadline, fetch, before)
    else
      :no_room
    end
  end

  # Room for git's own lock wait and a fetch around it: a git killed while it holds one ref's lock
  # and waits on another's leaves the first behind.
  defp room?(deadline), do: room_left(deadline) > 0

  defp room_left(deadline),
    do: deadline - System.monotonic_time(:millisecond) - @ref_lock_wait_ms - @min_git_ms

  # git fetch exits 1 when it refused a ref update, 128 on anything fatal. Fetched once more only
  # when a ref this fetch writes CHANGED during the attempt: another git moved it while this one
  # waited ("incorrect old value provided", git 2.53.0), and a second fetch reads it afresh. A
  # refusal with the refs unchanged (a lock held past the wait, a ref that cannot sit beside
  # another) would only repeat. A stale lock on a ref this fetch writes explains a refusal, and is
  # reported.
  defp retry_moved({:ok, _out, 1} = result, attempt, deadline, fetch, before) do
    cond do
      (stale = stale_locks(fetch)) != [] -> {:stale, result, stale}
      room?(deadline) and ref_values(fetch.repo, fetch.refspecs) != before -> attempt.()
      true -> result
    end
  end

  defp retry_moved(result, _attempt, _deadline, _fetch, _before), do: result

  # One fetch of a repository at a time in this BEAM (`LoopctlRunner.FetchLock`, first come first
  # served), waited for only while a fetch could still start. A repository whose common directory
  # cannot be read, or a BEAM without the lock server (a script that never started the
  # application), is not serialised.
  defp with_fetch_lock(common, locks, deadline, fun) do
    key = lock_key(common)

    cond do
      key == nil or GenServer.whereis(locks) == nil ->
        fun.()

      FetchLock.acquire(locks, key, max(room_left(deadline), 0)) == :ok ->
        try do
          fun.()
        after
          FetchLock.release(locks, key)
        end

      true ->
        :no_room
    end
  end

  @doc false
  # The repository's identity: its git common directory, as git resolves it, the same for every
  # path that reaches it (a symlink, a linked worktree).
  @spec fetch_lock_key(String.t()) :: {:fetch, String.t()} | nil
  def fetch_lock_key(repo_path), do: repo_path |> common_dir_bounded() |> lock_key()

  defp lock_key(nil), do: nil
  defp lock_key(common), do: {:fetch, common}

  # `common_dir/1` under a bound: a repository on a stalled volume must not hang the fetch before
  # its own bound starts.
  defp common_dir_bounded(repo_path) do
    script = ~s(exec git -C "$1" rev-parse --path-format=absolute --git-common-dir </dev/null)

    case bounded(script, [repo_path], @git_probe_ms) do
      {:ok, out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  # The values of the refs `refspecs` write, one line each ("none" for one that does not exist),
  # or nil when they cannot be read: then no change can be seen, and nothing is retried.
  defp ref_values(repo_path, refspecs) do
    refs = for spec <- refspecs, [_src, dest] <- [String.split(spec, ":", parts: 2)], do: dest

    script =
      ~s(dir=$1; shift; for r; do git -C "$dir" rev-parse -q --verify "$r" </dev/null || echo none; done)

    case bounded(script, [repo_path | refs], @git_probe_ms) do
      {:ok, out, 0} -> out
      _ -> nil
    end
  end

  # Locks on the refs this fetch writes older than its whole bound, which no live fetch holds: a
  # git killed mid-update left them. Files backend only; reftable keeps no per-ref lock.
  defp stale_locks(%{common: nil}), do: []

  defp stale_locks(%{common: common, refspecs: refspecs, timeout_ms: timeout_ms}) do
    now = System.os_time(:second)

    for refspec <- refspecs,
        [_source, dest] <- [String.split(refspec, ":", parts: 2)],
        lock = Path.join(common, dest <> ".lock"),
        {:ok, %File.Stat{mtime: mtime}} <- [File.stat(lock, time: :posix)],
        (now - mtime) * 1000 > timeout_ms,
        do: {lock, now - mtime}
  end

  # The error is shipped in a trace event whose data loopctl caps: git's words and any stale-lock
  # notes together stay within twice `@fetch_error_chars`.
  defp cap_error({:error, reason}), do: {:error, String.slice(reason, 0, 2 * @fetch_error_chars)}
  defp cap_error(result), do: result

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
  defp fetch_once(git, repo_path, refspecs, deadline) do
    args =
      [git, "-C", repo_path, "-c", "core.askPass=", "-c", "credential.interactive=false"] ++
        ["-c", "core.filesRefLockTimeout=#{@ref_lock_wait_ms}"] ++
        ["-c", "reftable.lockTimeout=#{@ref_lock_wait_ms}"] ++
        ["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--no-auto-maintenance"] ++
        ["origin" | refspecs]

    remaining = max(deadline - System.monotonic_time(:millisecond), 1)

    env = [{"SSH_ASKPASS_REQUIRE", "never"}, {"GCM_INTERACTIVE", "never"} | batch_ssh(repo_path)]

    bounded(~s(exec "$@" </dev/null), args, remaining, env,
      inherit: @operator_auth_env,
      term_grace_ms: @fetch_term_grace_ms
    )
  end

  defp fetch_outcome(:no_room, timeout_ms, elapsed),
    do:
      {:error,
       "not fetched: #{elapsed} ms into its #{timeout_ms} ms bound, fewer than " <>
         "#{@ref_lock_wait_ms + @min_git_ms} ms were left to start git in"}

  defp fetch_outcome({:stale, result, stale}, timeout_ms, elapsed) do
    {:error, said} = fetch_outcome(result, timeout_ms, elapsed)

    notes =
      stale
      |> Enum.map_join("; ", fn {lock, age} ->
        "#{lock} is #{age} s old, left by a git that no longer runs: remove it"
      end)

    # One note per ref the fetch writes: two at most, so the error stays near its cap.
    {:error, said <> "; " <> notes}
  end

  defp fetch_outcome({:ok, _out, 0}, _timeout_ms, _waited), do: :ok

  defp fetch_outcome({:error, :timeout}, timeout_ms, _waited),
    do: {:error, "timed out after #{timeout_ms} ms"}

  defp fetch_outcome({:ok, out, status}, _timeout_ms, _waited) do
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

  # The worktree removed, then the branch deleted, whatever commits it has: the caller has proven
  # none holds anything origin's base lacks.
  defp retire(repo_path, path, branch) do
    case remove_worktree(repo_path, path) do
      {:kept, _} = kept ->
        %{worktree: kept, branch: kept}

      worktree ->
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

  @doc """
  Removes a triage tree and, when it holds no commits of its own, its branch — a detached triage
  tree has none, and passes `""`.

  A triage tree is the runner's scratch, so it is removed as it is, with no scan for repositories
  nested in it: its submodules are clones of the operator's own, and nothing a triage session
  leaves in it is work. A story's worktree is removed by `remove_if_clean/4` instead.

  Returns what happened to each, for the trace.
  """
  @spec remove(String.t(), String.t(), String.t(), String.t()) :: removal()
  def remove(repo_path, path, branch, base) do
    worktree =
      if File.dir?(path), do: force_remove(repo_path, path), else: drop_entry(repo_path, path)

    %{worktree: worktree, branch: remove_branch(repo_path, branch, base)}
  end

  defp remove_branch(repo_path, branch, base) do
    cond do
      not branch_exists?(repo_path, branch) -> :absent
      commits_ahead(repo_path, branch, base) == :none -> delete_branch(repo_path, branch)
      true -> {:kept, "commits beyond #{base}"}
    end
  end

  # `--force` removes everything under the tree, and a session following the delivery loop cuts
  # worktrees of its own INSIDE it (`.claude/worktrees/<name>`, ignored, so the tree reads clean),
  # or clones a repository there. Work only they hold would go with it (`holds_work?/3`): such a
  # tree is kept, and so is its branch, which a nested repository does not hold but which is this
  # tree's.
  defp remove_worktree(repo_path, path) do
    cond do
      not File.dir?(path) ->
        drop_entry(repo_path, path)

      nested = nested_repositories(path) ->
        {:kept, "holds repositories of its own: " <> Enum.join(nested, ", ")}

      true ->
        force_remove(repo_path, path)
    end
  end

  defp force_remove(repo_path, path) do
    case git(repo_path, ["worktree", "remove", "--force", path]) do
      {:ok, _} -> :removed
      {:error, out} -> {:error, out}
    end
  end

  # Its directory gone, the tree may still be registered: that one entry is dropped, and git's
  # refusal of a path it has no entry for is the same absence. Never a repository-wide
  # `worktree prune`, which would drop every missing worktree of the operator's with it.
  defp drop_entry(repo_path, path) do
    git(repo_path, ["worktree", "remove", "--force", path])
    :absent
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
  # off. `ProcessGroup.run/5` unsets GIT_ASKPASS and SSH_ASKPASS with the other credential names.
  defp bounded(script, args, timeout_ms, env \\ [], opts \\ []) do
    env = clear_repo_env() ++ [{"GIT_TERMINAL_PROMPT", "0"} | env]
    ProcessGroup.run("/bin/sh", ["-c", script, "sh" | args], timeout_ms, env, opts)
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

  # git with stdout as the ANSWER, untrimmed, and stderr kept apart: a warning git prints (an
  # ambiguous ref, say) must never be read as part of a commit id or a file's bytes. System.cmd
  # can only merge stderr into stdout, so the shell splits them itself and writes no file: git's
  # stdout goes straight out, its stderr is held in a variable and printed after it, followed by
  # a line giving its length in bytes, so the two are cut apart exactly.
  @split_stderr ~S"""
  exec 3>&1
  err=$("$0" "$@" 2>&1 >&3 3>&-)
  rc=$?
  exec 3>&-
  LC_ALL=C
  printf '%s\n%d' "$err" "${#err}"
  exit "$rc"
  """

  defp git_stdout(dir, args), do: split_git("git", dir, args)

  @doc false
  # git_stdout's mechanism, with the git to run passed in, so a test can run one that writes part
  # of its stdout and then fails.
  @spec split_git(String.t(), String.t(), [String.t()]) :: {:ok, binary()} | {:error, String.t()}
  def split_git(git, dir, args) do
    env = Enum.map(@repo_locating_env, &{&1, nil})
    {out, status} = System.cmd("sh", ["-c", @split_stderr, git, "-C", dir | args], env: env)

    case {split_stderr(out), status} do
      {{stdout, ""}, 0} ->
        {:ok, stdout}

      {{stdout, err}, 0} ->
        Logger.warning("git #{Enum.join(args, " ")} in #{dir} warned: #{String.trim(err)}")
        {:ok, stdout}

      {{_stdout, err}, _} when err != "" ->
        {:error, String.trim(err)}

      {_, 0} ->
        {:error, "git's output carried no length line"}

      _ ->
        {:error, "git exited #{status}"}
    end
  end

  defp split_stderr(out) do
    with [trailer, digits] <- Regex.run(~r/\n(\d+)\z/, out),
         n = String.to_integer(digits),
         at when at >= 0 <- byte_size(out) - byte_size(trailer) - n do
      {binary_part(out, 0, at), binary_part(out, at, n)}
    else
      _ -> :error
    end
  end
end
