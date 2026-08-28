# frozen_string_literal: true

require_relative "metadata_codec"

module Wrq
  class LibraryPaths
    attr_reader :root, :library, :state, :records, :versions, :tmp, :cache, :trash, :lock

    def self.default_root(env = nil)
      configured = environment_value(env, "WRQ_PATH").to_s.strip
      return File.expand_path(configured) unless configured.empty?

      home = environment_value(env, "HOME").to_s.strip
      return File.expand_path("papers", home) unless home.empty?
      File.expand_path("~/papers")
    end

    def self.environment_value(env, name)
      env ? env[name] : ENV[name]
    end

    def initialize(root = nil, env = nil)
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
      @versions = File.join(@state, "versions")
      @tmp = File.join(@state, "tmp")
      @cache = File.join(@state, "cache")
      @trash = File.join(@state, "trash")
      @lock = File.join(@state, "lock")
    end

    def prepare!
      [@root, @library, @state, @records, @versions, @tmp, @cache, @trash].each do |path|
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

    def version_file(filename)
      value = filename.to_s
      unless File.basename(value) == value && value.downcase.end_with?(".pdf")
        raise UnsafePath, "unsafe version PDF filename: #{filename.inspect}"
      end
      safe_join(@versions, value)
    end

    def asset_path(relative)
      value = relative.to_s
      parts = value.split("/")
      visible = parts.length == 2 && parts[0] == "library"
      retained = parts.length == 3 && parts[0] == ".wrq" && parts[1] == "versions"
      unless (visible || retained) && parts[-1].downcase.end_with?(".pdf")
        raise UnsafePath, "asset is outside managed paper storage: #{relative.inspect}"
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
    USER_METADATA_FIELDS = %w[
      venue year track status decision publication_doi tags provenance added_at
    ].freeze

    attr_reader :paths

    def self.default_root(env = nil)
      LibraryPaths.default_root(env)
    end

    def initialize(root = nil, env = nil)
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

    def with_lock(exclusive = true)
      prepare!
      lock = Compat.acquire_file_lock(@paths.lock, exclusive)
      begin
        yield
      ensure
        Compat.release_file_lock(lock)
      end
    end

    def save(paper)
      with_lock { save_unlocked(paper) }
    end

    def update(reference)
      prepare!
      lock = Compat.acquire_file_lock(@paths.lock, true)
      begin
        paper = find(reference)
        if paper
          yield paper
          paper.touch!
          save_unlocked(paper)
        else
          nil
        end
      ensure
        Compat.release_file_lock(lock)
      end
    end

    def update_metadata(reference, values)
      update(reference) { |paper| paper.merge_metadata!(values) }
    end

    def add_alias(reference, value)
      update(reference) { |paper| paper.add_alias!(value) }
    end

    def activate_asset(reference, version: nil, sha256: nil)
      with_lock do
        paper = find(reference)
        return nil unless paper
        target = if !version.nil?
                   paper.asset_for_version(version)
                 elsif sha256
                   paper.asset_for_hash(sha256)
                 else
                   paper.current_asset
                 end
        return nil unless target
        if sha256 && target.sha256 != sha256.to_s.downcase.sub(/\Asha256:/, "")
          return nil
        end

        relocations = []
        begin
          target, relocations = activate_asset_paths_unlocked(paper, target)
          paper.set_active_asset!(target)
          save_unlocked(paper)
        rescue StandardError, Interrupt
          rollback_relocations(paper, relocations)
          raise
        end
        paper
      end
    end

    def papers
      return [] unless Dir.exist?(@paths.records)

      entries = Dir.entries(@paths.records).select do |name|
        name.end_with?(".json")
      end
      entries.sort.map do |name|
        path = File.join(@paths.records, name)
        next unless File.exist?(path) || File.symlink?(path)
        paper = read_record_safely(path)
        expected = @paths.record_path(paper.key)
        unless File.expand_path(path) == File.expand_path(expected)
          raise InvalidRecord, "record filename does not match canonical key: #{path}"
        end
        paper
      end.compact
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
      return nil unless File.exist?(path) || File.symlink?(path)
      paper = read_record_safely(path)
      unless File.expand_path(path) == File.expand_path(@paths.record_path(paper.key))
        raise InvalidRecord, "record filename does not match canonical key: #{path}"
      end
      paper
    end

    def find_by_alias(value)
      needle = value.to_s.downcase
      matches = papers.select do |paper|
        paper.aliases.any? { |paper_alias| paper_alias.downcase == needle }
      end
      if matches.length > 1
        keys = matches.map(&:key).sort.join(", ")
        raise InvalidRecord, "ambiguous paper alias #{value.inspect}: #{keys}"
      end
      matches.first
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
        rescue StandardError, Interrupt
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

    def read_record_safely(path)
      if File.symlink?(path)
        raise UnsafePath, "record file cannot be a symlink: #{path}"
      end
      stat = File.lstat(path)
      unless stat.file? && stat.nlink == 1
        raise UnsafePath, "record file must be a regular unlinked file: #{path}"
      end
      MetadataCodec.read(path)
    end

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
        if identity.local?
          # A local import of bytes already attached to a canonical paper is a
          # duplicate, not a reason to create a second SHA-keyed record or to
          # replace trusted provider metadata with a filename-derived title.
          duplicate_paper = existing_hash.paper
          duplicate_paper.add_aliases!(identity_aliases)
          save_unlocked(duplicate_paper)
          return reuse_existing_asset(duplicate_paper, existing_hash.asset, staged)
        end

        if existing_hash.paper.identity.local?
          return promote_local_record(
            local_paper: existing_hash.paper,
            local_asset: existing_hash.asset,
            canonical_paper: paper,
            identity: identity,
            staged: staged,
            copied: copied,
            metadata: metadata,
            aliases: identity_aliases,
            version: version,
            source_url: source_url,
            added_at: added_at
          )
        end

        return deduplicate_external_record(
          existing: existing_hash,
          canonical_paper: paper,
          identity: identity,
          staged: staged,
          copied: copied,
          metadata: metadata,
          aliases: identity_aliases,
          version: version,
          source_url: source_url,
          added_at: added_at
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
        matching_path = asset_path(matching_asset)
        existed = File.file?(matching_path)
        unless existed
          File.rename(staged, matching_path)
        end
        relocations = []
        begin
          if paper.current_asset &&
             paper.current_asset.version == target_asset.version &&
             paper.current_asset.sha256 == target_asset.sha256
            target_asset, relocations = activate_asset_paths_unlocked(paper, target_asset)
            paper.set_active_asset!(target_asset, touch: false)
          end
          save_unlocked(paper)
          File.delete(staged) if existed && File.exist?(staged)
        rescue StandardError, Interrupt
          rollback_relocations(paper, relocations)
          raise
        end
        return IngestResult.new(
          paper,
          target_asset,
          asset_path(target_asset),
          existed
        )
      end

      filename = @paths.asset_filename(versioned_identity, paper.title, version)
      previous_active = paper.current_asset
      incoming_is_active = previous_active.nil? ||
        ([version || 0, added_at.to_s] <=>
          [previous_active.version || 0, previous_active.added_at]) == 1
      destination, destination_exists = available_destination(
        filename,
        copied.sha256,
        retained: !incoming_is_active
      )
      relative_path = relative_asset_path(destination)
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
      relocation = nil
      begin
        if incoming_is_active && previous_active
          relocation = archive_visible_asset(paper, previous_active)
        end
        if destination_exists
          File.delete(staged)
        else
          File.rename(staged, destination)
          published = true
        end
        save_unlocked(paper)
      rescue StandardError, Interrupt
        begin
          File.delete(destination) if published && File.exist?(destination)
        rescue SystemCallError
        end
        rollback_asset_relocation(paper, relocation) if relocation
        raise
      end

      IngestResult.new(paper, asset, destination, destination_exists)
    end

    def reuse_existing_asset(paper, asset, staged)
      existing_path = asset_path(asset)
      if File.file?(existing_path)
        File.delete(staged)
        deduplicated = true
      else
        File.rename(staged, existing_path)
        deduplicated = false
      end
      IngestResult.new(paper, asset, existing_path, deduplicated)
    end

    def promote_local_record(local_paper:, local_asset:, canonical_paper:, identity:,
                             staged:, copied:, metadata:, aliases:, version:,
                             source_url:, added_at:)
      merged_metadata = local_paper.metadata.dup
      metadata.each { |key, value| merged_metadata[key.to_s] = value }
      USER_METADATA_FIELDS.each do |key|
        if local_paper.metadata.key?(key)
          merged_metadata[key] = local_paper.metadata[key]
        end
      end

      promoted_asset = Asset.new(
        version: version,
        path: local_asset.path,
        sha256: copied.sha256,
        size: copied.size,
        source_url: source_url,
        added_at: added_at || local_asset.added_at
      )

      canonical_before = canonical_paper && Paper.from_h(canonical_paper.to_h)
      promoted = if canonical_paper
                   Paper.from_h(canonical_paper.to_h)
                 else
                   Paper.new(
                     identity: identity,
                     metadata: merged_metadata,
                     aliases: local_paper.aliases + aliases,
                     assets: []
                   )
                 end
      previous_active = promoted.current_asset
      if canonical_paper
        preserved = {}
        USER_METADATA_FIELDS.each do |key|
          preserved[key] = canonical_paper.metadata[key] if canonical_paper.metadata.key?(key)
        end
        promoted.merge_metadata!(merged_metadata)
        promoted.merge_metadata!(preserved)
        promoted.add_aliases!(local_paper.aliases + aliases)
      end
      promoted.add_asset!(promoted_asset)
      local_record_path = @paths.record_path(local_paper.key)
      canonical_record_path = @paths.record_path(promoted.key)
      incoming_is_active = previous_active.nil? ||
        ([version || 0, promoted_asset.added_at] <=>
          [previous_active.version || 0, previous_active.added_at]) == 1
      relocations = []
      canonical_saved = false
      local_deleted = false
      begin
        File.delete(staged) if File.exist?(staged)
        if incoming_is_active
          promoted_asset, relocations = activate_asset_paths_unlocked(
            promoted,
            promoted_asset
          )
          promoted.set_active_asset!(promoted_asset, touch: false)
        elsif promoted_asset.path.start_with?("library/")
          relocation = archive_visible_asset(promoted, promoted_asset)
          relocations << relocation if relocation
          promoted_asset = promoted.asset_for_version(version)
        end

        save_unlocked(promoted)
        canonical_saved = true
        if File.file?(local_record_path)
          File.delete(local_record_path)
          local_deleted = true
        end
      rescue StandardError, Interrupt
        rollback_relocations(promoted, relocations)
        begin
          if canonical_saved
            if canonical_before
              save_unlocked(canonical_before)
            elsif File.file?(canonical_record_path)
              File.delete(canonical_record_path)
            end
          end
          if local_deleted || !File.file?(local_record_path)
            save_unlocked(local_paper)
          end
        rescue StandardError
          # Preserve the original failure. doctor can report an incomplete
          # record rollback if the filesystem also refuses recovery writes.
        end
        raise
      end
      IngestResult.new(promoted, promoted_asset, asset_path(promoted_asset), true)
    end

    def deduplicate_external_record(existing:, canonical_paper:, identity:, staged:,
                                    copied:, metadata:, aliases:, version:,
                                    source_url:, added_at:)
      paper = canonical_paper || Paper.new(
        identity: identity,
        metadata: metadata,
        aliases: aliases
      )
      paper.add_aliases!(aliases)
      paper.merge_metadata!(metadata)
      previous_active = paper.current_asset
      incoming_is_active = previous_active.nil? ||
        ([version || 0, added_at.to_s] <=>
          [previous_active.version || 0, previous_active.added_at]) == 1
      filename = @paths.asset_filename(identity.with_version(version), paper.title, version)
      destination, destination_exists = available_destination(
        filename,
        copied.sha256,
        retained: !incoming_is_active
      )
      asset = Asset.new(
        version: version,
        path: relative_asset_path(destination),
        sha256: copied.sha256,
        size: copied.size,
        source_url: source_url,
        added_at: added_at
      )
      paper.add_asset!(asset)

      published = false
      relocation = nil
      begin
        File.delete(staged) if File.exist?(staged)
        unless destination_exists
          source = asset_path(existing.asset)
          begin
            File.link(source, destination)
          rescue SystemCallError
            Compat.copy_with_sha256(source, destination)
          end
          published = true
        end
        relocation = archive_visible_asset(paper, previous_active) if incoming_is_active && previous_active
        save_unlocked(paper)
      rescue StandardError, Interrupt
        begin
          File.delete(destination) if published && File.exist?(destination)
        rescue SystemCallError
        end
        rollback_asset_relocation(paper, relocation) if relocation
        raise
      end
      IngestResult.new(paper, asset, destination, true)
    end

    def available_destination(filename, sha256, retained: false)
      destination = retained ? @paths.version_file(filename) : @paths.library_file(filename)
      return [destination, false] unless File.exist?(destination)
      return [destination, true] if Compat.sha256_file(destination) == sha256

      stem = filename.sub(/\.pdf\z/i, "")
      100.times do |attempt|
        suffix = "--#{sha256[0, 12]}"
        suffix += "-#{attempt}" if attempt > 0
        candidate = if retained
                      @paths.version_file("#{stem}#{suffix}.pdf")
                    else
                      @paths.library_file("#{stem}#{suffix}.pdf")
                    end
        return [candidate, false] unless File.exist?(candidate)
        return [candidate, true] if Compat.sha256_file(candidate) == sha256
      end
      raise AssetConflict, "could not choose a unique PDF filename"
    end

    def archive_visible_asset(paper, asset)
      return nil unless asset.path.start_with?("library/")

      source = @paths.asset_path(asset.path)
      return nil unless File.file?(source)
      destination, destination_exists = available_destination(
        File.basename(source),
        asset.sha256,
        retained: true
      )
      old_path = asset.path
      relocation = {
        old_path: old_path,
        new_path: relative_asset_path(destination),
        source: source,
        destination: destination,
        destination_existed: destination_exists
      }
      begin
        if destination_exists
          File.delete(source)
        else
          File.rename(source, destination)
        end
        paper.relocate_asset_path!(old_path, relocation[:new_path], touch: false)
      rescue StandardError, Interrupt
        rollback_asset_relocation(paper, relocation)
        raise
      end
      relocation
    end

    def rollback_asset_relocation(paper, relocation)
      if relocation[:destination_existed]
        # The retained copy predated this transaction. Restore the visible copy
        # from it without removing the pre-existing retained file.
        File.open(relocation[:destination], "rb") do |source|
          File.open(relocation[:source], "wbx", 0o600) do |destination|
            loop do
              begin
                chunk = source.readpartial(Compat::COPY_CHUNK_SIZE)
              rescue EOFError
                break
              end
              destination.write(chunk)
            end
          end
        end
      elsif File.file?(relocation[:destination])
        File.rename(relocation[:destination], relocation[:source])
      end
      if paper.assets.any? { |asset| asset.path == relocation[:new_path] }
        paper.relocate_asset_path!(relocation[:new_path], relocation[:old_path], touch: false)
      end
    rescue SystemCallError, InvalidRecord
      # Preserve the original exception. doctor will report either path if the
      # filesystem itself prevents rollback.
    end


    def activate_asset_paths_unlocked(paper, target)
      relocations = []
      visible_paths = paper.assets.map(&:path).select do |path|
        path.start_with?("library/") && path != target.path
      end.uniq

      visible_paths.each do |path|
        visible_asset = paper.assets.find { |asset| asset.path == path }
        relocation = archive_visible_asset(paper, visible_asset)
        relocations << relocation if relocation
      end

      target = paper.assets.find do |asset|
        asset.version == target.version && asset.sha256 == target.sha256
      end
      if target && target.path.start_with?(".wrq/versions/")
        source = @paths.asset_path(target.path)
        raise InvalidRecord, "stored inactive asset is missing: #{source}" unless File.file?(source)
        destination, destination_exists = available_destination(
          File.basename(source),
          target.sha256,
          retained: false
        )
        old_path = target.path
        new_path = relative_asset_path(destination)
        relocation = {
          old_path: old_path,
          new_path: new_path,
          source: source,
          destination: destination,
          destination_existed: destination_exists
        }
        relocations << relocation
        if destination_exists
          File.delete(source)
        else
          File.rename(source, destination)
        end
        paper.relocate_asset_path!(old_path, new_path, touch: false)
        target = paper.assets.find do |asset|
          asset.version == target.version && asset.sha256 == target.sha256 && asset.path == new_path
        end
      end
      [target, relocations]
    rescue StandardError, Interrupt
      rollback_relocations(paper, relocations)
      raise
    end

    def rollback_relocations(paper, relocations)
      relocations.reverse_each do |relocation|
        rollback_asset_relocation(paper, relocation)
      end
    end

    def relative_asset_path(path)
      expanded = File.expand_path(path)
      root_prefix = @paths.root.end_with?(File::SEPARATOR) ? @paths.root : @paths.root + File::SEPARATOR
      unless expanded.start_with?(root_prefix)
        raise UnsafePath, "asset path escapes library root: #{path}"
      end
      expanded[root_prefix.length..-1]
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
