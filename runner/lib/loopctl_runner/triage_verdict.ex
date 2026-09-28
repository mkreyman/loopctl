defmodule LoopctlRunner.TriageVerdict do
  @moduledoc """
  The verdict a triage session states, read from its run directory and judged before it is sent.

  `priv/bin/loop-verdict` stores the session's bytes; everything that decides whether they are a
  verdict is here, because this is where the vendored contract is. Three things are checked, and
  the second and third exist because the contract cannot express them:

    * `RunnerTriageVerdict` itself — shape, enums and every declared bound;
    * the conditional shape its description states in prose: a draft `story` is REQUIRED when
      `outcome` is `story`, and FORBIDDEN otherwise. A verdict that says `story` and carries none
      has moved the work rather than done it; one that attaches a draft to an `escalate` is
      claiming an answer it did not give. JSON Schema's `if`/`then` is outside this validator, so
      the emitter is the only place either can be caught before the wire;
    * the object's size under the contract's own byte rule against `limits.triage_verdict`'s
      `max_bytes`. Field maxima do not imply it: every field at its declared maximum measures
      about 45,000 bytes of 48,000 in BMP characters and roughly twice that in astral ones,
      because the rule charges double for them — and an emoji in a drafted title is ordinary.

  A verdict that fails any of these is the session's mistake, not loopctl's, so it is reported
  as one: the run ends without a verdict and says which check refused it.
  """

  alias LoopctlRunner.{ByteRule, Capability, Contract}

  @definition "RunnerTriageVerdict"
  @verdict_file "verdict.json"
  # Fetched at COMPILE time, and fetched rather than got: `get_in` on a renamed key returns nil,
  # `bytes <= nil` is always true under term ordering, and the one check the contract cannot
  # express would disappear silently. A contract bump that moves this key fails the build.
  @max_bytes Map.fetch!(
               Map.fetch!(Map.fetch!(Contract.connection(), "limits"), "triage_verdict"),
               "max_bytes"
             )

  @type verdict :: %{String.t() => term()}

  @doc """
  Mints this run's verdict token, writes it where `loop-verdict` checks it, and returns it.

  The token goes in the session's PROMPT. A subagent inherits the environment and the session's
  allow-rules, so a built-in agent type dispatched for a fourth reading could otherwise run
  `loop-verdict` — and the verdict is first-write-wins, so it would fix the run's answer. It
  cannot state one it was never given the token for: a subagent is given a task, not the
  session's prompt, and its own tools cannot read the session's argv (no shell it may run, and
  its file tools are scoped to the checkout).

  What this does NOT defend against is another process on the machine: the token is an argv
  element of every `loop-verdict` call and of the `claude` process carrying the prompt, so any
  local user who can read `/proc` can read it. The boundary here is between the session and what
  it dispatches, not between this user and the machine.
  """
  @spec mint_token(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def mint_token(run_dir), do: Capability.mint(run_dir, "verdict.token")

  @doc """
  Mints this run's ESCALATE token, for the same reason and with the same rule.

  `loop-escalate` ends a run with no verdict, so a subagent that could call it could decide the
  run's outcome as surely as one that could state a verdict. A run that mints this requires it;
  an implement run mints none and is unchanged.
  """
  @spec mint_escalate_token(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def mint_escalate_token(run_dir), do: Capability.mint(run_dir, "escalate.token")

  @doc "The file `loop-verdict` writes in a run directory."
  @spec file(String.t()) :: String.t()
  def file(run_dir), do: Path.join(run_dir, @verdict_file)

  @doc """
  Reads the verdict `run_dir` holds, or says why there is none to send.

  `{:error, :none}` is the ordinary end of a run whose session stated nothing.
  """
  @spec read(String.t()) ::
          {:ok, verdict()} | {:error, :none} | {:error, {:invalid | :unreadable, String.t()}}
  def read(run_dir) do
    path = file(run_dir)

    case File.read(path) do
      {:ok, body} ->
        decode(body)

      {:error, :enoent} ->
        {:error, :none}

      {:error, reason} ->
        # Says only that the file would not read, and never why THAT is — deciding whether a
        # session wrote anything needs a look at what is actually at the path, which is
        # `TriageRun.unreadable/2`'s job. This used to say the failure was the runner's problem
        # and not the session's, and therefore not reportable; loopctl asked for the opposite and
        # was right, because an outcome with no wire form leaves the dispatch in flight for ever.
        {:error,
         {:unreadable, "the verdict file could not be read: #{:file.format_error(reason)}"}}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, verdict} when is_map(verdict) -> invalid(validate(verdict))
      {:ok, other} -> {:error, {:invalid, "the verdict is #{type_of(other)}, not a JSON object"}}
      {:error, _} -> {:error, {:invalid, "the verdict is not valid JSON"}}
    end
  end

  defp invalid({:error, reason}) when is_binary(reason), do: {:error, {:invalid, reason}}
  defp invalid(result), do: result

  @doc "Validates a verdict against the contract, its conditional shape and the byte rule."
  @spec validate(verdict()) :: {:ok, verdict()} | {:error, String.t()}
  def validate(verdict) when is_map(verdict) do
    with :ok <- against_contract(verdict),
         :ok <- story_matches_outcome(verdict),
         :ok <- within_byte_rule(verdict) do
      {:ok, verdict}
    end
  end

  defp against_contract(verdict) do
    case Contract.validate(@definition, verdict) do
      :ok ->
        :ok

      {:error, errors} ->
        {:error, "the verdict is not a #{@definition}: " <> Enum.join(errors, "; ")}
    end
  end

  # The contract states this in prose and cannot enforce it; nothing else will catch it before
  # loopctl does.
  defp story_matches_outcome(%{"outcome" => "story"} = verdict) do
    if Map.has_key?(verdict, "story"),
      do: :ok,
      else: {:error, "the verdict says story and carries no draft story"}
  end

  defp story_matches_outcome(%{"outcome" => outcome} = verdict) do
    if Map.has_key?(verdict, "story"),
      do: {:error, "the verdict says #{outcome} and still carries a draft story"},
      else: :ok
  end

  defp story_matches_outcome(_verdict), do: :ok

  defp within_byte_rule(verdict) do
    max = max_bytes()
    bytes = ByteRule.bytes(verdict)

    if bytes <= max,
      do: :ok,
      else: {:error, "the verdict is #{bytes} bytes under the contract's byte rule, over #{max}"}
  end

  @doc "The object cap the contract publishes for a verdict."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Whether an `escalate` verdict gives a person no words: every `escalation_reasons` entry is one of
  the codes the prompt tells a session to spell bare, or there are none at all.

  The contract asks for the opposite in the field's own description — "at least one entry must be
  prose, a bare code is not words a person can act on" — and `escalate` is the outcome that sends
  this to a human, so a verdict carrying only a classification sends them back to the start of the
  reading it just did.

  IT IS NOT ONE OF `validate/1`'s CHECKS, deliberately, and the asymmetry is the whole argument.
  The three there are things loopctl would refuse on the wire, where refusing locally costs the run
  nothing it had. This one loopctl accepts: it records the verdict's `escalation_reasons` verbatim
  (what gates, since 1.15.0, is each lens's own list in `lens_verdicts`), and an `escalate` goes to
  a person either way. Refusing it here would turn a verdict that escalates CORRECTLY — with its
  evidence, its `missing_information`, and a human on the other end — into `verdict_invalid`, which
  is the run reporting that it produced nothing at all. Nor can the session make it good: nothing
  validates a verdict until `loop-verdict` has already linked it into place, a run records one, and
  by the time this is read the session is over. So the prompt REQUIRES a sentence, this says when
  one did not arrive, and the thin verdict still goes: less than was asked for, and far more than
  the alternative.

  Read from `TriagePrompt.reason_codes/0` at call time so there is one list — the codes a session
  is told to spell bare are exactly the strings that are not words.
  """
  @spec bare_escalation?(verdict()) :: boolean()
  def bare_escalation?(%{"outcome" => "escalate"} = verdict) do
    codes = bare_codes()

    verdict
    |> Map.get("escalation_reasons")
    |> List.wrap()
    |> Enum.all?(&(&1 in codes))
  end

  def bare_escalation?(_verdict), do: false

  defp bare_codes do
    %{gating: gating, soft: soft} = LoopctlRunner.TriagePrompt.reason_codes()
    gating ++ soft
  end

  defp type_of(value) when is_list(value), do: "a JSON array"
  defp type_of(value) when is_binary(value), do: "a JSON string"
  defp type_of(value) when is_number(value), do: "a JSON number"
  defp type_of(value) when is_boolean(value), do: "a JSON boolean"
  defp type_of(nil), do: "JSON null"
  defp type_of(_value), do: "not a JSON object"
end
