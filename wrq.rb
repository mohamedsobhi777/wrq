#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/wrq/cli"

if $0 == __FILE__ || !File.basename($0.to_s).end_with?(".rb")
  Signal.trap("INT") { raise Interrupt }
  exit Wrq::CLI.new.run(ARGV)
end
