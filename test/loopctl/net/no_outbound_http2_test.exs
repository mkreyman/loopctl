defmodule Loopctl.Net.NoOutboundHttp2Test do
  @moduledoc """
  Nothing outbound speaks HTTP/2: Req's Finch pools fall back to `protocols: [:http1]`.
  This pinned the HTTP/2-only mint advisories (CVE-2026-91043, -92103) while mint sat at
  1.10.1 with ignore entries in mix.exs (PR #926); mint 1.10.2 fixed them and the ignores
  are gone (PR #1013). The posture stays pinned here because an h2 client re-exposes the
  surface every future mint advisory will live on, and the mix.exs mint comment points
  at this test as the standing guarantee.
  """

  use ExUnit.Case, async: true

  test "nothing in lib opts an outbound client into HTTP/2" do
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(fn path -> File.read!(path) =~ ~r/:http2\b/ end)

    assert offenders == [], "outbound HTTP/2 re-opens the surface the mint advisories lived on"
  end
end
