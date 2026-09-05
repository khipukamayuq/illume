defmodule Illume.LLM.AnthropicClientTest do
  use ExUnit.Case, async: true

  alias Illume.LLM.AnthropicClient

  test "sends the model, max_tokens, and forwards system/tools/messages" do
    Req.Test.stub(AnthropicClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:captured_request, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => "hi"}],
        "stop_reason" => "end_turn"
      })
    end)

    params = %{
      system: "you are a test",
      tools: [%{name: "noop", description: "does nothing", input_schema: %{type: "object"}}],
      messages: [%{role: "user", content: "hello"}]
    }

    assert {:ok, %{"content" => [%{"text" => "hi"}], "stop_reason" => "end_turn"}} =
             AnthropicClient.create(params)

    assert_received {:captured_request, request_body}
    assert request_body["model"] == "claude-sonnet-5"
    assert request_body["max_tokens"] == 4096
    assert request_body["system"] == "you are a test"
    assert request_body["messages"] == [%{"role" => "user", "content" => "hello"}]
    assert [%{"name" => "noop"}] = request_body["tools"]
  end

  test "propagates an API error as {:error, %ReqAnthropic.Error{}}" do
    Req.Test.stub(AnthropicClient, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "type" => "error",
        "error" => %{"type" => "invalid_request_error", "message" => "bad request"}
      })
    end)

    params = %{system: "sys", tools: [], messages: [%{role: "user", content: "hi"}]}

    assert {:error, %ReqAnthropic.Error{status: 400, message: "bad request"}} =
             AnthropicClient.create(params)
  end
end
