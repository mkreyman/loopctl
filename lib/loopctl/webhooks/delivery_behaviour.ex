defmodule Loopctl.Webhooks.DeliveryBehaviour do
  @moduledoc """
  Behaviour for webhook HTTP delivery.

  Implementations must accept a URL, JSON body, and headers,
  then return success or failure with details.
  """

  @type headers :: [{String.t(), String.t()}]
  @type delivery_result ::
          {:ok, %{status: integer(), body: String.t()}}
          | {:error, String.t()}

  @callback deliver(url :: String.t(), body :: String.t(), headers :: headers()) ::
              delivery_result()
end
