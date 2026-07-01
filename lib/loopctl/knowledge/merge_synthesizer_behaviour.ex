defmodule Loopctl.Knowledge.MergeSynthesizerBehaviour do
  @moduledoc """
  Behaviour for synthesizing ONE merged article from two overlapping ones — the
  clerical half of a `:merge` conflict resolution (route-the-findings #4, step 2).

  This is the only place an LLM touches conflict resolution, and it is deliberately an
  EXECUTOR, not a judge: the merge only runs because a grounded agent already recorded
  a `:merge` verdict on the pair. The synthesizer combines the two texts; it does not
  decide whether they should be merged. Its output always lands as a DRAFT for review —
  never auto-published — with both sources preserved, so a bad synthesis is harmless.

  ## Config-based DI

  `config/test.exs` swaps in `Loopctl.MockMergeSynthesizer`; the default is
  `Loopctl.Knowledge.ClaudeMergeSynthesizer`, resolved at call time via
  `Application.get_env(:loopctl, :merge_synthesizer, ...)`.
  """

  @type article :: %{title: String.t(), body: String.t()}

  @doc """
  Synthesize a merged article from two sources. Returns `{:ok, %{title, body}}` or
  `{:error, term}` — implementations MUST return an error (never a placeholder) when the
  backend is unavailable, so the executor leaves the resolution for retry rather than
  drafting garbage.
  """
  @callback synthesize(a :: article(), b :: article()) ::
              {:ok, article()} | {:error, term()}
end
