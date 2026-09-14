defmodule Loopctl.DeliveryGates.Measurement.RepoHistory do
  @moduledoc """
  Reads merged changes out of a git checkout, READ-ONLY. Every command is a plumbing read
  (`log`, `diff`, `ls-tree`); nothing here checks out, fetches, or writes a ref, so it may be
  pointed at a working checkout somebody else is using.

  ## Why first-parent commits

  The target repositories squash-merge, so one first-parent commit IS one merged pull request
  and its diff against its parent IS that pull request's diff. That makes the replay's inputs
  the same shape the merge precondition reads from the forge — a file list, a rename list and
  a diffstat — without a network call.

  ## The command runner is injected

  `run/2` is a function `([arg], opts) -> {:ok, binary} | {:error, term}`, defaulting to
  `git -C <repo>`. Tests pass a runner over canned output, so the parsing is covered without
  a fixture repository and without `git` on the path.

  ## It refuses rather than guesses

  A commit whose diff, tree or diffstat cannot be read comes back as
  `{:error, {sha, reason}}` and is COUNTED as unreadable in the report, never dropped and
  never defaulted. A corpus quietly missing the changes that failed to read is a corpus
  nobody can size.
  """

  alias Loopctl.DeliveryGates.Measurement.Change

  @pr_number ~r/\(#(\d+)\)\s*\z/

  @type runner :: ([String.t()] -> {:ok, binary()} | {:error, term()})

  @type opts :: [
          runner: runner(),
          since: String.t() | nil,
          until: String.t() | nil,
          limit: pos_integer() | nil,
          content?: boolean()
        ]

  @doc """
  The shas of the first-parent commits in the window, newest first.

  `:since` and `:until` are passed to `git log` verbatim (any date it accepts); `:limit` caps
  the count. An empty window is `{:ok, []}` — a caller decides whether that is an error, and
  the report does: a rate over nothing is not a rate.
  """
  @spec shas(String.t(), opts()) :: {:ok, [String.t()]} | {:error, term()}
  def shas(repo, opts \\ []) do
    args =
      ["log", "--first-parent", "--format=%H"] ++
        window_args(opts) ++ ["HEAD"]

    case read(repo, args, opts) do
      {:ok, output} -> {:ok, String.split(output, "\n", trim: true)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reads one change. `content?: false` skips the hunk-content read, which is the expensive one
  and is only needed by `EffectOracle`.
  """
  @spec change(String.t(), String.t(), opts()) ::
          {:ok, Change.t()} | {:error, {String.t(), term()}}
  def change(repo, sha, opts \\ []) do
    with {:ok, [parent | _] = _parents, meta} <- header(repo, sha, opts),
         {:ok, diff} <- read(repo, ["diff", "--name-status", "-M", "-z", parent, sha], opts),
         {:ok, numstat} <- read(repo, ["diff", "--numstat", "-z", parent, sha], opts),
         {:ok, head_files} <- read(repo, ["ls-tree", "-r", "--name-only", "-z", sha], opts),
         {:ok, base_files} <- read(repo, ["ls-tree", "-r", "--name-only", "-z", parent], opts),
         {:ok, content} <- content(repo, parent, sha, opts) do
      {:ok,
       %Change{
         sha: sha,
         parent_sha: parent,
         pr_number: pr_number(meta.subject),
         subject: meta.subject,
         committed_at: meta.committed_at,
         diff: diff,
         diffstat: diffstat(numstat),
         content: content,
         head_files: nul_list(head_files),
         base_files: nul_list(base_files)
       }}
    else
      {:error, {^sha, _reason} = tagged} -> {:error, tagged}
      {:error, reason} -> {:error, {sha, reason}}
    end
  end

  @doc """
  Every change in the window, as a lazy stream of `{:ok, change} | {:error, {sha, reason}}`.

  Lazy because one change at a time is what the memory bound is: a single diff's content runs
  to tens of thousands of lines, and holding a repository's whole history of them would make
  the harness unrunnable on the smallest machine in the fleet.
  """
  @spec stream(String.t(), opts()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(repo, opts \\ []) do
    with {:ok, shas} <- shas(repo, opts) do
      {:ok, Stream.map(shas, &change(repo, &1, opts))}
    end
  end

  @doc "The default runner: `git -C <repo> <args>`, read-only."
  @spec git(String.t(), [String.t()]) :: {:ok, binary()} | {:error, term()}
  def git(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:git_unavailable, Exception.message(error)}}
  end

  # -- reading ------------------------------------------------------------------------------

  defp header(repo, sha, opts) do
    # %P is the parent list; %ct the committer timestamp; %s the subject. Read in ONE call so
    # the three cannot come from different commits.
    with {:ok, output} <- read(repo, ["log", "-1", "--format=%P%x00%ct%x00%s", sha], opts),
         [parents, timestamp, subject] <- output |> String.trim_trailing("\n") |> split_nul(3),
         {unix, ""} <- Integer.parse(timestamp),
         {:ok, committed_at} <- DateTime.from_unix(unix),
         [_ | _] = parent_list <- String.split(parents, " ", trim: true) do
      {:ok, parent_list, %{subject: subject, committed_at: committed_at}}
    else
      {:error, reason} -> {:error, {sha, reason}}
      [] -> {:error, {sha, :root_commit}}
      other -> {:error, {sha, {:unreadable_header, shape(other)}}}
    end
  end

  # `--unified=0` because only the changed lines are wanted and context would put a neighbouring
  # function's text into the oracle's input. `--no-color` and `--no-ext-diff` so a developer's
  # `~/.gitconfig` cannot inject escape codes or an external differ into what is being scanned.
  defp content(repo, parent, sha, opts) do
    if Keyword.get(opts, :content?, true) do
      args = ["diff", "--unified=0", "--no-color", "--no-ext-diff", parent, sha]

      with {:ok, unified} <- read(repo, args, opts) do
        {:ok, changed_lines(unified)}
      end
    else
      {:ok, nil}
    end
  end

  defp read(repo, args, opts) do
    runner = Keyword.get(opts, :runner, &git(repo, &1))
    runner.(args)
  end

  defp window_args(opts) do
    [
      {"--since", Keyword.get(opts, :since)},
      {"--until", Keyword.get(opts, :until)},
      {"--max-count", Keyword.get(opts, :limit)}
    ]
    |> Enum.flat_map(fn
      {_flag, nil} -> []
      {flag, value} -> ["#{flag}=#{value}"]
    end)
  end

  # -- parsing ------------------------------------------------------------------------------

  @doc """
  Sums `git diff --numstat -z` into the diffstat shape both gates take.

  A BINARY file's numstat is `-\t-\t<path>`: it has no line count, so its lines contribute 0
  while the file still counts toward `files`. Reporting a binary change as zero FILES would
  shrink the size bound around a change nobody can read.
  """
  @spec diffstat(binary()) :: Change.diffstat()
  def diffstat(numstat) do
    numstat
    |> String.split(<<0>>, trim: true)
    |> Enum.flat_map(&String.split(&1, "\n", trim: true))
    |> Enum.reduce(%{files: 0, changed_lines: 0}, fn record, acc ->
      case String.split(record, "\t") do
        [added, removed | _rest] ->
          %{
            files: acc.files + 1,
            changed_lines: acc.changed_lines + count(added) + count(removed)
          }

        _other ->
          acc
      end
    end)
  end

  # `-z` splits `--numstat` records on NUL for the PATHS only; the counts stay tab-separated
  # on one line, so a record may still arrive with a trailing newline. A non-numeric count is
  # git's binary marker.
  defp count(field) do
    case Integer.parse(String.trim(field)) do
      {n, ""} -> n
      _other -> 0
    end
  end

  @doc "The pull request number a squash-merge subject ends with, or nil."
  @spec pr_number(String.t()) :: pos_integer() | nil
  def pr_number(subject) when is_binary(subject) do
    case Regex.run(@pr_number, subject) do
      [_whole, digits] -> String.to_integer(digits)
      nil -> nil
    end
  end

  def pr_number(_subject), do: nil

  @doc """
  The ADDED and REMOVED lines of a unified diff, and nothing else.

  File headers (`+++ b/path`, `--- a/path`) are dropped: they are PATHS, and `EffectOracle`
  must not see one. Hunk headers are dropped for the same reason — `@@ ... @@ def foo` carries
  the enclosing function name, which is source rather than path but is context the change did
  not touch.
  """
  @spec changed_lines(binary()) :: String.t()
  def changed_lines(diff) when is_binary(diff) do
    diff
    |> String.split("\n")
    |> Enum.filter(&changed_line?/1)
    |> Enum.map_join("\n", &String.slice(&1, 1..-1//1))
  end

  defp changed_line?("+++ " <> _rest), do: false
  defp changed_line?("--- " <> _rest), do: false
  defp changed_line?("+" <> _rest), do: true
  defp changed_line?("-" <> _rest), do: true
  defp changed_line?(_line), do: false

  defp nul_list(output), do: String.split(output, <<0>>, trim: true)

  defp split_nul(binary, expected) do
    case String.split(binary, <<0>>) do
      parts when length(parts) == expected -> parts
      other -> other
    end
  end

  defp shape(value) when is_list(value), do: {:list, length(value)}
  defp shape(value) when is_atom(value), do: value
  defp shape(_value), do: :unreadable
end
