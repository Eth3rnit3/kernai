# frozen_string_literal: true

require_relative 'vcr_helper'
require_relative 'scenario_helpers'
require 'stringio'

class TestOllamaScenarios < Minitest::Test
  include Kernai::TestHelpers
  include ScenarioHelpers

  def setup
    super
    Kernai.config.debug = true
    @provider = Kernai::Examples::OllamaProvider.new
  end

  # --- Scenario 1: Inventory lookup ---

  def test_inventory_lookup
    setup_inventory_skill

    VCR.use_cassette('ollama_scenario_inventory') do
      agent = Kernai::Agent.new(
        instructions: INVENTORY_INSTRUCTIONS,
        provider: @provider,
        model: 'gemma3:27b',
        max_steps: 5
      )

      events = []
      result = Kernai::Kernel.run(agent, 'Which products are out of stock?') do |event|
        events << event
      end

      skill_events = events.select { |e| e.type == :skill_result }
      assert skill_events.any?, 'LLM should have used the inventory skill'
      assert_equal :inventory, skill_events.first.data[:skill]

      assert(result.include?('Carbon') || result.include?('WDG-402'),
             'Result should mention the out-of-stock product (Carbon Widget / WDG-402)')

      final_events = events.select { |e| e.type == :final }
      assert_equal 1, final_events.size
    end
  end

  # --- Scenario 2: Weather advisor ---

  def test_weather_outdoor_recommendation
    setup_weather_skill

    VCR.use_cassette('ollama_scenario_weather') do
      agent = Kernai::Agent.new(
        instructions: WEATHER_ADVISOR_INSTRUCTIONS,
        provider: @provider,
        model: 'gemma3:27b',
        max_steps: 5
      )

      events = []
      result = Kernai::Kernel.run(agent, "I'm in London, should I go for a bike ride today?") do |event|
        events << event
      end

      skill_events = events.select { |e| e.type == :skill_result }
      assert skill_events.any?, 'LLM should have used the weather skill'
      assert_equal :weather, skill_events.first.data[:skill]

      refute result.empty?, 'Should have a final answer'
    end
  end

  # --- Scenario 3: Data analysis with multiple skills ---

  def test_data_analysis_premium_users
    setup_user_database_skill
    setup_calculator_skill

    VCR.use_cassette('ollama_scenario_data_analysis') do
      agent = Kernai::Agent.new(
        instructions: DATA_ANALYST_INSTRUCTIONS,
        provider: @provider,
        model: 'gemma3:27b',
        max_steps: 10
      )

      events = []
      result = Kernai::Kernel.run(agent, 'What percentage of active users are on the premium plan?') do |event|
        events << event
      end

      skill_events = events.select { |e| e.type == :skill_result }
      skill_names = skill_events.map { |e| e.data[:skill] }

      assert_includes skill_names, :user_database, 'LLM should have queried the database'
      assert_includes skill_names, :calculator, 'LLM should have used the calculator'

      assert_includes result, '50', 'Result should contain the correct percentage (50%)'
    end
  end
end
