# frozen_string_literal: true

require_relative '../test_helper'

class TestGenerationOptions < Minitest::Test
  include Kernai::TestHelpers

  # --- Construction ---

  def test_empty_by_default
    opts = Kernai::GenerationOptions.new
    assert opts.empty?
    assert_equal({}, opts.to_h)
  end

  def test_stores_well_known_fields
    opts = Kernai::GenerationOptions.new(
      temperature: 0.2,
      max_tokens: 512,
      top_p: 0.9,
      thinking: { budget: 10_000 }
    )

    refute opts.empty?
    assert_in_delta 0.2, opts.temperature
    assert_equal 512, opts.max_tokens
    assert_in_delta 0.9, opts.top_p
    assert_equal({ budget: 10_000 }, opts.thinking)
  end

  def test_captures_vendor_specific_extras
    opts = Kernai::GenerationOptions.new(temperature: 0.1, response_format: 'json')
    assert_equal({ temperature: 0.1, response_format: 'json' }, opts.to_h)
    assert_equal({ response_format: 'json' }, opts.extra)
  end

  def test_to_h_compacts_nil_well_known_fields
    opts = Kernai::GenerationOptions.new(temperature: 0.5)
    assert_equal({ temperature: 0.5 }, opts.to_h)
  end

  # --- merge ---

  def test_merge_with_hash_overlays
    base = Kernai::GenerationOptions.new(temperature: 0.1, max_tokens: 100)
    merged = base.merge(temperature: 0.9)

    assert_in_delta 0.9, merged.temperature
    assert_equal 100, merged.max_tokens
  end

  def test_merge_with_nil_is_noop
    base = Kernai::GenerationOptions.new(temperature: 0.3)
    assert_same base, base.merge(nil)
  end

  def test_merge_with_other_generation_options
    base  = Kernai::GenerationOptions.new(temperature: 0.1)
    other = Kernai::GenerationOptions.new(max_tokens: 42)
    merged = base.merge(other)

    assert_in_delta 0.1, merged.temperature
    assert_equal 42, merged.max_tokens
  end

  # --- coerce ---

  def test_coerce_nil_returns_empty
    assert Kernai::GenerationOptions.coerce(nil).empty?
  end

  def test_coerce_hash_returns_new_options
    opts = Kernai::GenerationOptions.coerce(temperature: 0.5)
    assert_in_delta 0.5, opts.temperature
  end

  def test_coerce_existing_options_returns_same
    existing = Kernai::GenerationOptions.new(temperature: 0.1)
    assert_same existing, Kernai::GenerationOptions.coerce(existing)
  end

  def test_coerce_unknown_type_raises
    assert_raises(ArgumentError) { Kernai::GenerationOptions.coerce('bad') }
  end

  # --- equality / hash ---

  def test_equality_by_content
    a = Kernai::GenerationOptions.new(temperature: 0.2, max_tokens: 50)
    b = Kernai::GenerationOptions.new(temperature: 0.2, max_tokens: 50)
    assert_equal a, b
    assert_equal a.hash, b.hash
  end

  def test_inequality_when_any_field_differs
    a = Kernai::GenerationOptions.new(temperature: 0.1)
    b = Kernai::GenerationOptions.new(temperature: 0.2)
    refute_equal a, b
  end

  # --- Agent integration ---

  def test_agent_coerces_hash_to_generation_options
    agent = Kernai::Agent.new(
      instructions: 'test',
      generation: { temperature: 0.1, max_tokens: 100 }
    )
    assert_instance_of Kernai::GenerationOptions, agent.generation
    assert_in_delta 0.1, agent.generation.temperature
    assert_equal 100, agent.generation.max_tokens
  end

  def test_agent_defaults_to_empty_generation_options
    agent = Kernai::Agent.new(instructions: 'test')
    assert agent.generation.empty?
  end

  def test_agent_accepts_generation_options_instance
    opts = Kernai::GenerationOptions.new(thinking: { budget: 5_000 })
    agent = Kernai::Agent.new(instructions: 'test', generation: opts)
    assert_same opts, agent.generation
  end

  # --- Kernel → Provider plumbing ---

  def test_kernel_passes_generation_to_provider
    provider = Kernai::Mock::Provider.new.respond_with('<block type="final">OK</block>')
    agent = Kernai::Agent.new(
      instructions: 'test',
      provider: provider,
      generation: { temperature: 0.42 }
    )

    Kernai::Kernel.run(agent, 'hi')

    gen = provider.last_call[:generation]
    assert_instance_of Kernai::GenerationOptions, gen
    assert_in_delta 0.42, gen.temperature
  end

  def test_kernel_passes_empty_generation_when_agent_has_none
    provider = Kernai::Mock::Provider.new.respond_with('<block type="final">OK</block>')
    agent = Kernai::Agent.new(instructions: 'test', provider: provider)

    Kernai::Kernel.run(agent, 'hi')

    gen = provider.last_call[:generation]
    assert_instance_of Kernai::GenerationOptions, gen
    assert gen.empty?
  end
end
