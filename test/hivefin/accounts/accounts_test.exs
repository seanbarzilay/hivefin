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

  test "issue_token and get_user_by_token round-trip" do
    {:ok, user} =
      Accounts.create_user(%{
        name: "Tok",
        username: "tok",
        password: "password1",
        admin: false
      })

    assert {:ok, token, at} =
             Accounts.issue_token(user, %{
               device_id: "d1",
               device_name: "Phone",
               client: "App",
               client_version: "1.2.3"
             })

    assert is_binary(token)
    assert at.user_id == user.id
    assert at.device_id == "d1"

    found = Accounts.get_user_by_token(token)
    assert found.id == user.id
    assert Accounts.get_user_by_token("nope") == nil
  end

  test "issue_token requires device_id" do
    {:ok, user} =
      Accounts.create_user(%{
        name: "Dev",
        username: "devreq",
        password: "password1",
        admin: false
      })

    assert {:error, changeset} =
             Accounts.issue_token(user, %{
               device_name: "Phone",
               client: "App",
               client_version: "1.0"
             })

    assert %{device_id: _} = errors_on(changeset)
  end

  test "issue_token ignores user_id and token from attrs" do
    {:ok, user} =
      Accounts.create_user(%{
        name: "Safe",
        username: "safe",
        password: "password1",
        admin: false
      })

    assert {:ok, token, at} =
             Accounts.issue_token(user, %{
               device_id: "d1",
               device_name: "Phone",
               client: "App",
               client_version: "1.0",
               user_id: Ecto.UUID.generate(),
               token: "attacker-chosen-token"
             })

    assert at.user_id == user.id
    assert token != "attacker-chosen-token"
    assert at.token == token
    assert Accounts.get_user_by_token("attacker-chosen-token") == nil
    assert Accounts.get_user_by_token(token).id == user.id
  end

  test "revoke_token removes token lookup" do
    {:ok, user} =
      Accounts.create_user(%{
        name: "Rev",
        username: "rev",
        password: "password1",
        admin: false
      })

    assert {:ok, token, _} =
             Accounts.issue_token(user, %{
               device_id: "d1",
               device_name: "Phone",
               client: "App",
               client_version: "1.0"
             })

    assert Accounts.get_user_by_token(token).id == user.id
    assert {:ok, _} = Accounts.revoke_token(token)
    assert Accounts.get_user_by_token(token) == nil
    assert {:error, :not_found} = Accounts.revoke_token(token)
  end
end
