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

  alias OpenApiSpex.Schema
  alias Uro.AgentTasks

  action_fallback(Uro.FallbackController)

  tags(["agent tasks"])

  @task %Schema{
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      title: %Schema{type: :string},
      body: %Schema{type: :string}
    }
  }
  @task_id [id: [in: :path, schema: %Schema{type: :string, format: :uuid}]]
  @refused "This agent holds no claim on that task"

  operation(:index,
    operation_id: "agentTasks",
    summary: "The caller's open tasks, oldest first",
    responses: [
      ok:
        {"", "application/json",
         %Schema{type: :object, properties: %{tasks: %Schema{type: :array, items: @task}}}}
    ]
  )

  operation(:create,
    operation_id: "pushAgentTask",
    summary: "Push a task onto the caller's deque",
    request_body:
      {"", "application/json",
       %Schema{
         type: :object,
         required: [:title, :body],
         properties: %{
           title: %Schema{type: :string},
           body: %Schema{type: :string},
           pinned: %Schema{type: :boolean}
         }
       }},
    responses: [
      created: {"", "application/json", %Schema{type: :object, properties: %{task: @task}}}
    ]
  )

  operation(:claim,
    operation_id: "claimAgentTask",
    summary: "Claim the caller's newest task, else steal from the fullest queue",
    responses: [
      ok:
        {"", "application/json",
         %Schema{
           type: :object,
           properties: %{task: @task, stolen_from: %Schema{type: :string, nullable: true}}
         }},
      no_content: "No task is free anywhere"
    ]
  )

  operation(:renew,
    operation_id: "renewAgentTask",
    summary: "Extend the caller's lease on a task",
    parameters: @task_id,
    responses: [
      ok:
        {"", "application/json",
         %Schema{type: :object, properties: %{lease_seconds: %Schema{type: :integer}}}},
      conflict: @refused
    ]
  )

  operation(:complete,
    operation_id: "completeAgentTask",
    summary: "Finish a task the caller holds",
    parameters: @task_id,
    request_body:
      {"", "application/json",
       %Schema{type: :object, required: [:result], properties: %{result: %Schema{type: :string}}}},
    responses: [
      ok:
        {"", "application/json",
         %Schema{type: :object, properties: %{completed: %Schema{type: :string, format: :uuid}}}},
      conflict: @refused
    ]
  )

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
      {:error, :not_claimed} -> {:error, :conflict, @refused}
      other -> other
    end
  end

  def complete(conn, %{"id" => id, "result" => result}) when is_binary(result) do
    with {:ok, task_id} <- task_id(id),
         {:ok, agent} <- agent(conn),
         :ok <- AgentTasks.complete(agent, task_id, result) do
      json(conn, %{completed: task_id})
    else
      {:error, :not_claimed} -> {:error, :conflict, @refused}
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
