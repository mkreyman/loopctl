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
  - `{:wait, {:transient, retry_after}}` — the forge could not be asked (timeout, connection
    error, 5xx, rate limit), whichever read of the call it was. The worker waits, bounded by a
    count of polls in a row that ended this way; `retry_after` is the forge's own delay in
    seconds, when it gave one
  - `{:refused, code}` — the commit is not one this CI can vouch for: its diff with the base
    is empty, so nothing shows the story's work is in it (`empty_change`), it changes its own
    CI definitions, or that could not be told. No verdict, ever
  - `{:no_verdict, code}` — a PERMANENT forge answer that ends the run with no verdict (a 401,
    a non-rate-limit 403, a 404, a 422, a truncated or unreadable list)

  Every `code` is a short fixed string naming the reason. It carries no URL and no repository
  name, because it is recorded on the run as it is.
  """

  alias Loopctl.Verification.Credential

  @type evidence :: %{
          required(:url) => String.t(),
          optional(:check) => String.t(),
          optional(:conclusion) => String.t()
        }

  @type wait :: {:wait, :ci_pending | {:transient, pos_integer() | nil}}

  @type outcome ::
          {:pass, evidence()}
          | {:fail, evidence()}
          | wait()
          | {:refused, String.t()}
          | {:no_verdict, String.t()}

  @typedoc """
  What one verification asks: the story's branch (resolved from loopctl's own records, never
  from the caller), the base branch its change is compared against, the commit's FULL id, the
  checks the intake source requires, and the credential the reads authenticate with. The
  REPOSITORY is the credential's (`credential.repo.full_name`, #936) and nowhere else, so the
  reads and the evidence URLs cannot name two different repositories.
  """
  @type request :: %{
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
  it cannot read `{:no_verdict, "repository_unreadable"}`.
  """
  @callback resolve_commit(sha :: String.t(), Credential.t()) ::
              {:ok, String.t()} | wait() | {:refused, String.t()} | {:no_verdict, String.t()}

  @doc """
  Whether the commit is a change this CI can vouch for, by the thread merge gate's change
  rules (the commit's tree against the base's, and its three-dot comparison with the base
  branch): `:ok`, or a refusal (`empty_change`, `ci_definition_changed`,
  `ci_definition_unknown`), a wait or a permanent no-verdict. The worker asks it once per run
  and records that it passed, so a merge landing during the CI wait — which empties that
  diff — cannot turn a commit already checked into a refused one.
  """
  @callback check_change(request()) ::
              :ok | wait() | {:refused, String.t()} | {:no_verdict, String.t()}

  @doc """
  The CI outcome for one commit of the story's branch, from its evidence alone: it compares
  nothing with the base (that is `check_change/1`). See the moduledoc.
  """
  @callback verdict(request()) :: outcome()
end
