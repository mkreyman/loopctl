defmodule Loopctl.DeliveryGates.Measurement.EvalReplayTest do
  @moduledoc """
  US-48.10, AC-48.10.3 / TC-48.10.3: a recorded eval result is replayed through loopctl's own
  screens, and the screens it names are the ones the LIVE path produces for the same message.

  Two halves:

  - **Every committed result replays to its `expected.screens`.** Each file under
    `test/fixtures/eval_results/<spec>@<version>/` is cast through `RunnerContract` exactly as
    the runner channel casts it, then screened; the screens must equal the file's own
    expectation, order-insensitive. The sweep is guarded against going vacuous: it must find
    a file for each spec and at least one non-empty expectation.
  - **Replay and live agree.** Each result's message is sent through the live ingest path —
    the channel's own cast, then `TriageVerdict.apply/4` or `AgentResult.apply/4`, which is
    all the channel's handler does past its rate bucket — against real rows, and what that
    path RECORDED (the triage step's `gate_screen` codes, the escalation reason, the flagged
    signals, the `reply_drafts` row) is compared with the replay's answer.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.Agents.AgentResult
  alias Loopctl.Agents.Specs.ReplyDraftV1
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.TriageVerdict
  alias Loopctl.DeliveryGates.Measurement.EvalReplay
  alias Loopctl.ReplyDrafts.ReplyDraft
  alias Loopctl.Repo

  setup :verify_on_exit!

  @root Path.expand("../../../fixtures/eval_results", __DIR__)
  @epoch 4

  defp results do
    @root
    |> Path.join("*/*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      {:ok, result} = EvalReplay.load(path)
      {path, result}
    end)
  end

  defp results_for(spec_id),
    do: Enum.filter(results(), fn {_path, r} -> r["spec"]["id"] == spec_id end)

  describe "TC-48.10.3: every recorded result replays to its expected screens" do
    test "the sweep is not vacuous" do
      all = results()

      assert results_for("triage") != [], "no triage@1 result under #{@root}"
      assert results_for("reply_draft") != [], "no reply_draft@1 result under #{@root}"

      assert Enum.any?(all, fn {_path, r} -> r["expected"]["screens"] != [] end),
             "every expectation is empty, so a replay that screens nothing would pass"

      assert Enum.any?(all, fn {_path, r} -> r["expected"]["screens"] == [] end),
             "no clean case, so a replay that refuses everything would pass"
    end

    test "each file's message is admitted by the contract and screens to expected.screens" do
      for {path, result} <- results() do
        assert {:ok, replay} = EvalReplay.replay(result), "#{path} did not replay"

        assert Enum.sort(replay.screens) == Enum.sort(result["expected"]["screens"]),
               "#{Path.relative_to(path, @root)}: replayed #{inspect(replay.screens)}, " <>
                 "expected #{inspect(result["expected"]["screens"])}"
      end
    end

    test "a screen that refuses names its codes, and a clean one names none" do
      for {_path, result} <- results() do
        {:ok, replay} = EvalReplay.replay(result)

        assert Enum.sort(Map.keys(replay.codes)) == Enum.sort(replay.screens)
        assert Enum.all?(replay.codes, fn {_screen, codes} -> codes != [] end)
      end
    end
  end

  describe "the result file itself" do
    setup do
      {:ok, result} = EvalReplay.load(Path.join(@root, "triage@1/clean_story.json"))
      %{result: result}
    end

    test "a message the contract refuses is refused, not screened", %{result: result} do
      broken = put_in(result, ["message", "verdict", "outcome"], "ship_it")
      assert {:error, {:message_refused, _}} = EvalReplay.replay(broken)
    end

    test "an unknown format, spec, or an event the spec does not answer with is refused",
         %{result: result} do
      assert {:error, {:unknown_format, 2}} = EvalReplay.replay(%{result | "format" => 2})

      assert {:error, :unknown_spec} =
               EvalReplay.replay(%{result | "spec" => %{"id" => "triage", "version" => 9}})

      assert {:error, {:event_not_answered_by_spec, "agent_result"}} =
               EvalReplay.replay(%{result | "event" => "agent_result"})
    end

    test "a run that produced no message produced no screens", %{result: result} do
      assert {:ok, %{screens: [], codes: codes}} =
               EvalReplay.replay(%{result | "message" => nil})

      assert codes == %{}
    end

    test "implement@1's session_ended is not replayed: its screens run at dispatch", %{
      result: result
    } do
      implement = %{result | "spec" => %{"id" => "implement", "version" => 1}}

      assert {:error, {:no_result_screens, "implement@1"}} =
               EvalReplay.replay(%{implement | "event" => "session_ended"})

      # Not answered `[]` for a run with no message either: that would read as "screened, clean".
      assert {:error, {:no_result_screens, "implement@1"}} =
               EvalReplay.replay(%{implement | "event" => "session_ended", "message" => nil})
    end

    test "a reply_draft result its spec's schema refuses is refused, not screened" do
      {:ok, result} = EvalReplay.load(Path.join(@root, "reply_draft@1/clean_reply.json"))

      for body <- ["", "   ", String.duplicate("a", ReplyDraftV1.max_body_length() + 1)] do
        broken = put_in(result, ["message", "result", "body"], body)
        assert {:error, {:message_refused, {:invalid, [_ | _]}}} = EvalReplay.replay(broken)
      end

      # A message naming another spec than the file is filed under is not screened as either.
      other = put_in(result, ["message", "spec", "id"], "summary_draft")
      assert {:error, {:spec_mismatch, "summary_draft@1"}} = EvalReplay.replay(other)
    end

    test "an unreadable file is refused", %{result: _result} do
      assert {:error, {:unreadable, :enoent}} = EvalReplay.load(Path.join(@root, "nope.json"))
    end

    test "gate_b reads the dispatch's repository: one loopctl does not configure escalates",
         %{result: result} do
      elsewhere = put_in(result, ["input", "repo"], "acme/unconfigured")

      assert {:ok, %{screens: ["gate_b"], codes: %{"gate_b" => ["unknown_repo"]}}} =
               EvalReplay.replay(elsewhere)

      assert {:ok, %{screens: ["gate_b"], codes: %{"gate_b" => [code]}}} =
               EvalReplay.replay(%{result | "input" => Map.delete(result["input"], "repo")})

      assert code == "repository_unresolved:repo_not_in_input"
    end

    test "a malformed file is refused" do
      assert {:error, :not_a_result} = EvalReplay.replay(%{"format" => 1})
    end
  end

  describe "replay and the live path agree" do
    test "triage@1: every result, applied live, records what the replay screens" do
      for {path, result} <- results_for("triage") do
        {:ok, replay} = EvalReplay.replay(result)
        live = apply_triage_live(result)
        name = Path.relative_to(path, @root)

        # The triage step's own record of the verdict screens: absent exactly when none refused.
        assert live.gate_screen == gate_codes(replay), "#{name}: gate screen codes differ"

        # The draft screens, read off the route the live path took.
        assert live.draft_screen == draft_screen(replay), "#{name}: draft screen differs"

        if live.draft_screen == "draft_injection",
          do: assert(live.flagged == replay.codes["draft_injection"], "#{name}: signals differ")

        # A story verdict nothing refused is the one that queues.
        queues? = get_in(result, ["message", "verdict", "outcome"]) == "story"
        assert live.stage == if(queues? and replay.screens == [], do: :queued, else: :escalated)
      end
    end

    test "reply_draft@1: every result, applied live, stores what the replay screens" do
      for {path, result} <- results_for("reply_draft") do
        {:ok, replay} = EvalReplay.replay(result)
        draft = apply_reply_live(result)
        name = Path.relative_to(path, @root)

        case replay.screens do
          [] ->
            assert draft.status == :drafted, "#{name}: replay clean, live refused"
            assert draft.screen_code == nil

          ["injection_detector_draft"] ->
            assert draft.status == :refused, "#{name}: replay refused, live drafted"
            assert draft.screen_code == "injection_detector_draft"
            assert draft.screen_signals == replay.codes["injection_detector_draft"]
        end
      end
    end
  end

  # -- the live path ---------------------------------------------------------------------

  # The rows a triage verdict lands on, as `Loopctl.Delivery.TriageVerdictTest` builds them:
  # the project's one live source is `acme/widgets`, the repository the fixtures' dispatch
  # names and config/test.exs's trigger document configures.
  defp apply_triage_live(result) do
    story = fixture(:stage_story, %{claim_epoch: @epoch, agent_status: :implementing})
    runner = fixture(:stage_runner, %{tenant_id: story.tenant_id})

    fixture(:intake_record, %{
      tenant_id: story.tenant_id,
      project_id: story.project_id,
      repo_full_name: result["input"]["repo"]
    })

    fixture(:story_stage, %{
      tenant_id: story.tenant_id,
      story_id: story.id,
      stage: :detected,
      claim_epoch: @epoch
    })

    record =
      fixture(:accepted_dispatch, %{
        tenant_id: story.tenant_id,
        runner: runner,
        story_id: story.id,
        claim_epoch: @epoch,
        kind: "triage"
      })

    # THE CHANNEL'S PATH: the same cast `RunnerChannel.handle_message("triage_verdict", ...)`
    # runs, then the same apply.
    {:ok, message} =
      result["message"]
      |> Map.merge(%{"dispatch_id" => record.dispatch_id, "claim_epoch" => @epoch})
      |> RunnerContract.cast_triage_verdict_message()

    assert {:ok, _} = TriageVerdict.apply(story.tenant_id, runner.id, message)

    events = stage_events(story.tenant_id, story.id)
    row = Stages.get(story.tenant_id, story.id)

    triage_step = Enum.find(events, &(&1.from_stage == "detected" and &1.to_stage == "triaged"))

    flagged =
      events
      |> Enum.map(& &1.data["payload"])
      |> Enum.find_value(&(is_map(&1) && &1["draft_flagged_signals"]))

    %{
      stage: row.stage,
      gate_screen: get_in(triage_step.data, ["payload", "gate_screen"]),
      draft_screen: draft_screen_of(row.escalation_reason),
      flagged: flagged
    }
  end

  defp draft_screen_of("triage_verdict:draft_flagged"), do: "draft_injection"
  defp draft_screen_of("triage_verdict:draft_not_dispatchable"), do: "draft_dispatchable"
  defp draft_screen_of(_reason), do: nil

  # The replay's verdict-screen codes in the order the live screen records them, Gate A's
  # first; `nil` when neither refused, as the live triage step then records no key.
  defp gate_codes(replay) do
    case Enum.flat_map(["gate_a", "gate_b"], &Map.get(replay.codes, &1, [])) do
      [] -> nil
      codes -> codes
    end
  end

  defp draft_screen(replay),
    do: Enum.find(replay.screens, &(&1 in ["draft_injection", "draft_dispatchable"]))

  defp apply_reply_live(result) do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    story = fixture(:set_aside_story, %{tenant_id: tenant.id})
    runner = fixture(:stage_runner, %{tenant_id: tenant.id})

    record =
      fixture(:accepted_dispatch, %{
        tenant_id: tenant.id,
        runner: runner,
        story_id: story.id,
        claim_epoch: @epoch,
        kind: "reply_draft"
      })

    # THE CHANNEL'S PATH, as `handle_message("agent_result", ...)` runs it.
    {:ok, message} =
      result["message"]
      |> Map.merge(%{"dispatch_id" => record.dispatch_id, "claim_epoch" => @epoch})
      |> RunnerContract.cast_agent_result_message()

    assert {:ok, _} = AgentResult.apply(tenant.id, runner.id, message)

    {:ok, [draft]} =
      Repo.with_tenant(tenant.id, fn ->
        Repo.all(from d in ReplyDraft, where: d.tenant_id == ^tenant.id)
      end)

    draft
  end

  defp stage_events(tenant_id, story_id) do
    {:ok, events} =
      Repo.with_tenant(tenant_id, fn ->
        Repo.all(
          from e in Loopctl.Delivery.StageEvent,
            where: e.tenant_id == ^tenant_id and e.story_id == ^story_id,
            order_by: [asc: e.inserted_at, asc: e.lock_version]
        )
      end)

    events
  end
end
