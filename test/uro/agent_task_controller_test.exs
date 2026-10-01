defmodule Uro.AgentTaskControllerTest do
  use Uro.RepoCase, async: false

  import Plug.Test

  alias Uro.Accounts.User
  alias Uro.AgentTaskController

  defp user(name) do
    Repo.insert!(%User{username: name, display_name: name, email: name <> "@agents.test"})
  end

  defp conn_as(user), do: :post |> conn("/") |> Plug.Conn.assign(:current_user, user)

  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "a signed-in agent pushes, claims its own task, and completes it" do
    mac = user("mac")
    pushed = AgentTaskController.create(conn_as(mac), %{"title" => "port", "body" => "do it"})
    assert pushed.status == 201
    id = body(pushed)["task"]["id"]

    claimed = AgentTaskController.claim(conn_as(mac), %{})
    assert claimed.status == 200
    assert %{"task" => %{"id" => ^id}, "stolen_from" => nil} = body(claimed)

    done = AgentTaskController.complete(conn_as(mac), %{"id" => id, "result" => "PR #1"})
    assert done.status == 200
    assert body(AgentTaskController.index(conn_as(mac), %{}))["tasks"] == []
  end

  test "an idle agent steals, and the response names whom it stole from" do
    busy = user("busy")
    idle = user("idle")
    AgentTaskController.create(conn_as(busy), %{"title" => "first", "body" => "b"})
    AgentTaskController.create(conn_as(busy), %{"title" => "second", "body" => "b"})

    claimed = AgentTaskController.claim(conn_as(idle), %{})
    assert %{"task" => %{"title" => "first"}, "stolen_from" => "busy"} = body(claimed)
    assert AgentTaskController.claim(conn_as(user("third")), %{}) |> Map.get(:status) == 200
    assert AgentTaskController.claim(conn_as(user("fourth")), %{}).status == 204
  end

  test "only the claimer completes a task" do
    owner = user("owner")
    other = user("other")

    id =
      body(AgentTaskController.create(conn_as(owner), %{"title" => "t", "body" => "b"}))["task"][
        "id"
      ]

    AgentTaskController.claim(conn_as(owner), %{})

    assert {:error, :conflict, _} =
             AgentTaskController.complete(conn_as(other), %{"id" => id, "result" => "mine?"})
  end

  test "an anonymous caller gets nothing" do
    anonymous = :post |> conn("/") |> Plug.Conn.assign(:current_user, nil)
    assert {:error, :invalid_credentials} = AgentTaskController.claim(anonymous, %{})
  end

  test "a malformed task id is refused before it reaches the queue" do
    assert {:error, :bad_request, _} =
             AgentTaskController.renew(conn_as(user("mac")), %{"id" => "not-a-uuid"})
  end
end
