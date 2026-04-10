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
      # The main agent loop. Cohesive by design: every branch of the
      # dispatch — workflow vs command vs protocol vs final vs
      # informational-only vs chatbot fallback — belongs here so the
      # execution contract is visible in one place. Splitting would
      # force the reader to chase state across multiple methods without
      # making the logic simpler.
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/BlockLength
      def run(agent, input, provider: nil, history: [], recorder: nil, context: nil, &callback)
        provider = resolve_provider(agent, provider)
        raise ProviderError, 'No provider configured' unless provider

        rec = recorder || Kernai.config.recorder
        ctx = context || Context.new

        # Any Media the caller passes directly in `input` is registered in
        # the store up front so sub-agents and skills can look it up by id
        # throughout the run.
        Array(input).grep(Media).each { |m| ctx.media_store.put(m) }

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
          protocol_blocks = blocks.select { |b| Protocol.registered?(b.type) }

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
          elsif command_blocks.any? || protocol_blocks.any?
            # Actionable blocks take priority over `final`: execute them in
            # the order the LLM emitted them so command/protocol interleaving
            # stays deterministic, then continue the loop so the model can
            # react to their results.
            actionable = (command_blocks + protocol_blocks).sort_by { |b| blocks.index(b) }
            actionable.each do |block|
              result_msg = if command_blocks.include?(block)
                             execute_command(block, agent, ctx, rec, step, callback)
                           else
                             execute_protocol(block, agent, ctx, rec, step, callback)
                           end
              messages << result_msg
            end
          elsif final_block
            result = final_block.content
            Kernai.logger.info(event: 'agent.complete', steps: step + 1)
            record(rec, ctx, step: step, event: :result, data: result)
            callback&.call(Event.new(:final, result))
            break
          elsif informational_only?(blocks)
            # The agent emitted <plan> and/or <json> but nothing actionable
            # and no <final>. By the declared semantics of those blocks
            # (reasoning/side-channel, not terminal) the turn is NOT over:
            # small models often split "think" and "act" across turns. We
            # inject a corrective feedback and let the loop run another
            # step so the agent can follow up with an actual action.
            messages << handle_informational_only(blocks, rec, ctx, step, callback)
          else
            # Truly no blocks — the agent replied with plain prose. Treat
            # that as a chatbot-style final answer and return it as-is.
            result = llm_response.content
            record(rec, ctx, step: step, event: :result, data: result)
            break
          end
        end

        raise MaxStepsReachedError, "Agent reached maximum steps (#{agent.max_steps})" if result.nil?

        result
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/BlockLength

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

      # --- Informational-only turn handling ---

      # True when the parsed blocks contain at least one informational
      # block (plan / json) and no actionable or terminal block. Used to
      # detect the "agent is thinking but hasn't acted yet" state so the
      # loop can continue instead of prematurely terminating.
      def informational_only?(blocks)
        return false if blocks.empty?

        informational = blocks.any? { |b| %i[plan json].include?(b.type) }
        return false unless informational

        blocks.none? do |b|
          b.type == :final ||
            b.type == :command ||
            Protocol.registered?(b.type)
        end
      end

      def handle_informational_only(blocks, rec, ctx, step, callback)
        kinds = blocks.map(&:type).uniq
        Kernai.logger.info(event: 'agent.informational_only', kinds: kinds.join(','))
        record(rec, ctx, step: step, event: :informational_only,
                         data: { kinds: kinds.map(&:to_s) })
        callback&.call(Event.new(:informational_only, { kinds: kinds }))

        Message.new(
          role: :user,
          content: '<block type="error">You emitted only informational blocks ' \
                   "(#{kinds.map(&:to_s).join(', ')}) but nothing actionable. " \
                   'To make progress you must ALSO emit, in the same response, ' \
                   'at least one of: <block type="command" name="..."> to call ' \
                   'a skill, a protocol block such as <block type="mcp"> to call ' \
                   'an external system, or <block type="final"> to end the turn. ' \
                   'Reason with <plan> AND act in the same response — do not ' \
                   'split thinking and action across turns.</block>'
        )
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

      # The returned lambda is a self-contained task runner: spawn a
      # sub-agent, wire its context, emit start/complete/error events
      # with the scope inherited from the scheduler's context. All four
      # observability touches (log, record, callback, duration) live in
      # the same block on purpose.
      def build_task_runner(agent, provider, rec, callback)
        lambda do |task, sched_context| # rubocop:disable Metrics/BlockLength
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

      # Sub-agents inherit the parent's full max_steps budget. Previously
      # we silently halved it, which made the same workflow succeed on a
      # terse model and fail on a verbose one: small models spend their
      # first 2-3 steps re-doing discovery (/skills, /protocols) before
      # they can even start tooling, and the halved budget left them with
      # no room to emit a final block after the actual work. Full
      # inheritance is the simpler, more predictable contract: "a sub-agent
      # has the same per-agent budget as its parent". The overall workflow
      # cost is still bounded by (number_of_tasks * parent.max_steps).
      def build_sub_agent(parent)
        Agent.new(
          instructions: parent.instructions,
          provider: parent.provider,
          model: parent.model,
          max_steps: parent.max_steps,
          skills: parent.skills,
          protocols: parent.protocols
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
          builtin_result(command_name, Skill.listing(agent.skills, model: agent.model), rec, ctx, step, callback)
        when '/workflow'
          builtin_result(command_name, WORKFLOW_DOCUMENTATION, rec, ctx, step, callback)
        when '/tasks'
          payload = JSON.generate(tasks_snapshot(ctx))
          builtin_result(command_name, payload, rec, ctx, step, callback)
        when '/protocols'
          payload = JSON.generate(protocols_snapshot(agent))
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

      # --- Protocol execution ---

      # The length of this method is intentional: every observability
      # path (logger, recorder, streaming callback) must be covered for
      # the not-allowed / missing-handler / success / error branches,
      # and that flow is clearer as one linear sequence than split
      # across half a dozen helpers that would obscure the invariants.
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def execute_protocol(block, agent, ctx, rec, step, callback)
        protocol_name = block.type

        if agent.protocols && !agent.protocols.map(&:to_sym).include?(protocol_name)
          Kernai.logger.error(event: 'protocol.execute', protocol: protocol_name, error: 'not allowed')
          record(rec, ctx, step: step, event: :protocol_error,
                           data: { protocol: protocol_name, error: 'not allowed' })
          callback&.call(Event.new(:protocol_error,
                                   { protocol: protocol_name,
                                     error: "Protocol '#{protocol_name}' is not allowed" }))
          return Message.new(
            role: :user,
            content: "<block type=\"error\" name=\"#{protocol_name}\">" \
                     "Protocol '#{protocol_name}' is not allowed</block>"
          )
        end

        handler = Protocol.handler_for(protocol_name)
        # Defensive: should never happen — the dispatcher only reaches here
        # when Protocol.registered? returned true just a few lines above.
        unless handler
          Kernai.logger.error(event: 'protocol.execute', protocol: protocol_name, error: 'handler missing')
          record(rec, ctx, step: step, event: :protocol_error,
                           data: { protocol: protocol_name, error: 'handler missing' })
          callback&.call(Event.new(:protocol_error,
                                   { protocol: protocol_name, error: 'handler missing' }))
          return Message.new(
            role: :user,
            content: "<block type=\"error\" name=\"#{protocol_name}\">" \
                     "Protocol '#{protocol_name}' has no handler</block>"
          )
        end

        Kernai.logger.info(event: 'protocol.execute', protocol: protocol_name)
        record(rec, ctx, step: step, event: :protocol_execute,
                         data: { protocol: protocol_name, request: block.content })
        callback&.call(Event.new(:protocol_execute,
                                 { protocol: protocol_name, request: block.content }))

        started = monotonic_ms
        begin
          result = handler.call(block, ctx)
          duration_ms = monotonic_ms - started

          Kernai.logger.info(event: 'protocol.result', protocol: protocol_name, duration_ms: duration_ms)
          record(rec, ctx, step: step, event: :protocol_result,
                           data: { protocol: protocol_name, result: result, duration_ms: duration_ms })
          callback&.call(Event.new(:protocol_result,
                                   { protocol: protocol_name, result: result, duration_ms: duration_ms }))

          normalize_protocol_result(protocol_name, result)
        rescue StandardError => e
          duration_ms = monotonic_ms - started
          Kernai.logger.error(event: 'protocol.execute', protocol: protocol_name, error: e.message)
          record(rec, ctx, step: step, event: :protocol_error,
                           data: { protocol: protocol_name, error: e.message, duration_ms: duration_ms })
          callback&.call(Event.new(:protocol_error,
                                   { protocol: protocol_name, error: e.message, duration_ms: duration_ms }))

          Message.new(
            role: :user,
            content: "<block type=\"error\" name=\"#{protocol_name}\">#{e.message}</block>"
          )
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      # A protocol handler may return:
      #   - a String  → wrapped by the kernel as <block type="result" name="...">
      #   - a Message → used as-is (handler controls role + content entirely)
      # This two-form contract is intentionally minimal and forward compatible:
      # richer return types can be introduced later without breaking existing
      # handlers.
      def normalize_protocol_result(protocol_name, result)
        return result if result.is_a?(Message)

        Message.new(
          role: :user,
          content: "<block type=\"result\" name=\"#{protocol_name}\">#{result}</block>"
        )
      end

      def protocols_snapshot(agent)
        scope = agent.protocols&.map(&:to_sym)
        Protocol.all.filter_map do |reg|
          next if scope && !scope.include?(reg.name)

          { name: reg.name.to_s, documentation: reg.documentation }
        end
      end

      # Mirrors execute_protocol: the length tracks the number of
      # observability channels we must touch for every branch, not
      # complexity of the logic itself. Splitting these branches into
      # helpers would obscure the invariant "every path emits log +
      # recorder + callback in the same shape".
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
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
          raw = skill.call(params)
          parts = SkillResult.wrap(raw, ctx.media_store)
          duration_ms = monotonic_ms - started

          Kernai.logger.info(event: 'skill.result', skill: skill_name)
          record(rec, ctx, step: step, event: :skill_result,
                           data: { skill: skill_name, result: raw, duration_ms: duration_ms })
          callback&.call(Event.new(:skill_result, { skill: skill_name, result: raw }))

          Message.new(role: :user, content: wrap_result_block(skill_name, parts))
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
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      # Build the content array for a skill <result> message. Text parts
      # are concatenated inside a single <block type="result"> wrapper;
      # Media parts are spliced in as their own <block type="media"/>
      # references so the next provider call can encode them natively.
      def wrap_result_block(skill_name, parts)
        text_parts = parts.grep(String)
        media_parts = parts.grep(Media)

        opening = "<block type=\"result\" name=\"#{skill_name}\">"
        closing = '</block>'

        content = []
        content << "#{opening}#{text_parts.join}#{closing}"
        media_parts.each do |media|
          content << "<block type=\"media\" id=\"#{media.id}\" kind=\"#{media.kind}\" mime=\"#{media.mime_type}\"/>"
          content << media
        end
        content
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
