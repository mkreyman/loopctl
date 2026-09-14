defmodule Loopctl.Delivery.GitHubPullRequestSource do
  @moduledoc """
  `Loopctl.Delivery.PullRequestSource` over GitHub's REST API (issue #803, design §5).

  Three calls per evaluation, each bounded and none retried:

  1. `GET /repos/:repo/pulls/:number` — state, merged, head sha, base ref, and the
     AUTHORITATIVE diffstat (`changed_files`, `additions`, `deletions`)
  2. `GET /repos/:repo/compare/:base...:head` — the merge base sha
  3. `GET /repos/:repo/pulls/:number/files?per_page=100` — the changed names

  and one `GET /repos/:repo/git/trees/:ref?recursive=1` per `repo_files/2` call.

  Post-deploy verification (#803 §9) adds three more, each bounded the same way:

  4. `GET /repos/:repo/deployments?environment=:env&per_page=…` — a small page
     (`@deployment_page`) of the environment's newest deployments, each `sha` the commit the
     DEPLOYING JOB recorded. Never a workflow run's `head_sha`: a `workflow_run` deploy ships the
     triggering run's commit while the API attributes the run to the branch head at creation
     time, so the two diverge whenever two merges land minutes apart
  5. `GET /repos/:repo/deployments/:id/statuses?per_page=1` — one per deployment that
     SURVIVES the `since` filter, and none at all on the common early sweep where the deploy
     has not been created yet
  6. `GET /repos/:repo/compare/:sha...:ref` — whether a commit is reachable from another,
     which is what makes a story merged BEHIND the deployed head still count as shipped

  Telling the reporter what happened (#805) adds four more, and they are the only WRITES
  this module makes:

  7. `GET /repos/:repo/issues/:number` — state and labels, read BEFORE anything is written.
     An issue already closed carrying one of `Loopctl.Delivery.Resolution`'s labels is a
     close loopctl already made, and this read is what stops it being made twice
  8. `POST /repos/:repo/issues/:number/labels` — ADDS the resolution label. Additive rather
     than the issue endpoint's whole-set replace, which would drop a label somebody added
     between the read and the write
  9. `POST /repos/:repo/issues/:number/comments` — the resolution text
  10. `PATCH /repos/:repo/issues/:number` — `state: closed` with GitHub's `state_reason`.
      LAST, because the reporting system's webhook fires on the close and selects its
      resolution text by the label from call 8

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

  ## A 403 is two different things

  GitHub answers both a rate limit and a permanent permission denial with 403. They need
  opposite answers — retry versus tell a human — and the headers are what separate them:
  `x-ratelimit-remaining: 0` or the PRESENCE of a `retry-after` means a limit, and neither
  means the token cannot do this. A limit is reported as
  `{:github_rate_limited, status, delay}`; everything else keeps
  `{:github_api_error, status}`.

  Presence and parse are separate questions. A `Retry-After` this module cannot turn into a
  number — an HTTP-date, which is legal — still says "come back later", so it decides the
  CLASS; the delay then comes from `x-ratelimit-reset` instead. That header is never used to
  classify, because it rides on ordinary responses too, but it is the only thing that makes
  a PRIMARY (hourly) limit usable: without it the caller waits a floor measured in seconds
  against a window measured in an hour.

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

  # GitHub's primary rate-limit window is an hour. Anything beyond that plus slack is not a
  # window rolling over, so it is not turned into a delay a caller would sleep on.
  @max_reset_delay_seconds 3_900

  @repo_name ~r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}
  @ref ~r{\A[A-Za-z0-9_./-]+\z}
  @control ~r/[\x00-\x1f\x7f]/

  # How many of an environment's newest deployments one call reads, BEFORE the `since`
  # filter. Deep enough that reaching a record older than the merge is the ordinary outcome:
  # the forge applies this size first, so a page whose oldest record is still newer than
  # `since` is one that may be HIDING the deployment that carries the merge, and that is
  # refused rather than reported as a short list (a short list there is indistinguishable
  # from "nothing carries it" and ends in a confident false escalation).
  #
  # The list call is one request whatever this is; the cost is in the SURVIVORS, each of
  # which needs a status request and then a containment request from the verifier. So the
  # page is generous and the survivor count is what is capped.
  @deployment_page 30

  # How many deployments since the merge this will resolve states for. Past it the answer is
  # a refusal, not a truncated list, for the same reason as above.
  #
  # Five bounds the worst case at 11 requests for one story — one list, five statuses, and
  # the verifier's five containment calls — which at the 2s/5s timeouts is the ~77s the
  # sweep's wall-clock budget is sized against. More than five deployments landing on one
  # environment inside a story's verification window is an environment nobody can judge a
  # single merge against from here, and a human should look.
  @max_deployments_since 5

  # The largest resolution comment this will post. `Loopctl.Delivery.Resolution`'s longest
  # string is under 300 bytes, so this is a guard against a future caller rather than a bound
  # anyone meets — GitHub's own issue-body limit is 65,536 and a body it rejects for size
  # would fail a close that has no other reason to fail.
  @max_comment_bytes 8_192

  # Statuses read per deployment. More than one because `state` (the latest) and
  # `succeeded?` (did `success` EVER appear) are different questions, and it is the second
  # that says whether the commit shipped — GitHub writes `inactive` over a perfectly good
  # deployment as soon as a newer one succeeds. Same request either way.
  @status_page 20

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

  @impl true
  def deployments_since(repo, environment, %DateTime{} = since) do
    with {:ok, repo} <- repo_name(repo),
         {:ok, environment} <- environment(environment),
         path = "/deployments?environment=#{environment}&per_page=#{@deployment_page}",
         {:ok, body} <- get(repo, path) do
      deployments(repo, body, since)
    end
  end

  def deployments_since(_repo, _environment, since), do: {:error, {:invalid_since, shape(since)}}

  @doc "The most deployments since a merge this adapter will judge. See `@max_deployments_since`."
  @spec max_deployments_since() :: pos_integer()
  def max_deployments_since, do: @max_deployments_since

  @impl true
  def contains?(repo, sha, ref) do
    with {:ok, repo} <- repo_name(repo),
         {:ok, sha} <- ref(sha),
         {:ok, ref} <- ref(ref),
         {:ok, body} <- get(repo, "/compare/#{sha}...#{ref}") do
      containment(body)
    end
  end

  @impl true
  def issue(repo, number) when is_integer(number) and number > 0 do
    with {:ok, repo} <- repo_name(repo),
         {:ok, body} <- get(repo, "/issues/#{number}") do
      issue_facts(body)
    end
  end

  def issue(_repo, number), do: {:error, {:invalid_issue_number, number}}

  @impl true
  def label_issue(repo, number, label) when is_integer(number) and number > 0 do
    with {:ok, repo} <- repo_name(repo),
         {:ok, label} <- label(label),
         {:ok, _body} <- post(repo, "/issues/#{number}/labels", %{labels: [label]}) do
      :ok
    end
  end

  def label_issue(_repo, number, _label), do: {:error, {:invalid_issue_number, number}}

  @impl true
  def comment_issue(repo, number, body) when is_integer(number) and number > 0 do
    with {:ok, repo} <- repo_name(repo),
         {:ok, body} <- comment_body(body),
         {:ok, _response} <- post(repo, "/issues/#{number}/comments", %{body: body}) do
      :ok
    end
  end

  def comment_issue(_repo, number, _body), do: {:error, {:invalid_issue_number, number}}

  @impl true
  def close_issue(repo, number, state_reason)
      when is_integer(number) and number > 0 and state_reason in [:completed, :not_planned] do
    with {:ok, repo} <- repo_name(repo),
         {:ok, _body} <-
           patch(repo, "/issues/#{number}", %{
             state: "closed",
             state_reason: Atom.to_string(state_reason)
           }) do
      :ok
    end
  end

  def close_issue(_repo, number, state_reason) when is_integer(number) and number > 0,
    do: {:error, {:invalid_state_reason, state_reason}}

  def close_issue(_repo, number, _state_reason), do: {:error, {:invalid_issue_number, number}}

  # ONLY the two fields the closer judges on. The rest of an issue payload is reporter-
  # controlled text (`Loopctl.Intake.Record`'s untrusted boundary) and nothing here needs it,
  # so nothing here reads it.
  #
  # A non-string label is dropped rather than refused: it cannot match one of loopctl's, and
  # refusing the whole read on it would strand a close on somebody else's malformed label.
  defp issue_facts(%{"state" => state, "labels" => labels})
       when is_binary(state) and is_list(labels) do
    {:ok, %{state: state, labels: for(name <- Enum.map(labels, &label_name/1), name, do: name)}}
  end

  defp issue_facts(body), do: {:error, {:unreadable_issue, shape(body)}}

  defp label_name(%{"name" => name}) when is_binary(name), do: name
  defp label_name(name) when is_binary(name), do: name
  defp label_name(_other), do: nil

  # A label goes in a JSON BODY, never a URL path, so nothing here can address another
  # resource. What is still refused is what a body cannot make safe: an empty name, a control
  # character, or anything that is not a string.
  defp label(name) when is_binary(name) do
    if String.valid?(name) and name != "" and not Regex.match?(@control, name),
      do: {:ok, name},
      else: {:error, {:invalid_label, printable(name)}}
  end

  defp label(name), do: {:error, {:invalid_label, shape(name)}}

  # The resolution text. Capped because it becomes a comment on somebody else's ticket and a
  # body GitHub rejects for size would fail the whole close; `Loopctl.Delivery.Resolution`'s
  # strings are two orders of magnitude under this, so the cap is a guard rather than a
  # constraint anyone will meet.
  defp comment_body(body) when is_binary(body) do
    if String.valid?(body) and body != "" and byte_size(body) <= @max_comment_bytes,
      do: {:ok, body},
      else: {:error, {:invalid_comment_body, byte_size(body)}}
  end

  defp comment_body(body), do: {:error, {:invalid_comment_body, shape(body)}}

  # GitHub lists deployments newest first. The `since` filter is applied BEFORE any status
  # call, so the common early sweep — the deploy job has not created its record yet — costs
  # exactly one request and returns `{:ok, []}`.
  #
  # An empty list is a FACT, not a failure. Calling it an error would put it in the
  # transient/permanent classification, where "my deploy has not started" belongs to
  # neither: it is not going to clear on a retry of a broken call, and it is not a contract
  # change. The verifier waits on it, bounded by its own in-flight count.
  defp deployments(repo, entries, since) when is_list(entries) do
    entries
    |> Enum.map(&deployment_record/1)
    |> Enum.reduce_while({:ok, []}, &keep_since(&1, &2, since))
    |> case do
      {:ok, kept} -> kept |> Enum.reverse() |> bounded(entries, since, repo)
      error -> error
    end
  end

  defp deployments(_repo, body, _since), do: {:error, {:unreadable_deployments, shape(body)}}

  # Two ways the answer can be INCOMPLETE, and neither is a refusal HERE.
  #
  # A page that never reached a record older than `since` may be hiding the deployment that
  # carries the merge — the forge applied its page size before this filter did — and more
  # survivors than this adapter resolves states for is the same problem one layer along.
  #
  # Refusing on either at THIS point discarded a definitive answer. The verifier resolves
  # containment over the NEWEST records, and a carrying success there settles the verdict
  # whatever is hidden below it; refusing first meant a shipped story escalated on its first
  # sweep, naming the cap rather than anything about the story — and permanently, because
  # `since` is pinned to the merge so deployments only accumulate. A delayed sweep (a
  # backlog at `deployed`, a worker restart, a run of forge faults) hit it every time.
  #
  # So incompleteness travels as a FACT beside the newest records, and only the ABSENCE of a
  # carrying success lets the verifier turn it into an escalation.
  defp bounded(kept, entries, since, repo) do
    # Truncation FIRST: when the page is full it is the more accurate diagnosis, and a full
    # page is also over the survivor cap, so the other test would mask it.
    incomplete =
      cond do
        truncated?(kept, entries) -> {:deployment_page_exhausted, @deployment_page, since}
        length(kept) > @max_deployments_since -> too_many(kept)
        true -> nil
      end

    with {:ok, resolved} <- kept |> Enum.take(@max_deployments_since) |> resolve_states(repo) do
      {:ok, %{deployments: resolved, incomplete: incomplete}}
    end
  end

  defp too_many(kept),
    do: {:too_many_deployments_since_merge, length(kept), @max_deployments_since}

  # The page was FULL and every record on it survived the filter, so there may be more.
  # A page that reached an older record, or a short page, is the whole truth.
  defp truncated?(kept, entries),
    do: length(entries) >= @deployment_page and length(kept) == length(entries)

  # The list is newest first, so the FIRST record older than `since` ends it: nothing below
  # it can be newer, and every one of them would cost a status call to learn nothing.
  defp keep_since({:error, _reason} = error, _acc, _since), do: {:halt, error}

  defp keep_since({:ok, %{created_at: created_at} = record}, {:ok, acc}, since) do
    if DateTime.compare(created_at, since) == :lt,
      do: {:halt, {:ok, acc}},
      else: {:cont, {:ok, [record | acc]}}
  end

  defp deployment_record(%{"id" => id, "sha" => sha, "created_at" => created_at})
       when is_integer(id) and is_binary(sha) and is_binary(created_at) do
    case DateTime.from_iso8601(created_at) do
      {:ok, at, _offset} -> {:ok, %{id: id, sha: sha, created_at: at}}
      {:error, reason} -> {:error, {:unreadable_deployment_created_at, reason}}
    end
  end

  defp deployment_record(entry), do: {:error, {:unreadable_deployments, shape(entry)}}

  defp resolve_states(records, repo) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      case deployment_state(repo, record.id) do
        {:ok, facts} -> {:cont, {:ok, [Map.merge(record, facts) | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      error -> error
    end
  end

  # TWO facts from one request, because they answer different questions.
  #
  # `state` is the LATEST status. A deployment with none yet has not settled, which is the
  # same answer to a verifier as `queued`/`pending`/`in_progress`: ask again. An
  # unrecognised state is NOT approximated — a state we have not thought about is not
  # evidence that a deploy succeeded.
  #
  # `succeeded?` is whether `success` appears anywhere in the history. That is the one that
  # says the commit SHIPPED: GitHub writes `inactive` over an earlier deployment as soon as
  # a newer one succeeds, so a deployment that shipped is routinely `inactive` by the time
  # a sweep reads it, and judging on `state` alone escalated those.
  defp deployment_state(repo, id) do
    case get(repo, "/deployments/#{id}/statuses?per_page=#{@status_page}") do
      {:ok, []} -> {:ok, %{state: :pending, succeeded?: false}}
      {:ok, [_ | _] = statuses} -> deployment_facts(statuses)
      {:ok, body} -> {:error, {:unreadable_deployment_statuses, shape(body)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # EVERY element is validated, not just the head. Reading a PAGE of statuses is what made
  # this reachable: a non-map element (a proxy body, a partial response) reached
  # `Access.fetch/2` inside the scan and raised a `FunctionClauseError`, which propagates out
  # of the sweep, kills the run for every remaining candidate and burns an Oban attempt.
  defp deployment_facts([%{"state" => latest} | _rest] = statuses) when is_binary(latest) do
    if Enum.all?(statuses, &match?(%{"state" => s} when is_binary(s), &1)) do
      with {:ok, state} <- map_state(latest) do
        {:ok, %{state: state, succeeded?: Enum.any?(statuses, &(&1["state"] == "success"))}}
      end
    else
      {:error, {:unreadable_deployment_statuses, shape(statuses)}}
    end
  end

  defp deployment_facts(statuses),
    do: {:error, {:unreadable_deployment_statuses, shape(statuses)}}

  defp map_state("success"), do: {:ok, :success}
  defp map_state("failure"), do: {:ok, :failure}
  defp map_state("error"), do: {:ok, :error}
  defp map_state("inactive"), do: {:ok, :inactive}
  defp map_state(state) when state in ~w(queued pending in_progress), do: {:ok, :pending}
  defp map_state(state), do: {:error, {:unrecognised_deployment_state, printable(state)}}

  # `status` describes the HEAD relative to the BASE, and the call is
  # `compare/<sha>...<ref>` — so `identical` is the same commit and `ahead` means `ref` is
  # ahead of `sha`, i.e. `sha` is an ancestor of it. `behind` and `diverged` both mean the
  # commit is NOT in what `ref` names.
  defp containment(%{"status" => status}) when status in ~w(identical ahead), do: {:ok, true}
  defp containment(%{"status" => status}) when status in ~w(behind diverged), do: {:ok, false}

  defp containment(%{"status" => status}) when is_binary(status),
    do: {:error, {:unrecognised_compare_status, printable(status)}}

  defp containment(body), do: {:error, {:unreadable_compare, shape(body)}}

  # An environment name goes in a QUERY PARAMETER, so it is ENCODED, not pattern-matched.
  #
  # It was validated against `@ref` and that was wrong in the direction that costs the most:
  # GitHub environment names legally contain spaces (and much else), so a repository whose
  # environment is called "production (fly)" made every waiting story escalate on a
  # PERMANENT `invalid_environment` — an operator setting a correct value and being told it
  # is malformed. `URI.encode_www_form/1` handles `&`, `?`, `#`, spaces and the rest, so
  # nothing here can add a parameter of its own or address another resource.
  #
  # What is still refused is what encoding cannot make safe: a NUL or a control character,
  # which is not a name anyone configured on purpose, and anything that is not a string.
  defp environment(name) when is_binary(name) do
    if String.valid?(name) and name != "" and not Regex.match?(@control, name),
      do: {:ok, URI.encode_www_form(name)},
      else: {:error, {:invalid_environment, printable(name)}}
  end

  defp environment(name), do: {:error, {:invalid_environment, shape(name)}}

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

  # BOTH refs go through `ref/1`. `head_sha` is remote data like every other field on the
  # response, and it is spliced into a URL path — an unvalidated one could change which
  # resource is addressed.
  defp merge_base(repo, base_ref, head_sha) do
    with {:ok, base_ref} <- ref(base_ref),
         {:ok, head_sha} <- ref(head_sha),
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
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{} = response} -> {:error, failure(response)}
      {:error, reason} -> {:error, {:github_unreachable, shape(reason)}}
    end
  end

  # The two WRITE verbs (#805). Same options as `get/2` — the same bounded timeouts, the same
  # `retry: false`, the same `redirect: false` — so a write is no less bounded than a read and
  # a renamed repository cannot silently redirect one onto somebody else's issue.
  #
  # `retry: false` matters more here than it does on a read: Req's default retry would repeat
  # an outward act, and the caller's at-most-once record cannot see a retry the HTTP client
  # made underneath it.
  defp post(repo, path, body), do: write(&Req.post/2, repo, path, body)
  defp patch(repo, path, body), do: write(&Req.patch/2, repo, path, body)

  # GitHub answers 200 or 201 to the three writes here. Every other status goes through the
  # SAME `failure/1` a read does, so a rate limit stays transient and a 403 the headers do not
  # call a limit stays a permanent permission problem — one classification for the whole
  # client, which is why these live on this module rather than a second one.
  defp write(verb, repo, path, body) do
    url = @api_base <> "/repos/" <> repo <> path

    case verb.(url, Keyword.put(req_options(), :json, body)) do
      {:ok, %Req.Response{status: status, body: body}} when status in [200, 201] -> {:ok, body}
      {:ok, %Req.Response{} = response} -> {:error, failure(response)}
      {:error, reason} -> {:error, {:github_unreachable, shape(reason)}}
    end
  end

  # A 403 is TWO different things at GitHub and they need opposite answers.
  #
  # A rate limit is transient: wait and it clears, so the caller retries and the story stays
  # where it is. A PERMISSION denial is permanent — "Resource not accessible by personal
  # access token" is the shape a fine-grained token with pull-request read but no contents
  # read returns for every tree call, forever. Calling that transient makes the gate answer
  # "retry" for all time with no escalation ever written and no human told, which is exactly
  # what the 404/401 classification exists to avoid, reached through the one status assumed
  # benign.
  #
  # The headers are what tell them apart: GitHub sends `x-ratelimit-remaining: 0` on a
  # primary-limit 403 and a `retry-after` on a secondary one. Neither present means the
  # token cannot do this, and that is configuration for a human.
  # PRESENCE decides the CLASS; the parse only decides the DELAY. A 403 carrying a
  # `Retry-After` this module cannot turn into a number — an HTTP-date, which is legal — is
  # still a rate limit, and classifying it as a permission denial would escalate a story on
  # the one shape that says most clearly "come back later".
  defp failure(%Req.Response{status: status} = response) when status in [403, 429] do
    if status == 429 or limited?(response),
      do: {:github_rate_limited, status, delay(response)},
      else: {:github_api_error, 403}
  end

  defp failure(%Req.Response{status: status}), do: {:github_api_error, status}

  # The two signals GitHub uses, and ONLY these two. `x-ratelimit-reset` is deliberately not
  # one of them: it rides on ordinary responses too, so its presence says nothing about why
  # THIS one failed. It is read below, for the delay, once the class is already decided.
  defp limited?(response) do
    exhausted?(response) or Req.Response.get_header(response, "retry-after") != []
  end

  defp exhausted?(response) do
    case Req.Response.get_header(response, "x-ratelimit-remaining") do
      ["0" | _rest] -> true
      _other -> false
    end
  end

  # How long to wait, in seconds, from whichever header can say.
  #
  # `x-ratelimit-reset` is what makes a PRIMARY limit usable: it is the epoch second the
  # hourly window rolls over, and without it the caller falls back to a floor measured in
  # seconds against a window measured in an hour — which then trips the consecutive-
  # unevaluated bound and escalates the very fault that was going to clear on its own.
  # `Retry-After` wins when it parses, because a secondary limit is the forge speaking about
  # THIS request.
  defp delay(response) do
    retry_after_seconds(response) || reset_seconds(response)
  end

  defp retry_after_seconds(response) do
    with [value | _rest] <- Req.Response.get_header(response, "retry-after"),
         {seconds, ""} <- Integer.parse(String.trim(value)),
         true <- seconds > 0 do
      seconds
    else
      _other -> nil
    end
  end

  # An epoch second in the PAST, or one absurdly far ahead, tells a caller nothing useful, so
  # neither becomes a delay. The cap is the forge's own longest window plus slack.
  defp reset_seconds(response) do
    with [value | _rest] <- Req.Response.get_header(response, "x-ratelimit-reset"),
         {epoch, ""} <- Integer.parse(String.trim(value)),
         seconds = epoch - DateTime.to_unix(DateTime.utc_now()),
         true <- seconds > 0 and seconds <= @max_reset_delay_seconds do
      seconds
    else
      _other -> nil
    end
  end

  defp req_options do
    maybe_add_plug(
      headers: headers(),
      retry: false,
      # A renamed or transferred repository REDIRECTS, and Req follows by default — so the
      # gate would read a repository the trigger list is not keyed to and judge the change
      # against someone else's paths. `Loopctl.Webhooks.ReqDelivery` pins the same way.
      redirect: false,
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
