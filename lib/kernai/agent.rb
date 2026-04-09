# frozen_string_literal: true

module Kernai
  class Agent
    attr_reader :model, :max_steps
    attr_accessor :provider, :instructions, :skills

    def initialize(instructions:, provider: nil, model: nil, max_steps: 10, skills: nil)
      @instructions = instructions
      @provider = provider
      @model = model
      @max_steps = max_steps
      @skills = skills
    end

    def resolve_instructions(workflow_enabled: true)
      InstructionBuilder.new(
        @instructions,
        skills: @skills,
        workflow_enabled: workflow_enabled
      ).build
    end

    def update_instructions(text)
      @instructions = text
    end
  end
end
