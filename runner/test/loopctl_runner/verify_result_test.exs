defmodule LoopctlRunner.VerifyResultTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.{AgentResult, Contract, VerifyResult}

  @head String.duplicate("ab", 20)
  @other String.duplicate("cd", 20)

  defp schema, do: Contract.connection()["agent_result_schemas"]["verify@1"]

  describe "complete/2" do
    test "a pass becomes verify@1's result at the RUNNER's head, and validates" do
      assert {:ok, result} =
               VerifyResult.complete(%{"verdict" => "pass", "findings" => []}, @head)

      assert result == %{"verdict" => "pass", "findings" => [], "head_sha" => @head}
      assert Contract.validate_against(schema(), result, "verify@1") == :ok
    end

    test "a reject keeps its findings, in order" do
      findings = ["AC-1 is not met: hello is never printed", "no test covers the exit status"]

      assert {:ok, %{"verdict" => "reject", "findings" => ^findings, "head_sha" => @head}} =
               VerifyResult.complete(%{"verdict" => "reject", "findings" => findings}, @head)
    end

    test "absent findings are no findings" do
      assert {:ok, %{"findings" => []}} = VerifyResult.complete(%{"verdict" => "pass"}, @head)
    end

    test "a stated head equal to the checked-out one is admitted" do
      assert {:ok, %{"head_sha" => @head}} =
               VerifyResult.complete(
                 %{"verdict" => "pass", "findings" => [], "head_sha" => @head},
                 @head
               )
    end

    test "a stated head other than the checked-out one is refused" do
      assert {:error, reason} =
               VerifyResult.complete(
                 %{"verdict" => "pass", "findings" => [], "head_sha" => @other},
                 @head
               )

      assert reason =~ "names a head other than the one the runner checked out"
    end

    test "a pass that names findings is refused, never sent as a pass" do
      assert {:error, reason} =
               VerifyResult.complete(%{"verdict" => "pass", "findings" => ["AC-2 fails"]}, @head)

      assert reason =~ "pass but it names findings"
    end

    test "a key beyond verdict, findings and head_sha is refused" do
      assert {:error, reason} =
               VerifyResult.complete(
                 %{"verdict" => "pass", "findings" => [], "confidence" => "high"},
                 @head
               )

      assert reason =~ "1 key(s) besides verdict and findings"
    end
  end

  describe "through AgentResult.parse/3, which is how a run reads it" do
    defp parse(text),
      do: AgentResult.parse(text, {"verify", 1}, complete: &VerifyResult.complete(&1, @head))

    test "a final block is read, completed and validated against the spec" do
      text = "Read lib/app.ex.\n\n```json\n{\"verdict\": \"pass\", \"findings\": []}\n```"
      assert {:ok, %{"verdict" => "pass", "head_sha" => @head}} = parse(text)
    end

    test "every malformed verdict is an error, so none is ever a pass" do
      for text <- [
            "I think it passes.",
            "```json\n{\"verdict\": \"maybe\", \"findings\": []}\n```",
            "```json\n{\"verdict\": \"pass\", \"findings\": [\"x\"]}\n```",
            "```json\n{\"verdict\": \"reject\", \"findings\": [\"   \"]}\n```",
            "```json\n{\"verdict\": \"reject\", \"findings\": \"AC-1 fails\"}\n```",
            "```json\n{\"findings\": []}\n```",
            "```json\n{\"verdict\": \"pass\", \"findings\": [], \"head_sha\": \"#{@other}\"}\n```",
            "```json\n{\"verdict\": \"pass\"\n```"
          ] do
        assert {:error, _} = parse(text), "admitted: #{text}"
      end
    end

    test "a reject whose findings overrun the bounds is clipped to fit, never lost" do
      max_len = AgentResult.verify_max_finding_length()
      max_items = AgentResult.verify_max_findings()
      long = String.duplicate("é", max_len + 40)
      many = Enum.map(1..(max_items + 3), &"finding #{&1}")

      for findings <- [[long], many, [long | many]] do
        block = Jason.encode!(%{"verdict" => "reject", "findings" => findings})

        assert {:ok, %{"verdict" => "reject", "findings" => fitted}} =
                 parse("```json\n#{block}\n```")

        assert length(fitted) <= max_items

        assert Enum.all?(fitted, &(length(String.codepoints(&1)) <= max_len))
        assert Contract.validate_against(schema()["properties"]["findings"], fitted, "f") == :ok
      end
    end

    test "a clipped finding keeps its start and says it was cut" do
      max_len = AgentResult.verify_max_finding_length()
      long = "AC-7: " <> String.duplicate("x", max_len)
      block = Jason.encode!(%{"verdict" => "reject", "findings" => [long, "short"]})

      assert {:ok, %{"findings" => [clipped, "short"]}} = parse("```json\n#{block}\n```")
      assert String.starts_with?(clipped, "AC-7: x")
      assert String.ends_with?(clipped, "…")
      assert length(String.codepoints(clipped)) == max_len
    end

    test "findings past maxItems are dropped, and the last kept one counts them" do
      max_items = AgentResult.verify_max_findings()
      many = Enum.map(1..(max_items + 2), &"finding #{&1}")
      block = Jason.encode!(%{"verdict" => "reject", "findings" => many})

      assert {:ok, %{"findings" => fitted}} = parse("```json\n#{block}\n```")
      assert length(fitted) == max_items
      assert Enum.take(fitted, max_items - 1) == Enum.take(many, max_items - 1)
      assert List.last(fitted) == "finding #{max_items} (2 more finding(s) cut)"
    end

    test "a blank finding is refused even when overlong or past maxItems, never fitted" do
      max_len = AgentResult.verify_max_finding_length()
      max_items = AgentResult.verify_max_findings()
      blank_long = [String.duplicate(" ", max_len + 100)]
      blank_dropped = Enum.map(1..max_items, &"finding #{&1}") ++ ["   ", "finding last"]

      for findings <- [blank_long, blank_dropped] do
        block = Jason.encode!(%{"verdict" => "reject", "findings" => findings})
        assert {:error, _} = parse("```json\n#{block}\n```")
      end
    end

    test "a findings list that fits is sent exactly as stated" do
      findings = ["AC-1 fails", String.duplicate("y", AgentResult.verify_max_finding_length())]
      block = Jason.encode!(%{"verdict" => "reject", "findings" => findings})
      assert {:ok, %{"findings" => ^findings}} = parse("```json\n#{block}\n```")
    end

    test "the bounds are the vendored schema's, never typed in the runner" do
      assert AgentResult.verify_max_findings() == schema()["properties"]["findings"]["maxItems"]

      assert AgentResult.verify_max_finding_length() ==
               schema()["properties"]["findings"]["items"]["maxLength"]
    end
  end
end
