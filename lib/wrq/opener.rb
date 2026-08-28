# frozen_string_literal: true

module Wrq
  # Launches a PDF with the configured platform viewer without passing the
  # paper path through a shell.
  class Opener
    def initialize(env: nil, platform: RUBY_PLATFORM)
      @env = env
      @platform = platform.to_s
    end

    def open(path)
      path = File.expand_path(path.to_s)
      raise ArgumentError, "paper does not exist: #{path}" unless File.file?(path)

      # Deterministic hook for acceptance tests. It deliberately bypasses
      # process creation while exercising the same resolved-path contract.
      test_log = environment_value('WRQ_TEST_OPEN_LOG').to_s
      unless test_log.empty?
        File.open(test_log, 'a') { |file| file.puts(path) }
        return true
      end

      command = command_for_platform
      # Do not route through a shell. The CLI exits immediately after this
      # launch, so the child is inherited by the platform rather than retained
      # as a long-lived subprocess. Avoid Process.detach/File::NULL here: both
      # are absent from Spinel's intentionally small process API.
      null_device = @platform.match?(/mswin|mingw|cygwin/i) ? "NUL" : "/dev/null"
      Process.spawn(*(command + [path]), out: null_device, err: null_device)
      true
    rescue Errno::ENOENT
      raise RuntimeError, "paper opener is unavailable: #{command && command.first}"
    end

    private

    def command_for_platform
      configured = environment_value('WRQ_OPENER').to_s
      return [configured] unless configured.empty?

      if @platform.match?(/darwin/i)
        ['open']
      elsif @platform.match?(/mswin|mingw|cygwin/i)
        # explorer.exe accepts the file as a direct argv value; unlike
        # `cmd /c start`, metacharacters in a paper path are never reparsed.
        ['explorer.exe']
      else
        ['xdg-open']
      end
    end

    def environment_value(name)
      @env ? @env[name] : ENV[name]
    end
  end
end
