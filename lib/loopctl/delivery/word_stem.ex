defmodule Loopctl.Delivery.WordStem do
  @moduledoc """
  A deliberately small suffix stemmer for the user-agent instruction tripwire
  (`Loopctl.Delivery.InjectionDetector`), so `approving` and `approves` match the lexicon entry
  `approved`, and `reviewer` matches `review`.

  `match_key/1`, applied to BOTH the lexicon and the words read from a user agent:

  1. downcase;
  2. a word under five letters is matched EXACTLY and never by stem;
  3. otherwise strip ONE trailing `ing`, `ed`, `er`, `es` or `s`, tried in that order, when at
     least four letters remain.

  Nothing else is changed: no consonant undoubling and no final-`e` dropping. Both produced
  three-letter stems that real brand and model codes carry (`tell` became `tel`, as in `Tele2`
  and `mTEL`; `role` became `rol`, as in `ROL-W00`; `here` became `her`, as in Edge's
  `Herring/95`). A short word is matched exactly for the same reason: a stem under four letters
  is the shape of a model code, not of a word.

  It is not a linguistic stemmer and does not need to be one: both sides go through the same
  function, so it only has to map an inflection and its base to the SAME key, and it misses an
  inflection whose base ends in `e` (`merging` does not reach `merge`, only `merged`).
  """

  @suffixes ~w(ing ed er es s)
  @min_stemmed_length 5
  @min_stem_length 4

  @typedoc "What a word is compared by: itself when short, its stem otherwise."
  @type key :: {:exact, String.t()} | {:stem, String.t()}

  @doc "The key `word` is matched by. See the moduledoc."
  @spec match_key(String.t()) :: key()
  def match_key(word) when is_binary(word) do
    word = String.downcase(word)

    if byte_size(word) < @min_stemmed_length,
      do: {:exact, word},
      else: {:stem, strip_suffix(word)}
  end

  defp strip_suffix(word) do
    Enum.find_value(@suffixes, word, fn suffix ->
      base = String.replace_suffix(word, suffix, "")

      if base != word and byte_size(base) >= @min_stem_length, do: base
    end)
  end
end
