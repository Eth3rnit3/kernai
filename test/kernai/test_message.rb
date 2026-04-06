# frozen_string_literal: true

require_relative '../test_helper'

class TestMessage < Minitest::Test
  include Kernai::TestHelpers

  def test_creates_message_with_role_and_content
    msg = Kernai::Message.new(role: :user, content: 'hello')
    assert_equal :user, msg.role
    assert_equal 'hello', msg.content
  end

  def test_role_is_converted_to_symbol
    msg = Kernai::Message.new(role: 'assistant', content: 'hi')
    assert_equal :assistant, msg.role
  end

  def test_system_predicate
    msg = Kernai::Message.new(role: :system, content: 'you are helpful')
    assert msg.system?
    refute msg.user?
    refute msg.assistant?
  end

  def test_user_predicate
    msg = Kernai::Message.new(role: :user, content: 'question')
    assert msg.user?
    refute msg.system?
    refute msg.assistant?
  end

  def test_assistant_predicate
    msg = Kernai::Message.new(role: :assistant, content: 'answer')
    assert msg.assistant?
    refute msg.system?
    refute msg.user?
  end

  def test_to_h_returns_hash
    msg = Kernai::Message.new(role: :user, content: 'test')
    expected = { role: :user, content: 'test' }
    assert_equal expected, msg.to_h
  end

  def test_to_h_with_string_role_still_returns_symbol
    msg = Kernai::Message.new(role: 'system', content: 'prompt')
    hash = msg.to_h
    assert_equal :system, hash[:role]
    assert_equal 'prompt', hash[:content]
  end

  def test_content_preserves_multiline_text
    content = "line one\nline two\nline three"
    msg = Kernai::Message.new(role: :assistant, content: content)
    assert_equal content, msg.content
  end

  def test_content_can_be_empty_string
    msg = Kernai::Message.new(role: :assistant, content: '')
    assert_equal '', msg.content
  end
end
