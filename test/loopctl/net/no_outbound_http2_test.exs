defmodule Loopctl.Net.NoOutboundHttp2Test do
  @moduledoc """
  The mint HTTP/2 advisories (CVE-2026-91043, -92103) are ignored in mix.exs ONLY because no
  outbound client speaks HTTP/2: Req's Finch pools fall back to `protocols: [:http1]`. A call
  opting into `:http2` would make them reachable while the ignore entries keep CI green, so
  this fails first (PR #926).
  """

  use ExUnit.Case, async: true

  test "nothing in lib opts an outbound client into HTTP/2" do
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(fn path -> File.read!(path) =~ ~r/:http2\b/ end)

    assert offenders == [], "outbound HTTP/2 makes the ignored mint advisories reachable"
  end
end
