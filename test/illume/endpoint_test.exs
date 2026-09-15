defmodule Illume.EndpointTest do
  @moduledoc """
  Goes through the real endpoint plug pipeline (`Phoenix.ConnTest`, not
  `live_isolated/3`) — the regression guard against the exact gap the
  `/phx:review` pass found: every other test bypassed the browser/JS layer
  entirely (see DECISIONS.md entry 61).
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint Illume.Endpoint

  setup do
    start_supervised!({Phoenix.PubSub, name: Illume.PubSub})
    start_supervised!(Illume.Endpoint)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  test "serves the vendored phoenix.js", %{conn: conn} do
    conn = get(conn, "/assets/phoenix.js")

    assert conn.status == 200
    assert response(conn, 200) =~ "Phoenix"
  end

  test "serves the vendored phoenix_live_view.js", %{conn: conn} do
    conn = get(conn, "/assets/phoenix_live_view.js")

    assert conn.status == 200
    assert response(conn, 200) =~ "LiveView"
  end

  test "the index page carries standard security headers", %{conn: conn} do
    conn = get(conn, "/")

    assert conn.status == 200
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "x-permitted-cross-domain-policies") == ["none"]
  end
end
