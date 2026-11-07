defmodule LoopctlRunner.AgentResult do
  @moduledoc """
  The generic `agent_result` message (contract 1.25.0), which a `:draft` template's run sends
  back instead of a kind-specific event (US-48.9): the result the session stated, read from its
  output, judged against the spec's result schema, and wrapped in `RunnerAgentResultMessage`.
  Pure functions; `LoopctlRunner.TriageRun` reads and records, `LoopctlRunner.Control` pushes.

  ## Where the result comes from

  A draft session is given no command to state a result with (no lenses, no `verdict.json`), so
  its result is the LAST thing it says: its final message ends with
  exactly one fenced ```` ```json ```` block, and that message is the `result` text of the CLI's
  final `result` line in `stdout.ndjson`, which the runner keeps verbatim beside the trace. Exactly
  one block, at the very end: a message that quotes a block from the report it read and then
  states its own carries two, and taking either would be guessing which one the session meant.

  ## The result schema

  loopctl validates `result` against THE SPEC'S schema (`Loopctl.Agents.Specs.ReplyDraftV1`).
  `RunnerAgentResultMessage.result` is an open object, because its shape is the spec's, so the
  contract publishes each spec's schema beside it, in `x-connection.agent_result_schemas`, keyed
  `<id>@<version>` (1.26.0). This module reads them from the vendored copy at compile time, so
  `LoopctlRunner.Contract.validate_against/3` judges a result against loopctl's own schema and a
  result that fails it is never sent. That matters because the failure is permanent: loopctl
  refuses it `invalid_payload`, and nothing is recorded, so the run's only output is lost.

  The length is counted in CODEPOINTS (`Contract`'s rule), while loopctl's cast counts graphemes,
  so a body this side admits is never one loopctl refuses for length.

  ## Refusals

  Read from the contract, as `LoopctlRunner.TriageDispatch` reads its own:
  `x-connection.errors.agent_result` names what can come back, `permanent_errors` which of those
  never clear, and `permanent_error_conditions` the one whose permanence has a condition
  (`dispatch_not_accepted`). `already_recorded` is permanent: loopctl holds a different result
  for this dispatch, and no resend settles a disagreement the session cannot restate.
  """

  alias LoopctlRunner.{ByteRule, Contract}

  @event "agent_result"
  @message "RunnerAgentResultMessage"

  @max_bytes Map.fetch!(
               Map.fetch!(Map.fetch!(Contract.connection(), "limits"), @event),
               "max_bytes"
             )

  # Every spec's result schema as the vendored contract publishes it
  # (`x-connection.agent_result_schemas`, keyed `<id>@<version>`): loopctl's own, never a copy.
  @schemas Map.new(Map.fetch!(Contract.connection(), "agent_result_schemas"), fn {key, schema} ->
             [id, version] = String.split(key, "@")
             {{id, String.to_integer(version)}, schema}
           end)

  @reply_draft_max_body get_in(@schemas, [{"reply_draft", 1}, "properties", "body", "maxLength"])

  unless is_integer(@reply_draft_max_body) do
    raise "the vendored contract publishes no result schema for reply_draft@1"
  end

  # verify@1's bounds (contract 1.28.0), read for its prompt (`LoopctlRunner.VerifyPrompt`) so the
  # session is told the limits loopctl enforces rather than a copy of them.
  @verify_findings get_in(@schemas, [{"verify", 1}, "properties", "findings"])
  @verify_max_findings @verify_findings && @verify_findings["maxItems"]
  @verify_max_finding_length @verify_findings && get_in(@verify_findings, ["items", "maxLength"])

  unless is_integer(@verify_max_findings) and is_integer(@verify_max_finding_length) do
    raise "the vendored contract publishes no findings bounds for verify@1"
  end

  # spec_tuner@1's bounds (contract 1.30.0), read for its prompt (`LoopctlRunner.SpecTunerPrompt`)
  # and its critic (`LoopctlRunner.SpecTune`), never typed there.
  @spec_tuner get_in(@schemas, [{"spec_tuner", 1}, "properties"])
  @spec_tuner_max_new_cases @spec_tuner && get_in(@spec_tuner, ["new_cases", "maxItems"])
  @spec_tuner_max_diff @spec_tuner &&
                         get_in(@spec_tuner, [
                           "proposed_template",
                           "properties",
                           "diff",
                           "maxLength"
                         ])
  @spec_tuner_max_description @spec_tuner &&
                                get_in(@spec_tuner, [
                                  "new_cases",
                                  "items",
                                  "properties",
                                  "description",
                                  "maxLength"
                                ])

  unless is_integer(@spec_tuner_max_new_cases) and is_integer(@spec_tuner_max_diff) and
           is_integer(@spec_tuner_max_description) do
    raise "the vendored contract publishes no new_cases or diff bounds for spec_tuner@1"
  end

  @errors Map.fetch!(Map.fetch!(Contract.connection(), "errors"), @event)
  @permanent Contract.permanent_errors(@event)
  @conditional (Map.keys(Map.fetch!(Contract.connection(), "permanent_error_conditions")) --
                  Contract.event_permanent_errors(@event))
               |> Enum.filter(&(&1 in @errors))

  # The reading of each published condition this event can draw, pinned as `TriageDispatch` pins
  # its own: a vendoring that publishes another one for this event fails the build here.
  #   * dispatch_not_accepted: resend while an accept of ours is still outstanding.
  @readings %{"dispatch_not_accepted" => :conditional}

  unless Enum.sort(@conditional) == Enum.sort(Map.keys(@readings)) do
    raise "the vendored contract publishes conditions for #{inspect(Enum.sort(@conditional))} " <>
            "on an agent_result, and AgentResult reads #{inspect(Enum.sort(Map.keys(@readings)))}"
  end

  @named ~w(rate_limited internal_error) ++ @conditional
  unhandled = @errors -- (@named ++ @permanent)

  if unhandled != [] do
    raise "the vendored contract publishes #{Enum.join(unhandled, ", ")} for an agent_result, " <>
            "which this module neither handles by name nor knows to be permanent"
  end

  @doc "The event this message is pushed as."
  @spec event() :: String.t()
  def event, do: @event

  @doc "The refusal reasons the contract publishes for an `agent_result`."
  @spec errors() :: [String.t()]
  def errors, do: @errors

  @doc "The `result` cap the contract publishes, under the byte rule."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The longest `body` reply_draft@1 admits, in characters."
  @spec reply_draft_max_body() :: pos_integer()
  def reply_draft_max_body, do: @reply_draft_max_body

  @doc "The most findings verify@1 admits."
  @spec verify_max_findings() :: pos_integer()
  def verify_max_findings, do: @verify_max_findings

  @doc "The longest finding verify@1 admits, in characters."
  @spec verify_max_finding_length() :: pos_integer()
  def verify_max_finding_length, do: @verify_max_finding_length

  @doc "The most new eval cases one spec_tuner@1 result may add."
  @spec spec_tuner_max_new_cases() :: pos_integer()
  def spec_tuner_max_new_cases, do: @spec_tuner_max_new_cases

  @doc "The longest proposed template diff spec_tuner@1 admits, in characters."
  @spec spec_tuner_max_diff() :: pos_integer()
  def spec_tuner_max_diff, do: @spec_tuner_max_diff

  @doc "The longest description of a spec_tuner@1 new case, in characters."
  @spec spec_tuner_max_description() :: pos_integer()
  def spec_tuner_max_description, do: @spec_tuner_max_description

  @doc "The result schema mirrored for `{id, version}`, or `:error` for a spec with none here."
  @spec schema({String.t(), pos_integer()}) :: {:ok, map()} | :error
  def schema(key), do: Map.fetch(@schemas, key)

  @doc """
  The `result` the session stated, read from the run directory's `stdout.ndjson`: the `result`
  text of the CLI's LAST `result` line, parsed by `parse/3`. `{:error, reason}` names why there is
  none to send, in the runner's words — never the session's.

  `opts` is `parse/3`'s.
  """
  @spec from_stdout(String.t(), {String.t(), pos_integer()}, keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def from_stdout(run_dir, key, opts \\ []) do
    case File.read(Path.join(run_dir, "stdout.ndjson")) do
      {:ok, raw} ->
        case final_text(raw) do
          {:ok, text} -> parse(text, key, opts)
          :none -> {:error, "the session printed no final result message"}
        end

      {:error, :enoent} ->
        {:error, "the session wrote no output"}

      {:error, reason} ->
        {:error, "the session's output could not be read: #{:file.format_error(reason)}"}
    end
  end

  defp final_text(raw) do
    raw
    |> String.split("\n")
    |> Enum.reduce(:none, fn line, acc ->
      case JSON.decode(line) do
        {:ok, %{"type" => "result", "result" => text}} when is_binary(text) -> {:ok, text}
        {:ok, %{"type" => "result"}} -> :none
        _ -> acc
      end
    end)
  end

  @block ~r/```json[ \t]*\r?\n(.*?)\r?\n[ \t]*```/s

  @doc """
  The result a final message states: its ONE fenced ```` ```json ```` block, which must be the last
  thing in it, decoded and judged against `key`'s result schema (`validate/2`).

  `:complete` (a function of the decoded object) turns what the session stated into the result
  BEFORE it is judged, answering `{:ok, result}` or `{:error, reason}`: verify@1's head is the
  runner's, not the session's (`LoopctlRunner.VerifyResult.complete/2`). Absent, the object is
  the result as stated.
  """
  @spec parse(String.t(), {String.t(), pos_integer()}, keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def parse(text, key, opts \\ []) when is_binary(text) do
    complete = Keyword.get(opts, :complete, &{:ok, &1})

    with {:ok, stated} <- block(text),
         {:ok, result} <- complete.(stated) do
      validate(result, key)
    end
  end

  # The one fenced json block ending `text`, decoded to an object.
  defp block(text) do
    case Regex.scan(@block, text, return: :index) do
      [] ->
        {:error, "the session's final message carries no fenced json result block"}

      [[{start, length}, {body_start, body_length}]] ->
        trailing = binary_part(text, start + length, byte_size(text) - start - length)

        if String.trim(trailing) == "" do
          text |> binary_part(body_start, body_length) |> decode()
        else
          {:error, "the session's json result block is not the end of its final message"}
        end

      blocks ->
        {:error,
         "the session's final message carries #{length(blocks)} fenced json blocks, not one"}
    end
  end

  defp decode(json) do
    case JSON.decode(json) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:ok, _other} -> {:error, "the session's result block is not a JSON object"}
      {:error, _} -> {:error, "the session's result block is not valid JSON"}
    end
  end

  @doc """
  Whether `result` is what `key`'s spec admits: its mirrored schema, and the contract's byte cap
  on `result`. The errors never quote the result — `Contract` keeps a `result` path unshown.
  """
  @spec validate(map(), {String.t(), pos_integer()}) :: {:ok, map()} | {:error, String.t()}
  def validate(result, key) do
    with {:ok, schema} <- known_schema(key),
         :ok <- against(schema, result),
         :ok <- within_byte_rule(result) do
      {:ok, result}
    end
  end

  defp known_schema({id, version} = key) do
    case schema(key) do
      {:ok, schema} -> {:ok, schema}
      :error -> {:error, "this runner holds no result schema for #{id}@#{version}"}
    end
  end

  defp against(schema, result) do
    case Contract.validate_against(schema, result, "result") do
      :ok ->
        :ok

      {:error, errors} ->
        {:error, "the result fails its spec's schema: " <> Enum.join(errors, "; ")}
    end
  end

  defp within_byte_rule(result) do
    bytes = ByteRule.bytes(result)

    if bytes <= @max_bytes,
      do: :ok,
      else: {:error, "the result is #{bytes} bytes under the byte rule, over #{@max_bytes}"}
  end

  @doc """
  The `agent_result` message for `result`, from `binding` (the dispatch, or anything carrying its
  `dispatch_id` and `claim_epoch`) and the template's `{id, version}`, validated before it is
  returned: the envelope against the contract, the result against its spec's schema.
  """
  @spec message(map(), {String.t(), pos_integer()}, map()) ::
          {:ok, map()} | {:error, [String.t()]}
  def message(binding, {id, version}, result) do
    sendable(%{
      "dispatch_id" => binding["dispatch_id"],
      "claim_epoch" => binding["claim_epoch"],
      "spec" => %{"id" => id, "version" => version},
      "result" => result
    })
  end

  @doc """
  A message read back from disk: `{:ok, payload}` when it is still one this runner may push. The
  same checks `message/3` ends with, because a message kept for a restart is resent as it was
  built, never rebuilt.
  """
  @spec sendable(map()) :: {:ok, map()} | {:error, [String.t()]}
  def sendable(payload) do
    with :ok <- Contract.validate(@message, payload),
         :ok <- result_valid(payload) do
      {:ok, payload}
    end
  end

  defp result_valid(%{"spec" => %{"id" => id, "version" => version}, "result" => result}) do
    case validate(result, {id, version}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, [reason]}
    end
  end

  @doc "Whether `payload` is an `agent_result` message rather than a triage verdict."
  @spec message?(map()) :: boolean()
  def message?(payload), do: is_map(payload) and Map.has_key?(payload, "spec")

  @doc """
  How to answer a refusal of an `agent_result`, by its `reason`, in `TriageDispatch.classify/1`'s
  vocabulary: `:rate_limited`, `:internal_error`, `:conditional` (`dispatch_not_accepted`),
  `:permanent` (`already_recorded` among them: never retried) or `:unknown`. There is no
  `:resend_once`: `stale_claim_epoch` is not a refusal this event draws.
  """
  @spec classify(term()) :: :rate_limited | :internal_error | :conditional | :permanent | :unknown
  def classify("rate_limited"), do: :rate_limited
  def classify("internal_error"), do: :internal_error
  def classify(reason) when reason in @conditional, do: :conditional
  def classify(reason) when reason in @permanent, do: :permanent
  def classify(_reason), do: :unknown
end
