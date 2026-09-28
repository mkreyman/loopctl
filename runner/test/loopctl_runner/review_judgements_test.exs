defmodule LoopctlRunner.ReviewJudgementsTest do
  @moduledoc """
  The session's two commands (`priv/bin/loop-finding`, `priv/bin/loop-review-verdict`) and what
  the runner makes of what they record: the composed, numbered messages, written once.
  """

  use ExUnit.Case, async: true

  alias LoopctlRunner.{ReviewJudgements, RunState, Session}
  import LoopctlRunner.TestSupport

  defp finding_script, do: Path.expand("../../priv/bin/loop-finding", __DIR__)
  defp verdict_script, do: Path.expand("../../priv/bin/loop-review-verdict", __DIR__)

  # A run directory as a review run prepares it: its state naming the dispatch and the review, the
  # form, and the token.
  defp run_dir!(round \\ 1) do
    dir = tmp_dir!("review-judgements")
    review = %{"round" => round, "checkpoint_id" => Session.uuid4()}

    RunState.update(dir, %{
      "dispatch_id" => Session.uuid4(),
      "claim_epoch" => 5,
      "kind" => "review",
      "review" => review
    })

    :ok = ReviewJudgements.write_form(dir, review)
    {:ok, token} = ReviewJudgements.mint_token(dir)
    {dir, token}
  end

  # Runs a command with `input` on stdin, as a session's Bash tool would with a heredoc. The
  # environment is the script's own and names no credential.
  defp run(script, dir, args, input) do
    stdin = Path.join(dir, "stdin-#{System.unique_integer([:positive])}")
    File.write!(stdin, input)
    quoted = Enum.map_join(args, " ", &shell_quote/1)

    System.cmd("sh", ["-c", "#{script} #{quoted} < #{shell_quote(stdin)}"],
      env: [{"LOOP_RUN_DIR", dir}, {"LOOP_SESSION_ID", "s-1"}],
      stderr_to_stdout: true
    )
  end

  defp shell_quote(arg), do: "'" <> String.replace(arg, "'", ~S('\'')) <> "'"

  defp recorded(dir), do: ReviewJudgements.read_judgements(dir)

  # The checkpoint under review: the one id a finding's --introduced-by may name.
  defp checkpoint(dir), do: elem(RunState.read(dir), 1)["review"]["checkpoint_id"]

  describe "loop-finding" do
    test "records one finding as stated, with its severity, location and body" do
      {dir, token} = run_dir!()

      assert {out, 0} =
               run(
                 finding_script(),
                 dir,
                 [token, "--severity", "high", "--location", "lib/a.ex:3"],
                 """
                 The retry sends the payment twice when the ack is lost.
                 """
               )

      assert out =~ "Finding recorded"

      assert [
               %{
                 "kind" => "finding",
                 "severity" => "high",
                 "location" => "lib/a.ex:3",
                 "body" => "The retry sends the payment twice when the ack is lost.",
                 "session_id" => "s-1"
               } = line
             ] = recorded(dir)

      refute Map.has_key?(line, "introduced_by")
    end

    test "requires the run's token, and a run with none takes nothing" do
      {dir, token} = run_dir!()
      assert {_, 2} = run(finding_script(), dir, ["wrong", "--severity", "low"], "x\n")
      assert {_, 2} = run(finding_script(), dir, ["--severity", "low"], "x\n")

      File.rm!(Path.join(dir, "review.token"))
      assert {out, 2} = run(finding_script(), dir, [token, "--severity", "low"], "x\n")
      assert out =~ "no review token"
      assert recorded(dir) == []
    end

    test "refuses, recording nothing, what the runner could not send" do
      {dir, token} = run_dir!()

      refusals = [
        {[token], "defect\n", "--severity is required"},
        {[token, "--severity", "blocker"], "defect\n", "--severity must be one of"},
        {[token, "--severity", "low", "--introduced-by", "none"], "defect\n", "round 1"},
        {[token, "--severity", "low"], "   \n\n", "was empty"},
        {[token, "--severity", "low", "--location", ""], "defect\n", "--location was empty"},
        {[token, "--severity", "low", "--severity", "high"], "defect\n", "given twice"},
        {[token, "--severity", "low", "--colour", "red"], "defect\n", "report a finding as"},
        # Under the UTF-8 cap and over what the byte rule leaves for one message.
        {[token, "--severity", "low"], String.duplicate("a", 10_000), "byte rule"},
        # Over the UTF-8 cap the contract's description states.
        {[token, "--severity", "low"], String.duplicate("a", 16_385), "UTF-8 bytes"},
        {[token, "--severity", "low"], <<0xFF, 0xFE, ?x>>, "not UTF-8"}
      ]

      for {args, input, said} <- refusals do
        assert {out, 2} = run(finding_script(), dir, args, input)
        assert out =~ said, "#{inspect(args)}: #{out}"
      end

      assert recorded(dir) == []
    end

    test "after round 1 every finding names this checkpoint as its cause, or none" do
      {dir, token} = run_dir!(2)
      id = checkpoint(dir)

      assert {out, 2} = run(finding_script(), dir, [token, "--severity", "low"], "defect\n")
      assert out =~ "round 2"

      assert {_, 2} =
               run(
                 finding_script(),
                 dir,
                 [token, "--severity", "low", "--introduced-by", "x"],
                 "d\n"
               )

      # A well-formed checkpoint id that is not the one under review names nothing this runner
      # knows, and is refused while the session can still correct it.
      assert {out, 2} =
               run(
                 finding_script(),
                 dir,
                 [token, "--severity", "low", "--introduced-by", Session.uuid4()],
                 "d\n"
               )

      assert out =~ "must be #{id} (this checkpoint) or none"
      assert recorded(dir) == []

      assert {_, 0} =
               run(
                 finding_script(),
                 dir,
                 [token, "--severity", "low", "--introduced-by", id],
                 "d\n"
               )

      assert {_, 0} =
               run(
                 finding_script(),
                 dir,
                 [token, "--severity", "low", "--introduced-by", "none"],
                 "d\n"
               )

      assert Enum.map(recorded(dir), & &1["introduced_by"]) == [id, "none"]
    end

    test "a checkpoint id in capitals is recorded as loopctl spells it, and none lowercase" do
      {dir, token} = run_dir!(2)
      id = checkpoint(dir)

      for given <- [String.upcase(id), "NONE"] do
        assert {_, 0} =
                 run(
                   finding_script(),
                   dir,
                   [token, "--severity", "low", "--introduced-by", given],
                   "d\n"
                 )
      end

      assert Enum.map(recorded(dir), & &1["introduced_by"]) == [id, "none"]

      # And what is recorded is what the runner sends.
      assert {:ok, [{"review_finding", %{"introduced_by" => ^id}}, _]} =
               ReviewJudgements.compose(dir)
    end
  end

  describe "the UTF-8 byte cap" do
    # 5461 three-byte characters and one ASCII: exactly the cap, and well inside the byte rule's
    # budget (a BMP character costs the same whatever its UTF-8 width).
    @at_cap String.duplicate("\u20AC", 5461) <> "a"

    test "is on the body as recorded, after the heredoc's newline is trimmed" do
      {dir, token} = run_dir!()
      assert byte_size(@at_cap) == 16_384

      assert {_, 0} = run(verdict_script(), dir, [token], @at_cap <> "\n")
      assert [%{"body" => @at_cap}] = recorded(dir)
    end

    test "still refuses a body over it" do
      {dir, token} = run_dir!()
      assert {out, 2} = run(verdict_script(), dir, [token], @at_cap <> "b\n")
      assert out =~ "over 16384 UTF-8 bytes"
      assert recorded(dir) == []
    end
  end

  describe "loop-review-verdict" do
    test "records ONE verdict, and nothing is accepted after it" do
      {dir, token} = run_dir!()
      assert {_, 0} = run(finding_script(), dir, [token, "--severity", "medium"], "first\n")

      assert {out, 0} = run(verdict_script(), dir, [token], "One material defect.\n")
      assert out =~ "Stop working now"

      assert {out, 3} = run(verdict_script(), dir, [token], "A second opinion.\n")
      assert out =~ "already stated"

      assert {out, 3} = run(finding_script(), dir, [token, "--severity", "low"], "late\n")
      assert out =~ "nothing is accepted after it"

      assert [%{"kind" => "finding"}, %{"kind" => "verdict", "body" => "One material defect."}] =
               recorded(dir)
    end

    test "takes no flags, and its token" do
      {dir, token} = run_dir!()
      assert {_, 2} = run(verdict_script(), dir, [token, "--severity", "low"], "v\n")
      assert {_, 2} = run(verdict_script(), dir, ["nope"], "v\n")
      assert recorded(dir) == []
    end
  end

  describe "composing what the session stated" do
    test "the commands' records become numbered messages, written once and read back as sent" do
      {dir, token} = run_dir!()
      {:ok, state} = RunState.read(dir)

      assert {_, 0} =
               run(
                 finding_script(),
                 dir,
                 [token, "--severity", "high", "--location", "a.ex:1"],
                 "one\n"
               )

      assert {_, 0} = run(finding_script(), dir, [token, "--severity", "low"], "two\n")
      assert {_, 0} = run(verdict_script(), dir, [token], "done\n")

      assert {:ok, messages} = ReviewJudgements.compose(dir)

      assert [
               {"review_finding",
                %{
                  "client_seq" => 0,
                  "body" => "one",
                  "severity" => "high",
                  "location" => "a.ex:1"
                }},
               {"review_finding", %{"client_seq" => 1, "body" => "two", "severity" => "low"}},
               {"review_verdict", %{"client_seq" => 2, "body" => "done"} = verdict}
             ] = messages

      assert verdict["dispatch_id"] == state["dispatch_id"]
      assert verdict["claim_epoch"] == 5
    end

    test "a composition is written once: a judgement recorded later is never numbered" do
      {dir, token} = run_dir!()
      assert {_, 0} = run(finding_script(), dir, [token, "--severity", "high"], "one\n")

      assert {:ok, [{"review_finding", %{"client_seq" => 0}}] = messages} =
               ReviewJudgements.compose(dir)

      # Stated after the composition — by a session that outlived its run's end, say. A later
      # reader sends the bytes composed first: a number, once given, is never given to other
      # content, and nothing is numbered after it.
      assert {_, 0} = run(finding_script(), dir, [token, "--severity", "low"], "two\n")
      assert length(recorded(dir)) == 2
      assert ReviewJudgements.compose(dir) == {:ok, messages}
    end

    test "what settled is not owed, and the cursor never moves back" do
      {dir, token} = run_dir!()

      for body <- ~w(a b c),
          do: {_, 0} = run(finding_script(), dir, [token, "--severity", "low"], body)

      assert {:ok, [_, _, _]} = ReviewJudgements.outstanding(dir)

      :ok = ReviewJudgements.settle(dir, 2)

      assert {:ok, [{"review_finding", %{"client_seq" => 2, "body" => "c"}}]} =
               ReviewJudgements.outstanding(dir)

      :ok = ReviewJudgements.settle(dir, 1)
      assert ReviewJudgements.settled(dir) == 2
    end

    test "a verdict refused for good is recorded beside the run, for the operator" do
      assert ReviewJudgements.verdict_undelivered(nil, "refused secret_blocked") == :ok

      {dir, _token} = run_dir!()
      :ok = ReviewJudgements.verdict_undelivered(dir, "refused secret_blocked")

      assert {:ok, %{"review_verdict_undelivered" => "refused secret_blocked"}} =
               RunState.read(dir)
    end

    test "a run with no state naming a review has nothing to compose, and composes nothing" do
      dir = tmp_dir!("review-judgements-bare")
      assert {:error, why} = ReviewJudgements.compose(dir)
      assert why =~ "no state naming a review dispatch"
      refute File.exists?(ReviewJudgements.messages_file(dir))
    end
  end
end
