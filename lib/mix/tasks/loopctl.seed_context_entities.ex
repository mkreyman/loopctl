defmodule Mix.Tasks.Loopctl.SeedContextEntities do
  @moduledoc """
  US-30.6 — Seeds the dogfood Context-Retriever entity definitions
  (`project` / `story` / `epic`) for a tenant.

  Thin wrapper over `Loopctl.ContextRetriever.Dogfood.seed_default_entities/2`.
  Each definition is persisted through the vetted
  `Loopctl.ContextRetriever.Registry.create_entity/3` path (SERVER column
  allowlist + per-tenant cap + RLS + audit). Idempotent — re-running returns an
  unchanged definition as-is, reconciles a drifted one in place, and never
  commits a partial set near the entity cap (see the module's "Idempotency,
  drift reconciliation, and the entity cap"). The audit entries are attributed as
  `actor_type: "system"` (an operator-invoked task, not an API key).

  ## Usage

      mix loopctl.seed_context_entities --tenant-id UUID

  ## Options

      --tenant-id   Required. UUID of the tenant to seed the entity definitions under.
      --allow-prod  Bypass the environment guard. The seed only WRITES entity
                    definitions (not synthetic business rows) via the vetted
                    registry path, but it still commits directly, so a prod run is
                    gated behind explicit intent.

  ## Examples

      mix loopctl.seed_context_entities --tenant-id aaaaaaaa-0000-0000-0000-000000000001
  """

  use Mix.Task

  alias Loopctl.ContextRetriever.Dogfood

  @shortdoc "Seed dogfood Context-Retriever entity definitions for a tenant"

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [tenant_id: :string, allow_prod: :boolean])

    env = Mix.env()
    allow_prod = Keyword.get(opts, :allow_prod, false)

    unless env in [:test, :dev] or allow_prod do
      Mix.raise("""
      mix loopctl.seed_context_entities refuses to run in environment #{inspect(env)}.

      It commits entity definitions directly. To proceed in a non-test/dev
      environment, pass --allow-prod to confirm intent:

          mix loopctl.seed_context_entities --allow-prod --tenant-id UUID
      """)
    end

    tenant_id = Keyword.get(opts, :tenant_id)

    unless tenant_id do
      Mix.raise(
        "--tenant-id is required. Usage: mix loopctl.seed_context_entities --tenant-id UUID"
      )
    end

    Mix.Task.run("app.start")

    ensure_tenant_exists!(tenant_id)

    case Dogfood.seed_default_entities(tenant_id,
           actor_type: "system",
           actor_label: "mix loopctl.seed_context_entities",
           metadata: %{"source" => "dogfood_seed_task"}
         ) do
      {:ok, entities} ->
        names = entities |> Map.values() |> Enum.map(& &1.name) |> Enum.sort() |> Enum.join(", ")
        Mix.shell().info("Seeded dogfood entity definitions for tenant #{tenant_id}: #{names}")

      {:error, {entity_name, reason}} ->
        Mix.raise(
          "Failed to seed dogfood entity #{inspect(entity_name)} for tenant #{tenant_id}: " <>
            "#{inspect(reason)}"
        )
    end
  end

  # Fail with a clean, actionable message BEFORE seeding when the tenant does not
  # exist (or the id is not a UUID). Without this pre-check, a nonexistent
  # `--tenant-id` reaches `Registry.create_entity/3`'s `Multi.insert(:entity)`,
  # where the `entity_definitions.tenant_id` foreign key raises a `Postgrex.Error`.
  # That exception is a RAISE, not an `{:error, _}` step result, so it propagates
  # past `create_entity`'s step-error handling AND this task's `{:error, _}`
  # branch — the operator would get a raw stacktrace instead of the friendly
  # `Mix.raise` this task uses everywhere else. `Tenants.get_tenant/1` reads via
  # `AdminRepo` (tenants are global / not RLS-scoped), matching how the seed's
  # own RLS context will be set.
  defp ensure_tenant_exists!(tenant_id) do
    case Ecto.UUID.cast(tenant_id) do
      {:ok, uuid} ->
        case Loopctl.Tenants.get_tenant(uuid) do
          {:ok, _tenant} ->
            :ok

          {:error, :not_found} ->
            Mix.raise(
              "No tenant exists with id #{tenant_id}. Pass the id of an existing " <>
                "tenant to mix loopctl.seed_context_entities --tenant-id UUID."
            )
        end

      :error ->
        Mix.raise(
          "--tenant-id #{inspect(tenant_id)} is not a valid UUID. " <>
            "Usage: mix loopctl.seed_context_entities --tenant-id UUID"
        )
    end
  end
end
