module Kernai
  class Config
    attr_accessor :debug, :default_provider, :allowed_skills

    def initialize
      @debug = false
      @default_provider = nil
      @allowed_skills = nil
      @logger = nil
    end

    def logger
      @logger ||= Kernai::Logger.new
    end

    def logger=(val)
      @logger = val
    end
  end
end
