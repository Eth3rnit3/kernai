# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

class TestRecorder < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    @recorder = Kernai::Recorder.new
    @provider = Kernai::Mock::Provider.new
    @agent = Kernai::Agent.new(
      instructions: 'You are a helpful assistant.',
      provider: @provider,
      model: 'test-model',
      max_steps: 10
    )
  end

  # --- Recorder basics ---

  def test_recorder_starts_empty
    assert_empty @recorder.entries
    assert_empty @recorder.steps
  end

  def test_record_adds_entry
    @recorder.record(step: 0, event: :test, data: 'hello')
    assert_equal 1, @recorder.entries.size
    assert_equal 0, @recorder.entries[0][:step]
    assert_equal :test, @recorder.entries[0][:event]
    assert_equal 'hello', @recorder.entries[0][:data]
    assert @recorder.entries[0][:timestamp]
  end

  def test_clear_removes_all_entries
    @recorder.record(step: 0, event: :test, data: 'a')
    @recorder.record(step: 1, event: :test, data: 'b')
    @recorder.clear!
    assert_empty @recorder.entries
  end

  def test_to_a_returns_copy
    @recorder.record(step: 0, event: :test, data: 'a')
    copy = @recorder.to_a
    copy.clear
    assert_equal 1, @recorder.entries.size
  end

  def test_to_json_produces_valid_json
    @recorder.record(step: 0, event: :test, data: { key: 'value' })
    parsed = JSON.parse(@recorder.to_json)
    assert_equal 1, parsed.size
    assert_equal 'test', parsed[0]['event']
  end

  def test_steps_returns_unique_sorted
    @recorder.record(step: 1, event: :a, data: nil)
    @recorder.record(step: 0, event: :b, data: nil)
    @recorder.record(step: 1, event: :c, data: nil)
    assert_equal [0, 1], @recorder.steps
  end

  def test_for_step_filters
    @recorder.record(step: 0, event: :a, data: 'x')
    @recorder.record(step: 1, event: :b, data: 'y')
    @recorder.record(step: 0, event: :c, data: 'z')
    entries = @recorder.for_step(0)
    assert_equal 2, entries.size
    assert(entries.all? { |e| e[:step].zero? })
  end

  def test_for_event_filters
    @recorder.record(step: 0, event: :messages_sent, data: [])
    @recorder.record(step: 0, event: :raw_response, data: 'hi')
    @recorder.record(step: 1, event: :messages_sent, data: [])
    entries = @recorder.for_event(:messages_sent)
    assert_equal 2, entries.size
    assert(entries.all? { |e| e[:event] == :messages_sent })
  end

  def test_for_event_accepts_string
    @recorder.record(step: 0, event: :test, data: nil)
    assert_equal 1, @recorder.for_event('test').size
  end

  # --- Integration with Kernel.run (per-call recorder) ---

  def test_records_simple_final_block
    @provider.respond_with('<block type="final">Hello!</block>')
    Kernai::Kernel.run(@agent, 'Hi', recorder: @recorder)

    assert_equal [0], @recorder.steps

    # Should have: messages_sent, raw_response, blocks_parsed, result
    events = @recorder.entries.map { |e| e[:event] }
    assert_includes events, :messages_sent
    assert_includes events, :raw_response
    assert_includes events, :blocks_parsed
    assert_includes events, :result
  end

  def test_records_messages_sent_with_full_context
    @provider.respond_with('<block type="final">OK</block>')
    Kernai::Kernel.run(@agent, 'Hello there', recorder: @recorder)

    messages_entry = @recorder.for_event(:messages_sent).first
    messages = messages_entry[:data]

    assert_equal :system, messages[0][:role]
    assert_equal :user, messages[1][:role]
    assert_equal 'Hello there', messages[1][:content]
  end

  def test_records_raw_response
    @provider.respond_with('<block type="final">The answer</block>')
    Kernai::Kernel.run(@agent, 'Hi', recorder: @recorder)

    raw = @recorder.for_event(:raw_response).first
    assert_includes raw[:data], 'The answer'
  end

  def test_records_blocks_parsed
    @provider.respond_with('<block type="plan">Think first</block><block type="final">Done</block>')
    Kernai::Kernel.run(@agent, 'Go', recorder: @recorder)

    blocks_entry = @recorder.for_event(:blocks_parsed).first
    blocks = blocks_entry[:data]
    assert_equal 2, blocks.size
    assert_equal :plan, blocks[0][:type]
    assert_equal :final, blocks[1][:type]
  end

  def test_records_plain_text_result
    @provider.respond_with('Just plain text')
    Kernai::Kernel.run(@agent, 'Hi', recorder: @recorder)

    result_entry = @recorder.for_event(:result).first
    assert_equal 'Just plain text', result_entry[:data]
  end

  # --- Skill execution recording ---

  def test_records_skill_execute_and_result
    Kernai::Skill.define(:search) do
      input :query, String
      execute { |params| "Found: #{params[:query]}" }
    end

    @provider.respond_with(
      '<block type="command" name="search">test query</block>',
      '<block type="final">Done</block>'
    )

    Kernai::Kernel.run(@agent, 'Search', recorder: @recorder)

    exec_entries = @recorder.for_event(:skill_execute)
    assert_equal 1, exec_entries.size
    assert_equal :search, exec_entries[0][:data][:skill]
    assert_equal({ query: 'test query' }, exec_entries[0][:data][:params])

    result_entries = @recorder.for_event(:skill_result)
    assert_equal 1, result_entries.size
    assert_equal 'Found: test query', result_entries[0][:data][:result]
  end

  def test_records_skill_error
    Kernai::Skill.define(:failing) do
      input :query, String
      execute { |_| raise 'boom' }
    end

    @provider.respond_with(
      '<block type="command" name="failing">go</block>',
      '<block type="final">Recovered</block>'
    )

    Kernai::Kernel.run(@agent, 'Go', recorder: @recorder)

    error_entries = @recorder.for_event(:skill_error)
    assert_equal 1, error_entries.size
    assert_equal :failing, error_entries[0][:data][:skill]
    assert_includes error_entries[0][:data][:error], 'boom'
  end

  def test_records_skill_not_found
    @provider.respond_with(
      '<block type="command" name="unknown">go</block>',
      '<block type="final">OK</block>'
    )

    Kernai::Kernel.run(@agent, 'Go', recorder: @recorder)

    error_entries = @recorder.for_event(:skill_error)
    assert_equal 1, error_entries.size
    assert_equal :unknown, error_entries[0][:data][:skill]
    assert_equal 'not found', error_entries[0][:data][:error]
  end

  # --- Multi-step recording ---

  def test_records_multi_step_conversation
    Kernai::Skill.define(:step_a) do
      input :query, String
      execute { |_| 'result_a' }
    end

    @provider.respond_with(
      '<block type="command" name="step_a">go</block>',
      '<block type="final">All done</block>'
    )

    Kernai::Kernel.run(@agent, 'Do it', recorder: @recorder)

    assert_equal [0, 1], @recorder.steps

    # Step 0: messages_sent, raw_response, blocks_parsed, skill_execute, skill_result
    step0 = @recorder.for_step(0)
    step0_events = step0.map { |e| e[:event] }
    assert_includes step0_events, :messages_sent
    assert_includes step0_events, :raw_response
    assert_includes step0_events, :blocks_parsed
    assert_includes step0_events, :skill_execute
    assert_includes step0_events, :skill_result

    # Step 1: messages_sent (now includes skill result), raw_response, blocks_parsed, result
    step1 = @recorder.for_step(1)
    step1_events = step1.map { |e| e[:event] }
    assert_includes step1_events, :messages_sent
    assert_includes step1_events, :result

    # Step 1 messages should include the skill result from step 0
    step1_messages = step1.find { |e| e[:event] == :messages_sent }[:data]
    result_msg = step1_messages.find { |m| m[:content].to_s.include?('result_a') }
    assert result_msg, 'Step 1 messages should contain skill result from step 0'
  end

  # --- Config-based recorder ---

  def test_config_recorder_used_when_no_per_call_recorder
    config_recorder = Kernai::Recorder.new
    Kernai.config.recorder = config_recorder

    @provider.respond_with('<block type="final">OK</block>')
    Kernai::Kernel.run(@agent, 'Hi')

    refute_empty config_recorder.entries
  end

  def test_per_call_recorder_takes_precedence_over_config
    config_recorder = Kernai::Recorder.new
    Kernai.config.recorder = config_recorder

    @provider.respond_with('<block type="final">OK</block>')
    Kernai::Kernel.run(@agent, 'Hi', recorder: @recorder)

    refute_empty @recorder.entries
    assert_empty config_recorder.entries
  end

  # --- History recording ---

  def test_records_history_in_messages
    history = [
      { role: :user, content: 'Previous question' },
      { role: :assistant, content: 'Previous answer' }
    ]

    @provider.respond_with('<block type="final">OK</block>')
    Kernai::Kernel.run(@agent, 'New question', history: history, recorder: @recorder)

    messages_entry = @recorder.for_event(:messages_sent).first
    messages = messages_entry[:data]

    assert_equal 4, messages.size
    assert_equal :system, messages[0][:role]
    assert_equal 'Previous question', messages[1][:content]
    assert_equal 'Previous answer', messages[2][:content]
    assert_equal 'New question', messages[3][:content]
  end

  # --- JSON export for scenario creation ---

  def test_full_recording_is_json_serializable
    Kernai::Skill.define(:ping) do
      input :query, String
      execute { |_| 'pong' }
    end

    @provider.respond_with(
      '<block type="command" name="ping">hi</block>',
      '<block type="final">Done</block>'
    )

    Kernai::Kernel.run(@agent, 'Ping', recorder: @recorder)

    json = @recorder.to_json
    parsed = JSON.parse(json)
    assert parsed.is_a?(Array)
    assert parsed.size.positive?
    assert(parsed.all? { |e| e.key?('step') && e.key?('event') && e.key?('data') && e.key?('timestamp') })
  end
end
