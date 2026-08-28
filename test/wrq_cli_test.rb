# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "test_helper"
require_relative "../lib/wrq/cli"

class WrqCliTest < Minitest::Test
  class FakeArxiv
    attr_reader :fetches, :downloads

    def initialize(latest_version: 7)
      @latest_version = latest_version
      @fetches = []
      @downloads = []
    end

    def fetch(reference)
      identity = Wrq::Identity.parse(reference)
      version = identity.version || @latest_version
      @fetches << identity.versioned_id
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
        publication_doi: nil,
        abstract_url: "https://arxiv.org/abs/#{identity.base_id}v#{version}",
        pdf_url: "https://arxiv.org/pdf/#{identity.base_id}v#{version}.pdf",
        aliases: [identity.base_id, "arXiv:#{identity.base_id}"],
        provider_data: { arxiv: { resolved_id: "#{identity.base_id}v#{version}" } }
      }
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
  end

  def test_usage_errors_return_two
    status, _output, error = run_cli("meta", "missing")
    assert_equal 1, status
    assert_includes error, "no paper matches"

    status, _output, error = run_cli("import")
    assert_equal 2, status
    assert_includes error, "requires at least one"
  end
end
