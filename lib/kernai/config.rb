# frozen_string_literal: true

module Kernai
  class Config
    attr_accessor :debug, :default_provider, :allowed_skills, :recorder

    def initialize
      @debug = false
      @default_provider = nil
      @allowed_skills = nil
      @logger = nil
      @recorder = nil
    end

    def logger
      @logger ||= Kernai::Logger.new
    end

    attr_writer :logger
  end
end
