# frozen_string_literal: true

require_relative 'vcr_helper'
require 'stringio'

class TestOllamaProvider < Minitest::Test
  include Kernai::TestHelpers

  def setup
    super
    Kernai.config.logger = Kernai::Logger.new(StringIO.new)
    @provider = Kernai::Examples::OllamaProvider.new
  end

  # --- Non-streaming ---

  def test_simple_final_block_response
    VCR.use_cassette('ollama_final_block') do
      result = @provider.call(
        messages: [
          { role: :system, content: BLOCK_INSTRUCTIONS },
          { role: :user, content: 'What is 2+2?' }
        ],
        model: Kernai::Model.new(id: 'gemma3:27b')
      )

      assert_kind_of Kernai::LlmResponse, result
      assert_includes result.content, 'block'
      assert_includes result.content, 'final'
      assert_includes result.content, '4'
      assert_operator result.prompt_tokens, :>, 0
      assert_operator result.completion_tokens, :>, 0
    end
  end

  def test_non_streaming_parses_block_with_kernai
    VCR.use_cassette('ollama_final_block') do
      response = @provider.call(
        messages: [
          { role: :system, content: BLOCK_INSTRUCTIONS },
          { role: :user, content: 'What is 2+2?' }
        ],
        model: Kernai::Model.new(id: 'gemma3:27b')
      )

      parsed = Kernai::Parser.parse(response.content)
      assert_equal 2, parsed[:blocks].size
      assert_equal :plan, parsed[:blocks][0].type
      assert_equal :final, parsed[:blocks][1].type
      assert_includes parsed[:blocks][1].content, '4'
    end
  end

  # --- Streaming ---

  def test_streaming_final_block
    VCR.use_cassette('ollama_streaming_final') do
      chunks = []
      result = @provider.call(
        messages: [
          { role: :system, content: BLOCK_INSTRUCTIONS },
          { role: :user, content: 'What is 2+2?' }
        ],
        model: Kernai::Model.new(id: 'gemma3:27b')
      ) { |chunk| chunks << chunk }

      assert chunks.size > 1, 'Should receive multiple chunks'
      assert_equal result.content, chunks.join
      assert_includes result.content, '4'
    end
  end

  def test_streaming_with_stream_parser
    VCR.use_cassette('ollama_streaming_final') do
      parser = Kernai::StreamParser.new
      blocks = []

      parser.on(:block_complete) { |block| blocks << block }

      @provider.call(
        messages: [
          { role: :system, content: BLOCK_INSTRUCTIONS },
          { role: :user, content: 'What is 2+2?' }
        ],
        model: Kernai::Model.new(id: 'gemma3:27b')
      ) { |chunk| parser.push(chunk) }

      parser.flush

      assert_equal 2, blocks.size
      assert_equal :plan, blocks[0].type
      assert_equal :final, blocks[1].type
      assert_includes blocks[1].content, '4'
    end
  end

  # --- Full integration with Kernel ---

  def test_kernel_run_with_ollama_provider
    VCR.use_cassette('ollama_streaming_final') do
      agent = Kernai::Agent.new(
        instructions: BLOCK_INSTRUCTIONS,
        provider: @provider,
        model: Kernai::Model.new(id: 'gemma3:27b')
      )

      result = Kernai::Kernel.run(agent, 'What is 2+2?')
      assert_includes result, '4'
    end
  end
end
