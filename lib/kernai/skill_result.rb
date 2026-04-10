# frozen_string_literal: true

module Kernai
  # Normalises whatever a Skill's `execute` block returned into a canonical
  # list of parts the kernel can splice back into the conversation.
  #
  # A skill may return:
  #   - a String          → ['text']
  #   - a Media           → [media]
  #   - an Array<String|Media>    → taken as-is (each element validated)
  #   - nil               → ['']
  #   - anything else     → [value.to_s]
  #
  # Media parts are side-registered in the context's MediaStore so other
  # components (skills, workflow consumers, recorders) can look them up by
  # id without having to pass the object around.
  module SkillResult
    module_function

    def wrap(value, store)
      parts = normalise(value)
      parts.each { |p| store.put(p) if p.is_a?(Media) }
      parts
    end

    def normalise(value)
      case value
      when nil      then ['']
      when String   then [value]
      when Media    then [value]
      when Array    then value.map { |p| coerce(p) }
      else [value.to_s]
      end
    end

    def coerce(part)
      case part
      when String, Media then part
      else part.to_s
      end
    end
  end
end
