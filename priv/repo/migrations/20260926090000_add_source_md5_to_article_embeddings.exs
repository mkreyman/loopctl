defmodule Loopctl.Repo.Migrations.AddSourceMd5ToArticleEmbeddings do
  @moduledoc """
  Which version of its article an embedding row was made from (#896).

  `article_embeddings.source_md5` is the md5 of `title <> "\\n\\n" <> body` as its writer
  read it. `articles.text_md5` is the same md5 of the article's CURRENT text, kept by a
  trigger for system-scope rows (the only ones staleness is judged for), so every writer is
  covered: a changeset, a seeding migration's raw upsert, a hand-run UPDATE. "Is this
  system article embedded from its current text" is then a comparison of two stored
  columns, with no clock, no `updated_at` and no hashing on the search path.
  `embedding_content_hash` cannot serve: it hashes the `TextBudget`-cut text.

  The md5 formula lives ONLY in the trigger: writers copy `articles.text_md5` from the row
  they read, and the backfill below fires the trigger rather than repeating the expression.

  Backfill, in SQL, so the release does not make corpora read stale: system articles get
  `text_md5`, and each existing system row gets `source_md5` when EITHER the currency test
  it replaces passed (the row is no older than its article, which is what "current" meant
  until now) OR its stored content hash is the sha256 of the article's text as it stands
  (below the `TextBudget` cap, where the cut is a no-op). A row neither vouches for stays
  NULL and reads stale; the worker stamps it with no provider call when its hash matches,
  and re-embeds it when it does not, which is what the old test would also have done.
  """
  use Ecto.Migration

  @text "coalesce(title, '') || E'\\n\\n' || coalesce(body, '')"

  def up do
    alter table(:article_embeddings) do
      add :source_md5, :string
    end

    alter table(:articles) do
      add :text_md5, :string
    end

    execute """
    CREATE FUNCTION articles_set_text_md5() RETURNS trigger AS $$
    BEGIN
      NEW.text_md5 := md5(coalesce(NEW.title, '') || E'\\n\\n' || coalesce(NEW.body, ''));
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER articles_text_md5
    BEFORE INSERT OR UPDATE OF title, body, scope ON articles
    FOR EACH ROW WHEN (NEW.scope = 'system')
    EXECUTE FUNCTION articles_set_text_md5()
    """

    # Fires the trigger (an UPDATE OF title), so the formula is written once.
    execute "UPDATE articles SET title = title WHERE scope = 'system'"

    execute """
    UPDATE article_embeddings AS ae SET source_md5 = a.text_md5
    FROM articles AS a
    WHERE ae.article_id = a.id AND a.scope = 'system' AND ae.source_md5 IS NULL
      AND (
        ae.updated_at >= a.updated_at
        OR (
          char_length(#{@text}) < 32000
          AND ae.embedding_content_hash =
                encode(sha256(convert_to(#{@text}, 'UTF8')), 'hex')
        )
      )
    """
  end

  def down do
    execute "DROP TRIGGER articles_text_md5 ON articles"
    execute "DROP FUNCTION articles_set_text_md5()"

    alter table(:articles) do
      remove :text_md5
    end

    alter table(:article_embeddings) do
      remove :source_md5
    end
  end
end
