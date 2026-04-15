# frozen_string_literal: true

module Kernai
  class Skill
    attr_reader :name, :description_text, :inputs, :execute_block, :required_capabilities, :produced_kinds,
                :configs, :credentials

    class << self
      def define(name, &block)
        skill = new(name)
        skill.instance_eval(&block)
        register(skill)
        skill
      end

      def register(skill)
        @mutex.synchronize { registry[skill.name] = skill }
      end

      def find(name)
        @mutex.synchronize { registry[name.to_sym] }
      end

      def all
        @mutex.synchronize { registry.values }
      end

      def listing(scope = :all, model: nil)
        skills = case scope
                 when nil then []
                 when :all then all
                 when Array then scope.filter_map { |n| find(n) }
                 else []
                 end

        skills = skills.select { |s| Kernai.config.allowed_skills.include?(s.name) } if Kernai.config.allowed_skills
        skills = skills.select { |s| s.runnable_on?(model) } if model

        return 'No skills available.' if skills.empty?

        skills.map(&:to_description).join("\n")
      end

      def unregister(name)
        @mutex.synchronize { registry.delete(name.to_sym) }
      end

      def reset!
        @mutex.synchronize { @registry = {} }
      end

      def reload!
        reset!
        load_paths.each { |path| load_from(path) }
      end

      def load_from(pattern)
        @mutex.synchronize do
          @load_paths ||= []
          @load_paths << pattern unless @load_paths.include?(pattern)
        end
        Dir.glob(pattern).each { |file| load(file) }
      end

      private

      def registry
        @registry ||= {}
      end

      def load_paths
        @load_paths ||= []
      end
    end

    @mutex = Mutex.new

    def initialize(name)
      @name = name.to_sym
      @inputs = {}
      @configs = {}
      @credentials = {}
      @description_text = nil
      @execute_block = nil
      @required_capabilities = []
      @produced_kinds = []
    end

    def description(text)
      @description_text = text
    end

    def input(name, type, default: :__no_default__)
      @inputs[name] = { type: type, default: default }
    end

    # Declare a non-secret configuration value. Visible in the skill's
    # description (so the agent knows the knob exists) but its resolved
    # value is never included in any LLM-facing rendering — only the
    # execute block sees the value, via `ctx.config(:key)`.
    def config(name, type = String, default: nil, description: nil)
      @configs[name.to_sym] = { type: type, default: default, description: description }
    end

    # Declare a credential the skill needs. Credentials are *never*
    # rendered with their resolved values; only the declaration (name
    # + required flag) is visible. The execute block reads the value
    # via `ctx.credential(:key)`, which validates `required: true` at
    # access time.
    def credential(name, required: false, description: nil)
      @credentials[name.to_sym] = { required: required, description: description }
    end

    def execute(&block)
      @execute_block = block
    end

    # Declare the model capabilities the skill needs to be runnable. A
    # skill that consumes images in its prompt should `requires :vision`
    # so it stays hidden from text-only models. Multiple calls accumulate.
    def requires(*caps)
      @required_capabilities.concat(caps.flatten.map(&:to_sym))
    end

    # Declare the media kinds the skill may emit back into the conversation
    # (e.g. `produces :image` for an image-generation tool). Purely
    # informational for now — the kernel uses it to inform the instruction
    # builder, and future providers may route the result through an
    # appropriate output channel.
    def produces(*kinds)
      @produced_kinds.concat(kinds.flatten.map(&:to_sym))
    end

    # A skill is runnable on a given model when that model satisfies every
    # capability declared via `requires`. Skills with no requirements run
    # everywhere.
    def runnable_on?(model)
      return true if @required_capabilities.empty?

      model.supports?(*@required_capabilities)
    end

    def call(params = {})
      validated = validate_params(params)

      # Arity compat: legacy skills take `|params|` only. New skills
      # opt into `|params, ctx|` to reach credentials/config. We pass
      # the context only when the block can accept it.
      #   |p|        → arity 1  → legacy
      #   |p, c|     → arity 2  → new
      #   |p, *rest| → arity -2 → new (splat can absorb ctx)
      arity = @execute_block.arity
      if arity >= 2 || arity <= -2
        @execute_block.call(validated, SkillContext.new(self))
      else
        @execute_block.call(validated)
      end
    end

    def to_description
      parts = ["- #{@name}"]
      parts << ": #{@description_text}" if @description_text
      if @inputs.any?
        inputs_str = @inputs.map do |name, spec|
          str = "#{name} (#{spec[:type].name})"
          str += " default: #{spec[:default]}" unless spec[:default] == :__no_default__
          str
        end.join(', ')
        parts << "\n  Inputs: #{inputs_str}"
        parts << "\n  Usage: #{usage_example}"
      end
      if @configs.any?
        configs_str = @configs.map do |name, spec|
          str = "#{name} (#{spec[:type].name})"
          str += " default: #{spec[:default]}" unless spec[:default].nil?
          str
        end.join(', ')
        parts << "\n  Config: #{configs_str}"
      end
      # IMPORTANT: credentials never include resolved values in this
      # rendering. Declaring them here just signals to the agent that
      # the skill is backed by configured secrets (so it understands
      # why a CredentialMissingError might happen at runtime).
      if @credentials.any?
        creds_str = @credentials.map do |name, spec|
          spec[:required] ? "#{name} (required)" : name.to_s
        end.join(', ')
        parts << "\n  Credentials: #{creds_str}"
      end
      parts.join
    end

    private

    def usage_example
      if @inputs.size == 1
        input_name = @inputs.keys.first
        "<block type=\"command\" name=\"#{@name}\">#{input_name} value</block>"
      else
        json = @inputs.map { |k, _| "\"#{k}\": \"...\"" }.join(', ')
        "<block type=\"command\" name=\"#{@name}\">{#{json}}</block>"
      end
    end

    def validate_params(params)
      result = {}
      @inputs.each do |name, spec|
        if params.key?(name)
          value = params[name]
          unless value.is_a?(spec[:type])
            raise ArgumentError,
                  "Expected #{name} to be #{spec[:type]}, got #{value.class}.\n\n" \
                  "#{schema_hint(params)}"
          end

          result[name] = value
        elsif spec[:default] != :__no_default__
          result[name] = spec[:default]
        else
          raise ArgumentError,
                "Missing required input: #{name} for skill '#{@name}'.\n\n" \
                "#{schema_hint(params)}"
        end
      end
      result
    end

    # Builds a self-contained schema reminder included in every validation
    # error. The goal is to make the error self-correcting: when the agent
    # picks the wrong parameter shape (often pulled from training priors
    # like Aider/Cursor), the next turn sees exactly which params are
    # expected and how to call the skill, so it recovers in one retry.
    def schema_hint(received_params)
      expected = @inputs.keys.join(', ')
      received = received_params.respond_to?(:keys) ? received_params.keys.join(', ') : '(none)'
      <<~HINT.strip
        Got params:      #{received.empty? ? '(none)' : received}
        Expected params: #{expected}
        Usage:           #{usage_example}
      HINT
    end
  end
end
