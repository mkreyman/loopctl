defmodule Loopctl.Verification.CiBehaviour do
  @moduledoc """
  US-26.4.3, redesigned by US-26.4.6 — what a CI provider answers story verification.

  The adapter is the ONLY place that knows its forge's failure vocabulary. It classifies every
  read into one of the declared outcomes below, and the verification worker
  (`Loopctl.Workers.VerificationRunnerWorker`) branches on those alone — it never matches an
  adapter's error terms, so a second adapter, or a renamed error inside this one, cannot
  silently turn a wait into a final answer.

  ## Outcomes

  - `{:pass, evidence}` / `{:fail, evidence}` — a verdict. `evidence.url` points at the judged
    run (pass) or the failing job (fail), inside the tenant's own repository
  - `{:wait, :ci_pending}` — the forge answered and a required check is still running or not
    reported yet. The worker waits, bounded by the run's age
  - `{:wait, {:transient, retry_after, answered}}` — the forge could not be asked (timeout,
    connection error, 5xx, rate limit). The worker waits, bounded by a count of unanswered
    reads in a row; `retry_after` is the forge's own delay in seconds, when it gave one, and
    `answered` is `true` when an EARLIER read of the same call was answered (the comparison,
    before the evidence read faulted), which ends the previous streak
  - `{:refused, code}` — the commit is not one this CI can vouch for (it changes its own CI
    definitions, or that could not be told). No verdict, and never a local fallback
  - `{:no_verdict, code}` — a PERMANENT forge answer that ends the run with no verdict (a 401,
    a non-rate-limit 403, a 404, a 422, a truncated or unreadable list). The worker may fall
    back to local re-execution, when the commit's full id is known

  Every `code` is a short fixed string naming the reason. It carries no URL and no repository
  name, because it is recorded on the run as it is.
  """

  alias Loopctl.Verification.Credential

  @type evidence :: %{
          required(:url) => String.t(),
          optional(:check) => String.t(),
          optional(:conclusion) => String.t()
        }

  @type wait :: {:wait, :ci_pending | {:transient, pos_integer() | nil, boolean()}}

  @type outcome ::
          {:pass, evidence()}
          | {:fail, evidence()}
          | wait()
          | {:refused, String.t()}
          | {:no_verdict, String.t()}

  @typedoc """
  What one verification asks: the story's repository and branch (both resolved from loopctl's
  own records, never from the caller), the base branch its change is compared against, the
  commit's FULL id, the checks the intake source requires, and the credential that licenses
  the read.
  """
  @type request :: %{
          repo: String.t(),
          branch: String.t(),
          base_branch: String.t(),
          sha: String.t(),
          required_checks: [String.t()],
          credential: Credential.t()
        }

  @doc """
  The full id of an abbreviated commit SHA. Asked once per run; the worker persists the
  answer. A prefix the forge cannot resolve to one commit is `{:no_verdict, "unresolved_sha"}`
  (GitHub answers an unknown prefix and an ambiguous one with the same 422), and a repository
  it cannot read `{:no_verdict, "repository_unreadable"}`. A transient fault here is never
  `answered`: it is the call's only read.
  """
  @callback resolve_commit(repo :: String.t(), sha :: String.t(), Credential.t()) ::
              {:ok, String.t()} | wait() | {:refused, String.t()} | {:no_verdict, String.t()}

  @doc "The CI outcome for one commit of the story's branch. See the moduledoc."
  @callback verdict(request()) :: outcome()
end
