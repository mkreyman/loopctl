defmodule Loopctl.Delivery.GitHubPullRequestSource do
  @moduledoc """
  `Loopctl.Delivery.PullRequestSource` over GitHub's REST API (issue #803, design §5).

  Three calls per evaluation, each bounded and none retried:

  1. `GET /repos/:repo/pulls/:number` — state, merged, head sha, base ref, and the
     AUTHORITATIVE diffstat (`changed_files`, `additions`, `deletions`)
  2. `GET /repos/:repo/compare/:base...:head` — the merge base sha
  3. `GET /repos/:repo/pulls/:number/files?per_page=100` — the changed names

  and one `GET /repos/:repo/git/trees/:ref?recursive=1` per `repo_files/2` call.

  ## Slow connections, and the ceiling a caller sees

  Every request carries a 2s connect timeout and a 5s receive timeout, and `retry: false`
  — Req retries transient failures by DEFAULT, which would multiply the ceiling silently.
  Three calls for `pull_request/2` and one for `repo_files/2`, so a precondition that makes
  all five (a pull request plus two refs) waits at most 35 seconds before it has an answer,
  and the answer to a timeout is an ESCALATION, never a pass. Nothing here runs inside a
  database transaction: the caller gathers every fact before it opens one, so a slow forge
  never holds a pooled connection.

  ## What is refused rather than approximated

  - a file list GitHub TRUNCATED (`changed_files` beyond one page of 100) — the diffstat
    already escalates such a change on the size bound, but a short list must never be
    presented as the whole diff
  - a `truncated: true` git tree — an incomplete file list would read as a stale trigger,
    or worse, hide one
  - any status in `files[]` this module does not map, `"unchanged"` included. A status we
    have not thought about is not evidence that nothing was touched
  - a rename with no `previous_filename` — Gate B matches triggers against BOTH names, so
    a rename missing its old name could move a file out of a guarded path unseen

  ## Authentication

  `GITHUB_TOKEN`, through `Loopctl.Verification.GitHubActions.auth_headers/1` — one rule
  for the whole application, including its blank-value handling. Unset means anonymous
  calls, which work for a public repository until GitHub's per-IP hourly limit bites and
  then escalate rather than pass.
  """

  @behaviour Loopctl.Delivery.PullRequestSource

  alias Loopctl.Verification.GitHubActions

  @api_base "https://api.github.com"
  @connect_timeout_ms 2_000
  @receive_timeout_ms 5_000
  @files_per_page 100

  @repo_name ~r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}
  @ref ~r{\A[A-Za-z0-9_./-]+\z}

  @impl true
  def pull_request(repo, number) when is_integer(number) and number > 0 do
    with {:ok, repo} <- repo_name(repo),
         {:ok, pr} <- get(repo, "/pulls/#{number}"),
         {:ok, facts} <- pull_request_facts(pr) do
      merged_or_open(repo, number, facts)
    end
  end

  def pull_request(_repo, number), do: {:error, {:invalid_pr_number, number}}

  @impl true
  def repo_files(repo, ref) do
    with {:ok, repo} <- repo_name(repo),
         {:ok, ref} <- ref(ref),
         {:ok, body} <- get(repo, "/git/trees/#{ref}?recursive=1") do
      tree(body, ref)
    end
  end

  # A MERGED pull request is answered without reading its diff or its merge base: the
  # outward effect has already happened, so there is nothing left to gate, and the caller's
  # business here is adopting the sha rather than merging a second time.
  defp merged_or_open(_repo, _number, %{merged?: true} = facts) do
    {:ok,
     facts
     |> Map.delete(:base_ref)
     |> Map.merge(%{merge_base_sha: facts.head_sha, diff: {:ok, empty_diff()}})}
  end

  defp merged_or_open(repo, number, facts) do
    with {:ok, merge_base_sha} <- merge_base(repo, facts.base_ref, facts.head_sha) do
      {:ok,
       facts
       |> Map.delete(:base_ref)
       |> Map.merge(%{merge_base_sha: merge_base_sha, diff: diff(repo, number, facts.diffstat)})}
    end
  end

  defp empty_diff, do: %{files: [], renames: []}

  defp pull_request_facts(%{
         "state" => state,
         "merged" => merged,
         "merge_commit_sha" => merge_sha,
         "head" => %{"sha" => head_sha},
         "base" => %{"ref" => base_ref},
         "changed_files" => changed_files,
         "additions" => additions,
         "deletions" => deletions
       })
       when is_boolean(merged) do
    if strings?([state, head_sha, base_ref]) and counts?([changed_files, additions, deletions]) do
      {:ok,
       %{
         state: state,
         merged?: merged,
         merge_sha: if(merged and is_binary(merge_sha), do: merge_sha),
         head_sha: head_sha,
         base_ref: base_ref,
         diffstat: %{files: changed_files, changed_lines: additions + deletions}
       }}
    else
      {:error, {:unreadable_pull_request, :invalid_field_types}}
    end
  end

  defp pull_request_facts(body), do: {:error, {:unreadable_pull_request, shape(body)}}

  defp strings?(values), do: Enum.all?(values, &is_binary/1)
  defp counts?(values), do: Enum.all?(values, &(is_integer(&1) and &1 >= 0))

  defp merge_base(repo, base_ref, head_sha) do
    with {:ok, base_ref} <- ref(base_ref),
         {:ok, body} <- get(repo, "/compare/#{base_ref}...#{head_sha}") do
      case body do
        %{"merge_base_commit" => %{"sha" => sha}} when is_binary(sha) -> {:ok, sha}
        _other -> {:error, {:unreadable_merge_base, shape(body)}}
      end
    end
  end

  # Returned as a `DiffNames.parse/1`-shaped value, so an error here becomes Gate B's
  # unreadable-diff marker rather than a short file list.
  defp diff(_repo, _number, %{files: count}) when count > @files_per_page,
    do: {:error, {:file_list_truncated, count}}

  defp diff(repo, number, %{files: count}) do
    case get(repo, "/pulls/#{number}/files?per_page=#{@files_per_page}") do
      {:ok, entries} when is_list(entries) -> collect(entries, count)
      {:ok, body} -> {:error, {:unreadable_file_list, shape(body)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect(entries, expected) when length(entries) < expected,
    do: {:error, {:file_list_short, length(entries), expected}}

  defp collect(entries, _expected) do
    collected =
      Enum.reduce_while(entries, {:ok, empty_diff()}, fn entry, {:ok, acc} ->
        case entry(entry) do
          {:file, path} -> {:cont, {:ok, %{acc | files: [path | acc.files]}}}
          {:rename, old, new} -> {:cont, {:ok, add_rename(acc, old, new)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case collected do
      {:ok, acc} -> {:ok, reverse(acc)}
      error -> error
    end
  end

  defp reverse(acc),
    do: %{files: acc.files |> Enum.reverse() |> Enum.uniq(), renames: Enum.reverse(acc.renames)}

  defp add_rename(acc, old, new),
    do: %{acc | files: [new | acc.files], renames: [{old, new} | acc.renames]}

  # A deletion under a guarded path is a change to it, so `removed` is a touched path.
  # A copy leaves its source untouched, so only the new path counts.
  defp entry(%{"status" => status, "filename" => path})
       when status in ~w(added removed modified changed copied) and is_binary(path),
       do: {:file, path}

  defp entry(%{"status" => "renamed", "filename" => new, "previous_filename" => old})
       when is_binary(new) and is_binary(old),
       do: {:rename, old, new}

  defp entry(%{"status" => "renamed", "filename" => new}),
    do: {:error, {:rename_without_previous_filename, printable(new)}}

  defp entry(%{"status" => status}), do: {:error, {:unrecognised_status, printable(status)}}
  defp entry(entry), do: {:error, {:unreadable_file_entry, shape(entry)}}

  defp tree(%{"truncated" => true}, ref), do: {:error, {:tree_truncated, ref}}

  defp tree(%{"tree" => entries}, _ref) when is_list(entries) do
    {:ok, for(%{"type" => "blob", "path" => path} <- entries, is_binary(path), do: path)}
  end

  defp tree(body, _ref), do: {:error, {:unreadable_tree, shape(body)}}

  defp get(repo, path) do
    url = @api_base <> "/repos/" <> repo <> path

    case Req.get(url, req_options()) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:github_api_error, status}}
      {:error, reason} -> {:error, {:github_unreachable, shape(reason)}}
    end
  end

  defp req_options do
    maybe_add_plug(
      headers: headers(),
      retry: false,
      receive_timeout: @receive_timeout_ms,
      connect_options: [timeout: @connect_timeout_ms]
    )
  end

  # The same `Req.Test` seam `Loopctl.Webhooks.ReqDelivery` uses, so the response mapping
  # below — which decides whether a guarded path is SEEN — is exercised against real bytes
  # instead of only in production.
  defp maybe_add_plug(opts) do
    case Application.get_env(:loopctl, :delivery_github_req_plug) do
      nil -> opts
      plug -> Keyword.put(opts, :plug, plug)
    end
  end

  defp headers do
    GitHubActions.auth_headers(System.get_env("GITHUB_TOKEN")) ++
      [
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", "2022-11-28"},
        {"user-agent", "loopctl-delivery-gates"}
      ]
  end

  defp repo_name(repo) when is_binary(repo) do
    if Regex.match?(@repo_name, repo), do: {:ok, repo}, else: {:error, {:invalid_repo, repo}}
  end

  defp repo_name(repo), do: {:error, {:invalid_repo, shape(repo)}}

  # Interpolated into a URL path, so it may carry nothing that changes which resource is
  # addressed: no `?`, no `#`, no `..` segment, no percent escape.
  defp ref(ref) when is_binary(ref) do
    if Regex.match?(@ref, ref) and ".." not in String.split(ref, "/"),
      do: {:ok, ref},
      else: {:error, {:invalid_ref, printable(ref)}}
  end

  defp ref(ref), do: {:error, {:invalid_ref, shape(ref)}}

  defp printable(value) when is_binary(value) do
    if String.valid?(value) and String.printable?(value),
      do: String.slice(value, 0, 120),
      else: inspect(value, binaries: :as_binaries)
  end

  defp printable(value), do: shape(value)

  # A forge response is remote data. Only its SHAPE is echoed into a reason that reaches a
  # log line and an escalation, never its content.
  defp shape(%module{}), do: module
  defp shape(value) when is_map(value), do: {:map, value |> Map.keys() |> Enum.sort()}
  defp shape(value) when is_list(value), do: {:list, length(value)}
  defp shape(value) when is_atom(value), do: value
  defp shape(_value), do: :unreadable
end
