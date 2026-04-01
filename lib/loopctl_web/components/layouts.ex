defmodule LoopctlWeb.Layouts do
  @moduledoc """
  Layout components for the loopctl web interface.

  Provides root and app layouts for HTML pages (landing page, future admin).
  """

  use LoopctlWeb, :html

  embed_templates "layouts/*"
end
