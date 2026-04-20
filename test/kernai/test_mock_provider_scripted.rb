# frozen_string_literal: true

require_relative '../test_helper'

# Scripted / scenario-oriented extensions on top of Mock::Provider:
# indexed response scripts, deterministic error injection, and
# per-call introspection (messages_at, generation_at).
class TestMockProviderScripted < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    @provider = Kernai::Mock::Provider.new
  end

  # --- respond_with_script ---

  def test_respond_with_script_returns_by_step
    @provider.respond_with_script(
      0 => 'first',
      1 => 'second',
      2 => 'third'
    )

    r1 = @provider.call(messages: [], model: 'm')
    r2 = @provider.call(messages: [], model: 'm')
    r3 = @provider.call(messages: [], model: 'm')

    assert_equal 'first', r1.content
    assert_equal 'second', r2.content
    assert_equal 'third', r3.content
  end

  def test_respond_with_script_last_repeats_like_respond_with
    @provider.respond_with_script(0 => 'a', 1 => 'b')

    @provider.call(messages: [], model: 'm')
    @provider.call(messages: [], model: 'm')
    r3 = @provider.call(messages: [], model: 'm')

    assert_equal 'b', r3.content
  end

  def test_respond_with_script_rejects_non_contiguous_keys
    err = assert_raises(ArgumentError) do
      @provider.respond_with_script(0 => 'a', 2 => 'c')
    end
    assert_match(/contiguous/, err.message)
  end

  def test_respond_with_script_rejects_keys_not_starting_at_zero
    err = assert_raises(ArgumentError) do
      @provider.respond_with_script(1 => 'a', 2 => 'b')
    end
    assert_match(/starting at 0/, err.message)
  end

  def test_respond_with_script_returns_self_for_chaining
    assert_same @provider, @provider.respond_with_script(0 => 'a')
  end

  # --- fail_on_step ---

  def test_fail_on_step_raises_on_scheduled_step
    @provider
      .respond_with('ok')
      .fail_on_step(1, message: 'boom')

    # Step 0: success
    result = @provider.call(messages: [], model: 'm')
    assert_equal 'ok', result.content

    # Step 1: raises
    err = assert_raises(Kernai::ProviderError) do
      @provider.call(messages: [], model: 'm')
    end
    assert_equal 'boom', err.message
  end

  def test_fail_on_step_custom_error_class
    @provider.fail_on_step(0, error_class: RuntimeError, message: 'custom boom')

    assert_raises(RuntimeError) { @provider.call(messages: [], model: 'm') }
  end

  def test_fail_on_step_advances_call_count_so_responses_remain_aligned
    @provider
      .respond_with_script(0 => 'first', 1 => 'second')
      .fail_on_step(1)

    # Step 0: first response
    r0 = @provider.call(messages: [], model: 'm')
    assert_equal 'first', r0.content

    # Step 1: raises
    assert_raises(Kernai::ProviderError) { @provider.call(messages: [], model: 'm') }

    # Step 2: the next response is the LAST one ('second'), since responses
    # got consumed through the failure — simulating that a "step was used"
    # even though it errored.
    r2 = @provider.call(messages: [], model: 'm')
    assert_equal 'second', r2.content
  end

  def test_fail_on_step_returns_self_for_chaining
    assert_same @provider, @provider.fail_on_step(0)
  end

  # --- Introspection helpers ---

  def test_messages_at_and_generation_at
    @provider.respond_with('ok')

    agent = Kernai::Agent.new(
      instructions: 'test',
      provider: @provider,
      model: Kernai::Model.new(id: 'test'),
      generation: { temperature: 0.3 }
    )
    @provider.respond_with_script(0 => '<block type="final">done</block>')

    Kernai::Kernel.run(agent, 'hello')

    sent = @provider.messages_at(0)
    refute_nil sent
    assert_equal :system, sent[0][:role]
    assert_equal :user, sent[1][:role]

    gen = @provider.generation_at(0)
    assert_in_delta 0.3, gen.temperature
  end

  def test_messages_at_out_of_bounds_returns_nil
    assert_nil @provider.messages_at(42)
    assert_nil @provider.generation_at(42)
  end

  # --- reset! clears scripted state ---

  def test_reset_clears_script_and_failures
    @provider.respond_with_script(0 => 'a', 1 => 'b').fail_on_step(0)
    @provider.reset!

    # Neither the failure nor the script should fire — provider returns empty.
    result = @provider.call(messages: [], model: 'm')
    assert_equal '', result.content
  end

  # --- Kernel-level scenario: full round-trip using scripted responses ---

  def test_scripted_multi_step_run
    Kernai::Skill.reset!
    Kernai::Skill.define(:ping) do
      input :value, String
      execute { |_| 'pong' }
    end

    @provider.respond_with_script(
      0 => '<block type="command" name="ping">x</block>',
      1 => '<block type="final">all good</block>'
    )

    agent = Kernai::Agent.new(
      instructions: 'test',
      provider: @provider,
      model: Kernai::Model.new(id: 'test'),
      max_steps: 5
    )

    result = Kernai::Kernel.run(agent, 'do it')
    assert_equal 'all good', result
    assert_equal 2, @provider.call_count
  end
end
