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

  def test_includes_skills_command_hint
    result = Kernai::InstructionBuilder.new('Base.', skills: [:search]).build
    assert_includes result, '/skills'
    assert_includes result, 'name="/skills"'
  end

  def test_does_not_inject_skill_descriptions
    result = Kernai::InstructionBuilder.new('Base.', skills: [:search]).build
    refute_includes result, 'Search documents by keyword'
    refute_includes result, 'Available skills'
  end

  # --- Edge cases ---

  def test_empty_skills_array_still_adds_protocol
    result = Kernai::InstructionBuilder.new('Base.', skills: []).build
    assert_includes result, '<block type="final">'
    assert_includes result, '/skills'
  end

  def test_nil_skills_returns_base_only
    result = Kernai::InstructionBuilder.new('Base.', skills: nil).build
    assert_equal 'Base.', result
  end

  def test_callable_base_instructions
    builder = Kernai::InstructionBuilder.new(-> { 'Dynamic.' }, skills: [:search])
    result = builder.build
    assert_includes result, 'Dynamic.'
    assert_includes result, '/skills'
  end

  def test_skills_all_still_adds_protocol_only
    result = Kernai::InstructionBuilder.new('Base.', skills: :all).build
    assert_includes result, '/skills'
    refute_includes result, 'Search documents by keyword'
  end

  # --- Protocol awareness ---

  def test_no_protocol_mention_when_no_protocols_registered
    Kernai::Protocol.reset!
    result = Kernai::InstructionBuilder.new('Base.', skills: [:search]).build
    refute_includes result, '/protocols'
    refute_includes result, 'external protocol'
  end

  def test_protocol_mention_when_at_least_one_registered
    Kernai::Protocol.register(:fake) { |_b, _c| 'ok' }
    result = Kernai::InstructionBuilder.new('Base.', skills: [:search]).build
    assert_includes result, '/protocols'
    assert_includes result, 'external protocol'
  end

  def test_protocol_mention_hidden_when_agent_opts_out
    Kernai::Protocol.register(:fake) { |_b, _c| 'ok' }
    result = Kernai::InstructionBuilder.new('Base.', skills: [:search], protocols: []).build
    refute_includes result, '/protocols'
    refute_includes result, 'external protocol'
  end

  def test_protocol_mention_when_whitelist_matches_registered
    Kernai::Protocol.register(:fake) { |_b, _c| 'ok' }
    result = Kernai::InstructionBuilder.new('Base.', skills: [:search], protocols: [:fake]).build
    assert_includes result, '/protocols'
  end

  def test_protocol_mention_hidden_when_whitelist_matches_nothing_registered
    Kernai::Protocol.register(:fake) { |_b, _c| 'ok' }
    result = Kernai::InstructionBuilder.new('Base.', skills: [:search], protocols: [:other]).build
    refute_includes result, '/protocols'
  end

  # Regression: an agent with no local skills but a registered protocol
  # is still actionable through that protocol and MUST receive the block
  # protocol rules. Previously this was short-circuited by `@skills.nil?`,
  # which left protocol-only agents without any format guidance — they
  # would narrate in prose and the kernel would terminate with the raw
  # response as the final result.
  def test_protocol_only_agent_still_receives_block_protocol
    Kernai::Protocol.register(:fake) { |_b, _c| 'ok' }
    result = Kernai::InstructionBuilder.new('Base.', skills: nil).build
    assert_includes result, 'Base.'
    assert_includes result, '<block type="command"'
    assert_includes result, '<block type="final">'
    assert_includes result, '/protocols'
    assert_includes result, 'external protocol'
  end

  def test_protocol_only_agent_with_explicit_whitelist
    Kernai::Protocol.register(:fake) { |_b, _c| 'ok' }
    result = Kernai::InstructionBuilder.new('Base.', skills: nil, protocols: [:fake]).build
    assert_includes result, '<block type="final">'
    assert_includes result, '/protocols'
  end

  def test_protocol_opt_out_empty_array_returns_base_only_when_no_skills
    Kernai::Protocol.register(:fake) { |_b, _c| 'ok' }
    result = Kernai::InstructionBuilder.new('Base.', skills: nil, protocols: []).build
    assert_equal 'Base.', result
  end

  def test_chatbot_pure_case_still_returns_base_only
    # skills: nil AND no protocols registered → purely conversational agent
    Kernai::Protocol.reset!
    result = Kernai::InstructionBuilder.new('Base.', skills: nil).build
    assert_equal 'Base.', result
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
    assert_includes result, '/skills'
    assert_includes result, '<block type="command"'
    refute_includes result, 'Get weather for a city'
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
    assert_includes r1, '/skills'
  end

  def test_agent_skills_all
    Kernai::Skill.define(:search) do
      description 'Search things'
      input :query, String
      execute { |_| 'ok' }
    end

    agent = Kernai::Agent.new(instructions: 'Base.', skills: :all)
    result = agent.resolve_instructions
    assert_includes result, '/skills'
    refute_includes result, 'Search things'
    refute_includes result, 'Get weather'
  end
end
