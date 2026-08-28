# frozen_string_literal: true

require_relative "../compat"
require_relative "../sha256"

module Wrq
  module Sources
    # Small persistent cache for validated arXiv Atom responses. Callers are
    # responsible for validating a response before writing it; the cache keeps
    # exact requested identifiers separate and never derives a path from an ID.
    class ArxivAtomCache
      MAGIC = "wrq-arxiv-atom-cache-v1\n"
      DEFAULT_TTL = 6 * 60 * 60
      DEFAULT_MAX_ENTRIES = 256
      MAX_IDENTIFIER_BYTES = 1024
      SCOPE_KEY_BYTES = 64
      MAX_TIMESTAMP_BYTES = 64

      class UnsafeCache < Wrq::UnsafePath; end

      class Entry
        attr_reader :body

        def initialize(body, fresh)
          @body = body
          @fresh = fresh
        end

        def fresh?
          @fresh
        end
      end

      def initialize(path:, scope:, max_bytes:, ttl: DEFAULT_TTL,
                     max_entries: DEFAULT_MAX_ENTRIES, clock: nil)
        @path = File.expand_path(path.to_s)
        @root = File.dirname(@path)
        @scope_key = SHA256.hexdigest(scope.to_s)
        @max_bytes = Integer(max_bytes)
        @ttl = Float(ttl)
        @max_entries = Integer(max_entries)
        @clock = clock

        raise ArgumentError, "cache max_bytes must be positive" unless @max_bytes.positive?
        raise ArgumentError, "cache TTL must be non-negative" if @ttl.negative?
        unless @max_entries.positive?
          raise ArgumentError, "cache max_entries must be positive"
        end

        verify_existing_cache_directories
      end

      def read(identifier)
        requested_id = identifier.to_s
        return nil unless cacheable_identifier?(requested_id)
        return nil unless verify_existing_cache_directories

        contents = nil
        modified_at = nil
        open_verified_entry(entry_path(requested_id)) do |file|
          stat = file.stat
          return nil if stat.size > maximum_file_bytes

          begin
            contents = file.readpartial(maximum_file_bytes + 1)
          rescue EOFError
            contents = String.new
          end
          modified_at = stat.mtime.to_f
        end
        return nil if contents.nil? || contents.bytesize > maximum_file_bytes

        decoded = decode(contents, requested_id)
        return nil unless decoded

        body, stored_at = decoded
        cached_at = stored_at < modified_at ? stored_at : modified_at
        age = current_time - cached_at
        Entry.new(body, age >= 0.0 && age <= @ttl)
      rescue UnsafeCache
        raise
      rescue SystemCallError, IOError
        nil
      end

      def write(identifier, body)
        requested_id = identifier.to_s
        atom = body.to_s
        return false unless cacheable_identifier?(requested_id)
        return false if atom.bytesize > @max_bytes

        destination = entry_path(requested_id)
        with_cache_lock do
          verify_regular_path_if_present(destination, "cache entry")
          Compat.atomic_write(destination, encode(requested_id, atom))
          verify_regular_path_if_present(destination, "cache entry")
          prune(destination)
        end
        true
      rescue UnsafeCache
        raise
      rescue StandardError
        # Provider cache state is rebuildable and must never make a successful
        # metadata request fail.
        false
      end

      def delete(identifier)
        requested_id = identifier.to_s
        return false unless cacheable_identifier?(requested_id)
        return false unless verify_existing_cache_directories

        path = entry_path(requested_id)
        return false unless verify_regular_path_if_present(path, "cache entry")

        File.delete(path)
        true
      rescue UnsafeCache
        raise
      rescue SystemCallError, IOError
        false
      end

      private

      def current_time
        @clock ? @clock.call.to_f : Time.now.to_f
      end

      def cacheable_identifier?(identifier)
        !identifier.empty? && identifier.bytesize <= MAX_IDENTIFIER_BYTES &&
          !identifier.include?("\n") && !identifier.include?("\r")
      end

      def maximum_file_bytes
        MAGIC.bytesize + SCOPE_KEY_BYTES + 1 + MAX_IDENTIFIER_BYTES + 1 +
          MAX_TIMESTAMP_BYTES + 1 + @max_bytes
      end

      def encode(identifier, body)
        timestamp = format("%.9f", current_time)
        "#{MAGIC}#{@scope_key}\n#{identifier}\n#{timestamp}\n#{body}"
      end

      def decode(contents, expected_identifier)
        return nil unless contents.start_with?(MAGIC)

        scope_start = MAGIC.bytesize
        scope_end = contents.index("\n", scope_start)
        return nil unless scope_end
        return nil unless contents.byteslice(scope_start, scope_end - scope_start) == @scope_key

        identifier_start = scope_end + 1
        identifier_end = contents.index("\n", identifier_start)
        return nil unless identifier_end

        stored_identifier = contents.byteslice(
          identifier_start,
          identifier_end - identifier_start
        )
        return nil unless stored_identifier == expected_identifier

        timestamp_start = identifier_end + 1
        timestamp_end = contents.index("\n", timestamp_start)
        return nil unless timestamp_end
        return nil if timestamp_end - timestamp_start > MAX_TIMESTAMP_BYTES

        stored_at = Float(contents.byteslice(
          timestamp_start,
          timestamp_end - timestamp_start
        ))
        body_start = timestamp_end + 1
        body = contents.byteslice(body_start, contents.bytesize - body_start)
        return nil if body.nil? || body.bytesize > @max_bytes

        [body, stored_at]
      rescue ArgumentError
        nil
      end

      def entry_path(identifier)
        digest = SHA256.hexdigest("#{@scope_key}:#{identifier}")
        File.join(@path, "#{digest}.atom")
      end

      def lock_path
        File.join(@path, ".lock")
      end

      def verify_existing_cache_directories
        return false unless verify_directory_if_present(@root, "cache root")
        return false unless verify_directory_if_present(@path, "cache directory")

        true
      end

      def verify_directory_if_present(path, label)
        if File.symlink?(path)
          raise UnsafeCache, "arXiv #{label} cannot be a symlink: #{path}"
        end
        return false unless File.exist?(path)

        stat = File.lstat(path)
        unless stat.directory? && !stat.symlink?
          raise UnsafeCache, "arXiv #{label} is not a directory: #{path}"
        end
        true
      end

      def prepare_cache_directory
        mkdir_p_verified(@root, "cache root")
        mkdir_p_verified(@path, "cache directory")
      end

      def mkdir_p_verified(path, label)
        missing = []
        current = path
        loop do
          if File.symlink?(current)
            raise UnsafeCache, "arXiv #{label} traverses a symlink: #{current}"
          end
          if File.exist?(current)
            unless File.lstat(current).directory?
              raise UnsafeCache, "arXiv #{label} is not a directory: #{current}"
            end
            break
          end

          missing.unshift(current)
          parent = File.dirname(current)
          if parent == current
            raise UnsafeCache, "arXiv #{label} has no usable parent: #{path}"
          end
          current = parent
        end

        missing.each do |directory|
          begin
            Dir.mkdir(directory)
          rescue Errno::EEXIST
          end
          if File.symlink?(directory) || !File.lstat(directory).directory?
            raise UnsafeCache, "arXiv #{label} changed while creating: #{directory}"
          end
        end
      end

      def with_cache_lock
        prepare_cache_directory
        path = lock_path
        verify_regular_path_if_present(path, "cache lock")
        file = nil
        locked = false
        begin
          file = File.open(path, File::RDWR | File::CREAT, 0o600)
          verify_open_file(path, file, "cache lock")
          begin
            locked = file.flock(File::LOCK_EX) != false
          rescue NotImplementedError, SystemCallError
            locked = false
          end
          raise IOError, "arXiv cache locking is unavailable: #{path}" unless locked
          yield
        ensure
          if file
            if locked
              begin
                file.flock(File::LOCK_UN)
              rescue NotImplementedError, SystemCallError
              end
            end
            file.close unless file.closed?
          end
        end
      end

      def open_verified_entry(path)
        verify_regular_path_if_present(path, "cache entry")
        File.open(path, "rb") do |file|
          verify_open_file(path, file, "cache entry")
          yield file
        end
      end

      def verify_regular_path_if_present(path, label)
        if File.symlink?(path)
          raise UnsafeCache, "arXiv #{label} cannot be a symlink: #{path}"
        end
        return nil unless File.exist?(path)

        stat = File.lstat(path)
        unless stat.file? && !stat.symlink? && stat.nlink == 1
          raise UnsafeCache, "arXiv #{label} is not a private regular file: #{path}"
        end
        stat
      end

      def verify_open_file(path, file, label)
        path_stat = File.lstat(path)
        file_stat = file.stat
        unless path_stat.file? && !path_stat.symlink? && path_stat.nlink == 1 &&
               file_stat.file? && file_stat.nlink == 1 &&
               path_stat.dev == file_stat.dev && path_stat.ino == file_stat.ino
          raise UnsafeCache, "arXiv #{label} changed while opening: #{path}"
        end
      end

      def prune(current_path)
        files = []
        Dir.entries(@path).each do |name|
          path = File.join(@path, name)
          if name.match?(/\A[0-9a-f]{64}\.atom\.tmp-[0-9]+-[0-9]+\z/)
            verify_regular_path_if_present(path, "cache temporary file")
            File.delete(path)
          elsif name.match?(/\A[0-9a-f]{64}\.atom\z/)
            files << path if verify_regular_path_if_present(path, "cache entry")
          end
        end
        excess = files.length - @max_entries
        return unless excess.positive?

        candidates = files.reject { |path| path == current_path }
        candidates.sort_by! do |path|
          begin
            stat = verify_regular_path_if_present(path, "cache entry")
            [stat ? stat.mtime.to_f : 0.0, path]
          rescue SystemCallError
            [0.0, path]
          end
        end
        candidates.first(excess).each do |path|
          begin
            File.delete(path)
          rescue SystemCallError
          end
        end
      rescue SystemCallError, IOError
      end
    end
  end
end
