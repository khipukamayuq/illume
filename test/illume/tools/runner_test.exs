defmodule Illume.Tools.RunnerTest do
  use ExUnit.Case, async: true

  alias Illume.Tools.Runner

  test "returns {:ok, result} when the function completes in time" do
    assert Runner.run(fn -> 1 + 1 end, 100) == {:ok, 2}
  end

  test "returns {:error, :timeout} when the function runs too long" do
    assert Runner.run(fn -> Process.sleep(200) end, 10) == {:error, :timeout}
  end

  test "returns {:error, {:crashed, reason}} when the function raises" do
    assert {:error, {:crashed, {%RuntimeError{message: "boom"}, _stacktrace}}} =
             Runner.run(fn -> raise "boom" end, 100)
  end

  test "does not crash the caller when the tool function raises" do
    pid = self()

    assert {:error, {:crashed, _}} = Runner.run(fn -> raise "boom" end, 100)
    assert Process.alive?(pid)
  end
end
