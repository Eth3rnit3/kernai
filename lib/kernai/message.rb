# frozen_string_literal: true

module Kernai
  class Message
    attr_reader :role, :content

    def initialize(role:, content:)
      @role = role.to_sym
      @content = content
    end

    def to_h
      { role: @role, content: @content }
    end

    def system?
      role == :system
    end

    def user?
      role == :user
    end

    def assistant?
      role == :assistant
    end
  end
end
