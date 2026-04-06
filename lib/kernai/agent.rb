module Kernai
  class Agent
    attr_reader :model, :max_steps
    attr_accessor :provider, :instructions

    def initialize(instructions:, provider: nil, model: nil, max_steps: 10)
      @instructions = instructions
      @provider = provider
      @model = model
      @max_steps = max_steps
    end

    def resolve_instructions
      if @instructions.respond_to?(:call)
        @instructions.call
      else
        @instructions.to_s
      end
    end

    def update_instructions(text)
      @instructions = text
    end
  end
end
