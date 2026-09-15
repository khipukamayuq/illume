defmodule Illume.QuestionLive do
  @moduledoc """
  Single-page question/answer UI over `Illume.QA.ask/4`, run via
  `mix illume.server`. `target_dir` is a hardcoded compile-time constant —
  illume's own checkout, resolved from this module's own source location
  so it's correct regardless of the directory `mix` was invoked from —
  never form input; the spec requires this endpoint never accept an
  arbitrary filesystem path from an HTTP request (see DECISIONS.md
  entry 58).
  """

  use Phoenix.LiveView

  alias Phoenix.LiveView.Socket

  @target_dir Path.expand("../..", __DIR__)

  @telemetry_events [
    [:illume, :model_call, :start],
    [:illume, :tool_call, :start],
    [:illume, :loop_turn, :stop]
  ]

  @impl true
  def mount(_params, _session, socket) do
    handler_id = attach_telemetry(socket)

    {:ok,
     assign(socket,
       question: "",
       answer: nil,
       asking?: false,
       status_line: nil,
       telemetry_handler_id: handler_id
     )}
  end

  # Only the connected mount (not the initial static render) gets a handler
  # — attaching twice per connection would leak one on every reconnect,
  # and the static render's process never lives long enough to need one.
  @spec attach_telemetry(Socket.t()) :: term() | nil
  defp attach_telemetry(socket) do
    if connected?(socket) do
      handler_id = {__MODULE__, self()}

      :telemetry.attach_many(
        handler_id,
        @telemetry_events,
        &__MODULE__.forward_telemetry/4,
        self()
      )

      handler_id
    end
  end

  @doc false
  @spec forward_telemetry([atom()], map(), map(), pid()) :: :ok
  def forward_telemetry(event, measurements, metadata, lv_pid) do
    send(lv_pid, {:illume_telemetry, event, measurements, metadata})
    :ok
  end

  @impl true
  def terminate(_reason, socket) do
    if handler_id = socket.assigns[:telemetry_handler_id] do
      :telemetry.detach(handler_id)
    end

    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1>Illume</h1>
      <form phx-submit="ask">
        <input
          type="text"
          name="question"
          value={@question}
          placeholder="Ask a question about this codebase"
          disabled={@asking?}
        />
        <button type="submit" disabled={@asking?}>Ask</button>
      </form>
      <p :if={@status_line}>{@status_line}</p>
      <p :if={@answer}>{@answer}</p>
    </div>
    """
  end

  @impl true
  def handle_event("ask", %{"question" => question}, socket) do
    opts = qa_opts()

    socket =
      socket
      |> assign(question: question, answer: nil, asking?: true, status_line: "Thinking…")
      |> start_async(:ask, fn -> Illume.QA.ask(@target_dir, question, :direct, opts) end)

    {:noreply, socket}
  end

  # Test-only seam, same shape as `Illume.Tools.MCP.client_adapter/0`: lets
  # tests inject a mocked `Illume.LLM.Client` without threading a new
  # parameter through `handle_event/3`. `target_dir` itself is never
  # configurable this way — that stays a compile-time constant regardless.
  @spec qa_opts() :: keyword()
  defp qa_opts do
    case Application.get_env(:illume, :qa_client) do
      nil -> []
      client -> [client: client]
    end
  end

  @impl true
  def handle_async(:ask, {:ok, {:ok, text}}, socket) do
    {:noreply, assign(socket, answer: text, asking?: false, status_line: nil)}
  end

  def handle_async(:ask, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, answer: reason, asking?: false, status_line: nil)}
  end

  def handle_async(:ask, {:exit, _reason}, socket) do
    {:noreply,
     assign(socket,
       answer: "Something went wrong answering that question.",
       asking?: false,
       status_line: nil
     )}
  end

  # `:telemetry` events aren't scoped to a request — every LiveView
  # connection's handler receives every agent's events. Only apply one
  # while *this* connection is actually waiting on an answer, or an
  # unrelated question (another tab, another user) would flash a stray
  # status line here.
  @impl true
  def handle_info({:illume_telemetry, event, _measurements, metadata}, socket) do
    if socket.assigns.asking? do
      {:noreply, assign(socket, status_line: status_line_for(event, metadata))}
    else
      {:noreply, socket}
    end
  end

  @spec status_line_for([atom()], map()) :: String.t()
  defp status_line_for([:illume, :model_call, :start], _metadata), do: "Calling the model…"
  defp status_line_for([:illume, :tool_call, :start], %{name: name}), do: "Running: #{name}"
  defp status_line_for([:illume, :loop_turn, :stop], _metadata), do: "Thinking…"
end
