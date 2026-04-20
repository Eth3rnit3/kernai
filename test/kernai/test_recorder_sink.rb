# frozen_string_literal: true

require_relative '../test_helper'

# Tests focused on the pluggable Sink interface. The existing tests in
# test_recorder.rb already cover the full Recorder behavior against the
# default MemorySink; this file exercises the Sink abstraction itself.
class TestRecorderSink < Minitest::Test
  include Kernai::TestHelpers

  def test_base_sink_raises_on_record
    base = Kernai::Recorder::Sink::Base.new
    assert_raises(NotImplementedError) { base.record({}) }
  end

  def test_base_sink_entries_defaults_to_empty_array
    base = Kernai::Recorder::Sink::Base.new
    assert_equal [], base.entries
  end

  def test_base_sink_clear_is_noop
    base = Kernai::Recorder::Sink::Base.new
    assert_nil base.clear!
  end

  # --- MemorySink ---

  def test_memory_sink_appends_entries
    sink = Kernai::Recorder::Sink::MemorySink.new
    sink.record({ step: 0, event: :test })
    sink.record({ step: 1, event: :test })

    assert_equal 2, sink.entries.size
    assert_equal 0, sink.entries[0][:step]
    assert_equal 1, sink.entries[1][:step]
  end

  def test_memory_sink_clear_empties
    sink = Kernai::Recorder::Sink::MemorySink.new
    sink.record({ step: 0, event: :a })
    sink.clear!
    assert_empty sink.entries
  end

  def test_memory_sink_is_thread_safe_on_concurrent_writes
    sink = Kernai::Recorder::Sink::MemorySink.new
    threads = 50.times.map do |i|
      Thread.new { sink.record({ step: i, event: :t }) }
    end
    threads.each(&:join)
    assert_equal 50, sink.entries.size
  end

  # --- CompositeSink ---

  def test_composite_requires_at_least_one_sink
    assert_raises(ArgumentError) { Kernai::Recorder::Sink::CompositeSink.new }
  end

  def test_composite_fans_out_to_every_child
    a = Kernai::Recorder::Sink::MemorySink.new
    b = Kernai::Recorder::Sink::MemorySink.new
    composite = Kernai::Recorder::Sink::CompositeSink.new(a, b)

    composite.record({ step: 0, event: :ping })

    assert_equal 1, a.entries.size
    assert_equal 1, b.entries.size
  end

  def test_composite_entries_delegates_to_first_child
    a = Kernai::Recorder::Sink::MemorySink.new
    b_called = []
    b = Class.new(Kernai::Recorder::Sink::Base) do
      define_method(:record) { |entry| b_called << entry }
    end.new
    composite = Kernai::Recorder::Sink::CompositeSink.new(a, b)
    composite.record({ step: 0, event: :x })

    assert_equal 1, composite.entries.size
    assert_equal 1, b_called.size
  end

  def test_composite_clear_cascades
    a = Kernai::Recorder::Sink::MemorySink.new
    b = Kernai::Recorder::Sink::MemorySink.new
    composite = Kernai::Recorder::Sink::CompositeSink.new(a, b)

    composite.record({ step: 0, event: :x })
    composite.clear!

    assert_empty a.entries
    assert_empty b.entries
  end

  # --- Recorder integration ---

  def test_recorder_defaults_to_memory_sink
    recorder = Kernai::Recorder.new
    assert_instance_of Kernai::Recorder::Sink::MemorySink, recorder.sink
  end

  def test_recorder_accepts_custom_sink
    captured = []
    custom = Class.new(Kernai::Recorder::Sink::Base) do
      define_method(:record) { |entry| captured << entry }
    end.new

    recorder = Kernai::Recorder.new(sink: custom)
    recorder.record(step: 0, event: :ping, data: 'hi')

    assert_equal 1, captured.size
    assert_equal :ping, captured[0][:event]
    assert_equal 'hi', captured[0][:data]
  end

  def test_recorder_query_helpers_against_custom_sink_without_entries
    noop = Class.new(Kernai::Recorder::Sink::Base) do
      define_method(:record) { |_entry| nil }
    end.new

    recorder = Kernai::Recorder.new(sink: noop)
    recorder.record(step: 0, event: :x, data: nil)

    # No entries means no query results, but the helpers must not blow up.
    assert_empty recorder.entries
    assert_empty recorder.to_a
    assert_empty recorder.steps
    assert_empty recorder.for_event(:x)
    assert_empty recorder.for_step(0)
  end

  def test_recorder_with_composite_keeps_memory_queries_working
    db_rows = []
    db_sink = Class.new(Kernai::Recorder::Sink::Base) do
      define_method(:record) { |entry| db_rows << entry }
    end.new

    memory = Kernai::Recorder::Sink::MemorySink.new
    composite = Kernai::Recorder::Sink::CompositeSink.new(memory, db_sink)
    recorder = Kernai::Recorder.new(sink: composite)

    recorder.record(step: 0, event: :ping, data: 'a')
    recorder.record(step: 1, event: :pong, data: 'b')

    # Memory side-queries
    assert_equal 2, recorder.entries.size
    assert_equal [0, 1], recorder.steps
    assert_equal 1, recorder.for_event(:ping).size

    # Custom sink got the fan-out
    assert_equal 2, db_rows.size
  end

  # --- Duck typing: a plain object with `record` works ---

  def test_sink_can_be_any_object_implementing_record
    captured = []
    duck = Class.new do
      define_method(:record) { |entry| captured << entry }
    end.new

    recorder = Kernai::Recorder.new(sink: duck)
    recorder.record(step: 0, event: :x, data: 1)

    assert_equal 1, captured.size
  end
end
