defmodule Loopctl.Knowledge.ClaudeMergeSynthesizer do
  @moduledoc """
  Anthropic Claude-backed `MergeSynthesizerBehaviour`. Combines two overlapping
  knowledge articles into one, preserving every distinct fact and reconciling wording.

  Per-tenant BYO (Epic 28 residual, #179): the Anthropic key + merge model are
  resolved via `Loopctl.Llm.resolve(tenant_id, :merge)`. With no key it returns
  `{:error, :no_api_key}`, so the merge executor degrades gracefully (leaves the
  `:merge` resolution unexecuted) rather than drafting a placeholder. Token usage
  is recorded after a successful call via the shared `Loopctl.Llm.Anthropic`
  client.
  """

  @behaviour Loopctl.Knowledge.MergeSynthesizerBehaviour

  require Logger

  alias Loopctl.Llm.Anthropic

  @system_prompt """
  You merge TWO overlapping knowledge-base articles into ONE. Preserve every distinct \
  fact, caveat, and example from both — do NOT drop information, and do NOT invent \
  anything that isn't in the sources. If the two genuinely disagree on a point, keep both \
  claims and note the disagreement rather than silently picking one. Prefer the clearer \
  wording. Reply with a single compact JSON object with exactly two keys: "title" (a \
  concise, problem-first title) and "body" (markdown). Output nothing except that JSON.\
  """

  @max_body_chars 12_000

  @impl true
  def synthesize(tenant_id, a, b) do
    user_content =
      "ARTICLE A\nTitle: #{a.title}\n\nBody:\n#{clip(a.body)}\n\n" <>
        "ARTICLE B\nTitle: #{b.title}\n\nBody:\n#{clip(b.body)}"

    body_fun = fn _model ->
      %{
        max_tokens: 2000,
        system: @system_prompt,
        messages: [%{role: "user", content: user_content}]
      }
    end

    # Merge is a larger synthesis with no tight outer timeout; give it a slightly
    # longer bounded client budget (review #5).
    case Anthropic.message(tenant_id, :merge, body_fun, %{},
           receive_timeout: 55_000,
           max_retries: 1
         ) do
      {:ok, text} -> parse_text(text)
      {:error, :no_api_key} -> {:error, :no_api_key}
      {:error, _} = err -> err
    end
  end

  @doc """
  Parses an LLM response into a merged article. Tolerant of markdown fences / prose by
  extracting the first `{...}` object. Returns `{:error, :unparseable_merge}` for
  anything without non-empty `title` and `body`. Public so it's unit-testable without HTTP.
  """
  @spec parse_text(String.t() | nil) ::
          {:ok, Loopctl.Knowledge.MergeSynthesizerBehaviour.article()}
          | {:error, :unparseable_merge}
  def parse_text(text) when is_binary(text) do
    with {:ok, json} <- extract_json_object(text),
         %{"title" => title, "body" => body} <- json,
         true <- is_binary(title) and String.trim(title) != "",
         true <- is_binary(body) and String.trim(body) != "" do
      {:ok, %{title: title, body: body}}
    else
      _ -> {:error, :unparseable_merge}
    end
  end

  def parse_text(_), do: {:error, :unparseable_merge}

  defp extract_json_object(text) do
    case Regex.run(~r/\{.*\}/s, String.trim(text)) do
      [json] -> Jason.decode(json)
      _ -> :error
    end
  end

  defp clip(body), do: String.slice(body || "", 0, @max_body_chars)
end
