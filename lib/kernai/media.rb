# frozen_string_literal: true

require 'digest'
require 'base64'

module Kernai
  # Immutable value object representing a piece of media (image, audio,
  # video, document) flowing through the agent loop. A Media can reach the
  # conversation in three shapes:
  #
  #   - :url    → `data` is a remote URL the provider may reference directly
  #   - :path   → `data` is a filesystem path; the provider reads it lazily
  #   - :bytes  → `data` is the raw binary payload already in memory
  #
  # The `id` is derived deterministically from the payload so identical
  # media deduplicate across messages and can be referenced by stable id.
  class Media
    KINDS = %i[image audio video document].freeze
    SOURCES = %i[url path bytes].freeze

    attr_reader :kind, :mime_type, :source, :data, :metadata, :id

    def initialize(kind:, mime_type:, source:, data:, metadata: {})
      raise ArgumentError, "invalid kind: #{kind}" unless KINDS.include?(kind.to_sym)
      raise ArgumentError, "invalid source: #{source}" unless SOURCES.include?(source.to_sym)

      @kind = kind.to_sym
      @mime_type = mime_type.to_s
      @source = source.to_sym
      @data = data
      @metadata = metadata.dup.freeze
      @id = "media_#{Digest::SHA1.hexdigest(@data.to_s)[0, 12]}"
      freeze
    end

    def url?
      @source == :url
    end

    def path?
      @source == :path
    end

    def bytes?
      @source == :bytes
    end

    # Materialise the payload as raw bytes, regardless of how the media was
    # originally constructed. Providers that must upload binary content to
    # their vendor endpoint call this once they know they can actually use
    # the payload — we never load a file we won't send.
    def read_bytes
      case @source
      when :bytes then @data
      when :path  then File.binread(@data)
      when :url   then raise Error, "cannot read bytes of a URL-backed media (#{@data})"
      end
    end

    def to_base64
      Base64.strict_encode64(read_bytes)
    end

    def to_h
      { id: id, kind: @kind, mime_type: @mime_type, source: @source, metadata: @metadata }
    end

    class << self
      def from_file(path, kind: nil, mime_type: nil)
        mime = mime_type || guess_mime(path)
        new(
          kind: kind || kind_for(mime),
          mime_type: mime,
          source: :path,
          data: path
        )
      end

      def from_url(url, kind: nil, mime_type: nil)
        mime = mime_type || guess_mime(url)
        new(
          kind: kind || kind_for(mime),
          mime_type: mime,
          source: :url,
          data: url
        )
      end

      def from_bytes(bytes, mime_type:, kind: nil)
        new(
          kind: kind || kind_for(mime_type),
          mime_type: mime_type,
          source: :bytes,
          data: bytes
        )
      end

      private

      def kind_for(mime_type)
        case mime_type.to_s
        when %r{^image/}       then :image
        when %r{^audio/}       then :audio
        when %r{^video/}       then :video
        else :document
        end
      end

      # Minimal extension → MIME mapping. We intentionally avoid pulling a
      # heavy dependency (marcel / mime-types): the common cases are few,
      # and callers who need something exotic can pass `mime_type:` explicitly.
      EXT_MIME = {
        '.png' => 'image/png',
        '.jpg' => 'image/jpeg',
        '.jpeg' => 'image/jpeg',
        '.gif' => 'image/gif',
        '.webp' => 'image/webp',
        '.mp3' => 'audio/mpeg',
        '.wav' => 'audio/wav',
        '.ogg' => 'audio/ogg',
        '.mp4' => 'video/mp4',
        '.webm' => 'video/webm',
        '.pdf' => 'application/pdf',
        '.txt' => 'text/plain'
      }.freeze

      def guess_mime(path_or_url)
        ext = File.extname(path_or_url.to_s.split('?').first.to_s).downcase
        EXT_MIME[ext] || 'application/octet-stream'
      end
    end
  end
end
