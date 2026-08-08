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

  import ExUnit.CaptureLog

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.Consolidation
  alias Loopctl.SystemConfig
  alias Loopctl.Workers.KnowledgeLintWorker

  @keys ~w(
    knowledge_consolidation_max_applies
    knowledge_consolidation_max_unpublishes
    knowledge_consolidation_max_per_class
    knowledge_consolidation_min_duplicate_similarity_pct
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

  describe "the duplicate-similarity threshold is the same kind of lever" do
    test "a DB row moves the content gate live, with no redeploy" do
      # This threshold decides whether the only self-writing class applies anything at all.
      # Until #617 it was `Application.get_env/3` only, so an operator watching an
      # auto-unpublish behave wrong could move it only by deploying.
      tenant = fixture(:tenant)
      winner = publish!(tenant.id, "Lever Doc", String.duplicate("long ", 40))
      loser = publish!(tenant.id, "lever doc!", "short")

      # Cosine 0.6 — below the default 0.80, so the group is withheld until the lever moves.
      embed!(tenant.id, winner, [1.0 | List.duplicate(0.0, 1535)])
      embed!(tenant.id, loser, [0.6, 0.8 | List.duplicate(0.0, 1534)])

      {:ok, _} = Consolidation.run(tenant.id, day: Date.add(Date.utc_today(), -1))
      {:ok, _} = Consolidation.run(tenant.id)

      assert %{applied: 0, uncorroborated: 1} =
               Consolidation.apply_confirmed_duplicates(tenant.id)

      {:ok, _} = SystemConfig.put("knowledge_consolidation_min_duplicate_similarity_pct", 50)

      assert %{applied: 1, uncorroborated: 0} =
               Consolidation.apply_confirmed_duplicates(tenant.id)

      assert AdminRepo.get!(Article, loser).status == :draft
    end

    test "0 does NOT mean 'off' here — it is refused, not honoured as a pause" do
      # The sibling drain caps read 0 as an explicit pause, so 0 is the value an operator
      # reaches for to "turn the corroboration gate off". On THIS knob it does the
      # opposite: `min_sim >= 0.0` holds for every pair, so every title collision would
      # auto-unpublish with no content evidence at all. It falls back to the app layer.
      tenant = fixture(:tenant)
      winner = publish!(tenant.id, "Off Switch", String.duplicate("long ", 40))
      loser = publish!(tenant.id, "off switch!", "short")

      embed!(tenant.id, winner, [1.0 | List.duplicate(0.0, 1535)])
      embed!(tenant.id, loser, [0.0, 1.0 | List.duplicate(0.0, 1534)])

      {:ok, _} = Consolidation.run(tenant.id, day: Date.add(Date.utc_today(), -1))
      {:ok, _} = Consolidation.run(tenant.id)
      {:ok, _} = SystemConfig.put("knowledge_consolidation_min_duplicate_similarity_pct", 0)

      assert %{applied: 0, uncorroborated: 1} =
               Consolidation.apply_confirmed_duplicates(tenant.id)

      assert AdminRepo.get!(Article, loser).status == :published
    end

    test "100 or more DISABLES the class instead of quietly re-enabling it at the default" do
      # An impossible threshold has one reading: an operator shutting the auto-applying
      # class down mid-incident, without a deploy. Treating it as out-of-range and falling
      # back did the OPPOSITE of what was asked — it re-enabled auto-unpublish at 0.80 on
      # the very knob just set to stop it. So it is honoured: no cosine can reach it.
      tenant = fixture(:tenant)
      winner = publish!(tenant.id, "Hard Stop", String.duplicate("long ", 40))
      loser = publish!(tenant.id, "hard stop!", "short")

      # Byte-identical vectors: cosine 1.0, which corroborates at every honourable
      # threshold. Only a genuine disable withholds this pair.
      embed!(tenant.id, winner, [1.0 | List.duplicate(0.0, 1535)])
      embed!(tenant.id, loser, [1.0 | List.duplicate(0.0, 1535)])

      {:ok, _} = Consolidation.run(tenant.id, day: Date.add(Date.utc_today(), -1))
      {:ok, _} = Consolidation.run(tenant.id)
      {:ok, _} = SystemConfig.put("knowledge_consolidation_min_duplicate_similarity_pct", 100)

      assert %{applied: 0, uncorroborated: 1} =
               Consolidation.apply_confirmed_duplicates(tenant.id)

      assert AdminRepo.get!(Article, loser).status == :published
    end

    test "a STORED value is never mistaken for an unset one, even at the old sentinel" do
      # The percent was read with a `-1` sentinel default, so a row STORING -1 was
      # indistinguishable from no row: the operator's value was dropped in silence and the
      # app layer answered as if nothing had been configured. Presence is now answered on
      # its own terms, so an out-of-range STORED value is refused OUT LOUD (and still falls
      # back — below the range is the conservative direction) rather than vanishing.
      {:ok, _} = SystemConfig.put("knowledge_consolidation_min_duplicate_similarity_pct", -1)

      tenant = fixture(:tenant)
      winner = publish!(tenant.id, "Sentinel Doc", String.duplicate("long ", 40))
      loser = publish!(tenant.id, "sentinel doc!", "short")

      embed!(tenant.id, winner, [1.0 | List.duplicate(0.0, 1535)])
      embed!(tenant.id, loser, [1.0 | List.duplicate(0.0, 1535)])

      {:ok, _} = Consolidation.run(tenant.id, day: Date.add(Date.utc_today(), -1))
      {:ok, _} = Consolidation.run(tenant.id)

      log =
        capture_log(fn ->
          assert %{applied: 1} = Consolidation.apply_confirmed_duplicates(tenant.id)
        end)

      assert log =~ "ignoring duplicate similarity percent -1"
    end
  end

  defp publish!(tenant_id, title, body) do
    fixture(:article, %{tenant_id: tenant_id, title: title, body: body, category: :pattern})
    |> Ecto.Changeset.change(%{status: :published})
    |> AdminRepo.update!()
    |> Map.fetch!(:id)
  end

  defp embed!(tenant_id, id, vector),
    do: {:ok, _} = Knowledge.update_embedding(tenant_id, id, vector, nil)

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
