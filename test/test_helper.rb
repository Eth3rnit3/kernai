$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "kernai"
require "minitest/autorun"

module Kernai
  module TestHelpers
    def setup
      Kernai.reset!
    end
  end
end
