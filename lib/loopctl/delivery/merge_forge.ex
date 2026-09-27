defmodule Loopctl.Delivery.MergeForge do
  @moduledoc """
  The forge WRITES the merge executor makes (US-45.5, Epic 45 PRD §4), as loopctl's GitHub
  App rather than as the `GITHUB_TOKEN` the gate reads with.

  A behaviour so the executor is tested against a Mox mock (`Loopctl.MockMergeForge`) and
  resolved from config (`config :loopctl, :delivery_merge_forge`), exactly as
  `Loopctl.Delivery.PullRequestSource` is. The adapter is
  `Loopctl.Delivery.GitHubAppMergeForge`.

  ## A session is the App acting on ONE repository

  `session/1` finds the App's installation on the repository and mints an installation token
  scoped to it; every other callback takes that session. With the App's credentials unset it
  answers `{:error, :app_unconfigured}` and makes no request, which the executor escalates:
  nothing merges without the App.

  ## Errors

  Every callback answers `{:error, reason}` in `PullRequestSource`'s classification —
  `{:github_unreachable, _}`, `{:github_rate_limited, status, delay}`, `{:github_api_error,
  status}` — so `Loopctl.Delivery.MergePrecondition.transient?/1` decides retry or escalate
  for both clients the same way. Three answers are FACTS rather than failures and have their
  own shape: a ref update GitHub refuses as not a fast-forward, a base merge that conflicts,
  and a branch that already exists. A reason carries the response's SHAPE only — a status and
  one of those names — never text the forge wrote, because the executor escalates it into a
  stored reason and the audit chain.
  """

  @typedoc "An installation token bound to one repository. Opaque to the executor."
  @type session :: %{repo: String.t(), token: String.t()}

  @type error :: {:error, term()}

  @typedoc "A commit as the Git Data API reads it: its tree and its parents, in order."
  @type commit :: %{sha: String.t(), tree_sha: String.t(), parents: [String.t()]}

  @doc "The App's installation token for `repo`; `{:error, :app_unconfigured}` without one."
  @callback session(repo :: String.t()) :: {:ok, session()} | error()

  @doc "The commit `branch` names now."
  @callback branch_head(session(), branch :: String.t()) :: {:ok, String.t()} | error()

  @doc "`sha`'s tree and parents (`GET /repos/:repo/git/commits/:sha`)."
  @callback commit(session(), sha :: String.t()) :: {:ok, commit()} | error()

  @doc """
  Whether `ancestor` is reachable from `descendant` (the compare API: `identical` or
  `ahead`). A commit the forge does not have is `{:ok, false}`, never an error: an ancestor
  that does not exist is not one.
  """
  @callback ancestor?(session(), ancestor :: String.t(), descendant :: String.t()) ::
              {:ok, boolean()} | error()

  @doc "Creates a commit object (`POST /repos/:repo/git/commits`); moves no ref."
  @callback create_commit(
              session(),
              %{tree: String.t(), parents: [String.t()], message: String.t()}
            ) :: {:ok, String.t()} | error()

  @doc """
  Moves `branch` to `sha` with `force: false` — the compare-and-swap. GitHub refuses a move
  that is not a fast-forward, answered `{:error, :not_fast_forward}`.
  """
  @callback update_ref(session(), branch :: String.t(), sha :: String.t()) ::
              :ok | {:error, :not_fast_forward} | error()

  @doc """
  Creates branch `branch` at `sha` (`POST /repos/:repo/git/refs`). A branch that already exists
  is `{:error, :ref_exists}`. The executor's base update runs on a temporary branch this makes.
  """
  @callback create_ref(session(), branch :: String.t(), sha :: String.t()) ::
              :ok | {:error, :ref_exists} | error()

  @doc "Deletes branch `branch` (`DELETE /repos/:repo/git/refs/heads/:branch`)."
  @callback delete_ref(session(), branch :: String.t()) :: :ok | error()

  @doc """
  Merges `head` INTO `base` on the forge (`POST /repos/:repo/merges`), moving `base`. The
  merge commit on success, `{:ok, :up_to_date}` when `base` already contains `head`, and
  `{:error, :merge_conflict}` when the two do not merge cleanly.
  """
  @callback merge(session(), base :: String.t(), head :: String.t(), message :: String.t()) ::
              {:ok, commit() | :up_to_date} | {:error, :merge_conflict} | error()

  @doc "The configured adapter."
  @spec impl() :: module()
  def impl,
    do: Application.get_env(:loopctl, :delivery_merge_forge, Loopctl.Delivery.GitHubAppMergeForge)
end
