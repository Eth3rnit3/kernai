module Kernai
  class Block
    TYPES = %i[command json final plan result error].freeze

    attr_reader :type, :name, :content

    def initialize(type:, content:, name: nil)
      @type = type.to_sym
      @name = name
      @content = content
    end

    class << self
      def define(type, &handler)
        handlers[type.to_sym] = handler
      end

      def handler_for(type)
        handlers[type.to_sym]
      end

      def reset_handlers!
        @handlers = {}
      end

      private

      def handlers
        @handlers ||= {}
      end
    end
  end
end
