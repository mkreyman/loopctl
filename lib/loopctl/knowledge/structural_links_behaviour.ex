defmodule Loopctl.Knowledge.StructuralLinksBehaviour do
  @moduledoc """
  DI seam for the source-provenance harvest (`Loopctl.Knowledge.StructuralLinks`).

  Exists for ONE branch that a test database cannot produce: `harvest/2` answers
  `{:error, :heavy_read_overloaded}` when the corpus scan is shed by the heavy-read gate,
  and `Loopctl.Workers.StructuralLinksWorker` must turn that into a `{:snooze, n}` rather
  than a failed attempt. A sandboxed suite never sheds, so without a seam the snooze
  branch ships untested — which is exactly the class of inert guard this repo has been
  bitten by before.
  """

  @callback harvest(tenant_id :: binary(), opts :: keyword()) ::
              {:ok, map()} | {:error, :heavy_read_overloaded}
end
