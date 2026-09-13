defmodule Loopctl.Delivery.WordStemTest do
  use ExUnit.Case, async: true

  alias Loopctl.Delivery.WordStem

  test "a word of five or more letters loses one suffix when four letters remain" do
    assert WordStem.match_key("Reviewer") == {:stem, "review"}
    assert WordStem.match_key("approving") == WordStem.match_key("approved")
    assert WordStem.match_key("files") == {:stem, "file"}
  end

  test "a word under five letters is matched exactly, never by stem" do
    assert WordStem.match_key("tell") == {:exact, "tell"}
    refute WordStem.match_key("tells") == WordStem.match_key("tell")
    refute WordStem.match_key("roles") == WordStem.match_key("role")
  end

  test "nothing is undoubled and no final e is dropped" do
    assert WordStem.match_key("committed") == {:stem, "committ"}
    refute WordStem.match_key("committed") == WordStem.match_key("commit")
    assert WordStem.match_key("approve") == {:stem, "approve"}
  end

  test "words and model codes the round-2 review collided stay apart" do
    for {word, code} <- [
          {"tell", "Tele"},
          {"role", "ROL"},
          {"here", "Herring"},
          {"safe", "saf"},
          {"will", "wil"},
          {"but", "butter"},
          {"the", "thee"},
          {"master", "mast"}
        ] do
      refute WordStem.match_key(word) == WordStem.match_key(code), "#{word} matches #{code}"
    end
  end
end
