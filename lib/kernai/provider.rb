# frozen_string_literal: true

module Kernai
  # Abstract base for every LLM adapter. Concrete providers implement
  # `#call` to talk to their vendor, and optionally override `#encode_part`
  # to describe how a Media part should be serialised into the vendor's
  # multimodal format.
  #
  # The default `#encode_part` only knows how to pass through strings.
  # Every other part (including Media) is handed to `#fallback_for`, which
  # returns a plain-text placeholder. This means a text-only provider never
  # crashes on multimodal input: it just sees `"[image: image/png]"` in the
  # conversation — lossy but safe, and the instruction builder already
  # prevented the agent from proposing skills it couldn't satisfy.
  class Provider
    # Talk to the vendor.
    #
    # @param messages [Array<Hash>] [{role:, content: Array<String|Media>}]
    # @param model    [Kernai::Model] the selected model with its capabilities
    # @param block    [Proc] optional streaming callback (yields text chunks)
    # @return [Kernai::LlmResponse]
    def call(messages:, model:, &block)
      raise NotImplementedError, "#{self.class}#call must be implemented"
    end

    # Encode a list of parts into the vendor's native shape. Walks each
    # part through `#encode_part`; anything returning nil is degraded to
    # a text placeholder via `#fallback_for`, and that placeholder is
    # re-encoded so the subclass can wrap it in whatever text envelope
    # the vendor expects (a bare String, `{type: "text", text: ...}`,
    # etc). Callers never see a mixed-shape array.
    def encode(parts, model:)
      Array(parts).map do |p|
        encoded = encode_part(p, model: model)
        next encoded unless encoded.nil?

        placeholder = fallback_for(p)
        encode_part(placeholder, model: model) || placeholder
      end
    end

    # Override hook — return the vendor-native shape for the given part,
    # or nil to let the base class emit a textual fallback. The default
    # implementation passes strings through and declines everything else.
    def encode_part(part, model:) # rubocop:disable Lint/UnusedMethodArgument
      return part if part.is_a?(String)

      nil
    end

    # Lossy placeholder used whenever a part cannot be encoded for the
    # current model. Providers almost never need to override this — the
    # shape is intentionally provider-agnostic so it stays readable in the
    # conversation history regardless of the vendor on the other side.
    def fallback_for(part)
      return part.to_s unless part.is_a?(Media)

      "[#{part.kind} unavailable: #{part.mime_type}]"
    end
  end
end
