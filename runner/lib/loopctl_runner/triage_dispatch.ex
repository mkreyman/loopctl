defmodule LoopctlRunner.TriageDispatch do
  @moduledoc """
  What an accepted `triage` dispatch becomes on this machine, and the one message its run sends
  back: the triage object read from the dispatch, the `triage_verdict` payload, and how a refusal
  of that payload is read. Pure functions; `LoopctlRunner.Control` performs them, exactly as it
  performs `LoopctlRunner.DispatchRun`'s for an implement dispatch.

  ## The triage object

  The contract's own `RunnerDispatch` validation checks the object's shape, its required fields
  and its bounds, `record_id`'s uuid format included. What is left for here is what the schema
  cannot say: that a `triage` dispatch carries one at all (the property is optional at the
  dispatch level, because an implement dispatch carries `story` instead), and the whole-object
  byte cap. `record_id` is checked a second time because it becomes a PATH — `TriageRun` builds
  the run directory from it, and its own refusal has no wire form.

  Only the keys the contract names survive, as `DispatchRun.story_object/1` does the same: the
  object goes into a prompt, and a field a later contract adds should reach it when this repo
  vendors that contract, not before.

  ## The verdict message

  `RunnerTriageVerdictMessage` carries EXACTLY ONE of `verdict` and `incomplete`, and the schema
  cannot say so: both are optional and both are nullable, so a message with both or with neither
  validates here and is refused `invalid_payload` on the wire — which
  `x-connection.permanent_errors` makes PERMANENT, discarding the only output the run has. The
  rule is therefore the sender's, enforced in `verdict_message/2` and counted over NON-NULL
  values, because 1.9.2 publishes `null` as a member of the `incomplete` enum precisely so that an
  explicit null may sit beside a real verdict. This builder omits the unused field rather than
  sending it as null; the check is what stops a later edit from sending both.

  ## Refusals

  Read from the contract rather than from a list written here: `x-connection.errors.triage_verdict`
  names what can come back, `x-connection.permanent_errors` says which of those never clear — both
  for every event and for this one — and `x-connection.permanent_error_conditions` carries the
  reasons whose permanence has a condition, which is read only where this event does not call the
  reason permanent outright. A refusal this build does not handle by name is neither retried nor
  believed harmless — see `classify/1`.
  """

  alias LoopctlRunner.{ByteRule, Contract, Uuid}

  @message "RunnerTriageVerdictMessage"
  @triage_keys Contract.schema_def("RunnerTriage") |> Map.fetch!("properties") |> Map.keys()

  # Fetched, never `get_in`: a renamed key answers nil, and `bytes <= nil` is true under term
  # ordering, so the one check the schema cannot express would disappear at the next vendoring
  # with nothing failing. `TriageVerdict` guards its own cap the same way and for the same reason.
  @max_bytes Map.fetch!(
               Map.fetch!(Map.fetch!(Contract.connection(), "limits"), "triage"),
               "max_bytes"
             )

  # `|| raise` for the reason `TriageRun` gives for the same cap: `get_in/2` answers nil on a
  # renamed key, and `Enum.take/2` with a nil count raises inside the one path that reports a run
  # the runner itself failed — turning a reportable outcome into a crash at vendor time.
  @max_detail Contract.schema_def(@message)
              |> get_in(["properties", "detail", "maxLength"]) ||
                raise("the vendored contract publishes no maxLength for a triage verdict detail")

  @errors Map.fetch!(Map.fetch!(Contract.connection(), "errors"), "triage_verdict")
  @permanent_errors Map.fetch!(Contract.connection(), "permanent_errors")
  @permanent Map.fetch!(@permanent_errors, "*") ++
               Map.get(@permanent_errors, "triage_verdict", [])
  # A condition is read ONLY for a reason this event does not already call permanent outright, and
  # that subtraction is load-bearing as of 1.11.0: `stale_stage` gained a condition — read the row
  # off the refusal and report from where it says — while `permanent_errors.triage_verdict` names
  # it permanent, and the condition's own prose says why the two agree. A verdict has no row to
  # read: the story has left `detected` and the verdict's first transition can never match again.
  # Ordered the other way, `classify/1` would answer `:conditional` for it, `Control` would ask
  # whether its accept is still outstanding, and a resent verdict — the case where it IS — would
  # be pushed again for the life of the claim at a row nothing will ever move.
  @conditional Map.keys(Map.fetch!(Contract.connection(), "permanent_error_conditions")) --
                 Map.get(@permanent_errors, "triage_verdict", [])

  # The reasons `classify/1` answers for by name.
  @named ~w(rate_limited internal_error) ++ @conditional

  # Every refusal the contract publishes for this event is either named above or permanent. A
  # contract that adds a TRANSIENT reason fails the build here rather than being given up on at
  # runtime by the `:unknown` clause, which is the only handling an unrecognised reason can get:
  # resending on a reason whose meaning this build does not know is a guess, and so is not
  # resending. Naming it at vendor time is the cheap moment to decide.
  unhandled = @errors -- (@named ++ @permanent)

  if unhandled != [] do
    raise "the vendored contract publishes #{Enum.join(unhandled, ", ")} for a triage_verdict, " <>
            "which this module neither handles by name nor knows to be permanent"
  end

  @doc "The refusal reasons the contract publishes for a `triage_verdict`."
  @spec errors() :: [String.t()]
  def errors, do: @errors

  @doc """
  The reasons `classify/1` answers `:conditional` for: published conditions, less what this event
  calls permanent outright.

  Exposed because the CALLER implements each condition, and one caller today implements exactly
  one. A condition it does not know is worse than an unknown refusal: `:conditional` means
  "resend if the caller's own evidence says so", and evidence gathered for a different question
  is a guess wearing a verdict's clothes.
  """
  @spec conditional() :: [String.t()]
  def conditional, do: @conditional

  @doc "The object cap the contract publishes for a triage report."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  The dispatch's triage object: `{:ok, triage}` with only the contract's keys, `:none` when the
  dispatch carries none, or `{:error, detail}` when it is malformed.
  """
  @spec triage_object(map()) :: {:ok, map()} | :none | {:error, String.t()}
  def triage_object(dispatch) do
    case Map.fetch(dispatch, "triage") do
      :error -> :none
      {:ok, nil} -> :none
      {:ok, triage} when is_map(triage) -> validate_triage(triage)
      {:ok, _} -> {:error, "the dispatch triage is not an object"}
    end
  end

  defp validate_triage(triage) do
    with :ok <- record_id(triage["record_id"]),
         :ok <- within_byte_rule(triage) do
      {:ok, Map.take(triage, @triage_keys)}
    end
  end

  defp record_id(id) when is_binary(id) do
    if Uuid.valid?(id),
      do: :ok,
      else: {:error, "the dispatch triage record_id is not a uuid"}
  end

  defp record_id(_id), do: {:error, "the dispatch triage names no record_id"}

  # loopctl escalates an oversize record to a human rather than sending it, so this refuses what
  # should never arrive — which is the runner's standing posture towards a payload from the wire.
  defp within_byte_rule(triage) do
    bytes = ByteRule.bytes(triage)

    if bytes <= @max_bytes,
      do: :ok,
      else:
        {:error,
         "the dispatch triage is #{bytes} bytes under the contract's byte rule, over #{@max_bytes}"}
  end

  @doc """
  The `triage_verdict` message for a run's `LoopctlRunner.TriageRun.outcome/0`, validated against
  the contract and against the exactly-one-of rule the contract states in prose.

  `binding` is the dispatch, or anything carrying its `dispatch_id` and `claim_epoch`.
  """
  @spec verdict_message(map(), LoopctlRunner.TriageRun.outcome()) ::
          {:ok, map()} | {:error, [String.t()]}
  def verdict_message(binding, outcome) do
    %{"dispatch_id" => binding["dispatch_id"], "claim_epoch" => binding["claim_epoch"]}
    |> put_outcome(outcome)
    |> sendable()
  end

  @doc """
  A message read back from disk: `{:ok, payload}` when it is still one this runner may push.

  The same two checks `verdict_message/2` ends with, applied to bytes rather than to an outcome,
  because a message kept for a restart is RESENT as it was built and never rebuilt: loopctl
  answers an identical resend `ok` and refuses a different verdict for the same dispatch
  `already_recorded`, permanently.
  """
  @spec sendable(map()) :: {:ok, map()} | {:error, [String.t()]}
  def sendable(payload) do
    with :ok <- exactly_one(payload),
         :ok <- Contract.validate(@message, payload) do
      {:ok, payload}
    end
  end

  defp put_outcome(payload, {:verdict, verdict}), do: Map.put(payload, "verdict", verdict)

  # The cap is applied HERE, in the shared constructor, and not only by the producers that
  # remember to: a detail one codepoint over is refused `invalid_payload`, which is permanent, so
  # an oversize note about an incomplete run discards the run's whole report and leaves the
  # dispatch in flight. `TriageRun` caps its own (cutting twice costs nothing), and the producer
  # that did not is the one that pays for this: a task killed by a linked process is reported with
  # an exit reason of no fixed size, and `inspect/2`'s `:limit` bounds container elements rather
  # than the length of a binary inside them.
  defp put_outcome(payload, {:incomplete, reason, detail}) do
    payload = Map.put(payload, "incomplete", reason)
    if detail in [nil, ""], do: payload, else: Map.put(payload, "detail", detail(detail))
  end

  # `{:error, _}` is the outcome with no wire form: a run that reached it produced nothing loopctl
  # can be told about, and the dispatch would stay in flight for ever. It is reported as the one
  # thing the runner can say without claiming a session did anything — the same call `TriageRun`
  # makes for a run it could not prepare.
  defp put_outcome(payload, {:error, reason}),
    do: put_outcome(payload, {:incomplete, "no_verdict_written", reason})

  @doc "A reason cut to the message's own `detail` cap, in codepoints as loopctl counts it."
  @spec detail(String.t()) :: String.t()
  def detail(text), do: text |> String.codepoints() |> Enum.take(@max_detail) |> Enum.join()

  @doc """
  Whether a message states exactly one of `verdict` and `incomplete`, which is the rule loopctl
  enforces and the schema cannot.

  Counted over NON-NULL values: an explicit null is how the contract's own emitters say a field
  is not stated, and since 1.9.2 the `incomplete` enum lists null for that reason.
  """
  @spec states_exactly_one?(map()) :: boolean()
  def states_exactly_one?(payload),
    do: Enum.count(["verdict", "incomplete"], &(Map.get(payload, &1) != nil)) == 1

  defp exactly_one(payload) do
    if states_exactly_one?(payload) do
      :ok
    else
      {:error,
       [
         "#{@message}: does not state exactly one of verdict and incomplete, which loopctl " <>
           "refuses invalid_payload, permanently"
       ]}
    end
  end

  @doc """
  How to answer a refusal of a `triage_verdict`, by its `reason`:

    * `:rate_limited` — wait out the contract's refill interval and send the same message again;
    * `:internal_error` — transient on loopctl's side, with no promise that waiting helps: a
      bounded retry, then give up;
    * `:conditional` — permanent unless an accept this runner sent for the dispatch is still
      unacknowledged (`x-connection.permanent_error_conditions`), which only the caller knows. A
      reason `permanent_errors` names for THIS event is never conditional, whatever conditions it
      also carries: `stale_stage` carries one for a `stage` report and none for a verdict;
    * `:permanent` — nothing will change it, so the message is given up;
    * `:unknown` — a reason with no name, or one this build does not know. Given up, because
      resending on a reason whose meaning is unknown is as much a guess as not resending, and the
      log line is what gets it handled at the next vendoring.
  """
  @spec classify(term()) :: :rate_limited | :internal_error | :conditional | :permanent | :unknown
  def classify("rate_limited"), do: :rate_limited
  def classify("internal_error"), do: :internal_error
  def classify(reason) when reason in @conditional, do: :conditional
  def classify(reason) when reason in @permanent, do: :permanent
  def classify(_reason), do: :unknown
end
