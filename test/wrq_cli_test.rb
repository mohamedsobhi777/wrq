# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "digest"
require_relative "test_helper"
require_relative "../lib/wrq/cli"

class WrqCliTest < Minitest::Test
  class FakeArxiv
    attr_reader :fetches, :refreshes, :downloads

    def initialize(latest_version: 7, publication_doi: nil)
      @latest_version = latest_version
      @publication_doi = publication_doi
      @fetches = []
      @refreshes = []
      @downloads = []
    end

    def fetch(reference, refresh: false)
      identity = Wrq::Identity.parse(reference)
      version = identity.version || @latest_version
      @fetches << identity.versioned_id
      @refreshes << refresh
      {
        provider: "arxiv",
        canonical_key: identity.canonical_key,
        base_id: identity.base_id,
        requested_id: identity.versioned_id,
        requested_version: identity.version,
        resolved_id: "#{identity.base_id}v#{version}",
        resolved_version: version,
        title: "Attention Is All You Need",
        authors: ["Ashish Vaswani", "Noam Shazeer"],
        abstract: "A transformer paper.",
        categories: ["cs.CL"],
        primary_category: "cs.CL",
        published_at: "2017-06-12T00:00:00Z",
        updated_at: "2023-08-02T00:00:00Z",
        comment: "Accepted at NeurIPS 2017",
        journal_ref: nil,
        publication_doi: @publication_doi,
        abstract_url: "https://arxiv.org/abs/#{identity.base_id}v#{version}",
        pdf_url: "https://arxiv.org/pdf/#{identity.base_id}v#{version}.pdf",
        aliases: [identity.base_id, "arXiv:#{identity.base_id}"],
        provider_data: { arxiv: { resolved_id: "#{identity.base_id}v#{version}" } }
      }
    end

    def refresh(reference)
      fetch(reference, refresh: true)
    end

    def download(metadata, destination:, max_bytes: nil)
      @downloads << [metadata[:resolved_id], max_bytes]
      body = "%PDF-1.4\n#{metadata[:resolved_id]}\n"
      File.binwrite(destination, body)
      {
        path: destination,
        sha256: Digest::SHA256.hexdigest(body),
        bytes: body.bytesize,
        url: metadata[:pdf_url]
      }
    end
  end

  class FakeHuggingFace
    attr_reader :fetches

    def initialize
      @fetches = []
    end

    def fetch(reference)
      @fetches << reference
      {
        provider: "hugging_face",
        base_id: reference,
        summary: "HF community summary",
        ai_summary: "AI summary",
        ai_keywords: ["transformers"],
        upvotes: 42,
        authors: ["Ashish Vaswani"],
        hf_authors: [{ name: "Ashish Vaswani", username: "avaswani" }],
        hf_url: "https://huggingface.co/papers/#{reference}",
        models: [{ id: "org/model" }],
        datasets: [],
        spaces: [],
        provider_data: { hugging_face: { upvotes: 42 } }
      }
    end
  end

  class FailingHuggingFace
    def fetch(_reference)
      raise "temporary Hugging Face failure"
    end
  end

  class FakeOpener
    attr_reader :paths

    def initialize
      @paths = []
    end

    def open(path)
      @paths << path
      true
    end
  end

  class FailingOpener < FakeOpener
    def open(path)
      @paths << path
      raise RuntimeError, "viewer unavailable"
    end
  end

  def setup
    super
    @temporary = Dir.mktmpdir("wrq-cli")
    @root = File.join(@temporary, "papers")
    @library = Wrq::Library.new(@root, {})
    @arxiv = FakeArxiv.new
    @hf = FakeHuggingFace.new
    @opener = FakeOpener.new
  end

  def teardown
    FileUtils.remove_entry(@temporary) if @temporary && Dir.exist?(@temporary)
    super
  end

  def run_cli(*args, input: "")
    stdout = StringIO.new
    stderr = StringIO.new
    cli = Wrq::CLI.new(
      stdout: stdout,
      stderr: stderr,
      stdin: StringIO.new(input),
      env: {},
      library: @library,
      arxiv_source: @arxiv,
      hugging_face_source: @hf,
      opener: @opener,
      clock: proc { Time.utc(2026, 8, 28, 12, 0, 0) }
    )
    status = cli.run(args.flatten)
    [status, stdout.string, stderr.string]
  end

  def write_pdf(name, body = "%PDF-1.4\nlocal\n")
    path = File.join(@temporary, name)
    File.binwrite(path, body)
    path
  end

  def test_help_and_version_do_not_create_library
    status, output, = run_cli("--help")
    assert_equal 0, status
    assert_includes output, "local-first research paper library"
    refute Dir.exist?(@root)

    status, output, = run_cli("--version")
    assert_equal 0, status
    assert_equal "wrq 0.1.0\n", output
    refute Dir.exist?(@root)
  end

  def test_shorthand_downloads_once_then_opens_offline
    status, output, error = run_cli("1706.03762")
    assert_equal 0, status, error
    assert_includes output, "Downloaded: arxiv:1706.03762"
    assert_equal ["1706.03762"], @arxiv.fetches
    assert_equal 1, @arxiv.downloads.length
    assert_equal 1, @opener.paths.length
    assert File.file?(@opener.paths.first)

    status, output, error = run_cli("1706.03762")
    assert_equal 0, status, error
    assert_includes output, "Opened: arxiv:1706.03762"
    assert_equal ["1706.03762"], @arxiv.fetches
    assert_equal 1, @arxiv.downloads.length
    assert_equal 2, @opener.paths.length
  end

  def test_explicit_versions_are_distinct_assets_in_one_record
    assert_equal 0, run_cli("add", "1706.03762v1", "--no-open").first
    assert_equal 0, run_cli("add", "1706.03762v2", "--no-open").first

    paper = @library.find("1706.03762")
    assert_equal [1, 2], paper.assets.map(&:version).sort
    assert_equal "arxiv:1706.03762", paper.key
    assert_equal ["1706.03762v1", "1706.03762v2"], @arxiv.fetches
  end

  def test_opening_an_exact_version_makes_it_the_active_local_asset
    assert_equal 0, run_cli("add", "1706.03762v1", "--no-open").first
    assert_equal 0, run_cli("add", "1706.03762v2", "--no-open").first
    assert_equal 2, @library.find("1706.03762").current_asset.version

    status, _output, error = run_cli("1706.03762v1")
    assert_equal 0, status, error
    paper = @library.find("1706.03762")
    assert_equal 1, paper.current_asset.version
    assert paper.asset_for_version(1).path.start_with?("library/")
    assert paper.asset_for_version(2).path.start_with?(".wrq/versions/")

    status, _output, error = run_cli("1706.03762")
    assert_equal 0, status, error
    assert @opener.paths.last.include?("-v1")
    assert_equal 2, @arxiv.fetches.length
  end

  def test_hugging_face_url_enriches_without_replacing_arxiv_authors
    status, = run_cli("https://huggingface.co/papers/1706.03762", "--no-open")
    assert_equal 0, status
    paper = @library.find("1706.03762")
    assert_equal ["Ashish Vaswani", "Noam Shazeer"], paper.authors
    assert_equal "HF community summary", paper.metadata["hf_summary"]
    assert_equal 42, paper.metadata.dig("provider_data", "hugging_face", "upvotes")
    assert_equal ["1706.03762"], @hf.fetches
  end

  def test_import_uses_hash_deduplication_and_can_move_after_success
    first = write_pdf("first-paper.pdf")
    second = write_pdf("second-copy.pdf")

    status, output, error = run_cli("import", first)
    assert_equal 0, status, error
    assert_includes output, "Imported:"
    assert File.file?(first)

    status, output, error = run_cli("import", "--move", second)
    assert_equal 0, status, error
    assert_includes output, "Already cataloged:"
    refute File.exist?(second)
    assert_equal 1, @library.papers.length
    assert_equal 1, @library.papers.first.assets.length
  end

  def test_same_basename_imports_do_not_create_ambiguous_aliases
    first_directory = File.join(@temporary, "source-a")
    second_directory = File.join(@temporary, "source-b")
    FileUtils.mkdir_p(first_directory)
    FileUtils.mkdir_p(second_directory)
    first = File.join(first_directory, "paper.pdf")
    second = File.join(second_directory, "paper.pdf")
    File.binwrite(first, "%PDF-1.4\nfirst paper\n")
    File.binwrite(second, "%PDF-1.4\nsecond paper\n")

    status, _output, error = run_cli("import", first, second)
    assert_equal 0, status, error
    assert_equal 2, @library.papers.length
    refute @library.papers.any? { |paper| paper.aliases.include?("paper.pdf") }

    status, output, error = run_cli("doctor", "--json")
    assert_equal 0, status, error
    assert_empty JSON.parse(output)["errors"]
  end

  def test_metadata_info_search_and_print_path
    run_cli("1706.03762", "--no-open")
    status, output, error = run_cli(
      "meta", "1706.03762",
      "--venue", "NeurIPS", "--year", "2017", "--status", "read",
      "--tag", "transformers", "--tag", "foundational"
    )
    assert_equal 0, status, error
    assert_includes output, "Updated metadata"

    status, output, error = run_cli("info", "1706.03762", "--json")
    assert_equal 0, status, error
    payload = JSON.parse(output)
    assert_equal "NeurIPS", payload.dig("metadata", "venue")
    assert_equal 2017, payload.dig("metadata", "year")
    assert_equal ["transformers", "foundational"], payload.dig("metadata", "tags")

    status, output, error = run_cli("search", "vaswani", "--json")
    assert_equal 0, status, error
    results = JSON.parse(output)
    assert_equal "authors", results.first["matched_field"]

    status, output, error = run_cli("attention", "--print-path")
    assert_equal 0, status, error
    assert File.file?(output.strip)
  end

  def test_human_info_includes_complete_metadata_and_asset_details
    run_cli("1706.03762", "--no-open")
    run_cli(
      "meta", "1706.03762",
      "--venue", "NeurIPS", "--track", "Main", "--decision", "accepted"
    )

    status, output, error = run_cli("info", "1706.03762")
    assert_equal 0, status, error
    assert_includes output, "Provider Data:"
    assert_includes output, "Track: Main"
    assert_includes output, "Decision: accepted"
    assert_includes output, "Aliases:"
    assert_includes output, "Assets:"
    assert_includes output, "Sha256:"
    assert_includes output, "Source Url:"
    assert_includes output, "Created:"
    assert_includes output, "Updated:"
  end

  def test_failed_opener_restores_the_previous_active_version
    run_cli("add", "1706.03762v1", "--no-open")
    run_cli("add", "1706.03762v2", "--no-open")
    @opener = FailingOpener.new

    status, _output, error = run_cli("1706.03762v1")
    assert_equal 1, status
    assert_includes error, "viewer unavailable"

    paper = @library.find("1706.03762")
    assert_equal 2, paper.current_asset.version
    assert paper.asset_for_version(1).path.start_with?(".wrq/versions/")
    assert paper.asset_for_version(2).path.start_with?("library/")
    assert_nil paper.metadata["last_opened_at"]
  end

  def test_arbitrary_query_never_uses_network
    path = write_pdf("graph-neural-networks.pdf")
    run_cli("import", path)
    status, output, error = run_cli("graph neural", "--print-path")
    assert_equal 0, status, error
    assert File.file?(output.strip)
    assert_empty @arxiv.fetches
  end

  def test_dedupe_reports_external_duplicates_without_deleting
    source = write_pdf("paper.pdf")
    run_cli("import", source)
    duplicate = write_pdf("download-copy.pdf")

    status, output, error = run_cli("dedupe", duplicate, "--json")
    assert_equal 0, status, error
    report = JSON.parse(output)
    assert_equal @library.papers.first.key, report["external_files"].first["duplicate_of"]
    assert File.file?(duplicate)
    assert_equal [], report["deleted"]
  end

  def test_probable_dedupe_requires_author_agreement_when_authors_are_known
    first = write_pdf("first.pdf", "%PDF-1.4\nfirst\n")
    second = write_pdf("second.pdf", "%PDF-1.4\nsecond\n")
    @library.import_pdf(
      source_path: first,
      metadata: { "title" => "A Shared Research Title", "authors" => ["Alice Example"] }
    )
    @library.import_pdf(
      source_path: second,
      metadata: { "title" => "A Shared Research Title", "authors" => ["Bob Different"] }
    )

    status, output, error = run_cli("dedupe", "--json")
    assert_equal 0, status, error
    assert_empty JSON.parse(output)["probable_title_groups"]
  end

  def test_probable_dedupe_accepts_title_variation_with_shared_author
    first = write_pdf("variation-one.pdf", "%PDF-1.4\none\n")
    second = write_pdf("variation-two.pdf", "%PDF-1.4\ntwo\n")
    @library.import_pdf(
      source_path: first,
      metadata: { "title" => "Efficient Transformers for Long Context", "authors" => ["A. Researcher"] }
    )
    @library.import_pdf(
      source_path: second,
      metadata: { "title" => "Efficient Transformers for Long Context Windows", "authors" => ["Ada Researcher"] }
    )

    status, output, error = run_cli("dedupe", "--json")
    assert_equal 0, status, error
    groups = JSON.parse(output)["probable_title_groups"]
    assert groups.values.any? { |keys| keys.length == 2 }
  end

  def test_dedupe_reports_alias_conflicts_and_ignores_one_shared_physical_asset
    first = write_pdf("logical-one.pdf", "%PDF-1.4\none\n")
    second = write_pdf("logical-two.pdf", "%PDF-1.4\ntwo\n")
    one = @library.import_pdf(source_path: first, aliases: ["shared-paper"])
    two = @library.import_pdf(source_path: second, aliases: ["shared-paper"])

    same_v1 = write_pdf("same-v1.pdf", "%PDF-1.4\nsame\n")
    same_v2 = write_pdf("same-v2.pdf", "%PDF-1.4\nsame\n")
    @library.ingest_pdf(identity: Wrq::Identity.parse("2401.01234v1"), source_path: same_v1)
    @library.ingest_pdf(identity: Wrq::Identity.parse("2401.01234v2"), source_path: same_v2)

    status, output, error = run_cli("dedupe", "--json")
    assert_equal 0, status, error
    report = JSON.parse(output)
    assert_equal [one.paper.key, two.paper.key].sort,
      report["logical_identity_groups"]["alias:shared-paper"].sort
    assert_empty report["exact_hash_groups"]
  end

  def test_update_downloads_only_a_new_version
    run_cli("1706.03762", "--no-open")
    @arxiv = FakeArxiv.new(latest_version: 8)

    status, output, error = run_cli("update", "1706.03762", "--json")
    assert_equal 0, status, error
    row = JSON.parse(output).first
    assert_equal 8, row["version"]
    assert_equal true, row["downloaded"]
    assert_equal [7, 8], @library.find("1706.03762").assets.map(&:version).sort

    status, output, error = run_cli("update", "1706.03762", "--json")
    assert_equal 0, status, error
    assert_equal false, JSON.parse(output).first["downloaded"]
    assert_equal 1, @arxiv.downloads.length
    assert_equal [true, true], @arxiv.refreshes
  end

  def test_update_preserves_all_user_owned_metadata
    run_cli("1706.03762", "--no-open")
    status, _output, error = run_cli(
      "meta", "1706.03762",
      "--venue", "NeurIPS", "--year", "2017", "--track", "Main",
      "--status", "read", "--decision", "accepted",
      "--doi", "10.5555/manual-doi", "--tag", "foundational"
    )
    assert_equal 0, status, error
    before = @library.find("1706.03762").metadata
    added_at = before["added_at"]

    @arxiv = FakeArxiv.new(latest_version: 8)
    status, _output, error = run_cli("update", "1706.03762")
    assert_equal 0, status, error

    metadata = @library.find("1706.03762").metadata
    assert_equal "NeurIPS", metadata["venue"]
    assert_equal 2017, metadata["year"]
    assert_equal "Main", metadata["track"]
    assert_equal "read", metadata["status"]
    assert_equal "accepted", metadata["decision"]
    assert_equal "10.5555/manual-doi", metadata["publication_doi"]
    assert_equal ["foundational"], metadata["tags"]
    assert_equal added_at, metadata["added_at"]
    assert_equal "manual", metadata.dig("provenance", "publication_doi")
  end

  def test_update_refreshes_provider_owned_doi
    run_cli("1706.03762", "--no-open")
    @arxiv = FakeArxiv.new(latest_version: 7, publication_doi: "10.5555/provider-doi")

    status, _output, error = run_cli("update", "1706.03762")
    assert_equal 0, status, error
    assert_equal "10.5555/provider-doi",
      @library.find("1706.03762").metadata["publication_doi"]
  end

  def test_update_preserves_hugging_face_provider_data_on_transient_failure
    run_cli("https://huggingface.co/papers/1706.03762", "--no-open")
    assert_equal 42,
      @library.find("1706.03762").metadata.dig("provider_data", "hugging_face", "upvotes")
    @hf = FailingHuggingFace.new

    status, _output, error = run_cli("update", "1706.03762")
    assert_equal 0, status, error
    assert_equal 42,
      @library.find("1706.03762").metadata.dig("provider_data", "hugging_face", "upvotes")
  end

  def test_remove_requires_yes_and_uses_recoverable_trash
    run_cli("1706.03762", "--no-open")
    status, _output, error = run_cli("remove", "1706.03762", input: "NO\n")
    assert_equal 1, status
    assert_includes error, "Cancelled"
    assert @library.find("1706.03762")

    status, output, error = run_cli("remove", "1706.03762", input: "YES\n")
    assert_equal 0, status, error
    assert_includes output, ".wrq/trash"
    refute @library.find("1706.03762")
    assert Dir.exist?(File.join(@root, ".wrq", "trash"))
  end

  def test_doctor_validates_hashes_and_cleans_temporary_files
    run_cli("1706.03762", "--no-open")
    abandoned = @library.paths.temporary_path("abandoned")
    File.write(abandoned, "partial")
    File.utime(Time.at(0), Time.at(0), abandoned)
    active = @library.paths.temporary_path("active-download")
    File.write(active, "in progress")

    status, output, error = run_cli("doctor", "--json")
    assert_equal 0, status, error
    report = JSON.parse(output)
    assert_equal 1, report["checked_records"]
    assert_equal 1, report["checked_assets"]
    assert_equal 1, report["warnings"].length

    status, output, error = run_cli("doctor", "--fix", "--json")
    assert_equal 0, status, error
    assert_equal 1, JSON.parse(output)["removed_temporary_files"]
    refute File.exist?(abandoned)
    assert File.exist?(active)
  end

  def test_doctor_reports_size_signature_orphans_and_record_filename_mismatch
    run_cli("1706.03762", "--no-open")
    paper = @library.find("1706.03762")
    asset_path = @library.asset_path(paper.current_asset)
    File.binwrite(asset_path, "not a pdf")
    orphan = File.join(@library.library_path, "orphan.pdf")
    File.binwrite(orphan, "%PDF-1.4\norphan\n")

    record_path = @library.paths.record_path(paper.key)
    wrong_path = File.join(@library.paths.records, "wrong-name.json")
    File.rename(record_path, wrong_path)

    status, output, error = run_cli("doctor", "--json")
    assert_equal 1, status, error
    report = JSON.parse(output)
    joined_errors = report["errors"].join("\n")
    assert_includes joined_errors, "filename does not match canonical key"

    File.rename(wrong_path, record_path)
    status, output, error = run_cli("doctor", "--json")
    assert_equal 1, status, error
    report = JSON.parse(output)
    joined_errors = report["errors"].join("\n")
    assert_includes joined_errors, "size mismatch"
    assert_includes joined_errors, "invalid PDF signature"
    assert_includes joined_errors, "hash mismatch"
    assert report["warnings"].any? { |warning| warning.include?("orphan PDF") }
  end

  def test_doctor_rejects_symlinked_records_without_following_them
    run_cli("1706.03762", "--no-open")
    paper = @library.find("1706.03762")
    record_path = @library.paths.record_path(paper.key)
    external = File.join(@temporary, "external.json")
    File.rename(record_path, external)
    File.symlink(external, record_path)

    status, output, error = run_cli("doctor", "--json")
    assert_equal 1, status, error
    assert JSON.parse(output)["errors"].any? { |message| message.include?("symlink") }
  end

  def test_usage_errors_return_two
    status, _output, error = run_cli("meta", "missing")
    assert_equal 1, status
    assert_includes error, "no paper matches"

    status, _output, error = run_cli("import")
    assert_equal 2, status
    assert_includes error, "requires at least one"

    status, _output, error = run_cli("--bogus", "--json")
    assert_equal 2, status
    assert_includes error, "unknown option"

    status, _output, error = run_cli("--path", "--json")
    assert_equal 2, status
    assert_includes error, "--path requires a value"

    status, _output, error = run_cli("search", "attention", "--bogus")
    assert_equal 2, status
    assert_includes error, "unknown option"

    [
      ["open", " "],
      ["info", " "],
      ["meta", " ", "--status", "read"],
      ["update", " "],
      ["remove", " ", "--yes"]
    ].each do |arguments|
      status, _output, selector_error = run_cli(*arguments)
      assert_equal 2, status, arguments.inspect
      assert_includes selector_error, "requires a selector"
    end
  end
end
