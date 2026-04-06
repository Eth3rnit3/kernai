# frozen_string_literal: true

require_relative '../test_helper'

class TestInstructionBuilder < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    Kernai::Skill.define(:search) do
      description 'Search documents by keyword'
      input :query, String
      execute { |p| p[:query] }
    end

    Kernai::Skill.define(:calculator) do
      description 'Evaluate a math expression'
      input :expression, String
      execute { |p| eval(p[:expression]).to_s }
    end

    Kernai::Skill.define(:api_call) do
      description 'Call an external API'
      input :url, String
      input :method, String, default: 'GET'
      execute { |_p| 'ok' }
    end

    Kernai::Skill.define(:bare_skill) do
      execute { |_| 'no description' }
    end
  end

  # --- Base behavior ---

  def test_includes_base_instructions
    result = Kernai::InstructionBuilder.new('You are helpful.', skills: [:search]).build
    assert_includes result, 'You are helpful.'
  end

  def test_includes_block_protocol
    result = Kernai::InstructionBuilder.new('Base.', skills: [:search]).build
    assert_includes result, '<block type="command"'
    assert_includes result, '<block type="final">'
    assert_includes result, 'plan'
  end

  def test_includes_skill_descriptions
    result = Kernai::InstructionBuilder.new('Base.', skills: [:search]).build
    assert_includes result, 'search'
    assert_includes result, 'Search documents by keyword'
  end

  # --- Skill formatting ---

  def test_single_input_skill_shows_usage
    result = Kernai::InstructionBuilder.new('Base.', skills: [:search]).build
    assert_includes result, 'name="search"'
    assert_includes result, 'query'
  end

  def test_multi_input_skill_shows_json_usage
    result = Kernai::InstructionBuilder.new('Base.', skills: [:api_call]).build
    assert_includes result, 'url'
    assert_includes result, 'method'
    assert_includes result, 'GET'
  end

  def test_skill_without_description
    result = Kernai::InstructionBuilder.new('Base.', skills: [:bare_skill]).build
    assert_includes result, 'bare_skill'
  end

  def test_multiple_skills
    result = Kernai::InstructionBuilder.new('Base.', skills: %i[search calculator]).build
    assert_includes result, 'search'
    assert_includes result, 'calculator'
    assert_includes result, 'Search documents'
    assert_includes result, 'Evaluate a math'
  end

  # --- Skills: :all ---

  def test_all_skills
    result = Kernai::InstructionBuilder.new('Base.', skills: :all).build
    assert_includes result, 'search'
    assert_includes result, 'calculator'
    assert_includes result, 'api_call'
    assert_includes result, 'bare_skill'
  end

  # --- Edge cases ---

  def test_empty_skills_array_still_adds_protocol
    result = Kernai::InstructionBuilder.new('Base.', skills: []).build
    assert_includes result, '<block type="final">'
    refute_includes result, 'Available skills'
  end

  def test_unknown_skill_is_skipped
    result = Kernai::InstructionBuilder.new('Base.', skills: %i[search nonexistent]).build
    assert_includes result, 'search'
    refute_includes result, 'nonexistent'
  end

  def test_nil_skills_returns_base_only
    result = Kernai::InstructionBuilder.new('Base.', skills: nil).build
    assert_equal 'Base.', result
  end

  def test_callable_base_instructions
    builder = Kernai::InstructionBuilder.new(-> { 'Dynamic.' }, skills: [:search])
    result = builder.build
    assert_includes result, 'Dynamic.'
    assert_includes result, 'search'
  end
end

class TestAgentWithSkills < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    Kernai::Skill.define(:weather) do
      description 'Get weather for a city'
      input :city, String
      execute { |_p| '{"temp": 20}' }
    end
  end

  def test_agent_resolve_instructions_with_skills
    agent = Kernai::Agent.new(
      instructions: 'You are a travel assistant.',
      skills: [:weather]
    )

    result = agent.resolve_instructions
    assert_includes result, 'You are a travel assistant.'
    assert_includes result, 'weather'
    assert_includes result, 'Get weather for a city'
    assert_includes result, '<block type="command"'
  end

  def test_agent_without_skills_is_unchanged
    agent = Kernai::Agent.new(instructions: 'Plain prompt.')
    assert_equal 'Plain prompt.', agent.resolve_instructions
  end

  def test_agent_with_lambda_and_skills
    counter = 0
    agent = Kernai::Agent.new(
      instructions: lambda {
        counter += 1
        "Version #{counter}"
      },
      skills: [:weather]
    )

    r1 = agent.resolve_instructions
    r2 = agent.resolve_instructions
    assert_includes r1, 'Version 1'
    assert_includes r2, 'Version 2'
    assert_includes r1, 'weather'
  end

  def test_agent_skills_all
    Kernai::Skill.define(:search) do
      description 'Search things'
      input :query, String
      execute { |_| 'ok' }
    end

    agent = Kernai::Agent.new(instructions: 'Base.', skills: :all)
    result = agent.resolve_instructions
    assert_includes result, 'weather'
    assert_includes result, 'search'
  end
end
