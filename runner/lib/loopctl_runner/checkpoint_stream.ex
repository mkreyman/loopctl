defmodule LoopctlRunner.CheckpointStream do
  @moduledoc """
  One implement dispatch's `checkpoint` reports (contract 1.20.0): the pushed commits waiting to
  be reported, oldest first, and what a reply to the head means. `Control` owns the pushes and the
  timers; this module owns the decisions, so each refusal's meaning is stated in one place.

  The head stays until it is SETTLED. A lost ack is answered by sending it again — the contract
  replies `ok, replayed: true` to an identical resend even after the claim moved — so a push in
  flight when the channel closes is simply resent after the rejoin.

  What a refusal settles, from the contract's `permanent_errors`:

    * the CLAIM is over (`unknown_dispatch`, `stale_claim_epoch`, `dispatch_not_accepted`,
      `not_claimant`, `claim_not_live`): nothing further on this claim can be recorded, so the
      stream stops and its queue is dropped;
    * THOSE BYTES are refused (`invalid_payload`, `checkpoint_conflict`, `secret_blocked`,
      `audit_chain_append_failed`): resending them cannot change the answer, so that one commit is
      dropped and the next goes;
    * transient (`rate_limited`, `internal_error`, anything unnamed): the head waits and is sent
      again.

  `secret_blocked` names the NOTE, and this runner sends none, so it is not expected here; it is
  still handled by its published meaning rather than assumed away.
  """

  alias LoopctlRunner.Contract

  @claim_over ~w(unknown_dispatch stale_claim_epoch dispatch_not_accepted not_claimant claim_not_live)
  @bytes_refused ~w(invalid_payload checkpoint_conflict secret_blocked audit_chain_append_failed)

  @type t :: %{
          dispatch: map(),
          repo_path: String.t() | nil,
          base: String.t() | nil,
          branch: String.t() | nil,
          seen: MapSet.t(),
          queue: [map()],
          push: reference() | nil,
          timer: {reference(), reference()} | nil,
          retries: non_neg_integer(),
          stopped: boolean(),
          ended: boolean(),
          reader: (String.t(), String.t(), String.t() -> {:ok, [map()]} | {:error, String.t()}),
          read_error: String.t() | nil
        }

  @doc """
  A stream for `dispatch` (its `dispatch_id` and `claim_epoch`), reading `story`'s branch with
  `reader` (`PushedCommits.since/3` in production).
  """
  @spec new(map(), map(), (String.t(), String.t(), String.t() -> term())) :: t()
  def new(dispatch, story, reader) do
    %{
      dispatch: Map.take(dispatch, ["dispatch_id", "claim_epoch", "story_id"]),
      repo_path: story["repo_path"],
      base: story["base"],
      branch: story["branch"],
      seen: MapSet.new(),
      queue: [],
      push: nil,
      timer: nil,
      retries: 0,
      stopped: false,
      ended: false,
      reader: reader,
      read_error: nil
    }
  end

  @doc "Whether the stream knows which branch to read."
  @spec readable?(t()) :: boolean()
  def readable?(stream),
    do: is_binary(stream.repo_path) and is_binary(stream.base) and is_binary(stream.branch)

  @doc """
  Queues every commit not seen before, in the order given. A stopped stream queues nothing: its
  claim is over. Seen is kept for the life of the stream, so a commit is queued once however
  often the branch is read.
  """
  @spec enqueue(t(), [map()]) :: t()
  def enqueue(%{stopped: true} = stream, _commits), do: stream

  def enqueue(stream, commits) do
    fresh = Enum.reject(commits, &MapSet.member?(stream.seen, &1.commit_sha))

    %{
      stream
      | queue: stream.queue ++ fresh,
        seen: Enum.reduce(fresh, stream.seen, &MapSet.put(&2, &1.commit_sha))
    }
  end

  @doc "The head's `RunnerCheckpoint` payload, validated against the contract."
  @spec payload(t()) :: {:ok, map()} | {:error, [String.t()]} | :empty
  def payload(%{queue: []}), do: :empty

  def payload(%{queue: [head | _], dispatch: dispatch}) do
    payload = %{
      "dispatch_id" => dispatch["dispatch_id"],
      "claim_epoch" => dispatch["claim_epoch"],
      "commit_sha" => head.commit_sha,
      "tree_sha" => head.tree_sha
    }

    with :ok <- Contract.validate("RunnerCheckpoint", payload), do: {:ok, payload}
  end

  @doc """
  What a reply to the head means: `:recorded` or `{:dropped, reason}` advance past it, `:stopped`
  ends the stream, and `{:retry, ms}` keeps it at the head. `ms` is nil unless loopctl named one.
  """
  @spec settle(t(), term()) ::
          {:recorded | :stopped | {:dropped, String.t()} | {:retry, pos_integer() | nil}, t()}
  def settle(%{queue: [_ | rest]} = stream, reply) do
    stream = %{stream | push: nil}

    case reason(reply) do
      nil ->
        {:recorded, %{stream | queue: rest, retries: 0}}

      reason when reason in @claim_over ->
        {:stopped, %{stream | queue: [], stopped: true, retries: 0}}

      reason when reason in @bytes_refused ->
        {{:dropped, reason}, %{stream | queue: rest, retries: 0}}

      "rate_limited" ->
        {{:retry, min_interval(reply)}, %{stream | retries: stream.retries + 1}}

      _transient ->
        {{:retry, nil}, %{stream | retries: stream.retries + 1}}
    end
  end

  @doc "Whether the stream has nothing left to do once its run is over."
  @spec done?(t()) :: boolean()
  def done?(stream), do: stream.ended and stream.push == nil and stream.queue == []

  defp reason(:ok), do: nil
  defp reason({:ok, _body}), do: nil
  defp reason({:error, %{"reason" => reason}}) when is_binary(reason), do: reason
  defp reason(_other), do: "unrecognised_reply"

  defp min_interval({:error, %{"min_interval_ms" => ms}}) when is_integer(ms) and ms > 0, do: ms
  defp min_interval(_reply), do: nil
end
