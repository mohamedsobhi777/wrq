# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/wrq/http_client"
require_relative "../lib/wrq/throttle"
require_relative "../lib/wrq/sources/arxiv"
require_relative "../lib/wrq/sources/hugging_face"

class WrqSourcesTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/wrq", __dir__)

  class FakeHTTP
    attr_reader :gets, :downloads

    def initialize(body: nil, error: nil)
      @body = body
      @error = error
      @gets = []
      @downloads = []
    end

    def get(url, headers:, max_bytes:)
      @gets << { url: url, headers: headers, max_bytes: max_bytes }
      raise @error if @error

      { status: 200, headers: {}, body: @body, bytes: @body.to_s.bytesize, url: url }
    end

    def download_pdf(url, destination:, headers:, max_bytes:)
      @downloads << {
        url: url,
        destination: destination,
        headers: headers,
        max_bytes: max_bytes
      }
      { path: destination, sha256: "fixture-sha", bytes: 80, url: url }
    end
  end

  class FakeThrottle
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def wait
      @calls += 1
    end
  end

  class FixtureResponse
    attr_reader :code

    def initialize(body, headers = {})
      @body = body
      @headers = headers
      @code = "200"
    end

    def [](name)
      @headers[name.downcase]
    end

    def each_header(&block)
      @headers.each(&block)
    end

    def read_body
      midpoint = @body.bytesize / 2
      yield @body.byteslice(0, midpoint)
      yield @body.byteslice(midpoint, @body.bytesize - midpoint)
    end
  end

  class FixtureHTTPClient < Wrq::HTTPClient
    def initialize(body, headers = {})
      super(allowed_hosts: ["fixture.test"])
      @fixture_response = FixtureResponse.new(body, headers)
    end

    private

    def perform(url, _headers, _redirect_count)
      yield @fixture_response, url
    end
  end

  def fixture(name)
    File.read(File.join(FIXTURES, name))
  end

  def with_env(values)
    previous = {}
    values.each do |name, value|
      previous[name] = ENV[name]
      ENV[name] = value
    end
    yield
  ensure
    previous.each do |name, value|
      if value.nil?
        ENV.delete(name)
      else
        ENV[name] = value
      end
    end
  end

  def test_arxiv_normalizes_modern_versioned_legacy_and_urls
    modern = Wrq::Sources::Arxiv.normalize_identifier("1706.03762v7")
    assert_equal "1706.03762", modern[:base_id]
    assert_equal 7, modern[:requested_version]

    legacy = Wrq::Sources::Arxiv.normalize_identifier("hep-th/9901001v2")
    assert_equal "hep-th/9901001", legacy[:base_id]
    assert_equal 2, legacy[:requested_version]

    mixed_case_legacy = Wrq::Sources::Arxiv.normalize_identifier("Math.GT/0309136V1")
    assert_equal "math.gt/0309136v1", mixed_case_legacy[:requested_id]

    hf_url = Wrq::Sources::Arxiv.normalize_identifier("https://huggingface.co/papers/1706.03762")
    assert_equal "1706.03762", hf_url[:base_id]

    pdf_url = Wrq::Sources::Arxiv.normalize_identifier("https://arxiv.org/pdf/1706.03762v7.pdf")
    assert_equal "1706.03762v7", pdf_url[:requested_id]
  end

  def test_arxiv_rejects_non_identifiers
    assert_raises(Wrq::Sources::Arxiv::InvalidIdentifier) do
      Wrq::Sources::Arxiv.normalize_identifier("attention is all you need")
    end
    assert_raises(Wrq::Sources::Arxiv::InvalidIdentifier) do
      Wrq::Sources::Arxiv.normalize_identifier("https://evil.example/abs/1706.03762")
    end
    assert_raises(Wrq::Sources::Arxiv::InvalidIdentifier) do
      Wrq::Sources::Arxiv.normalize_identifier("1713.03762")
    end
    assert_raises(Wrq::Sources::Arxiv::InvalidIdentifier) do
      Wrq::Sources::Arxiv.normalize_identifier("1706.03762v0")
    end
  end

  def test_arxiv_parses_complete_atom_metadata
    source = Wrq::Sources::Arxiv.new(
      http_client: FakeHTTP.new,
      throttle: FakeThrottle.new
    )
    metadata = source.parse_atom(fixture("arxiv_attention.atom"), requested_id: "1706.03762v3")

    assert_equal "arxiv:1706.03762", metadata[:canonical_key]
    assert_equal "1706.03762", metadata[:base_id]
    assert_equal 3, metadata[:requested_version]
    assert_equal "1706.03762v7", metadata[:resolved_id]
    assert_equal 7, metadata[:resolved_version]
    assert_equal "Attention Is All You Need", metadata[:title]
    assert_equal ["Ashish Vaswani", "Noam Shazeer"], metadata[:authors]
    assert_match(/dominant sequence transduction/, metadata[:abstract])
    assert_equal ["cs.CL", "cs.LG"], metadata[:categories]
    assert_equal "cs.CL", metadata[:primary_category]
    assert_equal "2017-06-12T17:57:34Z", metadata[:published_at]
    assert_equal "2023-08-02T01:08:53Z", metadata[:updated_at]
    assert_equal "15 pages, 5 figures", metadata[:comment]
    assert_match(/Neural Information Processing Systems/, metadata[:journal_ref])
    assert_equal "10.5555/3295222.3295349", metadata[:publication_doi]
    assert_equal "https://arxiv.org/abs/1706.03762v7", metadata[:abstract_url]
    assert_equal "https://arxiv.org/pdf/1706.03762v7", metadata[:pdf_url]
    assert_includes metadata[:aliases], "arXiv:1706.03762v3"
    assert_equal "http://arxiv.org/abs/1706.03762v7", metadata.dig(:provider_data, :arxiv, :atom_id)
  end

  def test_arxiv_parses_legacy_atom_metadata
    source = Wrq::Sources::Arxiv.new(http_client: FakeHTTP.new, throttle: FakeThrottle.new)
    metadata = source.parse_atom(fixture("arxiv_legacy.atom"), requested_id: "hep-th/9901001")

    assert_equal "hep-th/9901001", metadata[:base_id]
    assert_equal "hep-th/9901001v2", metadata[:resolved_id]
    assert_equal "https://arxiv.org/pdf/hep-th/9901001v2", metadata[:pdf_url]
    assert_nil metadata[:comment]
    assert_nil metadata[:publication_doi]
  end

  def test_arxiv_not_found_feed_raises
    source = Wrq::Sources::Arxiv.new(http_client: FakeHTTP.new, throttle: FakeThrottle.new)
    assert_raises(Wrq::Sources::Arxiv::NotFound) do
      source.parse_atom(fixture("arxiv_not_found.atom"), requested_id: "1706.00000")
    end
  end

  def test_arxiv_fetch_throttles_and_uses_overridden_endpoint
    http = FakeHTTP.new(body: fixture("arxiv_attention.atom"))
    throttle = FakeThrottle.new
    source = Wrq::Sources::Arxiv.new(
      http_client: http,
      throttle: throttle,
      api_url: "http://127.0.0.1:9292/arxiv",
      pdf_url: "http://127.0.0.1:9292/pdf"
    )

    metadata = source.fetch("1706.03762v3")
    assert_equal 1, throttle.calls
    assert_equal "http://127.0.0.1:9292/arxiv?id_list=1706.03762v3", http.gets.first[:url]
    assert_equal "application/atom+xml", http.gets.first[:headers]["Accept"]
    assert_equal "http://127.0.0.1:9292/pdf/1706.03762v7.pdf", metadata[:pdf_url]
  end

  def test_arxiv_honors_environment_endpoint_overrides
    with_env(
      "WRQ_ARXIV_API_URL" => "http://127.0.0.1:9393/atom",
      "WRQ_ARXIV_PDF_URL" => "http://127.0.0.1:9393/pdf"
    ) do
      http = FakeHTTP.new(body: fixture("arxiv_attention.atom"))
      source = Wrq::Sources::Arxiv.new(http_client: http, throttle: FakeThrottle.new)
      metadata = source.fetch("1706.03762")

      assert_equal "http://127.0.0.1:9393/atom?id_list=1706.03762", http.gets.first[:url]
      assert_equal "http://127.0.0.1:9393/pdf/1706.03762v7.pdf", metadata[:pdf_url]
    end
  end

  def test_arxiv_download_delegates_streaming_and_limit
    http = FakeHTTP.new
    source = Wrq::Sources::Arxiv.new(http_client: http, throttle: FakeThrottle.new)
    result = source.download(
      { pdf_url: "https://arxiv.org/pdf/1706.03762v7" },
      destination: "/tmp/wrq-fixture.pdf",
      max_bytes: 1234
    )

    assert_equal "fixture-sha", result[:sha256]
    assert_equal 1234, http.downloads.first[:max_bytes]
    assert_equal "application/pdf", http.downloads.first[:headers]["Accept"]
  end

  def test_hugging_face_parses_tolerant_enrichment_and_preserves_raw_data
    source = Wrq::Sources::HuggingFace.new(http_client: FakeHTTP.new)
    metadata = source.parse_json(fixture("hugging_face_attention.json"), requested_id: "1706.03762v5")

    assert_equal "arxiv:1706.03762", metadata[:canonical_key]
    assert_equal 5, metadata[:requested_version]
    assert_equal "Attention Is All You Need", metadata[:title]
    assert_equal ["Ashish Vaswani", "Noam Shazeer", "Niki Parmar"], metadata[:authors]
    assert_equal "Ashish Vaswani", metadata[:hf_authors].first[:name]
    assert_equal "avaswani", metadata[:hf_authors].first[:username]
    assert_equal 4242, metadata[:upvotes]
    assert_equal "Introduces the Transformer architecture.", metadata[:ai_summary]
    assert_equal "https://example.test/transformer", metadata[:project_page]
    assert_equal "https://github.com/example/transformer", metadata[:github_repo]
    assert_equal "example/transformer", metadata[:models].first["id"]
    assert_equal true,
      metadata.dig(:provider_data, :hugging_face, :raw, "futureField", "kept")
    assert_equal "avaswani",
      metadata.dig(:provider_data, :hugging_face, :authors, 0, :username)
  end

  def test_hugging_face_fetch_uses_base_id_and_token
    http = FakeHTTP.new(body: fixture("hugging_face_attention.json"))
    source = Wrq::Sources::HuggingFace.new(
      http_client: http,
      api_url: "http://127.0.0.1:9292/api/papers",
      token: "secret-token"
    )
    source.fetch("1706.03762v5")

    request = http.gets.first
    assert_equal "http://127.0.0.1:9292/api/papers/1706.03762", request[:url]
    assert_equal "Bearer secret-token", request[:headers]["Authorization"]
  end

  def test_hugging_face_honors_environment_endpoint_override
    with_env("WRQ_HF_API_URL" => "http://127.0.0.1:9494/api/papers") do
      http = FakeHTTP.new(body: fixture("hugging_face_attention.json"))
      source = Wrq::Sources::HuggingFace.new(http_client: http, token: "")
      source.fetch("1706.03762")

      assert_equal "http://127.0.0.1:9494/api/papers/1706.03762", http.gets.first[:url]
    end
  end

  def test_hugging_face_missing_paper_is_optional
    error = Wrq::HTTPClient::HTTPError.new(
      status: 404,
      url: "https://huggingface.co/api/papers/1706.03762"
    )
    source = Wrq::Sources::HuggingFace.new(http_client: FakeHTTP.new(error: error))
    assert_nil source.fetch("1706.03762")
  end

  def test_http_client_rejects_non_https_and_unlisted_hosts_before_network
    client = Wrq::HTTPClient.new(allowed_hosts: ["arxiv.org"])
    assert_raises(Wrq::HTTPClient::InvalidURL) { client.get("http://arxiv.org/abs/1706.03762") }
    assert_raises(Wrq::HTTPClient::InvalidURL) { client.get("https://evil.example/1706.03762") }
    assert_raises(Wrq::HTTPClient::InvalidURL) { client.get("https://token@arxiv.org/1706.03762") }
  end

  def test_http_client_bounds_regular_response_bodies
    client = FixtureHTTPClient.new("metadata")
    response = client.get("https://fixture.test/metadata", max_bytes: 8)
    assert_equal "metadata", response[:body]
    assert_equal 8, response[:bytes]

    assert_raises(Wrq::HTTPClient::ResponseTooLarge) do
      client.get("https://fixture.test/metadata", max_bytes: 7)
    end
  end

  def test_http_client_strips_credentials_from_redirect_headers
    client = Wrq::HTTPClient.new(allowed_hosts: ["huggingface.co"])
    clean = client.send(
      :strip_sensitive_headers,
      "Authorization" => "Bearer secret",
      "Cookie" => "private=1",
      "Accept" => "application/json"
    )

    assert_equal({ "Accept" => "application/json" }, clean)
  end

  def test_http_client_streams_valid_pdf_and_calculates_sha256
    body = fixture("minimal.pdf")
    client = FixtureHTTPClient.new(body, "content-type" => "application/pdf")
    Dir.mktmpdir("wrq-pdf") do |directory|
      destination = File.join(directory, "paper.pdf")
      result = client.download_pdf("https://fixture.test/paper.pdf", destination: destination)

      assert_equal body, File.read(destination)
      assert_equal body.bytesize, result[:bytes]
      assert_equal Digest::SHA256.hexdigest(body), result[:sha256]
      assert_equal "application/pdf", result[:content_type]
      assert_empty Dir.glob("#{destination}.part-*")
    end
  end

  def test_http_client_rejects_non_pdf_without_clobbering_destination
    client = FixtureHTTPClient.new(fixture("not_a_pdf.txt"))
    Dir.mktmpdir("wrq-invalid-pdf") do |directory|
      destination = File.join(directory, "paper.pdf")
      File.write(destination, "existing paper")

      assert_raises(Wrq::HTTPClient::InvalidPDF) do
        client.download_pdf("https://fixture.test/not-pdf", destination: destination)
      end
      assert_equal "existing paper", File.read(destination)
      assert_empty Dir.glob("#{destination}.part-*")
    end
  end

  def test_http_client_enforces_streamed_pdf_limit
    body = fixture("minimal.pdf")
    client = FixtureHTTPClient.new(body)
    Dir.mktmpdir("wrq-large-pdf") do |directory|
      destination = File.join(directory, "paper.pdf")
      assert_raises(Wrq::HTTPClient::ResponseTooLarge) do
        client.download_pdf(
          "https://fixture.test/paper.pdf",
          destination: destination,
          max_bytes: body.bytesize - 1
        )
      end
      refute File.exist?(destination)
      assert_empty Dir.glob("#{destination}.part-*")
    end
  end

  def test_throttle_persists_timestamp_and_waits_for_remaining_interval
    Dir.mktmpdir("wrq-throttle") do |directory|
      now = 100.0
      sleeps = []
      throttle = Wrq::Throttle.new(
        path: File.join(directory, "state", "arxiv.throttle"),
        interval: 3,
        clock: proc { now },
        sleeper: proc { |seconds| sleeps << seconds; now += seconds }
      )

      assert_equal 0.0, throttle.wait
      now = 101.0
      assert_in_delta 2.0, throttle.wait, 0.0001
      assert_in_delta 2.0, sleeps.first, 0.0001
      assert_in_delta 103.0, File.read(File.join(directory, "state", "arxiv.throttle")).to_f, 0.0001
    end
  end

  def test_throttle_can_be_disabled_for_tests
    Dir.mktmpdir("wrq-throttle-disabled") do |directory|
      path = File.join(directory, "never-created")
      throttle = Wrq::Throttle.new(path: path, disabled: true)
      assert_equal 0.0, throttle.wait
      refute File.exist?(path)
    end
  end

  def test_throttle_disable_environment_prevents_state_write
    Dir.mktmpdir("wrq-throttle-env") do |directory|
      path = File.join(directory, "never-created")
      with_env("WRQ_DISABLE_THROTTLE" => "1") do
        assert_equal 0.0, Wrq::Throttle.new(path: path).wait
      end
      refute File.exist?(path)
    end
  end
end
