defmodule Loopctl.Repo.Migrations.PinTenantEmbeddingModel do
  use Ecto.Migration

  @moduledoc """
  US-41.1 AC-41.1.10 (review) — pin the model that produced the tenant's ACTIVE
  corpus alongside the dimension it produced.

  `tenants.tenant_embedding_dimension` records the SHAPE of the active corpus, but
  nothing recorded WHICH MODEL produced it, so the AC-41.1.10 guarantee ("the query
  embedding is generated against the model that produced the ACTIVE corpus — never
  the pending one") had nothing to resolve against: every query vector came from
  `tenant_llm_settings.embedding_model`, i.e. whatever the tenant is configured with
  RIGHT NOW. During a re-embed that is by definition the PENDING model, so recall
  either blacked out for the whole window or the re-embed could never obtain
  target-dimension vectors at all.

  With the model pinned here:

    * every ordinary embedding (query vectors AND newly-written article/memory
      vectors) is generated with the PINNED model, so it always agrees with the
      active corpus;
    * the re-embed worker deliberately uses the tenant's CURRENTLY CONFIGURED model
      (the pending one) to produce target-dimension vectors;
    * completion re-pins BOTH the dimension and the model in one transaction.

  Backfilled from `tenant_llm_settings.embedding_model` for every tenant that has
  already embedded something, mirroring the dimension pin of
  `20260721000300_pin_existing_tenant_embedding_dimensions`. A tenant with no
  settings row is left NULL — `Loopctl.Embeddings.active_model/1` then falls through
  to the ordinary settings resolution and the first write pins it.
  """

  def up do
    alter table(:tenants) do
      add_if_not_exists(:tenant_embedding_model, :text)
    end

    execute("""
    UPDATE tenants t
       SET tenant_embedding_model = s.embedding_model
      FROM tenant_llm_settings s
     WHERE s.tenant_id = t.id
       AND t.tenant_embedding_model IS NULL
       AND s.embedding_model IS NOT NULL
       AND t.tenant_embedding_dimension IS NOT NULL
    """)
  end

  def down do
    alter table(:tenants) do
      remove_if_exists(:tenant_embedding_model, :text)
    end
  end
end
