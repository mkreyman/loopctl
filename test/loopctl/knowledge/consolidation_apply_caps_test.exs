defmodule Loopctl.Knowledge.ConsolidationApplyCapsTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.Consolidation

  # Published articles are written as draft-then-update so the inline embedding -> linking
  # cascade never fires: every signal exercised here is lexical, never vector.
  defp published(tenant_id, attrs) do
    base = %{category: :pattern, tags: [], body: "Body #{System.unique_integer([:positive])}."}

    fixture(:article, Map.merge(base, Map.put(attrs, :tenant_id, tenant_id)))
    |> Ecto.Changeset.change(%{status: :published})
    |> AdminRepo.update!()
  end

  defp status(id), do: AdminRepo.get!(Article, id).status

  defp confirm_over_two_nights(tenant_id) do
    corroborate_all!(tenant_id)
    {:ok, _} = Consolidation.run(tenant_id, day: Date.add(Date.utc_today(), -1))
    {:ok, _} = Consolidation.run(tenant_id)
  end

  # These groups are GENUINE duplicates, so give them identical embeddings (cosine 1.0). The
  # apply path withholds a title-drift group whose bodies do not corroborate the shared title;
  # without this every budget test here would measure that gate instead of the budget.
  defp corroborate_all!(tenant_id) do
    vector = List.duplicate(0.1, 1536)

    Article
    |> Ecto.Query.where([a], a.tenant_id == ^tenant_id)
    |> AdminRepo.all()
    |> Enum.each(fn a ->
      {:ok, _} = Loopctl.Knowledge.update_embedding(tenant_id, a.id, vector, nil)
    end)
  end

  # One confirmed group of three: a winner and two losers, so the article budget can bind
  # WITHIN a group rather than only between groups.
  defp confirmed_trio(tenant_id) do
    winner =
      published(tenant_id, %{
        title: "Cap Group Doc",
        body: String.duplicate("long winner body ", 20)
      })

    middle = published(tenant_id, %{title: "cap-group-doc!", body: String.duplicate("mid ", 5)})
    shortest = published(tenant_id, %{title: "CAP GROUP DOC.", body: "s"})

    confirm_over_two_nights(tenant_id)
    {winner, [middle, shortest]}
  end

  describe "apply_confirmed_duplicates/2 — the article budget (#611 review round 2)" do
    test "drains a group larger than the budget as far as the budget goes, and converges" do
      # Skipping such a group WHOLE made any group with more losers than the cap unappliable
      # on every run forever, and with the cap itself ceilinged at 500 the "raise the cap"
      # remedy was unreachable — the backlog held a floor. Draining part-way is safe because
      # the winner is never a candidate: what is left behind is winner-plus-leftovers, the
      # same group the next scan re-derives.
      tenant = fixture(:tenant)
      {winner, losers} = confirmed_trio(tenant.id)

      assert %{applied: 1, skipped: 0, failed: 0, gate: :open} =
               Consolidation.apply_confirmed_duplicates(tenant.id, max_unpublishes: 1)

      assert status(winner.id) == :published
      assert Enum.count(losers, &(status(&1.id) == :published)) == 1

      # And the cap is still a real BOUND: exactly one loser left the published set, not both.
      # The next run's budget finishes the group off.
      assert %{applied: 1} =
               Consolidation.apply_confirmed_duplicates(tenant.id, max_unpublishes: 1)

      assert status(winner.id) == :published
      refute Enum.any?(losers, &(status(&1.id) == :published))
    end

    test "a cap of 0 PAUSES the drain instead of being rounded up to one group's worth" do
      # Halting the drain mid-incident is the reason an operator sets 0. Clamping it to 1
      # kept unpublishing, and the audit event read like a clean night while doing it.
      tenant = fixture(:tenant)
      {winner, losers} = confirmed_trio(tenant.id)

      assert %{applied: 0, skipped: 0, failed: 0, gate: :drain_disabled} =
               Consolidation.apply_confirmed_duplicates(tenant.id, max_unpublishes: 0)

      assert status(winner.id) == :published
      assert Enum.all?(losers, &(status(&1.id) == :published))
    end

    test "a negative or non-integer cap never reaches the query" do
      # A negative `:max_applies` reached `limit: ^cap` as a Postgrex error. A binary is the
      # worse half: Erlang term order sorts it ABOVE every integer, so an unguarded
      # `min(cap, 500)` handed a config typo the ceiling — the largest blast radius there is.
      tenant = fixture(:tenant)
      {winner, losers} = confirmed_trio(tenant.id)

      assert %{applied: 0, gate: :drain_disabled} =
               Consolidation.apply_confirmed_duplicates(tenant.id, max_applies: -1)

      assert Enum.all?(losers, &(status(&1.id) == :published))

      # "1" falls back to the module default (100), NOT to the 500 ceiling.
      assert %{applied: 2, gate: :open} =
               Consolidation.apply_confirmed_duplicates(tenant.id, max_unpublishes: "1")

      assert status(winner.id) == :published
    end
  end

  describe "latest/2 — an article turned PRIVATE after the scan" do
    test "redacts the excerpt a prior report quoted from it" do
      # The quiet harm the visibility guard exists for: the report carries a quoted body and
      # any orchestrator key can read it, so a published article that later becomes an agent's
      # private memory must redact exactly like an archived one.
      tenant = fixture(:tenant)

      article =
        published(tenant.id, %{title: "Untitled Document", body: "SECRET harvested material."})

      {:ok, _} = Consolidation.run(tenant.id)

      {:ok, before} = Consolidation.latest(tenant.id)
      assert [%{evidence: [entry]}] = before.proposals
      assert entry["excerpt"] =~ "SECRET harvested"

      article
      |> Ecto.Changeset.change(%{
        metadata: %{"visibility" => "private", "agent_id" => Ecto.UUID.generate()}
      })
      |> AdminRepo.update!()

      {:ok, result} = Consolidation.latest(tenant.id)
      assert [%{evidence: [redacted]}] = result.proposals
      assert redacted["redacted"] == true
      assert redacted["excerpt"] == ""
    end
  end
end
