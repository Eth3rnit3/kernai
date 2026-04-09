# frozen_string_literal: true

require_relative '../test_helper'

# Tests the "agent emitted only informational blocks" branch of the Kernel
# loop. Smaller models often split reasoning and action across turns: they
# emit a <plan> at turn N and the corresponding action at turn N+1. The
# kernel must NOT terminate the loop when a turn produces only <plan> or
# <json> blocks — it must nudge the agent and let it continue.
class TestKernelInformationalOnly < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    @provider = Kernai::Mock::Provider.new
    @agent = Kernai::Agent.new(
      instructions: 'You are helpful.',
      provider: @provider,
      model: 'test-model',
      max_steps: 6
    )
    @recorder = Kernai::Recorder.new
    @events = []
  end

  def run_kernel(input = 'hi')
    Kernai::Kernel.run(@agent, input, recorder: @recorder) { |e| @events << e }
  end

  # --- The core regression: plan-only turn must not terminate ---

  def test_plan_only_turn_continues_loop_and_reaches_final
    @provider.respond_with(
      '<block type="plan">I will first think, then emit a final block.</block>',
      '<block type="final">the answer</block>'
    )

    result = run_kernel
    assert_equal 'the answer', result
    assert_equal 2, @provider.call_count
  end

  def test_plan_only_turn_triggers_corrective_user_message
    @provider.respond_with(
      '<block type="plan">thinking...</block>',
      '<block type="final">done</block>'
    )

    run_kernel

    # The second LLM call should see the corrective error block injected
    # as a user message between the plan and the final.
    second_call_messages = @provider.calls[1][:messages]
    error_msg = second_call_messages.reverse.find do |m|
      m[:role] == :user && m[:content].include?('<block type="error">')
    end
    assert error_msg, 'expected an injected corrective user error block'
    assert_includes error_msg[:content], 'informational blocks'
    assert_includes error_msg[:content], 'actionable'
  end

  def test_plan_only_turn_emits_informational_only_event
    @provider.respond_with(
      '<block type="plan">thinking...</block>',
      '<block type="final">done</block>'
    )

    run_kernel

    rec_entries = @recorder.to_a.select { |e| e[:event] == :informational_only }
    assert_equal 1, rec_entries.size
    assert_equal ['plan'], rec_entries.first[:data][:kinds]
    assert_equal 0, rec_entries.first[:depth]
    assert_nil rec_entries.first[:task_id]

    stream = @events.select { |e| e.type == :informational_only }
    assert_equal 1, stream.size
    assert_equal [:plan], stream.first.data[:kinds]
  end

  def test_json_only_turn_also_continues
    @provider.respond_with(
      '<block type="json">{"draft": true}</block>',
      '<block type="final">done</block>'
    )

    result = run_kernel
    assert_equal 'done', result

    kinds = @recorder.to_a.select { |e| e[:event] == :informational_only }.map { |e| e[:data][:kinds] }
    assert_equal [['json']], kinds
  end

  def test_plan_and_json_together_without_action_continues
    @provider.respond_with(
      '<block type="plan">thinking</block><block type="json">{"x":1}</block>',
      '<block type="final">done</block>'
    )

    run_kernel

    entry = @recorder.to_a.find { |e| e[:event] == :informational_only }
    assert entry
    assert_equal %w[plan json].sort, entry[:data][:kinds].sort
  end

  # --- Bounded by max_steps ---

  def test_infinite_plan_only_loop_is_bounded_by_max_steps
    @agent = Kernai::Agent.new(
      instructions: 'You are helpful.',
      provider: @provider,
      model: 'test-model',
      max_steps: 3
    )
    @provider.respond_with('<block type="plan">still thinking...</block>')

    assert_raises(Kernai::MaxStepsReachedError) { run_kernel }
    assert_equal 3, @provider.call_count

    # Three corrective messages should have been recorded, one per step.
    info_events = @recorder.to_a.select { |e| e[:event] == :informational_only }
    assert_equal 3, info_events.size
  end

  # --- Backward-compatible cases (must keep working) ---

  def test_plan_with_final_in_same_response_still_terminates
    @provider.respond_with(
      '<block type="plan">I will answer.</block><block type="final">the answer</block>'
    )

    result = run_kernel
    assert_equal 'the answer', result
    assert_equal 1, @provider.call_count
    # No informational_only event: the turn was actionable (final present).
    assert_empty(@recorder.to_a.select { |e| e[:event] == :informational_only })
  end

  def test_plan_with_command_in_same_response_continues_normally
    Kernai::Skill.define(:ping) do
      execute { |_p| 'pong' }
    end

    @provider.respond_with(
      '<block type="plan">I will ping.</block><block type="command" name="ping"></block>',
      '<block type="final">done</block>'
    )

    result = run_kernel
    assert_equal 'done', result
    assert_empty(@recorder.to_a.select { |e| e[:event] == :informational_only })
  end

  def test_plan_with_protocol_block_in_same_response_continues_normally
    Kernai::Protocol.register(:fake) { |_b, _c| 'ok' }

    @provider.respond_with(
      '<block type="plan">I will call the protocol.</block><block type="fake">x</block>',
      '<block type="final">done</block>'
    )

    result = run_kernel
    assert_equal 'done', result
    assert_empty(@recorder.to_a.select { |e| e[:event] == :informational_only })
  end

  def test_plain_text_with_no_blocks_still_terminates_as_raw_response
    # Chatbot-style response with no blocks at all — the historical
    # behavior must be preserved. This is distinct from "informational
    # only": there are zero blocks, not one that happens to be plan/json.
    @provider.respond_with('Just a plain conversational answer with no blocks.')

    result = run_kernel
    assert_equal 'Just a plain conversational answer with no blocks.', result
    assert_equal 1, @provider.call_count
    assert_empty(@recorder.to_a.select { |e| e[:event] == :informational_only })
  end

  # --- Sub-agent scope ---

  def test_informational_only_event_in_subagent_carries_scope
    Kernai::Protocol.register(:fake) { |_b, _c| 'ok' }

    plan_json = JSON.generate(
      goal: 'test',
      strategy: 'sequential',
      tasks: [{ id: 't1', input: 'go', parallel: false, depends_on: [] }]
    )

    call_count = 0
    @provider.on_call do |_messages, _model|
      call_count += 1
      case call_count
      when 1 then "<block type=\"plan\">#{plan_json}</block>" # root: workflow plan
      when 2 then '<block type="plan">sub thinking</block>'   # sub-agent: plan only
      when 3 then '<block type="final">sub-done</block>'       # sub-agent: final
      else '<block type="final">root-done</block>'             # root: wrap-up
      end
    end

    run_kernel

    sub_info = @recorder.to_a.select do |e|
      e[:event] == :informational_only && e[:depth] == 1
    end
    assert_equal 1, sub_info.size
    assert_equal 't1', sub_info.first[:task_id]
  end
end
