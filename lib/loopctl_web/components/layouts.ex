defmodule LoopctlWeb.Layouts do
  @moduledoc """
  Layout components for the loopctl web interface.

  Provides root and app layouts for HTML pages (landing page, future
  admin) as well as the `app/1` function component used by LiveViews.
  The `app/1` function is compiled from `layouts/app.html.heex` via
  `embed_templates/1`.
  """

  use LoopctlWeb, :html

  embed_templates "layouts/*"
end
