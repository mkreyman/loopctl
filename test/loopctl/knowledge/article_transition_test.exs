defmodule Loopctl.Knowledge.ArticleTransitionTest do
  use ExUnit.Case, async: true

  alias Loopctl.Knowledge.Article

  describe "valid_transition?/2" do
    test "draft -> published is valid" do
      assert Article.valid_transition?(:draft, :published)
    end

    test "published -> draft is valid" do
      assert Article.valid_transition?(:published, :draft)
    end

    test "published -> archived is valid" do
      assert Article.valid_transition?(:published, :archived)
    end

    test "draft -> archived is valid" do
      assert Article.valid_transition?(:draft, :archived)
    end

    test "superseded -> draft is valid" do
      assert Article.valid_transition?(:superseded, :draft)
    end

    test "archived -> published is invalid" do
      refute Article.valid_transition?(:archived, :published)
    end

    test "archived -> draft is invalid" do
      refute Article.valid_transition?(:archived, :draft)
    end

    test "superseded -> published is invalid" do
      refute Article.valid_transition?(:superseded, :published)
    end

    test "superseded -> archived is invalid" do
      refute Article.valid_transition?(:superseded, :archived)
    end

    test "same status transition is invalid" do
      refute Article.valid_transition?(:draft, :draft)
      refute Article.valid_transition?(:published, :published)
      refute Article.valid_transition?(:archived, :archived)
      refute Article.valid_transition?(:superseded, :superseded)
    end

    test "draft -> superseded is invalid (only via article links)" do
      refute Article.valid_transition?(:draft, :superseded)
    end

    test "published -> superseded is invalid (only via article links)" do
      refute Article.valid_transition?(:published, :superseded)
    end
  end
end
