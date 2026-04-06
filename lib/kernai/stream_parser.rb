module Kernai
  class StreamParser
    OPEN_TAG_START = "<block"
    CLOSE_TAG = "</block>"

    attr_reader :state

    def initialize
      @callbacks = {}
      reset
    end

    def on(event, &block)
      @callbacks[event] = block
    end

    def push(chunk)
      @buffer << chunk
      consume
    end

    def flush
      case @state
      when :text
        emit_text_buffer
      when :tag_open
        # Incomplete tag -- emit as text
        emit(:text_chunk, @tag_buffer) unless @tag_buffer.empty?
        @tag_buffer = +""
      when :block_content
        # Incomplete block -- emit what we have as text
        emit(:text_chunk, @tag_buffer + @content_buffer) unless (@tag_buffer + @content_buffer).empty?
        @content_buffer = +""
        @tag_buffer = +""
      end
      @buffer = +""
      @state = :text
    end

    def reset
      @state = :text
      @buffer = +""
      @tag_buffer = +""
      @content_buffer = +""
      @current_type = nil
      @current_name = nil
    end

    private

    def consume
      while @buffer.length > 0
        case @state
        when :text
          consume_text
        when :tag_open
          consume_tag_open
        when :block_content
          consume_block_content
        end
      end
    end

    def consume_text
      idx = @buffer.index("<")
      if idx.nil?
        # No '<' found
        emit(:text_chunk, @buffer) unless @buffer.empty?
        @buffer = +""
      elsif idx > 0
        # Emit text before the '<'
        emit(:text_chunk, @buffer[0...idx])
        @buffer = @buffer[idx..]
        try_enter_tag_open
      else
        # '<' is at position 0
        try_enter_tag_open
      end
    end

    def try_enter_tag_open
      if @buffer.length < OPEN_TAG_START.length
        # Could be a partial match -- check prefix
        if OPEN_TAG_START.start_with?(@buffer)
          @tag_buffer = +@buffer
          @buffer = +""
          @state = :tag_open
        else
          emit(:text_chunk, @buffer[0])
          @buffer = @buffer[1..]
        end
      elsif @buffer.start_with?(OPEN_TAG_START)
        @tag_buffer = +""
        @state = :tag_open
      else
        emit(:text_chunk, @buffer[0])
        @buffer = @buffer[1..]
      end
    end

    def consume_tag_open
      @tag_buffer << @buffer
      @buffer = +""

      close_idx = @tag_buffer.index(">")
      return unless close_idx

      opening_tag = @tag_buffer[0..close_idx]
      remainder = @tag_buffer[(close_idx + 1)..]

      if opening_tag =~ /\A<block\s+type="([^"]+)"(?:\s+name="([^"]*)")?\s*>\z/
        @current_type = Regexp.last_match(1).to_sym
        @current_name = Regexp.last_match(2)

        emit(:block_start, { type: @current_type, name: @current_name })

        @content_buffer = +""
        @tag_buffer = +""
        @state = :block_content
        @buffer = remainder
      else
        emit(:text_chunk, @tag_buffer)
        @tag_buffer = +""
        @state = :text
      end
    end

    def consume_block_content
      @content_buffer << @buffer
      @buffer = +""

      close_idx = @content_buffer.index(CLOSE_TAG)
      if close_idx
        content = @content_buffer[0...close_idx]
        remainder = @content_buffer[(close_idx + CLOSE_TAG.length)..]

        emit(:block_content, content) unless content.empty?

        block = Block.new(type: @current_type, content: content, name: @current_name)
        emit(:block_complete, block)

        @content_buffer = +""
        @current_type = nil
        @current_name = nil
        @state = :text
        @buffer = remainder
      end
    end

    def emit_text_buffer
      # Nothing remaining to emit in text state
    end

    def emit(event, data)
      @callbacks[event]&.call(data)
    end
  end
end
