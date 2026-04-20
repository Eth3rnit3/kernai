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

    NO_DEFAULT = :__no_default__

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

    # Declare an input.
    #
    # Type grammar:
    #   Class                        → value.is_a?(Class)
    #   [Class, Class, ...]          → union; value.is_a?(any of the classes)
    #   Array, of: ELEM              → array where every element matches ELEM
    #   Hash,  schema: { ... }       → object with the given per-key typing
    #
    # `ELEM` and `schema` entries share a grammar:
    #   Class                        → required scalar of that class
    #   [Class, Class]               → required union scalar
    #   Hash (shorthand schema)      → required nested object (Hash {...})
    #   { type:, default:, of:, schema: }   → full spec hash
    def input(name, type, default: NO_DEFAULT, of: nil, schema: nil)
      raise ArgumentError, "Invalid input spec for :#{name} — `of:` requires type Array" if of && type != Array

      if schema && type != Hash
        raise ArgumentError,
              "Invalid input spec for :#{name} — `schema:` requires type Hash"
      end
      raise ArgumentError, "Invalid input spec for :#{name} — unsupported type #{type.inspect}" unless valid_type?(type)
      raise ArgumentError, "Invalid element spec for :#{name} — #{of.inspect}" if of && !valid_element_spec?(of)

      spec = { type: type, default: default }
      spec[:of] = of if of
      spec[:schema] = schema if schema
      @inputs[name] = spec
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

    # Invoke the skill with a positional params hash or keyword args.
    # Callers that need to surface the per-run Kernai::Context (e.g.
    # the kernel itself) should use `call_in_context` instead.
    def call(params = {})
      call_in_context(params, run_context: nil)
    end

    # Same as #call but forwards a run_context to the SkillContext so
    # the skill's execute block can reach `ctx.run_context` (the host
    # application's per-run state: current actor, ticket, request id,
    # whatever the host subclassed Kernai::Context to carry).
    def call_in_context(params, run_context:)
      validated = validate_params(params)

      # Arity compat: legacy skills take `|params|` only. New skills
      # opt into `|params, ctx|` to reach credentials/config AND the
      # host's per-run Context (via `ctx.run_context`). We pass the
      # context only when the block can accept it.
      #   |p|        → arity 1  → legacy
      #   |p, c|     → arity 2  → new
      #   |p, *rest| → arity -2 → new (splat can absorb ctx)
      arity = @execute_block.arity
      if arity >= 2 || arity <= -2
        @execute_block.call(validated, SkillContext.new(self, run_context: run_context))
      else
        @execute_block.call(validated)
      end
    end

    def to_description
      parts = ["- #{@name}"]
      parts << ": #{@description_text}" if @description_text
      if @inputs.any?
        parts << "\n  Inputs: #{render_inputs_summary}"
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

    # --- DSL-time spec validation ---

    def valid_type?(type)
      return true if type.is_a?(Class)
      return true if type.is_a?(Array) && type.any? && type.all? { |t| t.is_a?(Class) }

      false
    end

    def valid_element_spec?(spec)
      case spec
      when Class then true
      when Array then spec.any? && spec.all? { |t| t.is_a?(Class) }
      when Hash  then true
      else false
      end
    end

    # --- Validation / coercion ---

    def validate_params(params)
      normalized = symbolize_top_level(params)
      result = {}
      @inputs.each do |name, spec|
        if normalized.key?(name)
          result[name] = validate_value(normalized[name], spec, path: name.to_s, received: params)
        elsif spec[:default] != NO_DEFAULT
          result[name] = spec[:default]
        else
          raise ArgumentError,
                "Missing required input: #{name} for skill '#{@name}'.\n\n" \
                "#{schema_hint(params)}"
        end
      end
      result
    end

    def validate_value(value, spec, path:, received: nil)
      type = spec[:type]

      unless type_matches?(value, type)
        raise ArgumentError,
              "Expected #{path} to be #{format_type(type)}, got #{value.class}.\n\n" \
              "#{schema_hint(received || {})}"
      end

      return validate_array(value, spec[:of], path: path, received: received) if type == Array && spec[:of]
      return validate_hash(value, spec[:schema], path: path, received: received) if type == Hash && spec[:schema]

      value
    end

    def type_matches?(value, type)
      return type.any? { |t| value.is_a?(t) } if type.is_a?(Array)

      value.is_a?(type)
    end

    def format_type(type)
      return type.map { |t| type_name(t) }.join(' or ') if type.is_a?(Array)

      type_name(type)
    end

    def validate_array(array, element_spec, path:, received:)
      normalized = normalize_element_spec(element_spec)
      array.each_with_index.map do |elem, idx|
        validate_value(elem, normalized, path: "#{path}[#{idx}]", received: received)
      end
    end

    def validate_hash(hash, schema, path:, received:)
      normalized_hash = symbolize_top_level(hash)
      result = {}
      schema.each do |key, entry|
        entry_spec = normalize_schema_entry(entry)
        sub_path = "#{path}.#{key}"
        if normalized_hash.key?(key.to_sym)
          result[key.to_sym] = validate_value(normalized_hash[key.to_sym], entry_spec,
                                              path: sub_path, received: received)
        elsif entry_spec[:default] != NO_DEFAULT
          result[key.to_sym] = entry_spec[:default]
        else
          raise ArgumentError, "Missing required input: #{sub_path} for skill '#{@name}'."
        end
      end
      result
    end

    # Shorthand forms accepted as element_spec:
    #   Class                  → scalar of Class
    #   [Class, Class, ...]    → union scalar
    #   Hash without :type     → nested schema (type inferred to Hash)
    #   Hash with :type        → full spec hash
    def normalize_element_spec(element_spec)
      case element_spec
      when Class, Array
        { type: element_spec, default: NO_DEFAULT, of: nil, schema: nil }
      when Hash
        if spec_hash?(element_spec)
          normalize_schema_entry(element_spec)
        else
          { type: Hash, default: NO_DEFAULT, of: nil, schema: element_spec }
        end
      else
        raise ArgumentError, "Invalid element spec: #{element_spec.inspect}"
      end
    end

    def normalize_schema_entry(entry)
      case entry
      when Class, Array
        { type: entry, default: NO_DEFAULT, of: nil, schema: nil }
      when Hash
        if spec_hash?(entry)
          keyed = entry.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
          {
            type: keyed[:type],
            default: keyed.fetch(:default, NO_DEFAULT),
            of: keyed[:of],
            schema: keyed[:schema]
          }
        else
          { type: Hash, default: NO_DEFAULT, of: nil, schema: entry }
        end
      else
        raise ArgumentError, "Invalid schema entry: #{entry.inspect}"
      end
    end

    # A "spec hash" carries a `:type` key (symbol or string). Without one,
    # a Hash passed as an element_spec or schema entry is interpreted as a
    # nested schema (shorthand).
    def spec_hash?(hash)
      hash.key?(:type) || hash.key?('type')
    end

    def symbolize_top_level(hash)
      return {} if hash.nil?

      hash.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
    end

    # --- Description rendering ---

    def render_inputs_summary
      @inputs.map { |name, spec| render_input_entry(name, spec) }.join(', ')
    end

    def render_input_entry(name, spec)
      str = "#{name} (#{render_type(spec)})"
      str += " default: #{spec[:default]}" if spec[:default] != NO_DEFAULT
      str
    end

    def render_type(spec)
      type = spec[:type]

      if type == Array && spec[:of]
        "Array<#{render_element_type(spec[:of])}>"
      elsif type == Hash && spec[:schema]
        "Hash{#{render_schema_keys(spec[:schema])}}"
      elsif type.is_a?(Array)
        type.map { |t| type_name(t) }.join('|')
      else
        type_name(type)
      end
    end

    def render_element_type(element_spec)
      case element_spec
      when Class then type_name(element_spec)
      when Array then element_spec.map { |t| type_name(t) }.join('|')
      when Hash
        if spec_hash?(element_spec)
          render_type(normalize_schema_entry(element_spec))
        else
          "Hash{#{render_schema_keys(element_spec)}}"
        end
      end
    end

    def render_schema_keys(schema)
      schema.map { |k, v| "#{k}: #{render_type(normalize_schema_entry(v))}" }.join(', ')
    end

    def type_name(type)
      type.name || type.to_s
    end

    def usage_example
      if @inputs.size == 1
        input_name = @inputs.keys.first
        "<block type=\"command\" name=\"#{@name}\">#{input_name} value</block>"
      else
        json = @inputs.map { |k, _| "\"#{k}\": \"...\"" }.join(', ')
        "<block type=\"command\" name=\"#{@name}\">{#{json}}</block>"
      end
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
