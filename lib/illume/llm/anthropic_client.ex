defmodule Illume.LLM.AnthropicClient do
  @moduledoc """
  Real `Illume.LLM.Client` implementation, wrapping
  `ReqAnthropic.Messages.create/1` — the primitive, single-shot call.
  `ReqAnthropic.Messages.run/1` (the automatic tool-execution loop) is
  deliberately never used; `Illume.Agent` is the loop.
  """

  @behaviour Illume.LLM.Client

  @model "claude-sonnet-5"
  @max_tokens 4096

  @impl true
  def create(params) do
    ReqAnthropic.Messages.create(
      model: @model,
      max_tokens: @max_tokens,
      system: Map.fetch!(params, :system),
      tools: Map.fetch!(params, :tools),
      messages: Map.fetch!(params, :messages)
    )
  end
end
