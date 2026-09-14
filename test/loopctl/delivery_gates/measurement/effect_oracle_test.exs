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

    test "a HEX DIGEST containing 837 does not fire :edi" do
      # Bounded by decimal digits alone this matched inside `a837f`, so any diff full of content
      # hashes read as EDI. That is not the declared over-flag bias, it is a bug.
      assert {:ok, %{effect_bearing?: false}} =
               EffectOracle.judge(~s|  @digest "9e2db568a837f5c5f793ed102b5485d5832af9e2"|)
    end

    test "a PLAIN DECIMAL integer containing 837 or 835 does not fire :edi" do
      # Widening the bound to admit `era835` let every ordinary integer through: `18370`,
      # `8350`, `8375` and a version string all matched. A transaction number never has a
      # decimal digit, a dot or a hyphen touching it.
      for line <- [
            "      total = 18370",
            "      timeout: 8350,",
            "      port: 8375",
            ~s|      @version "1.0.837"|,
            "      id: 9837"
          ] do
        assert {:ok, %{effect_bearing?: false}} = EffectOracle.judge(line),
               "expected no :edi signal from #{line}"
      end
    end

    test "a hyphen-separated UUID segment does not fire :edi" do
      assert {:ok, %{effect_bearing?: false}} =
               EffectOracle.judge(~s|  @id "9e2db568-a837-4f79-b12c-5485d5832af9"|)
    end

    test "a domain spelling whose neighbour is a hex LETTER still fires :edi" do
      # `era835`: bounding by a SINGLE hex character rejected this, because `a` is hex — and
      # that silently dropped a real claims-path false negative between two runs. The bound is a
      # RUN of two hex characters, which is a digest rather than a name.
      assert {:ok, %{effect_bearing?: true, families: [:edi]}} =
               EffectOracle.judge("          next_step: :none | :ta1 | :era835,")
    end

    test "the bare word 'modifier' does not fire :billing_codes" do
      # It is ordinary programming vocabulary — a modifier function, a modifier key, a CSS
      # modifier. The DOMAIN sense always arrives qualified.
      assert {:ok, %{effect_bearing?: false}} =
               EffectOracle.judge("  def apply_modifier(assigns, modifier) do")
    end

    test "a QUALIFIED modifier does fire :billing_codes" do
      assert {:ok, %{effect_bearing?: true, families: [:billing_codes]}} =
               EffectOracle.judge("      hcpcs_modifier = row.modifier_code")
    end

    test "the SV1 field names and the bare PLURAL still fire :billing_codes" do
      # The first narrowing dropped these along with the bare singular, with no test pinning the
      # still-fires direction — the same gap that lost `era835`. `modifiers` is how the list is
      # spelled wherever it is a list of HCPCS modifiers.
      for line <- [
            "      modifier_1 = svc.modifier_2",
            "      modifier_3, modifier_4",
            "      modifiers = Enum.reject(svc.modifiers, &is_nil/1)"
          ] do
        assert {:ok, %{effect_bearing?: true, families: [:billing_codes]}} =
                 EffectOracle.judge(line),
               "expected a :billing_codes signal from #{line}"
      end
    end

    test "a literal HCPF modifier value fires :billing_codes" do
      assert {:ok, %{effect_bearing?: true, families: [:billing_codes]}} =
               EffectOracle.judge(~s|      @waiver_qualifier "U9"|)
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
