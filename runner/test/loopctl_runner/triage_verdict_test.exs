defmodule LoopctlRunner.TriageVerdictTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.{Contract, TriageVerdict}
  import LoopctlRunner.TestSupport

  @story %{
    "title" => "Give audit_logs a monotonic seq",
    "description" => "Same-second rows have no defined order.",
    "acceptance_criteria" => ["order is defined for same-second rows"],
    "test_cases" => ["two rows in one second come back in insertion order"],
    "touches" => ["lib/app/audit_log.ex"],
    "domain_reference" => "docs/domain/audit.md"
  }

  defp verdict(overrides \\ %{}),
    do: Map.merge(%{"outcome" => "escalate", "confidence" => "high"}, overrides)

  defp script, do: Path.expand("../../priv/bin/loop-verdict", __DIR__)

  defp state(reason), do: {:error, reason}

  describe "an escalation with no words" do
    @codes LoopctlRunner.TriagePrompt.reason_codes()
    @gating hd(Map.fetch!(@codes, :gating))
    @soft hd(Map.fetch!(@codes, :soft))

    test "an escalate carrying only bare codes, or none at all, gives a person nothing" do
      assert TriageVerdict.bare_escalation?(verdict())
      assert TriageVerdict.bare_escalation?(verdict(%{"escalation_reasons" => []}))
      assert TriageVerdict.bare_escalation?(verdict(%{"escalation_reasons" => [@gating]}))

      # The soft code counts too: it is equally a classification, and the prompt's own rule for it
      # says the sentence naming what was read is a SEPARATE entry beside it.
      assert TriageVerdict.bare_escalation?(verdict(%{"escalation_reasons" => [@soft]}))
      assert TriageVerdict.bare_escalation?(verdict(%{"escalation_reasons" => [@gating, @soft]}))
    end

    test "one sentence beside the codes is enough, and no other outcome is judged" do
      words = "the export has run without the site column since the March migration"

      refute TriageVerdict.bare_escalation?(verdict(%{"escalation_reasons" => [words]}))
      refute TriageVerdict.bare_escalation?(verdict(%{"escalation_reasons" => [@gating, words]}))

      # A reworded code is prose to the loop and prose to a person: it is words, so it counts.
      refute TriageVerdict.bare_escalation?(
               verdict(%{"escalation_reasons" => ["#{@gating} - the form never printed this"]})
             )

      # `story` and `reject` carry the codes too and are not sent to a person to act on, so the
      # requirement is `escalate`'s alone.
      for outcome <- ~w(story reject) do
        refute TriageVerdict.bare_escalation?(%{
                 "outcome" => outcome,
                 "escalation_reasons" => [@gating]
               })
      end
    end

    test "it is NOT a validation failure, because refusing one loses more than it saves" do
      # loopctl records `escalation_reasons` verbatim and routes on `outcome` alone, so a thin
      # escalate still reaches a human with its evidence and missing_information. Refused here it
      # would be `verdict_invalid` instead — the run reporting that it produced nothing — and the
      # session cannot be asked again: `loop-verdict` links the file into place before anything
      # validates it, and a run records one verdict.
      thin = verdict(%{"escalation_reasons" => [@gating]})

      assert TriageVerdict.bare_escalation?(thin)
      assert {:ok, ^thin} = TriageVerdict.validate(thin)
    end
  end

  describe "what a verdict must be" do
    test "a verdict the contract admits passes, with and without its draft story" do
      assert {:ok, _} = TriageVerdict.validate(verdict())

      assert {:ok, _} =
               TriageVerdict.validate(verdict(%{"outcome" => "story", "story" => @story}))
    end

    test "the contract's own bounds and enums are enforced" do
      assert {:error, message} = TriageVerdict.validate(verdict(%{"outcome" => "maybe"}))
      assert message =~ "not a RunnerTriageVerdict"
      assert message =~ "not in"

      long = String.duplicate("e", 400)

      assert {:error, message} =
               TriageVerdict.validate(verdict(%{"escalation_reasons" => [long]}))

      assert message =~ "longer than"
    end

    test "the conditional shape the contract states in prose is enforced here" do
      assert TriageVerdict.validate(verdict(%{"outcome" => "story"})) ==
               state("the verdict says story and carries no draft story")

      assert TriageVerdict.validate(verdict(%{"outcome" => "reject", "story" => @story})) ==
               state("the verdict says reject and still carries a draft story")

      # The validator alone cannot: if/then is outside it, and the contract requires neither.
      assert Contract.validate("RunnerTriageVerdict", verdict(%{"outcome" => "story"})) == :ok
    end

    test "a verdict inside every field bound can still be over the object cap" do
      props = Contract.schema_def("RunnerTriageVerdict")["properties"]
      emoji = <<0x1F600::utf8>>

      # Every bounded field at its declared maximum, written in emoji.
      at_maximum = fn
        %{"items" => items, "maxItems" => max} ->
          List.duplicate(String.duplicate(emoji, items["maxLength"]), max)

        %{"maxLength" => max} ->
          String.duplicate(emoji, max)
      end

      huge =
        verdict(%{
          "outcome" => "story",
          "story" => Map.new(props["story"]["properties"], fn {n, s} -> {n, at_maximum.(s)} end),
          "evidence" => at_maximum.(props["evidence"]),
          "missing_information" => at_maximum.(props["missing_information"]),
          "escalation_reasons" => at_maximum.(props["escalation_reasons"])
        })

      assert Contract.validate("RunnerTriageVerdict", huge) == :ok
      assert {:error, message} = TriageVerdict.validate(huge)
      assert message =~ "under the contract's byte rule, over #{TriageVerdict.max_bytes()}"
    end
  end

  describe "reading what the session wrote" do
    setup do
      {:ok, run_dir: tmp_dir!("verdict")}
    end

    test "no verdict is the ordinary end of a run that stated none", %{run_dir: run_dir} do
      assert TriageVerdict.read(run_dir) == {:error, :none}
    end

    test "a verdict the session wrote is read back and judged", %{run_dir: run_dir} do
      File.write!(TriageVerdict.file(run_dir), Jason.encode!(verdict()))
      assert {:ok, %{"outcome" => "escalate"}} = TriageVerdict.read(run_dir)
    end

    test "bytes that are not a verdict say so, tagged as the SESSION's mistake", %{
      run_dir: run_dir
    } do
      # :invalid is the session's — it wrote something that is not a verdict. A read failure is
      # the runner's, and conflating them would report an operator's failing volume as a bad
      # verdict the session never wrote.
      File.write!(TriageVerdict.file(run_dir), "I think this is a bug, probably")
      assert TriageVerdict.read(run_dir) == {:error, {:invalid, "the verdict is not valid JSON"}}

      File.write!(TriageVerdict.file(run_dir), ~s(["story"]))

      assert TriageVerdict.read(run_dir) ==
               {:error, {:invalid, "the verdict is a JSON array, not a JSON object"}}

      File.write!(TriageVerdict.file(run_dir), ~s({"outcome":"story","confidence":"high"}))
      assert {:error, {:invalid, reason}} = TriageVerdict.read(run_dir)
      assert reason =~ "carries no draft story"
    end

    test "a verdict the runner cannot READ is the runner's problem, not the session's", %{
      run_dir: run_dir
    } do
      path = TriageVerdict.file(run_dir)
      File.write!(path, ~s({"outcome":"escalate","confidence":"high"}))
      File.chmod!(path, 0o000)

      on_exit(fn -> File.chmod(path, 0o600) end)

      assert {:error, {:unreadable, reason}} = TriageVerdict.read(run_dir)
      assert reason =~ "could not be read"
    end
  end

  describe "the command a session states its verdict with" do
    setup do
      {:ok, run_dir: tmp_dir!("loop-verdict")}
    end

    # The script reads stdin, so it is driven through a shell with the input in a file: a
    # session pipes a heredoc into it exactly this way. The file goes in its OWN directory, never
    # beside the run dir and never in the shared system temp: `System.unique_integer/1` is unique
    # within one BEAM, so two concurrent suites — one per worktree, the fleet's normal shape —
    # would pick the same name there, and one would truncate or delete the other's stdin.
    defp run(run_dir, input, args \\ :minted) do
      args =
        case args do
          :minted ->
            {:ok, token} = TriageVerdict.mint_token(run_dir)
            [token]

          given ->
            given
        end

      System.cmd("sh", ["-c", "#{script()} #{Enum.join(args, " ")} < #{write_stdin(input)}"],
        env: [{"LOOP_RUN_DIR", run_dir}],
        stderr_to_stdout: true
      )
    end

    # What the script left behind, beside the token the runner minted for the run.
    defp leftovers(run_dir),
      do: run_dir |> File.ls!() |> Enum.reject(&(&1 == "verdict.token")) |> Enum.sort()

    defp write_stdin(input) do
      path = Path.join(tmp_dir!("stdin"), "stdin")
      File.write!(path, input)
      path
    end

    test "a verdict on stdin is stored whole, and read back", %{run_dir: run_dir} do
      body = Jason.encode!(verdict(%{"outcome" => "story", "story" => @story}))
      assert {out, 0} = run(run_dir, body)
      assert out =~ "Verdict recorded, and not yet validated"
      assert File.read!(TriageVerdict.file(run_dir)) == body
      assert {:ok, %{"outcome" => "story"}} = TriageVerdict.read(run_dir)
    end

    test "a run states one verdict: a second is refused and the first stands", %{run_dir: run_dir} do
      first = Jason.encode!(verdict())
      assert {_, 0} = run(run_dir, first)
      assert {out, 3} = run(run_dir, Jason.encode!(verdict(%{"outcome" => "reject"})))
      assert out =~ "already stated"
      assert File.read!(TriageVerdict.file(run_dir)) == first
    end

    test "an empty verdict records nothing", %{run_dir: run_dir} do
      assert {out, 2} = run(run_dir, "   \n")
      assert out =~ "empty"
      refute File.exists?(TriageVerdict.file(run_dir))
    end

    test "a runaway verdict records nothing rather than filling the disk", %{run_dir: run_dir} do
      assert {out, 2} = run(run_dir, String.duplicate("x", 300_000))
      assert out =~ "over"
      refute File.exists?(TriageVerdict.file(run_dir))
      assert leftovers(run_dir) == []
    end

    test "a runaway verdict of MULTIBYTE characters is refused, not truncated", %{
      run_dir: run_dir
    } do
      # head -c reads bytes; ${#var} counts characters. When the cap was measured in characters,
      # this was stored as the fragment head had cut — mid-character, so not valid UTF-8 — and
      # the session was told it had succeeded.
      assert {out, 2} = run(run_dir, String.duplicate("中", 200_000))
      assert out =~ "over"
      refute File.exists?(TriageVerdict.file(run_dir))
      assert leftovers(run_dir) == []
    end

    test "the claim is atomic: a verdict appearing mid-read does not lose", %{run_dir: run_dir} do
      # The existence check and the write are separated by the whole of stdin, and Claude Code's
      # Bash tool can run two of these at once — so with a plain `mv` both would pass the check
      # and the LAST would win, the opposite of one verdict per run. Driven deterministically: a
      # feeder pauses mid-stdin, and the winning verdict lands inside that pause.
      winner = ~s({"outcome":"story"})

      feeder =
        ~s(printf '%s' '{"outcome":"escalate",'; sleep 1; printf '%s' '"confidence":"high"}')

      {:ok, token} = TriageVerdict.mint_token(run_dir)

      task =
        Task.async(fn ->
          System.cmd("sh", ["-c", "(#{feeder}) | #{script()} #{token}"],
            env: [{"LOOP_RUN_DIR", run_dir}],
            stderr_to_stdout: true
          )
        end)

      Process.sleep(400)
      File.write!(TriageVerdict.file(run_dir), winner)

      assert {out, 3} = Task.await(task, 10_000)
      assert out =~ "already stated"
      assert File.read!(TriageVerdict.file(run_dir)) == winner
      # And the loser left nothing behind.
      assert leftovers(run_dir) == ["verdict.json"]
    end

    test "an over-cap verdict cut at a newline is refused, not stored short", %{run_dir: run_dir} do
      # Command substitution strips trailing newlines, so a cut landing on one measured exactly
      # at the cap: inside it, stored truncated, and the session told it had succeeded.
      # The cut must LAND on the newline: head reads max_bytes + 1 = 262_145 bytes, so the
      # 262_145th byte is the newline command substitution would have stripped.
      over = "{" <> String.duplicate("a", 262_143) <> "\n" <> String.duplicate("x", 100) <> "}"

      assert binary_part(over, 262_144, 1) == "\n"

      assert {out, 2} = run(run_dir, over)
      assert out =~ "over"
      refute File.exists?(TriageVerdict.file(run_dir))
      assert leftovers(run_dir) == []
    end

    test "bytes that are plainly not a verdict are refused, not called recorded", %{
      run_dir: run_dir
    } do
      # The script judges no contract, but it must not report success for something no reading
      # could make a verdict — a session told to stop cannot restate it.
      assert {out, 2} = run(run_dir, "I think this is a bug, probably")
      assert out =~ "not a JSON object"
      refute File.exists?(TriageVerdict.file(run_dir))
      assert leftovers(run_dir) == []
    end

    test "a write that fails for another reason is not called an existing verdict", %{
      run_dir: run_dir
    } do
      # `ln` failing means "a verdict was already stated" ONLY when one is there. Anything else —
      # a filesystem without hard links, a permissions change — is a write failure, and reporting
      # it as a duplicate would stop the session over a verdict that does not exist. A stub `ln`
      # on PATH fails the way such a filesystem does.
      bin = tmp_dir!("no-ln")
      stub = Path.join(bin, "ln")
      File.write!(stub, "#!/bin/sh\necho 'ln: hard links not supported' >&2\nexit 1\n")
      File.chmod!(stub, 0o755)
      stdin = write_stdin(~s({"outcome":"reject"}))
      {:ok, token} = TriageVerdict.mint_token(run_dir)

      {out, code} =
        System.cmd("sh", ["-c", "#{script()} #{token} < #{stdin}"],
          env: [{"LOOP_RUN_DIR", run_dir}, {"PATH", bin <> ":" <> System.get_env("PATH")}],
          stderr_to_stdout: true
        )

      assert code == 1
      assert out =~ "could not be recorded"
      assert out =~ "hard links not supported"
      refute out =~ "already stated"
      refute File.exists?(TriageVerdict.file(run_dir))
    end

    test "a verdict without this run's token is refused, and records nothing", %{run_dir: run_dir} do
      # The session's allow-rule lets any subagent it dispatched run this script, and the verdict
      # is first-write-wins — so without the token a fourth reading could fix the run's answer.
      {:ok, token} = TriageVerdict.mint_token(run_dir)
      body = Jason.encode!(verdict())

      assert {out, 2} = run(run_dir, body, ["wrong-token"])
      assert out =~ "the token from your prompt"
      refute File.exists?(TriageVerdict.file(run_dir))

      assert {out, 2} = run(run_dir, body, [])
      assert out =~ "the token from your prompt"
      refute File.exists?(TriageVerdict.file(run_dir))

      assert {_, 0} = run(run_dir, body, [token])
      assert File.read!(TriageVerdict.file(run_dir)) == body
    end

    test "a run with no token minted records nothing at all", %{run_dir: run_dir} do
      assert {out, 2} = run(run_dir, Jason.encode!(verdict()), ["anything"])
      assert out =~ "no verdict token"
      refute File.exists?(TriageVerdict.file(run_dir))
    end

    test "an escalate token gates the command that ENDS a run, for runs that mint one" do
      # A subagent that could run loop-escalate could decide the run's outcome as surely as one
      # that could state a verdict — on the branch whose outcome is nothing at all.
      run_dir = tmp_dir!("escalate-token")
      escalate = Path.expand("../../priv/bin/loop-escalate", __DIR__)
      {:ok, token} = TriageVerdict.mint_escalate_token(run_dir)
      stdin = write_stdin("the checkout will not read")

      {out, 2} =
        System.cmd("sh", ["-c", "#{escalate} wrong-token < #{stdin}"],
          env: [{"LOOP_RUN_DIR", run_dir}],
          stderr_to_stdout: true
        )

      assert out =~ "the token from your prompt"
      refute File.exists?(Path.join(run_dir, "escalations.ndjson"))

      {_, 0} =
        System.cmd("sh", ["-c", "#{escalate} #{token} < #{stdin}"],
          env: [{"LOOP_RUN_DIR", run_dir}],
          stderr_to_stdout: true
        )

      assert File.read!(Path.join(run_dir, "escalations.ndjson")) =~ "will not read"
    end

    test "a run that mints no escalate token escalates as before", %{run_dir: run_dir} do
      # Every implement run: escalation stays a command any part of that session may call.
      escalate = Path.expand("../../priv/bin/loop-escalate", __DIR__)
      stdin = write_stdin("should voided visits count?")

      {_, 0} =
        System.cmd("sh", ["-c", "#{escalate} < #{stdin}"],
          env: [{"LOOP_RUN_DIR", run_dir}],
          stderr_to_stdout: true
        )

      assert File.read!(Path.join(run_dir, "escalations.ndjson")) =~ "voided visits"
    end

    test "the token file is this user's alone", %{run_dir: run_dir} do
      assert {:ok, token} = TriageVerdict.mint_token(run_dir)
      assert byte_size(token) >= 24
      path = Path.join(run_dir, "verdict.token")
      assert File.read!(path) == token
      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o077) == 0

      # The final mode is the same whichever order the mint uses, so the ORDER is pinned at the
      # source: the window where the file exists at the umask's mode with the token already in it
      # cannot be observed from here without racing the mint.
      source = File.read!("lib/loopctl_runner/triage_verdict.ex")
      touch = :binary.match(source, "File.touch(path)") |> elem(0)
      chmod = :binary.match(source, "File.chmod(path, 0o600)") |> elem(0)
      write = :binary.match(source, "File.write(path, token)") |> elem(0)
      assert touch < chmod and chmod < write, "the token is written before the file is narrowed"

      assert {:ok, escalate} = TriageVerdict.mint_escalate_token(run_dir)
      assert escalate != token
      assert {:ok, %File.Stat{mode: mode}} = File.stat(Path.join(run_dir, "escalate.token"))
      assert Bitwise.band(mode, 0o077) == 0
    end

    test "the script refuses to run outside a loop session" do
      assert {out, code} =
               System.cmd(script(), ["token"],
                 env: [{"LOOP_RUN_DIR", ""}],
                 stderr_to_stdout: true
               )

      assert code != 0
      assert out =~ "only works inside a loop session"
    end
  end
end
