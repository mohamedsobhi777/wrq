# frozen_string_literal: true

module Wrq
  # A file-backed throttle shared by every wrq process. The exclusive lock is
  # held while waiting and writing the next timestamp, preventing two processes
  # from both passing the same rate-limit window.
  class Throttle
    DEFAULT_INTERVAL = 3.0
    DISABLE_ENV = "WRQ_DISABLE_THROTTLE"

    class UnsafeState < StandardError; end

    def initialize(path:, interval: DEFAULT_INTERVAL, disabled: nil, clock: nil, sleeper: nil)
      @path = File.expand_path(path.to_s)
      @interval = Float(interval)
      @disabled = disabled.nil? ? env_disabled? : !!disabled
      @clock = clock
      @sleeper = sleeper

      raise ArgumentError, "interval must be non-negative" if @interval.negative?
    end

    # Serialize an entire provider request. The file lock remains held while
    # the block runs, enforcing both the minimum start interval and arXiv's
    # one-connection-at-a-time requirement across wrq processes.
    def synchronize
      return yield(0.0) if @disabled

      mkdir_p(File.dirname(@path))
      slept = 0.0
      result = nil
      open_verified_state_file do |file|
        file.flock(File::LOCK_EX)
        previous = read_timestamp(file)
        now = current_time
        remaining = @interval - (now - previous)
        if previous.positive? && remaining.positive?
          sleep_for(remaining)
          slept = remaining
        end

        file.rewind
        # Fixed-width first-line state avoids File#truncate, which is outside
        # Spinel's IO subset. Readers intentionally consume only this line.
        file.write(format("%020.9f\n", current_time))
        file.flush
        begin
          file.fsync
        rescue SystemCallError, IOError
        end
        result = yield(slept)
      ensure
        begin
          file.flock(File::LOCK_UN)
        rescue SystemCallError, IOError
        end
      end
      result
    end

    # Wait-only compatibility helper used by callers that do not need to keep
    # the connection gate. Returns the amount of time slept.
    def wait
      slept = 0.0
      synchronize { |duration| slept = duration }
      slept
    end

    alias call wait

    private

    def current_time
      @clock ? @clock.call.to_f : Time.now.to_f
    end

    def sleep_for(seconds)
      if @sleeper
        @sleeper.call(seconds)
      else
        sleep(seconds)
      end
    end

    def env_disabled?
      value = ENV[DISABLE_ENV].to_s.downcase
      value == "1" || value == "true" || value == "yes"
    end

    def read_timestamp(file)
      file.rewind
      value = file.gets.to_s.strip
      return 0.0 if value.empty?

      Float(value)
    rescue ArgumentError
      0.0
    end

    def open_verified_state_file
      if File.symlink?(@path)
        raise UnsafeState, "throttle state cannot be a symlink: #{@path}"
      end

      File.open(@path, File::RDWR | File::CREAT, 0o600) do |file|
        path_stat = File.lstat(@path)
        file_stat = file.stat
        if path_stat.symlink? || path_stat.nlink != 1 || file_stat.nlink != 1 ||
           path_stat.dev != file_stat.dev || path_stat.ino != file_stat.ino
          raise UnsafeState, "throttle state changed while opening: #{@path}"
        end
        yield file
      end
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
