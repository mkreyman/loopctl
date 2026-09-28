defmodule LoopctlRunner.ReviewJudgements do
  @moduledoc """
  A review run's judgements on disk, from what the session stated to what loopctl has settled.
  Everything lives in the run directory, beside the state naming the dispatch:

      judgements.ndjson     what the session stated, one JSON object a line, appended by
                            `priv/bin/loop-finding` and `priv/bin/loop-review-verdict`
      review.form.json      what those commands check a judgement against (`ReviewDispatch.form/1`)
      review.token          the capability both commands require, minted for the session's prompt
      review_messages.json  the messages composed from the judgements, numbered, written ONCE
      state.json            `review_settled`: how many of those loopctl has settled, and
                            `review_verdict_undelivered`: why the verdict never reached
                            loopctl — refused for good, or given up with everything still owed
                            once retrying ran out of time — for the operator

  THE COMPOSED BYTES ARE KEPT, NOT THE MATERIALS TO REBUILD THEM, for the reason
  `LoopctlRunner.PendingVerdicts` keeps a triage verdict's: every message is idempotent on
  `<dispatch_id>:<client_seq>`, a resend of the same content is answered `ok`, and other content
  on a used `client_seq` is `idempotency_key_reused`, permanently. So the numbering is decided once
  — by whoever composes first: the run at its end, or a Control closing a run whose task died, or
  one starting over a run nobody closed — and every later reader sends exactly those bytes. A
  restart can never give a number to different content, because nothing ever numbers twice.

  The cursor only ever moves forward, one settled message at a time (acknowledged, or refused in a
  way no resend can move), so what a restart sends is exactly what is still owed. A refusal that
  can clear settles nothing: `Control` resends that message until it lands, or until its retry
  budget runs out and it settles everything left at once.
  """

  require Logger

  alias LoopctlRunner.{AtomicFile, Capability, ReviewDispatch, RunState}

  @judgements "judgements.ndjson"
  @messages "review_messages.json"
  @form "review.form.json"
  @token "review.token"

  @spec judgements_file(String.t()) :: String.t()
  def judgements_file(run_dir), do: Path.join(run_dir, @judgements)

  @spec messages_file(String.t()) :: String.t()
  def messages_file(run_dir), do: Path.join(run_dir, @messages)

  @spec form_file(String.t()) :: String.t()
  def form_file(run_dir), do: Path.join(run_dir, @form)

  @doc """
  Mints the capability the session's two commands require (`LoopctlRunner.Capability`), as a
  triage run's verdict token is minted: it goes in the session's PROMPT and nowhere else, so a
  subagent the session dispatches cannot state a finding or the verdict — which is
  first-write-wins — in the session's name. It defends against a subagent stating one by
  ACCIDENT, not against a process of this user that reads the run directory: nothing here is a
  sandbox (CLAUDE.md).
  """
  @spec mint_token(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def mint_token(run_dir), do: Capability.mint(run_dir, @token)

  @doc "Writes the form the commands check a judgement against, atomically."
  @spec write_form(String.t(), map()) :: :ok | {:error, term()}
  def write_form(run_dir, binding),
    do: AtomicFile.write(form_file(run_dir), JSON.encode!(ReviewDispatch.form(binding)))

  @doc """
  What the session stated, in order. A line that is not a JSON object is logged and skipped: the
  commands write only objects, so one that is not was written by something else.
  """
  @spec read_judgements(String.t()) :: [map()]
  def read_judgements(run_dir) do
    case File.read(judgements_file(run_dir)) do
      {:ok, raw} ->
        for line <- String.split(raw, "\n", trim: true),
            judgement = decode_line(line, run_dir),
            judgement != nil,
            do: judgement

      {:error, _} ->
        []
    end
  end

  defp decode_line(line, run_dir) do
    case JSON.decode(line) do
      {:ok, %{} = judgement} ->
        judgement

      _ ->
        Logger.error("a line of #{judgements_file(run_dir)} is not a judgement; skipped")
        nil
    end
  end

  @doc """
  The messages this run owes, composed once: read back when a composition is already on disk, or
  composed now from `judgements.ndjson` and `state.json` and written before anything is sent.

  `{:error, why}` only when there is no state naming the dispatch to address them to, or the
  composition cannot be written — then nothing is sent, since sending bytes that are not on disk
  is how a restart would come to number different content.
  """
  @spec compose(String.t()) :: {:ok, [{String.t(), map()}]} | {:error, String.t()}
  def compose(run_dir) do
    case File.read(messages_file(run_dir)) do
      {:ok, raw} -> stored(raw, run_dir)
      {:error, :enoent} -> compose_now(run_dir)
      {:error, reason} -> {:error, "#{messages_file(run_dir)} cannot be read: #{inspect(reason)}"}
    end
  end

  # A stored message that no longer validates is not sent, and not renumbered either: the number
  # it holds is spent, and giving it to the next message would be different content on it.
  defp stored(raw, run_dir) do
    case JSON.decode(raw) do
      {:ok, list} when is_list(list) ->
        messages =
          for %{"event" => event, "payload" => payload} <- list,
              sendable?({event, payload}, run_dir),
              do: {event, payload}

        {:ok, messages}

      _ ->
        {:error, "#{messages_file(run_dir)} is not a list of messages"}
    end
  end

  defp sendable?(message, run_dir) do
    case ReviewDispatch.sendable(message) do
      :ok ->
        true

      {:error, why} ->
        Logger.error("a review message stored in #{run_dir} is not sendable (#{why}); skipped")
        false
    end
  end

  defp compose_now(run_dir) do
    with {:ok, binding} <- review_binding(run_dir) do
      %{messages: messages, skipped: skipped, after_verdict: after_verdict} =
        ReviewDispatch.messages(binding, read_judgements(run_dir))

      for {index, why} <- skipped do
        Logger.error(
          "judgement #{index} of the review run in #{run_dir} is not a message loopctl would " <>
            "take (#{why}); it is not sent",
          dispatch_id: binding["dispatch_id"]
        )
      end

      if after_verdict > 0 do
        Logger.warning(
          "#{after_verdict} judgement(s) recorded after the review's verdict are not sent: a " <>
            "review takes nothing after its verdict",
          dispatch_id: binding["dispatch_id"]
        )
      end

      encoded = JSON.encode!(Enum.map(messages, fn {e, p} -> %{"event" => e, "payload" => p} end))

      case AtomicFile.write(messages_file(run_dir), encoded) do
        :ok ->
          {:ok, messages}

        {:error, reason} ->
          {:error, "the review messages could not be recorded: #{inspect(reason)}"}
      end
    end
  end

  defp review_binding(run_dir) do
    case RunState.read(run_dir) do
      {:ok, %{"dispatch_id" => id, "claim_epoch" => epoch, "review" => %{"round" => round} = r}}
      when is_binary(id) and is_integer(epoch) ->
        {:ok,
         %{
           "dispatch_id" => id,
           "claim_epoch" => epoch,
           "round" => round,
           "checkpoint_id" => r["checkpoint_id"]
         }}

      _ ->
        {:error, "#{run_dir} has no state naming a review dispatch"}
    end
  end

  @doc "How many of this run's messages loopctl has settled."
  @spec settled(String.t()) :: non_neg_integer()
  def settled(run_dir) do
    case RunState.read(run_dir) do
      {:ok, %{"review_settled" => n}} when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  @doc "The messages still owed: composed, less every one numbered below the settled cursor."
  @spec outstanding(String.t()) :: {:ok, [{String.t(), map()}]} | {:error, String.t()}
  def outstanding(run_dir) do
    with {:ok, messages} <- compose(run_dir) do
      settled = settled(run_dir)
      {:ok, Enum.filter(messages, fn {_event, payload} -> payload["client_seq"] >= settled end)}
    end
  end

  @doc """
  Records that every message numbered below `next` is settled. Guarded: a run directory that is
  gone costs only the restart guarantee, which is logged, and never the stream in flight.
  """
  @spec settle(String.t() | nil, non_neg_integer()) :: :ok
  def settle(nil, _next), do: :ok

  def settle(run_dir, next) do
    if next > settled(run_dir), do: RunState.update(run_dir, %{"review_settled" => next})
    :ok
  rescue
    exception ->
      Logger.warning(
        "could not record that #{next} review message(s) of #{run_dir} are settled " <>
          "(#{inspect(exception.__struct__)}); a restart sends them again"
      )

      :ok
  end

  @doc """
  Records that this run's verdict will never reach loopctl — refused for good, or given up — and
  `why`, for the OPERATOR: nothing
  sent to loopctl changes with it, since a review's `session_ended` "only frees the runner's slot".
  Written before the cursor moves past the verdict. Guarded as `settle/2` is.
  """
  @spec verdict_undelivered(String.t() | nil, String.t()) :: :ok
  def verdict_undelivered(nil, _why), do: :ok

  def verdict_undelivered(run_dir, why) do
    RunState.update(run_dir, %{"review_verdict_undelivered" => why})
    :ok
  rescue
    exception ->
      Logger.warning(
        "could not record that the verdict of #{run_dir} was not delivered " <>
          "(#{inspect(exception.__struct__)}); only the log says so"
      )

      :ok
  end
end
