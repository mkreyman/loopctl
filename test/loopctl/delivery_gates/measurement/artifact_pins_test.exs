defmodule Loopctl.DeliveryGates.Measurement.ArtifactPinsTest do
  use ExUnit.Case, async: true

  alias Loopctl.DeliveryGates.Measurement.ArtifactPins

  @moduletag :tmp_dir

  # No tenant: this reads committed files and never the database.

  defp write(dir, name, artifact) do
    File.write!(Path.join(dir, name), Jason.encode!(artifact))
  end

  defp gate_b(overrides \\ %{}) do
    %{
      "gate" => "B",
      "meta" =>
        Map.merge(
          %{
            "head" => "03ad989c711a433812727fdb4bee8d512857fe5d",
            "trigger_fingerprint" => "9e2db568545c",
            "trigger_shape" => %{"effect_patterns" => 7, "human_patterns" => 3},
            "repo" => "acme/repo",
            "generated_at" => "2026-09-14T04:08:37Z"
          },
          overrides
        )
    }
  end

  defp gate_a(overrides \\ %{}) do
    %{
      "gate" => "A",
      "meta" =>
        Map.merge(
          %{
            "corpus" => "acme/repo issues, all states",
            "corpus_fingerprint" => "38065cd323ce",
            "tickets" => 322,
            "generated_at" => "2026-09-14T04:08:37Z"
          },
          overrides
        )
    }
  end

  describe "check/1 accepts what it should" do
    test "an empty directory is not an error", %{tmp_dir: dir} do
      # A repository with no measurements yet is legitimate; failing on it would make the check
      # impossible to introduce.
      assert {:ok, 0} = ArtifactPins.check(dir)
    end

    test "two runs pinned to the same head with the same configuration", %{tmp_dir: dir} do
      write(dir, "gate_b_2026-09-14.json", gate_b())
      write(dir, "gate_b_2026-09-20.json", gate_b(%{"generated_at" => "2026-09-20T01:00:00Z"}))

      assert {:ok, 2} = ArtifactPins.check(dir)
    end

    test "two runs on DIFFERENT heads may differ freely", %{tmp_dir: dir} do
      write(dir, "gate_b_2026-09-14.json", gate_b())

      write(
        dir,
        "gate_b_2026-09-20.json",
        gate_b(%{
          "head" => "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "trigger_fingerprint" => "ffffffffffff",
          "generated_at" => "2026-09-20T01:00:00Z"
        })
      )

      assert {:ok, 2} = ArtifactPins.check(dir)
    end
  end

  describe "check/1 refuses an artifact that cannot be compared" do
    test "a Gate B artifact with no head", %{tmp_dir: dir} do
      write(dir, "gate_b_2026-09-14.json", gate_b(%{"head" => nil}))

      assert {:error, findings} = ArtifactPins.check(dir)
      assert Enum.any?(findings, fn {_where, why} -> why =~ "meta.head" end)
    end

    test "a Gate A artifact with no corpus fingerprint", %{tmp_dir: dir} do
      write(dir, "gate_a_2026-09-14.json", gate_a(%{"corpus_fingerprint" => ""}))

      assert {:error, findings} = ArtifactPins.check(dir)
      assert Enum.any?(findings, fn {_where, why} -> why =~ "meta.corpus_fingerprint" end)
    end

    test "a file that is not valid JSON", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "gate_b_2026-09-14.json"), "{not json")

      assert {:error, [{_path, "is not valid JSON"}]} = ArtifactPins.check(dir)
    end
  end

  describe "check/1 refuses a pair that is not like-for-like" do
    test "same head, different trigger fingerprint", %{tmp_dir: dir} do
      write(dir, "gate_b_2026-09-14.json", gate_b())

      write(
        dir,
        "gate_b_2026-09-20.json",
        gate_b(%{
          "trigger_fingerprint" => "ffffffffffff",
          "generated_at" => "2026-09-20T01:00:00Z"
        })
      )

      assert {:error, findings} = ArtifactPins.check(dir)
      assert Enum.any?(findings, fn {_where, why} -> why =~ "trigger_fingerprint" end)
    end

    test "same head, different trigger shape", %{tmp_dir: dir} do
      write(dir, "gate_b_2026-09-14.json", gate_b())

      write(
        dir,
        "gate_b_2026-09-20.json",
        gate_b(%{
          "trigger_shape" => %{"effect_patterns" => 9, "human_patterns" => 3},
          "generated_at" => "2026-09-20T01:00:00Z"
        })
      )

      assert {:error, findings} = ArtifactPins.check(dir)
      assert Enum.any?(findings, fn {_where, why} -> why =~ "trigger_shape" end)
    end

    test "same corpus fingerprint, different corpus label", %{tmp_dir: dir} do
      write(dir, "gate_a_2026-09-14.json", gate_a())

      write(
        dir,
        "gate_a_2026-09-20.json",
        gate_a(%{"corpus" => "something else", "generated_at" => "2026-09-20T01:00:00Z"})
      )

      assert {:error, findings} = ArtifactPins.check(dir)
      assert Enum.any?(findings, fn {_where, why} -> why =~ "meta.corpus" end)
    end
  end

  describe "check/1 pins the filename convention" do
    test "a filename date that is not the run's UTC date", %{tmp_dir: dir} do
      write(dir, "gate_b_2026-09-13.json", gate_b(%{"generated_at" => "2026-09-14T04:08:37Z"}))

      assert {:error, findings} = ArtifactPins.check(dir)
      assert Enum.any?(findings, fn {_where, why} -> why =~ "is named for 2026-09-13" end)
    end
  end

  describe "the COMMITTED artifacts" do
    @tag tmp_dir: false
    test "carry their pins and agree with each other" do
      # This is the check the Mix task runs, over the real directory, so CI enforces the rule
      # without the task having to be wired into `mix precommit`.
      assert {:ok, count} = ArtifactPins.check("docs/measurements")
      assert count > 0, "no measurement artifacts found — the check would pass vacuously"
    end
  end
end
