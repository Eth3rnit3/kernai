# frozen_string_literal: true

require_relative '../test_helper'

# Tests the "agent emitted zero blocks" branch of the Kernel loop.
#
# Small models frequently stall by narrating intent ("I will now call
# X...") without ever emitting a command block — they announce an
# action in prose and stop. When the agent has actionable rails
# (skills or protocols available) this is almost always a bug: the
# turn accomplishes nothing but the user sees a promise.
#
# The kernel must not silently accept this as a chatbot-style final
# for actionable agents. It must nudge the model and rerun the step so
# the agent commits to a command or a real final.
#
# The pure chatbot case (no skills, no protocols) keeps the permissive
# behaviour — prose is a legitimate final when the agent can't act.
class TestKernelNoBlocksStall < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    @provider = Kernai::Mock::Provider.new
    @recorder = Kernai::Recorder.new
    @events = []
  end

  def build_agent(skills: [], protocols: nil)
    Kernai::Agent.new(
      instructions: 'You are helpful.',
      provider: @provider,
      model: Kernai::Model.new(id: 'test-model'),
      max_steps: 6,
      skills: skills,
      protocols: protocols
    )
  end

  def run_kernel(agent, input = 'do the thing')
    Kernai::Kernel.run(agent, input, recorder: @recorder) { |e| @events << e }
  end

  # --- Actionable agent stall: prose gets rejected, loop continues ---

  def test_actionable_agent_prose_turn_does_not_terminate
    @provider.respond_with(
      'I will now create something for you.',
      '<block type="final">Created.</block>'
    )

    result = run_kernel(build_agent(skills: []))

    assert_equal 'Created.', result
    assert_equal 2, @provider.call_count
  end

  def test_actionable_agent_prose_turn_injects_corrective_error
    @provider.respond_with(
      'Sure, I will do that.',
      '<block type="final">ok</block>'
    )

    run_kernel(build_agent(skills: []))

    second_call_messages = @provider.calls[1][:messages]
    error_msg = second_call_messages.reverse.find do |m|
      m[:role] == :user && m[:content].join.include?('<block type="error">')
    end
    refute_nil error_msg, 'expected a corrective user error block'
    joined = error_msg[:content].join
    assert_includes joined, 'no block'
    # The corrective must spell out both options (wrap informational
    # prose OR emit a command) so the model doesn't get stuck
    # re-emitting naked prose.
    assert_includes joined, '<block type="final">'
    assert_includes joined, '<block type="command"'
    assert_includes joined, 'wrap it now'
  end

  def test_actionable_agent_emits_no_blocks_stall_event
    @provider.respond_with(
      'I will get on it.',
      '<block type="final">done</block>'
    )

    run_kernel(build_agent(skills: []))

    rec_entries = @recorder.to_a.select { |e| e[:event] == :no_blocks_stall }
    assert_equal 1, rec_entries.size

    stream = @events.select { |e| e.type == :no_blocks_stall }
    assert_equal 1, stream.size
    assert_includes stream.first.data[:prose_preview], 'I will get on it.'
  end

  # Repeated stalls get exhausted by max_steps, not silently accepted.
  def test_actionable_agent_repeated_stalls_exhaust_max_steps
    agent = build_agent(skills: [])
    @provider.respond_with('I will do it.')  # last response repeats

    assert_raises Kernai::MaxStepsReachedError do
      Kernai::Kernel.run(agent, 'go', recorder: @recorder)
    end
  end

  # --- Pure chatbot agent: prose is still legitimate ---

  def test_pure_chatbot_agent_accepts_prose_as_final
    # skills: nil AND no visible protocol → no rails to act → prose ok.
    agent = Kernai::Agent.new(
      instructions: 'You are a friendly chatbot.',
      provider: @provider,
      model: Kernai::Model.new(id: 'test-model'),
      max_steps: 3,
      skills: nil,
      protocols: nil
    )
    @provider.respond_with('Bonjour, ravi de vous parler !')

    result = Kernai::Kernel.run(agent, 'hi', recorder: @recorder)

    assert_equal 'Bonjour, ravi de vous parler !', result
    assert_equal 1, @provider.call_count
    rec_entries = @recorder.to_a.select { |e| e[:event] == :no_blocks_stall }
    assert_empty rec_entries, 'pure chatbot should not trigger the stall branch'
  end
end
