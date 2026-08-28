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
      assert Dir.exist?(File.join(library.root, ".wrq", "versions"))
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
      assert_equal 1, Dir.entries(library.library_path).grep(/\.pdf\z/).length
      assert_equal 1, Dir.entries(library.paths.versions).grep(/\.pdf\z/).length
      assert result.paper.asset_for_version(1).path.start_with?(".wrq/versions/")
      assert result.paper.asset_for_version(2).path.start_with?("library/")
      assert_equal 2, result.paper.current_asset.version

      record = JSON.parse(File.read(library.paths.record_path(result.paper.key)))
      assert_equal 2, record.dig("active_asset", "version")
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

  def test_reusing_an_older_hash_for_new_version_restores_it_as_visible_active_asset
    with_library do |library, directory|
      first = File.join(directory, "v1.pdf")
      second = File.join(directory, "v2.pdf")
      third = File.join(directory, "v3.pdf")
      write_pdf(first, "payload-a")
      write_pdf(second, "payload-b")
      write_pdf(third, "payload-a")

      library.ingest_pdf(identity: Wrq::Identity.parse("2401.01234v1"), source_path: first)
      library.ingest_pdf(identity: Wrq::Identity.parse("2401.01234v2"), source_path: second)
      result = library.ingest_pdf(identity: Wrq::Identity.parse("2401.01234v3"), source_path: third)

      paper = library.find(result.paper.key)
      assert_equal 3, paper.current_asset.version
      assert paper.asset_for_version(3).path.start_with?("library/")
      assert paper.asset_for_version(1).path.start_with?("library/")
      assert paper.asset_for_version(2).path.start_with?(".wrq/versions/")
      assert_equal paper.asset_for_version(1).path, paper.asset_for_version(3).path
      assert_equal 1, Dir.entries(library.library_path).grep(/\.pdf\z/).length
      assert_equal 1, Dir.entries(library.paths.versions).grep(/\.pdf\z/).length
    end
  end

  def test_explicit_active_asset_survives_record_round_trip
    with_library do |library, directory|
      first = File.join(directory, "v1.pdf")
      second = File.join(directory, "v2.pdf")
      write_pdf(first, "first")
      write_pdf(second, "second")
      library.ingest_pdf(identity: Wrq::Identity.parse("2401.01234v1"), source_path: first)
      result = library.ingest_pdf(identity: Wrq::Identity.parse("2401.01234v2"), source_path: second)

      library.update(result.paper.key) do |paper|
        paper.set_active_asset!(paper.asset_for_version(1))
      end

      reloaded = library.find(result.paper.key)
      assert_equal 1, reloaded.current_asset.version
      assert_equal reloaded.asset_for_version(1).sha256,
        reloaded.to_h.dig("active_asset", "sha256")
    end
  end

  def test_hash_collision_between_distinct_external_ids_deduplicates_without_merging_metadata
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
        source_path: second,
        metadata: { "title" => "Second provider record" }
      )

      assert duplicate.deduplicated?
      assert_equal original.paper, library.find("2401.01234")
      assert_equal "Second provider record", library.find("2402.12345").title
      assert_equal 2, library.papers.length
      assert_equal 2, Dir.entries(library.library_path).grep(/\.pdf\z/).length
      assert_equal File.stat(original.path).ino, File.stat(duplicate.path).ino
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
        source_path: first_arxiv,
        source_url: "https://arxiv.org/pdf/2401.01234v1.pdf"
      )
      updated = library.ingest_pdf(
        identity: Wrq::Identity.parse("2401.01234v2"),
        source_path: second_arxiv
      )

      assert_equal "arxiv:2401.01234", aliased.paper.key
      assert_equal "arxiv:2401.01234", updated.paper.key
      assert_equal [1, 2], updated.paper.assets.map(&:version).sort
      assert_equal "https://arxiv.org/pdf/2401.01234v1.pdf", aliased.asset.source_url
      assert_nil library.find_by_key(local.paper.key)
      assert_equal 1, library.papers.length
    end
  end

  def test_promoting_local_bytes_into_existing_record_keeps_only_new_active_version_visible
    with_library do |library, directory|
      canonical_source = File.join(directory, "canonical-v1.pdf")
      local_source = File.join(directory, "local-v2.pdf")
      provider_source = File.join(directory, "provider-v2.pdf")
      write_pdf(canonical_source, "canonical version one")
      write_pdf(local_source, "local version two")
      write_pdf(provider_source, "local version two")

      library.ingest_pdf(
        identity: Wrq::Identity.parse("2401.01234v1"),
        source_path: canonical_source
      )
      local = library.import_pdf(
        source_path: local_source,
        metadata: { "tags" => ["reviewed"] }
      )
      promoted = library.ingest_pdf(
        identity: Wrq::Identity.parse("2401.01234v2"),
        source_path: provider_source
      )

      paper = library.find("2401.01234")
      assert promoted.deduplicated?
      assert_nil library.find_by_key(local.paper.key)
      assert_equal [1, 2], paper.assets.map(&:version).sort
      assert_equal 2, paper.current_asset.version
      assert paper.asset_for_version(1).path.start_with?(".wrq/versions/")
      assert paper.asset_for_version(2).path.start_with?("library/")
      assert_equal ["reviewed"], paper.metadata["tags"]
      assert_equal 1, Dir.entries(library.library_path).grep(/\.pdf\z/).length
    end
  end

  def test_promoting_older_local_bytes_retains_them_as_an_inactive_version
    with_library do |library, directory|
      canonical_source = File.join(directory, "canonical-v2.pdf")
      local_source = File.join(directory, "local-v1.pdf")
      provider_source = File.join(directory, "provider-v1.pdf")
      write_pdf(canonical_source, "canonical version two")
      write_pdf(local_source, "local version one")
      write_pdf(provider_source, "local version one")

      library.ingest_pdf(
        identity: Wrq::Identity.parse("2401.01234v2"),
        source_path: canonical_source
      )
      local = library.import_pdf(source_path: local_source)
      library.ingest_pdf(
        identity: Wrq::Identity.parse("2401.01234v1"),
        source_path: provider_source
      )

      paper = library.find("2401.01234")
      assert_nil library.find_by_key(local.paper.key)
      assert_equal 2, paper.current_asset.version
      assert paper.asset_for_version(1).path.start_with?(".wrq/versions/")
      assert paper.asset_for_version(2).path.start_with?("library/")
      assert_equal 1, Dir.entries(library.library_path).grep(/\.pdf\z/).length
      assert_equal 1, Dir.entries(library.paths.versions).grep(/\.pdf\z/).length
    end
  end

  def test_activation_rolls_back_file_moves_when_record_save_is_interrupted
    with_library do |library, directory|
      first = File.join(directory, "v1.pdf")
      second = File.join(directory, "v2.pdf")
      write_pdf(first, "first payload")
      write_pdf(second, "second payload")
      library.ingest_pdf(identity: Wrq::Identity.parse("2401.01234v1"), source_path: first)
      library.ingest_pdf(identity: Wrq::Identity.parse("2401.01234v2"), source_path: second)

      original_save = library.method(:save_unlocked)
      interrupt_once = true
      library.define_singleton_method(:save_unlocked) do |paper|
        if interrupt_once && paper.current_asset.version == 1
          interrupt_once = false
          raise Interrupt, "injected record interruption"
        end
        original_save.call(paper)
      end

      assert_raises(Interrupt) { library.activate_asset("2401.01234", version: 1) }

      paper = library.find("2401.01234")
      assert_equal 2, paper.current_asset.version
      assert paper.asset_for_version(1).path.start_with?(".wrq/versions/")
      assert paper.asset_for_version(2).path.start_with?("library/")
      assert File.file?(library.asset_path(paper.asset_for_version(1)))
      assert File.file?(library.asset_path(paper.asset_for_version(2)))
    end
  end

  def test_local_promotion_rolls_back_file_moves_when_save_is_interrupted
    with_library do |library, directory|
      canonical_source = File.join(directory, "canonical-v1.pdf")
      local_source = File.join(directory, "local-v2.pdf")
      provider_source = File.join(directory, "provider-v2.pdf")
      write_pdf(canonical_source, "canonical version one")
      write_pdf(local_source, "local version two")
      write_pdf(provider_source, "local version two")
      library.ingest_pdf(
        identity: Wrq::Identity.parse("2401.01234v1"),
        source_path: canonical_source
      )
      local = library.import_pdf(source_path: local_source)

      original_save = library.method(:save_unlocked)
      interrupt_once = true
      library.define_singleton_method(:save_unlocked) do |paper|
        if interrupt_once && paper.key == "arxiv:2401.01234" && paper.assets.length == 2
          interrupt_once = false
          raise Interrupt, "injected promotion interruption"
        end
        original_save.call(paper)
      end

      assert_raises(Interrupt) do
        library.ingest_pdf(
          identity: Wrq::Identity.parse("2401.01234v2"),
          source_path: provider_source
        )
      end

      canonical = library.find("2401.01234")
      restored_local = library.find_by_key(local.paper.key)
      assert_equal [1], canonical.assets.map(&:version)
      assert_equal 1, canonical.current_asset.version
      refute_nil restored_local
      assert canonical.current_asset.path.start_with?("library/")
      assert restored_local.current_asset.path.start_with?("library/")
      assert File.file?(library.asset_path(canonical.current_asset))
      assert File.file?(library.asset_path(restored_local.current_asset))
      assert_empty Dir.entries(library.paths.tmp).grep(/\.part\z/)
    end
  end

  def test_local_duplicate_of_canonical_paper_reuses_record_without_overwriting_metadata
    with_library do |library, directory|
      canonical_source = File.join(directory, "canonical.pdf")
      local_copy = File.join(directory, "local-copy.pdf")
      write_pdf(canonical_source, "same work")
      write_pdf(local_copy, "same work")

      canonical = library.ingest_pdf(
        identity: Wrq::Identity.parse("2401.01234v1"),
        source_path: canonical_source,
        metadata: { "title" => "Trusted provider title" }
      )
      duplicate = library.import_pdf(
        source_path: local_copy,
        metadata: { "title" => "local copy" },
        aliases: ["local-copy.pdf"]
      )

      assert duplicate.deduplicated?
      assert_equal canonical.paper.key, duplicate.paper.key
      assert_equal "Trusted provider title", library.find("2401.01234").title
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

  def test_ambiguous_exact_alias_is_rejected_instead_of_selecting_first_record
    with_library do |library, directory|
      first = File.join(directory, "first.pdf")
      second = File.join(directory, "second.pdf")
      write_pdf(first, "first")
      write_pdf(second, "second")
      library.import_pdf(source_path: first, aliases: ["shared-name"])
      library.import_pdf(source_path: second, aliases: ["shared-name"])

      error = assert_raises(Wrq::InvalidRecord) { library.find("shared-name") }
      assert_includes error.message, "ambiguous paper alias"
    end
  end

  def test_transactional_update_reloads_the_record_under_the_lock
    with_library do |library, directory|
      source = File.join(directory, "paper.pdf")
      write_pdf(source)
      library.ingest_pdf(
        identity: Wrq::Identity.parse("2401.01234"),
        source_path: source,
        metadata: { "status" => "unread", "tags" => [] }
      )
      stale = library.find("2401.01234")

      library.update("2401.01234") { |fresh| fresh.merge_metadata!({ "status" => "read" }) }
      library.update("2401.01234") do |fresh|
        fresh.merge_metadata!({ "tags" => ["important"] })
      end

      reloaded = library.find("2401.01234")
      assert_equal "unread", stale.metadata["status"]
      assert_equal "read", reloaded.metadata["status"]
      assert_equal ["important"], reloaded.metadata["tags"]
    end
  end

  def test_paths_reject_traversal_and_unsafe_filenames
    with_library do |library, _directory|
      assert_raises(Wrq::UnsafePath) { library.paths.safe_join(library.root, "../escape") }
      assert_raises(Wrq::UnsafePath) { library.paths.asset_path(".wrq/records/paper.json") }
      assert_raises(Wrq::UnsafePath) { library.paths.library_file("nested/paper.pdf") }
    end
  end

  def test_catalog_rejects_symlinked_record_files
    with_library do |library, directory|
      source = File.join(directory, "paper.pdf")
      write_pdf(source)
      result = library.ingest_pdf(
        identity: Wrq::Identity.parse("2401.01234"),
        source_path: source
      )
      real_record = library.paths.record_path(result.paper.key)
      external = File.join(directory, "external-record.json")
      File.rename(real_record, external)
      File.symlink(external, real_record)

      assert_raises(Wrq::UnsafePath) { library.papers }
      assert_raises(Wrq::UnsafePath) { library.find("2401.01234") }
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
