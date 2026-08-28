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
    ABANDONED_TEMP_AGE = 60 * 60
    USER_OWNED_METADATA_FIELDS = %w[
      venue year track status decision publication_doi tags provenance
    ].freeze

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
          WRQ_OPENER        Viewer executable (default: open/xdg-open/explorer)
        HF_TOKEN          Optional Hugging Face token for higher quotas
    TEXT

    def initialize(stdout: STDOUT, stderr: STDERR, stdin: STDIN, env: nil,
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
      @clock = clock
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
      Tui.disable_colors! if !environment_value('NO_COLOR').to_s.empty?

      command = args.shift
      return browse("") if command.nil?
      if command.start_with?("-")
        raise UsageError, "unknown option: #{command}"
      end

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
          unless args[index + 1] && !args[index + 1].start_with?("-")
            raise UsageError, "#{name} requires a value"
          end
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
          unless args[index + 1] && !args[index + 1].start_with?("-")
            raise UsageError, "#{name} requires a value"
          end
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
      default_arxiv_source
    end

    def default_arxiv_source
      @arxiv_source ||= begin
        library.prepare!
        throttle_path = File.join(library.paths.cache, "arxiv-api.throttle")
        Sources::Arxiv.new(
          throttle: Throttle.new(path: throttle_path),
          cache_path: library.paths.cache
        )
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
      reject_unknown_options!(args)
      raise UsageError, "add requires one paper reference" if args.empty?
      raise UsageError, "add accepts one paper reference" if args.length > 1
      identity = Identity.parse(args.first)
      raise UsageError, "add requires an arXiv or Hugging Face reference" unless identity.arxiv?
      add_or_open_reference(args.first)
    end

    def command_open(args)
      reject_unknown_options!(args)
      selector = selector_argument(args, "open")
      paper = resolve_one(selector)
      return not_found(selector) unless paper
      finish_paper(paper)
    end

    def command_search(args)
      reject_unknown_options!(args)
      browse(args.join(" "))
    end

    def command_import(args)
      recursive = extract_flag!(args, "--recursive")
      move = extract_flag!(args, "--move")
      reject_unknown_options!(args)
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
          aliases: [],
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
      reject_unknown_options!(args)
      selector = selector_argument(args, "info")
      paper = resolve_one(selector)
      return not_found(selector) unless paper

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
      reject_unknown_options!(args)
      selector = selector_argument(args, "meta")
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

      if changes.empty? && add_tags.empty? && remove_tags.empty?
        raise UsageError, "meta requires at least one metadata option"
      end

      paper = library.update(paper.key) do |fresh|
        transaction_changes = changes.dup
        unless add_tags.empty? && remove_tags.empty?
          tags = Array(fresh.metadata["tags"]).map(&:to_s)
          add_tags.each { |tag| tags << tag unless tags.include?(tag) }
          remove_tags.each { |tag| tags.delete(tag) }
          transaction_changes["tags"] = tags
        end

        provenance = fresh.metadata["provenance"]
        provenance = provenance.is_a?(Hash) ? provenance.dup : {}
        transaction_changes.keys.each do |key|
          provenance[key] = "manual" unless key == "tags"
        end
        transaction_changes["provenance"] = provenance
        fresh.merge_metadata!(transaction_changes)
      end
      raise Error, "paper disappeared while updating metadata" unless paper

      if @options[:json]
        emit_json(paper_payload(paper))
      else
        @stdout.puts("Updated metadata: #{paper.key}")
      end
      0
    end

    def command_dedupe(args)
      recursive = extract_flag!(args, "--recursive")
      reject_unknown_options!(args)
      raise UsageError, "dedupe accepts at most one path" if args.length > 1

      papers = library.papers
      hash_groups = {}
      papers.each do |paper|
        seen_paths = {}
        paper.assets.each do |asset|
          path = library.asset_path(asset)
          next if seen_paths[path]
          seen_paths[path] = true
          hash_groups[asset.sha256] ||= []
          hash_groups[asset.sha256] << {
            "paper" => paper.key,
            "path" => path,
            "version" => asset.version
          }
        end
      end
      exact = hash_groups.select { |_hash, values| values.length > 1 }

      logical_groups = {}
      papers.each do |paper|
        logical_identity_tokens(paper).each do |token|
          logical_groups[token] ||= []
          logical_groups[token] << paper.key unless logical_groups[token].include?(paper.key)
        end
      end
      logical = logical_groups.select { |_token, keys| keys.length > 1 }

      probable = {}
      papers.each_with_index do |paper, index|
        later = index + 1
        while later < papers.length
          candidate = papers[later]
          if probable_duplicate?(paper, candidate)
            left = normalize_title(paper.title)
            right = normalize_title(candidate.title)
            label = left == right ? left : "#{left} <> #{right}"
            probable[label] ||= []
            probable[label] << paper.key unless probable[label].include?(paper.key)
            probable[label] << candidate.key unless probable[label].include?(candidate.key)
          end
          later += 1
        end
      end

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
        "logical_identity_groups" => logical,
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
      reject_unknown_options!(args)
      if update_all
        raise UsageError, "update --all does not accept a selector" unless args.empty?
        papers = library.papers.select { |paper| paper.identity.arxiv? }
      else
        selector = selector_argument(args, "update", suffix: " or --all")
        paper = resolve_one(selector)
        return not_found(selector) unless paper
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
      reject_unknown_options!(args)
      selector = selector_argument(args, "remove")
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
      reject_unknown_options!(args)
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

      result = if defined?(RubyVM) && @selector_class != Selector
        @selector_class.new(records, query: query).run
      else
        Selector.new(records, query: query).run
      end
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
      record_metadata["tags"] = []
      record_metadata["status"] = "unread"
      record_metadata["added_at"] = timestamp

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
        download_arxiv_pdf(metadata, temporary)
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
      metadata = arxiv_source.refresh(paper.identity.base_id)
      resolved_version = metadata[:resolved_version]
      record_metadata = arxiv_record_metadata(metadata)
      existing_provider_data = paper.metadata["provider_data"]
      if existing_provider_data.is_a?(Hash)
        record_metadata["provider_data"] = deep_merge_hashes(
          existing_provider_data,
          record_metadata["provider_data"] || {}
        )
      end
      if enrich_hf || paper.metadata.dig("provider_data", "hugging_face")
        begin
          hf = hugging_face_source.fetch(paper.identity.base_id)
          record_metadata = merge_hugging_face(record_metadata, hf) if hf
        rescue StandardError => error
          @stderr.puts("Warning: Hugging Face enrichment failed for #{paper.key}: #{error.message}")
        end
      end

      # Provider refreshes update provider-owned fields only. These fields are
      # curated by the user (including an initially inferred DOI), so once a
      # record exists they must never be silently replaced by upstream data.
      provenance = paper.metadata["provenance"]
      provenance = {} unless provenance.is_a?(Hash)
      USER_OWNED_METADATA_FIELDS.each do |key|
        next if key == "publication_doi" && provenance[key] != "manual"
        record_metadata.delete(key)
      end

      existing = resolved_version && paper.asset_for_version(resolved_version)
      downloaded = false
      if existing && File.file?(library.asset_path(existing))
        paper = library.update(paper.key) do |fresh|
          fresh.merge_metadata!(record_metadata)
          fresh.add_aliases!(Array(metadata[:aliases]))
        end
        raise Error, "paper disappeared while refreshing metadata" unless paper
      else
        temporary = library.paths.temporary_path("arxiv-update")
        begin
          download_arxiv_pdf(metadata, temporary)
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

    def download_arxiv_pdf(metadata, destination)
      if defined?(RubyVM) && @arxiv_override
        @arxiv_override.download(
          metadata,
          destination: destination,
          max_bytes: MAX_PDF_BYTES
        )
      else
        source = default_arxiv_source
        source.download(
          metadata,
          destination: destination,
          max_bytes: MAX_PDF_BYTES
        )
      end
    end

    def finish_paper(paper, asset: nil)
      asset ||= paper.current_asset
      raise Error, "paper has no stored PDF: #{paper.key}" unless asset
      path = library.asset_path(asset)
      raise Error, "stored PDF is missing: #{path}" unless File.file?(path)

      if @options[:json]
        emit_json(paper_payload(paper).merge("selected_path" => path))
      elsif @options[:print_path]
        @stdout.puts(path)
      elsif @options[:no_open]
        @stdout.puts("Stored: #{path}")
      else
        original_asset = paper.current_asset
        activated = library.activate_asset(
          paper.key,
          version: asset.version,
          sha256: asset.sha256
        )
        raise Error, "paper disappeared while opening" unless activated
        selected = activated.asset_for_version(asset.version)
        selected ||= activated.asset_for_hash(asset.sha256)
        raise Error, "selected PDF disappeared while opening" unless selected
        path = library.asset_path(selected)
        begin
          opened = @opener.open(path)
          raise Error, "paper opener did not start" unless opened
        rescue StandardError, Interrupt
          begin
            if original_asset
              library.activate_asset(
                paper.key,
                version: original_asset.version,
                sha256: original_asset.sha256
              )
            end
          rescue StandardError
          end
          raise
        end
        paper = activated
        paper = library.update(paper.key) do |fresh|
          fresh.merge_metadata!({ "last_opened_at" => timestamp })
        end
        raise Error, "paper disappeared while recording open" unless paper
        @stdout.puts("Opened: #{paper.key}")
      end
      0
    end

    def resolve_one(selector)
      value = selector.to_s.strip
      return nil if value.empty?
      exact = library.find(value)
      return exact if exact

      result = Search.new(library.papers, now: now).call(value, limit: 1).first
      result && result.record
    end

    def selector_argument(args, command, suffix: "")
      value = args.join(" ").strip
      if value.empty?
        raise UsageError, "#{command} requires a selector#{suffix}"
      end
      value
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
      record
    end

    def merge_hugging_face(record_metadata, hf)
      merged = deep_copy(record_metadata)
      provider_data = merged["provider_data"]
      provider_data = {} unless provider_data.is_a?(Hash)
      hf_provider = hf[:provider_data] || hf["provider_data"] || { "hugging_face" => hf }
      hf_provider = deep_stringify(hf_provider)
      hf_provider.each do |key, value|
        provider_data[key] = value
      end
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

    def logical_identity_tokens(paper)
      tokens = [paper.key.downcase]
      paper.aliases.each do |paper_alias|
        normalized = paper_alias.to_s.strip.downcase
        next if normalized.empty?
        identity = Identity.recognize(paper_alias)
        tokens << (identity ? identity.canonical_key : "alias:#{normalized}")
      end
      tokens.uniq
    end

    def probable_duplicate?(left, right)
      left_title = normalize_title(left.title)
      right_title = normalize_title(right.title)
      return false if left_title.empty? || right_title.empty?

      title_match = left_title == right_title || title_token_similarity(left_title, right_title) >= 0.7
      return false unless title_match

      left_authors = normalized_authors(left)
      right_authors = normalized_authors(right)
      return true if left_authors.empty? || right_authors.empty?

      left_authors.any? do |author|
        right_authors.any? { |candidate| authors_match?(author, candidate) }
      end
    end

    def title_token_similarity(left, right)
      left_tokens = left.split(" ").uniq
      right_tokens = right.split(" ").uniq
      union = (left_tokens + right_tokens).uniq
      return 0.0 if union.empty?
      shared = left_tokens.count { |token| right_tokens.include?(token) }
      shared.to_f / union.length
    end

    def normalized_authors(paper)
      paper.authors.map do |author|
        author.to_s.downcase.gsub(/[^a-z0-9]+/, " ").strip
      end.reject(&:empty?).uniq
    end

    def authors_match?(left, right)
      return true if left == right
      left_parts = left.split(" ")
      right_parts = right.split(" ")
      !left_parts.empty? && !right_parts.empty? && left_parts[-1] == right_parts[-1]
    end

    def doctor_report(fix: false)
      errors = []
      warnings = []
      checked_records = 0
      checked_assets = 0
      removed = 0
      catalog = library
      current_time = now.to_f

      catalog.with_lock do
        referenced_paths = {}
        alias_owners = {}
        entries = Dir.entries(catalog.paths.records).select { |name| name.end_with?(".json") }.sort
        entries.each do |name|
          path = File.join(catalog.paths.records, name)
          begin
            if File.symlink?(path)
              raise UnsafePath, "record file is a symlink"
            end
            stat = File.lstat(path)
            unless stat.file? && stat.nlink == 1
              raise UnsafePath, "record file is not a regular single-link file"
            end
            paper = MetadataCodec.read(path)
            expected = catalog.paths.record_path(paper.key)
            unless File.expand_path(path) == File.expand_path(expected)
              raise InvalidRecord, "filename does not match canonical key #{paper.key}"
            end
            checked_records += 1

            paper.aliases.each do |paper_alias|
              alias_identity = Identity.recognize(paper_alias)
              token = if alias_identity
                        alias_identity.canonical_key
                      else
                        "alias:#{paper_alias.to_s.strip.downcase}"
                      end
              alias_owners[token] ||= []
              alias_owners[token] << paper.key unless alias_owners[token].include?(paper.key)
            end

            paper.assets.each do |asset|
              checked_assets += 1
              asset_path = catalog.asset_path(asset)
              referenced_paths[File.expand_path(asset_path)] = true
              if File.symlink?(asset_path)
                errors << "asset is a symlink for #{paper.key}: #{asset_path}"
                next
              end
              unless File.file?(asset_path)
                errors << "missing asset for #{paper.key}: #{asset_path}"
                next
              end
              actual_size = File.size(asset_path)
              if actual_size != asset.size
                errors << "size mismatch for #{paper.key}: #{asset_path} (#{actual_size} != #{asset.size})"
              end
              header = File.open(asset_path, "rb") do |file|
                begin
                  file.readpartial(5).to_s
                rescue EOFError
                  String.new
                end
              end
              unless header == "%PDF-"
                errors << "invalid PDF signature for #{paper.key}: #{asset_path}"
              end
              actual = catalog.sha256(asset_path)
              errors << "hash mismatch for #{paper.key}: #{asset_path}" unless actual == asset.sha256
            end

            active = paper.current_asset
            if active && !active.path.start_with?("library/")
              errors << "active asset is not visible for #{paper.key}: #{active.path}"
            end
            visible_paths = paper.assets.map(&:path).select { |value| value.start_with?("library/") }.uniq
            if visible_paths.length > 1
              errors << "multiple visible assets for #{paper.key}: #{visible_paths.join(', ')}"
            end
          rescue StandardError => error
            errors << "invalid record #{path}: #{error.message}"
          end
        end

        alias_owners.each do |token, owners|
          if owners.length > 1
            errors << "alias conflict #{token}: #{owners.join(', ')}"
          end
        end

        [catalog.paths.library, catalog.paths.versions].each do |directory|
          Dir.entries(directory).sort.each do |name|
            next if name == "." || name == ".."
            path = File.join(directory, name)
            next unless name.downcase.end_with?(".pdf") || File.symlink?(path)
            if File.symlink?(path)
              errors << "managed PDF is a symlink: #{path}"
            elsif File.file?(path) && !referenced_paths[File.expand_path(path)]
              warnings << "orphan PDF: #{path}"
            end
          end
        end

        candidates = []
        Dir.entries(catalog.paths.tmp).each do |name|
          next if name == "." || name == ".."
          path = File.join(catalog.paths.tmp, name)
          candidates << path if File.file?(path) && !File.symlink?(path)
        end
        Dir.entries(catalog.paths.records).each do |name|
          next unless name.include?(".tmp-")
          path = File.join(catalog.paths.records, name)
          candidates << path if File.file?(path) && !File.symlink?(path)
        end
        abandoned = candidates.select do |path|
          current_time - File.mtime(path).to_f >= ABANDONED_TEMP_AGE
        end.sort
        if fix
          abandoned.each do |path|
            begin
              File.delete(path)
              removed += 1
            rescue SystemCallError => error
              errors << "could not remove temporary file #{path}: #{error.message}"
            end
          end
        elsif !abandoned.empty?
          warnings << "#{abandoned.length} abandoned temporary file(s)"
        end
        nil
      end

      {
        "root" => catalog.root,
        "checked_records" => checked_records,
        "checked_assets" => checked_assets,
        "errors" => errors,
        "warnings" => warnings,
        "removed_temporary_files" => removed
      }
    end

    def print_paper_info(payload)
      metadata = payload["metadata"] || {}
      @stdout.puts(metadata["title"].to_s.empty? ? payload["key"] : metadata["title"])
      @stdout.puts("ID: #{payload['key']}")
      identity = payload["identity"] || {}
      @stdout.puts("Provider: #{identity['provider']}") if identity["provider"]
      @stdout.puts("Base ID: #{identity['base_id']}") if identity["base_id"]
      @stdout.puts("Schema: #{payload['schema_version']}")
      @stdout.puts("Created: #{payload['created_at']}")
      @stdout.puts("Updated: #{payload['updated_at']}")
      @stdout.puts("Active PDF: #{payload['current_path']}") if payload["current_path"]

      @stdout.puts("Metadata:")
      metadata.keys.sort.each do |key|
        @stdout.puts("  #{info_label(key)}: #{info_value(metadata[key])}")
      end

      aliases = Array(payload["aliases"])
      @stdout.puts("Aliases:")
      if aliases.empty?
        @stdout.puts("  (none)")
      else
        aliases.each { |paper_alias| @stdout.puts("  - #{paper_alias}") }
      end

      active = payload["active_asset"] || {}
      @stdout.puts("Assets:")
      Array(payload["assets"]).each do |asset|
        selected = asset["sha256"] == active["sha256"] &&
          asset["version"] == active["version"]
        marker = selected ? "*" : "-"
        version = asset["version"] ? "v#{asset['version']}" : "unversioned"
        @stdout.puts("  #{marker} #{version}")
        asset.keys.sort.each do |key|
          next if key == "version"
          @stdout.puts("      #{info_label(key)}: #{info_value(asset[key])}")
        end
      end
    end

    def info_label(key)
      key.to_s.split("_").map { |part| part.capitalize }.join(" ")
    end

    def info_value(value)
      if value.is_a?(Array) && value.all? { |item| !item.is_a?(Hash) && !item.is_a?(Array) }
        value.empty? ? "(none)" : value.map(&:to_s).join(", ")
      elsif value.is_a?(Hash) || value.is_a?(Array)
        JSON.generate(value)
      elsif value.nil?
        "(none)"
      else
        value.to_s
      end
    end

    def print_dedupe_report(report)
      logical = report["logical_identity_groups"]
      exact = report["exact_hash_groups"]
      probable = report["probable_title_groups"]
      external = report["external_files"]
      @stdout.puts("Logical identity conflicts: #{logical.length}")
      logical.each { |token, keys| @stdout.puts("  #{token}: #{keys.join(', ')}") }
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

    def reject_unknown_options!(args)
      unknown = args.find { |argument| argument.start_with?("-") }
      raise UsageError, "unknown option: #{unknown}" if unknown
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

    def deep_merge_hashes(base, updates)
      merged = deep_copy(base)
      updates.each do |key, value|
        normalized_key = key.to_s
        if merged[normalized_key].is_a?(Hash) && value.is_a?(Hash)
          merged[normalized_key] = deep_merge_hashes(merged[normalized_key], value)
        else
          merged[normalized_key] = deep_copy(value)
        end
      end
      merged
    end

    def hugging_face_reference?(value)
      value.to_s.match?(%r{\Ahttps?://(?:www\.)?(?:huggingface\.co|hf\.co)/papers/}i)
    end

    def now
      @clock ? @clock.call : Time.now
    end

    def timestamp
      Paper.timestamp(now)
    end

    def debug?
      value = environment_value('WRQ_DEBUG').to_s.downcase
      value == '1' || value == 'true' || value == 'yes'
    end

    def environment_value(name)
      @env ? @env[name] : ENV[name]
    end
  end
end
