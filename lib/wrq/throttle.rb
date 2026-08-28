# frozen_string_literal: true

module Wrq
  # A file-backed throttle shared by every wrq process. The exclusive lock is
  # held while waiting and writing the next timestamp, preventing two processes
  # from both passing the same rate-limit window.
  class Throttle
    DEFAULT_INTERVAL = 3.0
    DISABLE_ENV = "WRQ_DISABLE_THROTTLE"

    def initialize(path:, interval: DEFAULT_INTERVAL, disabled: nil, clock: nil, sleeper: nil)
      @path = File.expand_path(path.to_s)
      @interval = Float(interval)
      @disabled = disabled.nil? ? env_disabled? : !!disabled
      @clock = clock || proc { Time.now.to_f }
      @sleeper = sleeper || proc { |seconds| sleep(seconds) }

      raise ArgumentError, "interval must be non-negative" if @interval.negative?
    end

    # Wait until the interval has elapsed, persist the request timestamp, and
    # return the number of seconds slept.
    def wait
      return 0.0 if @disabled || @interval.zero?

      mkdir_p(File.dirname(@path))
      slept = 0.0
      File.open(@path, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        previous = read_timestamp(file)
        now = @clock.call.to_f
        remaining = @interval - (now - previous)
        if previous.positive? && remaining.positive?
          @sleeper.call(remaining)
          slept = remaining
        end

        file.rewind
        file.truncate(0)
        file.write(format("%.9f\n", @clock.call.to_f))
        file.flush
        begin
          file.fsync
        rescue SystemCallError, IOError
        end
      ensure
        begin
          file.flock(File::LOCK_UN)
        rescue SystemCallError, IOError
        end
      end
      slept
    end

    alias call wait

    private

    def env_disabled?
      value = ENV[DISABLE_ENV].to_s.downcase
      value == "1" || value == "true" || value == "yes"
    end

    def read_timestamp(file)
      file.rewind
      value = file.read.to_s.strip
      return 0.0 if value.empty?

      Float(value)
    rescue ArgumentError
      0.0
    end

    def mkdir_p(path)
      return if path.empty? || Dir.exist?(path)

      missing = []
      current = path
      until current.empty? || current == "." || Dir.exist?(current)
        missing.unshift(current)
        parent = File.dirname(current)
        break if parent == current

        current = parent
      end
      missing.each do |directory|
        begin
          Dir.mkdir(directory)
        rescue Errno::EEXIST
        end
      end
    end
  end
end
