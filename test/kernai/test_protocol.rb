# frozen_string_literal: true

require 'test_helper'

class TestProtocol < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    Kernai::Protocol.reset!
  end

  # --- register ---

  def test_register_returns_symbol_name
    name = Kernai::Protocol.register(:mcp, documentation: 'doc') { |_b, _c| 'ok' }
    assert_equal :mcp, name
  end

  def test_register_accepts_string_name
    Kernai::Protocol.register('mcp') { |_b, _c| 'ok' }
    assert Kernai::Protocol.registered?(:mcp)
  end

  def test_register_raises_without_name
    assert_raises(ArgumentError) do
      Kernai::Protocol.register(nil) { |_b, _c| 'ok' }
    end
  end

  def test_register_raises_on_blank_name
    assert_raises(ArgumentError) do
      Kernai::Protocol.register('   ') { |_b, _c| 'ok' }
    end
  end

  def test_register_raises_without_block
    assert_raises(ArgumentError) do
      Kernai::Protocol.register(:mcp)
    end
  end

  def test_register_refuses_core_block_types
    Kernai::Protocol::CORE_BLOCK_TYPES.each do |reserved|
      assert_raises(ArgumentError, "should refuse :#{reserved}") do
        Kernai::Protocol.register(reserved) { |_b, _c| 'ok' }
      end
    end
  end

  def test_register_overwrites_previous_registration
    Kernai::Protocol.register(:mcp, documentation: 'v1') { |_b, _c| 'v1' }
    Kernai::Protocol.register(:mcp, documentation: 'v2') { |_b, _c| 'v2' }

    assert_equal 'v2', Kernai::Protocol.documentation_for(:mcp)
    assert_equal 'v2', Kernai::Protocol.handler_for(:mcp).call(nil, nil)
    assert_equal 1, Kernai::Protocol.all.size
  end

  # --- lookup ---

  def test_registered_accepts_symbol_and_string
    Kernai::Protocol.register(:mcp) { |_b, _c| 'ok' }
    assert Kernai::Protocol.registered?(:mcp)
    assert Kernai::Protocol.registered?('mcp')
    refute Kernai::Protocol.registered?(:other)
  end

  def test_registered_false_for_nil
    refute Kernai::Protocol.registered?(nil)
  end

  def test_handler_for_returns_callable
    Kernai::Protocol.register(:mcp) { |_b, _c| 'payload' }
    assert_equal 'payload', Kernai::Protocol.handler_for(:mcp).call(nil, nil)
  end

  def test_handler_for_nil_on_missing
    assert_nil Kernai::Protocol.handler_for(:missing)
    assert_nil Kernai::Protocol.handler_for(nil)
  end

  def test_documentation_for
    Kernai::Protocol.register(:mcp, documentation: 'MCP doc') { |_b, _c| 'ok' }
    assert_equal 'MCP doc', Kernai::Protocol.documentation_for(:mcp)
    assert_nil Kernai::Protocol.documentation_for(:missing)
  end

  def test_documentation_nil_by_default
    Kernai::Protocol.register(:mcp) { |_b, _c| 'ok' }
    assert_nil Kernai::Protocol.documentation_for(:mcp)
  end

  # --- all / names ---

  def test_all_returns_registrations
    Kernai::Protocol.register(:mcp, documentation: 'a') { |_b, _c| 'ok' }
    Kernai::Protocol.register(:a2a, documentation: 'b') { |_b, _c| 'ok' }

    all = Kernai::Protocol.all
    assert_equal 2, all.size
    assert(all.all? { |r| r.is_a?(Kernai::Protocol::Registration) })
    names = all.map(&:name).sort
    assert_equal %i[a2a mcp], names
  end

  def test_all_empty_by_default
    assert_equal [], Kernai::Protocol.all
  end

  def test_names
    Kernai::Protocol.register(:mcp) { |_b, _c| 'ok' }
    Kernai::Protocol.register(:a2a) { |_b, _c| 'ok' }
    assert_equal %i[a2a mcp], Kernai::Protocol.names.sort
  end

  # --- unregister / reset ---

  def test_unregister
    Kernai::Protocol.register(:mcp) { |_b, _c| 'ok' }
    assert Kernai::Protocol.registered?(:mcp)

    Kernai::Protocol.unregister(:mcp)
    refute Kernai::Protocol.registered?(:mcp)
  end

  def test_unregister_nil_is_noop
    assert_nil Kernai::Protocol.unregister(nil)
  end

  def test_reset_clears_all
    Kernai::Protocol.register(:mcp) { |_b, _c| 'ok' }
    Kernai::Protocol.register(:a2a) { |_b, _c| 'ok' }

    Kernai::Protocol.reset!
    assert_equal [], Kernai::Protocol.all
  end

  def test_kernai_reset_clears_protocols
    Kernai::Protocol.register(:mcp) { |_b, _c| 'ok' }
    Kernai.reset!
    assert_equal [], Kernai::Protocol.all
  end

  # --- thread safety ---

  def test_concurrent_register_is_consistent
    threads = 50.times.map do |i|
      Thread.new do
        Kernai::Protocol.register("proto_#{i}".to_sym) { |_b, _c| i.to_s }
      end
    end
    threads.each(&:join)

    assert_equal 50, Kernai::Protocol.all.size
    50.times { |i| assert Kernai::Protocol.registered?("proto_#{i}".to_sym) }
  end

  def test_concurrent_register_and_read
    writer = Thread.new do
      100.times { |i| Kernai::Protocol.register("p#{i}".to_sym) { |_b, _c| 'ok' } }
    end

    reader = Thread.new do
      100.times { Kernai::Protocol.all }
    end

    [writer, reader].each(&:join)
    assert_equal 100, Kernai::Protocol.all.size
  end
end
