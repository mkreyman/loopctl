defmodule Loopctl.Repo.Migrations.AddPublishedHeatIndexToArticles do
  use Ecto.Migration

  # `heat_index/2` filters its event aggregate through
  # `e.article_id IN (SELECT id FROM articles WHERE (tenant_id = $1 OR scope = 'system') AND
  # status = 'published' [AND category = $2])`. The events side is windowed and index-backed;
  # the article side had no index that produced that id set directly, so it fell back to
  # `articles_tenant_id_index` plus a heap fetch to test `status` — work proportional to the
  # tenant's WHOLE article count on a per-turn endpoint under a 10s statement timeout.
  #
  # These two partial indexes make each arm of the disjunction an index-only scan yielding
  # exactly the ids. `category` sits between `tenant_id` and `id` so ONE index serves both
  # shapes: with a category it is an equality on the second key, without one it is a range
  # scan over the tenant prefix.
  #
  # NOT the rewrite that was proposed for this (aggregate first, filter the top-K afterwards).
  # That inverts the meaning: the filters would no longer decide WHICH articles compete for
  # the top-K, only which survive it, so `heat_index(category: :playbook)` would rank the
  # whole corpus, take 101, and then keep the handful that happen to be playbooks. The
  # semi-join is load-bearing for the correctness of the ranking; what it needed was an index.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:articles, [:tenant_id, :category, :id],
        name: :articles_published_tenant_category_id_idx,
        where: "status = 'published'",
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:articles, [:category, :id],
        name: :articles_published_system_category_id_idx,
        where: "status = 'published' AND scope = 'system'",
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:articles, [:tenant_id, :category, :id],
        name: :articles_published_tenant_category_id_idx,
        concurrently: true
      )
    )

    drop_if_exists(
      index(:articles, [:category, :id],
        name: :articles_published_system_category_id_idx,
        concurrently: true
      )
    )
  end
end
