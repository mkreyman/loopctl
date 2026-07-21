defmodule Loopctl.Memory.Promoter.OpenAiLLM do
  @moduledoc """
  OpenAI-compatible SIBLING of `Loopctl.Memory.Promoter.DefaultLLM` (US-41.3,
  AC-41.3.2).

  Both AC-29.1.3 (determinism: `temperature: 0` + a FIXED system prompt) and
  AC-29.1.5 (injection hardening: untrusted session content framed by fixed
  delimiters that are neutralized in the content itself) are PRESERVED by reading
  the prompt and the framed user message from the Anthropic impl rather than
  copying them — a copy would let the hardening silently drift out of this path,
  which is precisely the path handling attacker-influenced content.

  ## Shape validation (AC-41.3.4) happens HERE, not in the promoter

  The behaviour returns RAW TEXT and `Loopctl.Memory.Promoter` parses it — but the
  promoter's parser is the Anthropic-era TOLERANT one: a non-list body yields
  `{:error, :unexpected_llm_output}` / `{:error, {:json_parse_error, _}}` (neither
  naming an endpoint or a model, and both RETRIED by
  `Loopctl.Workers.MemoryPromotionWorker`, which re-POSTs the session content), and
  `normalize_candidate/1` SILENTLY DROPS every malformed candidate — exactly the
  "write an arbitrary subset of a malformed response" behaviour
  `Loopctl.Knowledge.StrictArticleParser` was written to eliminate on the other
  four impls. This is the surface with the MOST attacker-influenced payload, so it
  does not get the weaker treatment: the response is shape-VALIDATED here, before
  it is returned, and a violation is a `Loopctl.Llm.ShapeError` naming the endpoint
  and the model — which the worker CANCELS instead of retrying.

  Validation is deliberately a CHECK, not a rewrite: on success the original text
  is returned unchanged and the promoter still performs the per-field capping and
  the tenant-scoped `cross_links` validation that are its job.
  """

  @behaviour Loopctl.Memory.Promoter.LLMBehaviour

  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Llm.OpenAiChat
  alias Loopctl.Llm.ShapeError
  alias Loopctl.Memory.Promoter.DefaultLLM

  @impl true
  def extract(scope_or_tenant_id, session_content, _opts \\ []) when is_binary(session_content) do
    scope = EgressScope.coerce(scope_or_tenant_id)
    params = DefaultLLM.request_params()

    body_fun = fn _model ->
      %{
        max_tokens: params.max_tokens,
        temperature: 0,
        system: DefaultLLM.system_prompt(),
        messages: [%{role: "user", content: DefaultLLM.user_content(session_content)}]
      }
    end

    with {:ok, target} <- OpenAiChat.resolve_target(scope.tenant_id, :extraction),
         {:ok, text} <-
           OpenAiChat.call(
             scope,
             :extraction,
             target.base_url,
             target.api_key,
             target.model,
             body_fun,
             %{},
             receive_timeout: params.receive_timeout,
             max_retries: params.max_retries
           ) do
      validate_shape(text, target)
    end
  end

  # The strict candidate-list check. Mirrors `Loopctl.Knowledge.StrictArticleParser`:
  # an EXPLICIT empty list is a valid "nothing worth promoting"; anything else must
  # be a list of objects each carrying a non-empty `text` and a usable
  # `confidence`. A PARTIALLY malformed list refuses — promoting whichever
  # candidates survived a silent filter is worse than a legible refusal, because
  # nothing downstream can tell "the model found 2 facts" from "the model mangled 8
  # of 10".
  defp validate_shape(text, target) when is_binary(text) do
    case text |> strip_markdown_fences() |> JSON.decode() do
      {:ok, []} ->
        {:ok, text}

      {:ok, candidates} when is_list(candidates) ->
        validate_candidates(candidates, text, target)

      {:ok, %{"candidates" => candidates}} when is_list(candidates) ->
        validate_candidates(candidates, text, target)

      {:ok, _other} ->
        {:error,
         ShapeError.new(
           target.endpoint,
           target.model,
           :not_a_list,
           "expected a JSON array of memory candidates"
         )}

      {:error, _reason} ->
        {:error,
         ShapeError.new(
           target.endpoint,
           target.model,
           :not_json,
           "the response was not JSON (a local model returning prose instead of the " <>
             "requested JSON array is the usual cause)"
         )}
    end
  end

  defp validate_candidates(candidates, text, target) do
    invalid = Enum.count(candidates, &(not valid_candidate?(&1)))

    cond do
      invalid == length(candidates) ->
        {:error,
         ShapeError.new(
           target.endpoint,
           target.model,
           :no_valid_items,
           "no element carried a non-empty text and a usable confidence"
         )}

      invalid > 0 ->
        {:error,
         ShapeError.new(
           target.endpoint,
           target.model,
           :missing_required_fields,
           "#{invalid} of #{length(candidates)} candidates lacked a non-empty text or a " <>
             "usable confidence; refusing a PARTIAL promotion"
         )}

      true ->
        {:ok, text}
    end
  end

  # The SAME acceptance rule `Loopctl.Memory.Promoter.normalize_candidate/1`
  # applies — stated as a predicate so a candidate the promoter would silently DROP
  # is refused here instead.
  defp valid_candidate?(%{"text" => text} = raw) when is_binary(text) do
    String.trim(text) != "" and usable_confidence?(raw["confidence"])
  end

  defp valid_candidate?(_raw), do: false

  defp usable_confidence?(c) when is_float(c) or is_integer(c), do: true
  defp usable_confidence?(c) when is_binary(c), do: match?({_f, _rest}, Float.parse(c))
  defp usable_confidence?(_c), do: false

  defp strip_markdown_fences(text) do
    trimmed = String.trim(text)

    if String.starts_with?(trimmed, "```") do
      trimmed
      |> String.replace(~r/\A```(?:json)?\s*\n?/, "")
      |> String.replace(~r/\n?```\s*\z/, "")
    else
      trimmed
    end
  end
end
