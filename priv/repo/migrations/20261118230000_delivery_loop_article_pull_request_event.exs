defmodule Loopctl.Repo.Migrations.DeliveryLoopArticlePullRequestEvent do
  use Ecto.Migration

  # The public `delivery-loop` wiki article (seeded by 20260926060000) told operators to add the
  # webhook for the Issues event only. US-50.4 reads review outcomes from merged pull requests,
  # so the webhook needs the Pull requests event too. One sentence changes, so this replaces that
  # sentence in place rather than re-inlining the whole body a second time.
  @slug "delivery-loop"
  @old "add the GitHub webhook for the Issues event."
  @new "add the GitHub webhook for the Issues and Pull requests events (a merged pull request queues a read of its `## Review findings` section)."

  def up, do: swap(@old, @new)
  def down, do: swap(@new, @old)

  defp swap(from, to) do
    execute("""
    UPDATE articles
    SET body = replace(body, '#{escape_sql(from)}', '#{escape_sql(to)}'), updated_at = NOW()
    WHERE scope = 'system' AND slug = '#{@slug}'
    """)
  end

  defp escape_sql(text), do: String.replace(text, "'", "''")
end
