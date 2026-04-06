# frozen_string_literal: true

require_relative '../test_helper'

class TestMockProvider < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    @provider = Kernai::Mock::Provider.new
  end

  def test_respond_with_single_response
    @provider.respond_with('Hello!')
    result = @provider.call(messages: [{ role: 'user', content: 'hi' }], model: 'test')
    assert_equal 'Hello!', result
  end

  def test_respond_with_multiple_responses_consumed_in_order
    @provider.respond_with('first', 'second', 'third')

    r1 = @provider.call(messages: [], model: 'test')
    r2 = @provider.call(messages: [], model: 'test')
    r3 = @provider.call(messages: [], model: 'test')

    assert_equal 'first', r1
    assert_equal 'second', r2
    assert_equal 'third', r3
  end

  def test_last_response_repeats_when_exhausted
    @provider.respond_with('one', 'two')

    @provider.call(messages: [], model: 'test')
    @provider.call(messages: [], model: 'test')
    r3 = @provider.call(messages: [], model: 'test')
    r4 = @provider.call(messages: [], model: 'test')

    assert_equal 'two', r3
    assert_equal 'two', r4
  end

  def test_streaming_mode_yields_chars_to_block
    @provider.respond_with('Hi!')
    chunks = []

    @provider.call(messages: [], model: 'test') do |chunk|
      chunks << chunk
    end

    assert_equal ['H', 'i', '!'], chunks
  end

  def test_streaming_mode_still_returns_full_response
    @provider.respond_with('Hello')
    result = @provider.call(messages: [], model: 'test') { |_c| }
    assert_equal 'Hello', result
  end

  def test_call_recording_calls
    @provider.respond_with('response')
    messages = [{ role: 'user', content: 'test' }]
    @provider.call(messages: messages, model: 'gpt-4')

    assert_equal 1, @provider.calls.size
    assert_equal messages, @provider.calls[0][:messages]
    assert_equal 'gpt-4', @provider.calls[0][:model]
  end

  def test_call_count
    @provider.respond_with('r')

    assert_equal 0, @provider.call_count
    @provider.call(messages: [], model: 'test')
    assert_equal 1, @provider.call_count
    @provider.call(messages: [], model: 'test')
    assert_equal 2, @provider.call_count
  end

  def test_last_call
    @provider.respond_with('r')

    @provider.call(messages: [{ role: 'user', content: 'first' }], model: 'm1')
    @provider.call(messages: [{ role: 'user', content: 'second' }], model: 'm2')

    assert_equal [{ role: 'user', content: 'second' }], @provider.last_call[:messages]
    assert_equal 'm2', @provider.last_call[:model]
  end

  def test_on_call_dynamic_handler
    @provider.on_call do |messages, model|
      "dynamic: #{messages.last[:content]} via #{model}"
    end

    result = @provider.call(
      messages: [{ role: 'user', content: 'ping' }],
      model: 'claude'
    )
    assert_equal 'dynamic: ping via claude', result
  end

  def test_on_call_takes_precedence_over_respond_with
    @provider.respond_with('static')
    @provider.on_call { |_m, _model| 'dynamic' }

    result = @provider.call(messages: [], model: 'test')
    assert_equal 'dynamic', result
  end

  def test_reset_clears_state
    @provider.respond_with('data')
    @provider.on_call { |_m, _model| 'handler' }
    @provider.call(messages: [], model: 'test')

    @provider.reset!

    assert_equal 0, @provider.call_count
    assert_empty @provider.calls
    result = @provider.call(messages: [], model: 'test')
    assert_equal '', result
  end

  def test_empty_response_when_nothing_configured
    result = @provider.call(messages: [{ role: 'user', content: 'hello' }], model: 'test')
    assert_equal '', result
  end

  def test_respond_with_returns_self_for_chaining
    returned = @provider.respond_with('a')
    assert_same @provider, returned
  end

  def test_is_subclass_of_provider
    assert_kind_of Kernai::Provider, @provider
  end
end
