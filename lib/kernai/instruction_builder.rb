# frozen_string_literal: true

module Kernai
  class InstructionBuilder
    def initialize(base_instructions, skills: nil)
      @base_instructions = base_instructions
      @skills = skills
    end

    def build
      base = resolve_base

      return base if @skills.nil?

      [base, block_protocol].join("\n\n")
    end

    private

    def resolve_base
      if @base_instructions.respond_to?(:call)
        @base_instructions.call
      else
        @base_instructions.to_s
      end
    end

    def block_protocol
      <<~PROTOCOL.strip
        You MUST respond using XML blocks with this syntax:
        <block type="TYPE">content</block>

        Block types:
        - command: execute a skill or built-in command (requires name attribute)
          <block type="command" name="SKILL_NAME">parameters</block>
        - final: your final answer to the user
          <block type="final">Your answer here</block>
        - plan: your reasoning before acting (optional)
          <block type="plan">Your thinking</block>

        Built-in commands:
        - /skills: list all available skills and their usage
          <block type="command" name="/skills"></block>

        Workflow:
        1. Start by listing available skills with /skills
        2. Use <block type="command"> to call skills when you need data or actions
        3. You will receive results in <block type="result"> or errors in <block type="error">
        4. Analyze results and call more skills if needed
        5. When done, provide your final answer in <block type="final">
      PROTOCOL
    end
  end
end
