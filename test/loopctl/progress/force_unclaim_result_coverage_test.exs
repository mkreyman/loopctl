defmodule Loopctl.Progress.ForceUnclaimResultCoverageTest do
  use Loopctl.DataCase, async: true

  @moduledoc """
  846.8 AC-5. `Progress.force_unclaim_story/3` then built a five-step `Ecto.Multi` and matched its
  result against three shapes, so a refusal at `:stage`, `:audit` or `:webhook_events` raised
  `CaseClauseError` — out of the ONE call an operator makes to unstick a parked story, and
  against a `@spec` promising `{:error, atom()}`.

  Adding the missing clauses fixed today. This file is what stops it recurring: the defect
  arrived because a step was added to the Multi and the result `case` was not revisited, and
  nothing could see the two drift apart. The file's house style is explicit clauses with no
  catch-all (`LoopctlWeb.DispatchController.revoke_ceiling/3`), which is the right style and is
  exactly why the gap is invisible at the call site — a catch-all would have swallowed it
  instead, which is worse.

  ## THE MECHANISM, AND WHY IT IS NO LONGER A REGEX

  This guard read both halves out of the SOURCE TEXT with regular expressions for two review
  rounds, and each round found spellings the scan could not see: a pipe the formatter broke
  across lines, an atom carrying a digit, a step added anywhere other than a literal pipe in
  this one function, and a three-element `{:error, :some_atom, message}` RETURN being counted
  as a clause head. Every one failed SILENTLY GREEN — a step this does not see is dropped from
  the comparison, so `uncovered/0` answers `[]` — which is the exact direction the guard exists
  to prevent. Patching a fourth spelling would have bought one more round.

  So neither half reads text any more:

    * **The steps come from the `%Ecto.Multi{}` ITSELF.** `Progress.force_unclaim_multi/3` is
      published for this (see its `@doc`), builds nothing in the database, and
      `Ecto.Multi.to_list/1` returns the operation list. That is not an inference about the
      source, it is the value the transaction will run, so HOW a step was added cannot matter.
    * **The handled names come from the AST**, via `Code.string_to_quoted!/1`, walking the
      clause HEADS of the `case` over `AdminRepo.transaction/1`. A clause head and an
      expression in a clause body are different nodes, and a 3-tuple and a 4-tuple are
      different nodes, so the two confusions a regex kept making are not expressible here.

  ## WHAT IT STILL CANNOT SEE — stated, not implied

  Both remaining bounds fail LOUD (a false positive: a covered step reported as uncovered, so
  the test goes red and a human looks), never silently green. That asymmetry is the point.

    * `Ecto.Multi.merge/2` resolves its inner steps at RUN time from prior changes, so
      `to_list/1` reports the merge as a single operation named `:merge`. A merge added here
      would be reported as an uncovered step called `:merge`, which is right in spirit — the
      inner names cannot be known without running it, so a human has to decide. There is a
      control below asserting exactly that.
    * The handled half reads the `case` inside `force_unclaim_story/3`'s own AST. Delegating
      that `case` to a helper would leave it finding no clauses at all, so EVERY step would
      report uncovered. Loud, and pointing at the right place.

  Coverage is counted only where a clause could actually match a step: the second element of
  an `{:error, <step>, _, _}` clause head, or a member of a `when step in [...]` guard list.
  """

  alias Loopctl.MultiResultCoverage
  alias Loopctl.Progress

  @source_path "lib/loopctl/progress.ex"
  @fun :force_unclaim_story

  describe "every Multi step has a result clause" do
    test "force_unclaim_story/3's Multi steps are all named in its result case" do
      assert uncovered() == [],
             "force_unclaim_story/3 gained a Multi step with no clause in its result case: " <>
               "#{inspect(uncovered())}. A failure there is a CaseClauseError out of an " <>
               "operator remedy. Decide what that step's failure means and add a clause — " <>
               "never a catch-all, which is what hid this."
    end

    test "the extraction is not vacuous: it finds the steps that ARE there" do
      # Without this the assertion above is satisfied by an extractor that finds nothing.
      #
      # A SUBSET, not an equality. Adding a sixth step must make exactly ONE test red — the
      # one above, which names the step and says what to do. A maintainer handed two failures,
      # one of them about a list of names being out of date, learns less from the pair than
      # from the one. Equality here made both red, and this comment said the opposite of what
      # the assertion did until 846.8's second review round.
      steps = multi_steps()

      for step <- [:lock, :story, :stage, :audit, :webhook_events] do
        assert step in steps, "the step reader lost #{inspect(step)}"
      end
    end

    test "the check REPORTS a step that has no clause (negative control on the checker)" do
      # The checker run against a Multi carrying a sixth step. If this comes back empty the
      # two tests above prove nothing, whatever the real code says.
      extra =
        Ecto.Multi.run(control_multi(), :notify_everyone, fn _repo, _changes -> {:ok, nil} end)

      assert uncovered(extra, real_source()) == [:notify_everyone]
    end

    test "a step added by Multi.merge/2 is REPORTED, which is the declared bound" do
      # The one thing the runtime read cannot resolve: a merge's inner steps are built at run
      # time from prior changes, so the operation list carries the merge itself. Asserted
      # rather than described, so the moduledoc's claim about it is checkable — and note the
      # direction: it reports, it does not silently pass.
      merged =
        Ecto.Multi.merge(control_multi(), fn _changes ->
          Ecto.Multi.run(Ecto.Multi.new(), :inner, fn _repo, _changes -> {:ok, nil} end)
        end)

      assert uncovered(merged, real_source()) == [:merge]
    end
  end

  describe "what counts as a clause that HANDLES a step" do
    test "error tuples in a clause BODY are not clause heads, at any arity" do
      # The round 2 finding: a regex keyed on `{:error, :atom,` matched
      # `{:error, :unprocessable_entity, message}` — a RETURN VALUE this codebase already uses
      # — and read the step as covered with nothing handling it. Its round 1 twin was this
      # function's own two-element `{:error, :force_unclaim_failed}`.
      #
      # The bodies below carry a FOUR-element error tuple as well, which is the shape a head
      # would legitimately have. That is deliberate: with only the 2- and 3-element shapes,
      # this test would pass on the arity check alone and could not tell whether bodies are
      # read at all. Four elements makes it a pure head-versus-body discriminator.
      source = """
      defmodule Fake do
        def force_unclaim_story(_a, _b, _c) do
          case AdminRepo.transaction(multi) do
            {:error, :lock, reason, _} ->
              log(:unprocessable_entity, "refused")
              log({:error, :notify_everyone, reason, nil})
              {:error, :step_2}
          end
        end
      end
      """

      assert handled_names(source) == [:lock]
    end

    test "a THREE-element tuple in the HEAD is not a clause that can match" do
      # The other half of the 3-tuple case, and the one that actually exercises the arity
      # check: a clause HEAD of three elements. `AdminRepo.transaction/1` answers
      # `{:error, name, value, changes}` — four — so a three-element head matches nothing and
      # handles nothing, however much it looks like a clause for `:notify_everyone`. Without
      # this control the arity check is unfalsifiable, since the head/body split alone carries
      # the test above.
      source = """
      defmodule Fake do
        def force_unclaim_story(_a, _b, _c) do
          case AdminRepo.transaction(multi) do
            {:error, :lock, reason, _} -> {:error, reason}
            {:error, :notify_everyone, reason} -> {:error, reason}
          end
        end
      end
      """

      assert handled_names(source) == [:lock]
    end

    test "a `when step in [...]` guard covers every atom it lists" do
      # The positive control on the other position. Without it the two tests above are
      # satisfied by an extractor that only ever finds the first clause.
      source = """
      defmodule Fake do
        def force_unclaim_story(_a, _b, _c) do
          case AdminRepo.transaction(multi) do
            {:error, :lock, reason, _} -> {:error, reason}
            {:error, step, _r, _} when step in [:stage, :audit, :step_2] -> {:error, step}
          end
        end
      end
      """

      assert Enum.sort(handled_names(source)) == [:audit, :lock, :stage, :step_2]
    end

    test "a step named only in a COMMENT does not count as covered" do
      # The repo's own lesson about guard tests going vacuous through prose. The AST drops
      # comments outright, so this is now true by construction rather than by a filter — and
      # it is kept because a future mechanism that reads text again must still pass it.
      source = """
      defmodule Fake do
        def force_unclaim_story(_a, _b, _c) do
          # :notify_everyone cannot fail, so it needs no clause.
          case AdminRepo.transaction(multi) do
            {:error, :lock, reason, _} -> {:error, reason}
          end
        end
      end
      """

      assert handled_names(source) == [:lock]
    end

    test "a case over something OTHER than the transaction is not the result case" do
      # The handled half is anchored on `AdminRepo.transaction/1`. Anchoring on "the first
      # case in the function" would have counted an unrelated one, so this pins the anchor —
      # and shows the bound the moduledoc states: nothing found means nothing covered, which
      # makes every step report.
      source = """
      defmodule Fake do
        def force_unclaim_story(_a, _b, _c) do
          case something_else(multi) do
            {:error, :lock, reason, _} -> {:error, reason}
          end
        end
      end
      """

      assert handled_names(source) == []
    end
  end

  describe "the shapes the spec promises" do
    test "an unknown story is {:error, :not_found}, not a raise" do
      tenant = fixture(:tenant)

      assert {:error, :not_found} =
               Progress.force_unclaim_story(tenant.id, Ecto.UUID.generate())
    end

    test "a claimed story is released" do
      story = fixture(:story)
      agent = fixture(:agent, tenant_id: story.tenant_id)

      {:ok, _} =
        Progress.contract_story(story.tenant_id, story.id, %{}, skip_contract_check: true)

      {:ok, _} = Progress.claim_story(story.tenant_id, story.id, agent_id: agent.id)

      assert {:ok, released} = Progress.force_unclaim_story(story.tenant_id, story.id)
      assert released.agent_status == :pending
      assert is_nil(released.assigned_agent_id)
    end
  end

  # --- the checker -------------------------------------------------------------------------
  #
  # The mechanism itself is `Loopctl.MultiResultCoverage` (test/support), shared with
  # `Loopctl.Progress.UnclaimResultCoverageTest`; the controls above exercise it through here.

  defp uncovered, do: uncovered(real_multi(), real_source())

  defp uncovered(multi, source), do: MultiResultCoverage.uncovered(multi, source, @fun)

  # THE OPERATION LIST, not a reading of anything. Building the Multi runs no query — every
  # step is a closure — so fabricated ids are enough and this stays a pure function.
  defp real_multi, do: Progress.force_unclaim_multi(Ecto.UUID.generate(), Ecto.UUID.generate())

  defp multi_steps, do: MultiResultCoverage.steps_of(real_multi())

  # A SYNTHETIC base for the negative controls, deliberately not `real_multi/0`. Building them
  # on the production Multi coupled them to it: adding a step there turned one failure into
  # three, which is the very noise the subset assertion above exists to avoid. `:lock` is here
  # only so the controls assert on a list with something covered in it.
  defp control_multi,
    do: Ecto.Multi.run(Ecto.Multi.new(), :lock, fn _repo, _changes -> {:ok, nil} end)

  defp real_source, do: File.read!(@source_path)

  defp handled_names(source), do: MultiResultCoverage.handled_names(source, @fun)
end
