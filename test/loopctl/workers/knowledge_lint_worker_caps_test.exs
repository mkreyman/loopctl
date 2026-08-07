defmodule Loopctl.Workers.KnowledgeLintWorkerCapsTest do
  @moduledoc """
  The nightly's three consolidation caps are the ONLY lever that slows or stops the
  auto-unpublish drain, and until #617 the only way to move one was a deploy — an
  operator watching an apply go wrong had no way to halt it in the minutes that
  matter.

  `async: false` DELIBERATELY, for the same reason
  `Loopctl.ReleaseCustodyProfileTest` is: `SystemConfig.put/2` writes
  `:persistent_term`, which is VM-GLOBAL. Seeding a cap row from an `async: true`
  module would bleed that cap into every other test running concurrently. This is
  the documented exception to the repo's `async: true` rule, not a lapse from it —
  and it is why the production code reads the lever from the DB rather than from
  `Application.put_env/3`, which would have the same global-mutation problem in
  production as it does here.
  """

  use Loopctl.DataCase, async: false

  setup :verify_on_exit!

  alias Loopctl.SystemConfig
  alias Loopctl.Workers.KnowledgeLintWorker

  @keys ~w(
    knowledge_consolidation_max_applies
    knowledge_consolidation_max_unpublishes
    knowledge_consolidation_max_per_class
  )

  setup do
    on_exit(fn ->
      # The DB row dies with the sandbox transaction; the persistent_term does NOT.
      # Erasing it is what keeps this module from leaking a cap into the rest of the run.
      Enum.each(@keys, &:persistent_term.erase({SystemConfig, &1}))
    end)

    :ok
  end

  describe "cap resolution order: DB row -> app config -> module default" do
    test "with no DB row, the app config value is what the nightly uses" do
      # config/test.exs sets max_applies: 2 / max_unpublishes: 1. The SystemConfig
      # indirection must not change what a deployment without a row already saw.
      assert KnowledgeLintWorker.applies_cap() ==
               Application.get_env(:loopctl, :knowledge_consolidation_max_applies)

      assert KnowledgeLintWorker.unpublishes_cap() ==
               Application.get_env(:loopctl, :knowledge_consolidation_max_unpublishes)
    end

    test "the app config layer beats the module default when it is set" do
      # config/config.exs sets all three. The module default is the LAST resort, reached
      # only when neither a DB row nor an app config exists — see the coerce_int/2 block
      # below, which pins that leg without mutating VM-global state to remove the config.
      configured = Application.get_env(:loopctl, :knowledge_consolidation_max_per_class)

      assert is_integer(configured),
             "config/config.exs is expected to set :knowledge_consolidation_max_per_class"

      assert KnowledgeLintWorker.per_class_cap() == configured
    end

    test "a DB row OVERRIDES the app config, live, with no redeploy" do
      {:ok, _} = SystemConfig.put("knowledge_consolidation_max_applies", 7)
      {:ok, _} = SystemConfig.put("knowledge_consolidation_max_unpublishes", 9)
      {:ok, _} = SystemConfig.put("knowledge_consolidation_max_per_class", 11)

      assert KnowledgeLintWorker.applies_cap() == 7
      assert KnowledgeLintWorker.unpublishes_cap() == 9
      assert KnowledgeLintWorker.per_class_cap() == 11
    end

    test "0 is reachable through the lever — the operator HALT must survive the indirection" do
      # `apply_confirmed_duplicates/2` honours 0 as an explicit pause (`gate:
      # :drain_disabled`) rather than rounding it up. If the lever could not express 0,
      # the halt an operator reaches for mid-incident would not exist.
      {:ok, _} = SystemConfig.put("knowledge_consolidation_max_unpublishes", 0)

      assert KnowledgeLintWorker.unpublishes_cap() == 0
    end
  end

  describe "coerce_int/2 — the app-config layer is type-checked, not trusted" do
    test "a non-integer resolves to the default rather than raising" do
      # `SystemConfig.get_int/2` requires an INTEGER default and would raise a
      # FunctionClauseError on a `nil` or a `"25"`. Inside the nightly's rescue that
      # surfaces as a generic `apply_failed`, which reads as an outage rather than as the
      # config typo it is.
      for bad <- ["25", :all, 25.0, %{}, nil] do
        assert KnowledgeLintWorker.coerce_int(bad, 25) == 25
      end
    end

    test "an integer passes through untouched, including 0 and negatives" do
      # Clamping belongs to `Consolidation` (which distinguishes 0-as-pause from a typo);
      # this layer only guarantees the fallback chain cannot fault.
      for good <- [0, 1, -1, 500] do
        assert KnowledgeLintWorker.coerce_int(good, 25) == good
      end
    end
  end
end
