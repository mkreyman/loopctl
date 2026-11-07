defmodule Loopctl.Agents.KindPredicatesTest do
  @moduledoc """
  US-48.6: every "is this an implement session" check, every budget lookup and every kind
  default now asks the agent spec, and agrees with the code it replaced.

  THE ORACLE IS THE OLD CODE, COPIED. `old_*` below are the pre-US-48.6 bodies of
  `DispatchLedger.implement_kind?/1`, `DispatchLedger.where_implement_kind/1`'s kind list,
  `DispatchLedger.kind_answers?/2`'s `:implement` clause, `DispatchPayload.budget_keys/1` and
  the `"implement"` literals `fill/3` and `accepted_session/4` defaulted to. This file was run
  green against those functions before they were replaced, and is the equivalence the
  replacement is held to (AC-48.6.2).

  The one deliberate divergence is AC-48.6.3: a kind no spec describes used to spend the
  implement budget, and now gets none. It is asserted on its own, so the agreement property
  cannot silently absorb it.

  No tenant isolation case for the predicates, which read no tenant data; the `fill/3` cases
  run inside one tenant's story.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.Agents.Registry
  alias Loopctl.Agents.Spec
  alias Loopctl.Delivery.DispatchDriver
  alias Loopctl.Delivery.DispatchPayload
  alias Loopctl.Runners.DispatchLedger

  # ── the oracle: the pre-US-48.6 code, verbatim ─────────────────────────────────────────────

  @old_implement_kinds ["implement"]
  @old_default_kind "implement"

  # Registry kinds the oracle predates: added by a later story, so not in its budget table.
  @kinds_added_since ["reply_draft", "verify", "spec_tune"]

  defp old_implement_kind?(kind), do: is_nil(kind) or kind in @old_implement_kinds

  defp old_kind_answers?(_kind, :any), do: true
  defp old_kind_answers?(kind, :implement), do: old_implement_kind?(kind)
  defp old_kind_answers?(kind, wanted) when is_binary(wanted), do: kind == wanted

  defp old_budget_keys("triage"), do: {:triage_wall_clock_seconds, :triage_max_turns}
  defp old_budget_keys(_implement), do: {:dispatch_wall_clock_seconds, :dispatch_max_turns}

  # ── the generated kinds ────────────────────────────────────────────────────────────────────

  # Kinds no spec describes: a plausible future kind, case and whitespace variants of a real
  # one, the empty string, and a few random lower-case names.
  defp unknown_kinds do
    random =
      for _ <- 1..8 do
        "k" <> (:crypto.strong_rand_bytes(6) |> Base.encode32(case: :lower, padding: false))
      end

    ["review", "summary_draft", "IMPLEMENT", "Triage", "implement ", " triage", ""] ++ random
  end

  defp registry_kinds do
    kinds = Registry.kinds()
    # Non-vacuous: both of today's kinds are generated.
    assert "implement" in kinds and "triage" in kinds
    kinds
  end

  defp all_kinds, do: registry_kinds() ++ [nil] ++ unknown_kinds()

  # ── TC-48.6.1: predicate agreement ─────────────────────────────────────────────────────────

  describe "the new predicates agree with the old (TC-48.6.1, AC-48.6.2)" do
    test "Spec.holds_claim?/1 == implement_kind?/1 for every kind, nil and unknown ones" do
      for kind <- all_kinds() do
        assert Spec.holds_claim?(kind) == old_implement_kind?(kind), inspect(kind)
      end
    end

    test "kind_answers?/2's default (:holds_claim) == the old :implement, and the rest agree" do
      for kind <- all_kinds(), wanted <- [:any | registry_kinds()] do
        assert DispatchLedger.kind_answers?(kind, wanted) == old_kind_answers?(kind, wanted),
               "#{inspect(kind)} for #{inspect(wanted)}"
      end

      for kind <- all_kinds() do
        assert DispatchLedger.kind_answers?(kind, :holds_claim) ==
                 old_kind_answers?(kind, :implement),
               inspect(kind)
      end
    end

    # `where_holds_claim/1` is `is_nil(kind) or kind in claim_holding_kinds()` exactly when
    # `holds_claim?(nil)`, so its rows agree with the old filter iff these two agree.
    test "the query filter's kind list and NULL reading == the old filter's" do
      assert Registry.claim_holding_kinds() == @old_implement_kinds
      assert Spec.holds_claim?(nil) == old_implement_kind?(nil)

      for kind <- registry_kinds() do
        assert kind in Registry.claim_holding_kinds() == old_implement_kind?(kind), kind
      end
    end

    # The oracle knows the kinds that existed when it was copied. A kind added since has no
    # old pair to agree with — the old code would have charged it the implement budget, the
    # AC-48.6.3 divergence — so each one states its own below.
    test "budget_keys/1 == the old pair for every kind the oracle knew, and nil" do
      for kind <- (registry_kinds() -- @kinds_added_since) ++ [nil] do
        assert DispatchPayload.budget_keys(kind) == {:ok, old_budget_keys(kind)}, inspect(kind)
      end
    end

    test "US-48.9: reply_draft spends the triage budget, a pass that reads one report" do
      assert "reply_draft" in registry_kinds()

      assert DispatchPayload.budget_keys("reply_draft") ==
               {:ok, {:triage_wall_clock_seconds, :triage_max_turns}}

      refute Spec.holds_claim?("reply_draft")
    end

    test "US-48.13: spec_tune spends its own budget and holds no claim" do
      assert "spec_tune" in registry_kinds()

      assert DispatchPayload.budget_keys("spec_tune") ==
               {:ok, {:spec_tune_wall_clock_seconds, :spec_tune_max_turns}}

      refute Spec.holds_claim?("spec_tune")
    end

    test "the default kind (fill/3, a nil ledger row) == the old literal" do
      assert Registry.default_kind() == @old_default_kind
      assert Spec.holds_claim?(Registry.default_kind())
    end

    test "holds_claim? asks the archetype: :build holds a claim, every other archetype none" do
      for spec <- Registry.all() do
        assert Spec.holds_claim?(spec) == (spec.archetype == :build), spec.id
        assert Spec.holds_claim?(spec.kind) == Spec.holds_claim?(spec), spec.id
      end
    end
  end

  # ── TC-48.6.2: an unknown kind fails closed ────────────────────────────────────────────────

  describe "an unknown kind fails closed (TC-48.6.2, AC-48.6.3)" do
    test "it holds no claim and has no budget keys" do
      for kind <- unknown_kinds() do
        refute Spec.holds_claim?(kind), inspect(kind)
        refute DispatchLedger.kind_answers?(kind, :holds_claim), inspect(kind)
        assert DispatchPayload.budget_keys(kind) == {:error, :unknown_kind}, inspect(kind)
      end
    end

    test "a value that is not a kind at all holds no claim and has no budget" do
      for value <- [:implement, 1, %{}, ["implement"]] do
        refute Spec.holds_claim?(value), inspect(value)
        assert DispatchPayload.budget_keys(value) == {:error, :unknown_kind}, inspect(value)
      end
    end
  end

  # ── fill/3: the default kind and the budget it spends against ──────────────────────────────

  describe "fill/3 reads the kind's budget from its spec" do
    setup do
      tenant = fixture(:tenant)
      story = fixture(:ledger_story, %{tenant_id: tenant.id})

      payload =
        :placement_dispatch
        |> build(%{"story_id" => story.id})
        |> Map.drop(["wall_clock_seconds", "max_turns"])

      %{tenant: tenant, payload: payload}
    end

    # What the old code filled for `keys`: the pair read through the same reader.
    defp old_fill_budgets({clock_key, turns_key}) do
      with {:ok, seconds} <- read_budget(clock_key),
           {:ok, turns} <- read_budget(turns_key) do
        {:ok, {seconds, turns}}
      end
    end

    defp read_budget(key),
      do: DispatchDriver.normalise_budget(Application.get_env(:loopctl, key), key)

    defp filled_budgets({:ok, filled}),
      do: {:ok, {filled["wall_clock_seconds"], filled["max_turns"]}}

    defp filled_budgets({:error, _reason} = error), do: error

    test "an absent, nil, implement or triage kind fills what the old code filled", ctx do
      cases = [
        {Map.delete(ctx.payload, "kind"), old_budget_keys(@old_default_kind)},
        {Map.put(ctx.payload, "kind", nil), old_budget_keys(nil)},
        {Map.put(ctx.payload, "kind", "implement"), old_budget_keys("implement")},
        {Map.put(ctx.payload, "kind", "triage"), old_budget_keys("triage")}
      ]

      for {payload, old_keys} <- cases do
        assert filled_budgets(DispatchPayload.fill(ctx.tenant.id, payload)) ==
                 old_fill_budgets(old_keys),
               inspect(payload["kind"])
      end
    end

    test "an unknown kind is refused before any budget is read", ctx do
      payload = Map.put(ctx.payload, "kind", "review")

      assert {:error, {:invalid, [message]}} = DispatchPayload.fill(ctx.tenant.id, payload)
      assert message =~ ~s("review")
      assert message =~ "no budget"
    end

    test "another tenant's story is not found, whatever the kind", ctx do
      other = fixture(:tenant)

      for kind <- ["implement", "review"] do
        assert DispatchPayload.fill(other.id, Map.put(ctx.payload, "kind", kind)) ==
                 {:error, :story_not_found}
      end
    end
  end
end
