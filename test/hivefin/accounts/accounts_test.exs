defmodule Hivefin.AccountsTest do
  use Hivefin.DataCase

  alias Hivefin.Accounts

  test "authenticate succeeds with correct password" do
    {:ok, user} =
      Accounts.create_user(%{
        name: "Admin",
        username: "admin",
        password: "secret123",
        admin: true
      })

    assert {:ok, auth} = Accounts.authenticate("admin", "secret123")
    assert auth.id == user.id
    assert {:error, :invalid_credentials} = Accounts.authenticate("admin", "nope")
  end

  test "bootstrap_admin! creates user once from env" do
    System.put_env("HIVEFIN_ADMIN_USER", "boot")
    System.put_env("HIVEFIN_ADMIN_PASSWORD", "boot-secret-1")
    assert {:ok, user} = Accounts.bootstrap_admin()
    assert user.username == "boot"
    assert user.admin
    assert {:ok, ^user} = Accounts.bootstrap_admin()
    # second call is no-op when users already exist — same user count
    assert Accounts.count_users() == 1
  end
end
