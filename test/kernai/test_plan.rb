# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

class TestPlan < Minitest::Test
  include Kernai::TestHelpers

  # --- Valid plans ---

  def test_parse_accepts_minimal_valid_plan
    raw = {
      'goal' => 'Do the thing',
      'strategy' => 'sequential',
      'tasks' => [
        { 'id' => 't1', 'input' => 'first' }
      ]
    }
    plan = Kernai::Plan.parse(raw)
    refute_nil plan
    assert_equal 'Do the thing', plan.goal
    assert_equal 'sequential', plan.strategy
    assert_equal 1, plan.tasks.size
    assert_equal 't1', plan.tasks.first.id
    assert_equal 'first', plan.tasks.first.input
    refute plan.tasks.first.parallel?
    assert plan.tasks.first.pending?
  end

  def test_parse_accepts_json_string
    json = JSON.generate(
      goal: 'goal',
      strategy: 'parallel',
      tasks: [
        { id: 'a', input: 'do a', parallel: true },
        { id: 'b', input: 'do b', parallel: true }
      ]
    )
    plan = Kernai::Plan.parse(json)
    refute_nil plan
    assert_equal 2, plan.tasks.size
    assert(plan.tasks.all?(&:parallel?))
  end

  def test_parse_respects_dependencies
    plan = Kernai::Plan.parse(
      'tasks' => [
        { 'id' => 'a', 'input' => 'a' },
        { 'id' => 'b', 'input' => 'b', 'depends_on' => ['a'] }
      ]
    )
    assert_equal [], plan.tasks[0].depends_on
    assert_equal ['a'], plan.tasks[1].depends_on
  end

  def test_parse_defaults_strategy_to_mixed
    plan = Kernai::Plan.parse('tasks' => [{ 'id' => 't', 'input' => 'x' }])
    assert_equal 'mixed', plan.strategy
  end

  def test_parse_defaults_invalid_strategy_to_mixed
    plan = Kernai::Plan.parse(
      'strategy' => 'chaos',
      'tasks' => [{ 'id' => 't', 'input' => 'x' }]
    )
    assert_equal 'mixed', plan.strategy
  end

  def test_parse_preserves_declared_strategies
    %w[parallel sequential mixed].each do |s|
      plan = Kernai::Plan.parse(
        'strategy' => s,
        'tasks' => [{ 'id' => 't', 'input' => 'x' }]
      )
      assert_equal s, plan.strategy
    end
  end

  # --- Fail-safe ---

  def test_parse_returns_nil_for_invalid_json
    assert_nil Kernai::Plan.parse('{not json')
  end

  def test_parse_returns_nil_for_empty_string
    assert_nil Kernai::Plan.parse('')
  end

  def test_parse_returns_nil_when_tasks_missing
    assert_nil Kernai::Plan.parse('goal' => 'x')
  end

  def test_parse_returns_nil_when_tasks_empty
    assert_nil Kernai::Plan.parse('tasks' => [])
  end

  def test_parse_ignores_tasks_without_id_or_input
    plan = Kernai::Plan.parse(
      'tasks' => [
        { 'id' => '', 'input' => 'x' },
        { 'id' => 'valid', 'input' => 'ok' },
        { 'id' => 'no_input' }
      ]
    )
    refute_nil plan
    assert_equal 1, plan.tasks.size
    assert_equal 'valid', plan.tasks.first.id
  end

  def test_parse_drops_invalid_dependencies
    plan = Kernai::Plan.parse(
      'tasks' => [
        { 'id' => 'a', 'input' => 'a', 'depends_on' => %w[ghost b] },
        { 'id' => 'b', 'input' => 'b' }
      ]
    )
    assert_equal ['b'], plan.tasks[0].depends_on
  end

  def test_parse_drops_self_dependencies
    plan = Kernai::Plan.parse(
      'tasks' => [{ 'id' => 'a', 'input' => 'a', 'depends_on' => ['a'] }]
    )
    assert_equal [], plan.tasks[0].depends_on
  end

  def test_parse_rejects_cyclic_dependencies
    assert_nil Kernai::Plan.parse(
      'tasks' => [
        { 'id' => 'a', 'input' => 'a', 'depends_on' => ['b'] },
        { 'id' => 'b', 'input' => 'b', 'depends_on' => ['a'] }
      ]
    )
  end

  def test_parse_returns_nil_for_non_hash_non_string
    assert_nil Kernai::Plan.parse(42)
    assert_nil Kernai::Plan.parse(nil)
    assert_nil Kernai::Plan.parse([])
  end
end
