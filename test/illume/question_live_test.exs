defmodule Illume.QuestionLiveTest do
  use ExUnit.Case, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Illume.LLM.ClientMock
  alias Illume.QuestionLive

  @endpoint Illume.Endpoint

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    start_supervised!({Phoenix.PubSub, name: Illume.PubSub})
    start_supervised!(Illume.Endpoint)

    Application.put_env(:illume, :qa_client, ClientMock)
    on_exit(fn -> Application.delete_env(:illume, :qa_client) end)

    {:ok, conn: Plug.Test.conn(:get, "/")}
  end

  defp text_response(text) do
    {:ok, %{"content" => [%{"type" => "text", "text" => text}], "stop_reason" => "end_turn"}}
  end

  test "renders the question form", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, QuestionLive)
    assert html =~ "Ask a question about this codebase"
  end

  test "submitting a question renders the final answer", %{conn: conn} do
    expect(ClientMock, :create, fn _params -> text_response("42") end)

    {:ok, view, _html} = live_isolated(conn, QuestionLive)
    render_submit(view, "ask", %{"question" => "what is the answer?"})

    assert wait_for(fn -> render(view) =~ "42" end)
    refute render(view) =~ "Thinking"
  end

  test "an interim status line appears before the final answer for a slow call", %{conn: conn} do
    test_pid = self()

    expect(ClientMock, :create, fn _params ->
      send(test_pid, :model_called)
      Process.sleep(150)
      text_response("slow answer")
    end)

    {:ok, view, _html} = live_isolated(conn, QuestionLive)
    render_submit(view, "ask", %{"question" => "slow?"})

    assert_receive :model_called, 100
    assert wait_for(fn -> render(view) =~ "Calling the model" end)

    assert wait_for(fn -> render(view) =~ "slow answer" end)
    assert Process.alive?(view.pid)
  end

  test "a mocked model error renders the formatted error string, not a crash", %{conn: conn} do
    expect(ClientMock, :create, fn _params -> {:error, :timeout} end)

    {:ok, view, _html} = live_isolated(conn, QuestionLive)
    render_submit(view, "ask", %{"question" => "will this fail?"})

    assert wait_for(fn -> render(view) =~ "model call timed out" end)
    assert Process.alive?(view.pid)
  end

  # `Illume.Agent`/`Illume.Tools.Runner` isolate every model/tool failure
  # into a formatted `{:error, string}` before it ever reaches
  # `Illume.QA.ask/4`'s caller (see DECISIONS.md entry 56) — there is no
  # way to reach `start_async`'s `{:exit, reason}` case through a mocked
  # client alone, only by `Illume.QA.ask/4` itself crashing (e.g. its
  # `DynamicSupervisor.start_child` match failing). Tested directly, the
  # same way `mcp_server_test.exs` unit-tests callbacks no transport can
  # cheaply exercise end to end.
  test "handle_async/3 renders a clean message for the {:exit, reason} case" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    {:noreply, socket} = QuestionLive.handle_async(:ask, {:exit, :boom}, socket)

    assert socket.assigns.answer == "Something went wrong answering that question."
    assert socket.assigns.asking? == false
  end

  describe "server-side ask guard" do
    test "a second ask while asking? is already true is a no-op", %{conn: conn} do
      test_pid = self()

      expect(ClientMock, :create, fn _params ->
        send(test_pid, :model_called)
        Process.sleep(150)
        text_response("first answer")
      end)

      {:ok, view, _html} = live_isolated(conn, QuestionLive)
      render_submit(view, "ask", %{"question" => "first?"})
      assert_receive :model_called, 500

      # Illume.QA.ask/4's Mox expectation above only allows exactly one
      # call — this second submit would blow past that (via
      # `verify_on_exit!`) if the server-side `asking?` guard didn't
      # short-circuit before ever starting a second async task.
      render_submit(view, "ask", %{"question" => "second?"})

      assert wait_for(fn -> render(view) =~ "first answer" end)
    end

    test "an empty question does not call Illume.QA.ask/4", %{conn: conn} do
      deny(ClientMock, :create, 1)

      {:ok, view, _html} = live_isolated(conn, QuestionLive)
      render_submit(view, "ask", %{"question" => "   "})

      refute render(view) =~ "Thinking"
    end

    test "an oversized question does not call Illume.QA.ask/4", %{conn: conn} do
      deny(ClientMock, :create, 1)

      {:ok, view, _html} = live_isolated(conn, QuestionLive)
      render_submit(view, "ask", %{"question" => String.duplicate("a", 4_001)})

      refute render(view) =~ "Thinking"
    end
  end

  defp wait_for(fun, retries \\ 20)
  defp wait_for(_fun, 0), do: false

  defp wait_for(fun, retries) do
    if fun.() do
      true
    else
      Process.sleep(25)
      wait_for(fun, retries - 1)
    end
  end
end
