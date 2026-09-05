defmodule Illume.LLM.Client do
  @moduledoc """
  Behaviour for the LLM client `Illume.Agent` talks to. Exists so tests can
  inject a Mox double and drive the GenServer's state machine without any
  network access.
  """

  @doc """
  Send one non-streaming Messages request. `params` carries `:system`,
  `:tools`, and `:messages` — everything else (model, max_tokens, auth) is
  the implementation's concern.
  """
  @callback create(params :: map()) :: {:ok, map()} | {:error, term()}
end
