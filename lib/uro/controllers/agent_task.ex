# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.AgentTaskController do
  @moduledoc """
  The agents' work-stealing queue (`Uro.AgentTasks`) over HTTP. The signed-in user is the
  agent: its username names the deque it pushes to, claims from and completes in, so no
  agent can claim or finish work under another's name.

      GET  /api/v1/agent_tasks                 the caller's open tasks, oldest first
      POST /api/v1/agent_tasks                 {title, body, pinned?} onto the caller's deque
      POST /api/v1/agent_tasks/claim           own newest, else steal; 204 when nothing is free
      POST /api/v1/agent_tasks/:id/renew       extend the caller's lease
      POST /api/v1/agent_tasks/:id/complete    {result}; only the claimer may
  """

  use Uro, :controller

  alias Uro.AgentTasks

  action_fallback(Uro.FallbackController)

  def index(conn, _params) do
    with {:ok, agent} <- agent(conn) do
      json(conn, %{tasks: Enum.map(AgentTasks.queue(agent), &entry_json/1)})
    end
  end

  def create(conn, %{"title" => title, "body" => body} = params)
      when is_binary(title) and is_binary(body) do
    with {:ok, agent} <- agent(conn),
         {:ok, task} <- AgentTasks.push(agent, title, body, pinned: params["pinned"] == true) do
      conn |> put_status(:created) |> json(%{task: task_json(task)})
    end
  end

  def create(_conn, _params), do: {:error, :bad_request, "Expected {title, body}"}

  def claim(conn, _params) do
    with {:ok, agent} <- agent(conn) do
      case AgentTasks.claim(agent) do
        {:ok, {:own, task}} -> json(conn, %{task: task_json(task), stolen_from: nil})
        {:ok, {{:stolen, from}, task}} -> json(conn, %{task: task_json(task), stolen_from: from})
        :empty -> send_resp(conn, :no_content, "")
      end
    end
  end

  def renew(conn, %{"id" => id}) do
    with {:ok, task_id} <- task_id(id),
         {:ok, agent} <- agent(conn),
         :ok <- AgentTasks.renew(agent, task_id) do
      json(conn, %{lease_seconds: AgentTasks.lease_seconds()})
    else
      {:error, :not_claimed} -> {:error, :conflict, "This agent holds no claim on that task"}
      other -> other
    end
  end

  def complete(conn, %{"id" => id, "result" => result}) when is_binary(result) do
    with {:ok, task_id} <- task_id(id),
         {:ok, agent} <- agent(conn),
         :ok <- AgentTasks.complete(agent, task_id, result) do
      json(conn, %{completed: task_id})
    else
      {:error, :not_claimed} -> {:error, :conflict, "This agent holds no claim on that task"}
      other -> other
    end
  end

  def complete(_conn, _params), do: {:error, :bad_request, "Expected {result}"}

  defp agent(conn) do
    with {:ok, user} <- current_user(conn), do: AgentTasks.register(user.username)
  end

  defp task_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :bad_request, "Not a task id"}
    end
  end

  defp task_json(task), do: %{id: task.id, title: task.title, body: task.body}

  defp entry_json(%{task: task, claimed: claimed}),
    do: Map.put(task_json(task), :claimed, claimed)
end
