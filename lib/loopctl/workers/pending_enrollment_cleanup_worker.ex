defmodule Loopctl.Workers.PendingEnrollmentCleanupWorker do
  @moduledoc """
  US-26.0.1 — Oban worker that deletes half-finished tenant signups.

  A tenant row enters `:pending_enrollment` status the moment the
  signup ceremony inserts it, and flips to `:active` only once every
  authenticator verification succeeds. Any tenant still in
  `:pending_enrollment` after the TTL (15 minutes by default) is
  assumed to be an abandoned ceremony and deleted.

  Scheduled every 5 minutes via the Oban Cron plugin. See
  `config/config.exs`.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Tenants
  alias Loopctl.Tenants.Tenant

  @impl Oban.Worker
  def perform(_job) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-Tenants.pending_enrollment_ttl_seconds(), :second)

    # Fetch the abandoned tenants first so we can log their IDs,
    # then delete. SELECT + DELETE is safe here because no other
    # process transitions tenants OUT of :pending_enrollment except
    # the signup Multi (which sets :active atomically).
    abandoned =
      from(t in Tenant,
        where: t.status == :pending_enrollment,
        where: t.inserted_at < ^cutoff,
        select: %{id: t.id, slug: t.slug, inserted_at: t.inserted_at}
      )
      |> AdminRepo.all()

    if abandoned != [] do
      ids = Enum.map(abandoned, & &1.id)

      {deleted_count, _} =
        from(t in Tenant, where: t.id in ^ids)
        |> AdminRepo.delete_all()

      Logger.warning(
        "PendingEnrollmentCleanupWorker deleted #{deleted_count} abandoned signup tenants: #{inspect(ids)}"
      )
    end

    :ok
  end
end
