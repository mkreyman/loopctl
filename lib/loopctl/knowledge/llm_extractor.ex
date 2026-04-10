defmodule Loopctl.Knowledge.LlmExtractor do
  @moduledoc """
  Default stub implementation of `ExtractorBehaviour`.

  Returns an empty list for all inputs. The real LLM-powered
  implementation will replace this once the LLM integration
  story (US-24.2+) is built.
  """

  @behaviour Loopctl.Knowledge.ExtractorBehaviour

  @impl true
  def extract_articles(_context), do: {:ok, []}
end
