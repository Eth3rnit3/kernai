# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Focused tests for protocol dispatch in the Kernel. Kept separate from
# test_kernel.rb to keep the diff surface readable and because protocols are
# their own first-class extension point (symmetric to skills, not a subtype).
class TestKernelProtocol < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    @provider = Kernai::Mock::Provider.new
    @agent = Kernai::Agent.new(
      instructions: 'You are helpful.',
      provider: @provider,
      model: Kernai::Model.new(id: 'test-model'),
      max_steps: 10
    )
    @recorder = Kernai::Recorder.new
    @events = []
  end

  def run_kernel(input = 'hi')
    Kernai::Kernel.run(@agent, input, recorder: @recorder) { |e| @events << e }
  end

  # --- Happy path dispatch ---

  def test_registered_protocol_block_is_dispatched
    Kernai::Protocol.register(:fake) { |block, _ctx| "echo: #{block.content}" }

    @provider.respond_with(
      '<block type="fake">ping</block>',
      '<block type="final">done</block>'
    )

    result = run_kernel
    assert_equal 'done', result

    # Second LLM call should see the result block injected as user message
    second_call = @provider.calls[1]
    injected = second_call[:messages].last
    assert_equal :user, injected[:role]
    assert_includes injected[:content].join, '<block type="result" name="fake">'
    assert_includes injected[:content].join, 'echo: ping'
  end

  def test_unregistered_block_type_is_ignored
    # A block type that's neither a core type nor a registered protocol is
    # treated as an informational (non-actionable) block: the loop should
    # terminate with the raw response or a final block, not loop forever.
    @provider.respond_with(
      '<block type="unknown">nothing</block><block type="final">done</block>'
    )

    result = run_kernel
    assert_equal 'done', result
  end

  # --- Observability ---

  def test_protocol_execute_and_result_are_recorded_with_scope_and_duration
    Kernai::Protocol.register(:fake) { |_b, _c| 'ok' }

    @provider.respond_with(
      '<block type="fake">hello</block>',
      '<block type="final">done</block>'
    )

    run_kernel

    entries = @recorder.to_a
    execute = entries.find { |e| e[:event] == :protocol_execute }
    result = entries.find { |e| e[:event] == :protocol_result }

    assert execute, 'expected :protocol_execute event'
    assert_equal :fake, execute[:data][:protocol]
    assert_equal 'hello', execute[:data][:request]
    assert_equal 0, execute[:depth]
    assert_nil execute[:task_id]

    assert result, 'expected :protocol_result event'
    assert_equal :fake, result[:data][:protocol]
    assert_equal 'ok', result[:data][:result]
    assert result[:data][:duration_ms].is_a?(Integer)
    assert_equal 0, result[:depth]
  end

  def test_protocol_events_are_streamed_to_callback
    Kernai::Protocol.register(:fake) { |_b, _c| 'ok' }

    @provider.respond_with(
      '<block type="fake">hi</block>',
      '<block type="final">done</block>'
    )

    run_kernel

    types = @events.map(&:type)
    assert_includes types, :protocol_execute
    assert_includes types, :protocol_result
    assert_equal :fake, @events.find { |e| e.type == :protocol_execute }.data[:protocol]
    assert_equal 'ok', @events.find { |e| e.type == :protocol_result }.data[:result]
  end

  # --- Error handling ---

  def test_handler_raise_is_wrapped_as_error_block
    Kernai::Protocol.register(:fake) { |_b, _c| raise StandardError, 'boom' }

    @provider.respond_with(
      '<block type="fake">bad</block>',
      '<block type="final">recovered</block>'
    )

    result = run_kernel
    assert_equal 'recovered', result

    # The injected message should be an error block, not a result block
    second_call = @provider.calls[1]
    injected = second_call[:messages].last
    assert_includes injected[:content].join, '<block type="error" name="fake">'
    assert_includes injected[:content].join, 'boom'
  end

  def test_handler_raise_records_protocol_error_with_duration
    Kernai::Protocol.register(:fake) { |_b, _c| raise StandardError, 'boom' }

    @provider.respond_with(
      '<block type="fake">bad</block>',
      '<block type="final">recovered</block>'
    )

    run_kernel

    error = @recorder.to_a.find { |e| e[:event] == :protocol_error }
    assert error
    assert_equal :fake, error[:data][:protocol]
    assert_equal 'boom', error[:data][:error]
    assert error[:data][:duration_ms].is_a?(Integer)
  end

  def test_error_event_is_streamed_to_callback
    Kernai::Protocol.register(:fake) { |_b, _c| raise 'kaboom' }

    @provider.respond_with(
      '<block type="fake">bad</block>',
      '<block type="final">ok</block>'
    )

    run_kernel

    evt = @events.find { |e| e.type == :protocol_error }
    assert evt
    assert_equal 'kaboom', evt.data[:error]
  end

  # --- Return type flexibility ---

  def test_handler_can_return_message_directly
    Kernai::Protocol.register(:fake) do |_b, _c|
      Kernai::Message.new(
        role: :user,
        content: '<block type="result" name="fake">custom wrapping</block>'
      )
    end

    @provider.respond_with(
      '<block type="fake">hi</block>',
      '<block type="final">done</block>'
    )

    run_kernel

    injected = @provider.calls[1][:messages].last
    assert_equal :user, injected[:role]
    assert_includes injected[:content].join, 'custom wrapping'
  end

  # --- Agent whitelist ---

  def test_whitelist_nil_allows_all_protocols
    Kernai::Protocol.register(:fake) { |_b, _c| 'ok' }
    @agent.protocols = nil

    @provider.respond_with(
      '<block type="fake">x</block>',
      '<block type="final">done</block>'
    )

    run_kernel

    assert(@recorder.to_a.any? { |e| e[:event] == :protocol_result })
  end

  def test_whitelist_explicit_list_allows_matching
    Kernai::Protocol.register(:fake) { |_b, _c| 'ok' }
    @agent.protocols = [:fake]

    @provider.respond_with(
      '<block type="fake">x</block>',
      '<block type="final">done</block>'
    )

    run_kernel

    assert(@recorder.to_a.any? { |e| e[:event] == :protocol_result })
  end

  def test_whitelist_rejects_non_listed_protocol
    Kernai::Protocol.register(:fake) { |_b, _c| 'ok' }
    @agent.protocols = [:other]

    @provider.respond_with(
      '<block type="fake">x</block>',
      '<block type="final">done</block>'
    )

    run_kernel

    err = @recorder.to_a.find { |e| e[:event] == :protocol_error }
    assert err
    assert_equal 'not allowed', err[:data][:error]

    injected = @provider.calls[1][:messages].last
    assert_includes injected[:content].join, '<block type="error" name="fake">'
    assert_includes injected[:content].join, 'not allowed'
  end

  def test_whitelist_empty_blocks_everything
    Kernai::Protocol.register(:fake) { |_b, _c| 'ok' }
    @agent.protocols = []

    @provider.respond_with(
      '<block type="fake">x</block>',
      '<block type="final">done</block>'
    )

    run_kernel

    assert(@recorder.to_a.any? { |e| e[:event] == :protocol_error })
  end

  # --- Interleaving command + protocol in the same LLM response ---

  def test_command_and_protocol_execute_in_apparition_order
    Kernai::Skill.define(:echo) do
      input :val, String
      execute { |p| "skill:#{p[:val]}" }
    end

    Kernai::Protocol.register(:fake) { |b, _c| "proto:#{b.content}" }

    @provider.respond_with(
      '<block type="command" name="echo">first</block>' \
      '<block type="fake">second</block>',
      '<block type="final">done</block>'
    )

    run_kernel

    injected_contents = @provider.calls[1][:messages].select { |m| m[:role] == :user }.map { |m| m[:content].join }
    # First user message is the initial prompt; following are the command
    # result then the protocol result in insertion order.
    # We assert the order by finding their indexes.
    idx_skill = injected_contents.index { |c| c.include?('skill:first') }
    idx_proto = injected_contents.index { |c| c.include?('proto:second') }
    assert idx_skill
    assert idx_proto
    assert idx_skill < idx_proto, 'command result must precede protocol result'
  end

  def test_protocol_before_command_order_preserved
    Kernai::Skill.define(:echo) do
      input :val, String
      execute { |p| "skill:#{p[:val]}" }
    end

    Kernai::Protocol.register(:fake) { |b, _c| "proto:#{b.content}" }

    @provider.respond_with(
      '<block type="fake">first</block>' \
      '<block type="command" name="echo">second</block>',
      '<block type="final">done</block>'
    )

    run_kernel

    contents = @provider.calls[1][:messages].map { |m| m[:content].join }
    idx_proto = contents.index { |c| c.include?('proto:first') }
    idx_skill = contents.index { |c| c.include?('skill:second') }
    assert idx_proto
    assert idx_skill
    assert idx_proto < idx_skill, 'protocol result must precede command result'
  end

  # --- Sub-agent scope inheritance ---

  def test_subagent_protocol_call_inherits_depth_and_task_id
    Kernai::Protocol.register(:fake) { |_b, _c| 'sub-ok' }

    # Root emits a workflow plan with a single task. Sub-agent uses the protocol.
    plan_json = JSON.generate(
      goal: 'test',
      strategy: 'sequential',
      tasks: [{ id: 't1', input: 'call fake', parallel: false, depends_on: [] }]
    )

    call_count = 0
    @provider.on_call do |_messages, _model|
      call_count += 1
      case call_count
      when 1 then "<block type=\"plan\">#{plan_json}</block>"
      when 2 then '<block type="fake">sub</block>' # sub-agent step 1
      when 3 then '<block type="final">sub-done</block>' # sub-agent step 2
      else        '<block type="final">root-done</block>' # root wrap-up
      end
    end

    run_kernel

    sub_events = @recorder.to_a.select { |e| e[:event] == :protocol_execute }
    assert_equal 1, sub_events.size
    sub_event = sub_events.first
    assert_equal 1, sub_event[:depth], 'sub-agent protocol event must be stamped with depth=1'
    assert_equal 't1', sub_event[:task_id], 'sub-agent protocol event must be stamped with task_id'
  end

  def test_subagent_inherits_protocols_whitelist
    Kernai::Protocol.register(:fake) { |_b, _c| 'ok' }
    @agent.protocols = [:fake]

    plan_json = JSON.generate(
      goal: 'test',
      strategy: 'sequential',
      tasks: [{ id: 't1', input: 'go', parallel: false, depends_on: [] }]
    )

    call_count = 0
    @provider.on_call do |_messages, _model|
      call_count += 1
      case call_count
      when 1 then "<block type=\"plan\">#{plan_json}</block>"
      when 2 then '<block type="fake">x</block>'
      when 3 then '<block type="final">sub-done</block>'
      else '<block type="final">root-done</block>'
      end
    end

    run_kernel

    # Must be allowed (not blocked) — inheritance worked
    results = @recorder.to_a.select { |e| e[:event] == :protocol_result }
    errors = @recorder.to_a.select { |e| e[:event] == :protocol_error }
    assert_equal 1, results.size
    assert_empty errors
  end

  # --- /protocols built-in ---

  def test_protocols_builtin_lists_registered_protocols
    Kernai::Protocol.register(:fake, documentation: 'Fake protocol doc') { |_b, _c| 'ok' }
    Kernai::Protocol.register(:other, documentation: 'Other doc') { |_b, _c| 'ok' }

    @provider.respond_with(
      '<block type="command" name="/protocols"></block>',
      '<block type="final">done</block>'
    )

    run_kernel

    result_evt = @recorder.to_a.find { |e| e[:event] == :builtin_result && e[:data][:command] == '/protocols' }
    assert result_evt
    payload = JSON.parse(result_evt[:data][:result])
    assert_equal 2, payload.size
    names = payload.map { |h| h['name'] }.sort
    assert_equal %w[fake other], names
    assert(payload.any? { |h| h['documentation'] == 'Fake protocol doc' })
  end

  def test_protocols_builtin_respects_agent_whitelist
    Kernai::Protocol.register(:fake, documentation: 'doc1') { |_b, _c| 'ok' }
    Kernai::Protocol.register(:other, documentation: 'doc2') { |_b, _c| 'ok' }
    @agent.protocols = [:fake]

    @provider.respond_with(
      '<block type="command" name="/protocols"></block>',
      '<block type="final">done</block>'
    )

    run_kernel

    result_evt = @recorder.to_a.find { |e| e[:event] == :builtin_result && e[:data][:command] == '/protocols' }
    payload = JSON.parse(result_evt[:data][:result])
    assert_equal 1, payload.size
    assert_equal 'fake', payload.first['name']
  end

  def test_protocols_builtin_empty_list
    @provider.respond_with(
      '<block type="command" name="/protocols"></block>',
      '<block type="final">done</block>'
    )

    run_kernel

    result_evt = @recorder.to_a.find { |e| e[:event] == :builtin_result && e[:data][:command] == '/protocols' }
    assert result_evt
    assert_equal '[]', result_evt[:data][:result]
  end

  # --- Logger integration ---

  def test_logger_emits_protocol_lines
    Kernai::Protocol.register(:fake) { |_b, _c| 'ok' }
    io = StringIO.new
    Kernai.config.logger = Kernai::Logger.new(io)

    @provider.respond_with(
      '<block type="fake">x</block>',
      '<block type="final">done</block>'
    )

    run_kernel

    output = io.string
    assert_includes output, 'event=protocol.execute'
    assert_includes output, 'event=protocol.result'
  end
end
