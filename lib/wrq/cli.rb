# frozen_string_literal: true

require "json"
require "time"
require_relative "version"
require_relative "library"
require_relative "opener"
require_relative "search"
require_relative "selector"
require_relative "sources/arxiv"
require_relative "sources/hugging_face"

module Wrq
  class UsageError < Error; end

  # Command dispatcher for the local paper library. Helpers return values and
  # statuses; only the executable entrypoint calls exit.
  class CLI
    COMMANDS = %w[add open search import info meta dedupe update remove doctor].freeze
    MAX_PDF_BYTES = 512 * 1024 * 1024

    HELP = <<~TEXT
      wrq v#{VERSION} - local-first research paper library

      Usage:
        wrq                              Browse the local library
        wrq <arxiv-id-or-url>            Open, or download then open
        wrq <hugging-face-paper-url>      Resolve through arXiv and enrich from HF
        wrq <query>                       Fuzzy-search local papers
        wrq add REFERENCE [--no-open]     Explicitly add a paper
        wrq open SELECTOR                 Open an existing paper
        wrq search [QUERY]                Search the local library
        wrq import PATH...                Import PDF files or directories
        wrq info SELECTOR                 Show stored metadata
        wrq meta SELECTOR [OPTIONS]       Edit venue, status, DOI, and tags
        wrq dedupe [PATH]                 Report duplicates without deleting
        wrq update SELECTOR | --all       Refresh metadata and newer versions
        wrq remove SELECTOR               Move a paper to recoverable trash
        wrq doctor [--fix]                Validate and repair local state

      Global options:
        --path PATH       Override WRQ_PATH (default: ~/papers)
        --json            Print machine-readable JSON
        --no-open         Do not launch the PDF viewer
        --print-path      Print the selected PDF path instead of opening it
        --no-colors       Disable ANSI colors
        --help, -h        Show help
        --version, -v     Show version

      Import options:
        --recursive       Recurse into imported directories
        --move            Remove each source only after successful import

      Metadata options:
        --venue NAME      Publication venue or conference
        --year YEAR       Venue/publication year
        --track NAME      Conference track
        --status STATUS   Reading or publication status
        --decision VALUE  Acceptance decision
        --doi DOI         Publication DOI
        --tag TAG         Add a tag (repeatable)
        --remove-tag TAG  Remove a tag (repeatable)

      Environment:
        WRQ_PATH          Library root (default: ~/papers)
        WRQ_OPENER        Viewer executable (default: open/xdg-open/start)
        HF_TOKEN          Optional Hugging Face token for higher quotas
    TEXT

    def initialize(stdout: STDOUT, stderr: STDERR, stdin: STDIN, env: ENV,
                   library: nil, arxiv_source: nil, hugging_face_source: nil,
                   opener: nil, selector_class: Selector, clock: nil)
      @stdout = stdout
      @stderr = stderr
      @stdin = stdin
      @env = env
      @library_override = library
      @arxiv_override = arxiv_source
      @hugging_face_override = hugging_face_source
      @opener = opener || Opener.new(env: env)
      @selector_class = selector_class
      @clock = clock || proc { Time.now }
      @options = {}
    end

    def run(arguments)
      args = arguments.to_a.map(&:to_s)
      @options = parse_global_options!(args)

      if @options[:help]
        @stdout.print(HELP)
        return 0
      end
      if @options[:version]
        @stdout.puts("wrq #{VERSION}")
        return 0
      end

      Tui.disable_colors! if @options[:no_colors]
      Tui.disable_colors! if !@env['NO_COLOR'].to_s.empty?

      command = args.shift
      return browse("") if command.nil?

      case command
      when "add" then command_add(args)
      when "open" then command_open(args)
      when "search" then command_search(args)
      when "import" then command_import(args)
      when "info" then command_info(args)
      when "meta" then command_meta(args)
      when "dedupe" then command_dedupe(args)
      when "update" then command_update(args)
      when "remove" then command_remove(args)
      when "doctor" then command_doctor(args)
      else shorthand(([command] + args).join(" "))
      end
    rescue UsageError => error
      @stderr.puts("Error: #{error.message}")
      @stderr.puts("Run 'wrq --help' for usage.")
      2
    rescue Interrupt
      @stderr.puts("Cancelled.")
      1
    rescue StandardError => error
      @stderr.puts("Error: #{error.message}")
      if debug?
        error.backtrace.to_a.each { |line| @stderr.puts("  #{line}") }
      end
      1
    end

    private

    def parse_global_options!(args)
      {
        path: extract_value!(args, "--path"),
        json: extract_flag!(args, "--json"),
        no_open: extract_flag!(args, "--no-open"),
        print_path: extract_flag!(args, "--print-path"),
        no_colors: extract_flag!(args, "--no-colors"),
        help: extract_flag!(args, "--help") || extract_flag!(args, "-h"),
        version: extract_flag!(args, "--version") || extract_flag!(args, "-v")
      }
    end

    def extract_flag!(args, name)
      found = false
      index = args.length - 1
      while index >= 0
        if args[index] == name
          args.delete_at(index)
          found = true
        end
        index -= 1
      end
      found
    end

    def extract_value!(args, name)
      found = nil
      index = 0
      while index < args.length
        argument = args[index]
        if argument == name
          raise UsageError, "#{name} requires a value" unless args[index + 1]
          found = args[index + 1]
          args.slice!(index, 2)
          next
        elsif argument.start_with?("#{name}=")
          found = argument[(name.length + 1)..-1]
          raise UsageError, "#{name} requires a value" if found.to_s.empty?
          args.delete_at(index)
          next
        end
        index += 1
      end
      found
    end

    def extract_values!(args, name)
      values = []
      loop do
        value = extract_first_value!(args, name)
        break if value.nil?
        values << value
      end
      values
    end

    def extract_first_value!(args, name)
      args.each_with_index do |argument, index|
        if argument == name
          raise UsageError, "#{name} requires a value" unless args[index + 1]
          value = args[index + 1]
          args.slice!(index, 2)
          return value
        elsif argument.start_with?("#{name}=")
          value = argument[(name.length + 1)..-1]
          raise UsageError, "#{name} requires a value" if value.to_s.empty?
          args.delete_at(index)
          return value
        end
      end
      nil
    end

    def library
      @library ||= @library_override || Library.new(@options[:path], @env)
    end

    def arxiv_source
      return @arxiv_override if @arxiv_override
      @arxiv_source ||= begin
        library.prepare!
        throttle_path = File.join(library.paths.cache, "arxiv-api.throttle")
        Sources::Arxiv.new(throttle: Throttle.new(path: throttle_path))
      end
    end

    def hugging_face_source
      @hugging_face_source ||= @hugging_face_override || Sources::HuggingFace.new
    end

    def shorthand(value)
      identity = Identity.recognize(value)
      return add_or_open_reference(value) if identity && identity.arxiv?
      browse(value)
    end

    def command_add(args)
      raise UsageError, "add requires one paper reference" if args.empty?
      raise UsageError, "add accepts one paper reference" if args.length > 1
      identity = Identity.parse(args.first)
      raise UsageError, "add requires an arXiv or Hugging Face reference" unless identity.arxiv?
      add_or_open_reference(args.first)
    end

    def command_open(args)
      raise UsageError, "open requires a selector" if args.empty?
      paper = resolve_one(args.join(" "))
      return not_found(args.join(" ")) unless paper
      finish_paper(paper)
    end

    def command_search(args)
      browse(args.join(" "))
    end

    def command_import(args)
      recursive = extract_flag!(args, "--recursive")
      move = extract_flag!(args, "--move")
      raise UsageError, "import requires at least one PDF file or directory" if args.empty?

      files = collect_pdf_files(args, recursive: recursive)
      raise Error, "no PDF files found" if files.empty?
      results = []

      files.each do |source|
        identity = identity_from_filename(source)
        title = title_from_filename(source, identity)
        metadata = {
          "title" => title,
          "authors" => [],
          "tags" => [],
          "status" => "unread",
          "imported_from" => source,
          "added_at" => timestamp
        }
        result = library.import_pdf(
          source_path: source,
          identity: identity && identity.without_version,
          version: identity && identity.version,
          metadata: metadata,
          aliases: [source, File.basename(source)],
          move: move
        )
        row = ingest_result_hash(result).merge("source" => source)
        results << row
        unless @options[:json]
          action = result.deduplicated? ? "Already cataloged" : "Imported"
          @stdout.puts("#{action}: #{source} -> #{result.path}")
        end
      end

      emit_json(results) if @options[:json]
      0
    end

    def command_info(args)
      raise UsageError, "info requires a selector" if args.empty?
      paper = resolve_one(args.join(" "))
      return not_found(args.join(" ")) unless paper

      payload = paper_payload(paper)
      if @options[:json]
        emit_json(payload)
      else
        print_paper_info(payload)
      end
      0
    end

    def command_meta(args)
      venue = extract_value!(args, "--venue")
      year = extract_value!(args, "--year")
      track = extract_value!(args, "--track")
      status = extract_value!(args, "--status")
      decision = extract_value!(args, "--decision")
      publication_doi = extract_value!(args, "--doi")
      add_tags = extract_values!(args, "--tag")
      remove_tags = extract_values!(args, "--remove-tag")
      raise UsageError, "meta requires a selector" if args.empty?
      selector = args.join(" ")
      paper = resolve_one(selector)
      return not_found(selector) unless paper

      changes = {}
      changes["venue"] = venue unless venue.nil?
      unless year.nil?
        raise UsageError, "--year must be four digits" unless year.match?(/\A\d{4}\z/)
        changes["year"] = year.to_i
      end
      changes["track"] = track unless track.nil?
      changes["status"] = status unless status.nil?
      changes["decision"] = decision unless decision.nil?
      unless publication_doi.nil?
        doi = publication_doi.sub(/\Ahttps?:\/\/(?:dx\.)?doi\.org\//i, "")
        raise UsageError, "--doi must look like a DOI" unless doi.match?(/\A10\.\d{4,9}\/.+/)
        changes["publication_doi"] = doi
      end

      tags = Array(paper.metadata["tags"]).map(&:to_s)
      add_tags.each { |tag| tags << tag unless tags.include?(tag) }
      remove_tags.each { |tag| tags.delete(tag) }
      changes["tags"] = tags unless add_tags.empty? && remove_tags.empty?
      if changes.empty?
        raise UsageError, "meta requires at least one metadata option"
      end

      provenance = paper.metadata["provenance"]
      provenance = {} unless provenance.is_a?(Hash)
      changes.keys.each { |key| provenance[key] = "manual" unless key == "tags" }
      changes["provenance"] = provenance
      paper.merge_metadata!(changes)
      library.save(paper)

      if @options[:json]
        emit_json(paper_payload(paper))
      else
        @stdout.puts("Updated metadata: #{paper.key}")
      end
      0
    end

    def command_dedupe(args)
      recursive = extract_flag!(args, "--recursive")
      raise UsageError, "dedupe accepts at most one path" if args.length > 1

      papers = library.papers
      hash_groups = {}
      papers.each do |paper|
        paper.assets.each do |asset|
          hash_groups[asset.sha256] ||= []
          hash_groups[asset.sha256] << {
            "paper" => paper.key,
            "path" => library.asset_path(asset),
            "version" => asset.version
          }
        end
      end
      exact = hash_groups.select { |_hash, values| values.length > 1 }

      title_groups = {}
      papers.each do |paper|
        normalized = normalize_title(paper.title)
        next if normalized.empty?
        title_groups[normalized] ||= []
        title_groups[normalized] << paper.key
      end
      probable = title_groups.select { |_title, keys| keys.uniq.length > 1 }

      external = []
      unless args.empty?
        collect_pdf_files(args, recursive: recursive).each do |path|
          hash = library.sha256(path)
          lookup = library.find_asset_by_hash(hash)
          external << {
            "path" => path,
            "sha256" => hash,
            "duplicate_of" => lookup && lookup.paper.key,
            "library_path" => lookup && library.asset_path(lookup.asset)
          }
        end
      end

      report = {
        "exact_hash_groups" => exact,
        "probable_title_groups" => probable,
        "external_files" => external,
        "deleted" => []
      }
      if @options[:json]
        emit_json(report)
      else
        print_dedupe_report(report)
      end
      0
    end

    def command_update(args)
      update_all = extract_flag!(args, "--all")
      enrich_hf = extract_flag!(args, "--hf")
      if update_all
        raise UsageError, "update --all does not accept a selector" unless args.empty?
        papers = library.papers.select { |paper| paper.identity.arxiv? }
      else
        raise UsageError, "update requires a selector or --all" if args.empty?
        paper = resolve_one(args.join(" "))
        return not_found(args.join(" ")) unless paper
        raise Error, "local-only papers cannot be updated from arXiv" unless paper.identity.arxiv?
        papers = [paper]
      end

      rows = papers.map { |paper| refresh_paper(paper, enrich_hf: enrich_hf) }
      if @options[:json]
        emit_json(rows)
      else
        rows.each do |row|
          @stdout.puts("Updated #{row['key']}: #{row['version'] || 'unversioned'}#{row['downloaded'] ? ' (downloaded)' : ''}")
        end
      end
      0
    end

    def command_remove(args)
      yes = extract_flag!(args, "--yes")
      raise UsageError, "remove requires a selector" if args.empty?
      selector = args.join(" ")
      paper = resolve_one(selector)
      return not_found(selector) unless paper

      unless yes
        @stderr.puts("Move #{paper.key} and #{paper.assets.length} asset(s) to trash?")
        @stderr.print("Type YES to confirm: ")
        confirmation = @stdin.gets.to_s.chomp
        unless confirmation == "YES"
          @stderr.puts("Cancelled.")
          return 1
        end
      end

      result = library.trash(paper.key)
      raise Error, "paper disappeared before removal" unless result
      if @options[:json]
        emit_json({ "key" => paper.key, "trash_path" => result.path, "files" => result.files })
      else
        @stdout.puts("Moved to trash: #{result.path}")
      end
      0
    end

    def command_doctor(args)
      fix = extract_flag!(args, "--fix")
      raise UsageError, "doctor does not accept positional arguments" unless args.empty?
      report = doctor_report(fix: fix)
      if @options[:json]
        emit_json(report)
      else
        print_doctor_report(report)
      end
      report["errors"].empty? ? 0 : 1
    end

    def browse(query)
      records = library.papers
      if @options[:json]
        results = Search.new(records, now: now).call(query)
        emit_json(results.map { |result| search_result_payload(result) })
        return 0
      end

      # Path-oriented invocations are useful in scripts and cannot display a
      # TUI. Resolve the highest-ranked local result deterministically.
      if @options[:print_path] || @options[:no_open]
        paper = resolve_one(query)
        return not_found(query) unless paper
        return finish_paper(paper)
      end

      result = @selector_class.new(records, query: query).run
      case result[:action]
      when :select
        finish_paper(result[:record])
      when :cancel
        @stderr.puts("Cancelled.")
        1
      else
        1
      end
    end

    def add_or_open_reference(reference)
      identity = Identity.parse(reference)
      paper = library.find(identity.canonical_key) || library.find(reference)
      if paper
        asset = identity.version ? paper.asset_for_version(identity.version) : paper.current_asset
        return finish_paper(paper, asset: asset) if asset && File.file?(library.asset_path(asset))
      end

      metadata = arxiv_source.fetch(identity.versioned_id)
      canonical = Identity.parse(metadata[:base_id]).without_version
      resolved_version = metadata[:resolved_version] || identity.version
      record_metadata = arxiv_record_metadata(metadata)

      if hugging_face_reference?(reference)
        begin
          hf = hugging_face_source.fetch(canonical.base_id)
          record_metadata = merge_hugging_face(record_metadata, hf) if hf
        rescue StandardError => error
          @stderr.puts("Warning: Hugging Face enrichment failed: #{error.message}")
        end
      end

      library.prepare!
      temporary = library.paths.temporary_path("arxiv-download")
      begin
        arxiv_source.download(metadata, destination: temporary, max_bytes: MAX_PDF_BYTES)
        result = library.ingest_pdf(
          identity: canonical,
          source_path: temporary,
          metadata: record_metadata,
          aliases: Array(metadata[:aliases]) + [reference],
          version: resolved_version,
          source_url: metadata[:pdf_url]
        )
      ensure
        begin
          File.delete(temporary) if temporary && File.exist?(temporary)
        rescue SystemCallError
        end
      end

      unless @options[:json] || @options[:print_path]
        action = result.deduplicated? ? "Already cataloged" : "Downloaded"
        @stdout.puts("#{action}: #{result.paper.key}")
      end
      finish_paper(result.paper, asset: result.asset)
    end

    def refresh_paper(paper, enrich_hf: false)
      metadata = arxiv_source.fetch(paper.identity.base_id)
      resolved_version = metadata[:resolved_version]
      record_metadata = arxiv_record_metadata(metadata)
      if enrich_hf || paper.metadata.dig("provider_data", "hugging_face")
        begin
          hf = hugging_face_source.fetch(paper.identity.base_id)
          record_metadata = merge_hugging_face(record_metadata, hf) if hf
        rescue StandardError => error
          @stderr.puts("Warning: Hugging Face enrichment failed for #{paper.key}: #{error.message}")
        end
      end

      existing = resolved_version && paper.asset_for_version(resolved_version)
      downloaded = false
      if existing && File.file?(library.asset_path(existing))
        paper.merge_metadata!(record_metadata)
        paper.add_aliases!(Array(metadata[:aliases]))
        library.save(paper)
      else
        temporary = library.paths.temporary_path("arxiv-update")
        begin
          arxiv_source.download(metadata, destination: temporary, max_bytes: MAX_PDF_BYTES)
          result = library.ingest_pdf(
            identity: paper.identity,
            source_path: temporary,
            metadata: record_metadata,
            aliases: Array(metadata[:aliases]),
            version: resolved_version,
            source_url: metadata[:pdf_url]
          )
          paper = result.paper
          downloaded = !result.deduplicated?
        ensure
          begin
            File.delete(temporary) if temporary && File.exist?(temporary)
          rescue SystemCallError
          end
        end
      end
      { "key" => paper.key, "version" => resolved_version, "downloaded" => downloaded }
    end

    def finish_paper(paper, asset: nil)
      asset ||= paper.current_asset
      raise Error, "paper has no stored PDF: #{paper.key}" unless asset
      path = library.asset_path(asset)
      raise Error, "stored PDF is missing: #{path}" unless File.file?(path)

      paper.merge_metadata!({ "last_opened_at" => timestamp }) unless @options[:no_open]
      library.save(paper)

      if @options[:json]
        emit_json(paper_payload(paper).merge("selected_path" => path))
      elsif @options[:print_path]
        @stdout.puts(path)
      elsif @options[:no_open]
        @stdout.puts("Stored: #{path}")
      else
        @opener.open(path)
        @stdout.puts("Opened: #{paper.key}")
      end
      0
    end

    def resolve_one(selector)
      value = selector.to_s.strip
      exact = library.find(value)
      return exact if exact
      return nil if value.empty? && library.papers.empty?

      result = Search.new(library.papers, now: now).call(value, limit: 1).first
      result && result.record
    end

    def arxiv_record_metadata(metadata)
      keys = [
        :title, :authors, :abstract, :categories, :primary_category,
        :published_at, :updated_at, :comment, :journal_ref, :publication_doi,
        :abstract_url, :pdf_url, :requested_id, :requested_version,
        :resolved_id, :resolved_version
      ]
      record = {}
      keys.each do |key|
        value = metadata[key]
        record[key.to_s] = deep_stringify(value) unless value.nil?
      end
      record["provider_data"] = deep_stringify(metadata[:provider_data] || {})
      record["tags"] ||= []
      record["status"] ||= "unread"
      record["added_at"] ||= timestamp
      record
    end

    def merge_hugging_face(record_metadata, hf)
      merged = deep_copy(record_metadata)
      provider_data = merged["provider_data"]
      provider_data = {} unless provider_data.is_a?(Hash)
      hf_provider = hf[:provider_data] || hf["provider_data"] || { "hugging_face" => hf }
      hf_provider = deep_stringify(hf_provider)
      provider_data.merge!(hf_provider)
      merged["provider_data"] = provider_data

      {
        "hf_summary" => hf[:summary],
        "hf_ai_summary" => hf[:ai_summary],
        "hf_keywords" => hf[:ai_keywords],
        "hf_upvotes" => hf[:upvotes],
        "hf_authors" => hf[:hf_authors],
        "project_page" => hf[:project_page],
        "github_repo" => hf[:github_repo],
        "hf_url" => hf[:hf_url],
        "related_models" => hf[:models],
        "related_datasets" => hf[:datasets],
        "related_spaces" => hf[:spaces]
      }.each do |key, value|
        merged[key] = deep_stringify(value) unless value.nil?
      end
      merged
    end

    def paper_payload(paper)
      value = paper.to_h
      value["asset_paths"] = paper.assets.map { |asset| library.asset_path(asset) }
      current = paper.current_asset
      value["current_path"] = current && library.asset_path(current)
      value
    end

    def ingest_result_hash(result)
      {
        "key" => result.paper.key,
        "path" => result.path,
        "sha256" => result.asset.sha256,
        "version" => result.asset.version,
        "deduplicated" => result.deduplicated?
      }
    end

    def search_result_payload(result)
      {
        "score" => result.score,
        "matched_field" => result.matched_field,
        "title_highlight_positions" => result.highlight_positions,
        "paper" => paper_payload(result.record)
      }
    end

    def collect_pdf_files(paths, recursive: false)
      found = []
      paths.each do |input|
        path = File.expand_path(input)
        if File.file?(path)
          raise Error, "not a PDF file: #{input}" unless path.downcase.end_with?(".pdf")
          found << path
        elsif Dir.exist?(path)
          if recursive
            walk_pdf_directory(path, found)
          else
            Dir.entries(path).sort.each do |name|
              next if name == "." || name == ".."
              child = File.join(path, name)
              found << child if File.file?(child) && child.downcase.end_with?(".pdf")
            end
          end
        else
          raise Error, "path does not exist: #{input}"
        end
      end
      found.map { |path| File.expand_path(path) }.uniq.sort
    end

    def walk_pdf_directory(path, found)
      Dir.entries(path).sort.each do |name|
        next if name == "." || name == ".." || name == ".wrq"
        child = File.join(path, name)
        if File.directory?(child) && !File.symlink?(child)
          walk_pdf_directory(child, found)
        elsif File.file?(child) && child.downcase.end_with?(".pdf")
          found << child
        end
      end
    end

    def identity_from_filename(path)
      basename = File.basename(path, File.extname(path))
      modern = basename.match(/(?:\A|[^0-9])(\d{4}\.\d{4,6}(?:v[1-9]\d*)?)(?:\z|[^0-9])/i)
      return Identity.recognize(modern[1]) if modern
      nil
    end

    def title_from_filename(path, identity)
      title = File.basename(path, File.extname(path))
      if identity
        title = title.gsub(identity.versioned_id, "")
        title = title.gsub(identity.base_id, "")
      end
      title = title.gsub(/[_-]+/, " ").gsub(/\s+/, " ").strip
      title.empty? ? "Untitled paper" : title
    end

    def normalize_title(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").strip
    end

    def doctor_report(fix: false)
      library.prepare!
      errors = []
      warnings = []
      checked_records = 0
      checked_assets = 0

      entries = Dir.entries(library.paths.records).select { |name| name.end_with?(".json") }.sort
      entries.each do |name|
        path = File.join(library.paths.records, name)
        begin
          paper = MetadataCodec.read(path)
          checked_records += 1
          paper.assets.each do |asset|
            checked_assets += 1
            asset_path = library.asset_path(asset)
            unless File.file?(asset_path)
              errors << "missing asset for #{paper.key}: #{asset_path}"
              next
            end
            actual = library.sha256(asset_path)
            errors << "hash mismatch for #{paper.key}: #{asset_path}" unless actual == asset.sha256
          end
        rescue StandardError => error
          errors << "invalid record #{path}: #{error.message}"
        end
      end

      abandoned = Dir.entries(library.paths.tmp).select do |name|
        name != "." && name != ".." && File.file?(File.join(library.paths.tmp, name))
      end
      if fix
        abandoned.each do |name|
          begin
            File.delete(File.join(library.paths.tmp, name))
          rescue SystemCallError => error
            errors << "could not remove temporary file #{name}: #{error.message}"
          end
        end
      elsif !abandoned.empty?
        warnings << "#{abandoned.length} abandoned temporary file(s)"
      end

      {
        "root" => library.root,
        "checked_records" => checked_records,
        "checked_assets" => checked_assets,
        "errors" => errors,
        "warnings" => warnings,
        "removed_temporary_files" => fix ? abandoned.length : 0
      }
    end

    def print_paper_info(payload)
      metadata = payload["metadata"] || {}
      @stdout.puts(metadata["title"].to_s.empty? ? payload["key"] : metadata["title"])
      @stdout.puts("ID: #{payload['key']}")
      authors = Array(metadata["authors"])
      @stdout.puts("Authors: #{authors.join(', ')}") unless authors.empty?
      @stdout.puts("Venue: #{metadata['venue']}") if metadata["venue"]
      @stdout.puts("Year: #{metadata['year']}") if metadata["year"]
      @stdout.puts("Status: #{metadata['status']}") if metadata["status"]
      @stdout.puts("DOI: #{metadata['publication_doi']}") if metadata["publication_doi"]
      @stdout.puts("Tags: #{Array(metadata['tags']).join(', ')}") unless Array(metadata["tags"]).empty?
      @stdout.puts("PDF: #{payload['current_path']}") if payload["current_path"]
      @stdout.puts
      @stdout.puts(metadata["abstract"]) if metadata["abstract"]
    end

    def print_dedupe_report(report)
      exact = report["exact_hash_groups"]
      probable = report["probable_title_groups"]
      external = report["external_files"]
      @stdout.puts("Exact duplicate hash groups: #{exact.length}")
      exact.each { |hash, rows| @stdout.puts("  #{hash}: #{rows.map { |row| row['path'] }.join(', ')}") }
      @stdout.puts("Probable duplicate title groups: #{probable.length}")
      probable.each { |title, keys| @stdout.puts("  #{title}: #{keys.join(', ')}") }
      external.each do |row|
        state = row["duplicate_of"] ? "duplicate of #{row['duplicate_of']}" : "new"
        @stdout.puts("  #{row['path']}: #{state}")
      end
      @stdout.puts("No files were deleted.")
    end

    def print_doctor_report(report)
      @stdout.puts("Library: #{report['root']}")
      @stdout.puts("Checked #{report['checked_records']} record(s), #{report['checked_assets']} asset(s)")
      report["warnings"].each { |warning| @stdout.puts("Warning: #{warning}") }
      report["errors"].each { |error| @stdout.puts("Error: #{error}") }
      @stdout.puts("Removed #{report['removed_temporary_files']} temporary file(s)") if report["removed_temporary_files"] > 0
      @stdout.puts("OK") if report["errors"].empty?
    end

    def emit_json(value)
      @stdout.puts(JSON.pretty_generate(value))
    end

    def not_found(selector)
      @stderr.puts("Error: no paper matches #{selector.inspect}")
      1
    end

    def deep_stringify(value)
      case value
      when Hash
        result = {}
        value.each { |key, item| result[key.to_s] = deep_stringify(item) }
        result
      when Array
        value.map { |item| deep_stringify(item) }
      else
        value
      end
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end

    def hugging_face_reference?(value)
      value.to_s.match?(%r{\Ahttps?://(?:www\.)?(?:huggingface\.co|hf\.co)/papers/}i)
    end

    def now
      @clock.call
    end

    def timestamp
      Paper.timestamp(now)
    end

    def debug?
      value = @env['WRQ_DEBUG'].to_s.downcase
      value == '1' || value == 'true' || value == 'yes'
    end
  end
end
