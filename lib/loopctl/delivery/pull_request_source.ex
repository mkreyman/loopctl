defmodule Loopctl.Delivery.PullRequestSource do
  @moduledoc """
  The facts about a real pull request that the merge precondition judges (issue #803,
  design §5 and §9). A behaviour, resolved through config-based DI, because loopctl holds
  no checkout of the target repository and must not reach the network from a context.

  `Loopctl.Delivery.MergePrecondition` resolves the implementation from
  `config :loopctl, :delivery_pull_request_source`; production is
  `Loopctl.Delivery.GitHubPullRequestSource` and the test environment is a Mox mock, so no
  test ever makes a live call.

  ## Every callback may fail, and a failure is never a pass

  Both callbacks return `{:error, reason}` for anything they could not establish —
  unreachable, rate-limited, a body that did not decode, a file list GitHub truncated. The
  precondition turns every one of them into an escalation naming the reason. There is no
  value either callback can return that lets a change merge on incomplete knowledge.

  ## `pull_request/2`

  Returns the facts of one pull request:

  - `:state` — `"open"` or `"closed"` as the forge reports it
  - `:merged?` — whether the pull request has ALREADY been merged, with `:merge_sha` set
    when it has. A resuming caller that crashed between merging and recording the merge
    asks again and adopts this answer instead of merging a second time; that is why a
    merged pull request is not an error here
  - `:head_sha`, `:merge_base_sha` — the two refs the file lists are read at
  - `:diffstat` — `%{files: n, changed_lines: n}`, the forge's own authoritative totals,
    NOT `length(files)`. A truncated file list must not shrink the diffstat that bounds it
  - `:diff` — a `Loopctl.DeliveryGates.DiffNames.parse/1`-SHAPED result, passed to
    `DiffNames.merge_input/2` untouched: `{:ok, %{files: _, renames: _}}` or
    `{:error, reason}`, which becomes Gate B's unreadable-diff marker. Every added,
    modified, deleted and renamed-to path, plus both names of every rename

  ## `repo_files/2`

  The repository's whole file list at one ref — Gate B's stale-trigger input. The
  precondition asks for it at BOTH the head and the merge base, because a pattern matching
  at one and not the other is exactly the drift the guard exists to catch.
  """

  alias Loopctl.DeliveryGates.DiffNames

  @type repo :: String.t()

  @type diff :: {:ok, DiffNames.parsed()} | {:error, term()}

  @type pull_request :: %{
          state: String.t(),
          merged?: boolean(),
          merge_sha: String.t() | nil,
          head_sha: String.t(),
          merge_base_sha: String.t(),
          diffstat: %{files: non_neg_integer(), changed_lines: non_neg_integer()},
          diff: diff()
        }

  @doc "The facts of one pull request. See the moduledoc."
  @callback pull_request(repo(), pos_integer()) :: {:ok, pull_request()} | {:error, term()}

  @doc "Every file the repository holds at `ref`."
  @callback repo_files(repo(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
end
