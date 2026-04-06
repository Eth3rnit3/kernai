# frozen_string_literal: true

require 'json'

module Kernai
  class Event
    attr_reader :type, :data

    def initialize(type, data)
      @type = type
      @data = data
    end
  end

  module Kernel
    class << self
      def run(agent, input, provider: nil, history: [], recorder: nil, &callback)
        provider = resolve_provider(agent, provider)
        raise ProviderError, 'No provider configured' unless provider

        rec = recorder || Kernai.config.recorder

        messages = [
          Message.new(role: :system, content: agent.resolve_instructions),
          *history.map { |m| Message.new(role: m[:role], content: m[:content]) },
          Message.new(role: :user, content: input)
        ]

        result = nil

        agent.max_steps.times do |step|
          # Hot reload: update system message each step
          messages[0] = Message.new(role: :system, content: agent.resolve_instructions)

          stream_parser = StreamParser.new
          blocks = []

          setup_stream_callbacks(stream_parser, blocks, callback)

          Kernai.logger.debug(event: 'llm.request', step: step + 1, model: agent.model)

          rec&.record(step: step, event: :messages_sent, data: messages.map(&:to_h))

          raw_response = provider.call(
            messages: messages.map(&:to_h),
            model: agent.model
          ) { |chunk| stream_parser.push(chunk) }

          stream_parser.flush

          Kernai.logger.debug(event: 'llm.response', step: step + 1)

          rec&.record(step: step, event: :raw_response, data: raw_response)

          messages << Message.new(role: :assistant, content: raw_response)

          final_block = blocks.find { |b| b.type == :final }
          command_blocks = blocks.select { |b| b.type == :command }

          rec&.record(step: step, event: :blocks_parsed, data: blocks.map(&:to_h))

          # Emit non-action block events
          blocks.each do |block|
            case block.type
            when :plan
              Kernai.logger.debug(event: 'block.complete', type: :plan)
              callback&.call(Event.new(:plan, block.content))
            when :json
              Kernai.logger.debug(event: 'block.complete', type: :json)
              callback&.call(Event.new(:json, block.content))
            end
          end

          # Commands take priority: execute them and continue the loop
          # even if the LLM also sent a final block (it needs to see results first)
          if command_blocks.any?
            command_blocks.each do |block|
              result_msg = execute_command(block, agent, rec, step, callback)
              messages << result_msg
            end
          elsif final_block
            result = final_block.content
            Kernai.logger.info(event: 'agent.complete', steps: step + 1)
            rec&.record(step: step, event: :result, data: result)
            callback&.call(Event.new(:final, result))
            break
          else
            # No blocks or only informational blocks — treat raw response as result
            result = raw_response
            rec&.record(step: step, event: :result, data: result)
            break
          end
        end

        raise MaxStepsReachedError, "Agent reached maximum steps (#{agent.max_steps})" if result.nil?

        result
      end

      private

      def resolve_provider(agent, override)
        override || agent.provider || Kernai.config.default_provider
      end

      def setup_stream_callbacks(parser, blocks, callback)
        parser.on(:text_chunk) do |data|
          callback&.call(Event.new(:text_chunk, data))
        end

        parser.on(:block_start) do |data|
          Kernai.logger.debug(event: 'block.detected', type: data[:type])
          callback&.call(Event.new(:block_start, data))
        end

        parser.on(:block_content) do |data|
          callback&.call(Event.new(:block_content, data))
        end

        parser.on(:block_complete) do |block|
          blocks << block
        end
      end

      def execute_command(block, agent, rec, step, callback)
        command_name = block.name&.strip

        unless command_name
          Kernai.logger.error(event: 'skill.execute', error: 'no skill name in command block')
          return Message.new(
            role: :user,
            content: '<block type="error">Command block missing skill name</block>'
          )
        end

        # Built-in commands (prefixed with /)
        return execute_builtin(command_name, agent, rec, step, callback) if command_name.start_with?('/')

        execute_skill(command_name.to_sym, block.content, rec, step, callback)
      end

      def execute_builtin(command_name, agent, rec, step, callback)
        case command_name
        when '/skills'
          listing = Skill.listing(agent.skills)
          Kernai.logger.info(event: 'builtin.execute', command: '/skills')
          rec&.record(step: step, event: :builtin_result, data: { command: '/skills', result: listing })
          callback&.call(Event.new(:builtin_result, { command: '/skills', result: listing }))

          Message.new(
            role: :user,
            content: "<block type=\"result\" name=\"/skills\">#{listing}</block>"
          )
        else
          Kernai.logger.error(event: 'builtin.execute', command: command_name, error: 'unknown')
          rec&.record(step: step, event: :builtin_error, data: { command: command_name, error: 'unknown' })

          Message.new(
            role: :user,
            content: "<block type=\"error\" name=\"#{command_name}\">Unknown command '#{command_name}'</block>"
          )
        end
      end

      def execute_skill(skill_name, content, rec, step, callback)
        skill = Skill.find(skill_name)

        unless skill
          Kernai.logger.error(event: 'skill.execute', skill: skill_name, error: 'not found')
          rec&.record(step: step, event: :skill_error, data: { skill: skill_name, error: 'not found' })
          callback&.call(Event.new(:skill_error, { skill: skill_name, error: "Skill '#{skill_name}' not found" }))
          return Message.new(
            role: :user,
            content: "<block type=\"error\" name=\"#{skill_name}\">Skill '#{skill_name}' not found</block>"
          )
        end

        if Kernai.config.allowed_skills && !Kernai.config.allowed_skills.include?(skill_name)
          Kernai.logger.error(event: 'skill.execute', skill: skill_name, error: 'not allowed')
          rec&.record(step: step, event: :skill_error, data: { skill: skill_name, error: 'not allowed' })
          callback&.call(Event.new(:skill_error, { skill: skill_name, error: "Skill '#{skill_name}' is not allowed" }))
          return Message.new(
            role: :user,
            content: "<block type=\"error\" name=\"#{skill_name}\">Skill '#{skill_name}' is not allowed</block>"
          )
        end

        begin
          Kernai.logger.info(event: 'skill.execute', skill: skill_name)
          params = parse_command_params(content, skill)
          rec&.record(step: step, event: :skill_execute, data: { skill: skill_name, params: params })
          result = skill.call(params)
          Kernai.logger.info(event: 'skill.result', skill: skill_name)
          rec&.record(step: step, event: :skill_result, data: { skill: skill_name, result: result })
          callback&.call(Event.new(:skill_result, { skill: skill_name, result: result }))

          Message.new(
            role: :user,
            content: "<block type=\"result\" name=\"#{skill_name}\">#{result}</block>"
          )
        rescue StandardError => e
          Kernai.logger.error(event: 'skill.execute', skill: skill_name, error: e.message)
          rec&.record(step: step, event: :skill_error, data: { skill: skill_name, error: e.message })
          callback&.call(Event.new(:skill_error, { skill: skill_name, error: e.message }))

          Message.new(
            role: :user,
            content: "<block type=\"error\" name=\"#{skill_name}\">#{e.message}</block>"
          )
        end
      end

      def parse_command_params(content, skill)
        content = content.strip

        begin
          parsed = JSON.parse(content)
          return parsed.transform_keys(&:to_sym) if parsed.is_a?(Hash)
        rescue JSON::ParserError
          # Not JSON
        end

        # Map to first input if skill has exactly one
        if skill.inputs.size == 1
          input_name = skill.inputs.keys.first
          return { input_name => content }
        end

        { input: content }
      end
    end
  end
end
