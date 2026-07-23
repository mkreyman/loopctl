defmodule Loopctl.Embeddings.SystemConfigReadPath do
  @moduledoc """
  Production implementation of `Loopctl.Embeddings.ReadPathBehaviour`: the
  US-41.1 cutover flag as a `SystemConfig` integer (`0` = legacy column,
  `1` = side table), cached in `:persistent_term`.

  This is the pre-existing behaviour, moved behind the behaviour unchanged —
  the flip and, just as importantly, the REVERT stay a single operator UPDATE
  with no redeploy (AC-41.1.8(ii)/(iii)), and the read stays a near-zero-cost
  `:persistent_term` lookup on the request path.
  """

  @behaviour Loopctl.Embeddings.ReadPathBehaviour

  alias Loopctl.Embeddings
  alias Loopctl.SystemConfig

  @impl Loopctl.Embeddings.ReadPathBehaviour
  def side_table_reads_enabled? do
    SystemConfig.get_int(Embeddings.read_flag_key(), 0) == 1
  end
end
