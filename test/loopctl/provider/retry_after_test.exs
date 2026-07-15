defmodule Loopctl.Provider.RetryAfterTest do
  @moduledoc "US-37.3 (TC-37.3.2): the provider Retry-After parser."
  use ExUnit.Case, async: true

  alias Loopctl.Provider.RetryAfter

  describe "parse/1" do
    test "delta-seconds integer string parses to that many seconds" do
      assert RetryAfter.parse("30") == 30
      assert RetryAfter.parse("0") == 0
      assert RetryAfter.parse("  15  ") == 15
    end

    test "an IMF-fixdate HTTP-date ~30s out parses to ~30s (max(0, diff))" do
      target =
        DateTime.utc_now()
        |> DateTime.add(30, :second)
        |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

      seconds = RetryAfter.parse(target)
      # Class assertion (not an exact instant): within a small window of 30s.
      assert seconds >= 27 and seconds <= 30
    end

    test "an HTTP-date in the PAST clamps to 0 (never negative)" do
      past =
        DateTime.utc_now()
        |> DateTime.add(-120, :second)
        |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

      assert RetryAfter.parse(past) == 0
    end

    test "absent / empty / malformed values → nil (defensive fallback)" do
      assert RetryAfter.parse(nil) == nil
      assert RetryAfter.parse("") == nil
      assert RetryAfter.parse("   ") == nil
      assert RetryAfter.parse("garbage") == nil
      # Fractional and negative delta-seconds are malformed per RFC → nil.
      assert RetryAfter.parse("30.5") == nil
      assert RetryAfter.parse("-5") == nil
      # A non-binary is defensively nil.
      assert RetryAfter.parse(:not_a_string) == nil
    end

    test "clamps a hostile huge value to the SystemConfig max (default 300s)" do
      assert RetryAfter.parse("999999999") == RetryAfter.max_seconds()
      assert RetryAfter.max_seconds() == 300
    end
  end

  describe "from_error/1" do
    test "extracts the Retry-After from the throttle 4-tuple" do
      assert RetryAfter.from_error({:api_error, 429, :provider_error, 42}) == 42
    end

    test "returns nil for the legacy 3-tuple and any other term" do
      assert RetryAfter.from_error({:api_error, 429, :provider_error}) == nil
      assert RetryAfter.from_error({:api_error, 500}) == nil
      assert RetryAfter.from_error(:timeout) == nil
      assert RetryAfter.from_error({:api_error, 429, :provider_error, nil}) == nil
    end
  end

  describe "from_response/2" do
    test "parses Retry-After only for throttle statuses (429/503)" do
      resp = %Req.Response{status: 429, headers: %{"retry-after" => ["30"]}}
      assert RetryAfter.from_response(429, resp) == 30

      resp503 = %Req.Response{status: 503, headers: %{"retry-after" => ["45"]}}
      assert RetryAfter.from_response(503, resp503) == 45
    end

    test "ignores Retry-After for non-throttle statuses" do
      resp = %Req.Response{status: 401, headers: %{"retry-after" => ["30"]}}
      assert RetryAfter.from_response(401, resp) == nil
    end

    test "a throttle status with no Retry-After header → nil" do
      resp = %Req.Response{status: 429, headers: %{}}
      assert RetryAfter.from_response(429, resp) == nil
    end
  end
end
