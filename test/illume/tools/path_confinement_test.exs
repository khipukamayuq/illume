defmodule Illume.Tools.PathConfinementTest do
  use ExUnit.Case, async: true

  alias Illume.Tools.PathConfinement

  @moduletag :tmp_dir

  test "confine accepts a plain path inside the target dir", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "hello.txt"), "hi")
    assert {:ok, full} = PathConfinement.confine(tmp_dir, "hello.txt")
    assert full == Path.join(Path.expand(tmp_dir), "hello.txt")
  end

  test "confine rejects `..` traversal outside the target dir", %{tmp_dir: tmp_dir} do
    assert {:error, message} = PathConfinement.confine(tmp_dir, "../../../../etc/passwd")
    assert message =~ "escapes target directory"
  end

  test "confine rejects a symlink inside the target dir pointing outside it", %{tmp_dir: tmp_dir} do
    outside_dir =
      Path.join(System.tmp_dir!(), "illume_pc_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside_dir)
    File.write!(Path.join(outside_dir, "secret.txt"), "top secret")
    on_exit(fn -> File.rm_rf!(outside_dir) end)

    link = Path.join(tmp_dir, "escape")
    File.ln_s!(outside_dir, link)

    assert {:error, message} = PathConfinement.confine(tmp_dir, "escape/secret.txt")
    assert message =~ "escapes target directory"
  end

  test "within?/2 accepts a symlink that points to somewhere inside the target dir", %{
    tmp_dir: tmp_dir
  } do
    File.mkdir_p!(Path.join(tmp_dir, "real"))
    link = Path.join(tmp_dir, "alias")
    File.ln_s!(Path.join(tmp_dir, "real"), link)

    assert PathConfinement.within?(link, tmp_dir)
  end

  test "real_path/1 returns nil (fails closed) on a symlink cycle", %{tmp_dir: tmp_dir} do
    a = Path.join(tmp_dir, "a")
    b = Path.join(tmp_dir, "b")
    File.ln_s!(b, a)
    File.ln_s!(a, b)

    assert PathConfinement.real_path(a) == nil
    refute PathConfinement.within?(a, tmp_dir)
  end
end
