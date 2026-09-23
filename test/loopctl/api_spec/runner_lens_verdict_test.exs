defmodule Loopctl.ApiSpec.RunnerLensVerdictTest do
  @moduledoc """
  `lens_verdicts` on the triage verdict message (contract 1.15.0, epic 44 US-44.1): the three
  rules the schema cannot state, and the cap sized so all three at their maxima fit.
  """

  use ExUnit.Case, async: true

  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.ApiSpec.RunnerContract.ByteRule
  alias Loopctl.ApiSpec.RunnerContract.RunnerLensVerdict

  defp lens(name, extra \\ %{}),
    do: Map.merge(%{"lens" => name, "outcome" => "story", "confidence" => "high"}, extra)

  defp message(lens_verdicts, extra \\ %{}) do
    Map.merge(
      %{
        "dispatch_id" => Ecto.UUID.generate(),
        "claim_epoch" => 0,
        "verdict" => %{
          "outcome" => "story",
          "confidence" => "high",
          "story" => %{"title" => "T", "description" => "D", "acceptance_criteria" => ["A"]}
        },
        "lens_verdicts" => lens_verdicts
      },
      extra
    )
  end

  defp three, do: Enum.map(RunnerLensVerdict.lenses(), &lens/1)

  test "three lens verdicts, one per lens, are accepted and kept" do
    assert {:ok, cast} = RunnerContract.cast_triage_verdict_message(message(three()))

    assert cast.lens_verdicts |> Enum.map(& &1.lens) |> Enum.sort() ==
             ~w(analyst architect engineer)
  end

  test "a message without lens verdicts is still accepted (a 1.14.0 runner)" do
    assert {:ok, cast} =
             RunnerContract.cast_triage_verdict_message(Map.delete(message(nil), "lens_verdicts"))

    assert Map.get(cast, :lens_verdicts) == nil
  end

  test "two lens verdicts are refused" do
    assert {:error, {:invalid, errors}} =
             RunnerContract.cast_triage_verdict_message(message(Enum.take(three(), 2)))

    assert "lens_verdicts_must_name_each_lens_once" in errors
  end

  test "a lens named twice is refused" do
    assert {:error, {:invalid, errors}} =
             RunnerContract.cast_triage_verdict_message(
               message([lens("analyst"), lens("analyst"), lens("engineer")])
             )

    assert "lens_verdicts_must_name_each_lens_once" in errors
  end

  test "lens verdicts beside an incomplete report are refused" do
    payload =
      three()
      |> message(%{"incomplete" => "session_crashed"})
      |> Map.delete("verdict")

    assert {:error, {:invalid, errors}} = RunnerContract.cast_triage_verdict_message(payload)
    assert "lens_verdicts_only_beside_a_verdict" in errors
  end

  test "three lens verdicts at every declared maximum fit the cap, and the figure is known" do
    reason = String.duplicate("r", 60)

    at_max =
      Enum.map(RunnerLensVerdict.lenses(), fn name ->
        lens(name, %{
          "outcome" => "escalate",
          "confidence" => "medium",
          "escalation_reasons" => [reason, reason, reason],
          "contradicts" => [
            %{
              "kind" => "story",
              "ref" => String.duplicate("f", 60),
              "why" => String.duplicate("w", 100)
            }
          ]
        })
      end)

    assert {:ok, cast} = RunnerContract.cast_triage_verdict_message(message(at_max))
    bytes = ByteRule.bytes(cast.lens_verdicts)
    assert bytes <= RunnerLensVerdict.max_bytes()
    assert bytes == 8_402
  end

  test "a verdict and its lens verdicts, both at their caps, fit one socket frame" do
    # `max_frame_size: 64_000` on the runner socket (lib/loopctl_web/endpoint.ex:73). The lens
    # cap was sized from what the verdict's cap and the envelope leave of it.
    frame = 64_000

    assert RunnerContract.RunnerTriageVerdict.max_bytes() + RunnerLensVerdict.max_bytes() +
             RunnerContract.frame_envelope_bytes() <= frame
  end
end
