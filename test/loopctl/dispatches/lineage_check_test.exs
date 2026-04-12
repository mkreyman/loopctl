defmodule Loopctl.Dispatches.LineageCheckTest do
  @moduledoc """
  Tests for US-26.2.2 — lineage-based self-check and verifier selection.
  """

  use Loopctl.DataCase, async: true

  import Loopctl.Fixtures

  alias Loopctl.Dispatches

  setup :verify_on_exit!

  describe "lineage_shares_prefix?/2" do
    test "detects shared prefix between sibling dispatches" do
      # root -> orch -> impl and root -> orch -> rev share prefix at [root, orch]
      root = Ecto.UUID.generate()
      orch = Ecto.UUID.generate()
      impl = Ecto.UUID.generate()
      rev = Ecto.UUID.generate()

      impl_lineage = [root, orch, impl]
      rev_lineage = [root, orch, rev]

      assert Dispatches.lineage_shares_prefix?(impl_lineage, rev_lineage)
    end

    test "detects non-overlapping lineages from different roots" do
      root_a = Ecto.UUID.generate()
      impl = Ecto.UUID.generate()
      root_b = Ecto.UUID.generate()
      rev = Ecto.UUID.generate()

      refute Dispatches.lineage_shares_prefix?([root_a, impl], [root_b, rev])
    end

    test "handles empty lineages" do
      refute Dispatches.lineage_shares_prefix?([], [Ecto.UUID.generate()])
      refute Dispatches.lineage_shares_prefix?([Ecto.UUID.generate()], [])
      refute Dispatches.lineage_shares_prefix?([], [])
    end

    test "single-element lineages from the same root share prefix" do
      root = Ecto.UUID.generate()
      assert Dispatches.lineage_shares_prefix?([root], [root])
    end
  end

  describe "story dispatch fields" do
    test "stories have implementer_dispatch_id and verifier_dispatch_id fields" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      assert story.implementer_dispatch_id == nil
      assert story.verifier_dispatch_id == nil
      assert story.verifier_needed == false
    end
  end
end
