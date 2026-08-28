# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/wrq/search"

class WrqSearchTest < Minitest::Test
  Record = Struct.new(:attributes) do
    def to_h
      attributes
    end
  end

  def test_empty_query_sorts_by_recency
    now = Time.new(2026, 8, 28, 12, 0, 0, "+00:00")
    old = { canonical_id: "1", title: "Old", added_at: now - 86_400 }
    recent = { canonical_id: "2", title: "Recent", added_at: now - 60 }

    results = Wrq::Search.new([old, recent], now: now).call("")

    assert_equal [recent, old], results.map(&:record)
  end

  def test_weight_order_is_id_title_authors_venue_tags_abstract
    records = [
      { canonical_id: "abstract", title: "A", abstract: "needle" },
      { canonical_id: "tags", title: "B", tags: ["needle"] },
      { canonical_id: "venue", title: "C", venue: "needle" },
      { canonical_id: "author", title: "D", authors: ["needle"] },
      { canonical_id: "title", title: "needle", authors: ["Someone"] }
    ]

    results = Wrq::Search.new(records).call("needle")

    assert_equal %w[title author tags venue abstract], results.map { |result| result.record[:canonical_id] }
    assert_equal :title, results[0].matched_field
    assert_equal :authors, results[1].matched_field
  end

  def test_exact_normalized_arxiv_id_has_highest_weight
    exact = { canonical_id: "arxiv:1706.03762", title: "Transformers" }
    title = { canonical_id: "arxiv:9999.00001", title: "Notes on 1706.03762" }

    results = Wrq::Search.new([title, exact]).call("https://arxiv.org/abs/1706.03762v7")

    assert_equal exact, results.first.record
    assert_equal :canonical_id, results.first.matched_field
  end

  def test_every_accepted_paper_url_form_exactly_matches_local_identity
    record = { canonical_id: "arxiv:1706.03762", title: "Transformers" }
    references = [
      "https://arxiv.org/abs/1706.03762v7",
      "https://arxiv.org/pdf/1706.03762v7.pdf",
      "https://arxiv.org/html/1706.03762v7",
      "https://huggingface.co/papers/1706.03762.md",
      "https://hf.co/papers/1706.03762"
    ]

    references.each do |reference|
      result = Wrq::Search.new([record]).call(reference).first
      assert_equal record, result.record, reference
      assert_equal :canonical_id, result.matched_field, reference
    end
  end

  def test_natural_spaces_match_and_title_positions_are_display_offsets
    record = { canonical_id: "1706.03762", title: "Attention Is All You Need" }

    result = Wrq::Search.new([record]).call("is all").first

    assert_equal :title, result.matched_field
    assert_equal [10, 11, 12, 13, 14, 15], result.highlight_positions
    assert_equal result.highlight_positions, result[:highlight_positions]
  end

  def test_title_positions_are_returned_when_title_and_another_field_match
    record = { canonical_id: "needle-paper", title: "A Needle Study", authors: ["Needle"] }

    result = Wrq::Search.new([record]).call("needle").first

    assert_equal :title, result.matched_field
    assert_equal [2, 3, 4, 5, 6, 7], result.title_highlight_positions
  end

  def test_title_positions_refer_to_original_whitespace
    record = { canonical_id: "spaces", title: "  Deep   Learning" }

    result = Wrq::Search.new([record]).call("deep learning").first

    assert_equal [2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14, 15, 16], result.highlight_positions
  end

  def test_accepts_string_keys_and_to_h_records
    record = Record.new({
      "canonical_id" => "arxiv:1234.56789",
      "title" => "Paper Objects",
      "authors" => [{ "name" => "Ada Lovelace" }]
    })

    result = Wrq::Search.new([record]).call("ada").first

    assert_equal record, result.record
    assert_equal :authors, result[:matched_field]
    assert_equal "Paper Objects", result[:title]
  end

  def test_reads_canonical_key_and_nested_paper_metadata
    record = Record.new({
      "key" => "arxiv:1706.03762",
      "metadata" => {
        "title" => "Attention Is All You Need",
        "authors" => ["Ashish Vaswani"],
        "journal_ref" => "NeurIPS 2017"
      },
      "updated_at" => "2026-08-28T00:00:00Z"
    })

    exact = Wrq::Search.new([record]).call("1706.03762").first
    venue = Wrq::Search.new([record]).call("neurips").first

    assert_equal :canonical_id, exact.matched_field
    assert_equal :venue, venue.matched_field
    assert_equal "Attention Is All You Need", venue[:title]
  end

  def test_multi_term_query_can_match_across_research_metadata_fields
    record = {
      canonical_id: "arxiv:1706.03762",
      title: "Attention Is All You Need",
      authors: ["Ashish Vaswani"],
      venue: "NeurIPS"
    }

    result = Wrq::Search.new([record]).call("vaswani neurips").first

    assert_equal record, result.record
    assert_equal :multiple, result.matched_field
    assert_empty result.highlight_positions
    assert_empty Wrq::Search.new([record]).call("vaswani icml")
  end

  def test_ties_have_a_deterministic_content_order
    a = { canonical_id: "arxiv:2", title: "Same", authors: ["B"] }
    b = { canonical_id: "arxiv:1", title: "Same", authors: ["A"] }
    search = Wrq::Search.new([a, b], now: Time.at(0))

    assert_equal [b, a], search.call("same").map(&:record)
    assert_equal [b, a], Wrq::Search.new([b, a], now: Time.at(0)).call("same").map(&:record)
  end

  def test_limit_and_no_match
    records = [
      { canonical_id: "1", title: "Alpha" },
      { canonical_id: "2", title: "Alphabet" }
    ]

    assert_equal 1, Wrq::Search.call(records, "alpha", limit: 1).length
    assert_empty Wrq::Search.call(records, "unrelated")
  end
end
