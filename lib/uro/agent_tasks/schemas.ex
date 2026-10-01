# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.AgentTasks.Agent do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "agents" do
    field :name, :string
    timestamps(updated_at: false)
  end
end

defmodule Uro.AgentTasks.Task do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "agent_tasks" do
    field :title, :string
    field :body, :string
    timestamps(updated_at: false)
  end
end

defmodule Uro.AgentTasks.QueueEntry do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:task_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "agent_task_queue_entries" do
    field :agent_id, :binary_id
    field :position, :integer
  end
end

defmodule Uro.AgentTasks.Claim do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:task_id, :binary_id, autogenerate: false}
  schema "agent_task_claims" do
    field :agent_id, :binary_id
    field :lease_until, :utc_datetime_usec
  end
end

defmodule Uro.AgentTasks.Pin do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:task_id, :binary_id, autogenerate: false}
  schema "agent_task_pins" do
  end
end

defmodule Uro.AgentTasks.Result do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:task_id, :binary_id, autogenerate: false}
  schema "agent_task_results" do
    field :agent_id, :binary_id
    field :result, :string
    field :done_at, :utc_datetime_usec
  end
end
