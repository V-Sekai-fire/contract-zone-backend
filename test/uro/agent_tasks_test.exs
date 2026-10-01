defmodule Uro.AgentTasksTest do
  use Uro.RepoCase, async: false

  alias Uro.AgentTasks
  alias Uro.AgentTasks.Claim

  defp agent(name) do
    {:ok, a} = AgentTasks.register(name)
    a
  end

  defp push!(agent, title, opts \\ []) do
    {:ok, task} = AgentTasks.push(agent, title, "body of " <> title, opts)
    task
  end

  test "an agent claims its own newest task first" do
    mac = agent("mac")
    push!(mac, "older")
    push!(mac, "newer")
    assert {:ok, {:own, %{title: "newer"}}} = AgentTasks.claim(mac)
    assert {:ok, {:own, %{title: "older"}}} = AgentTasks.claim(mac)
    assert AgentTasks.claim(mac) == :empty
  end

  test "an idle agent steals the oldest task of the fullest queue, which moves to it" do
    idle = agent("idle")
    busy = agent("busy")
    light = agent("light")
    push!(busy, "b1")
    push!(busy, "b2")
    push!(busy, "b3")
    push!(light, "l1")

    assert {:ok, {{:stolen, "busy"}, %{title: "b1"}}} = AgentTasks.claim(idle)
    assert [%{task: %{title: "b1"}, claimed: true}] = AgentTasks.queue(idle)
    assert Enum.map(AgentTasks.queue(busy), & &1.task.title) == ["b2", "b3"]
  end

  test "a pinned task is never stolen" do
    idle = agent("idle")
    frame = agent("frame-owner")
    push!(frame, "needs the headset", pinned: true)
    assert AgentTasks.claim(idle) == :empty
  end

  test "control: the same task unpinned is stolen" do
    idle = agent("idle")
    frame = agent("frame-owner")
    push!(frame, "needs nothing special")
    assert {:ok, {{:stolen, "frame-owner"}, _}} = AgentTasks.claim(idle)
  end

  test "a claimed task is not claimed again, by its owner or a thief" do
    owner = agent("owner")
    thief = agent("thief")
    push!(owner, "only")
    assert {:ok, {:own, _}} = AgentTasks.claim(owner)
    assert AgentTasks.claim(owner) == :empty
    assert AgentTasks.claim(thief) == :empty
  end

  test "two agents racing for one free task: exactly one gets it" do
    owner = agent("owner")
    a = agent("racer-a")
    b = agent("racer-b")
    push!(owner, "contested")
    parent = self()

    results =
      [a, b]
      |> Enum.map(fn racer ->
        Elixir.Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Uro.Repo, parent, self())
          AgentTasks.claim(racer)
        end)
      end)
      |> Enum.map(&Elixir.Task.await(&1, 30_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == :empty)) == 1
    assert Repo.aggregate(Claim, :count) == 1
  end

  test "control: the database itself refuses a second claim on one task" do
    owner = agent("owner")
    task = push!(owner, "contested")
    assert {:ok, {:own, _}} = AgentTasks.claim(owner)
    lease = DateTime.utc_now() |> DateTime.add(60, :second)

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%Claim{task_id: task.id, agent_id: owner.id, lease_until: lease})
    end
  end

  test "a lapsed lease frees the task for a thief" do
    owner = agent("owner")
    thief = agent("thief")
    push!(owner, "abandoned")
    past = DateTime.utc_now() |> DateTime.add(-3 * AgentTasks.lease_seconds(), :second)
    assert {:ok, {:own, _}} = AgentTasks.claim(owner, past)
    assert {:ok, 1} = AgentTasks.release_expired()
    assert {:ok, {{:stolen, "owner"}, %{title: "abandoned"}}} = AgentTasks.claim(thief)
  end

  test "control: a live lease is not released" do
    owner = agent("owner")
    push!(owner, "in hand")
    assert {:ok, {:own, _}} = AgentTasks.claim(owner)
    assert {:ok, 0} = AgentTasks.release_expired()
  end

  test "completing records the result and takes the task off the queue; only its claimer may" do
    owner = agent("owner")
    other = agent("other")
    task = push!(owner, "work")
    assert {:ok, {:own, _}} = AgentTasks.claim(owner)
    assert {:error, :not_claimed} = AgentTasks.complete(other, task.id, "not mine")
    assert :ok = AgentTasks.complete(owner, task.id, "done: PR #1")
    assert AgentTasks.queue(owner) == []
    assert %{result: "done: PR #1"} = Repo.get!(Uro.AgentTasks.Result, task.id)
  end
end
