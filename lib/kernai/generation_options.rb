# frozen_string_literal: true

module Kernai
  # Provider-agnostic knobs for how the LLM should generate its response.
  # Carries the fields every major vendor exposes (temperature, max_tokens,
  # top_p) plus a generic `thinking` hash for reasoning models (Anthropic's
  # extended thinking `budget`, OpenAI/Gemini-style `effort`).
  #
  # The value object is intentionally dumb: it does not know which vendor
  # honours which field. Each provider inspects the fields it supports
  # and routes them into its vendor payload. Fields left nil are simply
  # ignored.
  #
  # Extra vendor-specific knobs pass through `extra:` (kwargs), so an
  # application can still reach provider-specific params without having
  # to subclass the value object. Providers that don't recognise a key
  # should silently drop it.
  class GenerationOptions
    attr_reader :temperature, :max_tokens, :top_p, :thinking, :extra

    def initialize(temperature: nil, max_tokens: nil, top_p: nil, thinking: nil, **extra)
      @temperature = temperature
      @max_tokens  = max_tokens
      @top_p       = top_p
      @thinking    = thinking
      @extra       = extra
    end

    def to_h
      {
        temperature: @temperature,
        max_tokens: @max_tokens,
        top_p: @top_p,
        thinking: @thinking
      }.compact.merge(@extra)
    end

    # An options object with no fields set. Providers can fast-path on
    # `generation.empty?` to avoid building their vendor payload.
    def empty?
      to_h.empty?
    end

    # Returns a new GenerationOptions with `other`'s non-nil fields
    # layered on top of this one. Accepts a Hash or another
    # GenerationOptions. Nil inputs are a no-op.
    def merge(other)
      return self if other.nil?

      self.class.new(**to_h.merge(other.to_h))
    end

    def ==(other)
      other.is_a?(GenerationOptions) && to_h == other.to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end

    # Construct from any of: nil, Hash, or existing GenerationOptions.
    def self.coerce(value)
      case value
      when nil then new
      when GenerationOptions then value
      when Hash then new(**value)
      else
        raise ArgumentError, "Cannot coerce #{value.class} to GenerationOptions"
      end
    end
  end
end
