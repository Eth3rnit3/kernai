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

    def resolve_instructions
      InstructionBuilder.new(@instructions, skills: @skills).build
    end

    def update_instructions(text)
      @instructions = text
    end
  end
end
