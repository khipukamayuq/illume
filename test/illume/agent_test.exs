defmodule Illume.AgentTest do
  use ExUnit.Case, async: true

  import Mox

  alias Illume.Agent
  alias Illume.LLM.ClientMock

  setup :verify_on_exit!
  @moduletag :tmp_dir

  defp text_response(text) do
    {:ok, %{"content" => [%{"type" => "text", "text" => text}], "stop_reason" => "end_turn"}}
  end

  defp tool_use_response(name, input, id \\ "toolu_1") do
    {:ok,
     %{
       "content" => [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}],
       "stop_reason" => "tool_use"
     }}
  end

  defp tool_use_response_multi(specs) do
    content =
      Enum.map(specs, fn {name, input, id} ->
        %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
      end)

    {:ok, %{"content" => content, "stop_reason" => "tool_use"}}
  end

  defp mcp_text_result(text) do
    {:ok, %{result: %{"content" => [%{"type" => "text", "text" => text}]}, is_error: false}}
  end

  defp start_agent(opts) do
    pid = start_supervised!({Agent, Keyword.put_new(opts, :client, ClientMock)})
    allow(ClientMock, self(), pid)
    pid
  end

  test "an unexpected-but-successful API response is a clean error, not a crash", %{
    tmp_dir: tmp_dir
  } do
    expect(ClientMock, :create, fn _params -> {:ok, %{"stop_reason" => "end_turn"}} end)

    pid = start_agent(target_dir: tmp_dir)

    assert {:error, message} = Agent.ask(pid, "what is the answer?")
    assert message =~ "unexpected API response"
    assert Process.alive?(pid)
  end

  test "a model call that outlives model_timeout is a clean error, not a hang", %{
    tmp_dir: tmp_dir
  } do
    stub(ClientMock, :create, fn _params ->
      Process.sleep(50)
      text_response("too slow")
    end)

    pid = start_agent(target_dir: tmp_dir, model_timeout: 1)

    assert {:error, message} = Agent.ask(pid, "what is the answer?")
    assert message =~ "timed out"
    assert Process.alive?(pid)
  end

  test "a model call that raises is a clean error, not a crash", %{tmp_dir: tmp_dir} do
    expect(ClientMock, :create, fn _params -> raise "boom" end)

    pid = start_agent(target_dir: tmp_dir)

    assert {:error, "boom"} = Agent.ask(pid, "what is the answer?")
    assert Process.alive?(pid)
  end

  test "a model call that crashes without raising an exception reports the reason without a stacktrace",
       %{tmp_dir: tmp_dir} do
    expect(ClientMock, :create, fn _params -> throw(:mocked_boom) end)

    pid = start_agent(target_dir: tmp_dir)

    assert {:error, message} = Agent.ask(pid, "what is the answer?")
    assert message =~ "mocked_boom"
    refute message =~ "Task.Supervised"
    refute message =~ "elixir.erl"
    assert Process.alive?(pid)
  end

  test "idle -> awaiting_model -> done happy path (no tool use)", %{tmp_dir: tmp_dir} do
    expect(ClientMock, :create, fn params ->
      assert [%{role: "user", content: "what is the answer?"}] = params.messages
      text_response("The answer is 42.")
    end)

    pid = start_agent(target_dir: tmp_dir)

    assert {:ok, "The answer is 42."} = Agent.ask(pid, "what is the answer?")
    assert Process.alive?(pid)
  end

  test "idle -> awaiting_model -> awaiting_tool -> awaiting_model -> done", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "foo.exs"), "IO.puts(:hi)")

    expect(ClientMock, :create, fn params ->
      assert [%{role: "user"}] = params.messages
      tool_use_response("search_files", %{"pattern" => "*.exs"})
    end)

    expect(ClientMock, :create, fn params ->
      assert [%{role: "user"}, %{role: "assistant"}, %{role: "user", content: [result]}] =
               params.messages

      assert result.type == "tool_result"
      assert result.tool_use_id == "toolu_1"
      refute Map.get(result, :is_error, false)
      assert result.content =~ "foo.exs"

      text_response("Found foo.exs.")
    end)

    pid = start_agent(target_dir: tmp_dir)

    assert {:ok, "Found foo.exs."} = Agent.ask(pid, "where are the exs files?")
    assert Process.alive?(pid)
  end

  test "gives up after max_iterations instead of looping forever", %{tmp_dir: tmp_dir} do
    stub(ClientMock, :create, fn _params ->
      tool_use_response("search_files", %{"pattern" => "*.ex"})
    end)

    pid = start_agent(target_dir: tmp_dir, max_iterations: 2)

    assert {:ok, message} = Agent.ask(pid, "loop forever")
    assert message =~ "gave up after 2"
    assert Process.alive?(pid)
  end

  test "a crashing tool is recovered as an error tool_result, not an agent crash", %{
    tmp_dir: tmp_dir
  } do
    expect(ClientMock, :create, fn _params ->
      tool_use_response("read_file", %{"path" => nil})
    end)

    expect(ClientMock, :create, fn params ->
      assert [_, _, %{role: "user", content: [result]}] = params.messages
      assert result.type == "tool_result"
      assert result.is_error == true
      assert result.content =~ "crashed"

      text_response("Recovered from the crash.")
    end)

    pid = start_agent(target_dir: tmp_dir)

    assert {:ok, "Recovered from the crash."} = Agent.ask(pid, "read a bad path")
    assert Process.alive?(pid)
  end

  test "a tool crashing without raising an exception reports the reason without a stacktrace",
       %{tmp_dir: tmp_dir} do
    expect(ClientMock, :create, fn _params ->
      tool_use_response("read_file", %{"path" => "a.txt"})
    end)

    expect(ClientMock, :create, fn params ->
      assert [_, _, %{role: "user", content: [result]}] = params.messages
      assert result.is_error == true
      assert result.content =~ "mocked_boom"
      refute result.content =~ "Task.Supervised"
      refute result.content =~ "elixir.erl"

      text_response("Recovered from the crash.")
    end)

    pid = start_agent(target_dir: tmp_dir, tool_backend: :mcp)
    allow(Illume.Tools.MCP.ClientMock, self(), pid)

    stub(Illume.Tools.MCP.ClientMock, :call_tool, fn Illume.MCP.FilesystemClient,
                                                     "read_text_file",
                                                     _args ->
      throw(:mocked_boom)
    end)

    assert {:ok, "Recovered from the crash."} = Agent.ask(pid, "read a bad path")
    assert Process.alive?(pid)
  end

  test "a tool's ordinary (non-crash) error result is fed back to the model", %{
    tmp_dir: tmp_dir
  } do
    expect(ClientMock, :create, fn _params ->
      tool_use_response("read_file", %{"path" => "does_not_exist.txt"})
    end)

    expect(ClientMock, :create, fn params ->
      assert [_, _, %{role: "user", content: [result]}] = params.messages
      assert result.type == "tool_result"
      assert result.is_error == true
      assert result.content =~ "no such file"

      text_response("That file doesn't exist.")
    end)

    pid = start_agent(target_dir: tmp_dir)

    assert {:ok, "That file doesn't exist."} = Agent.ask(pid, "read a missing file")
    assert Process.alive?(pid)
  end

  test "a timing-out tool is recovered as an error tool_result, not an agent crash", %{
    tmp_dir: tmp_dir
  } do
    expect(ClientMock, :create, fn _params ->
      tool_use_response("git_log", %{})
    end)

    expect(ClientMock, :create, fn params ->
      assert [_, _, %{role: "user", content: [result]}] = params.messages
      assert result.type == "tool_result"
      assert result.is_error == true
      assert result.content =~ "timed out"

      text_response("Recovered from the timeout.")
    end)

    pid = start_agent(target_dir: tmp_dir, tool_timeout: 0)

    assert {:ok, "Recovered from the timeout."} = Agent.ask(pid, "show recent commits")
    assert Process.alive?(pid)
  end

  test "a disallowed tool name is rejected as an error tool_result before dispatch", %{
    tmp_dir: tmp_dir
  } do
    expect(ClientMock, :create, fn _params ->
      tool_use_response("git_commit", %{"message" => "pwned"})
    end)

    expect(ClientMock, :create, fn params ->
      assert [_, _, %{role: "user", content: [result]}] = params.messages
      assert result.is_error == true
      assert result.content =~ "not allowed"

      text_response("I can't do that.")
    end)

    pid = start_agent(target_dir: tmp_dir)

    assert {:ok, "I can't do that."} = Agent.ask(pid, "commit this")
    assert Process.alive?(pid)
  end

  test "returns {:error, :busy} for a second concurrent ask", %{tmp_dir: tmp_dir} do
    test_pid = self()

    stub(ClientMock, :create, fn _params ->
      send(test_pid, :model_called)
      Process.sleep(50)
      text_response("done")
    end)

    pid = start_agent(target_dir: tmp_dir)

    task = Task.async(fn -> Agent.ask(pid, "first question") end)
    assert_receive :model_called, 100

    assert {:error, :busy} = Agent.ask(pid, "second question")
    assert {:ok, "done"} = Task.await(task)
  end

  test "runs multiple tool_use calls in one turn concurrently, preserving request order",
       %{tmp_dir: tmp_dir} do
    expect(ClientMock, :create, fn _params ->
      tool_use_response_multi([
        {"read_file", %{"path" => "a.txt"}, "toolu_1"},
        {"git_log", %{}, "toolu_2"}
      ])
    end)

    expect(ClientMock, :create, fn params ->
      assert [_question, _assistant, %{role: "user", content: [first, second]}] = params.messages
      assert first.tool_use_id == "toolu_1"
      assert second.tool_use_id == "toolu_2"
      text_response("done")
    end)

    pid = start_agent(target_dir: tmp_dir, tool_backend: :mcp)
    allow(Illume.Tools.MCP.ClientMock, self(), pid)

    # The first-requested tool (toolu_1) sleeps far longer than the
    # second (toolu_2) — if ordering were determined by completion time
    # rather than genuinely preserved by `ordered: true`, toolu_2 would
    # land first in the result and this test would catch it.
    stub(Illume.Tools.MCP.ClientMock, :call_tool, fn
      Illume.MCP.FilesystemClient, "read_text_file", _args ->
        Process.sleep(300)
        mcp_text_result("slow file contents")

      Illume.MCP.GitClient, "git_log", _args ->
        Process.sleep(80)
        mcp_text_result("fast log")
    end)

    {elapsed_us, result} = :timer.tc(fn -> Agent.ask(pid, "run two tools") end)

    assert {:ok, "done"} = result
    # Sequential would be ~380ms (300 + 80); concurrent should be ~300ms.
    assert elapsed_us / 1000 < 350
  end

  test "a tool slower than 5s is bounded by tool_timeout, not async_stream's own default timeout",
       %{tmp_dir: tmp_dir} do
    expect(ClientMock, :create, fn _params ->
      tool_use_response("read_file", %{"path" => "a.txt"})
    end)

    expect(ClientMock, :create, fn params ->
      assert [_question, _assistant, %{role: "user", content: [result]}] = params.messages
      refute result.is_error
      assert result.content =~ "slow but fine"
      text_response("done")
    end)

    pid = start_agent(target_dir: tmp_dir, tool_backend: :mcp, tool_timeout: 10_000)
    allow(Illume.Tools.MCP.ClientMock, self(), pid)

    # Task.Supervisor.async_stream_nolink defaults to a 5s timeout with
    # on_timeout: :exit, which would kill this very Agent process before
    # Runner.run/2's own tool_timeout (10s here) ever gets a say. Sleeping
    # past 5s but under tool_timeout proves the stream itself imposes no
    # timeout of its own.
    stub(Illume.Tools.MCP.ClientMock, :call_tool, fn Illume.MCP.FilesystemClient,
                                                     "read_text_file",
                                                     _args ->
      Process.sleep(5_500)
      mcp_text_result("slow but fine")
    end)

    assert {:ok, "done"} = Agent.ask(pid, "read a slow file")
    assert Process.alive?(pid)
  end
end
