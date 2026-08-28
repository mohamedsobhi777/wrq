# frozen_string_literal: true

require "json"
require_relative "paper"

module Wrq
  module MetadataCodec
    def self.dump(paper)
      raise InvalidRecord, "expected a paper record" unless paper.is_a?(Paper)
      JSON.pretty_generate(paper.to_h) + "\n"
    rescue JSON::GeneratorError => error
      raise InvalidRecord, "paper metadata is not JSON-compatible: #{error.message}"
    end

    def self.load(contents)
      value = JSON.parse(contents.to_s)
      Paper.from_h(value)
    rescue JSON::ParserError => error
      raise InvalidRecord, "invalid paper record JSON: #{error.message}"
    end

    def self.read(path)
      File.open(path.to_s, "rb") { |io| load(io.read) }
    rescue Errno::ENOENT
      nil
    end

    def self.write(path, paper, temporary_directory = nil)
      Compat.atomic_write(path, dump(paper), 0o600, temporary_directory)
    end
  end
end
