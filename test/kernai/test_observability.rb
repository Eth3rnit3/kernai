# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Tests for the observability surface added on top of the kernel:
#   - llm_response events carry content + latency + token usage
#   - scope (depth, task_id) is stamped on every recorder entry
#   - plan_rejected events expose a structured reason
#   - task_start / task_complete / task_error fire with durations
#   - skill_result and workflow_complete carry duration_ms
class TestObservability < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    @provider = Kernai::Mock::Provider.new
    @recorder = Kernai::Recorder.new
    @agent = Kernai::Agent.new(
      instructions: 'manager',
      provider: @provider,
      model: Kernai::Model.new(id: 'test-model'),
      max_steps: 5,
      skills: :all
    )
  end

  # Helpers — keep the mock manager scripts readable.

  def plan_block(plan)
    "<block type=\"plan\">#{JSON.generate(plan)}</block>"
  end

  # Root agent: emit `plan_block` on step 0, then a generic final block.
  # Sub-agent calls fall through to `sub_response`.
  def wire_manager(plan, sub_response)
    manager_step = 0
    @provider.on_call do |messages, _model|
      if messages[0][:content].join.include?('/workflow')
        response = manager_step.zero? ? plan_block(plan) : '<block type="final">ok</block>'
        manager_step += 1
        response
      else
        sub_response.is_a?(Proc) ? sub_response.call(messages) : sub_response
      end
    end
  end

  # --- llm_response shape ---

  def test_llm_response_event_carries_stats
    @provider
      .respond_with('<block type="final">done</block>')
      .with_token_counter { |_m, _c| { prompt_tokens: 42, completion_tokens: 7 } }

    Kernai::Kernel.run(@agent, 'go', recorder: @recorder)

    entry = @recorder.for_event(:llm_response).first
    assert_equal '<block type="final">done</block>', entry[:data][:content]
    assert_equal 42, entry[:data][:prompt_tokens]
    assert_equal 7, entry[:data][:completion_tokens]
    assert_equal 49, entry[:data][:total_tokens]
    assert_operator entry[:data][:latency_ms], :>=, 0
  end

  # --- Scope stamping ---

  def test_every_entry_carries_depth_and_task_id_keys
    @provider.respond_with('<block type="final">done</block>')
    Kernai::Kernel.run(@agent, 'go', recorder: @recorder)

    assert(@recorder.entries.all? { |e| e.key?(:depth) && e.key?(:task_id) })
    assert(@recorder.entries.all? { |e| e[:depth].zero? && e[:task_id].nil? })
  end

  def test_subagent_entries_carry_depth_one_and_task_id
    plan = {
      goal: 'test', strategy: 'sequential',
      tasks: [{ id: 'greet', input: 'say hi' }]
    }

    wire_manager(plan, '<block type="final">hi there</block>')

    Kernai::Kernel.run(@agent, 'go', recorder: @recorder)

    sub_entries = @recorder.entries.select { |e| e[:depth] == 1 }
    refute_empty sub_entries, 'expected at least one entry recorded inside the sub-agent'
    assert(sub_entries.all? { |e| e[:task_id] == 'greet' })
  end

  # --- Plan rejection ---

  def test_plan_rejected_event_fires_with_reason_for_invalid_json
    @provider.respond_with(
      '<block type="plan">{not valid json</block><block type="final">done</block>'
    )

    Kernai::Kernel.run(@agent, 'go', recorder: @recorder)

    rejected = @recorder.for_event(:plan_rejected)
    assert_equal 1, rejected.size
    assert_equal 'invalid_json', rejected.first[:data][:reason]
  end

  def test_plan_rejected_event_fires_with_reason_for_cycle
    cyclic = {
      goal: 'cyc', strategy: 'mixed',
      tasks: [
        { id: 'a', input: 'do a', depends_on: ['b'] },
        { id: 'b', input: 'do b', depends_on: ['a'] }
      ]
    }
    @provider.respond_with(
      "<block type=\"plan\">#{JSON.generate(cyclic)}</block><block type=\"final\">done</block>"
    )

    Kernai::Kernel.run(@agent, 'go', recorder: @recorder)

    rejected = @recorder.for_event(:plan_rejected)
    assert_equal 1, rejected.size
    assert_equal 'cyclic', rejected.first[:data][:reason]
  end

  def test_nested_plan_rejected_with_reason_nested
    plan = {
      goal: 'outer', strategy: 'sequential',
      tasks: [{ id: 'child', input: 'run child' }]
    }

    nested_plan = {
      goal: 'inner', strategy: 'parallel',
      tasks: [{ id: 'x', input: 'dummy' }]
    }

    sub_response = "#{plan_block(nested_plan)}<block type=\"final\">child done</block>"
    wire_manager(plan, sub_response)

    Kernai::Kernel.run(@agent, 'go', recorder: @recorder)

    rejected = @recorder.for_event(:plan_rejected)
    nested = rejected.find { |e| e[:data][:reason] == 'nested' }
    refute_nil nested, 'sub-agent plan should be rejected with reason "nested"'
    assert_equal 1, nested[:depth]
  end

  # --- Task events + durations ---

  def test_task_start_and_complete_events_with_duration
    plan = {
      goal: 'test', strategy: 'sequential',
      tasks: [{ id: 'hello', input: 'say hi' }]
    }

    wire_manager(plan, '<block type="final">hi</block>')

    Kernai::Kernel.run(@agent, 'go', recorder: @recorder)

    starts = @recorder.for_event(:task_start)
    completes = @recorder.for_event(:task_complete)

    assert_equal 1, starts.size
    assert_equal 'hello', starts.first[:data][:task_id]

    assert_equal 1, completes.size
    assert_equal 'hello', completes.first[:data][:task_id]
    assert_equal 'hi', completes.first[:data][:result]
    assert completes.first[:data].key?(:duration_ms)
    assert_operator completes.first[:data][:duration_ms], :>=, 0
  end

  def test_task_error_event_records_failure
    # Force the sub-agent to keep calling an unknown skill so it never
    # emits a final block and ultimately hits max_steps. Kernel.run then
    # raises MaxStepsReachedError which the task runner catches and
    # records as :task_error.
    plan = {
      goal: 'test', strategy: 'sequential',
      tasks: [{ id: 'boom', input: 'loop forever' }]
    }

    wire_manager(plan, '<block type="command" name="ghost">noop</block>')

    Kernai::Kernel.run(@agent, 'go', recorder: @recorder)

    errors = @recorder.for_event(:task_error)
    assert_equal 1, errors.size
    assert_equal 'boom', errors.first[:data][:task_id]
    assert_includes errors.first[:data][:error], 'maximum steps'
    assert errors.first[:data].key?(:duration_ms)
  end

  # --- Skill duration ---

  def test_skill_result_carries_duration_ms
    Kernai::Skill.define(:ping) do
      input :q, String
      execute { |_| 'pong' }
    end

    @provider.respond_with(
      '<block type="command" name="ping">hello</block>',
      '<block type="final">done</block>'
    )

    Kernai::Kernel.run(@agent, 'go', recorder: @recorder)

    entry = @recorder.for_event(:skill_result).first
    assert_equal :ping, entry[:data][:skill]
    assert_equal 'pong', entry[:data][:result]
    assert entry[:data].key?(:duration_ms)
    assert_operator entry[:data][:duration_ms], :>=, 0
  end

  # --- Workflow duration ---

  def test_workflow_complete_carries_results_and_duration
    plan = {
      goal: 'test', strategy: 'sequential',
      tasks: [{ id: 'only', input: 'say hi' }]
    }

    wire_manager(plan, '<block type="final">hi</block>')

    Kernai::Kernel.run(@agent, 'go', recorder: @recorder)

    entry = @recorder.for_event(:workflow_complete).first
    refute_nil entry
    assert_equal({ 'only' => 'hi' }, entry[:data][:results])
    assert entry[:data].key?(:duration_ms)
    assert_operator entry[:data][:duration_ms], :>=, 0
  end
end
