defmodule Loopctl.Delivery.StagesNestingGuardTest do
  @moduledoc """
  A SOURCE guard for the one defect class this suite is structurally blind to.

  `Loopctl.Repo.with_tenant/2` refuses to be nested inside a `Repo` transaction, and
  `Loopctl.Delivery.Stages.advance/4` calls it — so a caller that wraps `advance/4` in
  `Repo.transaction/1` raises in production. No test can catch that by RUNNING it:
  `Loopctl.Repo`'s own comment says the guard is inert under the SQL sandbox, "i.e. for the
  entire test suite ... actual nesting must be verified by inspection or in dev/prod".

  "By inspection" is not a mechanism, and it failed the first time it was relied on: contract
  1.9.0's verdict path shipped through a review with `Stages.advance/4` inside a
  `Repo.transaction/1`, green on every test, and would have raised out of `handle_in/3` on the
  first real verdict and taken the channel down with every session on it.

  So this reads the SOURCE instead. It is deliberately crude — it flags a file that calls both
  in the same module rather than proving a call path — because the realistic mistake is
  writing the two together, and a guard that only catches what a whole-program analysis could
  prove would catch nothing at all.

  ## If this fails

  Do not wrap the transition. `Stages.advance/4` owns its transaction by design, so the fix is
  to sequence the work and make the RETRY converge — which is what `Loopctl.Delivery.TriageVerdict`
  does: it records first, transitions second, and its replay path re-attempts the transitions
  rather than trusting the record.

  The allow-list is empty and should stay that way: no module legitimately wraps a transition.
  """

  use ExUnit.Case, async: true

  # Files allowed to contain both, with the reason. Empty today, and that is the point: no
  # module legitimately wraps a transition. An entry here needs a reason a reader can check.
  @allowed %{}

  test "no module wraps Stages.advance/4 in a Repo transaction" do
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(&1 |> File.read!() |> calls_both?()))
      |> Enum.reject(&Map.has_key?(@allowed, &1))

    assert offenders == [],
           """
           These files call Stages.advance/4 AND open a Repo transaction:

           #{Enum.map_join(offenders, "\n", &("  " <> &1))}

           `advance/4` calls `Repo.with_tenant/2`, which raises when nested — and the SQL
           sandbox makes that guard inert, so every test will pass while production crashes.
           Sequence the work and make the retry converge instead; see this module's doc.
           """
  end

  test "the PREDICATE is not vacuous, on sources written for it" do
    # The scan clears every file in `lib/`, so on its own it is indistinguishable from a
    # predicate that matches nothing — which is the inert-guard shape this whole file exists
    # to prevent, one level up. There is no real file that legitimately does both, so the
    # positive control is written here rather than allow-listed.
    assert calls_both?("""
           def f do
             Repo.transaction(fn -> Stages.advance(tenant_id, story_id, t, opts) end)
           end
           """)

    refute calls_both?("def f, do: Stages.advance(tenant_id, story_id, t, opts)")
    refute calls_both?("def f, do: Repo.transaction(fn -> Repo.insert(changeset) end)")
  end

  defp calls_both?(source) when is_binary(source) do
    String.contains?(source, "Stages.advance(") and String.contains?(source, "Repo.transaction(")
  end
end
