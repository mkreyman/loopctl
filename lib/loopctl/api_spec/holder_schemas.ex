defmodule Loopctl.ApiSpec.HolderSchemas do
  @moduledoc "OpenAPI schemas for the session holder endpoints (US-52.13)."

  alias OpenApiSpex.Schema

  defmodule Holder do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Holder",
      description:
        "One session of an agent. Live while `ended_at` is null; its lease runs to " <>
          "`lease_until`, renewed by each heartbeat.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        agent_id: %Schema{type: :string, format: :uuid},
        kind: %Schema{type: :string, enum: ["runner_session", "interactive", "cloud"]},
        session_id: %Schema{type: :string},
        host: %Schema{type: :string},
        worktree: %Schema{type: :string, nullable: true},
        dispatch_id: %Schema{type: :string, format: :uuid, nullable: true},
        last_seen_at: %Schema{type: :string, format: :"date-time"},
        lease_until: %Schema{type: :string, format: :"date-time"},
        ended_at: %Schema{type: :string, format: :"date-time", nullable: true},
        ended_reason: %Schema{type: :string, enum: ["ended", "lapsed"], nullable: true}
      }
    })
  end

  defmodule RegisterRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HolderRegisterRequest",
      type: :object,
      properties: %{
        kind: %Schema{
          type: :string,
          enum: ["interactive", "cloud"],
          description: "Runner sessions are holders through placement, never through this call"
        },
        session_id: %Schema{type: :string, maxLength: 255},
        host: %Schema{type: :string, maxLength: 255},
        worktree: %Schema{type: :string, maxLength: 4096, nullable: true}
      },
      required: [:kind, :session_id, :host]
    })
  end

  defmodule Credential do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HolderCredential",
      description: "The holder's API key. `raw_key` is returned once and never again.",
      type: :object,
      properties: %{
        raw_key: %Schema{type: :string},
        api_key_id: %Schema{type: :string, format: :uuid},
        key_prefix: %Schema{type: :string},
        expires_at: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  defmodule RegisterResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HolderRegisterResponse",
      type: :object,
      properties: %{
        holder: Loopctl.ApiSpec.HolderSchemas.Holder,
        credential: %Schema{
          allOf: [Loopctl.ApiSpec.HolderSchemas.Credential],
          nullable: true,
          description: "null when the calling key is already this holder's credential"
        },
        heartbeat_seconds: %Schema{type: :integer}
      }
    })
  end

  defmodule HeartbeatResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HolderHeartbeatResponse",
      type: :object,
      properties: %{
        lease_until: %Schema{type: :string, format: :"date-time"},
        heartbeat_seconds: %Schema{type: :integer}
      },
      required: [:lease_until, :heartbeat_seconds]
    })
  end

  defmodule HolderResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HolderResponse",
      type: :object,
      properties: %{holder: Loopctl.ApiSpec.HolderSchemas.Holder}
    })
  end
end
