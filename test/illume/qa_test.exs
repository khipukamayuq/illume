defmodule Illume.QATest do
  use ExUnit.Case, async: false

  import Mox

  alias Illume.LLM.ClientMock
  alias Illume.QA

  @moduletag :tmp_dir

  setup :set_mox_global
  setup :verify_on_exit!

  test "delegates to an Illume.Agent and returns its :ok result unchanged", %{tmp_dir: tmp_dir} do
    expect(ClientMock, :create, fn _params ->
      {:ok,
       %{"content" => [%{"type" => "text", "text" => "the answer"}], "stop_reason" => "end_turn"}}
    end)

    assert {:ok, "the answer"} = QA.ask(tmp_dir, "a question", :direct, client: ClientMock)
  end

  test "returns an :error result unchanged when the model call fails", %{tmp_dir: tmp_dir} do
    expect(ClientMock, :create, fn _params -> {:error, :boom} end)

    # `:boom` isn't `:timeout` or `{:crashed, _}` or an exception, so
    # `Illume.Agent`'s `format_error/1` falls through to its catch-all
    # `inspect/1` clause — asserting that exact string (not a wildcard)
    # pins down which branch actually ran.
    assert {:error, ":boom"} = QA.ask(tmp_dir, "a question", :direct, client: ClientMock)
  end
end
