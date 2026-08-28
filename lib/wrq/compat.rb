# frozen_string_literal: true

require "digest"

module Wrq
  class Error < StandardError; end
  class InvalidIdentity < Error; end
  class InvalidRecord < Error; end
  class UnsafePath < Error; end
  class AssetConflict < Error; end

  # Small, stdlib-only filesystem helpers shared by MRI and Spinel builds.
  module Compat
    class CopyResult
      attr_reader :sha256, :size, :header

      def initialize(sha256, size, header)
        @sha256 = sha256
        @size = size
        @header = header
      end
    end

    COPY_CHUNK_SIZE = 1024 * 1024

    def self.mkdir_p(path)
      expanded = File.expand_path(path.to_s)
      return expanded if Dir.exist?(expanded)

      missing = []
      current = expanded
      while current != "/" && current != "." && !Dir.exist?(current)
        missing.unshift(current)
        parent = File.dirname(current)
        break if parent == current
        current = parent
      end

      missing.each do |directory|
        begin
          Dir.mkdir(directory)
        rescue Errno::EEXIST
          raise unless Dir.exist?(directory)
        end
      end
      expanded
    end

    def self.atomic_write(path, contents, mode = 0o600)
      destination = File.expand_path(path.to_s)
      mkdir_p(File.dirname(destination))
      temporary = nil
      io = nil

      100.times do |attempt|
        candidate = "#{destination}.tmp-#{Process.pid}-#{attempt}"
        begin
          io = File.open(candidate, "wbx", mode)
          temporary = candidate
          break
        rescue Errno::EEXIST
        end
      end
      raise Error, "could not allocate a temporary file for #{destination}" unless io

      begin
        io.write(contents.to_s)
        io.flush
        begin
          io.fsync if io.respond_to?(:fsync)
        rescue NotImplementedError, SystemCallError
        end
        io.close
        io = nil
        File.rename(temporary, destination)
        temporary = nil
      ensure
        io.close if io && !io.closed?
        begin
          File.delete(temporary) if temporary && File.exist?(temporary)
        rescue SystemCallError
        end
      end
      destination
    end

    def self.copy_with_sha256(source_path, destination_path, chunk_size = COPY_CHUNK_SIZE)
      digest = Digest::SHA256.new
      size = 0
      header = String.new

      begin
        File.open(source_path.to_s, "rb") do |source|
          File.open(destination_path.to_s, "wbx", 0o600) do |destination|
            loop do
              chunk = source.read(chunk_size)
              break if chunk.nil? || chunk.empty?

              header << chunk.byteslice(0, 5 - header.bytesize) if header.bytesize < 5
              digest.update(chunk)
              destination.write(chunk)
              size += chunk.bytesize
            end
            destination.flush
            begin
              destination.fsync if destination.respond_to?(:fsync)
            rescue NotImplementedError, SystemCallError
            end
          end
        end
      rescue
        begin
          File.delete(destination_path.to_s) if File.exist?(destination_path.to_s)
        rescue SystemCallError
        end
        raise
      end

      CopyResult.new(digest.hexdigest, size, header)
    end

    def self.sha256_file(path, chunk_size = COPY_CHUNK_SIZE)
      digest = Digest::SHA256.new
      File.open(path.to_s, "rb") do |io|
        loop do
          chunk = io.read(chunk_size)
          break if chunk.nil? || chunk.empty?
          digest.update(chunk)
        end
      end
      digest.hexdigest
    end

    # File#flock is available on MRI's supported Unix platforms. Spinel or a
    # filesystem without flock still gets correct single-process behavior.
    def self.with_file_lock(path, exclusive = true)
      mkdir_p(File.dirname(File.expand_path(path.to_s)))
      lock = File.open(path.to_s, "a")
      locked = false
      begin
        begin
          if lock.respond_to?(:flock)
            result = lock.flock(exclusive ? 2 : 1)
            locked = result != false
          end
        rescue NotImplementedError, SystemCallError
          locked = false
        end
        yield
      ensure
        if locked
          begin
            lock.flock(8)
          rescue NotImplementedError, SystemCallError
          end
        end
        lock.close unless lock.closed?
      end
    end
  end
end
