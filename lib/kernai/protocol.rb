# frozen_string_literal: true

module Kernai
  # Registry of external protocols an agent can address directly via block
  # types. A protocol is any structured, extensible interface (MCP, A2A,
  # custom in-house systems, ...) that doesn't fit the "local Ruby skill"
  # model: each registered protocol claims a block type, and the Kernel
  # dispatches matching blocks to its handler.
  #
  # Conceptually: `command` invokes a Skill, `<protocol_name>` invokes a
  # Protocol. Both return their payload in <block type="result" name="...">.
  # Kernai itself knows nothing about any specific protocol — adapters
  # register themselves from outside the core.
  module Protocol
    Registration = Struct.new(:name, :documentation, :handler, keyword_init: true)

    # Block types owned by the kernel's own protocol. Registrations cannot
    # shadow them, otherwise the dispatcher would become ambiguous.
    CORE_BLOCK_TYPES = %i[command final plan json result error].freeze

    class << self
      def register(name, documentation: nil, &handler)
        raise ArgumentError, 'protocol name is required' if name.nil? || name.to_s.strip.empty?
        raise ArgumentError, 'protocol handler block is required' unless block_given?

        sym = name.to_sym
        if CORE_BLOCK_TYPES.include?(sym)
          raise ArgumentError, "cannot register protocol ':#{sym}' — reserved core block type"
        end

        @mutex.synchronize do
          @handlers[sym] = Registration.new(
            name: sym,
            documentation: documentation,
            handler: handler
          )
        end

        sym
      end

      def registered?(name)
        return false if name.nil?

        @mutex.synchronize { @handlers.key?(name.to_sym) }
      end

      def handler_for(name)
        return nil if name.nil?

        @mutex.synchronize { @handlers[name.to_sym]&.handler }
      end

      def documentation_for(name)
        return nil if name.nil?

        @mutex.synchronize { @handlers[name.to_sym]&.documentation }
      end

      def all
        @mutex.synchronize { @handlers.values.map(&:dup) }
      end

      def names
        @mutex.synchronize { @handlers.keys }
      end

      def unregister(name)
        return nil if name.nil?

        @mutex.synchronize { @handlers.delete(name.to_sym) }
      end

      def reset!
        @mutex.synchronize { @handlers.clear }
      end
    end

    @handlers = {}
    @mutex = Mutex.new
  end
end
