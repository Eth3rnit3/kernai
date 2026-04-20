# frozen_string_literal: true

require_relative '../test_helper'
require 'kernai/providers'

# Structural tests for the bundled provider adapters. Full VCR-backed
# integration tests live under `test/examples/` against the legacy
# `Kernai::Examples::*` aliases; this file only validates the promoted
# class shape so we detect accidental breakage of the public surface.
class TestProviders < Minitest::Test
  include Kernai::TestHelpers

  def test_anthropic_is_subclass_of_provider
    assert Kernai::Providers::Anthropic < Kernai::Provider
  end

  def test_openai_is_subclass_of_provider
    assert Kernai::Providers::Openai < Kernai::Provider
  end

  def test_ollama_is_subclass_of_provider
    assert Kernai::Providers::Ollama < Kernai::Provider
  end

  def test_anthropic_accepts_custom_api_url_and_version
    provider = Kernai::Providers::Anthropic.new(
      api_key: 'k',
      api_url: 'https://proxy.example.com/v1/messages',
      api_version: '2024-01-01'
    )
    assert_kind_of Kernai::Providers::Anthropic, provider
  end

  def test_openai_accepts_custom_api_url
    provider = Kernai::Providers::Openai.new(api_key: 'k', api_url: 'https://my-proxy/v1/chat/completions')
    assert_kind_of Kernai::Providers::Openai, provider
  end

  def test_ollama_accepts_custom_base_url
    provider = Kernai::Providers::Ollama.new(base_url: 'http://remote-ollama:11434')
    assert_kind_of Kernai::Providers::Ollama, provider
  end

  # --- Backward-compat aliases under Kernai::Examples::* ---

  def test_legacy_anthropic_alias_resolves_to_new_class
    require_relative '../../examples/providers/anthropic_provider'

    assert_same Kernai::Providers::Anthropic, Kernai::Examples::AnthropicProvider
  end

  def test_legacy_openai_alias_resolves_to_new_class
    require_relative '../../examples/providers/openai_provider'

    assert_same Kernai::Providers::Openai, Kernai::Examples::OpenaiProvider
  end

  def test_legacy_ollama_alias_resolves_to_new_class
    require_relative '../../examples/providers/ollama_provider'

    assert_same Kernai::Providers::Ollama, Kernai::Examples::OllamaProvider
  end
end
