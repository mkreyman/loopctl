defmodule Loopctl.Changes.SignatureTest do
  @moduledoc "US-47.3: the chg HMAC, both directions (Epic 47 PRD §5; mkreyman/chg#33)."

  use ExUnit.Case, async: true

  alias Loopctl.Changes.Signature

  @secret String.duplicate("s", 32)
  @now 1_792_370_000

  defp header(ts, body), do: Signature.header(@secret, Signature.delivery_string(ts, body))

  test "a delivery signs \"<timestamp>.<raw body>\" as sha256=<hex>" do
    expected =
      :hmac
      |> :crypto.mac(:sha256, @secret, "1792370000.{\"a\":1}")
      |> Base.encode16(case: :lower)

    assert header("1792370000", ~s({"a":1})) == "sha256=" <> expected
  end

  test "a gap pull signs \"<timestamp>.GET.<path>?<query>\"" do
    assert Signature.pull_string("1792370000", "/api/v1/changes/01JA/events", "after=7") ==
             "1792370000.GET./api/v1/changes/01JA/events?after=7"
  end

  test "verify/5 accepts a correct signature inside the window, upper-case hex included" do
    ts = Integer.to_string(@now - 299)
    assert Signature.verify(@secret, ts, "body", header(ts, "body"), @now) == :ok

    assert Signature.verify(
             @secret,
             ts,
             "body",
             String.upcase(header(ts, "body")) |> String.replace("SHA256=", "sha256="),
             @now
           ) == :ok
  end

  test "verify/5 refuses a wrong, malformed or missing signature" do
    ts = Integer.to_string(@now)

    for sig <- [header(ts, "other"), "sha256=nothex", "md5=" <> String.duplicate("0", 64), nil] do
      assert Signature.verify(@secret, ts, "body", sig, @now) == {:error, :bad_signature}
    end

    assert Signature.verify(String.duplicate("t", 32), ts, "body", header(ts, "body"), @now) ==
             {:error, :bad_signature}
  end

  test "verify/5 refuses a timestamp outside 300 seconds either way" do
    for ts <- [@now - 301, @now + 301] do
      ts = Integer.to_string(ts)

      assert Signature.verify(@secret, ts, "body", header(ts, "body"), @now) ==
               {:error, :stale_timestamp}
    end
  end

  test "verify/5 refuses a timestamp that is not unix seconds" do
    for ts <- ["2026-10-18T00:00:00Z", "-5", "", nil] do
      assert {:error, _} =
               Signature.verify(@secret, ts, "body", header(to_string(ts), "body"), @now)
    end
  end

  test "the signature binds the timestamp: a fresh timestamp on an old signature fails" do
    old = Integer.to_string(@now - 400)
    fresh = Integer.to_string(@now)

    assert Signature.verify(@secret, fresh, "body", header(old, "body"), @now) ==
             {:error, :bad_signature}
  end
end
