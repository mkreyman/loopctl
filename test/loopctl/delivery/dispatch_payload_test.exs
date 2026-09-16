defmodule Loopctl.Delivery.DispatchPayloadTest do
  @moduledoc """
  Story 846.2: the branch a dispatch carries is DERIVED from what the target runner declared,
  and it is derived in ONE place.

  These are the pure halves — `branch_for/2` and `branch_allowed?/2` — asserted against a
  bare `%Story{}` with no database at all. The WIRING (that a placement reads the declaration
  off the live socket and hands it to this derivation) is in
  `Loopctl.Delivery.PlacementTest`, because a derivation that is correct and never called is
  exactly the defect this story exists to fix.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Delivery.DispatchPayload
  alias Loopctl.WorkBreakdown.Story

  @story %Story{number: 7, id: "a1b2c3d4-e5f6-4789-abcd-ef0123456789"}
  @suffix "story-7-a1b2c3d4"

  describe "branch_for/2 with NO declaration" do
    # AC-1's other half, stated as an equality rather than as a literal. A runner that
    # declares nothing must be placed on EXACTLY as it was before this field existed, and the
    # un-prefixed call is the shape every caller used then.
    test "an empty declaration derives what the no-argument call derives" do
      assert DispatchPayload.branch_for(@story, []) == DispatchPayload.branch_for(@story)
    end

    test "that name is the one loopctl has always sent" do
      assert DispatchPayload.branch_for(@story, []) == {:ok, "feature/" <> @suffix}
    end

    # The list may reach here from a Presence meta rather than from `cast_join/1`, so an
    # entry the cast would have refused is treated as no usable declaration rather than as a
    # prefix to concatenate.
    test "a declaration of only non-strings is no declaration" do
      assert DispatchPayload.branch_for(@story, [3, nil]) == {:ok, "feature/" <> @suffix}
    end
  end

  describe "branch_for/2 with a declaration" do
    # AC-4. This is the failure the story is written from: minis declares `loop/` and loopctl
    # sent `feature/...`, which the machine refused `branch_not_allowed`.
    test "the derived branch starts with the declared prefix" do
      assert DispatchPayload.branch_for(@story, ["loop/"]) == {:ok, "loop/" <> @suffix}
    end

    # AC-5. The prefix changes; the part that makes the name unique never does.
    test "the story number and the id fragment survive every prefix" do
      for prefix <- ["loop/", "agent-work/", "x", "a/b/c/"] do
        assert {:ok, branch} = DispatchPayload.branch_for(@story, [prefix])
        assert String.starts_with?(branch, prefix)
        assert String.ends_with?(branch, @suffix)
      end
    end

    # Two stories on ONE repository can never be handed one branch — the property AC-5 is
    # actually about, which a single-story assertion cannot show.
    test "two stories under one prefix get two branches" do
      other = %Story{number: 7, id: "99999999-e5f6-4789-abcd-ef0123456789"}
      same_number_different_id = DispatchPayload.branch_for(other, ["loop/"])

      assert DispatchPayload.branch_for(@story, ["loop/"]) != same_number_different_id
    end

    test "the FIRST usable prefix wins, so a retry re-derives one name" do
      assert DispatchPayload.branch_for(@story, ["loop/", "feature/"]) ==
               {:ok, "loop/" <> @suffix}

      assert DispatchPayload.branch_for(@story, ["feature/", "loop/"]) ==
               {:ok, "feature/" <> @suffix}
    end

    test "a later prefix is the fallback when the first cannot produce a valid name" do
      assert DispatchPayload.branch_for(@story, ["bad//", "loop/"]) == {:ok, "loop/" <> @suffix}
    end
  end

  describe "branch_for/2 when uniqueness and the declaration cannot both be satisfied" do
    # The suffix is NEVER shortened to make a prefix fit: shortening it is what would let two
    # stories share a branch, so an unsatisfiable declaration is a refusal.
    test "an over-long prefix refuses rather than truncating the unique part" do
      long = String.duplicate("a", 200) <> "/"

      assert DispatchPayload.branch_for(@story, [long]) ==
               {:error, {:no_conforming_branch, [long]}}
    end

    test "a prefix that cannot be part of a git ref name refuses" do
      for bad <- ["loop//", "../", "-o", "loop/\n", "loop/.."] do
        assert {:error, {:no_conforming_branch, [^bad]}} =
                 DispatchPayload.branch_for(@story, [bad]),
               "#{inspect(bad)} produced a branch name"
      end
    end

    # 846.2 REVIEW FINDING 4. Every one of these is admitted by `@branch_name` (which allows
    # `.`) and produces a name git REFUSES, and none was checked: the guard standing in for
    # them tested `String.ends_with?(branch, ".lock")` against the WHOLE composed name, which
    # always ends with the `story-N-<id8>` suffix, so it could not fire for any input this
    # function receives. Git's rules are per-COMPONENT and that is where they are applied now.
    test "a prefix breaking a git rule on a PATH COMPONENT refuses" do
      for bad <- ["x.lock/", "a/.b/", "a/x.lock/", "a/b./"] do
        assert {:error, {:no_conforming_branch, [^bad]}} =
                 DispatchPayload.branch_for(@story, [bad]),
               "#{inspect(bad)} produced a branch name git refuses"
      end
    end

    # The other half of finding 4, and the reason the component rules did not simply replace
    # the `..` check: `a..b` is ONE component, breaks no component rule, and git refuses the
    # ref anyway.
    test "`..` inside a single component still refuses" do
      assert {:error, {:no_conforming_branch, ["a..b/"]}} =
               DispatchPayload.branch_for(@story, ["a..b/"])
    end

    test "the refusal names the prefixes, which is the fact an operator cannot otherwise read" do
      assert {:error, {:no_conforming_branch, ["loop//", "-x"]}} =
               DispatchPayload.branch_for(@story, ["loop//", "-x"])
    end
  end

  describe "branch_allowed?/2" do
    test "no declaration allows any branch, which is the pre-1.14.0 behaviour" do
      assert DispatchPayload.branch_allowed?("anything/at/all", [])
    end

    test "a conforming branch is allowed and a non-conforming one is not" do
      assert DispatchPayload.branch_allowed?("loop/story-7", ["loop/"])
      refute DispatchPayload.branch_allowed?("feature/story-7", ["loop/"])
    end

    test "any declared prefix will do, not only the first" do
      assert DispatchPayload.branch_allowed?("feature/x", ["loop/", "feature/"])
    end
  end
end
