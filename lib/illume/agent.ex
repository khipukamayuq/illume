defmodule Illume.Agent do
  @moduledoc """
  Conversation state machine for a single question against a single target
  directory. Hand-built multi-step tool-calling loop — deliberately does
  NOT use `ReqAnthropic.Messages.run/1`.

  One agent answers one question: `ask/2` is expected to be called once per
  process. State moves `:idle -> :awaiting_model -> (:awaiting_tool ->
  :awaiting_model)* -> :done`, driven by `handle_continue/2` so each step is
  independently testable and the original caller stays blocked on
  `GenServer.reply/2` for the whole loop.

  `messages` is kept most-recent-first internally (prepending is O(1),
  unlike appending to the end of a list) and reversed into chronological
  order only when actually sent to the model in `call_model/1`.
  """

  use GenServer

  alias Illume.Tools

  @default_max_iterations 10
  @default_tool_timeout 10_000

  defstruct [
    :target_dir,
    :client,
    :system,
    :from,
    messages: [],
    status: :idle,
    iteration: 0,
    max_iterations: @default_max_iterations,
    tool_timeout: @default_tool_timeout,
    tool_backend: :direct
  ]

  @type t :: %__MODULE__{
          target_dir: Path.t(),
          client: module(),
          system: String.t(),
          from: GenServer.from() | nil,
          messages: [map()],
          status: :idle | :awaiting_model | :awaiting_tool | :done,
          iteration: non_neg_integer(),
          max_iterations: pos_integer(),
          tool_timeout: timeout(),
          tool_backend: Tools.backend()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Ask a question and block until the agent produces a final answer."
  @spec ask(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def ask(pid, question) do
    GenServer.call(pid, {:ask, question}, :infinity)
  end

  @impl true
  def init(opts) do
    target_dir = Keyword.fetch!(opts, :target_dir)

    state = %__MODULE__{
      target_dir: target_dir,
      client: Keyword.get(opts, :client, Illume.LLM.AnthropicClient),
      system: Illume.LLM.Prompts.system(target_dir),
      max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations),
      tool_timeout: Keyword.get(opts, :tool_timeout, @default_tool_timeout),
      tool_backend: Keyword.get(opts, :tool_backend, :direct)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:ask, question}, from, %__MODULE__{status: :idle} = state) do
    state = %{
      state
      | messages: [%{role: "user", content: question} | state.messages],
        from: from,
        status: :awaiting_model
    }

    {:noreply, state, {:continue, :call_model}}
  end

  def handle_call({:ask, _question}, _from, state) do
    {:reply, {:error, :busy}, state}
  end

  @impl true
  def handle_continue(:call_model, state) do
    telemetry([:loop_turn, :start], %{iteration: state.iteration})
    telemetry([:model_call, :start], %{})

    case call_model(state) do
      {:ok, %{"content" => content} = body} ->
        telemetry([:model_call, :stop], %{stop_reason: body["stop_reason"]})
        handle_model_response(content, state)

      {:ok, body} ->
        telemetry([:model_call, :exception], %{reason: :unexpected_response})
        finish(state, {:error, "unexpected API response: #{inspect(body)}"})

      {:error, reason} ->
        telemetry([:model_call, :exception], %{reason: reason})
        finish(state, {:error, format_error(reason)})
    end
  end

  def handle_continue({:run_tools, tool_uses}, state) do
    tool_results = Enum.map(tool_uses, &run_tool(&1, state))
    state = %{state | messages: [%{role: "user", content: tool_results} | state.messages]}
    telemetry([:loop_turn, :stop], %{iteration: state.iteration})
    {:noreply, state, {:continue, :call_model}}
  end

  @spec call_model(t()) :: {:ok, map()} | {:error, term()}
  defp call_model(state) do
    params = %{
      system: state.system,
      tools: Tools.specs(),
      messages: Enum.reverse(state.messages)
    }

    state.client.create(params)
  rescue
    e -> {:error, e}
  end

  @spec handle_model_response([map()], t()) ::
          {:noreply, t()} | {:noreply, t(), {:continue, {:run_tools, [map()]}}}
  defp handle_model_response(content, state) do
    state = %{state | messages: [%{role: "assistant", content: content} | state.messages]}
    tool_uses = Enum.filter(content, &match?(%{"type" => "tool_use"}, &1))

    cond do
      tool_uses == [] ->
        telemetry([:loop_turn, :stop], %{iteration: state.iteration})
        finish(state, {:ok, extract_text(content)})

      state.iteration >= state.max_iterations ->
        telemetry([:loop_turn, :stop], %{iteration: state.iteration, gave_up: true})

        finish(
          state,
          {:ok,
           "I gave up after #{state.max_iterations} tool-use turns without reaching a final answer."}
        )

      true ->
        state = %{state | status: :awaiting_tool, iteration: state.iteration + 1}
        {:noreply, state, {:continue, {:run_tools, tool_uses}}}
    end
  end

  @spec finish(t(), {:ok, String.t()} | {:error, term()}) :: {:noreply, t()}
  defp finish(state, reply) do
    GenServer.reply(state.from, reply)
    {:noreply, %{state | status: :done, from: nil}}
  end

  @spec run_tool(map(), t()) :: map()
  defp run_tool(%{"id" => id, "name" => name, "input" => input}, state) do
    telemetry([:tool_call, :start], %{name: name})

    if Tools.allowed?(name) do
      run_allowed_tool(id, name, input, state)
    else
      telemetry([:tool_call, :exception], %{name: name, reason: :not_allowed})
      tool_result(id, "tool #{name} is not allowed", true)
    end
  end

  @spec run_allowed_tool(String.t(), String.t(), map(), t()) :: map()
  defp run_allowed_tool(id, name, input, state) do
    fun = fn -> Tools.dispatch(name, input, state.target_dir, state.tool_backend) end

    case Illume.Tools.Runner.run(fun, state.tool_timeout) do
      {:ok, {:ok, result}} ->
        telemetry([:tool_call, :stop], %{name: name})
        tool_result(id, to_content_string(result), false)

      {:ok, {:error, reason}} ->
        telemetry([:tool_call, :stop], %{name: name, error: true})
        tool_result(id, to_content_string(reason), true)

      {:error, :timeout} ->
        telemetry([:tool_call, :exception], %{name: name, reason: :timeout})
        tool_result(id, "tool #{name} timed out", true)

      {:error, {:crashed, reason}} ->
        telemetry([:tool_call, :exception], %{name: name, reason: reason})
        tool_result(id, "tool #{name} crashed: #{inspect(reason)}", true)
    end
  end

  @spec tool_result(String.t(), String.t(), boolean()) :: map()
  defp tool_result(id, content, is_error?) do
    %{type: "tool_result", tool_use_id: id, content: content, is_error: is_error?}
  end

  @spec to_content_string(term()) :: String.t()
  defp to_content_string(result) when is_binary(result), do: result
  defp to_content_string(result) when is_list(result), do: Enum.join(result, "\n")
  defp to_content_string(result), do: inspect(result)

  @spec extract_text([map()]) :: String.t()
  defp extract_text(content) do
    content
    |> Enum.filter(&match?(%{"type" => "text"}, &1))
    |> Enum.map_join("\n", & &1["text"])
  end

  @spec format_error(term()) :: String.t()
  defp format_error(reason) when is_exception(reason), do: Exception.message(reason)
  defp format_error(reason), do: inspect(reason)

  @spec telemetry([atom()], map()) :: :ok
  defp telemetry(event_suffix, metadata) do
    :telemetry.execute([:illume | event_suffix], %{system_time: System.system_time()}, metadata)
  end
end
