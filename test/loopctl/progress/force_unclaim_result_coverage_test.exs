defmodule Loopctl.Progress.ForceUnclaimResultCoverageTest do
  use Loopctl.DataCase, async: true

  @moduledoc """
  846.8 AC-5. `Progress.force_unclaim_story/3` builds a five-step `Ecto.Multi` and matched
  its result against three shapes, so a refusal at `:stage`, `:audit` or `:webhook_events`
  raised `CaseClauseError` — out of the ONE call an operator makes to unstick a parked story,
  and against a `@spec` promising `{:error, atom()}`.

  Adding the missing clauses fixes today. This test is what stops it recurring: the defect
  arrived because a step was added to the Multi and the result `case` was not revisited, and
  nothing could see the two drift apart. The file's house style is explicit clauses with no
  catch-all (`LoopctlWeb.DispatchController.revoke_ceiling/3`), which is the right style and
  is exactly why the gap is invisible at the call site — a catch-all would have swallowed it
  instead, which is worse.

  Coverage is counted only where a clause could actually match a step: the second element of
  an `{:error, <step>, _, _}` head, or a member of a `when step in [...]` guard list. An atom
  appearing in the result half for any other reason — a returned `{:error, :some_atom}`, a
  Logger metadata key — is NOT coverage, and `handled_names/1` says why that distinction is
  load-bearing rather than pedantic.

  It reads SOURCE rather than calling the function, because four of the five steps cannot be
  made to refuse from Elixir at all (see the comment on that `case`), so a behavioural test
  could only ever cover `:lock` and `:story` — the two that were already handled.
  """

  alias Loopctl.Progress

  @source_path "lib/loopctl/progress.ex"

  # What a step's atom may look like. DIGITS are in it because `:step_2` is an ordinary step
  # name and was invisible to the `[a-z_]+` class this used until 846.8's review. Shared by
  # `multi_steps/1` and `handled_names/1`, which have to agree on it: if only the first is
  # widened, a covered `:step_2` is reported as uncovered and the guard cries wolf.
  @atom_name "[a-z_][a-z0-9_]*"

  describe "every Multi step has a result clause" do
    test "force_unclaim_story/3's Multi steps are all named in its result case" do
      body = function_source!(File.read!(@source_path), "force_unclaim_story")

      assert uncovered(body) == [],
             "force_unclaim_story/3 gained a Multi step with no clause in its result case: " <>
               "#{inspect(uncovered(body))}. A failure there is a CaseClauseError out of an " <>
               "operator remedy. Decide what that step's failure means and add a clause — " <>
               "never a catch-all, which is what hid this."
    end

    test "the extraction is not vacuous: it finds the steps that ARE there" do
      # Without this the assertion above is satisfied by an extractor that finds nothing.
      body = function_source!(File.read!(@source_path), "force_unclaim_story")

      # Every step the function actually has, by name. Naming them beats a count: adding a
      # sixth step keeps all five present, so this stays green and the assertion above is the
      # one that goes red — which is the division of labour these two tests are for.
      assert Enum.sort(multi_steps(body)) ==
               ~w(audit lock stage story webhook_events)
    end

    test "the check REPORTS a step that has no clause (negative control on the checker)" do
      # The checker run against a fabricated body carrying a sixth step. If this comes back
      # empty the two tests above prove nothing, whatever the real source says.
      fabricated = """
          multi =
            Multi.new()
            |> Multi.run(:lock, fn _repo, _changes -> {:ok, nil} end)
            |> Multi.run(:story, fn _repo, _changes -> {:ok, nil} end)
            |> Multi.run(:notify_everyone, fn _repo, _changes -> {:ok, nil} end)

          case AdminRepo.transaction(multi) do
            {:ok, %{story: updated}} -> {:ok, updated}
            {:error, :lock, reason, _} -> {:error, reason}
            {:error, :story, changeset, _} -> {:error, changeset}
          end
      """

      assert uncovered(fabricated) == ["notify_everyone"]
    end

    test "a step named where no clause HANDLES it does not count as covered" do
      # The position class the checker was blind to. `{:error, :notify_everyone}` is a RETURN
      # VALUE, not a clause head, and it is the realistic shape — this very function returns
      # `{:error, :force_unclaim_failed}` — so a bare atom scan reads the step as covered while
      # nothing handles it. The Logger metadata key on the line above never leaked (the colon
      # follows the name there) and is included only so both shapes are exercised together.
      fabricated = """
          multi =
            Multi.new()
            |> Multi.run(:lock, fn _repo, _changes -> {:ok, nil} end)
            |> Multi.run(:notify_everyone, fn _repo, _changes -> {:ok, nil} end)

          case AdminRepo.transaction(multi) do
            {:error, :lock, reason, _} ->
              Logger.error("failed", tenant_id: tenant_id, notify_everyone: true)
              {:error, :notify_everyone}
          end
      """

      assert uncovered(fabricated) == ["notify_everyone"]
    end

    test "a step whose pipe the FORMATTER BROKE ACROSS LINES is still seen" do
      # `mix format` writes this the moment the step's arguments get long, and it is what
      # `force_unclaim_story/3`'s own steps would become if one more argument were added to
      # any of them. The per-line scan this file used until 846.8's review saw only `lock`
      # here — so the sixth step somebody adds is dropped from the comparison and the guard
      # reports a clean function.
      fabricated = """
          multi =
            Multi.new()
            |> Multi.run(:lock, fn _repo, _changes -> {:ok, nil} end)
            |> Multi.run(
              :notify_everyone,
              fn _repo, _changes -> {:ok, nil} end
            )

          case AdminRepo.transaction(multi) do
            {:error, :lock, reason, _} -> {:error, reason}
          end
      """

      assert uncovered(fabricated) == ["notify_everyone"]
    end

    test "a step whose atom carries a DIGIT is still seen" do
      # `:step_2` is an ordinary Elixir atom and an ordinary step name; `[a-z_]+` matched only
      # its `step_` prefix, and `step_` is not the step, so the step read as absent.
      fabricated = """
          multi =
            Multi.new()
            |> Multi.run(:lock, fn _repo, _changes -> {:ok, nil} end)
            |> Multi.run(:step_2, fn _repo, _changes -> {:ok, nil} end)

          case AdminRepo.transaction(multi) do
            {:error, :lock, reason, _} -> {:error, reason}
          end
      """

      assert uncovered(fabricated) == ["step_2"]
    end

    test "a digit-bearing step that IS handled reads as covered, not as a false positive" do
      # The other half of the widening. `multi_steps/1` and `handled_names/1` have to agree on
      # what an atom looks like: widening only the first turns a correctly-covered `:step_2`
      # into a permanent failure, and a guard that fails on correct code gets deleted.
      fabricated = """
          multi =
            Multi.new()
            |> Multi.run(:step_2, fn _repo, _changes -> {:ok, nil} end)

          case AdminRepo.transaction(multi) do
            {:error, :step_2, reason, _} -> {:error, reason}
          end
      """

      assert multi_steps(fabricated) == ["step_2"]
      assert uncovered(fabricated) == []
    end

    test "a step named only in a COMMENT does not count as covered" do
      # The repo's own lesson about guard tests going vacuous through prose: coverage has to
      # be established by a clause, not by a sentence describing one.
      fabricated = """
          multi =
            Multi.new()
            |> Multi.run(:lock, fn _repo, _changes -> {:ok, nil} end)
            |> Multi.run(:notify_everyone, fn _repo, _changes -> {:ok, nil} end)

          # :notify_everyone cannot fail, so it needs no clause.
          case AdminRepo.transaction(multi) do
            {:error, :lock, reason, _} -> {:error, reason}
          end
      """

      assert uncovered(fabricated) == ["notify_everyone"]
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

  # --- the checker -----------------------------------------------------------------------

  defp uncovered(body) do
    handled = handled_names(body)
    body |> multi_steps() |> Enum.reject(&(&1 in handled)) |> Enum.uniq()
  end

  # The first argument of every piped call in the Multi-building half: `Multi.run(:lock, …)`,
  # `Audit.log_in_multi(:audit, …)`, `EventGenerator.generate_events(:webhook_events, …)`.
  # Keyed on the PIPE and the leading colon rather than on the three function names, so a
  # fourth way of adding a step is still seen.
  #
  # Compared as STRINGS end to end. `String.to_existing_atom/1` would raise on a newly added
  # step whose atom this test process has never loaded — red, but red with an ArgumentError
  # instead of the name of the step somebody forgot, which is the one thing this test is for.
  # SCANNED ACROSS THE WHOLE CHUNK, not line by line, and over an atom class that admits
  # digits. Both halves are 846.8 review fixes, and both failure modes were silent in the
  # direction that matters: a step this does not see is DROPPED from the comparison, so
  # `uncovered/1` answers `[]` and the guard passes green on precisely the regression it is
  # the only defence against. The two spellings that were invisible are the realistic ones —
  #
  #   * the formatter breaking a long step across lines:
  #
  #         |> Multi.run(
  #           :notify_everyone,
  #           fn _repo, _changes -> ... end
  #         )
  #
  #   * an atom carrying a digit, `:step_2`.
  #
  # Against a body containing both, the per-line `[a-z_]+` scan found only `["lock"]`. Each
  # has its own negative control above, because a fix with no control is the same vacuity one
  # generation later, which is this file's whole subject.
  #
  # Comments are still stripped LINE BY LINE, before the join — which is why this joins
  # `code_lines/1`'s output rather than scanning `multi_half/1` whole. A step named only in a
  # comment therefore still does not count, and its control stays green.
  defp multi_steps(body) do
    chunk = body |> multi_half() |> code_lines() |> Enum.join("\n")

    ~r/\|>\s*[A-Za-z_][\w.]*\(\s*:(#{@atom_name})\s*,/
    |> Regex.scan(chunk)
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
  end

  # Atoms in a POSITION THAT ACTUALLY HANDLES A STEP, never every atom in the chunk. The two
  # positions are the only two `AdminRepo.transaction/1` offers:
  #
  #   * the second element of an error clause head — `{:error, :lock, reason, _} ->`, which is
  #     a THREE-or-more element tuple, hence the trailing comma in the pattern;
  #   * a member of a `when step in [...]` guard list, which is how one clause covers several.
  #
  # Scanning the whole chunk was looser than this test's own moduledoc claimed, and on a file
  # whose entire subject is code and the claim about it disagreeing, a guard that overstates
  # its reach is the wrong thing to ship. The leak was the RETURNED atom: this function's
  # `{:error, :force_unclaim_failed}` matched a bare `:([a-z_]+)` scan, so a step named
  # `:force_unclaim_failed` would have read as covered with no clause at all. (Logger metadata
  # never leaked — `tenant_id: tenant_id` puts the colon AFTER the name — but a two-element
  # `{:error, :atom}` return is indistinguishable from a clause head without the comma.)
  #
  # Still strings end to end, for the reason `multi_steps/1` documents.
  defp handled_names(body) do
    chunk = body |> result_half() |> code_lines() |> Enum.join("\n")

    heads = Regex.scan(~r/\{\s*:error\s*,\s*:(#{@atom_name})\s*,/, chunk)

    guards =
      ~r/\bwhen\s+\w+\s+in\s+\[([^\]]*)\]/
      |> Regex.scan(chunk)
      |> Enum.flat_map(fn [_, list] -> Regex.scan(~r/:(#{@atom_name})/, list) end)

    (heads ++ guards) |> Enum.map(fn [_, name] -> name end) |> Enum.uniq()
  end

  @split "case AdminRepo.transaction(multi) do"

  defp multi_half(body), do: body |> String.split(@split, parts: 2) |> hd()

  defp result_half(body) do
    case String.split(body, @split, parts: 2) do
      [_, rest] -> rest
      [_] -> ""
    end
  end

  defp code_lines(chunk) do
    chunk
    |> String.split("\n")
    |> Enum.reject(&(&1 |> String.trim_leading() |> String.starts_with?("#")))
  end

  # From `def <name>(` to the next top-level `defp`, which is what follows this function.
  defp function_source!(source, name) do
    [_head, rest] = String.split(source, "\n  def #{name}(", parts: 2)

    case String.split(rest, "\n  defp ", parts: 2) do
      [body, _] -> body
      [body] -> body
    end
  end
end
