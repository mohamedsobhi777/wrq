# frozen_string_literal: true

require "digest"
require "tmpdir"
require_relative "test_helper"
require_relative "../lib/wrq/sha256"

class WrqSha256Test < Minitest::Test
  VECTORS = [
    "",
    "abc",
    "The quick brown fox jumps over the lazy dog",
    "a" * 55,
    "a" * 56,
    "a" * 64,
    "a" * 65,
    (0..255).to_a.pack("C*")
  ].freeze

  def test_matches_standard_sha256_vectors_and_chunk_boundaries
    VECTORS.each do |value|
      expected = Digest::SHA256.hexdigest(value)
      assert_equal expected, Wrq::SHA256.hexdigest(value)

      incremental = Wrq::SHA256.new
      value.bytes.each_slice(7) { |slice| incremental.update(slice.pack("C*")) }
      assert_equal expected, incremental.hexdigest
    end
  end

  def test_streams_files_without_changing_the_result
    Dir.mktmpdir("wrq-sha256") do |directory|
      path = File.join(directory, "paper.pdf")
      body = ("%PDF-1.7\n" + ("payload" * 20_000)).b
      File.binwrite(path, body)

      assert_equal Digest::SHA256.hexdigest(body), Wrq::SHA256.file(path, 97)
    end
  end

  def test_streams_binary_files_that_begin_with_nul
    Dir.mktmpdir("wrq-sha256-binary") do |directory|
      path = File.join(directory, "binary.pdf")
      body = ("\x00\x01\x02\xff".b * 20_000)
      File.binwrite(path, body)

      assert_equal Digest::SHA256.hexdigest(body), Wrq::SHA256.file(path, 1024)
    end
  end

  def test_finished_digest_cannot_be_updated
    digest = Wrq::SHA256.new.update("abc")
    assert_equal Digest::SHA256.hexdigest("abc"), digest.hexdigest
    assert_raises(ArgumentError) { digest.update("more") }
  end
end
