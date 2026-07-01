defmodule Loopctl.Knowledge.ClaudeMergeSynthesizer do
  @moduledoc """
  Anthropic Claude-backed `MergeSynthesizerBehaviour`. Combines two overlapping
  knowledge articles into one, preserving every distinct fact and reconciling wording.

  Reuses the shared `:anthropic_provider` config (same key as the classifier/extractors).
  With no API key it returns `{:error, :not_configured}`, so the merge executor degrades
  gracefully (leaves the `:merge` resolution unexecuted) rather than drafting a placeholder.
  """

  @behaviour Loopctl.Knowledge.MergeSynthesizerBehaviour

  require Logger

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
  def synthesize(a, b) do
    config = Application.get_env(:loopctl, :anthropic_provider, %{})
    api_key = config[:api_key] || ""

    if api_key == "" do
      {:error, :not_configured}
    else
      call_anthropic(a, b, config)
    end
  end

  defp call_anthropic(a, b, config) do
    base_url = config[:base_url] || "https://api.anthropic.com/v1"

    model =
      Application.get_env(:loopctl, :knowledge_merge_model) ||
        config[:model] || "claude-haiku-4-5-20251001"

    user_content =
      "ARTICLE A\nTitle: #{a.title}\n\nBody:\n#{clip(a.body)}\n\n" <>
        "ARTICLE B\nTitle: #{b.title}\n\nBody:\n#{clip(b.body)}"

    req_body = %{
      model: model,
      max_tokens: 2000,
      system: @system_prompt,
      messages: [%{role: "user", content: user_content}]
    }

    case Req.post("#{base_url}/messages",
           json: req_body,
           headers: [
             {"x-api-key", config[:api_key]},
             {"anthropic-version", "2023-06-01"}
           ]
         ) do
      {:ok, %{status: 200, body: resp}} ->
        parse_text(get_in(resp, ["content", Access.at(0), "text"]))

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
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
