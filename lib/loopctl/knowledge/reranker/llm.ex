defmodule Loopctl.Knowledge.Reranker.Llm do
  @moduledoc """
  Reranks a search page by asking the tenant's configured Anthropic model to order it.

  Per-tenant BYO, resolved through `Loopctl.Llm.Anthropic.message/5` under the
  `:classification` purpose, so a tenant with no key simply gets `{:error, :no_api_key}` and
  the dispatcher leaves the fused order alone.

  ## Why the model is shown positions, not ids

  Article ids are UUIDs. Asking a model to echo 10 UUIDs invites transcription errors that
  look like invented ids, and the dispatcher's permutation check would then throw away an
  otherwise good ordering. It sees `1..N` and replies with those numbers; the mapping back to
  ids happens here, where it cannot be got wrong.

  Anything that is not a clean permutation of `1..N` is an error, and the dispatcher keeps
  the fused order. That includes a truncated list — a partial ordering is not a cheaper
  success, it is a different page.
  """

  @behaviour Loopctl.Knowledge.Reranker

  alias Loopctl.Llm.Anthropic

  # Enough of a snippet to judge relevance, not enough to make the prompt scale with body
  # size. The page is already capped by the caller's limit.
  @snippet_chars 240
  @max_tokens 200

  @system_prompt """
  You order search results by how well each one answers the user's query. You will be given \
  a query and a numbered list of candidate documents (title and a short excerpt). Reply with \
  a single compact JSON object with exactly one key, "order", whose value is an array \
  containing EVERY candidate number exactly once, most relevant first. Do not omit a number, \
  do not repeat one, and do not invent one. Output nothing except that JSON object.\
  """

  @doc "The reranking system prompt. Public so a recording tool and tests share it."
  @spec system_prompt() :: String.t()
  def system_prompt, do: @system_prompt

  @doc "The user message for a query and its candidates. Public for the same reason."
  @spec user_content(String.t(), [Loopctl.Knowledge.Reranker.candidate()]) :: String.t()
  def user_content(query, candidates) do
    listed =
      candidates
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {candidate, index} ->
        excerpt = candidate.snippet |> to_string() |> String.slice(0, @snippet_chars)
        "#{index}. #{candidate.title}\n   #{excerpt}"
      end)

    "Query: #{query}\n\nCandidates:\n#{listed}"
  end

  @impl true
  def rerank(scope_or_tenant_id, query, candidates, opts \\ []) do
    content = user_content(query, candidates)

    body_fun = fn _model ->
      %{
        max_tokens: @max_tokens,
        system: @system_prompt,
        messages: [%{role: "user", content: content}]
      }
    end

    case call(scope_or_tenant_id, opts, body_fun) do
      {:ok, text} -> parse_order(text, candidates)
      {:error, _} = error -> error
    end
  end

  # Mirrors `ClaudeCategoryClassifier.classify_via/3`: pre-resolved credentials when the
  # caller supplied them, otherwise the ordinary per-tenant BYO resolve. The opts are named
  # `:rerank_api_key`/`:rerank_model` rather than the bare `:api_key`/`:model` because they
  # travel the whole length of `search_combined/3`'s opts, where a generic name would sit
  # next to `:api_key_id` and invite exactly one confusion too many.
  #
  # The explicit-credential path exists for ONE caller — the retrieval eval's
  # `--record-rerank`, which runs against a throwaway tenant that by construction has no
  # stored LLM settings, and reads `ANTHROPIC_API_KEY` instead. That key is an Anthropic
  # key by definition, so the cross-provider leak `Anthropic.call/7` is unguarded against
  # (a tenant's openai_compatible key POSTed to api.anthropic.com) cannot arise here.
  # Production always takes the `message/5` branch, and with it the provider guard.
  defp call(scope_or_tenant_id, opts, body_fun) do
    case {opts[:rerank_api_key], opts[:rerank_model]} do
      {api_key, model} when is_binary(api_key) and is_binary(model) ->
        Anthropic.call(scope_or_tenant_id, :classification, api_key, model, body_fun)

      _ ->
        Anthropic.message(scope_or_tenant_id, :classification, body_fun)
    end
  end

  @doc """
  Parses a model reply into the reranked ids, or an error.

  Public so the permutation rules are unit-testable without HTTP — the failure modes here
  (a fence-wrapped object, a dropped number, a 1-based/0-based confusion) are the ones that
  actually happen.
  """
  @spec parse_order(String.t() | nil, [Loopctl.Knowledge.Reranker.candidate()]) ::
          {:ok, [String.t()]} | {:error, atom()}
  def parse_order(text, candidates) when is_binary(text) do
    count = length(candidates)

    with {:ok, json} <- extract_json_object(text),
         %{"order" => order} when is_list(order) <- json,
         true <- valid_permutation?(order, count) do
      {:ok, Enum.map(order, fn position -> Enum.at(candidates, position - 1).id end)}
    else
      _ -> {:error, :unparseable_order}
    end
  end

  def parse_order(_text, _candidates), do: {:error, :unparseable_order}

  defp valid_permutation?(order, count) do
    length(order) == count and
      Enum.all?(order, &is_integer/1) and
      MapSet.new(order) == MapSet.new(1..count//1)
  end

  defp extract_json_object(text) do
    case Regex.run(~r/\{.*\}/s, String.trim(text)) do
      [json] -> JSON.decode(json)
      _ -> :error
    end
  end
end
