defmodule LoopctlWeb.WikiIndexLive do
  @moduledoc """
  US-26.0.3 / kbweb-01 — Public wiki landing page.

  Shows a grid of the most-viewed featured system articles by default and
  switches to a keyword search result list as soon as the visitor types.
  No authentication required.
  """

  use LoopctlWeb, :live_view

  alias Loopctl.Knowledge

  @impl true
  def mount(_params, _session, socket) do
    featured = Knowledge.list_featured_articles()

    {:ok,
     socket
     |> assign(:page_title, "loopctl Wiki")
     |> assign(:featured_articles, featured)
     |> assign(:search_query, "")
     |> assign(:search_results, nil)}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) when byte_size(query) > 0 do
    # Push search to DB to avoid loading full article bodies into LiveView
    import Ecto.Query

    escaped =
      query
      |> String.downcase()
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    pattern = "%#{escaped}%"

    results =
      from(a in Loopctl.Knowledge.Article,
        where:
          a.scope == :system and a.status == :published and
            (ilike(a.title, ^pattern) or ilike(a.body, ^pattern)),
        order_by: [asc: a.title],
        select: %{id: a.id, title: a.title, slug: a.slug, category: a.category}
      )
      |> Loopctl.AdminRepo.all()

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:search_results, results)}
  end

  def handle_event("search", _params, socket) do
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> assign(:search_results, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="mx-auto w-full max-w-5xl px-6 py-16" id="wiki-index">
      <header class="mb-8">
        <h1 class="font-display text-2xl font-semibold text-slate-100">loopctl Wiki</h1>
        <p class="mt-2 text-sm text-slate-400">
          Canonical documentation for the loopctl trust model, custody protocol, and agent lifecycle.
        </p>
      </header>

      <form phx-change="search" class="mb-8" id="wiki-search-form">
        <input
          type="text"
          name="q"
          value={@search_query}
          placeholder="Search articles..."
          class="w-full rounded-md border border-slate-700 bg-slate-900 px-4 py-2 font-mono text-sm text-slate-200 placeholder-slate-500 focus:border-accent-500 focus:outline-none focus:ring-1 focus:ring-accent-500"
          autocomplete="off"
          phx-debounce="300"
        />
      </form>

      <%= if @search_results do %>
        <div id="search-results" class="space-y-3">
          <h2 class="font-mono text-xs uppercase tracking-wide text-slate-500">
            {length(@search_results)} result(s) for "{@search_query}"
          </h2>
          <div
            :for={article <- @search_results}
            class="rounded-md border border-slate-800 bg-slate-900/60 p-4"
          >
            <.link
              navigate={~p"/wiki/#{article.slug}"}
              class="text-accent-400 hover:text-accent-300 font-display text-sm"
            >
              {article.title}
            </.link>
            <span class="ml-2 font-mono text-xs text-slate-500">{article.category}</span>
          </div>
          <p :if={@search_results == []} class="text-sm text-slate-500">
            No articles match your search.
          </p>
        </div>
      <% else %>
        <div id="featured-articles">
          <h2 class="mb-4 font-mono text-xs font-semibold uppercase tracking-wide text-slate-400">
            Featured articles
          </h2>
          <div class="grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-4">
            <.link
              :for={article <- @featured_articles}
              id={"featured-#{article.id}"}
              navigate={~p"/wiki/#{article.slug}"}
              class="flex flex-col rounded-md border border-slate-700 bg-slate-900 p-4 transition-colors hover:border-accent-500"
            >
              <h3 class="text-sm font-medium text-slate-200">{article.title}</h3>
              <p class="mt-2 flex-1 text-xs text-slate-400">{article.snippet}</p>
              <div class="mt-3 flex items-center justify-between gap-2">
                <span class="rounded-full bg-slate-800 px-2 py-0.5 font-mono text-xs text-slate-600">
                  {article.category}
                </span>
                <span class="font-mono text-xs text-slate-500">
                  {article.view_count} views
                </span>
              </div>
            </.link>
          </div>
          <p :if={@featured_articles == []} class="text-sm text-slate-500">
            No system articles published yet.
          </p>
        </div>
      <% end %>
    </section>
    """
  end
end
