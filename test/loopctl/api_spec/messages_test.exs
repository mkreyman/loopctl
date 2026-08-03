defmodule Loopctl.ApiSpec.MessagesTest do
  @moduledoc """
  #558 — the published spec and the runtime body must render the SAME text.

  This is what makes the shared definition load-bearing rather than decorative: it reads the
  OpenAPI schema's example and compares it to the canonical message. Without it, someone
  re-inlines a literal at either site and the drift is invisible again — nothing else in the
  suite compares a spec example to a response body.
  """
  use ExUnit.Case, async: true

  alias Loopctl.ApiSpec.Messages
  alias Loopctl.ApiSpec.Schemas.IngestionBacklogError

  test "the OpenAPI example for a 429 is the canonical message" do
    spec_example = IngestionBacklogError.schema().example.error.message

    assert spec_example == Messages.ingestion_backlog_exceeded(5)
  end

  test "the documented message property uses it too" do
    props = IngestionBacklogError.schema().properties.error.properties

    assert props.message.example == Messages.ingestion_backlog_exceeded(5)
  end

  test "the message does not assert a backlog that may never have been measured" do
    # Two causes, and on the metered fail-open path nothing was counted — the real backlog
    # may be zero. Wording that promises "drains" points at a remedy that may not apply.
    msg = Messages.ingestion_backlog_exceeded(5)

    refute msg =~ "already has too many"
    refute msg =~ "once the backlog drains"
    assert msg =~ "could not be measured"
    assert msg =~ "Retry after 5 seconds"
  end
end
