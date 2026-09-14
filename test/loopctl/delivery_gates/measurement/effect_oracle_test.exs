defmodule Loopctl.DeliveryGates.Measurement.EffectOracleTest do
  use ExUnit.Case, async: true

  alias Loopctl.DeliveryGates.Measurement.EffectOracle

  # No tenant appears anywhere in the measurement harness: it is pure, reads no database and
  # takes no tenant_id, so there is nothing for a tenant-isolation case to isolate.

  describe "judge/1 — each signal family fires on its own" do
    test "edi: a quoted segment identifier" do
      assert {:ok, %{effect_bearing?: true, families: [:edi]}} =
               EffectOracle.judge(~s|      segment("CLM", claim_id)|)
    end

    test "edi: an 837 transaction number" do
      assert {:ok, %{effect_bearing?: true, families: families}} =
               EffectOracle.judge("  def build_837(batch) do")

      assert :edi in families
    end

    test "billing_codes: a HCPCS-shaped literal" do
      assert {:ok, %{effect_bearing?: true, families: [:billing_codes]}} =
               EffectOracle.judge(~s|  @home_health "T1019"|)
    end

    test "rates: the fee schedule vocabulary" do
      assert {:ok, %{effect_bearing?: true, families: [:rates]}} =
               EffectOracle.judge("  fee_schedule_for(client, on: date)")
    end

    test "outbound: what carries the effect out of the building" do
      assert {:ok, %{effect_bearing?: true, families: [:outbound]}} =
               EffectOracle.judge("  {:ok, conn} = SFTP.connect(host)")
    end

    test "several families at once are all reported" do
      content = """
      -  @code "T1019"
      +  @code "T1020"
         Remittance.attach(claim)
      """

      assert {:ok, %{effect_bearing?: true, families: families}} = EffectOracle.judge(content)
      assert :billing_codes in families
      assert :outbound in families
    end
  end

  describe "judge/1 — silence" do
    test "ordinary code fires nothing" do
      content = """
      -  def render(assigns) do
      +  def render(%{user: user} = assigns) do
      """

      assert {:ok, %{effect_bearing?: false, families: []}} = EffectOracle.judge(content)
    end

    test "an empty diff fires nothing" do
      assert {:ok, %{effect_bearing?: false, families: []}} = EffectOracle.judge("")
    end

    test "a word that merely CONTAINS a token does not fire it" do
      # `era` inside `operation`, `st` inside `list` — the patterns are anchored, and an
      # unanchored version of this oracle would call every change effect-bearing.
      assert {:ok, %{effect_bearing?: false}} =
               EffectOracle.judge("  operations = Enum.map(list, &String.trim/1)")
    end
  end

  describe "judge/1 — refuses rather than guesses" do
    test "content that could not be read is an error, not an inert change" do
      assert {:error, :no_content} = EffectOracle.judge(nil)
      assert {:error, :no_content} = EffectOracle.judge(:unreadable)
      assert {:error, :no_content} = EffectOracle.judge(%{})
    end
  end

  test "families/0 names every family the report counts" do
    assert EffectOracle.families() == [:edi, :billing_codes, :rates, :outbound]
  end
end
