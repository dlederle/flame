defmodule Dragonfly.PooTest do
  use ExUnit.Case, async: false

  alias Dragonfly.Pool

  defp sim_long_running(pool, time \\ 1_000) do
    ref = make_ref()
    parent = self()

    task =
      Task.async(fn ->
        Dragonfly.call(pool, fn ->
          send(parent, {ref, :called})
          Process.sleep(time)
        end)
      end)

    receive do
      {^ref, :called} -> task
    end
  end

  test "init boots min runners synchronously", config do
    dyn_sup = Module.concat(config.test, "DynamicSup")

    _pid =
      start_supervised!({Pool.Supervisor, name: config.test, min: 1, max: 2, max_concurrency: 2})

    min_pool = Supervisor.which_children(dyn_sup)
    assert [{:undefined, _pid, :worker, [Dragonfly.Runner]}] = min_pool
    # execute against single runner
    assert Dragonfly.call(config.test, fn -> :works end) == :works

    # dynamically grows to max
    _task1 = sim_long_running(config.test)
    assert Dragonfly.call(config.test, fn -> :works end) == :works
    # max concurrency still below threshold
    assert Supervisor.which_children(dyn_sup) == min_pool
    # max concurrency above threshold boots new runner
    _task2 = sim_long_running(config.test)
    assert Dragonfly.call(config.test, fn -> :works end) == :works
    new_pool = Supervisor.which_children(dyn_sup)
    refute new_pool == min_pool
    assert length(new_pool) == 2
    # caller is now queued while waiting for available runner
    _task3 = sim_long_running(config.test)
    _task4 = sim_long_running(config.test)
    # task is queued and times out
    queued = spawn(fn -> Dragonfly.call(config.test, fn -> :queued end, timeout: 100) end)
    ref = Process.monitor(queued)
    assert_receive {:DOWN, ^ref, :process, _, {:timeout, _}}, 1000
    assert Dragonfly.call(config.test, fn -> :queued end) == :queued
    assert new_pool == Supervisor.which_children(dyn_sup)
  end
end