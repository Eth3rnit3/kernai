# frozen_string_literal: true

module Kernai
  # Declarative description of an LLM: its vendor id and the set of media
  # modalities it can accept as input or emit as output. Capabilities drive
  # two things in the kernel:
  #
  #   1. Instruction builder sections (don't advertise vision to a text-only
  #      model, don't describe image generation to a chat-only model).
  #   2. Skill filtering — skills declaring `requires :vision` are hidden
  #      from agents whose model can't satisfy them.
  #
  # Providers receive the Model instance on every call and use it to decide
  # how to encode multimodal parts (or fall back to text).
  class Model
    INPUT_CAPABILITIES  = %i[text vision audio_in video_in document_in].freeze
    OUTPUT_CAPABILITIES = %i[text image_gen audio_out].freeze
    CAPABILITIES = (INPUT_CAPABILITIES + OUTPUT_CAPABILITIES).uniq.freeze

    attr_reader :id, :capabilities

    def initialize(id:, capabilities: %i[text])
      raise ArgumentError, 'id is required' if id.nil? || id.to_s.empty?

      @id = id.to_s
      @capabilities = capabilities.map(&:to_sym).freeze
      freeze
    end

    def supports?(*caps)
      caps.flatten.all? { |c| @capabilities.include?(c.to_sym) }
    end

    # Which Media.kind values this model can accept in inbound messages.
    def supported_media_inputs
      mapping = {
        vision: :image,
        audio_in: :audio,
        video_in: :video,
        document_in: :document
      }
      @capabilities.filter_map { |c| mapping[c] }
    end

    def to_s
      @id
    end

    def ==(other)
      other.is_a?(Model) && other.id == @id && other.capabilities == @capabilities
    end
    alias eql? ==

    def hash
      [@id, @capabilities].hash
    end
  end

  # Pre-declared catalogue for the most common models. Consumers either use
  # these directly or instantiate `Kernai::Model.new` for anything not listed
  # — there's no hidden registry, what you see here is what we ship.
  module Models
    # Text-only
    TEXT_ONLY = Model.new(id: 'text-only', capabilities: %i[text])

    # Anthropic
    CLAUDE_OPUS_4    = Model.new(id: 'claude-opus-4-20250514',    capabilities: %i[text vision])
    CLAUDE_SONNET_4  = Model.new(id: 'claude-sonnet-4-20250514',  capabilities: %i[text vision])
    CLAUDE_HAIKU_4_5 = Model.new(id: 'claude-haiku-4-5-20251001', capabilities: %i[text vision])

    # OpenAI
    GPT_4O      = Model.new(id: 'gpt-4o',      capabilities: %i[text vision audio_in audio_out])
    GPT_4O_MINI = Model.new(id: 'gpt-4o-mini', capabilities: %i[text vision])

    # Google
    GEMINI_2_5_PRO = Model.new(
      id: 'gemini-2.5-pro',
      capabilities: %i[text vision audio_in video_in document_in]
    )

    # Ollama (local)
    LLAMA_3_1 = Model.new(id: 'llama3.1', capabilities: %i[text])
    LLAVA     = Model.new(id: 'llava',    capabilities: %i[text vision])
  end
end
