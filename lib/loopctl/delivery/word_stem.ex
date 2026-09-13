defmodule Loopctl.Delivery.WordStem do
  @moduledoc """
  A deliberately small suffix stemmer for the user-agent instruction tripwire
  (`Loopctl.Delivery.InjectionDetector`), so `approving`, `approved` and `approves` match the
  lexicon entry `approve`, and `reviewer` matches `review`.

  `stem/1`, applied to BOTH the lexicon and the words read from a user agent:

  1. downcase;
  2. strip ONE trailing `ing`, `ed`, `er`, `es` or `s`, tried in that order, keeping at least
     three letters;
  3. undouble a final doubled consonant (`skipp` is `skip`, `pull` is `pul`);
  4. strip a final `e` when four or more letters remain (`approve` is `approv`).

  It is not a linguistic stemmer and does not need to be one: both sides go through the same
  function, so it only has to map an inflection and its base to the SAME string.
  """

  @suffixes ~w(ing ed er es s)
  @double_consonant ~r/([b-df-hj-np-tv-z])\1\z/

  @doc "The stem of `word`. See the moduledoc."
  @spec stem(String.t()) :: String.t()
  def stem(word) when is_binary(word) do
    word
    |> String.downcase()
    |> strip_suffix()
    |> undouble()
    |> strip_final_e()
  end

  defp strip_suffix(word) do
    Enum.find_value(@suffixes, word, fn suffix ->
      base = String.replace_suffix(word, suffix, "")

      if base != word and byte_size(base) >= 3, do: base
    end)
  end

  defp undouble(word) do
    if byte_size(word) >= 4 and Regex.match?(@double_consonant, word),
      do: binary_part(word, 0, byte_size(word) - 1),
      else: word
  end

  defp strip_final_e(word) do
    if byte_size(word) >= 4 and String.ends_with?(word, "e"),
      do: binary_part(word, 0, byte_size(word) - 1),
      else: word
  end
end
