# frozen_string_literal: true

module Kernai
  class Agent
    attr_reader :model, :max_steps
    attr_accessor :provider, :instructions, :skills, :protocols

    # `protocols` is a whitelist of Protocol block types this agent may address:
    #   nil  → all registered protocols are allowed (default)
    #   []   → no protocol is allowed (explicit opt-out)
    #   [:mcp, :a2a] → only the named protocols are allowed
    def initialize(instructions:, provider: nil, model: nil, max_steps: 10, skills: nil, protocols: nil)
      @instructions = instructions
      @provider = provider
      @model = model
      @max_steps = max_steps
      @skills = skills
      @protocols = protocols
    end

    def resolve_instructions(workflow_enabled: true)
      InstructionBuilder.new(
        @instructions,
        skills: @skills,
        protocols: @protocols,
        workflow_enabled: workflow_enabled
      ).build
    end

    def update_instructions(text)
      @instructions = text
    end
  end
end
