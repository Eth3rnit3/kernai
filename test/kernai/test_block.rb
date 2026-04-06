# frozen_string_literal: true

require_relative '../test_helper'

class TestBlock < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    Kernai::Block.reset_handlers!
  end

  # -- Creation and attributes --

  def test_block_creation_with_required_attributes
    block = Kernai::Block.new(type: :command, content: 'ls -la')
    assert_equal :command, block.type
    assert_equal 'ls -la', block.content
    assert_nil block.name
  end

  def test_block_creation_with_name
    block = Kernai::Block.new(type: :command, content: 'run', name: 'deploy')
    assert_equal :command, block.type
    assert_equal 'run', block.content
    assert_equal 'deploy', block.name
  end

  def test_block_type_is_symbol
    block = Kernai::Block.new(type: 'json', content: '{}')
    assert_equal :json, block.type
  end

  def test_block_types_constant
    assert_includes Kernai::Block::TYPES, :command
    assert_includes Kernai::Block::TYPES, :json
    assert_includes Kernai::Block::TYPES, :final
    assert_includes Kernai::Block::TYPES, :plan
    assert_includes Kernai::Block::TYPES, :result
    assert_includes Kernai::Block::TYPES, :error
  end

  # -- Handler registry --

  def test_define_and_retrieve_handler
    handler = proc { |content, _ctx| content.upcase }
    Kernai::Block.define(:command, &handler)

    assert_equal handler, Kernai::Block.handler_for(:command)
  end

  def test_handler_for_returns_nil_for_undefined_type
    assert_nil Kernai::Block.handler_for(:unknown)
  end

  def test_define_handler_with_block_syntax
    Kernai::Block.define(:json) do |content, _context|
      content.strip
    end

    handler = Kernai::Block.handler_for(:json)
    assert_instance_of Proc, handler
    assert_equal 'hello', handler.call('  hello  ', nil)
  end

  def test_reset_handlers_clears_all
    Kernai::Block.define(:command) { |c, _| c }
    Kernai::Block.define(:json) { |c, _| c }

    Kernai::Block.reset_handlers!

    assert_nil Kernai::Block.handler_for(:command)
    assert_nil Kernai::Block.handler_for(:json)
  end

  def test_define_handler_overwrites_previous
    Kernai::Block.define(:command) { |_c, _| 'first' }
    Kernai::Block.define(:command) { |_c, _| 'second' }

    handler = Kernai::Block.handler_for(:command)
    assert_equal 'second', handler.call(nil, nil)
  end

  def test_handler_for_accepts_string_type
    Kernai::Block.define(:error) { |c, _| c }
    assert_instance_of Proc, Kernai::Block.handler_for('error')
  end
end
