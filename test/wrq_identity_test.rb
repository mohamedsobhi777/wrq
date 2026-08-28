# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/wrq/identity"

class WrqIdentityTest < Minitest::Test
  def test_normalizes_modern_id_and_separates_version
    identity = Wrq::Identity.parse(" arXiv:1706.03762v7 ")

    assert_equal "1706.03762", identity.base_id
    assert_equal 7, identity.version
    assert_equal "1706.03762v7", identity.versioned_id
    assert_equal "arxiv:1706.03762", identity.canonical_key
    assert identity.modern?
  end

  def test_normalizes_legacy_id
    identity = Wrq::Identity.parse("HEP-TH/9901001v2")

    assert_equal "hep-th/9901001", identity.base_id
    assert_equal 2, identity.version
    assert identity.legacy?
  end

  def test_recognizes_arxiv_abs_and_pdf_urls
    abs = Wrq::Identity.parse("https://arxiv.org/abs/2401.01234v3")
    pdf = Wrq::Identity.parse("https://export.arxiv.org/pdf/hep-th/9901001v2.pdf?download=1")

    assert_equal "2401.01234v3", abs.versioned_id
    assert_equal "hep-th/9901001v2", pdf.versioned_id
  end

  def test_recognizes_hugging_face_paper_url
    identity = Wrq::Identity.parse("https://huggingface.co/papers/1706.03762v5#discussion")

    assert_equal "1706.03762", identity.base_id
    assert_equal 5, identity.version
  end

  def test_recognizes_hugging_face_short_url_and_markdown_suffix
    short = Wrq::Identity.parse("https://hf.co/papers/1706.03762")
    markdown = Wrq::Identity.parse("https://huggingface.co/papers/1706.03762.md")

    assert_equal "1706.03762", short.base_id
    assert_equal "1706.03762", markdown.base_id
  end

  def test_rejects_noncanonical_six_digit_modern_sequences
    assert_raises(Wrq::InvalidIdentity) { Wrq::Identity.parse("9912.123456v2") }
  end

  def test_aliases_include_versionless_key_and_source_urls
    identity = Wrq::Identity.parse("https://arxiv.org/abs/1706.03762v2")

    assert_includes identity.aliases, "arxiv:1706.03762"
    assert_includes identity.aliases, "1706.03762v2"
    assert_includes identity.aliases, "https://arxiv.org/pdf/1706.03762v2.pdf"
    assert_includes identity.aliases, "https://huggingface.co/papers/1706.03762v2"
  end

  def test_rejects_bad_month_partial_id_and_unrecognized_url
    assert_raises(Wrq::InvalidIdentity) { Wrq::Identity.parse("2413.01234") }
    assert_raises(Wrq::InvalidIdentity) { Wrq::Identity.parse("1706.037") }
    assert_raises(Wrq::InvalidIdentity) { Wrq::Identity.parse("https://example.com/1706.03762") }
    assert_nil Wrq::Identity.recognize("attention transformer")
  end

  def test_local_identity_is_canonicalized_from_sha256
    digest = "AB" * 32
    identity = Wrq::Identity.local(digest)

    assert identity.local?
    assert_equal "ab" * 32, identity.base_id
    assert_equal "sha256:#{"ab" * 32}", identity.canonical_key
    assert_equal identity, Wrq::Identity.from_h(identity.to_h)
    assert_raises(Wrq::InvalidIdentity) { identity.with_version(2) }
  end
end
