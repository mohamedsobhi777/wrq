# frozen_string_literal: true

require_relative "sha256"

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
          io.fsync
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
      digest = SHA256.new
      size = 0
      header = String.new

      begin
        File.open(source_path.to_s, "rb") do |source|
          File.open(destination_path.to_s, "wbx", 0o600) do |destination|
            loop do
              chunk = source.read(chunk_size)
              break if chunk.nil? || chunk.bytesize == 0

              header << chunk.byteslice(0, 5 - header.bytesize) if header.bytesize < 5
              digest.update(chunk)
              destination.write(chunk)
              size += chunk.bytesize
            end
            destination.flush
            begin
              destination.fsync
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
      SHA256.file(path, chunk_size)
    end

    def self.acquire_file_lock(path, exclusive = true)
      lock_path = File.expand_path(path.to_s)
      mkdir_p(File.dirname(lock_path))
      raise UnsafePath, "lock file cannot be a symlink: #{lock_path}" if File.symlink?(lock_path)

      lock = File.open(lock_path, "a", 0o600)
      begin
        path_stat = File.lstat(lock_path)
        file_stat = lock.stat
        if path_stat.symlink? || path_stat.nlink != 1 || file_stat.nlink != 1 ||
           path_stat.dev != file_stat.dev || path_stat.ino != file_stat.ino
          raise UnsafePath, "lock file changed while opening: #{lock_path}"
        end
        result = lock.flock(exclusive ? 2 : 1)
        raise Error, "could not acquire library lock: #{lock_path}" if result == false
        lock
      rescue StandardError, Interrupt
        lock.close unless lock.closed?
        raise
      end
    end

    def self.release_file_lock(lock)
      return unless lock

      begin
        lock.flock(8)
      rescue SystemCallError
      ensure
        lock.close unless lock.closed?
      end
      nil
    end

    def self.with_file_lock(path, exclusive = true)
      lock = acquire_file_lock(path, exclusive)
      begin
        yield
      ensure
        release_file_lock(lock)
      end
    end
  end
end
