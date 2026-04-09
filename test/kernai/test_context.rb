# frozen_string_literal: true

require_relative '../test_helper'

class TestContext < Minitest::Test
  include Kernai::TestHelpers

  def test_defaults
    ctx = Kernai::Context.new
    assert_nil ctx.plan
    assert_equal [], ctx.tasks
    assert_equal({}, ctx.task_results)
    assert_equal 0, ctx.depth
    assert ctx.root?
  end

  def test_hydrate_from_plan_copies_tasks
    plan = Kernai::Plan.parse(
      'tasks' => [
        { 'id' => 'a', 'input' => 'do a' },
        { 'id' => 'b', 'input' => 'do b', 'depends_on' => ['a'] }
      ]
    )
    ctx = Kernai::Context.new
    ctx.hydrate_from_plan(plan)

    assert_equal 2, ctx.tasks.size
    assert_equal plan, ctx.plan
    assert_equal({}, ctx.task_results)

    # Ensure the tasks are new instances, not the plan's originals
    plan.tasks.first.status = :done
    assert ctx.tasks.first.pending?
  end

  def test_record_result_is_thread_safe
    ctx = Kernai::Context.new
    threads = 20.times.map do |i|
      Thread.new { ctx.record_result("t#{i}", "r#{i}") }
    end
    threads.each(&:join)
    assert_equal 20, ctx.task_results.size
    20.times { |i| assert_equal "r#{i}", ctx.task_results["t#{i}"] }
  end

  def test_spawn_child_increments_depth_and_isolates
    parent = Kernai::Context.new
    parent.record_result('x', 'parent_result')

    child = parent.spawn_child
    assert_equal 1, child.depth
    refute child.root?
    assert_equal({}, child.task_results, 'child state is isolated from parent')

    child.record_result('y', 'child_result')
    assert_nil parent.task_results['y'], 'parent must not see child writes'
  end

  def test_nested_spawn
    ctx = Kernai::Context.new
    c1 = ctx.spawn_child
    c2 = c1.spawn_child
    assert_equal 2, c2.depth
    refute c2.root?
  end
end
