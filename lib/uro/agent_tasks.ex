# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.AgentTasks do
  @moduledoc """
  The agent sessions' shared work-stealing queue.

  Each agent owns a deque of open tasks. It claims its own newest first; with none left, it
  steals the oldest unclaimed, unpinned task from the agent holding the most, and the task
  moves to the thief's deque. A claim is a lease that `renew/3` extends and
  `Uro.AgentTasks.Janitor` frees once it lapses. Every change is one transaction on
  `Uro.Repo`'s one connection, so two claims never interleave.
  """

  import Ecto.Query

  alias Uro.AgentTasks.Agent
  alias Uro.AgentTasks.Claim
  alias Uro.AgentTasks.Pin
  alias Uro.AgentTasks.QueueEntry
  alias Uro.AgentTasks.Result
  alias Uro.AgentTasks.Task
  alias Uro.Repo

  @lease_seconds 2 * 60 * 60

  def lease_seconds, do: @lease_seconds

  @doc "The agent named `name`, created on first use."
  def register(name) when is_binary(name) and name != "" do
    case Repo.get_by(Agent, name: name) do
      %Agent{} = agent -> {:ok, agent}
      nil -> Repo.insert(%Agent{name: name})
    end
  end

  @doc "Adds a task to the bottom of `agent`'s deque; `pinned: true` keeps it from being stolen."
  def push(%Agent{id: agent_id}, title, body, opts \\ []) do
    Repo.transaction(fn ->
      task = Repo.insert!(%Task{title: title, body: body})

      Repo.insert!(%QueueEntry{
        task_id: task.id,
        agent_id: agent_id,
        position: next_position(agent_id)
      })

      if Keyword.get(opts, :pinned, false), do: Repo.insert!(%Pin{task_id: task.id})
      task
    end)
  end

  @doc """
  Claims `agent`'s newest unclaimed task, or else steals one. `{:ok, {:own, task}}`,
  `{:ok, {{:stolen, from_name}, task}}`, or `:empty` when no task is free anywhere.
  """
  def claim(%Agent{id: agent_id} = agent, now \\ DateTime.utc_now()) do
    Repo.transaction(fn ->
      case own_entry(agent_id) do
        %QueueEntry{} = entry ->
          {:own, take!(entry, agent, now)}

        nil ->
          case steal_entry(agent_id) do
            nil ->
              Repo.rollback(:empty)

            {entry, from} ->
              entry
              |> Ecto.Changeset.change(agent_id: agent_id, position: next_position(agent_id))
              |> Repo.update!()

              {{:stolen, from}, take!(entry, agent, now)}
          end
      end
    end)
    |> case do
      {:error, :empty} -> :empty
      other -> other
    end
  end

  @doc "Extends `agent`'s lease on `task_id` by another lease period."
  def renew(%Agent{id: agent_id}, task_id, now \\ DateTime.utc_now()) do
    case from(c in Claim, where: c.task_id == ^task_id and c.agent_id == ^agent_id)
         |> Repo.update_all(set: [lease_until: lease_until(now)]) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_claimed}
    end
  end

  @doc "Records `result` for a task `agent` holds and takes it off the queue."
  def complete(%Agent{id: agent_id}, task_id, result, now \\ DateTime.utc_now()) do
    Repo.transaction(fn ->
      case Repo.get_by(Claim, task_id: task_id, agent_id: agent_id) do
        nil ->
          Repo.rollback(:not_claimed)

        claim ->
          Repo.insert!(%Result{
            task_id: task_id,
            agent_id: agent_id,
            result: result,
            done_at: now
          })

          Repo.delete!(claim)
          from(q in QueueEntry, where: q.task_id == ^task_id) |> Repo.delete_all()
          from(p in Pin, where: p.task_id == ^task_id) |> Repo.delete_all()
          :ok
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  @doc "Frees every claim whose lease ended before `now`; the tasks stay where they are."
  def release_expired(now \\ DateTime.utc_now()) do
    {count, _} = from(c in Claim, where: c.lease_until < ^now) |> Repo.delete_all()
    {:ok, count}
  end

  @doc "`agent`'s open tasks, oldest first, each with whether it is claimed."
  def queue(%Agent{id: agent_id}) do
    from(q in QueueEntry,
      join: t in Task,
      on: t.id == q.task_id,
      left_join: c in Claim,
      on: c.task_id == q.task_id,
      where: q.agent_id == ^agent_id,
      order_by: q.position,
      select: %{task: t, claimed: not is_nil(c.task_id)}
    )
    |> Repo.all()
  end

  defp own_entry(agent_id) do
    from(q in unclaimed(), where: q.agent_id == ^agent_id, order_by: [desc: q.position], limit: 1)
    |> Repo.one()
  end

  defp steal_entry(agent_id) do
    stealable =
      from(q in unclaimed(),
        left_join: p in Pin,
        on: p.task_id == q.task_id,
        where: is_nil(p.task_id)
      )

    victim =
      from(q in stealable,
        where: q.agent_id != ^agent_id,
        group_by: q.agent_id,
        order_by: [desc: count(q.task_id), asc: min(q.position)],
        limit: 1,
        select: q.agent_id
      )
      |> Repo.one()

    with victim when not is_nil(victim) <- victim do
      entry =
        from(q in stealable, where: q.agent_id == ^victim, order_by: q.position, limit: 1)
        |> Repo.one!()

      {entry, Repo.get!(Agent, victim).name}
    end
  end

  defp unclaimed do
    from(q in QueueEntry,
      left_join: c in Claim,
      on: c.task_id == q.task_id,
      where: is_nil(c.task_id)
    )
  end

  defp take!(%QueueEntry{task_id: task_id}, %Agent{id: agent_id}, now) do
    Repo.insert!(%Claim{task_id: task_id, agent_id: agent_id, lease_until: lease_until(now)})
    Repo.get!(Task, task_id)
  end

  defp next_position(agent_id) do
    (from(q in QueueEntry, where: q.agent_id == ^agent_id, select: max(q.position)) |> Repo.one() ||
       0) + 1
  end

  defp lease_until(now), do: DateTime.add(now, @lease_seconds, :second)
end
