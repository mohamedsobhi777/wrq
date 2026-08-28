# frozen_string_literal: true

module Wrq
  # Launches a PDF with the configured platform viewer without passing the
  # paper path through a shell.
  class Opener
    def initialize(env: ENV, platform: RUBY_PLATFORM)
      @env = env
      @platform = platform.to_s
    end

    def open(path)
      path = File.expand_path(path.to_s)
      raise ArgumentError, "paper does not exist: #{path}" unless File.file?(path)

      # Deterministic hook for acceptance tests. It deliberately bypasses
      # process creation while exercising the same resolved-path contract.
      test_log = @env['WRQ_TEST_OPEN_LOG'].to_s
      unless test_log.empty?
        File.open(test_log, 'a') { |file| file.puts(path) }
        return true
      end

      command = command_for_platform
      pid = Process.spawn(*(command + [path]), out: File::NULL, err: File::NULL)
      Process.detach(pid)
      true
    rescue Errno::ENOENT
      raise RuntimeError, "paper opener is unavailable: #{command && command.first}"
    end

    private

    def command_for_platform
      configured = @env['WRQ_OPENER'].to_s
      return [configured] unless configured.empty?

      if @platform.match?(/darwin/i)
        ['open']
      elsif @platform.match?(/mswin|mingw|cygwin/i)
        ['cmd', '/c', 'start', '']
      else
        ['xdg-open']
      end
    end
  end
end
