defmodule Illume.LLM.PromptsTest do
  use ExUnit.Case, async: true

  alias Illume.LLM.Prompts

  test "mentions the target directory and every allowed tool name" do
    prompt = Prompts.system("/some/target/dir")

    assert prompt =~ "/some/target/dir"

    for tool <- ~w(grep_content search_files read_file git_log git_show) do
      assert prompt =~ tool
    end
  end

  test "states the read-only invariant" do
    prompt = Prompts.system("/some/target/dir")
    assert prompt =~ "read-only"
  end
end
