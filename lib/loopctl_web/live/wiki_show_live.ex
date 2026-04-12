defmodule LoopctlWeb.WikiShowLive do
  @moduledoc """
  US-26.0.3 — Public wiki article viewer.

  Renders a system-scoped article as HTML from its Markdown body.
  Includes a sticky sidebar listing all system articles.
  No authentication required.
  """

  use LoopctlWeb, :live_view

  require Logger

  alias Loopctl.Knowledge

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Knowledge.get_system_article_by_slug(slug) do
      {:ok, article} ->
        all_articles = Knowledge.list_system_articles()
        rendered_html = render_markdown(article.body, all_articles)

        {:ok,
         socket
         |> assign(:page_title, article.title)
         |> assign(:article, article)
         |> assign(:rendered_html, rendered_html)
         |> assign(:all_articles, all_articles)
         |> assign(:current_slug, slug)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> assign(:page_title, "Not Found")
         |> assign(:article, nil)
         |> assign(:rendered_html, nil)
         |> assign(:all_articles, Knowledge.list_system_articles())
         |> assign(:current_slug, slug)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-screen" id="wiki-show">
      <%!-- Sidebar --%>
      <nav
        class="sticky top-0 hidden h-screen w-64 shrink-0 overflow-y-auto border-r border-slate-800 bg-slate-950 px-4 py-8 lg:block"
        id="wiki-sidebar"
      >
        <h2 class="mb-4 font-mono text-xs font-semibold uppercase tracking-wide text-slate-500">
          System Articles
        </h2>
        <ul class="space-y-1">
          <li :for={a <- @all_articles}>
            <.link
              navigate={~p"/wiki/#{a.slug}"}
              class={[
                "block rounded-md px-3 py-1.5 text-xs transition-colors",
                if(a.slug == @current_slug,
                  do: "bg-accent-500/10 text-accent-400 font-medium",
                  else: "text-slate-400 hover:bg-slate-800 hover:text-slate-200"
                )
              ]}
            >
              {a.title}
            </.link>
          </li>
        </ul>
      </nav>

      <%!-- Main content --%>
      <main class="flex-1 px-6 py-8 lg:px-12">
        <%= if @article do %>
          <article class="mx-auto max-w-3xl" id="wiki-article">
            <header class="mb-8">
              <h1 class="font-display text-2xl font-semibold text-slate-100">{@article.title}</h1>
              <div class="mt-2 flex items-center gap-3">
                <span class="font-mono text-xs uppercase text-slate-500">{@article.category}</span>
                <span
                  :for={tag <- @article.tags}
                  class="rounded-md bg-slate-800 px-2 py-0.5 font-mono text-xs text-slate-400"
                >
                  {tag}
                </span>
              </div>
            </header>

            <div
              class="prose prose-invert prose-slate max-w-none prose-headings:font-display prose-code:font-mono prose-code:text-accent-300 prose-pre:rounded-md prose-pre:border prose-pre:border-slate-800 prose-pre:bg-slate-950"
              id="wiki-body"
            >
              {Phoenix.HTML.raw(@rendered_html)}
            </div>
          </article>
        <% else %>
          <div class="mx-auto max-w-2xl py-16 text-center" id="wiki-not-found">
            <h1 class="font-display text-xl text-slate-200">Article not found</h1>
            <p class="mt-2 text-sm text-slate-500">
              No system article exists at <code class="font-mono text-accent-400">/wiki/{@current_slug}</code>.
            </p>
            <.link
              navigate={~p"/wiki"}
              class="mt-4 inline-block text-sm text-accent-400 hover:text-accent-300"
            >
              Browse all articles
            </.link>
          </div>
        <% end %>
      </main>
    </div>
    """
  end

  defp render_markdown(nil, _all_articles), do: ""

  defp render_markdown(body, all_articles) when is_binary(body) do
    slugs = MapSet.new(all_articles, & &1.slug)

    body
    |> check_internal_links(slugs)
    |> Earmark.as_html!(compact_output: true)
  end

  # Scan for /wiki/:slug links and flag broken ones
  defp check_internal_links(body, valid_slugs) do
    Regex.replace(~r|\[([^\]]+)\]\(/wiki/([a-z0-9][a-z0-9-]*[a-z0-9])\)|, body, fn
      full_match, text, slug ->
        if MapSet.member?(valid_slugs, slug) do
          full_match
        else
          Logger.warning("Wiki: broken internal link to /wiki/#{slug}")
          "[#{text}](/wiki/#{slug} \"⚠ broken link\")"
        end
    end)
  end
end
