# frozen_string_literal: true

require_relative '../test_helper'

class TestConfig < Minitest::Test
  include Kernai::TestHelpers

  def test_default_debug_is_false
    assert_equal false, Kernai.config.debug
  end

  def test_default_provider_is_nil
    assert_nil Kernai.config.default_provider
  end

  def test_default_allowed_skills_is_nil
    assert_nil Kernai.config.allowed_skills
  end

  def test_logger_returns_a_kernai_logger_by_default
    assert_instance_of Kernai::Logger, Kernai.config.logger
  end

  def test_set_debug
    Kernai.config.debug = true
    assert_equal true, Kernai.config.debug
  end

  def test_set_default_provider
    provider = Object.new
    Kernai.config.default_provider = provider
    assert_equal provider, Kernai.config.default_provider
  end

  def test_set_allowed_skills
    Kernai.config.allowed_skills = %i[search calculate]
    assert_equal %i[search calculate], Kernai.config.allowed_skills
  end

  def test_set_custom_logger
    custom_logger = Kernai::Logger.new(StringIO.new)
    Kernai.config.logger = custom_logger
    assert_equal custom_logger, Kernai.config.logger
  end

  def test_configure_block
    Kernai.configure do |c|
      c.debug = true
      c.allowed_skills = [:search]
    end

    assert_equal true, Kernai.config.debug
    assert_equal [:search], Kernai.config.allowed_skills
  end

  def test_reset_restores_defaults
    Kernai.config.debug = true
    Kernai.config.allowed_skills = [:search]
    Kernai.reset!

    assert_equal false, Kernai.config.debug
    assert_nil Kernai.config.allowed_skills
  end

  def test_logger_is_lazy_initialized
    config = Kernai::Config.new
    # The internal @logger should be nil initially
    assert_nil config.instance_variable_get(:@logger)
    # But calling logger should create one
    logger = config.logger
    assert_instance_of Kernai::Logger, logger
  end

  def test_kernai_logger_delegates_to_config_logger
    custom_logger = Kernai::Logger.new(StringIO.new)
    Kernai.config.logger = custom_logger
    assert_equal custom_logger, Kernai.logger
  end
end
