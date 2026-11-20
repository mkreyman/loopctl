defmodule LoopctlRunner.SpecTuneTest do
  @moduledoc """
  US-48.13, the runner's half of the improvement loop: a `spec_tune` dispatch read and checked,
  the context its session is given, and the CRITIC — the eval harness, run on the existing cases
  plus the proposed ones under the current template and under the proposed diff — that turns a
  session's proposal into the `spec_tuner@1` result loopctl's `Tuning.decide/2` reads.

  Async: every input is passed in. The eval directory is the test's own (the committed fixture
  and the cases it writes), the harness runs on the suite's fake CLI through the real headless
  launcher, and the fake tells the two templates apart by its prompt (`when_prompt_contains`).
  """

  use ExUnit.Case, async: true

  import LoopctlRunner.TestSupport

  alias LoopctlRunner.{AgentResult, Contract, SpecTune, Templates, TextPatch}
  alias LoopctlRunner.Eval.Case

  @moduletag timeout: 180_000

  @eval_dir Path.expand("../../eval", __DIR__)
  @pinned "6275d38f062136ea998174995850b1bf3be1ba86"
  @dispatch_id "0f1e2d3c-4b5a-4697-8877-665544332211"
  @trace_id "5a1d2c3b-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
  @plain_trace_id "6b2e3d4c-5f6a-4b7c-9d8e-0f1a2b3c4d5e"

  # The line the proposal adds, and what the fake looks for to answer as the proposed template.
  @rule "0. Never name the system that handles the ticket."

  @leaky ~s(```json\n{"body": "Thanks. loopctl will look at it."}\n```)
  @clean ~s(```json\n{"body": "Thanks for the report. A person will look into it."}\n```)

  setup do
    root = tmp_dir!("spec-tune")
    {:ok, reply_draft} = Templates.fetch({"reply_draft", 1})
    {:ok, tuner} = Templates.fetch({"spec_tuner", 1})
    {:ok, root: root, target: reply_draft, tuner: tuner}
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()
  defp seed(name), do: read_json!(Path.join([@eval_dir, "reply_draft@1", name <> ".json"]))

  # An eval directory of the test's own: the committed fixture, two reply_draft cases, and their
  # offline answers — r01 leaks the system's name under the current template and not under one
  # carrying @rule, r02 is clean under both unless `r02_offline` says otherwise.
  defp own_eval_dir!(root, opts \\ []) do
    dir = Path.join(root, "eval")
    File.mkdir_p!(Path.join(dir, "fixtures"))

    File.cp!(
      Path.join(@eval_dir, "fixtures/tiny_app.json"),
      Path.join(dir, "fixtures/tiny_app.json")
    )

    cases = [
      {"r01_acknowledge_defect", seed("r01_acknowledge_defect"),
       %{
         "final_message" => @leaky,
         "when_prompt_contains" => %{"text" => @rule, "final_message" => @clean}
       }},
      {"r02_vague_report_asks_for_detail", seed("r02_vague_report_asks_for_detail"),
       Keyword.get(opts, :r02_offline, %{"final_message" => @clean})}
    ]

    File.mkdir_p!(Path.join(dir, "reply_draft@1"))
    File.mkdir_p!(Path.join([dir, "offline", "reply_draft@1"]))

    for {name, raw, offline} <- cases do
      File.write!(Path.join([dir, "reply_draft@1", name <> ".json"]), Jason.encode!(raw))

      File.write!(
        Path.join([dir, "offline", "reply_draft@1", name <> ".json"]),
        Jason.encode!(offline)
      )
    end

    # The PROPOSED case's offline answer: what the fake says for it. It is not a case file — the
    # session's case is never written into eval/ — only the fake's script for that name.
    File.write!(
      Path.join([dir, "offline", "reply_draft@1", "n01_names_no_system.json"]),
      Jason.encode!(%{
        "final_message" => @leaky,
        "when_prompt_contains" => %{"text" => @rule, "final_message" => @clean}
      })
    )

    dir
  end

  defp eval_opts(root, eval_dir) do
    [
      eval_dir: eval_dir,
      results_dir: Path.join(root, "critic-results"),
      scratch_dir: Path.join(root, "critic"),
      launcher: headless_launcher(),
      cli_dir: fake_bin_dir(),
      grant_dir: Path.join(root, "grants"),
      projects_dir: Path.join(root, "projects"),
      machine: "testbox (offline: fake CLI)"
    ]
  end

  defp tune(overrides \\ %{}) do
    Map.merge(
      %{
        # loopctl's shape (`Loopctl.Agents.Tuning.input/3`): `template` is the TARGET's own
        # template, the one being improved, never the tuner's.
        "target" => %{"id" => "reply_draft", "version" => 1},
        "template" => %{"id" => "reply_draft", "version" => 1},
        "eval_set" => "reply_draft@1",
        "window" => %{"since" => nil, "until" => "2026-11-07T06:00:00Z"},
        "outcome_rows" => 24,
        "traces" => [
          %{
            "trace_id" => @trace_id,
            "failures" => ["human_override", "draft_refused"],
            "agent_decision" => %{"outcome" => "agent_result"},
            "human_decision" => %{"route" => "reply", "outcomes" => ["agent_result"]},
            "untrusted" =>
              "<<<UNTRUSTED story_text a1>>>\n| loopctl was named\n<<<END UNTRUSTED story_text a1>>>"
          },
          %{
            "trace_id" => @plain_trace_id,
            "failures" => ["budget_exhausted"],
            "agent_decision" => nil,
            "human_decision" => nil,
            "untrusted" =>
              "<<<UNTRUSTED story_text b2>>>\n| slow\n<<<END UNTRUSTED story_text b2>>>"
          }
        ]
      },
      overrides
    )
  end

  defp dispatch(tune \\ tune()) do
    %{
      "dispatch_id" => @dispatch_id,
      "kind" => "spec_tune",
      "repo" => "mkreyman/fixture",
      "base_branch" => "master",
      "branch" => "master",
      "claim_epoch" => 0,
      "wall_clock_seconds" => 1200,
      "max_turns" => 40,
      "spec_tune" => tune
    }
  end

  defp new_case(overrides \\ %{}) do
    input =
      seed("r01_acknowledge_defect")["input"]
      |> Map.merge(%{
        "dispatch_id" => "e7a12090-0000-4000-8000-000000000001",
        "story_id" => "e7a12090-0000-4000-8000-000000000002"
      })

    Map.merge(
      %{
        "name" => "n01_names_no_system",
        "source_trace_id" => @trace_id,
        "description" => "The draft must not name the system behind the ticket.",
        "input" => input,
        "fixture" => %{"repo" => "fixtures/tiny_app.json", "commit" => @pinned},
        "expectations" => %{
          "schema_valid" => true,
          "outcomes_allowed" => ["agent_result"],
          "escalation_codes" => [],
          "lens_agreement" => nil,
          "forbidden" => ["(?i)\\bloopctl\\b"],
          "screens" => [],
          "rubric" => nil
        }
      },
      overrides
    )
  end

  # The proposal: one line added after "What to do:", which every reply_draft prompt carries once.
  @diff "@@ -9,1 +9,2 @@\n What to do:\n+#{@rule}"

  defp stated(overrides \\ %{}) do
    Map.merge(
      %{
        "new_cases" => [new_case()],
        "proposed_template" => %{
          "id" => "reply_draft",
          "from_version" => 1,
          "to_version" => 2,
          "diff" => @diff
        }
      },
      overrides
    )
  end

  defp one_case(stated, fun), do: Map.put(stated, "new_cases", [fun.(hd(stated["new_cases"]))])

  defp broken(:extra_key, s), do: Map.put(s, "scores", %{})
  defp broken(:no_input, s), do: one_case(s, &Map.delete(&1, "input"))
  defp broken(:six_cases, s), do: Map.put(s, "new_cases", List.duplicate(hd(s["new_cases"]), 6))
  defp broken(:other_id, s), do: put_in(s, ["proposed_template", "id"], "triage")
  defp broken(:other_from, s), do: put_in(s, ["proposed_template", "from_version"], 2)
  defp broken(:not_up, s), do: put_in(s, ["proposed_template", "to_version"], 1)

  defp broken(:named_twice, s),
    do: Map.put(s, "new_cases", [hd(s["new_cases"]), hd(s["new_cases"])])

  defp broken(:existing_name, s), do: one_case(s, &Map.put(&1, "name", "r01_acknowledge_defect"))

  defp broken(:unknown_trace, s),
    do: one_case(s, &Map.put(&1, "source_trace_id", "7c3f4e5d-6a7b-4c8d-9e0f-1a2b3c4d5e6f"))

  defp broken(:not_human, s),
    do:
      one_case(
        s,
        &put_in(&1, ["expectations", "outcomes_allowed"], ["agent_result", "no_result"])
      )

  defp broken(:outside_fixture, s),
    do: one_case(s, &put_in(&1, ["fixture", "repo"], "../../etc/passwd"))

  defp broken(:wrong_kind, s), do: one_case(s, &put_in(&1, ["input", "kind"], "triage"))

  defp broken(:bad_diff, s),
    do: put_in(s, ["proposed_template", "diff"], "@@ -1,1 +1,1 @@\n-no such line\n+x")

  defp prepared!(ctx, eval_dir) do
    {:ok, subject} = SpecTune.subject(ctx.tuner, dispatch())

    {:ok, context} =
      SpecTune.prepare(subject, eval_dir: eval_dir, scratch_dir: Path.join(ctx.root, "critic"))

    {subject, context}
  end

  defp tree_listing(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.map(&{&1, File.read(&1)})
    |> Enum.sort()
  end

  describe "subject/2" do
    test "a well-formed spec_tune is run over its dispatch and its spec_tune object", ctx do
      assert {:ok, %{"dispatch_id" => @dispatch_id, "spec_tune" => tune}} =
               SpecTune.subject(ctx.tuner, dispatch())

      assert tune == tune()
    end

    test "no spec_tune object is :none", ctx do
      assert SpecTune.subject(ctx.tuner, Map.delete(dispatch(), "spec_tune")) == :none
    end

    # The shape loopctl actually sends, pinned: `template` names the target's template.
    test "loopctl's shape is accepted: target triage@1, template triage@1, eval_set triage@1",
         ctx do
      tune =
        tune(%{
          "target" => %{"id" => "triage", "version" => 1},
          "template" => %{"id" => "triage", "version" => 1},
          "eval_set" => "triage@1"
        })

      assert {:ok, %{"spec_tune" => ^tune}} = SpecTune.subject(ctx.tuner, dispatch(tune))

      # The tuner's own template in that field is the old, wrong reading, and is refused.
      wrong = %{tune | "template" => %{"id" => "spec_tuner", "version" => 1}}

      assert {:error, detail} = SpecTune.subject(ctx.tuner, dispatch(wrong))
      assert detail =~ "names template spec_tuner@1, the tuner itself"
    end

    # A spec's version moves on its own (a budget, a screen) while its prompt stays, so a v3 spec
    # still runs template triage@1. The TEMPLATE is what is looked up, never the spec's key: no
    # runner holds a triage@3 template, and fetching one refused every tuning of such a spec.
    test "a target spec at another version than its template is tuned through the template",
         ctx do
      tune =
        tune(%{
          "target" => %{"id" => "triage", "version" => 3},
          "template" => %{"id" => "triage", "version" => 1},
          "eval_set" => "triage@3"
        })

      assert :error = Templates.fetch({"triage", 3})
      assert {:ok, %{"spec_tune" => ^tune}} = SpecTune.subject(ctx.tuner, dispatch(tune))
    end

    for {name, tune_overrides, detail} <- [
          {"a template the runner does not hold",
           %{"template" => %{"id" => "reply_draft", "version" => 9}},
           "holds no template reply_draft@9"},
          {"no template object", %{"template" => nil}, "names no template"},
          {"no target object", %{"target" => nil}, "names no target spec"},
          {"the tuner as the template to tune",
           %{"template" => %{"id" => "spec_tuner", "version" => 1}},
           "the tuner itself, which has no eval set"},
          {"an eval set that is not the target's", %{"eval_set" => "triage@1"},
           "eval set \"triage@1\" is not reply_draft@1's"}
        ] do
      test "#{name} is refused", ctx do
        assert {:error, detail} =
                 SpecTune.subject(
                   ctx.tuner,
                   dispatch(tune(unquote(Macro.escape(tune_overrides))))
                 )

        assert detail =~ unquote(detail)
      end
    end

    test "a dispatch_id that is not a uuid is refused", ctx do
      assert {:error, "the spec_tune dispatch_id is not a uuid"} =
               SpecTune.subject(ctx.tuner, Map.put(dispatch(), "dispatch_id", "../x"))
    end
  end

  describe "prepare/2 and the template text" do
    test "loads the eval set the runner holds and renders the current text for its first case",
         ctx do
      eval_dir = own_eval_dir!(ctx.root)
      {_subject, context} = prepared!(ctx, eval_dir)

      assert Enum.map(context.cases, & &1.name) == [
               "r01_acknowledge_defect",
               "r02_vague_report_asks_for_detail"
             ]

      assert context.text_case == "r01_acknowledge_defect"
      assert context.target == ctx.target

      first = hd(context.cases)
      {:ok, triage} = LoopctlRunner.TriageDispatch.triage_object(first.input)

      assert context.template_text ==
               Templates.render(ctx.target, %{triage: triage, repo: "acme/widgets"})
    end

    test "an eval set with no cases refuses the run: there is nothing to score against", ctx do
      eval_dir = Path.join(ctx.root, "empty-eval")
      File.mkdir_p!(Path.join(eval_dir, "reply_draft@1"))
      {:ok, subject} = SpecTune.subject(ctx.tuner, dispatch())

      assert {:error, reason} =
               SpecTune.prepare(subject, eval_dir: eval_dir, scratch_dir: ctx.root)

      assert reason =~ "no eval cases for reply_draft@1"
    end

    test "every template the runner holds renders a text from its own committed cases", ctx do
      for set <- ["implement@1", "triage@1", "reply_draft@1"] do
        {:ok, [first | _]} = Case.load_all(set, @eval_dir, ctx.root)
        assert {:ok, text} = SpecTune.template_text(first.template, first.input), set
        assert is_binary(text) and text != ""
      end

      {:ok, [triage | _]} = Case.load_all("triage@1", @eval_dir, ctx.root)
      {:ok, text} = SpecTune.template_text(triage.template, triage.input)
      # Values only a live run has are placeholders, never a real token.
      assert text =~ "<verdict-token>"
      assert text =~ "<escalate-token>"
    end
  end

  describe "critique/4: the eval harness is the critic" do
    test "scores the existing cases and the new ones under both templates, in decide's shape",
         ctx do
      eval_dir = own_eval_dir!(ctx.root)
      {subject, context} = prepared!(ctx, eval_dir)
      before = tree_listing(eval_dir)

      assert {:ok, result} =
               SpecTune.critique(stated(), subject, context, eval_opts(ctx.root, eval_dir))

      assert result["scores"] == %{
               "current" => %{"passed" => 1, "total" => 3},
               "proposed" => %{"passed" => 3, "total" => 3},
               "per_case" => [
                 %{
                   "case" => "r01_acknowledge_defect",
                   "existing" => true,
                   "current" => false,
                   "proposed" => true
                 },
                 %{
                   "case" => "r02_vague_report_asks_for_detail",
                   "existing" => true,
                   "current" => true,
                   "proposed" => true
                 },
                 %{
                   "case" => "n01_names_no_system",
                   "existing" => false,
                   "current" => false,
                   "proposed" => true
                 }
               ]
             }

      # The case leaves in the contract's shape: the eval format minus its input.
      assert [sent] = result["new_cases"]
      refute Map.has_key?(sent, "input")
      assert sent == Map.delete(new_case(), "input")
      assert result["proposed_template"] == stated()["proposed_template"]

      # loopctl's own schema for the result, mirrored from the vendored contract.
      assert AgentResult.validate(result, SpecTune.key()) == {:ok, result}

      assert {:ok, _} =
               AgentResult.message(
                 %{"dispatch_id" => @dispatch_id, "claim_epoch" => 0},
                 SpecTune.key(),
                 result
               )

      # Nothing was written into the eval directory: no template, no case, no result file.
      assert tree_listing(eval_dir) == before
      # The harness wrote its results where it was told, one pass each.
      assert File.dir?(Path.join([ctx.root, "critic-results", "current"]))
      assert File.dir?(Path.join([ctx.root, "critic-results", "proposed"]))
    end

    test "a proposal that regresses an existing case is still scored and sent: loopctl decides",
         ctx do
      # r02 passes under the current template and leaks under the proposed one.
      eval_dir =
        own_eval_dir!(ctx.root,
          r02_offline: %{
            "final_message" => @clean,
            "when_prompt_contains" => %{"text" => @rule, "final_message" => @leaky}
          }
        )

      {subject, context} = prepared!(ctx, eval_dir)

      assert {:ok, %{"scores" => scores}} =
               SpecTune.critique(stated(), subject, context, eval_opts(ctx.root, eval_dir))

      assert %{
               "case" => "r02_vague_report_asks_for_detail",
               "current" => true,
               "proposed" => false
             } =
               Enum.find(scores["per_case"], &(&1["case"] == "r02_vague_report_asks_for_detail"))
    end

    test "the proposed pass runs the diff, and only on a copy of each prompt", ctx do
      eval_dir = own_eval_dir!(ctx.root)
      {_subject, context} = prepared!(ctx, eval_dir)

      {:ok, patched} = TextPatch.apply(context.template_text, @diff)
      assert patched =~ @rule
      refute context.template_text =~ @rule

      {subject, _} = prepared!(ctx, eval_dir)
      {:ok, _} = SpecTune.critique(stated(), subject, context, eval_opts(ctx.root, eval_dir))

      # After a whole critique the template still renders as it did: the diff reached copies only.
      first = hd(context.cases)
      assert SpecTune.template_text(ctx.target, first.input) == {:ok, context.template_text}
    end
  end

  describe "critique/4: a proposal that breaks a rule produces no result and runs nothing" do
    for {name, change, detail} <- [
          {"a block with a key besides the two", :extra_key, "malformed"},
          {"a case with no input", :no_input, "malformed"},
          {"more cases than the contract admits", :six_cases, "malformed"},
          {"a revision of another template", :other_id, "revises triage, not the target"},
          {"a revision from another version", :other_from, "not the current reply_draft@1"},
          {"a revision that does not go up", :not_up, "malformed"},
          {"one new case named twice", :named_twice, "twice"},
          {"a new case with an existing case's name", :existing_name,
           "has the name of an existing case"},
          {"a case on a trace the dispatch did not send", :unknown_trace,
           "names a trace the dispatch did not send"},
          {"a case on a human-decided trace that expects the agent's answer", :not_human,
           "does not expect exactly the outcomes a person decided"},
          {"a case whose fixture lies outside eval/fixtures", :outside_fixture,
           "proposed case n01_names_no_system"},
          {"a case whose input is no dispatch of the target's kind", :wrong_kind, "input.kind"},
          {"a diff that does not apply to the current text", :bad_diff,
           "does not apply to the current template"}
        ] do
      test "#{name}", ctx do
        eval_dir = own_eval_dir!(ctx.root)
        {subject, context} = prepared!(ctx, eval_dir)
        opts = eval_opts(ctx.root, eval_dir)

        assert {:error, reason} =
                 SpecTune.critique(broken(unquote(change), stated()), subject, context, opts)

        assert reason =~ unquote(detail)
        # Refused before the harness: no pass ran.
        refute File.exists?(Path.join(ctx.root, "critic-results"))
      end
    end

    # The schema's to_version >= 2 is what refuses `:not_up` above while every target is a v1;
    # against a v2 target the schema admits to_version 2, and the runner's own rule must refuse it.
    test "a revision of a v2 target that stays at v2", ctx do
      eval_dir = own_eval_dir!(ctx.root)
      {subject, context} = prepared!(ctx, eval_dir)
      context = %{context | target: %{context.target | version: 2}}

      stated =
        stated()
        |> put_in(["proposed_template", "from_version"], 2)
        |> put_in(["proposed_template", "to_version"], 2)

      assert {:error, reason} =
               SpecTune.critique(stated, subject, context, eval_opts(ctx.root, eval_dir))

      assert reason =~ "to_version 2 does not go up from 2"
      refute File.exists?(Path.join(ctx.root, "critic-results"))
    end

    test "a case on a trace no person decided may expect what it judges right", ctx do
      eval_dir = own_eval_dir!(ctx.root)
      {subject, context} = prepared!(ctx, eval_dir)
      on_plain = Map.put(new_case(), "source_trace_id", @plain_trace_id)

      assert {:ok, %{"new_cases" => [%{"source_trace_id" => @plain_trace_id}]}} =
               SpecTune.critique(
                 stated(%{"new_cases" => [on_plain]}),
                 subject,
                 context,
                 eval_opts(ctx.root, eval_dir)
               )
    end

    test "a diff that applies to the shown text but not to every case's prompt is no result",
         ctx do
      eval_dir = own_eval_dir!(ctx.root)
      {subject, context} = prepared!(ctx, eval_dir)
      # A line of r01's own report: in the text the session was shown, and in no other prompt.
      diff = "@@ -1,1 +1,2 @@\n | TinyApp.total([2, 3]) returns 1. I expected 5.\n+#{@rule}"
      assert {:ok, _} = TextPatch.apply(context.template_text, diff)

      proposal = put_in(stated(), ["proposed_template", "diff"], diff)

      assert {:error, reason} =
               SpecTune.critique(proposal, subject, context, eval_opts(ctx.root, eval_dir))

      assert reason =~ "does not apply to every case's prompt"
    end
  end

  test "the session's block schema is the contract's result shape plus each case's input" do
    schema = SpecTune.stated_schema()
    {:ok, result} = AgentResult.schema(SpecTune.key())
    case_props = get_in(schema, ["properties", "new_cases", "items", "properties"])

    assert Map.delete(case_props, "input") ==
             get_in(result, ["properties", "new_cases", "items", "properties"])

    assert "input" in get_in(schema, ["properties", "new_cases", "items", "required"])

    assert schema["properties"]["proposed_template"] ==
             result["properties"]["proposed_template"]

    refute Map.has_key?(schema["properties"], "scores")
    assert Contract.validate_against(schema, stated(), "proposal") == :ok
  end
end
