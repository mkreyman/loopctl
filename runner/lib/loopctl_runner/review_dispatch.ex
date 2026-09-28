defmodule LoopctlRunner.ReviewDispatch do
  @moduledoc """
  What an accepted `review` dispatch becomes on this machine, and the messages its run sends back
  (contract 1.21.0; refusals as of 1.22.0): the `review` object read from the dispatch, the `review_finding` and
  `review_verdict` payloads, the form the session's two commands check their input against, and
  how a refusal of either message is read. Pure functions; `LoopctlRunner.Control` performs them,
  as it performs `LoopctlRunner.DispatchRun`'s for an implement dispatch and
  `LoopctlRunner.TriageDispatch`'s for a triage one.

  ## The review object

  The contract's own `RunnerDispatch` validation checks its shape and bounds. What is left for here
  is what the schema cannot say: that a `review` dispatch carries one at all — the property is
  optional at the dispatch level, because the other kinds carry none — and that the commit and
  tree it names are lowercase hex, because both become arguments to git.

  ## The messages

  Every judgement the session states is numbered by the RUNNER (`client_seq`, "the runner's own
  number for this judgement within the dispatch, shared with `review_verdict`"), in the order the
  session stated it, and the verdict is the last one: "ONE per review, sent after every finding.
  It completes the review's round, ends the review — every later judgement is `review_closed`".
  Each is checked here against everything loopctl would refuse it for as `invalid_payload`, which
  is permanent: the schema, the round rule on `introduced_by` ("Absent in round 1 ... REQUIRED
  after it"), the UTF-8 byte caps the descriptions state and the schema's `maxLength` cannot, and
  the whole message under the contract's byte rule.

  ## Refusals

  Read from the contract, and nothing about what a refusal MEANS is written here:
  `x-connection.errors` names what can come back for each event, `x-connection.permanent_errors`
  (`"*"` and the event's own list) which never clear, and `x-connection.claim_ending_errors`
  (1.22.0) which of those end the claim the message ran under:

    * `:claim_ended` — the event's `claim_ending_errors` (`review_closed`, `review_claim_ended`,
      `review_round_superseded`, `reviewer_not_separate`, `unknown_dispatch` and
      `stale_claim_epoch` in 1.22.0): "send that dispatch no more messages of its work ... and stop
      its session", while its `session_ended` still goes;
    * `:stop` — a published CONDITION that ends the run without ending the claim, which is only
      `dispatch_not_accepted`: "permanent unless an accept YOU sent for this dispatch is still
      unacknowledged", which cannot hold here, since a review run starts only once loopctl has
      acknowledged its accept, so the run is over and the stream ends. A vendoring that publishes
      another condition for either event fails the build until it is given its own reading;
    * `:drop` — every OTHER permanent refusal, which "refuses only the message that drew it":
      `secret_blocked`, `idempotency_key_reused`, `invalid_payload`, `audit_chain_append_failed`,
      and 1.22.0's `claim_epoch_mismatch` and `wrong_dispatch_kind`. The next one may well go;
    * `:halted` — `tenant_halted`, which is NOT permanent: "the tenant's custody halt, and clears
      when an operator lifts it". The same bytes are sent again.

  A vendoring that publishes a refusal that is none of these fails the build.
  """

  alias LoopctlRunner.{ByteRule, Contract}

  @events ~w(review_finding review_verdict)
  @finding "RunnerReviewFinding"
  @verdict "RunnerReviewVerdict"

  @hex ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/

  @connection Contract.connection()
  @limits Map.fetch!(@connection, "limits")
  @errors Map.fetch!(@connection, "errors")

  # Fetched, never `get_in`: a renamed key answers nil, and `bytes <= nil` is true under term
  # ordering, so the one check the schema cannot express would disappear at the next vendoring.
  @finding_max_bytes Map.fetch!(Map.fetch!(@limits, "review_finding"), "max_bytes")
  @verdict_max_bytes Map.fetch!(Map.fetch!(@limits, "review_verdict"), "max_bytes")
  @finding_fields Map.fetch!(Map.fetch!(@limits, "review_finding"), "fields")
  @verdict_fields Map.fetch!(Map.fetch!(@limits, "review_verdict"), "fields")

  # The descriptions state these caps in UTF-8 BYTES ("At most 16384 UTF-8 BYTES", "at most 1024
  # UTF-8 bytes"), which the schema's `maxLength` — characters — cannot say; the published limits
  # carry the number.
  @body_max_bytes Map.fetch!(Map.fetch!(@finding_fields, "body"), "max_length")
  @verdict_body_max_bytes Map.fetch!(Map.fetch!(@verdict_fields, "body"), "max_length")
  @location_max_bytes Map.fetch!(Map.fetch!(@finding_fields, "location"), "max_length")

  @severities Contract.schema_def(@finding)
              |> Map.fetch!("properties")
              |> Map.fetch!("severity")
              |> Map.fetch!("enum")

  @per_char get_in(@connection, ["limits", "json_byte_rule", "per_string_char"]) ||
              raise("the vendored contract publishes no per_string_char for its byte rule")

  # What each rate-limited message waits when the refusal names no `min_interval_ms`: its own
  # burst's refill, fetched at COMPILE time and never defaulted, for the reason `Control` gives for
  # the triage verdict's — a default that happens to equal the published number goes stale in
  # silence the day the number moves.
  @retry_ms %{
    "review_finding" =>
      Map.fetch!(Map.fetch!(@limits, "review_finding_burst"), "refill_interval_ms"),
    "review_verdict" =>
      Map.fetch!(Map.fetch!(@limits, "review_verdict_burst"), "refill_interval_ms")
  }

  @claim_ending Map.new(@events, &{&1, Contract.claim_ending_errors(&1)})

  # A condition published for a refusal of the event that neither ends the claim nor is permanent
  # for this event outright. Each one is a READING this module has to implement, and it implements
  # one: dispatch_not_accepted's, which cannot hold for a review (its run starts only once loopctl
  # acknowledged the accept), so the run is over. Derived and then pinned, so a new condition fails
  # the build instead of being read as that one.
  @conditions @connection |> Map.fetch!("permanent_error_conditions") |> Map.keys()

  @stop Map.new(@events, fn event ->
          {event,
           Enum.filter(@conditions, &(&1 in Map.fetch!(@errors, event))) --
             (Map.fetch!(@claim_ending, event) ++ Contract.event_permanent_errors(event))}
        end)

  @halted ~w(tenant_halted)

  @drop Map.new(@events, fn event ->
          permanent = Contract.permanent_errors(event)

          {event,
           Enum.filter(Map.fetch!(@errors, event), &(&1 in permanent)) --
             (Map.fetch!(@claim_ending, event) ++ Map.fetch!(@stop, event))}
        end)

  for event <- @events do
    errors = Map.fetch!(@errors, event)
    permanent = Contract.permanent_errors(event)

    unless Map.fetch!(@stop, event) == ["dispatch_not_accepted"] do
      raise "the vendored contract publishes conditions for " <>
              "#{inspect(Map.fetch!(@stop, event))} on a #{event}, and ReviewDispatch reads only " <>
              "dispatch_not_accepted's; give each new one its own reading before the vendoring lands"
    end

    # Every published refusal is answered: resent (rate_limited, internal_error, a halt) or
    # permanent, which the sets above split by what it ends.
    unhandled = errors -- (~w(rate_limited internal_error) ++ @halted ++ permanent)

    if unhandled != [] do
      raise "the vendored contract publishes #{Enum.join(unhandled, ", ")} for a #{event}, which " <>
              "is neither permanent nor a refusal ReviewDispatch resends"
    end

    # A claim end is only ever a PERMANENT refusal: resending on one the contract calls transient
    # would be the right answer, and giving up the dispatch the wrong one.
    not_permanent = Map.fetch!(@claim_ending, event) -- permanent

    if not_permanent != [] do
      raise "the vendored contract ends the claim on #{Enum.join(not_permanent, ", ")} for a " <>
              "#{event}, and does not call it permanent"
    end

    halted_permanent = Enum.filter(@halted, &(&1 in permanent))

    if halted_permanent != [] do
      raise "ReviewDispatch resends on #{Enum.join(halted_permanent, ", ")}, which the " <>
              "vendored contract now calls permanent"
    end
  end

  @doc "The events a review run sends, besides its `session_ended`."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc "The severities the contract publishes for a finding."
  @spec severities() :: [String.t()]
  def severities, do: @severities

  @doc "The refusal reasons the contract publishes for `event`."
  @spec errors(String.t()) :: [String.t()]
  def errors(event) when event in @events, do: Map.fetch!(@errors, event)

  @doc "What a rate-limited `event` waits when the refusal names no interval: its burst's refill."
  @spec retry_ms(String.t()) :: pos_integer()
  def retry_ms(event) when event in @events, do: Map.fetch!(@retry_ms, event)

  @doc """
  The dispatch's review object: `{:ok, review}` with only the contract's keys, `:none` when the
  dispatch carries none, or `{:error, detail}` when it is malformed.
  """
  @spec review_object(map()) :: {:ok, map()} | :none | {:error, String.t()}
  def review_object(dispatch) do
    case Map.fetch(dispatch, "review") do
      :error -> :none
      {:ok, nil} -> :none
      {:ok, review} when is_map(review) -> validate_review(review)
      {:ok, _} -> {:error, "the dispatch review is not an object"}
    end
  end

  @review_keys Contract.schema_def("RunnerReview") |> Map.fetch!("properties") |> Map.keys()

  defp validate_review(review) do
    with :ok <- Contract.validate("RunnerReview", review),
         :ok <- hex(review["commit_sha"], "commit_sha"),
         :ok <- hex(review["tree_sha"], "tree_sha") do
      {:ok, Map.take(review, @review_keys)}
    else
      {:error, [_ | _] = errors} -> {:error, "the dispatch review: " <> Enum.join(errors, "; ")}
      {:error, detail} -> {:error, detail}
    end
  end

  defp hex(value, field) when is_binary(value) do
    if value =~ @hex,
      do: :ok,
      else: {:error, "the dispatch review #{field} is not a lowercase commit or tree id"}
  end

  defp hex(_value, field), do: {:error, "the dispatch review has no #{field}"}

  @doc """
  The judgements a session stated, in the order it stated them, as the messages this runner
  sends: numbered from 0 in that order, the first verdict last, and everything after it left out
  — a review takes nothing after its verdict. A judgement no message can be made from is left out
  too, and named in `skipped` with why, since `invalid_payload` would discard it permanently
  anyway.

  `binding` carries `dispatch_id`, `claim_epoch` and the review's `round` and `checkpoint_id`.
  """
  @spec messages(map(), [map()]) :: %{
          messages: [{String.t(), map()}],
          skipped: [{non_neg_integer(), String.t()}],
          after_verdict: non_neg_integer()
        }
  def messages(binding, judgements) do
    {before, verdict, rest} = split_at_verdict(judgements)
    stated = if verdict, do: before ++ [verdict], else: before

    {messages, skipped, _next} =
      stated
      |> Enum.with_index()
      |> Enum.reduce({[], [], 0}, fn {judgement, index}, {messages, skipped, next} ->
        case message(binding, judgement, next) do
          {:ok, message} -> {[message | messages], skipped, next + 1}
          {:error, why} -> {messages, [{index, why} | skipped], next}
        end
      end)

    %{
      messages: Enum.reverse(messages),
      skipped: Enum.reverse(skipped),
      after_verdict: length(rest)
    }
  end

  defp split_at_verdict(judgements) do
    case Enum.split_while(judgements, &(Map.get(&1, "kind") != "verdict")) do
      {before, [verdict | rest]} -> {before, verdict, rest}
      {before, []} -> {before, nil, []}
    end
  end

  @doc "One judgement as the message that states it, numbered `client_seq`."
  @spec message(map(), map(), non_neg_integer()) ::
          {:ok, {String.t(), map()}} | {:error, String.t()}
  def message(binding, %{"kind" => "finding"} = judgement, client_seq) do
    payload =
      binding
      |> envelope(client_seq)
      |> Map.merge(%{"body" => judgement["body"], "severity" => judgement["severity"]})
      |> put_present("location", judgement["location"])
      |> put_present("introduced_by", judgement["introduced_by"])

    with :ok <- round_rule(binding["round"], payload),
         :ok <- introduced_by(payload["introduced_by"], binding["checkpoint_id"]),
         :ok <- utf8_cap(payload["body"], @body_max_bytes, "body"),
         :ok <- utf8_cap(payload["location"], @location_max_bytes, "location"),
         :ok <- valid(@finding, payload, @finding_max_bytes) do
      {:ok, {"review_finding", payload}}
    end
  end

  def message(binding, %{"kind" => "verdict"} = judgement, client_seq) do
    payload = binding |> envelope(client_seq) |> Map.put("body", judgement["body"])

    with :ok <- utf8_cap(payload["body"], @verdict_body_max_bytes, "body"),
         :ok <- valid(@verdict, payload, @verdict_max_bytes) do
      {:ok, {"review_verdict", payload}}
    end
  end

  def message(_binding, _judgement, _client_seq), do: {:error, "not a finding or a verdict"}

  defp envelope(binding, client_seq),
    do: %{
      "dispatch_id" => binding["dispatch_id"],
      "claim_epoch" => binding["claim_epoch"],
      "client_seq" => client_seq
    }

  defp put_present(payload, _key, nil), do: payload
  defp put_present(payload, key, value), do: Map.put(payload, key, value)

  defp round_rule(1, %{"introduced_by" => _}),
    do: {:error, "introduced_by is not allowed in round 1"}

  defp round_rule(round, payload) when is_integer(round) and round > 1 do
    if Map.has_key?(payload, "introduced_by"),
      do: :ok,
      else: {:error, "introduced_by is required after round 1"}
  end

  defp round_rule(_round, _payload), do: :ok

  # The description's own words: "the id of a checkpoint of this story at or before the one being
  # read, or `none`". This runner knows ONE checkpoint id — the one under review — so that is the
  # only id a finding may name (a defect this checkpoint's fix introduced), recorded exactly as
  # loopctl gave it (`loop-review-record`); anything else names no checkpoint this runner can vouch
  # for, and is not sent.
  defp introduced_by(nil, _checkpoint), do: :ok
  defp introduced_by("none", _checkpoint), do: :ok
  defp introduced_by(checkpoint, checkpoint) when is_binary(checkpoint), do: :ok

  defp introduced_by(value, _checkpoint),
    do: {:error, "introduced_by #{inspect(value)} is neither this review's checkpoint nor none"}

  defp utf8_cap(nil, _max, _field), do: :ok

  defp utf8_cap(value, max, field) when is_binary(value) do
    if byte_size(value) <= max,
      do: :ok,
      else: {:error, "#{field} is #{byte_size(value)} UTF-8 bytes, over #{max}"}
  end

  defp utf8_cap(_value, _max, field), do: {:error, "#{field} is not a string"}

  defp valid(definition, payload, max_bytes) do
    with :ok <- contract(definition, payload) do
      bytes = ByteRule.bytes(payload)

      if bytes <= max_bytes,
        do: :ok,
        else:
          {:error,
           "the message is #{bytes} bytes under the contract's byte rule, over #{max_bytes}"}
    end
  end

  defp contract(definition, payload) do
    case Contract.validate(definition, payload) do
      :ok -> :ok
      {:error, errors} -> {:error, "not a #{definition}: " <> Enum.join(errors, "; ")}
    end
  end

  @doc """
  A message read back from disk, `{event, payload}`: whether it is still one this runner may send.
  The bytes are resent as they were composed and never rebuilt — loopctl answers a resend of the
  same content `ok` and refuses other content on a used `client_seq` `idempotency_key_reused` —
  so this only checks them.
  """
  @spec sendable({String.t(), map()}) :: :ok | {:error, String.t()}
  def sendable({"review_finding", payload}) when is_map(payload),
    do: valid(@finding, payload, @finding_max_bytes)

  def sendable({"review_verdict", payload}) when is_map(payload),
    do: valid(@verdict, payload, @verdict_max_bytes)

  def sendable(_message), do: {:error, "not a review message"}

  @doc """
  The form the session's commands (`priv/bin/loop-finding`, `priv/bin/loop-review-verdict`) check
  a judgement against BEFORE recording it, so the session is refused while it can still correct
  itself: a judgement this runner would refuse after the session has ended is a defect nobody is
  told about.

  Every number is the contract's, handed to the scripts rather than typed into them. The two
  `*_budget` figures are what the byte rule leaves for the text the session writes: the message's
  cap less the size of the message with every text field empty and every other field at its
  widest, so a script needs only `per_char` times the text's UTF-16 units to decide. The
  `checkpoint_id` under review is the one checkpoint a finding's `--introduced-by` may name.
  """
  @spec form(map()) :: map()
  def form(binding) do
    %{
      "round" => binding["round"],
      "checkpoint_id" => binding["checkpoint_id"],
      "severities" => @severities,
      "body_max_bytes" => @body_max_bytes,
      "verdict_body_max_bytes" => @verdict_body_max_bytes,
      "location_max_bytes" => @location_max_bytes,
      "per_char" => @per_char,
      "finding_budget" => finding_budget(),
      "verdict_budget" => verdict_budget()
    }
  end

  # The widest a message's fixed part can be: a uuid, numbers (the byte rule charges every number
  # the same), the longest severity, and every optional text field present and empty.
  @widest_uuid String.duplicate("f", 36)

  defp finding_budget do
    empty = %{
      "dispatch_id" => @widest_uuid,
      "claim_epoch" => 0,
      "client_seq" => 0,
      "severity" => Enum.max_by(@severities, &String.length/1),
      "body" => "",
      "location" => "",
      "introduced_by" => ""
    }

    @finding_max_bytes - ByteRule.bytes(empty)
  end

  defp verdict_budget do
    empty = %{"dispatch_id" => @widest_uuid, "claim_epoch" => 0, "client_seq" => 0, "body" => ""}
    @verdict_max_bytes - ByteRule.bytes(empty)
  end

  @doc """
  How to answer a refusal of `event` by its `reason` (see the moduledoc): `:rate_limited`,
  `:internal_error`, `:halted`, `:claim_ended`, `:stop`, `:drop`, or `:unknown` for a reason this
  build does not know. `Control` resends an `:unknown` like an `:internal_error` rather than
  dropping it: a dropped finding is a round the verdict completes without it, and a resend of the
  same bytes is safe, since each judgement is idempotent on `<dispatch_id>:<client_seq>`.
  """
  @spec classify(String.t(), term()) ::
          :rate_limited | :internal_error | :halted | :claim_ended | :stop | :drop | :unknown
  def classify(event, reason) when event in @events do
    cond do
      reason == "rate_limited" -> :rate_limited
      reason == "internal_error" -> :internal_error
      reason in @halted -> :halted
      reason in Map.fetch!(@claim_ending, event) -> :claim_ended
      reason in Map.fetch!(@stop, event) -> :stop
      reason in Map.fetch!(@drop, event) -> :drop
      true -> :unknown
    end
  end
end
