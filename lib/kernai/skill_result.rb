# frozen_string_literal: true

module Kernai
  # Rich return shape for a skill's `execute` block. Lets the skill carry
  # three distinct pieces of information back to the kernel:
  #
  #   - `text`     → the message the LLM will see (injected in a
  #                  <block type="result" name="..."> wrapper)
  #   - `media`    → one or more Kernai::Media parts (spliced in as
  #                  <block type="media"/> references after the text)
  #   - `metadata` → free-form hash attached to the :skill_result recorder
  #                  entry. Never shown to the LLM; useful for scoring,
  #                  timings, structured status codes, etc.
  #
  # Skills are NOT required to return a SkillResult — the legacy return
  # shapes (String, Media, Array<String|Media>, nil, other) remain fully
  # supported. Use SkillResult only when you need the metadata side-channel
  # or when it reads more clearly than a raw string.
  #
  # Normalisation utilities for ANY return shape live as class methods on
  # this class (`.wrap`, `.metadata_of`) so callers only have to know
  # about one name.
  class SkillResult
    attr_reader :text, :media, :metadata

    def initialize(text: '', media: nil, metadata: nil)
      @text = text.to_s
      @media = Array(media).compact
      @metadata = metadata || {}
    end

    def to_h
      { text: @text, media: @media.map(&:to_h), metadata: @metadata }
    end

    # --- Normalisation utilities (work on ANY skill return value) ---

    # Turn whatever a Skill's execute block returned into a canonical
    # list of parts the kernel can splice back into the conversation.
    # Media parts are side-registered in the context's MediaStore so
    # other components (skills, workflow consumers, recorders) can look
    # them up by id without having to pass the object around.
    def self.wrap(value, store)
      parts = normalise(value)
      parts.each { |p| store.put(p) if p.is_a?(Media) }
      parts
    end

    # Extract observability metadata from a skill return value. Only
    # explicit SkillResult instances carry metadata; every other return
    # shape yields an empty hash. Providers / the kernel call this without
    # having to introspect the return type themselves.
    def self.metadata_of(value)
      value.is_a?(SkillResult) ? value.metadata : {}
    end

    # Extract the text payload from a skill return value — what ends up
    # in the LLM-facing <block type="result"> wrapper. Defined as the
    # counterpart to `metadata_of` so the kernel can log "what the LLM
    # saw" cleanly.
    def self.text_of(value)
      case value
      when nil         then ''
      when SkillResult then value.text
      when String      then value
      when Media       then ''
      when Array       then value.grep(String).join
      else value.to_s
      end
    end

    def self.normalise(value)
      case value
      when nil         then ['']
      when String      then [value]
      when Media       then [value]
      when Array       then value.map { |p| coerce(p) }
      when SkillResult then [value.text, *value.media]
      else [value.to_s]
      end
    end

    def self.coerce(part)
      case part
      when String, Media then part
      else part.to_s
      end
    end
  end
end
