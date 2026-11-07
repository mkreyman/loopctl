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
  as one. `loop-verdict` runs these same checks (`check_file/1`) before it records anything, so
  the session hears which one refused it and states the verdict again; only a verdict recorded
  unchecked (the check could not run) can still end the run without one, reported as
  `verdict_invalid` with the check named.

  The same object carries `lens_verdicts`, the three lenses' own judgements that the message sends
  beside the verdict and Gate A reads (contract 1.15.0). They are checked on their own and, unlike
  the verdict, DROPPED rather than refused when they fail: `validate/1` says why.
  """

  alias LoopctlRunner.{ByteRule, Capability, Contract}

  require Logger

  @definition "RunnerTriageVerdict"
  @verdict_file "verdict.json"
  # Fetched at COMPILE time, and fetched rather than got: `get_in` on a renamed key returns nil,
  # `bytes <= nil` is always true under term ordering, and the one check the contract cannot
  # express would disappear silently. A contract bump that moves this key fails the build.
  @max_bytes Map.fetch!(
               Map.fetch!(Map.fetch!(Contract.connection(), "limits"), "triage_verdict"),
               "max_bytes"
             )

  # `lens_verdicts` as the MESSAGE defines it, which is what loopctl validates: the field's own
  # schema, items inline, read from `RunnerTriageVerdictMessage` and fetched so a rename fails the
  # build. The lens names come from the same place.
  @lens_key "lens_verdicts"
  @lens_schema Contract.schema_def("RunnerTriageVerdictMessage")
               |> Map.fetch!("properties")
               |> Map.fetch!(@lens_key)
  @lens_names @lens_schema
              |> Map.fetch!("items")
              |> Map.fetch!("properties")
              |> Map.fetch!("lens")
              |> Map.fetch!("enum")
              |> Enum.sort()

  # THE CAP ON ALL THREE TOGETHER, under the byte rule, which the field maxima do not imply: three
  # lenses at every maxLength are 8402 bytes in ASCII and about twice that in astral characters.
  # Read from the vendored file, never typed: from `limits.lens_verdicts.max_bytes` once a vendoring
  # publishes it there (loopctl 1.24.0), and until then from the field's own description, where
  # 1.15.0 states it ("At most N bytes for all three under the byte rule"). Neither present fails
  # the build, because a missing cap is a set loopctl refuses whole, taking the verdict with it.
  @lens_max_bytes (case get_in(Contract.connection(), ["limits", @lens_key, "max_bytes"]) do
                     max when is_integer(max) ->
                       max

                     nil ->
                       case Regex.run(
                              ~r/At most (\d+) bytes for all three under the byte rule/,
                              Map.fetch!(@lens_schema, "description")
                            ) do
                         [_, digits] ->
                           String.to_integer(digits)

                         nil ->
                           raise "the vendored contract states no byte cap for lens_verdicts"
                       end
                   end)

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

  @doc """
  Judges the verdict at `path` exactly as `read/1` will judge the run's verdict file, so
  `loop-verdict` can refuse one the runner would throw away WHILE the session can still correct
  it.

  Before this, `loop-verdict` linked whatever object it was given and told the session to stop,
  and the first judgement came after the session had ended. One `evidence` string past its
  150-character cap then discarded a whole triage as `verdict_invalid`: on 2026-11-07 that was
  five of five HCB tickets on minis.
  """
  @spec check_file(String.t()) ::
          {:ok, verdict()} | {:error, {:invalid | :unreadable, String.t()}}
  def check_file(path) do
    case File.read(path) do
      {:ok, body} ->
        decode(body)

      {:error, reason} ->
        {:error,
         {:unreadable, "the verdict file could not be read: #{:file.format_error(reason)}"}}
    end
  end

  # The exit status `loop-verdict` reads as "this verdict breaks the contract, record nothing".
  # Any other non-zero status means the check itself did not run, and the script records the
  # verdict unchecked, as it did before, rather than losing a verdict to a broken checker.
  @invalid_status 65

  @doc "The exit status `check_cli/0` gives a verdict that breaks the contract."
  @spec invalid_status() :: pos_integer()
  def invalid_status, do: @invalid_status

  @doc """
  What `check_cli/0` prints and exits with for a `check_file/1` result: `{0, text}` for a valid
  verdict, `{invalid_status(), reason}` for one the runner would refuse, `{1, reason}` when the
  file could not be judged at all.
  """
  @spec cli_result({:ok, verdict()} | {:error, {:invalid | :unreadable, String.t()}}) ::
          {non_neg_integer(), String.t()}
  def cli_result({:ok, _verdict}), do: {0, "the verdict is valid"}
  def cli_result({:error, {:invalid, reason}}), do: {@invalid_status, reason}
  def cli_result({:error, {:unreadable, reason}}), do: {1, reason}

  @doc """
  The entry point `loop-verdict` reaches through the release's `eval`: judges the file named by
  `LOOP_VERDICT_FILE`, prints the judgement and halts with `cli_result/1`'s status. It runs in a
  fresh VM that starts no application; the contract is compiled into `LoopctlRunner.Contract`,
  so nothing here needs the daemon.
  """
  @spec check_cli() :: no_return()
  def check_cli do
    {status, text} =
      case System.get_env("LOOP_VERDICT_FILE") do
        path when is_binary(path) and path != "" -> path |> check_file() |> cli_result()
        _ -> {1, "LOOP_VERDICT_FILE names no file to check"}
      end

    IO.puts(text)
    System.halt(status)
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

  @doc """
  Validates what a session stated: the verdict against the contract, its conditional shape and the
  byte rule, and the `lens_verdicts` stated beside it.

  The session states ONE object: the `RunnerTriageVerdict` fields, plus `lens_verdicts` — the
  three lenses' own judgements, which the message carries BESIDE the verdict (contract 1.15.0) and
  never inside it. They are split here, so every check on the verdict sees the verdict alone, and
  rejoined on the way out for `LoopctlRunner.TriageDispatch` to place in the message.

  LENS VERDICTS THAT FAIL ARE DROPPED, NEVER THE VERDICT. A verdict without them still reaches
  loopctl, which escalates it at triage because Gate A cannot be evaluated — a person sees it,
  with its evidence. Refusing the whole statement instead would turn that into `verdict_invalid`,
  a run that produced nothing whenever the session cannot restate it: out of turns, or with
  `loop-verdict` unable to run its check first and recording the verdict unchecked. A dropped set is logged as an error; a missing one is an error unless the verdict was an
  `escalate` already, which it costs nothing.
  """
  @spec validate(verdict()) :: {:ok, verdict()} | {:error, String.t()}
  def validate(statement) when is_map(statement) do
    {lenses, verdict} = Map.pop(statement, @lens_key)

    with :ok <- against_contract(verdict),
         :ok <- story_matches_outcome(verdict),
         :ok <- within_byte_rule(verdict) do
      {:ok, with_lenses(verdict, lenses)}
    end
  end

  # Missing lens verdicts cost something only when the verdict was NOT already an escalate: Gate A
  # then overturns the session's `story` or `reject`. An escalate loses nothing, and the empty
  # report is told to leave them out, so that case is noted rather than raised as an error.
  defp with_lenses(%{"outcome" => "escalate"} = verdict, nil) do
    Logger.info("this run's escalate verdict carries no lens_verdicts; it escalates as stated")
    verdict
  end

  defp with_lenses(verdict, nil) do
    Logger.error(
      "this run's #{verdict["outcome"]} verdict carries no lens_verdicts; loopctl escalates it " <>
        "at triage because Gate A cannot be evaluated without one judgement per lens"
    )

    verdict
  end

  defp with_lenses(verdict, lenses) do
    case validate_lens_verdicts(lenses) do
      :ok ->
        Map.put(verdict, @lens_key, lenses)

      {:error, reason} ->
        Logger.error(
          "this run's lens_verdicts were dropped and the verdict sent without them, so loopctl " <>
            "escalates it at triage: #{reason}"
        )

        verdict
    end
  end

  @doc """
  Whether `lens_verdicts` is what the message admits: the contract's own schema for the field, and
  the rule its description states in prose and the schema cannot — every lens it names, each
  exactly once.
  """
  @spec validate_lens_verdicts(term()) :: :ok | {:error, String.t()}
  def validate_lens_verdicts(lenses) do
    with :ok <- lenses_against_contract(lenses),
         :ok <- each_lens_once(lenses) do
      lenses_within_byte_rule(lenses)
    end
  end

  defp each_lens_once(lenses) do
    named = lenses |> Enum.map(& &1["lens"]) |> Enum.sort()

    if named == @lens_names,
      do: :ok,
      else:
        {:error,
         "lens_verdicts names #{inspect(named)}; it must name each of " <>
           "#{inspect(@lens_names)} exactly once"}
  end

  defp lenses_within_byte_rule(lenses) do
    bytes = ByteRule.bytes(lenses)

    if bytes <= @lens_max_bytes,
      do: :ok,
      else:
        {:error,
         "lens_verdicts is #{bytes} bytes under the contract's byte rule, over #{@lens_max_bytes}"}
  end

  @doc "The cap the vendored contract states for the three lens verdicts together."
  @spec lens_max_bytes() :: pos_integer()
  def lens_max_bytes, do: @lens_max_bytes

  defp lenses_against_contract(lenses) do
    case Contract.validate_against(@lens_schema, lenses, @lens_key) do
      :ok -> :ok
      {:error, errors} -> {:error, Enum.join(errors, "; ")}
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
  is the run reporting that it produced nothing at all. Nor does `loop-verdict` refuse it: that
  command refuses exactly what `validate/1` refuses (`check_file/1`), and this is deliberately not
  one of those checks, so the session is not asked to restate it. So the prompt REQUIRES a sentence, this says when
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
