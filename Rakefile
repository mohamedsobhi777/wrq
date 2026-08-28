# frozen_string_literal: true

require "rake/testtask"
require "rbconfig"
require "tmpdir"

RUBY_SOURCES = FileList["wrq.rb", "lib/**/*.rb"].to_a.freeze
WRQ_SPEC_RUNNER = "spec/tests/wrq_runner.sh"
WRQ_COMPARE_RUNNER = "spec/tests/wrq_runner_and_compare.sh"

def spinel_cmd
  ENV.fetch("SPINEL", "spinel")
end

def spinel_available?
  system("sh", "-c", 'command -v "$1" >/dev/null 2>&1', "--", spinel_cmd)
end

Rake::TestTask.new(:unit) do |task|
  task.libs << "lib" << "test" << "."
  task.pattern = "test/**/*_test.rb"
end

desc "Check every Ruby file with MRI and the complete program with Spinel"
task :lint do
  RUBY_SOURCES.each do |file|
    sh RbConfig.ruby, "-c", file
  end

  unless spinel_available?
    warn "warning: Spinel not found (#{spinel_cmd}); skipping AOT syntax checks"
    next
  end

  Dir.mktmpdir("wrq-spinel-lint") do |directory|
    output = File.join(directory, "wrq.c")
    sh spinel_cmd, "-c", "wrq.rb", "-o", output
  end
end

desc "Run wrq shell acceptance specs against MRI"
task :spec do
  unless File.file?(WRQ_SPEC_RUNNER)
    raise "missing wrq shell spec runner: #{WRQ_SPEC_RUNNER}"
  end

  sh "bash", WRQ_SPEC_RUNNER, "./wrq.rb"
end

desc "Build, spec, and compare the Spinel executable"
task :spec_spinel do
  unless spinel_available?
    warn "warning: Spinel not found (#{spinel_cmd}); skipping native specs"
    next
  end

  unless File.file?(WRQ_COMPARE_RUNNER)
    raise "missing wrq comparison runner: #{WRQ_COMPARE_RUNNER}"
  end

  sh "make", "native", "SPINEL=#{spinel_cmd}"
  sh "bash", WRQ_SPEC_RUNNER, "dist/wrq"
  sh "bash", WRQ_COMPARE_RUNNER, "./wrq.rb", "dist/wrq"
end

desc "Build the wrq-cli gem"
task :gem do
  sh "gem", "build", "wrq.gemspec"
end

desc "Run all checks (native checks are automatic when Spinel is available)"
task test: [:lint, :unit, :spec, :spec_spinel]

task default: :test
