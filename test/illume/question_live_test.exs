defmodule Illume.QuestionLiveTest do
  use ExUnit.Case, async: false

  import Mox
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn

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

    assert render_async(view) =~ "42"
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

    assert_receive :model_called, 500
    assert render(view) =~ "Calling the model"

    assert render_async(view, 500) =~ "slow answer"
    assert Process.alive?(view.pid)
  end

  test "a mocked model error renders the formatted error string, not a crash", %{conn: conn} do
    expect(ClientMock, :create, fn _params -> {:error, :timeout} end)

    {:ok, view, _html} = live_isolated(conn, QuestionLive)
    render_submit(view, "ask", %{"question" => "will this fail?"})

    assert render_async(view) =~ "model call timed out"
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

  describe "telemetry coverage" do
    test "terminate/2 detaches the telemetry handler mount/3 attached" do
      # Mirrors what `mount/3`'s `attach_telemetry/1` does for a connected
      # socket, then calls `terminate/2` directly — the same "exercise
      # the callback as a plain function" approach already used above
      # for `handle_async/3`'s `{:exit, reason}` case, rather than
      # killing a real LiveView process and fighting its test-harness
      # process topology (the proxy process `live_isolated/3` links in
      # isn't the same pid as `view.pid`, so unlinking just the latter
      # still let the former's exit signal reach this test).
      handler_id = {QuestionLive, self()}

      :telemetry.attach_many(
        handler_id,
        [[:illume, :model_call, :start]],
        &QuestionLive.forward_telemetry/4,
        self()
      )

      socket = %Phoenix.LiveView.Socket{assigns: %{telemetry_handler_id: handler_id}}
      QuestionLive.terminate(:shutdown, socket)

      refute Enum.any?(
               :telemetry.list_handlers([:illume, :model_call, :start]),
               &(&1.id == handler_id)
             )
    end

    # The real `request_id` a connection is waiting on is generated fresh
    # per `ask` (`make_ref()`) and opaque from outside `handle_event/3` —
    # there's no way for a test to fire a *matching* synthetic
    # `:telemetry.execute/3` call at a real `live_isolated/3` view from
    # here. Exercised as a plain function call instead (matching the
    # `terminate/2` test above), which also lets both the matching and
    # non-matching cases be asserted precisely.
    test "a tool_call telemetry event renders the \"Running: <name>\" status line when it matches the in-flight request" do
      request_id = make_ref()

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          asking?: true,
          current_request_id: request_id,
          status_line: nil
        }
      }

      {:noreply, socket} =
        QuestionLive.handle_info(
          {:illume_telemetry, [:illume, :tool_call, :start], %{},
           %{
             name: "read_file",
             request_id: request_id
           }},
          socket
        )

      assert socket.assigns.status_line == "Running: read_file"
    end

    test "a tool_call telemetry event from a different request does not update the status line" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          asking?: true,
          current_request_id: make_ref(),
          status_line: nil
        }
      }

      {:noreply, socket} =
        QuestionLive.handle_info(
          {:illume_telemetry, [:illume, :tool_call, :start], %{},
           %{
             name: "read_file",
             request_id: make_ref()
           }},
          socket
        )

      assert socket.assigns.status_line == nil
    end
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

      assert render_async(view, 500) =~ "first answer"
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

    # A non-string `question` can only arrive via a raw socket frame — the
    # real `<input>` always submits a string — so this is exercised as a
    # plain function call, mirroring `handle_async/3`'s `{:exit, reason}`
    # test above rather than driving it through `render_submit/3`.
    test "a non-binary question does not crash the session" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, authorized?: true, asking?: false, question: ""}
      }

      assert {:noreply, ^socket} = QuestionLive.handle_event("ask", %{"question" => 123}, socket)
    end
  end

  describe "bearer-token auth (P2-T3)" do
    # `live_isolated/3` never routes real query params (it always passes
    # the literal atom `:not_mounted_at_router` to `mount/3`), so these
    # go through the real router via `live/2` instead — the only way to
    # actually exercise the `?token=...` query param this check relies on.
    setup do
      Application.put_env(:illume, :web_token, "expected-token")
      on_exit(fn -> Application.delete_env(:illume, :web_token) end)
      :ok
    end

    test "mounting with no token does not render the ask form" do
      {:ok, _view, html} = build_conn() |> get("/") |> live()

      refute html =~ "Ask a question about this codebase"
      assert html =~ "Unauthorized"
    end

    test "mounting with the wrong token does not render the ask form" do
      {:ok, _view, html} = build_conn() |> get("/?token=wrong") |> live()

      refute html =~ "Ask a question about this codebase"
      assert html =~ "Unauthorized"
    end

    test "mounting with the correct token renders the ask form" do
      {:ok, _view, html} = build_conn() |> get("/?token=expected-token") |> live()

      assert html =~ "Ask a question about this codebase"
    end

    test "an ask event while unauthorized does not call Illume.QA.ask/4" do
      deny(ClientMock, :create, 1)

      {:ok, view, _html} = build_conn() |> get("/?token=wrong") |> live()
      render_submit(view, "ask", %{"question" => "hello?"})

      refute render(view) =~ "Thinking"
    end
  end
end
