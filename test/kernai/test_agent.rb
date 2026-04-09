# frozen_string_literal: true

require_relative '../test_helper'

class TestAgent < Minitest::Test
  include Kernai::TestHelpers

  def test_creation_with_all_params
    provider = Kernai::Mock::Provider.new
    agent = Kernai::Agent.new(
      instructions: 'You are helpful',
      provider: provider,
      model: 'gpt-4',
      max_steps: 5
    )

    assert_equal 'gpt-4', agent.model
    assert_equal 5, agent.max_steps
    assert_equal provider, agent.provider
  end

  def test_default_max_steps
    agent = Kernai::Agent.new(instructions: 'test')
    assert_equal 10, agent.max_steps
  end

  def test_default_provider_is_nil
    agent = Kernai::Agent.new(instructions: 'test')
    assert_nil agent.provider
  end

  def test_resolve_instructions_with_string
    agent = Kernai::Agent.new(instructions: 'You are helpful')
    assert_equal 'You are helpful', agent.resolve_instructions
  end

  def test_resolve_instructions_with_lambda
    counter = 0
    agent = Kernai::Agent.new(instructions: lambda {
      counter += 1
      "Version #{counter}"
    })

    assert_equal 'Version 1', agent.resolve_instructions
    assert_equal 'Version 2', agent.resolve_instructions
  end

  def test_resolve_instructions_with_proc
    agent = Kernai::Agent.new(instructions: proc { 'dynamic' })
    assert_equal 'dynamic', agent.resolve_instructions
  end

  def test_update_instructions
    agent = Kernai::Agent.new(instructions: 'original')
    assert_equal 'original', agent.resolve_instructions

    agent.update_instructions('updated')
    assert_equal 'updated', agent.resolve_instructions
  end

  def test_set_instructions_to_lambda
    agent = Kernai::Agent.new(instructions: 'static')
    agent.instructions = -> { 'now dynamic' }
    assert_equal 'now dynamic', agent.resolve_instructions
  end

  def test_hot_reload_instructions_evaluated_each_time
    store = 'v1'
    agent = Kernai::Agent.new(instructions: -> { store })

    assert_equal 'v1', agent.resolve_instructions
    store = 'v2'
    assert_equal 'v2', agent.resolve_instructions
  end

  def test_provider_is_settable
    agent = Kernai::Agent.new(instructions: 'test')
    provider = Kernai::Mock::Provider.new
    agent.provider = provider
    assert_equal provider, agent.provider
  end

  # --- protocols whitelist ---

  def test_protocols_default_is_nil
    agent = Kernai::Agent.new(instructions: 'test')
    assert_nil agent.protocols
  end

  def test_protocols_can_be_set_at_init
    agent = Kernai::Agent.new(instructions: 'test', protocols: [:mcp])
    assert_equal [:mcp], agent.protocols
  end

  def test_protocols_can_be_empty_array
    agent = Kernai::Agent.new(instructions: 'test', protocols: [])
    assert_equal [], agent.protocols
  end

  def test_protocols_mutable_via_accessor
    agent = Kernai::Agent.new(instructions: 'test')
    agent.protocols = %i[mcp a2a]
    assert_equal %i[mcp a2a], agent.protocols
  end
end
