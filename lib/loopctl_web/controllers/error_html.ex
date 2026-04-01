defmodule LoopctlWeb.ErrorHTML do
  @moduledoc """
  Renders HTML error pages for browser requests.

  Handles 404 and 500 status codes with styled error pages
  matching the loopctl design system.
  """

  use LoopctlWeb, :html

  # If you want to customize your error pages,
  # uncomment the embed_templates line below and add pages
  # to the error_html directory:
  #
  #   * lib/loopctl_web/controllers/error_html/404.html.heex
  #   * lib/loopctl_web/controllers/error_html/500.html.heex
  #
  # embed_templates "error_html/*"

  def render("404.html", _assigns) do
    error_page("404", "Page not found", "The page you are looking for does not exist.")
  end

  def render("500.html", _assigns) do
    error_page("500", "Internal server error", "Something went wrong. Please try again later.")
  end

  # Catch-all for any other status code templates
  def render(template, _assigns) do
    status =
      template
      |> String.split(".")
      |> hd()

    error_page(status, "Error #{status}", "An error occurred.")
  end

  defp error_page(status, title, message) do
    assigns = %{status: status, title: title, message: message}

    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="dark">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@title} - loopctl</title>
        <style>
          body { background: #0b0e14; color: #b4b8c7; font-family: system-ui, sans-serif; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
          .error { text-align: center; }
          .error h1 { font-size: 4rem; font-weight: 700; color: #e8eaf0; margin: 0; }
          .error p { font-size: 1rem; color: #8b90a0; margin-top: 0.5rem; }
          .error a { color: #5b7de6; text-decoration: none; display: inline-block; margin-top: 1.5rem; font-size: 0.875rem; }
          .error a:hover { color: #8098f0; }
        </style>
      </head>
      <body>
        <div class="error">
          <h1>{@status}</h1>
          <p>{@message}</p>
          <a href="/">Back to home</a>
        </div>
      </body>
    </html>
    """
  end
end
