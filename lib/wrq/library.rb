# frozen_string_literal: true

require_relative "metadata_codec"

module Wrq
  class LibraryPaths
    attr_reader :root, :library, :state, :records, :tmp, :cache, :trash, :lock

    def self.default_root(env = ENV)
      configured = env["WRQ_PATH"].to_s.strip
      return File.expand_path(configured) unless configured.empty?

      home = env["HOME"].to_s.strip
      return File.expand_path("papers", home) unless home.empty?
      File.expand_path("~/papers")
    end

    def initialize(root = nil, env = ENV)
      if root.is_a?(Hash)
        options = root
        root = options[:root] || options["root"]
        env = options[:env] || options["env"] || env
      end
      selected_root = root.to_s.strip
      selected_root = self.class.default_root(env) if selected_root.empty?
      @root = File.expand_path(selected_root)
      @library = File.join(@root, "library")
      @state = File.join(@root, ".wrq")
      @records = File.join(@state, "records")
      @tmp = File.join(@state, "tmp")
      @cache = File.join(@state, "cache")
      @trash = File.join(@state, "trash")
      @lock = File.join(@state, "lock")
    end

    def prepare!
      [@root, @library, @state, @records, @tmp, @cache, @trash].each do |path|
        raise UnsafePath, "managed directory cannot be a symlink: #{path}" if File.symlink?(path)
        Compat.mkdir_p(path)
      end
      self
    end

    def safe_join(base, relative)
      value = relative.to_s
      if value.empty? || value.include?("\0") || value.include?("\\") ||
         value.start_with?("/") || value =~ /\A[A-Za-z]:/
        raise UnsafePath, "unsafe relative path: #{relative.inspect}"
      end

      parts = value.split("/")
      if parts.any? { |part| part.empty? || part == "." || part == ".." }
        raise UnsafePath, "unsafe relative path: #{relative.inspect}"
      end

      expanded_base = File.expand_path(base.to_s)
      raise UnsafePath, "path base cannot be a symlink: #{base}" if File.symlink?(expanded_base)
      destination = File.expand_path(value, expanded_base)
      prefix = expanded_base.end_with?(File::SEPARATOR) ? expanded_base : expanded_base + File::SEPARATOR
      unless destination.start_with?(prefix)
        raise UnsafePath, "path escapes library: #{relative.inspect}"
      end
      current = destination
      while current != expanded_base
        raise UnsafePath, "path traverses a symlink: #{relative.inspect}" if File.symlink?(current)
        parent = File.dirname(current)
        break if parent == current
        current = parent
      end
      destination
    end

    def library_file(filename)
      value = filename.to_s
      unless File.basename(value) == value && value.downcase.end_with?(".pdf")
        raise UnsafePath, "unsafe PDF filename: #{filename.inspect}"
      end
      safe_join(@library, value)
    end

    def asset_path(relative)
      value = relative.to_s
      parts = value.split("/")
      unless parts.length == 2 && parts[0] == "library" && parts[1].downcase.end_with?(".pdf")
        raise UnsafePath, "asset is outside the visible library: #{relative.inspect}"
      end
      safe_join(@root, value)
    end

    def record_path(key)
      safe_join(@records, "#{encode_key(key)}.json")
    end

    def temporary_path(label = "asset")
      safe_label = slug(label, 32)
      stamp = Time.now.to_i
      100.times do |attempt|
        name = "#{safe_label}-#{Process.pid}-#{stamp}-#{attempt}.part"
        candidate = safe_join(@tmp, name)
        return candidate unless File.exist?(candidate)
      end
      raise Error, "could not allocate a library temporary path"
    end

    def asset_filename(identity, title = nil, version = nil)
      raise InvalidIdentity, "paper identity is invalid" unless identity.is_a?(Identity)

      resolved_version = version || identity.version
      if resolved_version && (!resolved_version.is_a?(Integer) || resolved_version < 1)
        raise InvalidIdentity, "arXiv version must be a positive integer"
      end

      identifier = if identity.local?
                     "local-#{identity.base_id[0, 16]}"
                   else
                     identity.base_id.downcase.gsub("/", "--").gsub(/[^a-z0-9.-]+/, "-")
                   end
      version_label = resolved_version ? "-v#{resolved_version}" : ""
      title_slug = slug(title, 96)
      title_label = title_slug == "paper" ? "" : "--#{title_slug}"
      "#{identifier}#{version_label}#{title_label}.pdf"
    end

    def slug(value, maximum = 96)
      result = value.to_s.downcase.gsub(/[^a-z0-9]+/, "-")
      result = result.gsub(/\A-+|-+\z/, "")
      result = result[0, maximum].to_s.gsub(/-+\z/, "")
      result.empty? ? "paper" : result
    end

    private

    def encode_key(key)
      value = key.to_s
      raise UnsafePath, "record key is empty" if value.empty?

      encoded = String.new
      value.each_byte do |byte|
        character = byte.chr
        if character =~ /[A-Za-z0-9.-]/
          encoded << character
        else
          encoded << format("_%02X", byte)
        end
      end
      encoded
    end
  end

  class AssetLookup
    attr_reader :paper, :asset

    def initialize(paper, asset)
      @paper = paper
      @asset = asset
    end
  end

  class IngestResult
    attr_reader :paper, :asset, :path

    def initialize(paper, asset, path, deduplicated)
      @paper = paper
      @asset = asset
      @path = path
      @deduplicated = deduplicated
    end

    def deduplicated?
      @deduplicated
    end
  end

  class TrashResult
    attr_reader :paper, :path, :files

    def initialize(paper, path, files)
      @paper = paper
      @path = path
      @files = files
    end
  end

  class Library
    HASH_RE = /\A(?:sha256:)?([0-9a-f]{64})\z/i

    attr_reader :paths

    def self.default_root(env = ENV)
      LibraryPaths.default_root(env)
    end

    def initialize(root = nil, env = ENV)
      if root.is_a?(Hash)
        options = root
        root = options[:root] || options["root"]
        env = options[:env] || options["env"] || env
      end
      @paths = LibraryPaths.new(root, env)
    end

    def root
      @paths.root
    end

    def library_path
      @paths.library
    end

    def state_path
      @paths.state
    end

    def prepare!
      @paths.prepare!
      self
    end

    def with_lock(exclusive = true, &block)
      prepare!
      Compat.with_file_lock(@paths.lock, exclusive, &block)
    end

    def save(paper)
      with_lock { save_unlocked(paper) }
    end

    def update(reference)
      with_lock do
        paper = find(reference)
        return nil unless paper
        yield paper
        paper.touch!
        save_unlocked(paper)
      end
    end

    def update_metadata(reference, values)
      update(reference) { |paper| paper.merge_metadata!(values) }
    end

    def add_alias(reference, value)
      update(reference) { |paper| paper.add_alias!(value) }
    end

    def papers
      return [] unless Dir.exist?(@paths.records)

      entries = Dir.entries(@paths.records).select do |name|
        name.end_with?(".json") && File.file?(File.join(@paths.records, name))
      end
      entries.sort.map { |name| MetadataCodec.read(File.join(@paths.records, name)) }.compact
    end

    def find(reference)
      value = reference.to_s.strip
      return nil if value.empty?

      hash_match = HASH_RE.match(value)
      return find_by_hash(hash_match[1]) if hash_match

      identity = Identity.recognize(value)
      if identity
        found = find_by_key(identity.canonical_key)
        return found if found
      end

      found = find_by_key(value)
      found || find_by_alias(value)
    end

    def find_by_key(key)
      path = @paths.record_path(key.to_s)
      MetadataCodec.read(path)
    end

    def find_by_alias(value)
      needle = value.to_s.downcase
      papers.find do |paper|
        paper.aliases.any? { |paper_alias| paper_alias.downcase == needle }
      end
    end

    def find_by_hash(value)
      lookup = find_asset_by_hash(value)
      lookup && lookup.paper
    end

    def find_asset_by_hash(value)
      match = HASH_RE.match(value.to_s)
      return nil unless match

      normalized = match[1].downcase
      papers.each do |paper|
        asset = paper.asset_for_hash(normalized)
        return AssetLookup.new(paper, asset) if asset
      end
      nil
    end

    def asset_path(asset)
      raise InvalidRecord, "paper asset is invalid" unless asset.is_a?(Asset)
      @paths.asset_path(asset.path)
    end

    def sha256(path)
      Compat.sha256_file(path)
    end

    def ingest_pdf(identity: nil, source_path:, metadata: {}, aliases: [], version: nil,
                   source_url: nil, added_at: nil, verify_pdf: true)
      if identity && !identity.is_a?(Identity)
        raise InvalidIdentity, "paper identity is invalid"
      end
      source = File.expand_path(source_path.to_s)
      raise Errno::ENOENT, source unless File.file?(source)

      prepare!
      staged = @paths.temporary_path("ingest")
      copied = nil
      begin
        copied = Compat.copy_with_sha256(source, staged)
        if verify_pdf && copied.header != "%PDF-"
          raise InvalidRecord, "source is not a PDF"
        end

        identity ||= Identity.local(copied.sha256)
        resolved_version = resolve_version(identity, version)

        with_lock do
          result = ingest_staged(
            identity: identity,
            staged: staged,
            copied: copied,
            metadata: metadata,
            aliases: aliases,
            version: resolved_version,
            source_url: source_url,
            added_at: added_at
          )
          staged = nil
          result
        end
      ensure
        begin
          File.delete(staged) if staged && File.exist?(staged)
        rescue SystemCallError
        end
      end
    end

    def import_pdf(source_path:, identity: nil, metadata: {}, aliases: [],
                   version: nil, source_url: nil, move: false, verify_pdf: true)
      source = File.expand_path(source_path.to_s)
      result = ingest_pdf(
        identity: identity,
        source_path: source,
        metadata: metadata,
        aliases: aliases,
        version: version,
        source_url: source_url,
        verify_pdf: verify_pdf
      )
      if move && source != File.expand_path(result.path) && File.file?(source)
        File.delete(source)
      end
      result
    end

    def trash(reference, at = Time.now)
      with_lock do
        paper = find(reference)
        return nil unless paper

        bundle = next_trash_bundle(paper.key, at)
        Compat.mkdir_p(bundle)
        moved = []
        begin
          paper.assets.map(&:path).uniq.each do |relative|
            source = @paths.asset_path(relative)
            next unless File.file?(source)
            destination = @paths.safe_join(bundle, File.basename(source))
            File.rename(source, destination)
            moved << [source, destination]
          end

          record_source = @paths.record_path(paper.key)
          record_destination = @paths.safe_join(bundle, "record.json")
          File.rename(record_source, record_destination)
          moved << [record_source, record_destination]
        rescue
          moved.reverse_each do |source, destination|
            begin
              File.rename(destination, source) if File.exist?(destination)
            rescue SystemCallError
            end
          end
          begin
            Dir.rmdir(bundle) if Dir.exist?(bundle) && Dir.entries(bundle).length == 2
          rescue SystemCallError
          end
          raise
        end
        TrashResult.new(paper, bundle, moved.map { |_source, destination| destination })
      end
    end

    private

    def save_unlocked(paper)
      raise InvalidRecord, "expected a paper record" unless paper.is_a?(Paper)
      prepare!
      MetadataCodec.write(@paths.record_path(paper.key), paper)
      paper
    end

    def resolve_version(identity, version)
      if identity.local? && version
        raise InvalidIdentity, "local identities cannot have versions"
      end
      if version && (!version.is_a?(Integer) || version < 1)
        raise InvalidIdentity, "arXiv version must be a positive integer"
      end
      if version && identity.version && version != identity.version
        raise InvalidIdentity, "conflicting arXiv versions"
      end
      version || identity.version
    end

    def ingest_staged(identity:, staged:, copied:, metadata:, aliases:, version:,
                      source_url:, added_at:)
      versioned_identity = version ? identity.with_version(version) : identity.without_version
      identity_aliases = versioned_identity.aliases + Array(aliases)
      existing_hash = find_asset_by_hash(copied.sha256)
      paper = find_by_key(identity.canonical_key) || find_by_alias(identity.canonical_key)

      if existing_hash && (!paper || existing_hash.paper.key != paper.key)
        duplicate_paper = existing_hash.paper
        duplicate_paper.add_aliases!(identity_aliases + [identity.canonical_key])
        duplicate_paper.merge_metadata!(metadata)
        save_unlocked(duplicate_paper)
        existing_path = asset_path(existing_hash.asset)
        if File.file?(existing_path)
          File.delete(staged)
          deduplicated = true
        else
          File.rename(staged, existing_path)
          deduplicated = false
        end
        return IngestResult.new(
          duplicate_paper,
          existing_hash.asset,
          existing_path,
          deduplicated
        )
      end

      paper ||= Paper.new(identity: identity, metadata: metadata, aliases: identity_aliases)
      paper.add_aliases!(identity_aliases)
      paper.merge_metadata!(metadata)

      matching_asset = paper.asset_for_hash(copied.sha256)
      if matching_asset
        target_asset = paper.asset_for_version(version)
        if target_asset && target_asset.sha256 != copied.sha256
          raise AssetConflict, "#{paper.key} already has a different asset for this version"
        end
        unless target_asset
          target_asset = Asset.new(
            version: version,
            path: matching_asset.path,
            sha256: copied.sha256,
            size: copied.size,
            source_url: source_url,
            added_at: added_at
          )
          paper.add_asset!(target_asset)
        end
        save_unlocked(paper)
        matching_path = asset_path(matching_asset)
        if File.file?(matching_path)
          File.delete(staged)
          deduplicated = true
        else
          File.rename(staged, matching_path)
          deduplicated = false
        end
        return IngestResult.new(paper, target_asset, matching_path, deduplicated)
      end

      filename = @paths.asset_filename(versioned_identity, paper.title, version)
      destination, destination_exists = available_destination(filename, copied.sha256)
      relative_path = "library/#{File.basename(destination)}"
      asset = Asset.new(
        version: version,
        path: relative_path,
        sha256: copied.sha256,
        size: copied.size,
        source_url: source_url,
        added_at: added_at
      )

      # Detect a version conflict before publishing the staged file.
      paper.add_asset!(asset)
      published = false
      begin
        if destination_exists
          File.delete(staged)
        else
          File.rename(staged, destination)
          published = true
        end
        save_unlocked(paper)
      rescue
        begin
          File.delete(destination) if published && File.exist?(destination)
        rescue SystemCallError
        end
        raise
      end

      IngestResult.new(paper, asset, destination, destination_exists)
    end

    def available_destination(filename, sha256)
      destination = @paths.library_file(filename)
      return [destination, false] unless File.exist?(destination)
      return [destination, true] if Compat.sha256_file(destination) == sha256

      stem = filename.sub(/\.pdf\z/i, "")
      100.times do |attempt|
        suffix = "--#{sha256[0, 12]}"
        suffix += "-#{attempt}" if attempt > 0
        candidate = @paths.library_file("#{stem}#{suffix}.pdf")
        return [candidate, false] unless File.exist?(candidate)
        return [candidate, true] if Compat.sha256_file(candidate) == sha256
      end
      raise AssetConflict, "could not choose a unique PDF filename"
    end

    def next_trash_bundle(key, at)
      timestamp = Paper.timestamp(at).gsub(/[^0-9]/, "")
      label = @paths.slug(key, 64)
      100.times do |attempt|
        suffix = attempt > 0 ? "-#{attempt}" : ""
        candidate = @paths.safe_join(@paths.trash, "#{timestamp}--#{label}#{suffix}")
        return candidate unless File.exist?(candidate)
      end
      raise Error, "could not allocate a trash directory"
    end
  end
end
