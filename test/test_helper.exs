ExUnit.start()

Mox.defmock(Illume.LLM.ClientMock, for: Illume.LLM.Client)
Mox.defmock(Illume.Tools.MCP.ClientMock, for: Illume.Tools.MCP.Client)

# Route ReqAnthropic's HTTP calls through Req.Test instead of the network;
# each test controls the response via Req.Test.stub/expect.
Application.put_env(:req_anthropic, :plug, {Req.Test, Illume.LLM.AnthropicClient})

# Every test that exercises the :mcp tool backend wants the same mock
# module here — Mox's own per-process expectation ownership (not this
# value) is what actually isolates concurrent tests from each other, so
# this is safe to set once rather than per-test.
Application.put_env(:illume, :mcp_client, Illume.Tools.MCP.ClientMock)
