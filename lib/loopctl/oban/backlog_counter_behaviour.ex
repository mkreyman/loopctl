defmodule Loopctl.Oban.BacklogCounterBehaviour do
  @moduledoc """
  Behaviour for the in-flight backlog count the batch-ingest admission gate
  (US-36.3, `LoopctlWeb.KnowledgeIngestionController.create_batch/2`) consults.

  Extracted purely so the count is a config-swappable DI seam. Production/dev
  resolve it to `Loopctl.Oban.FairShare` (the real bounded, tenant-scoped,
  index-backed count); `config/test.exs` maps a Mox mock whose default stub delegates
  back to the real `FairShare.in_flight_ingestion_backlog/1` (so the existing backlog
  tests exercise the real count unchanged), while the fail-open test overrides it with
  `Mox.expect/3` to RAISE a DB timeout/connection error — deterministically driving the
  gate's fail-open path (an unmeasurable count must ADMIT the batch, never surface as a
  generic HTTP 500).

  The count is WORKER-scoped (`worker = ContentIngestionWorker`, the sole `:ingestion`
  worker) rather than queue-scoped, so it rides the partial index
  `oban_jobs_ingestion_tenant_idx` and its cost is bounded to the CALLER's own ingestion
  backlog — see `Loopctl.Oban.FairShare`'s "Cost / index justification".
  """
  @callback in_flight_ingestion_backlog(tenant_id :: binary()) :: non_neg_integer()
end
