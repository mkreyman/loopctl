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

  alias LoopctlRunner.{ByteRule, Contract}

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

  @doc "The file `loop-verdict` writes in a run directory."
  @spec file(String.t()) :: String.t()
  def file(run_dir), do: Path.join(run_dir, @verdict_file)

  @doc """
  Reads the verdict `run_dir` holds, or says why there is none to send.

  `{:error, :none}` is the ordinary end of a run whose session stated nothing.
  """
  @spec read(String.t()) :: {:ok, verdict()} | {:error, :none} | {:error, String.t()}
  def read(run_dir) do
    path = file(run_dir)

    case File.read(path) do
      {:ok, body} ->
        decode(body)

      {:error, :enoent} ->
        {:error, :none}

      {:error, reason} ->
        {:error, "the verdict file could not be read: #{:file.format_error(reason)}"}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, verdict} when is_map(verdict) -> validate(verdict)
      {:ok, other} -> {:error, "the verdict is #{type_of(other)}, not a JSON object"}
      {:error, _} -> {:error, "the verdict is not valid JSON"}
    end
  end

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

  defp type_of(value) when is_list(value), do: "a JSON array"
  defp type_of(value) when is_binary(value), do: "a JSON string"
  defp type_of(value) when is_number(value), do: "a JSON number"
  defp type_of(value) when is_boolean(value), do: "a JSON boolean"
  defp type_of(nil), do: "JSON null"
  defp type_of(_value), do: "not a JSON object"
end
