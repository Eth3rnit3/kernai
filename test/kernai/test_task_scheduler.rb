# frozen_string_literal: true

require_relative '../test_helper'

class TestTaskScheduler < Minitest::Test
  include Kernai::TestHelpers

  def build_context(plan_hash)
    plan = Kernai::Plan.parse(plan_hash)
    ctx = Kernai::Context.new
    ctx.hydrate_from_plan(plan)
    ctx
  end

  def test_runs_single_task
    ctx = build_context('tasks' => [{ 'id' => 't1', 'input' => 'hi' }])
    runner = ->(task, _ctx) { "result:#{task.id}" }

    results = Kernai::TaskScheduler.new(ctx, runner).run

    assert_equal({ 't1' => 'result:t1' }, results)
    assert ctx.tasks.first.done?
  end

  def test_runs_sequential_tasks_in_order
    order = []
    ctx = build_context(
      'tasks' => [
        { 'id' => 'a', 'input' => 'a' },
        { 'id' => 'b', 'input' => 'b' },
        { 'id' => 'c', 'input' => 'c' }
      ]
    )
    runner = lambda do |task, _ctx|
      order << task.id
      task.id
    end

    Kernai::TaskScheduler.new(ctx, runner).run
    assert_equal %w[a b c], order
  end

  def test_respects_dependencies
    order = []
    ctx = build_context(
      'tasks' => [
        { 'id' => 'c', 'input' => 'c', 'depends_on' => ['b'] },
        { 'id' => 'b', 'input' => 'b', 'depends_on' => ['a'] },
        { 'id' => 'a', 'input' => 'a' }
      ]
    )
    runner = lambda do |task, _ctx|
      order << task.id
      task.id
    end

    Kernai::TaskScheduler.new(ctx, runner).run
    assert_equal %w[a b c], order
  end

  def test_parallel_tasks_run_concurrently
    started_at = {}
    ctx = build_context(
      'tasks' => [
        { 'id' => 'p1', 'input' => 'p1', 'parallel' => true },
        { 'id' => 'p2', 'input' => 'p2', 'parallel' => true },
        { 'id' => 'p3', 'input' => 'p3', 'parallel' => true }
      ]
    )

    barrier = Queue.new
    count_mutex = Mutex.new
    concurrent = 0
    max_concurrent = 0

    runner = lambda do |task, _ctx|
      count_mutex.synchronize do
        concurrent += 1
        max_concurrent = concurrent if concurrent > max_concurrent
      end
      started_at[task.id] = Time.now
      sleep 0.02
      count_mutex.synchronize { concurrent -= 1 }
      task.id
    end

    Kernai::TaskScheduler.new(ctx, runner).run

    assert_equal 3, max_concurrent, 'all three parallel tasks should run at the same time'
    barrier # silence rubocop
  end

  def test_parallel_tasks_with_shared_dependency
    order = []
    order_mutex = Mutex.new
    ctx = build_context(
      'tasks' => [
        { 'id' => 'a', 'input' => 'a' },
        { 'id' => 'b', 'input' => 'b', 'parallel' => true, 'depends_on' => ['a'] },
        { 'id' => 'c', 'input' => 'c', 'parallel' => true, 'depends_on' => ['a'] }
      ]
    )

    runner = lambda do |task, _ctx|
      order_mutex.synchronize { order << "start:#{task.id}" }
      sleep 0.01
      order_mutex.synchronize { order << "end:#{task.id}" }
      task.id
    end

    Kernai::TaskScheduler.new(ctx, runner).run

    # a must finish before either b or c starts
    a_end = order.index('end:a')
    b_start = order.index('start:b')
    c_start = order.index('start:c')
    assert a_end < b_start
    assert a_end < c_start
  end

  def test_results_recorded_in_context
    ctx = build_context(
      'tasks' => [
        { 'id' => 'x', 'input' => 'x' },
        { 'id' => 'y', 'input' => 'y', 'parallel' => true },
        { 'id' => 'z', 'input' => 'z', 'parallel' => true }
      ]
    )
    runner = ->(task, _ctx) { "r_#{task.id}" }

    Kernai::TaskScheduler.new(ctx, runner).run

    assert_equal 'r_x', ctx.task_results['x']
    assert_equal 'r_y', ctx.task_results['y']
    assert_equal 'r_z', ctx.task_results['z']
  end

  def test_runner_exception_captured_as_error_result
    ctx = build_context('tasks' => [{ 'id' => 'boom', 'input' => 'boom' }])
    runner = ->(_task, _ctx) { raise 'explode' }

    results = Kernai::TaskScheduler.new(ctx, runner).run
    assert_includes results['boom'], 'error'
    assert_includes results['boom'], 'explode'
    assert ctx.tasks.first.done?
  end

  # --- Strategy ---

  def test_strategy_parallel_forces_all_tasks_parallel
    mutex = Mutex.new
    current = 0
    max_concurrent = 0

    ctx = build_context(
      'strategy' => 'parallel',
      'tasks' => [
        { 'id' => 'a', 'input' => 'a' },
        { 'id' => 'b', 'input' => 'b' },
        { 'id' => 'c', 'input' => 'c' }
      ]
    )
    runner = lambda do |task, _ctx|
      mutex.synchronize do
        current += 1
        max_concurrent = current if current > max_concurrent
      end
      sleep 0.02
      mutex.synchronize { current -= 1 }
      task.id
    end

    Kernai::TaskScheduler.new(ctx, runner).run
    assert_equal 3, max_concurrent,
                 "strategy 'parallel' should override per-task flags"
  end

  def test_strategy_sequential_forces_serial_even_when_tasks_flagged_parallel
    mutex = Mutex.new
    current = 0
    max_concurrent = 0

    ctx = build_context(
      'strategy' => 'sequential',
      'tasks' => [
        { 'id' => 'a', 'input' => 'a', 'parallel' => true },
        { 'id' => 'b', 'input' => 'b', 'parallel' => true }
      ]
    )
    runner = lambda do |task, _ctx|
      mutex.synchronize do
        current += 1
        max_concurrent = current if current > max_concurrent
      end
      sleep 0.02
      mutex.synchronize { current -= 1 }
      task.id
    end

    Kernai::TaskScheduler.new(ctx, runner).run
    assert_equal 1, max_concurrent,
                 "strategy 'sequential' should override per-task parallel flag"
  end

  def test_strategy_mixed_honors_per_task_flag
    mutex = Mutex.new
    current = 0
    max_concurrent = 0

    ctx = build_context(
      'strategy' => 'mixed',
      'tasks' => [
        { 'id' => 'p1', 'input' => 'p1', 'parallel' => true },
        { 'id' => 'p2', 'input' => 'p2', 'parallel' => true },
        { 'id' => 's', 'input' => 's' }
      ]
    )
    runner = lambda do |task, _ctx|
      mutex.synchronize do
        current += 1
        max_concurrent = current if current > max_concurrent
      end
      sleep 0.02
      mutex.synchronize { current -= 1 }
      task.id
    end

    Kernai::TaskScheduler.new(ctx, runner).run
    assert_equal 2, max_concurrent,
                 "strategy 'mixed' should respect per-task parallel flags"
  end

  # --- Deadlock detection ---

  def test_deadlock_detected_immediately
    # Directly construct tasks that depend on a non-existent id. Plan.parse
    # would prune these, but a caller building a Context by hand should
    # still be protected.
    ctx = Kernai::Context.new
    ctx.tasks = [
      Kernai::Task.new(id: 'a', input: 'a', depends_on: ['ghost'])
    ]

    err = assert_raises(Kernai::TaskScheduler::DeadlockError) do
      Kernai::TaskScheduler.new(ctx, ->(_t, _c) { 'never' }).run
    end
    assert_includes err.message, 'a'
  end
end
