# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "wrq-cli"
  spec.version = File.read(File.expand_path("VERSION", __dir__)).strip
  spec.authors = ["Mohamed Morsi", "Tobi Lutke"]

  spec.summary = "A local-first research paper library for the command line"
  spec.description = <<~DESCRIPTION.strip
    Download, organize, search, annotate, deduplicate, and open research papers
    from a local library, with arXiv and Hugging Face Papers support.
  DESCRIPTION
  spec.homepage = "https://github.com/mohamedsobhi777/wrq"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata = {
    "bug_tracker_uri" => "https://github.com/mohamedsobhi777/wrq/issues",
    "changelog_uri" => "https://github.com/mohamedsobhi777/wrq/releases",
    "documentation_uri" => "https://github.com/mohamedsobhi777/wrq#readme",
    "rubygems_mfa_required" => "true",
    "source_code_uri" => spec.homepage,
  }

  spec.files = Dir[
    "bin/wrq",
    "lib/**/*.rb",
    "wrq.rb",
    "VERSION",
    "LICENSE",
    "README.md",
  ]
  spec.bindir = "bin"
  spec.executables = ["wrq"]
  spec.require_paths = ["lib", "."]
end
