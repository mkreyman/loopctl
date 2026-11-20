defmodule LoopctlRunner.AgentResultTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.{AgentResult, Contract}
  import LoopctlRunner.TestSupport

  @key {"reply_draft", 1}
  @binding %{"dispatch_id" => "7d0c1f6e-3b1a-4f7e-9c2d-5a6b7c8d9e0f", "claim_epoch" => 3}

  defp final(json), do: "I read the report and the upload code.\n\n```json\n#{json}\n```\n"

  describe "parse/2: the one fenced json block ending the final message" do
    test "a good body is the result" do
      assert {:ok, %{"body" => "Thanks for the report."}} =
               AgentResult.parse(final(~s({"body": "Thanks for the report."})), @key)
    end

    test "a blank body is refused: the schema's pattern wants a non-space" do
      assert {:error, reason} = AgentResult.parse(final(~s({"body": "   \\n  "})), @key)
      assert reason =~ "fails its spec's schema"
      assert {:error, _} = AgentResult.parse(final(~s({"body": ""})), @key)
    end

    test "a body over 3000 characters is refused, and 3000 exactly is not" do
      max = AgentResult.reply_draft_max_body()
      assert max == 3_000

      over = Jason.encode!(%{"body" => String.duplicate("a", max + 1)})
      assert {:error, reason} = AgentResult.parse(final(over), @key)
      assert reason =~ "longer than #{max}"

      at = Jason.encode!(%{"body" => String.duplicate("a", max)})
      assert {:ok, _} = AgentResult.parse(final(at), @key)
    end

    test "any key beside body is refused" do
      assert {:error, reason} =
               AgentResult.parse(final(~s({"body": "Hi", "send": true})), @key)

      assert reason =~ "send"
    end

    test "no block, two blocks, or text after the block is no result" do
      assert {:error, reason} = AgentResult.parse("Here is my reply: hello.", @key)
      assert reason =~ "no fenced json result block"

      two = final(~s({"body": "quoted"})) <> final(~s({"body": "mine"}))
      assert {:error, reason} = AgentResult.parse(two, @key)
      assert reason =~ "2 fenced json blocks"

      assert {:error, reason} = AgentResult.parse(final(~s({"body": "Hi"})) <> "PS more", @key)
      assert reason =~ "not the end"
    end

    test "a block that is not a JSON object is no result" do
      assert {:error, _} = AgentResult.parse(final("not json"), @key)
      assert {:error, _} = AgentResult.parse(final(~s(["body"])), @key)
    end

    test "a spec this runner holds no schema for is refused, never passed unchecked" do
      assert {:error, reason} = AgentResult.parse(final(~s({"body": "Hi"})), {"other", 1})
      assert reason =~ "no result schema"
    end

    test "errors never quote the session's body" do
      secret = String.duplicate("z", 3_001)
      assert {:error, reason} = AgentResult.parse(final(Jason.encode!(%{"body" => secret})), @key)
      refute reason =~ "zzzz"

      assert {:error, reason} = AgentResult.validate(%{"body" => "   "}, @key)
      refute reason =~ "\"   \""
    end
  end

  describe "from_stdout/2: read from the CLI's final result line" do
    test "the LAST result line's text is the one parsed" do
      dir = tmp_dir!("agent-result")

      lines = [
        Jason.encode!(%{"type" => "system", "subtype" => "init"}),
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "success",
          "result" => final(~s({"body": "first"}))
        }),
        "this line is not json",
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "success",
          "result" => final(~s({"body": "last"}))
        })
      ]

      File.write!(Path.join(dir, "stdout.ndjson"), Enum.join(lines, "\n"))
      assert {:ok, %{"body" => "last"}} = AgentResult.from_stdout(dir, @key)
    end

    test "no output, or a final line with no text, is no result" do
      dir = tmp_dir!("agent-result-none")
      assert {:error, "the session wrote no output"} = AgentResult.from_stdout(dir, @key)

      File.write!(
        Path.join(dir, "stdout.ndjson"),
        Jason.encode!(%{"type" => "result", "subtype" => "error_max_turns"})
      )

      assert {:error, "the session printed no final result message"} =
               AgentResult.from_stdout(dir, @key)
    end
  end

  describe "the agent_result message" do
    test "validates against the vendored RunnerAgentResultMessage and names reply_draft@1" do
      assert {:ok, payload} = AgentResult.message(@binding, @key, %{"body" => "Thanks."})

      assert payload == %{
               "dispatch_id" => @binding["dispatch_id"],
               "claim_epoch" => 3,
               "spec" => %{"id" => "reply_draft", "version" => 1},
               "result" => %{"body" => "Thanks."}
             }

      assert Contract.validate("RunnerAgentResultMessage", payload) == :ok
      assert AgentResult.message?(payload)
      refute AgentResult.message?(%{"dispatch_id" => "x", "verdict" => %{}})
      assert AgentResult.event() in Map.keys(Contract.connection()["events"])
    end

    test "a result failing its spec is never a message, nor is a payload read back from disk" do
      assert {:error, _} = AgentResult.message(@binding, @key, %{"body" => ""})
      assert {:error, _} = AgentResult.message(%{"claim_epoch" => 3}, @key, %{"body" => "Hi"})

      {:ok, payload} = AgentResult.message(@binding, @key, %{"body" => "Hi"})
      assert {:ok, ^payload} = AgentResult.sendable(payload)
      assert {:error, _} = AgentResult.sendable(put_in(payload, ["result", "extra"], 1))
    end
  end

  describe "classify/1, read from the contract" do
    test "already_recorded is permanent and is never retried" do
      assert "already_recorded" in AgentResult.errors()
      assert AgentResult.classify("already_recorded") == :permanent
      assert AgentResult.classify("invalid_payload") == :permanent
      assert AgentResult.classify("unknown_dispatch") == :permanent
    end

    test "rate_limited and internal_error are retried, dispatch_not_accepted is conditional" do
      assert AgentResult.classify("rate_limited") == :rate_limited
      assert AgentResult.classify("internal_error") == :internal_error
      assert AgentResult.classify("dispatch_not_accepted") == :conditional
      assert AgentResult.classify("something_new") == :unknown
      assert AgentResult.classify(nil) == :unknown
    end
  end
end
