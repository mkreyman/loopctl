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

    test "findings beyond the spec's bounds are refused" do
      many = Enum.map(1..(AgentResult.verify_max_findings() + 1), &"finding #{&1}")
      long = [String.duplicate("x", AgentResult.verify_max_finding_length() + 1)]

      for findings <- [many, long] do
        block = Jason.encode!(%{"verdict" => "reject", "findings" => findings})
        assert {:error, _} = parse("```json\n#{block}\n```")
      end
    end

    test "the bounds are the vendored schema's, never typed in the runner" do
      assert AgentResult.verify_max_findings() == schema()["properties"]["findings"]["maxItems"]

      assert AgentResult.verify_max_finding_length() ==
               schema()["properties"]["findings"]["items"]["maxLength"]
    end
  end
end
