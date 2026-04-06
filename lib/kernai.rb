require_relative "kernai/version"
require_relative "kernai/config"
require_relative "kernai/logger"
require_relative "kernai/message"
require_relative "kernai/block"
require_relative "kernai/parser"
require_relative "kernai/stream_parser"
require_relative "kernai/skill"
require_relative "kernai/provider"
require_relative "kernai/instruction_builder"
require_relative "kernai/agent"
require_relative "kernai/kernel"
require_relative "kernai/mock/provider"

module Kernai
  class Error < StandardError; end
  class SkillNotFoundError < Error; end
  class SkillNotAllowedError < Error; end
  class MaxStepsReachedError < Error; end
  class ProviderError < Error; end

  def self.config
    @config ||= Config.new
  end

  def self.configure
    yield config
  end

  def self.logger
    config.logger
  end

  def self.reset!
    @config = Config.new
    Skill.reset!
  end
end
