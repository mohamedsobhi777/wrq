# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require_relative "../lib/wrq/library"

class WrqLibraryTest < Minitest::Test
  def with_library
    Dir.mktmpdir("wrq-library-test") do |directory|
      library = Wrq::Library.new(File.join(directory, "papers"))
      yield library, directory
    end
  end

  def write_pdf(path, body = "paper")
    File.open(path, "wb") { |io| io.write("%PDF-1.7\n#{body}\n%%EOF\n") }
  end

  def test_default_root_and_prepared_layout
    with_library do |library, directory|
      expected = File.join(directory, "configured")
      assert_equal expected, Wrq::Library.default_root("WRQ_PATH" => expected)

      library.prepare!
      assert Dir.exist?(library.library_path)
      assert Dir.exist?(File.join(library.root, ".wrq", "records"))
      assert Dir.exist?(File.join(library.root, ".wrq", "tmp"))
      assert Dir.exist?(File.join(library.root, ".wrq", "cache"))
      assert Dir.exist?(File.join(library.root, ".wrq", "trash"))
    end
  end

  def test_library_accepts_keyword_style_root_for_cli_callers
    Dir.mktmpdir("wrq-keyword-root") do |directory|
      library = Wrq::Library.new(root: File.join(directory, "papers"))
      assert_equal File.join(directory, "papers"), library.root
    end
  end

  def test_ingest_writes_visible_pdf_and_atomic_schema_one_record
    with_library do |library, directory|
      source = File.join(directory, "download.pdf")
      write_pdf(source, "version one")
      identity = Wrq::Identity.parse("1706.03762v1")

      result = library.ingest_pdf(
        identity: identity,
        source_path: source,
        metadata: { title: "Attention Is All You Need", authors: ["A. Author"] },
        source_url: identity.arxiv_pdf_url
      )

      refute result.deduplicated?
      assert File.file?(result.path)
      assert result.path.start_with?(library.library_path + File::SEPARATOR)
      assert_equal "Attention Is All You Need", result.paper.title
      assert_equal result.paper, library.find("https://huggingface.co/papers/1706.03762")
      assert_equal result.paper, library.find(result.asset.sha256)

      record_path = library.paths.record_path("arxiv:1706.03762")
      record = JSON.parse(File.read(record_path))
      assert_equal 1, record["schema_version"]
      assert_equal "arxiv:1706.03762", record["key"]
      assert_equal 1, record["assets"].first["version"]
      assert_empty Dir.entries(library.paths.records).grep(/\.tmp-/)
    end
  end

  def test_keeps_distinct_arxiv_versions_in_one_record
    with_library do |library, directory|
      first = File.join(directory, "v1.pdf")
      second = File.join(directory, "v2.pdf")
      write_pdf(first, "first payload")
      write_pdf(second, "second payload")

      library.ingest_pdf(identity: Wrq::Identity.parse("2401.01234v1"), source_path: first)
      result = library.ingest_pdf(identity: Wrq::Identity.parse("2401.01234v2"), source_path: second)

      assert_equal [1, 2], result.paper.assets.map(&:version).sort
      assert_equal 2, Dir.entries(library.library_path).grep(/\.pdf\z/).length
      assert_equal 2, result.paper.current_asset.version
    end
  end

  def test_same_bytes_for_another_version_reuse_one_pdf
    with_library do |library, directory|
      first = File.join(directory, "first.pdf")
      second = File.join(directory, "second.pdf")
      write_pdf(first, "identical")
      write_pdf(second, "identical")

      library.ingest_pdf(identity: Wrq::Identity.parse("2401.01234v1"), source_path: first)
      result = library.ingest_pdf(identity: Wrq::Identity.parse("2401.01234v2"), source_path: second)

      assert result.deduplicated?
      assert_equal 2, result.paper.assets.length
      assert_equal 1, result.paper.assets.map(&:path).uniq.length
      assert_equal 1, Dir.entries(library.library_path).grep(/\.pdf\z/).length
    end
  end

  def test_hash_deduplication_adds_second_identity_as_alias
    with_library do |library, directory|
      first = File.join(directory, "first.pdf")
      second = File.join(directory, "second.pdf")
      write_pdf(first, "same work")
      write_pdf(second, "same work")

      original = library.ingest_pdf(
        identity: Wrq::Identity.parse("2401.01234v1"),
        source_path: first
      )
      duplicate = library.ingest_pdf(
        identity: Wrq::Identity.parse("2402.12345v1"),
        source_path: second
      )

      assert duplicate.deduplicated?
      assert_equal original.paper.key, duplicate.paper.key
      assert_equal duplicate.paper, library.find("2402.12345")
      assert_equal 1, library.papers.length
      assert_equal 1, Dir.entries(library.library_path).grep(/\.pdf\z/).length
    end
  end

  def test_an_aliased_identity_adds_future_versions_to_the_same_record
    with_library do |library, directory|
      local_source = File.join(directory, "local.pdf")
      first_arxiv = File.join(directory, "arxiv-v1.pdf")
      second_arxiv = File.join(directory, "arxiv-v2.pdf")
      write_pdf(local_source, "first version")
      write_pdf(first_arxiv, "first version")
      write_pdf(second_arxiv, "second version")

      local = library.import_pdf(source_path: local_source)
      aliased = library.ingest_pdf(
        identity: Wrq::Identity.parse("2401.01234v1"),
        source_path: first_arxiv
      )
      updated = library.ingest_pdf(
        identity: Wrq::Identity.parse("2401.01234v2"),
        source_path: second_arxiv
      )

      assert_equal local.paper.key, aliased.paper.key
      assert_equal local.paper.key, updated.paper.key
      assert_equal [nil, 2], updated.paper.assets.map(&:version).sort_by { |value| value || 0 }
      assert_equal 1, library.papers.length
    end
  end

  def test_import_without_arxiv_id_uses_local_hash_identity_and_can_move
    with_library do |library, directory|
      source = File.join(directory, "unknown.pdf")
      write_pdf(source, "unknown paper")

      result = library.import_pdf(
        source_path: source,
        metadata: { "title" => "An Unknown Paper" },
        aliases: ["unknown-paper"],
        move: true
      )

      assert result.paper.identity.local?
      assert_equal "sha256:#{result.asset.sha256}", result.paper.key
      refute File.exist?(source)
      assert_equal result.paper, library.find("unknown-paper")
      assert_equal result.paper, library.find("sha256:#{result.asset.sha256}")
    end
  end

  def test_metadata_and_alias_mutation_are_persisted
    with_library do |library, directory|
      source = File.join(directory, "paper.pdf")
      write_pdf(source)
      library.ingest_pdf(identity: Wrq::Identity.parse("2401.01234"), source_path: source)

      library.update_metadata("2401.01234", venue: "NeurIPS", year: 2017)
      library.add_alias("2401.01234", "transformer-paper")

      reloaded = library.find("transformer-paper")
      assert_equal "NeurIPS", reloaded.metadata["venue"]
      assert_equal 2017, reloaded.metadata["year"]
    end
  end

  def test_paths_reject_traversal_and_unsafe_filenames
    with_library do |library, _directory|
      assert_raises(Wrq::UnsafePath) { library.paths.safe_join(library.root, "../escape") }
      assert_raises(Wrq::UnsafePath) { library.paths.asset_path(".wrq/records/paper.json") }
      assert_raises(Wrq::UnsafePath) { library.paths.library_file("nested/paper.pdf") }
    end
  end

  def test_invalid_pdf_leaves_no_asset_or_record
    with_library do |library, directory|
      source = File.join(directory, "not-a-pdf")
      File.open(source, "wb") { |io| io.write("not actually a PDF") }

      assert_raises(Wrq::InvalidRecord) do
        library.ingest_pdf(identity: Wrq::Identity.parse("2401.01234"), source_path: source)
      end
      assert_empty library.papers
      assert_empty Dir.entries(library.library_path).grep(/\.pdf\z/)
      assert_empty Dir.entries(library.paths.tmp).grep(/\.part\z/)
    end
  end

  def test_trash_moves_record_and_assets_recoverably
    with_library do |library, directory|
      source = File.join(directory, "paper.pdf")
      write_pdf(source)
      ingested = library.ingest_pdf(
        identity: Wrq::Identity.parse("2401.01234v1"),
        source_path: source
      )

      trashed = library.trash("2401.01234", Time.utc(2026, 8, 28, 12, 0, 0))

      assert_nil library.find("2401.01234")
      refute File.exist?(ingested.path)
      assert trashed.path.start_with?(library.paths.trash + File::SEPARATOR)
      assert File.file?(File.join(trashed.path, "record.json"))
      assert trashed.files.any? { |path| path.end_with?(".pdf") }
    end
  end

  def test_codec_rejects_unknown_schema
    error = assert_raises(Wrq::InvalidRecord) do
      Wrq::MetadataCodec.load('{"schema_version":2}')
    end
    assert_match(/unsupported record schema/, error.message)
  end
end
