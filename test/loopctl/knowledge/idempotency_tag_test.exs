defmodule Loopctl.Knowledge.IdempotencyTagTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge.IdempotencyTag, as: Tag

  @hex12 "7ebe1ca33431"
  @hex40 String.duplicate("a1b2", 10)

  describe "reserved?/1" do
    test "matches on prefix regardless of shape" do
      assert Tag.reserved?("idem-url-#{@hex12}")
      assert Tag.reserved?("idem-design")
      assert Tag.reserved?("idem-")
    end

    test "does not match topical tags or the legacy bare form" do
      refute Tag.reserved?("url-design")
      refute Tag.reserved?("url-#{@hex12}")
      refute Tag.reserved?("idempotent")
      refute Tag.reserved?(nil)
      refute Tag.reserved?(123)
    end
  end

  describe "well_formed?/1" do
    test "accepts both digest eras" do
      assert Tag.well_formed?("idem-url-#{@hex12}")
      assert Tag.well_formed?("idem-url-#{@hex40}")
    end

    test "accepts every source family in the live corpus" do
      for family <- ~w(url doc book yt) do
        assert Tag.well_formed?("idem-#{family}-#{@hex12}"), family
      end
    end

    test "rejects free text, wrong digest lengths, uppercase and non-hex" do
      refute Tag.well_formed?("idem-design")
      refute Tag.well_formed?("idem-url-notahexstring")
      # 11 and 13 chars bracket the 12-char era.
      refute Tag.well_formed?("idem-url-7ebe1ca3343")
      refute Tag.well_formed?("idem-url-7ebe1ca334312")
      refute Tag.well_formed?("idem-url-#{String.upcase(@hex12)}")
      refute Tag.well_formed?("url-#{@hex12}")
      refute Tag.well_formed?(nil)
    end
  end

  describe "legacy?/1" do
    test "matches the bare pre-reservation form by shape" do
      assert Tag.legacy?("url-#{@hex12}")
      assert Tag.legacy?("url-#{@hex40}")
      assert Tag.legacy?("doc-#{@hex12}")
      assert Tag.legacy?("book-#{@hex12}")
    end

    test "never matches a genuine topical tag" do
      for tag <- ~w(url-design url-generation url-encoding url-routing
                    url-normalization url-management doc-string book-review elixir) do
        refute Tag.legacy?(tag), tag
      end
    end

    test "never matches an already-reserved tag — this is what keeps promotion idempotent" do
      refute Tag.legacy?("idem-url-#{@hex12}")
    end
  end

  describe "promote/1" do
    test "prefixes a legacy tag" do
      assert Tag.promote("url-#{@hex12}") == {:ok, "idem-url-#{@hex12}"}
    end

    test "refuses anything that is not legacy-shaped" do
      assert Tag.promote("url-design") == :error
      assert Tag.promote("idem-url-#{@hex12}") == :error
      assert Tag.promote(nil) == :error
    end
  end

  describe "promote_tags/2" do
    test "adds the reserved form and leaves topical tags exactly as they are" do
      assert Tag.promote_tags(["url-design", "url-#{@hex12}", "elixir"]) ==
               ["url-design", "url-#{@hex12}", "idem-url-#{@hex12}", "elixir"]
    end

    test "is idempotent — re-running never double-prefixes" do
      once = Tag.promote_tags(["url-#{@hex12}"])
      assert Tag.promote_tags(once) == once
      assert Tag.promote_tags(Tag.promote_tags(once)) == once
      refute Enum.any?(once, &String.contains?(&1, "idem-idem-"))
    end

    test "is a no-op for a tag list with no legacy tags" do
      tags = ["url-design", "elixir", "idem-url-#{@hex12}"]
      assert Tag.promote_tags(tags) == tags
    end

    test "drop_legacy: true removes the bare form and stays idempotent" do
      dropped = Tag.promote_tags(["url-design", "url-#{@hex12}"], drop_legacy: true)
      assert dropped == ["url-design", "idem-url-#{@hex12}"]
      assert Tag.promote_tags(dropped, drop_legacy: true) == dropped
    end

    test "deduplicates when the reserved form is already present" do
      tags = ["url-#{@hex12}", "idem-url-#{@hex12}"]
      assert Tag.promote_tags(tags) == tags
    end
  end

  describe "published contract" do
    test "the 422 message names the prefix, the shape and an example" do
      message = Tag.reserved_violation_message()
      assert message =~ Tag.reserved_prefix()
      assert message =~ Tag.shape()
      assert message =~ Tag.example()
    end

    test "the OpenAPI description points callers at the idempotency_key column" do
      description = Tag.contract_description()
      assert description =~ Tag.reserved_prefix()
      assert description =~ Tag.shape()
      assert description =~ "idempotency_key"
      assert description =~ "422"
    end

    test "the example is itself well-formed — the docs cannot advertise a rejected tag" do
      assert Tag.well_formed?(Tag.example())
    end
  end
end
