# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Repo.Migrations.CreateAgentTasks do
  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      timestamps(updated_at: false)
    end

    create(unique_index(:agents, [:name]))

    create table(:agent_tasks, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:title, :string, null: false)
      add(:body, :text, null: false)
      timestamps(updated_at: false)
    end

    # The deque an open task sits in, and where.
    create table(:agent_task_queue_entries, primary_key: false) do
      add(:task_id, references(:agent_tasks, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false)
      add(:position, :integer, null: false)
    end

    create(index(:agent_task_queue_entries, [:agent_id, :position]))

    create table(:agent_task_claims, primary_key: false) do
      add(:task_id, references(:agent_tasks, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false)
      add(:lease_until, :utc_datetime_usec, null: false)
    end

    create table(:agent_task_pins, primary_key: false) do
      add(:task_id, references(:agent_tasks, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )
    end

    create table(:agent_task_results, primary_key: false) do
      add(:task_id, references(:agent_tasks, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false)
      add(:result, :text, null: false)
      add(:done_at, :utc_datetime_usec, null: false)
    end
  end
end
