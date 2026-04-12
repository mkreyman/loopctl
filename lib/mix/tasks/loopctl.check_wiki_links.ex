defmodule Mix.Tasks.Loopctl.CheckWikiLinks do
  @moduledoc """
  US-26.0.5 — Verifies that all internal wiki links in system articles resolve.

  Crawls all published system articles, extracts `/wiki/:slug` references,
  and checks that each slug exists as a published system article.

  ## Usage

      mix loopctl.check_wiki_links

  Exits with code 0 if all links resolve, 1 if any are broken.
  """

  use Mix.Task

  @shortdoc "Check internal wiki links in system articles"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    alias Loopctl.AdminRepo
    alias Loopctl.Knowledge.Article

    import Ecto.Query

    articles =
      from(a in Article,
        where: a.scope == :system and a.status == :published,
        select: %{slug: a.slug, title: a.title, body: a.body}
      )
      |> AdminRepo.all()

    valid_slugs = MapSet.new(articles, & &1.slug)

    broken =
      Enum.flat_map(articles, fn article ->
        Regex.scan(~r|/wiki/([a-z0-9][a-z0-9-]*[a-z0-9])|, article.body || "")
        |> Enum.map(fn [_full, slug] -> slug end)
        |> Enum.reject(&MapSet.member?(valid_slugs, &1))
        |> Enum.map(&{article.slug, &1})
      end)

    if broken == [] do
      Mix.shell().info("All internal wiki links resolve (#{length(articles)} articles checked)")
    else
      Mix.shell().error("Broken internal wiki links found:")

      for {source, target} <- broken do
        Mix.shell().error("  #{source} → /wiki/#{target} (not found)")
      end

      Mix.raise("#{length(broken)} broken wiki link(s) found")
    end
  end
end
