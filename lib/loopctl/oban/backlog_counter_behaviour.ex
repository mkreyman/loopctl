defmodule Loopctl.Oban.BacklogCounterBehaviour do
  @moduledoc """
  Behaviour for the in-flight backlog count the batch-ingest admission gate
  (US-36.3, `LoopctlWeb.KnowledgeIngestionController.create_batch/2`) consults.

  Extracted purely so the count is a config-swappable DI seam. Production/dev
  resolve it to `Loopctl.Oban.FairShare` (the real bounded, tenant-scoped count);
  `config/test.exs` maps a Mox mock whose default stub delegates back to the real
  `FairShare.in_flight_count/2` (so the existing backlog tests exercise the real
  count unchanged), while the fail-open test overrides it with `Mox.expect/3` to
  RAISE — deterministically driving the gate's fail-open path (an unmeasurable
  count must ADMIT the batch, never surface as a generic HTTP 500), mirroring the
  US-36.2 fair-share gate's own count rescue.
  """
  @callback in_flight_count(tenant_id :: binary(), queue :: atom() | binary()) ::
              non_neg_integer()
end
