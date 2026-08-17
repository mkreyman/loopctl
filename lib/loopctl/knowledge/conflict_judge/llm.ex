defmodule Loopctl.Knowledge.ConflictJudge.Llm do
  @moduledoc """
  Judges a flagged pair by READING both articles, via the tenant's configured Anthropic model.

  Per-tenant BYO through `Loopctl.Llm.Anthropic.message/5` under the `:classification`
  purpose, so a tenant with no key returns `{:error, :no_api_key}` and the dispatcher falls
  back to the similarity verdict — the drain continues either way.

  ## The prompt is built to make `:redundant` easy and `:contradictory` hard

  The failure that would matter is a false `:contradictory`: it writes a `contradicts` edge
  and puts the pair into a lint report a human reads as a real disagreement. A false
  `:redundant` costs only what the previous similarity-only judge already cost. So the
  instruction requires an INCOMPATIBLE CLAIM — not a different emphasis, a newer date or a
  broader scope — and names those three near-misses explicitly, because they are what two
  articles flagged by a similarity threshold usually differ by.

  Bodies are truncated: the pair was flagged on whole-document similarity, and the claim that
  distinguishes agreement from disagreement is essentially always stated up front in this
  corpus. A larger window buys a longer prompt on ~450 pairs a night.
  """

  @behaviour Loopctl.Knowledge.ConflictJudge

  alias Loopctl.Llm.Anthropic

  @body_chars 2_000
  @max_tokens 400

  @classifications %{
    "redundant" => :redundant,
    "contradictory" => :contradictory,
    "complementary" => :complementary
  }

  @confidences %{"low" => :low, "medium" => :medium, "high" => :high}

  @system_prompt """
  You compare two knowledge-base articles that an automatic similarity check flagged as \
  possibly conflicting. The check only knows they are ABOUT the same thing; your job is to \
  say what their relationship actually is.

  Answer with exactly one classification:

  - "redundant" — they state substantially the same knowledge. This is the most common \
  answer and should be your default when the two agree.
  - "contradictory" — they make claims that CANNOT both be true. Reserve this for a genuine \
  incompatibility. A different emphasis, a newer version of the same advice, or one being \
  broader in scope than the other are NOT contradictions.
  - "complementary" — related but neither duplicated nor incompatible; the similarity flag \
  was a false positive.

  Reply with a single compact JSON object with exactly three keys: "classification" (one of \
  the three values above), "confidence" ("low", "medium" or "high"), and "rationale" (one \
  sentence, at most 200 characters, naming the specific claims that decided it). Output \
  nothing except that JSON object.\
  """

  @doc "The judging system prompt. Public so tests and any sibling implementation share it."
  @spec system_prompt() :: String.t()
  def system_prompt, do: @system_prompt

  @doc "The user message for a pair. Public for the same reason."
  @spec user_content(map(), map(), float() | nil) :: String.t()
  def user_content(left, right, similarity) do
    """
    Cosine similarity: #{Float.round((similarity || 0.0) / 1, 4)} (context only — it cannot tell you whether they agree)

    ARTICLE A
    Title: #{left.title}
    #{String.slice(left.body || "", 0, @body_chars)}

    ARTICLE B
    Title: #{right.title}
    #{String.slice(right.body || "", 0, @body_chars)}
    """
  end

  @impl true
  def judge(scope_or_tenant_id, left, right, opts) do
    content = user_content(left, right, Keyword.get(opts, :similarity))

    body_fun = fn _model ->
      %{
        max_tokens: @max_tokens,
        system: @system_prompt,
        messages: [%{role: "user", content: content}]
      }
    end

    case call(scope_or_tenant_id, opts, body_fun) do
      {:ok, text} -> parse_verdict(text)
      {:error, _} = error -> error
    end
  end

  # Mirrors `ClaudeCategoryClassifier.classify_via/3`: pre-resolved credentials when a caller
  # supplied them, otherwise the ordinary per-tenant BYO resolve. The explicit path exists for
  # tests and for a backfill run against a tenant whose settings are not the ones to use.
  defp call(scope_or_tenant_id, opts, body_fun) do
    case {opts[:judge_api_key], opts[:judge_model]} do
      {api_key, model} when is_binary(api_key) and is_binary(model) ->
        Anthropic.call(scope_or_tenant_id, :classification, api_key, model, body_fun)

      _ ->
        Anthropic.message(scope_or_tenant_id, :classification, body_fun)
    end
  end

  @doc """
  Parse a model reply into a verdict.

  Public because the validation is the interesting part and deserves testing without HTTP.
  An unknown classification is an ERROR rather than a default: silently mapping it to
  `:redundant` would make a broken prompt indistinguishable from a corpus with no
  contradictions in it, which is precisely the state this judge exists to end.
  """
  @spec parse_verdict(String.t() | nil) ::
          {:ok, Loopctl.Knowledge.ConflictJudge.verdict()} | {:error, atom()}
  def parse_verdict(text) when is_binary(text) do
    with {:ok, json} <- extract_json_object(text),
         %{"classification" => raw_class} <- json,
         {:ok, classification} <- Map.fetch(@classifications, raw_class) do
      {:ok,
       %{
         classification: classification,
         confidence: Map.get(@confidences, json["confidence"], :medium),
         rationale: rationale(json["rationale"], classification)
       }}
    else
      _ -> {:error, :unparseable_verdict}
    end
  end

  def parse_verdict(_text), do: {:error, :unparseable_verdict}

  # The rationale is stored as evidence a human reads later, so an absent or oversized one is
  # normalised rather than rejected — the CLASSIFICATION is the part that must be exact.
  defp rationale(text, classification) when is_binary(text) and text != "",
    do: "Judged by reading both articles: " <> String.slice(text, 0, 400) <> tail(classification)

  defp rationale(_text, classification),
    do: "Judged by reading both articles." <> tail(classification)

  defp tail(:contradictory),
    do:
      " Both articles are RETAINED and a contradicts edge is recorded; deciding which is " <>
        "correct is not something an unattended judge is entitled to do."

  defp tail(_), do: " Both articles are retained; re-annotate this pair to override."

  defp extract_json_object(text) do
    case Regex.run(~r/\{.*\}/s, String.trim(text)) do
      [json] -> JSON.decode(json)
      _ -> :error
    end
  end
end
