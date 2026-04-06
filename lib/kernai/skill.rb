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

    private

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
