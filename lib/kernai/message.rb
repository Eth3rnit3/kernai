# frozen_string_literal: true

module Kernai
  # A message in the conversation. `content` is ALWAYS an ordered list of
  # parts (String or Media) — there is no polymorphism to worry about in
  # the rest of the kernel. The constructor normalises scalar inputs so
  # callers can still write `Message.new(role: :user, content: 'hi')`.
  class Message
    attr_reader :role, :content

    def initialize(role:, content:)
      @role = role.to_sym
      @content = Array(content).freeze
    end

    def to_h
      { role: @role, content: @content }
    end

    def system?    = role == :system
    def user?      = role == :user
    def assistant? = role == :assistant

    # Joined textual view of the message — concatenates String parts and
    # renders Media parts as a stable placeholder. Used by recorders, the
    # stream parser fallback, and any consumer that doesn't care about
    # vendor encoding.
    def text
      @content.map { |p| p.is_a?(Media) ? "[#{p.kind}:#{p.id}]" : p.to_s }.join
    end

    def media
      @content.grep(Media)
    end

    def media?
      @content.any? { |p| p.is_a?(Media) }
    end
  end
end
