defmodule Loopctl.Knowledge.CategoriesTest do
  use ExUnit.Case, async: true

  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.Categories

  describe "taxonomy composition" do
    test "all/0 is active ++ retired with no overlap" do
      assert Categories.all() == Categories.active() ++ Categories.retired()
      assert MapSet.disjoint?(MapSet.new(Categories.active()), MapSet.new(Categories.retired()))
    end

    test "active set is the expanded taxonomy and excludes the retired convention" do
      assert Enum.sort(Categories.active()) ==
               Enum.sort([
                 :pattern,
                 :decision,
                 :finding,
                 :reference,
                 :playbook,
                 :insight,
                 :entity,
                 :idea,
                 :quote,
                 :question
               ])

      refute :convention in Categories.active()
    end

    test "convention is retired but still DB-valid (so existing rows load)" do
      assert :convention in Categories.retired()
      assert :convention in Categories.all()
    end
  end

  describe "string helpers" do
    test "all_strings/0 and active_strings/0 mirror the atom lists" do
      assert Categories.all_strings() == Enum.map(Categories.all(), &Atom.to_string/1)
      assert Categories.active_strings() == Enum.map(Categories.active(), &Atom.to_string/1)
    end
  end

  describe "definitions and prompt fragment" do
    test "every active category has a definition" do
      for category <- Categories.active() do
        assert is_binary(Categories.definition(category)),
               "missing definition for active category #{inspect(category)}"
      end
    end

    test "retired categories are not offered a definition (not for new content)" do
      assert Categories.definition(:convention) == nil
    end

    test "prompt_fragment lists every active category and no retired one" do
      fragment = Categories.prompt_fragment()

      for category <- Categories.active() do
        assert fragment =~ Atom.to_string(category)
      end

      refute fragment =~ "convention"
    end
  end

  test "the Article enum is backed by the canonical taxonomy" do
    # Ecto stores the enum mappings; assert it matches Categories.all/0 exactly,
    # so the schema can never drift from the source of truth.
    enum_values = Ecto.Enum.values(Article, :category)
    assert Enum.sort(enum_values) == Enum.sort(Categories.all())
  end
end
