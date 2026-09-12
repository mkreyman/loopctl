defmodule Loopctl.Runners.Presence do
  @moduledoc """
  Presence for the runner pool (issue #801).

  A runner's entry is tracked against its channel process, so it disappears when that
  process exits — a killed runner, a dropped socket, a revoked credential. That IS the
  liveness design: no TTL, no sweeper, no `last_seen_at` row to go stale.

  Read it through `Loopctl.Runners.pool/1`, which applies the tenant-scoped topic.

  Two limits a caller must not forget (design §7):

  - **Liveness hint, not a scheduler.** Presence is an eventually-consistent CRDT with no
    compare-and-set; two readers can both see `in_flight: 0` and both dispatch to the
    same runner. Reserve capacity in Postgres.
  - **It converges only within a cluster.** loopctl runs single-node today. If Fly starts
    a second machine without `DNS_CLUSTER_QUERY`, a runner tracked on node A is invisible
    on node B for as long as its socket lives.
  """

  use Phoenix.Presence,
    otp_app: :loopctl,
    pubsub_server: Loopctl.PubSub
end
