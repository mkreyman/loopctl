defmodule Loopctl.Delivery.RetryCeiling do
  @moduledoc """
  How many times the delivery loop may spend a dispatch on one story before a human decides
  (epic 44, US-44.4, #877). Pure — no database, no process.

  ## What is counted

  A release COUNTS when it spent an attempt: the lease ran out (`:runner_lost`), a runner
  reported `crashed`, a verifier rejected the work, the claimant gave the story back, or a
  placement was refused for a reason that recurs on every pass. Those are the two release
  edges a counted requeue writes into `story_stages.attempts` — `runner_lost` and
  `claim_released` — and `counted_releases/1` is their sum.

  A release that spent nothing is never written into either key, so it never reaches this
  sum: a placement refused because the runner was unavailable before any work, a subscription
  that ran dry (`usage_exhausted`), and an operator's force-unclaim, which is a human decision
  and goes to `escalated` instead (`Loopctl.Delivery.Stages.follow_release/5`).

  The count lives on the stage row and is never reset, a human re-queue included — so a story
  a human sent back after it reached the ceiling gets exactly one more attempt before it is in
  front of them again. That is the point of a ceiling on spend: the human decided to pay once
  more, not to re-open the budget.

  ## The ceiling has NO DEFAULT

  `DISPATCH_MAX_ATTEMPTS` is spend, and it follows the rule the dispatch budgets follow (#875):
  a figure nobody chose must not quietly become the cost policy. Unset, malformed or negative
  reads as a ceiling of `0` — the first counted release escalates, so nothing is ever spent
  twice on a number nobody set. `config/runtime.exs` parses the variable with `parse/1`; every
  release reads the configured value through `max_attempts/0`, which hands it to
  `ceiling_from/1` — the function the unset case is tested through.
  """

  @config_key :dispatch_max_attempts

  # The release edges a COUNTED requeue writes into `attempts`. Only a requeue whose `:cause`
  # is `:attempt` increments them (`Stages.follow_release/5`), so their sum is the number of
  # attempts this story has cost.
  @counted_edges ~w(runner_lost claim_released)

  @doc """
  Parses the `DISPATCH_MAX_ATTEMPTS` value `config/runtime.exs` read. A non-negative integer
  is `{:ok, n}`; anything else — unset, empty, malformed, negative — is `:unset`, which leaves
  the key out of the config and so reads as `0`.
  """
  @spec parse(String.t() | nil) :: {:ok, non_neg_integer()} | :unset
  def parse(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n >= 0 -> {:ok, n}
      _malformed -> :unset
    end
  end

  def parse(nil), do: :unset

  @doc """
  The configured ceiling: the most counted releases a story may take and still be re-queued.
  Reads the ONE key from the `:loopctl` application env and hands it to `ceiling_from/1`.
  """
  @spec max_attempts() :: non_neg_integer()
  def max_attempts, do: ceiling_from(Application.get_env(:loopctl, @config_key))

  @doc """
  The ceiling a configured value stands for: a non-negative integer as it is, and anything
  else — unset (`nil`), negative, not an integer — `0`, never a guess. Pure, so the unset case
  is tested here without touching the application env.
  """
  @spec ceiling_from(term()) :: non_neg_integer()
  def ceiling_from(n) when is_integer(n) and n >= 0, do: n
  def ceiling_from(_unset), do: 0

  @doc """
  The counted releases recorded in a stage row's `attempts` map (`runner_lost` plus
  `claim_released`). A missing key is zero.
  """
  @spec counted_releases(map()) :: non_neg_integer()
  def counted_releases(attempts) when is_map(attempts) do
    Enum.reduce(@counted_edges, 0, fn edge, total -> total + count_of(attempts, edge) end)
  end

  @doc """
  What a COUNTED release does, given the story's counted releases INCLUDING this one: fewer
  than the ceiling is a retry, reaching it escalates.
  """
  @spec decide(non_neg_integer(), non_neg_integer()) :: :retry | {:escalate, :attempts_exhausted}
  def decide(count, ceiling) when is_integer(count) and is_integer(ceiling) do
    if count < ceiling, do: :retry, else: {:escalate, :attempts_exhausted}
  end

  @doc """
  The `escalation_reason` an `:attempts_exhausted` escalation records. Built from numbers
  control holds, never from anything a session wrote: entering `escalated` is chained.
  """
  @spec exhausted_reason(non_neg_integer(), non_neg_integer()) :: String.t()
  def exhausted_reason(count, ceiling) do
    "attempts_exhausted: #{count} counted releases (runner_lost + claim_released) " <>
      "reached the retry ceiling of #{ceiling} (DISPATCH_MAX_ATTEMPTS). A human decides " <>
      "whether to spend another attempt."
  end

  defp count_of(attempts, edge) do
    case Map.get(attempts, edge) do
      n when is_integer(n) and n > 0 -> n
      _none -> 0
    end
  end
end
