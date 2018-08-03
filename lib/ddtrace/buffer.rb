require 'thread'
require 'concurrent/atomic/read_write_lock'

module Datadog
  # Trace buffer that stores application traces. The buffer has a maximum size and when
  # the buffer is full, a random trace is discarded. This class is thread-safe and is used
  # automatically by the ``Tracer`` instance when a ``Span`` is finished.
  class TraceBuffer
    def initialize(max_size)
      @max_size = max_size

      @mutex = Mutex.new()
      @btm = Concurrent::ReadWriteLock.new

      @traces = []
      @closed = false
    end

    # Add a new ``trace`` in the local queue. This method doesn't block the execution
    # even if the buffer is full. In that case, a random trace is discarded.
    def push(trace)
      @btm.with_read_lock do
        return if @closed
        len = @traces.length

        if len < @max_size || @max_size <= 0
          @traces << trace
        else
          # we should replace a random trace with the new one
          @traces[rand(len)] = trace
        end
      end
    end

    # Return the current number of stored traces.
    def length
      @traces.length
    end

    # Return if the buffer is empty.
    def empty?
      @traces.empty?
    end

    # Stored traces are returned and the local buffer is reset.
    def pop
      @btm.with_write_lock do
        traces = @traces
        @traces = []
        return traces
      end
    end

    def close
      @btm.with_write_lock do
        @closed = true
      end
    end
  end
end
