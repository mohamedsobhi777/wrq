# frozen_string_literal: true

require "rexml/document"
require "rexml/xpath"
require "uri"
require_relative "../http_client"
require_relative "../throttle"

module Wrq
  module Sources
    # Metadata and PDF access for modern and legacy arXiv identifiers.
    class Arxiv
      API_URL = "https://export.arxiv.org/api/query"
      PDF_URL = "https://arxiv.org/pdf"
      ABSTRACT_URL = "https://arxiv.org/abs"
      MAX_METADATA_BYTES = 2 * 1024 * 1024

      MODERN_ID = /\A\d{2}(?:0[1-9]|1[0-2])\.\d{4,5}(?:v[1-9]\d*)?\z/i
      LEGACY_ID = /\A[a-z][a-z0-9.\-]*\/\d{2}(?:0[1-9]|1[0-2])\d{3}(?:v[1-9]\d*)?\z/i
      VERSION = /v([1-9]\d*)\z/i
      LOOPBACK_HOSTS = ["localhost", "127.0.0.1", "::1"].freeze

      XML_NAMESPACES = {
        "atom" => "http://www.w3.org/2005/Atom",
        "arxiv" => "http://arxiv.org/schemas/atom"
      }.freeze

      class Error < StandardError; end
      class InvalidIdentifier < Error; end
      class NotFound < Error; end
      class InvalidResponse < Error; end

      attr_reader :api_url, :pdf_url

      def initialize(http_client: nil, throttle: nil, api_url: nil, pdf_url: nil)
        @api_overridden = !api_url.nil? || env_endpoint_set?("WRQ_ARXIV_API_URL")
        @pdf_overridden = !pdf_url.nil? || env_endpoint_set?("WRQ_ARXIV_PDF_URL")
        @api_url = (api_url || ENV["WRQ_ARXIV_API_URL"] || API_URL).to_s.sub(%r{/+\z}, "")
        @pdf_url = (pdf_url || ENV["WRQ_ARXIV_PDF_URL"] || PDF_URL).to_s.sub(%r{/+\z}, "")
        @http = http_client || build_http_client
        @throttle = throttle || Throttle.new(path: default_throttle_path)
      end

      # Return normalized arXiv metadata as a symbol-keyed Hash.
      def fetch(reference)
        identifier = self.class.normalize_identifier(reference)
        @throttle.wait
        response = @http.get(
          query_url(identifier[:requested_id]),
          headers: { "Accept" => "application/atom+xml" },
          max_bytes: MAX_METADATA_BYTES
        )
        parse_atom(response[:body], requested_id: identifier[:requested_id])
      rescue REXML::ParseException => error
        raise InvalidResponse, "invalid arXiv Atom response: #{error.message}"
      end

      # Download a fetched record (or an identifier that can be fetched) and
      # return path/hash/size details from HTTPClient.
      def download(reference_or_metadata, destination:, max_bytes: nil)
        metadata = if reference_or_metadata.is_a?(Hash)
          reference_or_metadata
        else
          fetch(reference_or_metadata)
        end
        url = metadata[:pdf_url] || metadata["pdf_url"]
        raise InvalidResponse, "arXiv metadata has no PDF URL" if url.nil? || url.empty?

        @http.download_pdf(
          url,
          destination: destination,
          headers: { "Accept" => "application/pdf" },
          max_bytes: max_bytes
        )
      end

      # Public for fixture consumers and import tooling that already has an
      # Atom response cached locally.
      def parse_atom(xml, requested_id:)
        requested = self.class.normalize_identifier(requested_id)
        document = REXML::Document.new(xml.to_s)
        entry = REXML::XPath.first(document, "/atom:feed/atom:entry", XML_NAMESPACES)
        raise NotFound, "arXiv paper not found: #{requested[:requested_id]}" unless entry

        atom_id = element_text(entry, "atom:id")
        resolved = self.class.normalize_identifier(atom_id)
        if requested[:base_id].downcase != resolved[:base_id].downcase
          raise InvalidResponse,
            "arXiv returned #{resolved[:base_id]} for #{requested[:base_id]}"
        end
        title = compact_text(element_text(entry, "atom:title"))
        abstract = compact_text(element_text(entry, "atom:summary"))
        authors = REXML::XPath.match(entry, "atom:author/atom:name", XML_NAMESPACES).map do |node|
          compact_text(node.text)
        end.reject(&:empty?)
        categories = REXML::XPath.match(entry, "atom:category", XML_NAMESPACES).map do |node|
          node.attributes["term"].to_s.strip
        end.reject(&:empty?).uniq
        primary_node = REXML::XPath.first(entry, "arxiv:primary_category", XML_NAMESPACES)
        primary_category = primary_node && primary_node.attributes["term"].to_s.strip
        primary_category = nil if primary_category && primary_category.empty?

        abstract_url = normalized_abstract_url(atom_id, resolved[:resolved_id])
        pdf_link = pdf_link_from(entry)
        resolved_pdf_url = normalized_pdf_url(pdf_link, resolved[:resolved_id])
        publication_doi = optional_text(entry, "arxiv:doi")
        aliases = build_aliases(requested, resolved, abstract_url, resolved_pdf_url)

        {
          provider: "arxiv",
          canonical_key: "arxiv:#{resolved[:base_id]}",
          base_id: resolved[:base_id],
          requested_id: requested[:requested_id],
          requested_version: requested[:requested_version],
          resolved_id: resolved[:resolved_id],
          resolved_version: resolved[:resolved_version],
          title: title,
          authors: authors,
          abstract: abstract,
          categories: categories,
          primary_category: primary_category,
          published_at: optional_text(entry, "atom:published"),
          updated_at: optional_text(entry, "atom:updated"),
          comment: optional_text(entry, "arxiv:comment"),
          journal_ref: optional_text(entry, "arxiv:journal_ref"),
          publication_doi: publication_doi,
          abstract_url: abstract_url,
          pdf_url: resolved_pdf_url,
          aliases: aliases,
          provider_data: {
            arxiv: {
              atom_id: atom_id,
              requested_id: requested[:requested_id],
              resolved_id: resolved[:resolved_id]
            }
          }
        }
      rescue InvalidIdentifier
        raise
      rescue REXML::ParseException => error
        raise InvalidResponse, "invalid arXiv Atom response: #{error.message}"
      end

      class << self
        # Accept IDs as well as canonical arXiv/Hugging Face paper URLs. The
        # returned version fields are integers so records can compare versions.
        def normalize_identifier(reference)
          value = extract_identifier(reference)
          unless value.match?(MODERN_ID) || value.match?(LEGACY_ID)
            raise InvalidIdentifier, "invalid arXiv identifier: #{reference}"
          end

          version_match = VERSION.match(value)
          version = version_match ? version_match[1].to_i : nil
          base_id = version_match ? value[0...version_match.begin(0)] : value
          base_id = base_id.downcase if base_id.include?("/")
          requested_id = version ? "#{base_id}v#{version}" : base_id
          {
            requested_id: requested_id,
            requested_version: version,
            base_id: base_id,
            resolved_id: requested_id,
            resolved_version: version
          }
        end

        private

        def extract_identifier(reference)
          value = reference.to_s.strip
          value = value.sub(/\Aarxiv:\s*/i, "")

          if value.match?(%r{\Ahttps?://}i)
            uri = URI.parse(value)
            host = uri.host.to_s.downcase
            path = URI.decode_www_form_component(uri.path.to_s)
            case host
            when "arxiv.org", "www.arxiv.org", "export.arxiv.org"
              match = %r{\A/(?:abs|pdf)/(.+?)(?:\.pdf)?/?\z}i.match(path)
              raise InvalidIdentifier, "invalid arXiv URL: #{reference}" unless match

              value = match[1]
            when "huggingface.co", "www.huggingface.co", "hf.co", "www.hf.co"
              match = %r{\A/papers/(.+?)(?:\.md)?/?\z}i.match(path)
              raise InvalidIdentifier, "invalid Hugging Face paper URL: #{reference}" unless match

              value = match[1]
            else
              raise InvalidIdentifier, "unsupported paper URL: #{reference}"
            end
          end

          value.sub(/\.pdf\z/i, "")
        rescue URI::InvalidURIError
          raise InvalidIdentifier, "invalid paper reference: #{reference}"
        end
      end

      private

      def build_http_client
        uris = [@api_url, @pdf_url].map { |value| URI.parse(value) }
        hosts = uris.map(&:host).compact
        http_hosts = uris.select { |uri| uri.scheme == "http" && LOOPBACK_HOSTS.include?(uri.host) }.map(&:host)
        HTTPClient.new(allowed_hosts: hosts, allow_http_hosts: http_hosts)
      rescue URI::InvalidURIError => error
        raise ArgumentError, "invalid arXiv endpoint: #{error.message}"
      end

      def default_throttle_path
        return ENV["WRQ_ARXIV_THROTTLE_PATH"] if ENV["WRQ_ARXIV_THROTTLE_PATH"]

        root = ENV["WRQ_PATH"] || File.expand_path("~/papers")
        File.join(root, ".wrq", "arxiv-api.throttle")
      end

      def query_url(identifier)
        separator = @api_url.include?("?") ? "&" : "?"
        "#{@api_url}#{separator}#{URI.encode_www_form(id_list: identifier)}"
      end

      def element_text(node, path)
        element = REXML::XPath.first(node, path, XML_NAMESPACES)
        value = element && element.text
        raise InvalidResponse, "arXiv response is missing #{path}" if value.nil? || value.strip.empty?

        value
      end

      def optional_text(node, path)
        element = REXML::XPath.first(node, path, XML_NAMESPACES)
        value = element && element.text
        return nil if value.nil?

        value = compact_text(value)
        value.empty? ? nil : value
      end

      def compact_text(value)
        value.to_s.gsub(/\s+/, " ").strip
      end

      def pdf_link_from(entry)
        links = REXML::XPath.match(entry, "atom:link", XML_NAMESPACES)
        link = links.find do |node|
          node.attributes["title"].to_s.downcase == "pdf" ||
            node.attributes["type"].to_s.downcase == "application/pdf"
        end
        link && link.attributes["href"].to_s
      end

      def normalized_abstract_url(atom_id, resolved_id)
        if @api_overridden
          "#{ABSTRACT_URL}/#{resolved_id}"
        else
          value = atom_id.to_s.sub(%r{\Ahttp://}i, "https://")
          value.empty? ? "#{ABSTRACT_URL}/#{resolved_id}" : value
        end
      end

      def normalized_pdf_url(link, resolved_id)
        return build_pdf_url(resolved_id) if @pdf_overridden

        value = link.to_s.strip
        value = value.sub(%r{\Ahttp://}i, "https://")
        value.empty? ? build_pdf_url(resolved_id) : value
      end

      def build_pdf_url(identifier)
        if @pdf_url.include?("%{id}")
          format(@pdf_url, id: identifier)
        else
          "#{@pdf_url}/#{identifier}.pdf"
        end
      end

      def env_endpoint_set?(name)
        value = ENV[name]
        value && !value.empty?
      end

      def build_aliases(requested, resolved, abstract_url, resolved_pdf_url)
        values = [
          requested[:requested_id],
          requested[:base_id],
          resolved[:resolved_id],
          resolved[:base_id],
          "arXiv:#{requested[:requested_id]}",
          abstract_url,
          resolved_pdf_url,
          "https://huggingface.co/papers/#{resolved[:base_id]}"
        ]
        values.compact.reject(&:empty?).uniq
      end
    end
  end
end
