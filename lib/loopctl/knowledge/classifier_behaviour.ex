defmodule Loopctl.Knowledge.ClassifierBehaviour do
  @moduledoc """
  Behaviour for classifying a knowledge article into a single category.

  Used by `Loopctl.Workers.KnowledgeReclassifyWorker` to move the existing
  corpus onto the expanded taxonomy. An implementation receives an article's
  title and body and returns the best ACTIVE category
  (`Loopctl.Knowledge.Categories.active/0`) plus a confidence in `[0.0, 1.0]`.

  The worker only WRITES a change when confidence clears the configured
  threshold AND the proposed category differs from the current one, so a
  low-confidence or uncertain classification is a safe no-op. An `{:error, _}`
  return means "leave this article alone".
  """

  @type result :: %{required(:category) => atom(), required(:confidence) => float()}

  @callback classify(title :: String.t(), body :: String.t()) ::
              {:ok, result()} | {:error, term()}
end
