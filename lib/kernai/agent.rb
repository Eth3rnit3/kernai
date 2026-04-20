# frozen_string_literal: true

module Kernai
  class Agent
    attr_reader :model, :max_steps, :generation
    attr_accessor :provider, :instructions, :skills, :protocols

    # `protocols` is a whitelist of Protocol block types this agent may address:
    #   nil  → all registered protocols are allowed (default)
    #   []   → no protocol is allowed (explicit opt-out)
    #   [:mcp, :a2a] → only the named protocols are allowed
    #
    # `generation` is a Kernai::GenerationOptions describing provider-agnostic
    # generation knobs (temperature, max_tokens, top_p, thinking, and
    # vendor-specific extras). Accepts `nil`, a Hash, or an existing
    # GenerationOptions instance.
    def initialize(instructions:, provider: nil, model: Models::TEXT_ONLY, max_steps: 10, skills: nil,
                   protocols: nil, generation: nil)
      raise ArgumentError, 'model: must be a Kernai::Model' unless model.is_a?(Model)

      @instructions = instructions
      @provider = provider
      @model = model
      @max_steps = max_steps
      @skills = skills
      @protocols = protocols
      @generation = GenerationOptions.coerce(generation)
    end

    def resolve_instructions(workflow_enabled: true)
      InstructionBuilder.new(
        @instructions,
        model: @model,
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
