# frozen_string_literal: true

module Kernai
  class InstructionBuilder
    def initialize(base_instructions, model: Models::TEXT_ONLY, skills: nil, protocols: nil, workflow_enabled: true)
      @base_instructions = base_instructions
      @model = model
      @skills = skills
      @protocols = protocols
      @workflow_enabled = workflow_enabled
    end

    def build
      base = resolve_base

      return base unless actionable?

      [base, block_protocol, *capability_sections].join("\n\n")
    end

    private

    # An agent is "actionable" — and therefore needs the block-protocol
    # rules injected — as soon as it has at least one rail to act through:
    # a skills whitelist (even an empty array, meaning "skills mechanism
    # opted in") or a visible protocol. The pure-chatbot case (skills: nil
    # + no visible protocol) gets the base instructions untouched.
    def actionable?
      return true unless @skills.nil?

      protocols_visible?
    end

    def resolve_base
      if @base_instructions.respond_to?(:call)
        @base_instructions.call
      else
        @base_instructions.to_s
      end
    end

    # Capability-driven appendices. Each section returns either a
    # non-empty String (appended to the prompt) or an empty String
    # (filtered out). The set of sections is fixed — enabling or
    # disabling one is a property of the model's capabilities, not a
    # conditional in the builder.
    def capability_sections
      [media_input_section, media_output_section].reject(&:empty?)
    end

    def media_input_section
      inputs = @model.supported_media_inputs
      return '' if inputs.empty?

      kinds = inputs.map(&:to_s).join(', ')
      <<~SECTION.strip
        ## MULTIMODAL INPUTS

        Your model can perceive #{kinds} content. When the user provides
        such a part in a message, it is available to you natively — no
        special block is needed to "load" it. Reason about it directly
        and reference it in your answer.
      SECTION
    end

    def media_output_section
      return '' unless @model.supports?(:image_gen) || @model.supports?(:audio_out)

      outs = []
      outs << 'images' if @model.supports?(:image_gen)
      outs << 'audio'  if @model.supports?(:audio_out)

      <<~SECTION.strip
        ## MULTIMODAL OUTPUTS

        Your model can emit #{outs.join(' and ')} alongside text. Prefer
        calling a skill that `produces` the relevant media kind: the
        runtime will capture the returned Media and inject it back into
        the conversation as a <block type="result"> referencing the
        media id. Do not attempt to emit raw binary in a text block.
      SECTION
    end

    def block_protocol
      <<~PROTOCOL.strip
        ## RESPONSE FORMAT (non-negotiable)

        You communicate EXCLUSIVELY through XML blocks:

        <block type="TYPE">content</block>

        Hard rules — violating any of these means your turn accomplishes nothing:
        - Every response MUST contain at least one <block>. Plain prose outside
          of blocks is discarded by the runtime and your turn will terminate
          with no effect.
        - NEVER narrate your intent in prose ("I will now call ..."). Emit the
          block directly. If you need to think out loud, wrap the thought in
          <block type="plan">...</block> — that is the ONLY way to reason
          visibly without breaking the protocol.
        - NEVER describe a block you are about to emit in prose beforehand.
          Just emit it.
        - Multiple blocks per response are allowed and executed in order.

        Block types:
        - command: execute a skill or built-in command (requires a name attribute)
          <block type="command" name="SKILL_NAME">parameters</block>
        - final: your final answer to the user — ends the conversation
          <block type="final">Your answer here</block>
        - plan: reasoning/thinking (emitted, visible to you, does NOT terminate the turn)
          <block type="plan">Your thinking</block>
        #{protocol_block_hint}
        Built-in commands:
        - /skills: list all available skills and their usage
          <block type="command" name="/skills"></block>
        #{protocols_builtin_hint}#{workflow_hint}
        Workflow:
        1. Start by listing available skills with /skills#{protocols_workflow_hint}
        2. Before calling a skill for the first time, locate it in the /skills
           output and copy its parameter names EXACTLY from the "Inputs:" line
           and the example in "Usage:". Do NOT infer parameter names from
           memory or from other tools you may know (Aider, Cursor, Anthropic
           Edit, OpenAI function calls, etc.) — they will not match.
        3. Use <block type="command"> to call skills when you need data or actions
        4. You will receive results in <block type="result"> or errors in <block type="error">
        5. Analyze results and call more skills if needed
        6. When done, provide your final answer in <block type="final">
      PROTOCOL
    end

    # True when at least one protocol is registered AND this agent has not
    # explicitly opted out by passing `protocols: []`.
    def protocols_visible?
      return false if @protocols == []

      registered = Protocol.all
      return false if registered.empty?

      return true if @protocols.nil?

      scope = @protocols.map(&:to_sym)
      registered.any? { |r| scope.include?(r.name) }
    end

    def protocol_block_hint
      return '' unless protocols_visible?

      <<~HINT.chomp
        - <protocol_name>: address an external protocol directly (e.g. MCP)
          <block type="PROTOCOL_NAME">protocol-specific JSON request</block>
          Protocols are distinct from skills: skills are local Ruby callables,
          protocols are external systems reached through a dedicated handler.
      HINT
    end

    def protocols_builtin_hint
      return '' unless protocols_visible?

      <<~HINT
        - /protocols: list registered protocols and their documentation
          <block type="command" name="/protocols"></block>
      HINT
    end

    def protocols_workflow_hint
      return '' unless protocols_visible?

      ' and registered protocols with /protocols'
    end

    def workflow_hint
      return '' unless @workflow_enabled

      <<~HINT.chomp
        - /workflow: show the structured plan format documentation
          <block type="command" name="/workflow"></block>
        - /tasks: show the current task execution state
          <block type="command" name="/tasks"></block>

        Structured workflows (optional): you may emit a <block type="plan"> containing JSON
        {"goal":"...","strategy":"parallel|sequential|mixed","tasks":[{"id":"t1","input":"...","parallel":true,"depends_on":[]}]}
        Each task runs as an isolated sub-agent. Results come back in <block type="result" name="tasks">.
        Call /workflow for details.
      HINT
    end
  end
end
