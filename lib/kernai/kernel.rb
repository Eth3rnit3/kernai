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
    WORKFLOW_DOCUMENTATION = <<~DOC
      Structured workflow plans

      Emit <block type="plan"> containing JSON:
      {
        "goal": "string",
        "strategy": "parallel | sequential | mixed",
        "tasks": [
          {
            "id": "string (required, unique)",
            "input": "string (required, the sub-agent prompt)",
            "parallel": true | false,
            "depends_on": ["other_task_id", "..."]
          }
        ]
      }

      Rules:
      - Each task runs as an isolated sub-agent inheriting provider, model and skills.
      - Tasks with parallel=true run concurrently; others run sequentially.
      - A task waits for every id listed in depends_on to finish first.
      - Sub-agents cannot themselves create nested structured plans.
      - Invalid plans are ignored (fail-safe).

      Results are injected back as:
      <block type="result" name="tasks">{"task_id": "result", ...}</block>

      Use /tasks to inspect current state.
    DOC

    class << self
      def run(agent, input, provider: nil, history: [], recorder: nil, context: nil, &callback)
        provider = resolve_provider(agent, provider)
        raise ProviderError, 'No provider configured' unless provider

        rec = recorder || Kernai.config.recorder
        ctx = context || Context.new

        messages = [
          Message.new(role: :system, content: agent.resolve_instructions(workflow_enabled: ctx.root?)),
          *history.map { |m| Message.new(role: m[:role], content: m[:content]) },
          Message.new(role: :user, content: input)
        ]

        result = nil

        agent.max_steps.times do |step|
          # Hot reload: update system message each step
          messages[0] = Message.new(
            role: :system,
            content: agent.resolve_instructions(workflow_enabled: ctx.root?)
          )

          stream_parser = StreamParser.new
          blocks = []

          setup_stream_callbacks(stream_parser, blocks, callback)

          Kernai.logger.debug(event: 'llm.request', step: step + 1, model: agent.model)

          record(rec, ctx, step: step, event: :messages_sent, data: messages.map(&:to_h))

          llm_response = provider.call(
            messages: messages.map(&:to_h),
            model: agent.model
          ) { |chunk| stream_parser.push(chunk) }

          stream_parser.flush

          Kernai.logger.debug(event: 'llm.response', step: step + 1)

          record(rec, ctx, step: step, event: :llm_response, data: llm_response.to_h)

          messages << Message.new(role: :assistant, content: llm_response.content)

          final_block = blocks.find { |b| b.type == :final }
          command_blocks = blocks.select { |b| b.type == :command }
          plan_blocks = blocks.select { |b| b.type == :plan }

          record(rec, ctx, step: step, event: :blocks_parsed, data: blocks.map(&:to_h))

          workflow_plan, consumed_plan_block = detect_workflow_plan(plan_blocks, ctx, rec, step)

          emit_informational_blocks(blocks, consumed_plan_block, step, rec, ctx, callback)

          if workflow_plan
            messages << execute_workflow(
              workflow_plan,
              agent: agent,
              provider: provider,
              ctx: ctx,
              rec: rec,
              step: step,
              callback: callback
            )
          elsif command_blocks.any?
            # Commands take priority: execute them and continue the loop
            # even if the LLM also sent a final block (it needs to see results first)
            command_blocks.each do |block|
              result_msg = execute_command(block, agent, ctx, rec, step, callback)
              messages << result_msg
            end
          elsif final_block
            result = final_block.content
            Kernai.logger.info(event: 'agent.complete', steps: step + 1)
            record(rec, ctx, step: step, event: :result, data: result)
            callback&.call(Event.new(:final, result))
            break
          else
            # No blocks or only informational blocks — treat raw response as result
            result = llm_response.content
            record(rec, ctx, step: step, event: :result, data: result)
            break
          end
        end

        raise MaxStepsReachedError, "Agent reached maximum steps (#{agent.max_steps})" if result.nil?

        result
      end

      private

      # Thin wrapper around Recorder#record that always stamps the current
      # execution scope. Every event in the kernel goes through this, so we
      # never forget to attach depth/task_id.
      def record(rec, ctx, step:, event:, data:)
        rec&.record(step: step, event: event, data: data, scope: ctx.recorder_scope)
      end

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

      # --- Plan / workflow handling ---

      # Returns [plan, consumed_block] or [nil, nil]. Emits a structured
      # :plan_rejected event for every plan block that failed validation
      # (except sub-agent attempts, which are rejected with the reason
      # :nested and only observed at depth > 0).
      def detect_workflow_plan(plan_blocks, ctx, rec, step)
        if ctx.root?
          plan_blocks.each do |block|
            result = Plan.validate(block.content)
            return [result.plan, block] if result.ok?

            record(rec, ctx, step: step, event: :plan_rejected,
                             data: { reason: result.reason.to_s, raw: block.content })
          end
        else
          plan_blocks.each do |block|
            record(rec, ctx, step: step, event: :plan_rejected,
                             data: { reason: 'nested', raw: block.content })
          end
        end

        [nil, nil]
      end

      def emit_informational_blocks(blocks, consumed_plan_block, step, rec, ctx, callback)
        blocks.each do |block|
          case block.type
          when :plan
            # Skip the block that was consumed as a workflow plan — the
            # scheduler owns its lifecycle from here on.
            next if block.equal?(consumed_plan_block)

            Kernai.logger.debug(event: 'block.complete', type: :plan)
            record(rec, ctx, step: step, event: :plan, data: block.content)
            callback&.call(Event.new(:plan, block.content))
          when :json
            Kernai.logger.debug(event: 'block.complete', type: :json)
            record(rec, ctx, step: step, event: :json, data: block.content)
            callback&.call(Event.new(:json, block.content))
          end
        end
      end

      def execute_workflow(plan, agent:, provider:, ctx:, rec:, step:, callback:)
        ctx.hydrate_from_plan(plan)

        Kernai.logger.info(event: 'workflow.start', tasks: plan.tasks.size)
        started = monotonic_ms
        record(rec, ctx, step: step, event: :workflow_start, data: plan.to_h)
        callback&.call(Event.new(:workflow_start, plan.to_h))

        runner = build_task_runner(agent, provider, rec, callback)
        scheduler = TaskScheduler.new(ctx, runner)

        begin
          scheduler.run
        rescue TaskScheduler::DeadlockError => e
          Kernai.logger.error(event: 'workflow.deadlock', error: e.message)
          record(rec, ctx, step: step, event: :workflow_error,
                           data: { error: e.message, duration_ms: monotonic_ms - started })
          return Message.new(
            role: :user,
            content: "<block type=\"error\" name=\"tasks\">#{e.message}</block>"
          )
        end

        duration_ms = monotonic_ms - started
        Kernai.logger.info(event: 'workflow.complete', tasks: ctx.task_results.size)
        record(rec, ctx, step: step, event: :workflow_complete,
                         data: { results: ctx.task_results, duration_ms: duration_ms })
        callback&.call(Event.new(:workflow_complete, ctx.task_results))

        Message.new(
          role: :user,
          content: "<block type=\"result\" name=\"tasks\">#{JSON.generate(ctx.task_results)}</block>"
        )
      end

      def build_task_runner(agent, provider, rec, callback)
        lambda do |task, sched_context|
          sub_agent = build_sub_agent(agent)
          sub_context = sched_context.spawn_child
          sub_context.current_task_id = task.id
          sub_input = build_task_input(task, sched_context)

          started = monotonic_ms
          record(rec, sched_context, step: 0, event: :task_start,
                                     data: { task_id: task.id, input: task.input, depends_on: task.depends_on })
          callback&.call(Event.new(:task_start, { id: task.id, input: task.input }))

          begin
            result = Kernel.run(
              sub_agent,
              sub_input,
              provider: provider,
              context: sub_context,
              recorder: rec,
              &callback
            )
            record(rec, sched_context, step: 0, event: :task_complete,
                                       data: { task_id: task.id, result: result, duration_ms: monotonic_ms - started })
            callback&.call(Event.new(:task_complete, { id: task.id, result: result }))
            result
          rescue StandardError => e
            error_data = { task_id: task.id, error: e.message, duration_ms: monotonic_ms - started }
            record(rec, sched_context, step: 0, event: :task_error, data: error_data)
            callback&.call(Event.new(:task_error, { id: task.id, error: e.message }))
            "error: #{e.message}"
          end
        end
      end

      def build_sub_agent(parent)
        sub_max = [parent.max_steps / 2, 3].max
        Agent.new(
          instructions: parent.instructions,
          provider: parent.provider,
          model: parent.model,
          max_steps: sub_max,
          skills: parent.skills
        )
      end

      def build_task_input(task, ctx)
        return task.input if task.depends_on.empty?

        dep_blocks = task.depends_on.map do |dep_id|
          value = ctx.task_results[dep_id.to_s]
          "<block type=\"result\" name=\"#{dep_id}\">#{value}</block>"
        end.join("\n")

        "#{dep_blocks}\n\n#{task.input}"
      end

      # --- Command execution ---

      def execute_command(block, agent, ctx, rec, step, callback)
        command_name = block.name&.strip

        unless command_name
          Kernai.logger.error(event: 'skill.execute', error: 'no skill name in command block')
          record(rec, ctx, step: step, event: :skill_error,
                           data: { skill: nil, error: 'no skill name in command block' })
          return Message.new(
            role: :user,
            content: '<block type="error">Command block missing skill name</block>'
          )
        end

        # Built-in commands (prefixed with /)
        return execute_builtin(command_name, agent, ctx, rec, step, callback) if command_name.start_with?('/')

        execute_skill(command_name.to_sym, block.content, rec, ctx, step, callback)
      end

      def execute_builtin(command_name, agent, ctx, rec, step, callback)
        case command_name
        when '/skills'
          builtin_result(command_name, Skill.listing(agent.skills), rec, ctx, step, callback)
        when '/workflow'
          builtin_result(command_name, WORKFLOW_DOCUMENTATION, rec, ctx, step, callback)
        when '/tasks'
          payload = JSON.generate(tasks_snapshot(ctx))
          builtin_result(command_name, payload, rec, ctx, step, callback)
        else
          Kernai.logger.error(event: 'builtin.execute', command: command_name, error: 'unknown')
          record(rec, ctx, step: step, event: :builtin_error,
                           data: { command: command_name, error: 'unknown' })

          Message.new(
            role: :user,
            content: "<block type=\"error\" name=\"#{command_name}\">Unknown command '#{command_name}'</block>"
          )
        end
      end

      def builtin_result(command_name, payload, rec, ctx, step, callback)
        Kernai.logger.info(event: 'builtin.execute', command: command_name)
        record(rec, ctx, step: step, event: :builtin_result,
                         data: { command: command_name, result: payload })
        callback&.call(Event.new(:builtin_result, { command: command_name, result: payload }))

        Message.new(
          role: :user,
          content: "<block type=\"result\" name=\"#{command_name}\">#{payload}</block>"
        )
      end

      def tasks_snapshot(ctx)
        {
          depth: ctx.depth,
          goal: ctx.plan&.goal,
          strategy: ctx.plan&.strategy,
          tasks: ctx.tasks.map(&:to_h),
          task_results: ctx.task_results
        }
      end

      def execute_skill(skill_name, content, rec, ctx, step, callback)
        skill = Skill.find(skill_name)

        unless skill
          Kernai.logger.error(event: 'skill.execute', skill: skill_name, error: 'not found')
          record(rec, ctx, step: step, event: :skill_error,
                           data: { skill: skill_name, error: 'not found' })
          callback&.call(Event.new(:skill_error, { skill: skill_name, error: "Skill '#{skill_name}' not found" }))
          return Message.new(
            role: :user,
            content: "<block type=\"error\" name=\"#{skill_name}\">Skill '#{skill_name}' not found</block>"
          )
        end

        if Kernai.config.allowed_skills && !Kernai.config.allowed_skills.include?(skill_name)
          Kernai.logger.error(event: 'skill.execute', skill: skill_name, error: 'not allowed')
          record(rec, ctx, step: step, event: :skill_error,
                           data: { skill: skill_name, error: 'not allowed' })
          callback&.call(Event.new(:skill_error, { skill: skill_name, error: "Skill '#{skill_name}' is not allowed" }))
          return Message.new(
            role: :user,
            content: "<block type=\"error\" name=\"#{skill_name}\">Skill '#{skill_name}' is not allowed</block>"
          )
        end

        begin
          Kernai.logger.info(event: 'skill.execute', skill: skill_name)
          params = parse_command_params(content, skill)
          record(rec, ctx, step: step, event: :skill_execute, data: { skill: skill_name, params: params })

          started = monotonic_ms
          result = skill.call(params)
          duration_ms = monotonic_ms - started

          Kernai.logger.info(event: 'skill.result', skill: skill_name)
          record(rec, ctx, step: step, event: :skill_result,
                           data: { skill: skill_name, result: result, duration_ms: duration_ms })
          callback&.call(Event.new(:skill_result, { skill: skill_name, result: result }))

          Message.new(
            role: :user,
            content: "<block type=\"result\" name=\"#{skill_name}\">#{result}</block>"
          )
        rescue StandardError => e
          Kernai.logger.error(event: 'skill.execute', skill: skill_name, error: e.message)
          record(rec, ctx, step: step, event: :skill_error, data: { skill: skill_name, error: e.message })
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

      def monotonic_ms
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
      end
    end
  end
end
