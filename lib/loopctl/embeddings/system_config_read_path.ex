defmodule Loopctl.Embeddings.SystemConfigReadPath do
  @moduledoc """
  Production implementation of `Loopctl.Embeddings.ReadPathBehaviour`: the
  US-41.1 cutover flag as a `SystemConfig` integer (`0` = legacy column,
  `1` = side table), cached in `:persistent_term`.

  This is the pre-existing behaviour, moved behind the behaviour unchanged —
  the flip and, just as importantly, the REVERT stay a single operator UPDATE
  with no redeploy (AC-41.1.8(ii)/(iii)), and the read stays a near-zero-cost
  `:persistent_term` lookup on the request path.

  The flag KEY lives here, not in `Loopctl.Embeddings`: this module is the
  INJECTED collaborator, so depending back on the module it is injected into
  (just to fetch a string constant) would defeat the seam and make it
  impossible to extract or exercise in isolation. `Embeddings.read_flag_key/0`
  delegates here.
  """

  @behaviour Loopctl.Embeddings.ReadPathBehaviour

  alias Loopctl.SystemConfig

  @read_flag_key "embedding_side_table_reads"

  @doc "The `SystemConfig` key backing the US-41.1 cutover decision."
  @spec read_flag_key() :: String.t()
  def read_flag_key, do: @read_flag_key

  @impl Loopctl.Embeddings.ReadPathBehaviour
  def side_table_reads_enabled? do
    SystemConfig.get_int(@read_flag_key, 0) == 1
  end
end
