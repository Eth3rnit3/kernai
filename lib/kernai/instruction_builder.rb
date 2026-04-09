# frozen_string_literal: true

module Kernai
  class InstructionBuilder
    def initialize(base_instructions, skills: nil, protocols: nil, workflow_enabled: true)
      @base_instructions = base_instructions
      @skills = skills
      @protocols = protocols
      @workflow_enabled = workflow_enabled
    end

    def build
      base = resolve_base

      return base unless actionable?

      [base, block_protocol].join("\n\n")
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
        2. Use <block type="command"> to call skills when you need data or actions
        3. You will receive results in <block type="result"> or errors in <block type="error">
        4. Analyze results and call more skills if needed
        5. When done, provide your final answer in <block type="final">
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
