module Kernai
  class InstructionBuilder
    def initialize(base_instructions, skills: nil)
      @base_instructions = base_instructions
      @skills = skills
    end

    def build
      base = resolve_base

      return base if @skills.nil?

      parts = [base, block_protocol]
      descriptions = skill_descriptions
      parts << descriptions if descriptions
      parts.join("\n\n")
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
        - command: execute a skill (requires name attribute)
          <block type="command" name="SKILL_NAME">parameters</block>
        - final: your final answer to the user
          <block type="final">Your answer here</block>
        - plan: your reasoning before acting (optional)
          <block type="plan">Your thinking</block>

        Workflow:
        1. Use <block type="command"> to call skills when you need data or actions
        2. You will receive results in <block type="result"> or errors in <block type="error">
        3. Analyze results and call more skills if needed
        4. When done, provide your final answer in <block type="final">
      PROTOCOL
    end

    def skill_descriptions
      skills = resolve_skills
      return nil if skills.empty?

      lines = ["Available skills:"]
      skills.each { |skill| lines << format_skill(skill) }
      lines.join("\n")
    end

    def resolve_skills
      names = case @skills
              when :all then Skill.all.map(&:name)
              when Array then @skills
              else return []
              end

      names.filter_map { |name| Skill.find(name) }
    end

    def format_skill(skill)
      parts = ["\n- #{skill.name}"]
      parts << ": #{skill.description_text}" if skill.description_text

      if skill.inputs.any?
        parts << "\n  Inputs: #{format_inputs(skill)}"
        parts << "\n  Usage: #{format_usage(skill)}"
      end

      parts.join
    end

    def format_inputs(skill)
      skill.inputs.map do |name, spec|
        str = "#{name} (#{spec[:type]})"
        str += " default: #{spec[:default]}" unless spec[:default] == :__no_default__
        str
      end.join(", ")
    end

    def format_usage(skill)
      if skill.inputs.size == 1
        input_name = skill.inputs.keys.first
        "<block type=\"command\" name=\"#{skill.name}\">#{input_name} value here</block>"
      else
        json_example = skill.inputs.map { |k, v| "\"#{k}\": \"...\"" }.join(", ")
        "<block type=\"command\" name=\"#{skill.name}\">{#{json_example}}</block>"
      end
    end
  end
end
