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
  - **It converges only within a cluster.** The production machines are clustered
    (`rel/env.sh.eex`), so every node holds a replica of every runner's entry. A node
    that is not connected — a netsplit, a machine on another release during a rolling
    deploy — does not see runners on the far side, and drops a silent peer's entries
    after 30 s of missed heartbeats. What that means for dispatch is in `Loopctl.Runners` ("Across the
    cluster").
  """

  use Phoenix.Presence,
    otp_app: :loopctl,
    pubsub_server: Loopctl.PubSub
end
