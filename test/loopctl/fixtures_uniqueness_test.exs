defmodule Loopctl.FixturesUniquenessTest do
  @moduledoc """
  Regression guard for the fixture-generated uniqueness sources.

  These fixtures previously derived story numbers from a modulo truncation
  (`"1.\#{rem(System.unique_integer([:positive]), 9999) + 1}"`), which is
  non-injective: two distinct seqs congruent mod 9999 — or a project with more
  than 9999 stories — produced the same `number`, intermittently tripping the
  `stories_tenant_id_project_id_number_index` unique constraint under parallel
  load. Tenant `slug`/`email` were already unique-per-VM via
  `System.unique_integer/1`; these tests pin BOTH invariants so a regression to
  a collidable generator (modulo / timestamp / plain counter) fails loudly.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.WorkBreakdown.Story

  describe "next_story_number/0" do
    test "returns only distinct, format-valid numbers across a large batch" do
      numbers = for _ <- 1..5_000, do: Loopctl.Fixtures.next_story_number()

      assert length(Enum.uniq(numbers)) == 5_000,
             "next_story_number/0 must never repeat within a VM run"

      for number <- numbers do
        parts = String.split(number, ".")
        assert length(parts) == 2

        for part <- parts do
          {n, ""} = Integer.parse(part)
          assert n >= 0 and n < 10_000, "each part must satisfy Story's <10000 format rule"
        end
      end
    end

    test "generated numbers never collide with small hard-coded numbers" do
      # Tests routinely insert explicit "1.1", "2.3", "72.3", … — generated
      # numbers use a high major (>= 1000) so they can never collide with those.
      numbers = for _ <- 1..2_000, do: Loopctl.Fixtures.next_story_number()

      majors =
        Enum.map(numbers, fn n -> n |> String.split(".") |> hd() |> String.to_integer() end)

      assert Enum.min(majors) >= 1_000
    end
  end

  describe "story number uniqueness within a (tenant, project)" do
    test "inserting many fixture stories in one project never collides" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      stories =
        for _ <- 1..300 do
          fixture(:story, %{
            tenant_id: tenant.id,
            project_id: project.id,
            epic_id: epic.id
          })
        end

      numbers = Enum.map(stories, & &1.number)

      assert length(Enum.uniq(numbers)) == 300

      # And the constraint really is satisfied at the DB level.
      persisted =
        Story
        |> where([s], s.project_id == ^project.id)
        |> Loopctl.AdminRepo.all()

      assert length(persisted) == 300
    end
  end

  describe "tenant slug/email uniqueness" do
    test "building many tenants yields distinct slugs and emails" do
      tenants = for _ <- 1..500, do: fixture(:tenant)

      slugs = Enum.map(tenants, & &1.slug)
      emails = Enum.map(tenants, & &1.email)

      assert length(Enum.uniq(slugs)) == 500
      assert length(Enum.uniq(emails)) == 500
    end
  end
end
