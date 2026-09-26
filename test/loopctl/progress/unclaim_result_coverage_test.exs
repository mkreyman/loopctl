defmodule Loopctl.Progress.UnclaimResultCoverageTest do
  use Loopctl.DataCase, async: true

  @moduledoc """
  #877 review round 1. `Progress.unclaim_story/3` matched its transaction's result against
  four of its Multi's steps, so a refusal at `:stage` — which since US-44.4 can refuse, when the
  release's escalation could not append its chain entry — or at `:audit` / `:webhook_events`
  was a `CaseClauseError` out of an agent's own unclaim.

  The same guard, and the same mechanism, as `Loopctl.Progress.ForceUnclaimResultCoverageTest`
  (read its moduledoc for why the steps are read off the `%Ecto.Multi{}` and the clauses off
  the AST, and for the two bounds it states): `Loopctl.MultiResultCoverage`. The checker's own
  controls live in that file; this one binds `unclaim_multi/3` to `unclaim_story/3`.
  """

  alias Loopctl.MultiResultCoverage
  alias Loopctl.Progress

  @source_path "lib/loopctl/progress.ex"
  @fun :unclaim_story

  describe "every Multi step has a result clause" do
    test "unclaim_story/3's Multi steps are all named in its result case" do
      assert uncovered() == [],
             "unclaim_story/3 gained a Multi step with no clause in its result case: " <>
               "#{inspect(uncovered())}. A failure there is a CaseClauseError out of an " <>
               "agent's unclaim. Decide what that step's failure means and add a clause — " <>
               "never a catch-all."
    end

    test "the extraction is not vacuous: it finds the steps that ARE there" do
      steps = MultiResultCoverage.steps_of(real_multi())

      for step <- [:lock, :validate, :story, :stage, :audit, :webhook_events, :recontract] do
        assert step in steps, "the step reader lost #{inspect(step)}"
      end
    end

    test "the check reads unclaim_story/3's OWN case: a step it does not name is reported" do
      # Negative control, bound to this function rather than to a synthetic source: the real
      # `case` plus one step it has no clause for must report exactly that step.
      extra =
        Ecto.Multi.run(real_multi(), :notify_everyone, fn _repo, _changes -> {:ok, nil} end)

      assert MultiResultCoverage.uncovered(extra, File.read!(@source_path), @fun) == [
               :notify_everyone
             ]
    end
  end

  describe "the shapes the spec promises" do
    test "an unknown story is {:error, :not_found}, not a raise" do
      tenant = fixture(:tenant)

      assert {:error, :not_found} = Progress.unclaim_story(tenant.id, Ecto.UUID.generate())
    end

    test "a story in another tenant is not found (tenant isolation)" do
      story = fixture(:story)
      other = fixture(:tenant)
      agent = fixture(:agent, tenant_id: story.tenant_id)

      {:ok, _} =
        Progress.contract_story(story.tenant_id, story.id, %{}, skip_contract_check: true)

      {:ok, _} = Progress.claim_story(story.tenant_id, story.id, agent_id: agent.id)

      assert {:error, :not_found} = Progress.unclaim_story(other.id, story.id, agent_id: agent.id)
    end
  end

  defp uncovered,
    do: MultiResultCoverage.uncovered(real_multi(), File.read!(@source_path), @fun)

  # Building the Multi runs no query, so fabricated ids are enough.
  defp real_multi, do: Progress.unclaim_multi(Ecto.UUID.generate(), Ecto.UUID.generate())
end
