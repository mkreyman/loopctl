defmodule Loopctl.Memory.PromotionEval.Dataset do
  @moduledoc """
  Loader for the COMMITTED labeled promotion-eval dataset (Epic 29 / US-29.5,
  AC-29.5.1).

  The dataset is a stable, committed data file (`priv/promotion_eval/dataset_v1.json`) —
  NOT code — so its ground-truth labels are versioned and reviewable. Each session
  carries:

    * `id` — a stable case identifier.
    * `turns` — the session content fed to `Loopctl.Memory.Promoter` (seeded as
      short-term turns).
    * `expected_facts` — the GROUND-TRUTH durable facts the compiler SHOULD emit.
      An empty list means "nothing durable" — the label for the noise/injection case.
    * `llm_output` — a REFERENCE structured LLM output (string-keyed candidate maps).
      It is NOT used by the eval scorer (the eval scores the compiler's real output
      against `expected_facts`). It exists so tests can drive the deterministic
      `MockPromoterLLM` to reproduce a well-behaved LLM for these sessions
      (TC-29.5.1); production runs use the tenant's real LLM instead.

  The dataset MUST include at least one adversarial/injection case whose
  `expected_facts` is empty (AC-29.5.4), so a compiler regression that emits an
  injected instruction as a durable fact shows up as a false positive / precision
  drop, closing the loop with US-29.1 AC-29.1.5.
  """

  @type session :: %{
          id: String.t(),
          label: String.t() | nil,
          turns: [String.t()],
          expected_facts: [String.t()],
          llm_output: [map()]
        }

  @type t :: %{version: String.t(), sessions: [session()]}

  @relative_path "promotion_eval/dataset_v1.json"

  @doc "The default committed labeled dataset (`priv/promotion_eval/dataset_v1.json`)."
  @spec default() :: t()
  def default do
    :loopctl
    |> :code.priv_dir()
    |> Path.join(@relative_path)
    |> File.read!()
    |> JSON.decode!()
    |> normalize()
  end

  # Map the committed JSON (string keys) into the pinned atom-keyed shape. Keys are
  # a FIXED, known set from a committed file — never `String.to_atom/1` on the values.
  defp normalize(%{"version" => version, "sessions" => sessions}) when is_list(sessions) do
    %{version: version, sessions: Enum.map(sessions, &normalize_session/1)}
  end

  defp normalize_session(s) do
    %{
      id: s["id"],
      label: s["label"],
      turns: s["turns"] || [],
      expected_facts: s["expected_facts"] || [],
      llm_output: s["llm_output"] || []
    }
  end
end
