# frozen_string_literal: true

module Kernai
  class Skill
    attr_reader :name, :description_text, :inputs, :execute_block

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

      def listing(scope = :all)
        skills = case scope
                 when nil then []
                 when :all then all
                 when Array then scope.filter_map { |n| find(n) }
                 else []
                 end

        skills = skills.select { |s| Kernai.config.allowed_skills.include?(s.name) } if Kernai.config.allowed_skills

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
      @description_text = nil
      @execute_block = nil
    end

    def description(text)
      @description_text = text
    end

    def input(name, type, default: :__no_default__)
      @inputs[name] = { type: type, default: default }
    end

    def execute(&block)
      @execute_block = block
    end

    def call(params = {})
      validated = validate_params(params)
      @execute_block.call(validated)
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
            raise ArgumentError, "Expected #{name} to be #{spec[:type]}, got #{value.class}"
          end

          result[name] = value
        elsif spec[:default] != :__no_default__
          result[name] = spec[:default]
        else
          raise ArgumentError, "Missing required input: #{name}"
        end
      end
      result
    end
  end
end
