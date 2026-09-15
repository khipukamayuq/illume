defmodule Illume.AsyncSpikeTest do
  @moduledoc """
  Throwaway spike (plan task 3.1) proving two `start_async`/`handle_async`
  claims directly against the real library, not from docs, before
  Component 3 is built on top of them:

  1. a raising async fun delivers `{:exit, reason}` to `handle_async/3`
     without crashing the LiveView process;
  2. there is no built-in timeout — a fun still running past 5s (the old
     `async_stream_nolink` default this project was burned by once, see
     DECISIONS.md entry 45) is neither killed nor treated as a crash.

  See DECISIONS.md entry 56 for the source-level mechanism these confirm
  (`Phoenix.LiveView.Async.do_async/5`'s try/catch + explicit unlink before
  re-raising) and the one scenario it does NOT cover (an inner linked
  process crashing) — irrelevant to `Illume.QA.ask/4`, which never spawns
  a nested linked process, but worth the record.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  @endpoint Illume.Endpoint

  setup do
    start_supervised!({Phoenix.PubSub, name: Illume.PubSub})
    start_supervised!(Illume.Endpoint)
    {:ok, conn: Plug.Test.conn(:get, "/")}
  end

  defmodule SpikeLive do
    @moduledoc false
    use Phoenix.LiveView

    @impl true
    def mount(_params, _session, socket), do: {:ok, assign(socket, status: :idle, result: nil)}

    @impl true
    def render(assigns) do
      ~H"""
      <div>status: {@status}</div>
      <div>result: {inspect(@result)}</div>
      """
    end

    @impl true
    def handle_event("raise", _params, socket) do
      {:noreply,
       socket
       |> assign(status: :running)
       |> start_async(:spike, fn -> raise "boom" end)}
    end

    def handle_event("slow", _params, socket) do
      {:noreply,
       socket
       |> assign(status: :running)
       |> start_async(:spike, fn ->
         Process.sleep(6_000)
         :finished
       end)}
    end

    @impl true
    def handle_async(:spike, {:exit, reason}, socket) do
      {:noreply, assign(socket, status: :exited, result: reason)}
    end

    def handle_async(:spike, {:ok, result}, socket) do
      {:noreply, assign(socket, status: :ok, result: result)}
    end
  end

  test "a raising async fun delivers {:exit, reason} without crashing the LiveView", %{
    conn: conn
  } do
    {:ok, view, _html} = live_isolated(conn, SpikeLive)

    render_click(view, "raise")

    assert render(view) =~ "exited"
    assert Process.alive?(view.pid)
  end

  test "no built-in timeout: a fun running past 5s is neither killed nor treated as a crash", %{
    conn: conn
  } do
    {:ok, view, _html} = live_isolated(conn, SpikeLive)

    render_click(view, "slow")

    # past the old async_stream_nolink 5s default (DECISIONS.md entry 45)
    # with no sign of a timeout kicking in
    Process.sleep(5_500)
    assert render(view) =~ "running"
    assert Process.alive?(view.pid)

    # then confirm it completes normally once the fun actually returns
    Process.sleep(1_000)
    assert render(view) =~ "ok"
    assert Process.alive?(view.pid)
  end
end
