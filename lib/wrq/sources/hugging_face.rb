# frozen_string_literal: true

require "json"
require "uri"
require_relative "../http_client"
require_relative "arxiv"

module Wrq
  module Sources
    # Optional enrichment from Hugging Face Paper Pages. arXiv remains the
    # source of identity and PDFs; this provider only contributes Hub metadata.
    class HuggingFace
      API_URL = "https://huggingface.co/api/papers"
      MAX_METADATA_BYTES = 4 * 1024 * 1024
      LOOPBACK_HOSTS = Arxiv::LOOPBACK_HOSTS

      class Error < StandardError; end
      class InvalidResponse < Error; end

      attr_reader :api_url

      def initialize(http_client: nil, api_url: nil, token: nil)
        @api_url = (api_url || ENV["WRQ_HF_API_URL"] || API_URL).to_s.sub(%r{/+\z}, "")
        @token = token.nil? ? ENV["HF_TOKEN"] : token
        @token_allowed = token_allowed_for_endpoint?
        @http = http_client || build_http_client
      end

      # Return enrichment metadata, or nil when the paper has not been indexed
      # by Hugging Face. The Authorization header is marked sensitive by the
      # HTTP client and is unconditionally removed before any redirect.
      def fetch(reference)
        identifier = Arxiv.normalize_identifier(reference)
        response = @http.get(
          paper_url(identifier[:base_id]),
          headers: request_headers,
          max_bytes: MAX_METADATA_BYTES
        )
        parse_json(response[:body], requested: identifier)
      rescue HTTPClient::HTTPError => error
        return nil if error.status == 404

        raise
      end

      # Public for cached response and fixture parsing.
      def parse_json(json, requested_id: nil, requested: nil)
        requested ||= Arxiv.normalize_identifier(requested_id)
        raw = JSON.parse(json.to_s)
        raise InvalidResponse, "Hugging Face paper response must be an object" unless raw.is_a?(Hash)

        paper = raw["paper"].is_a?(Hash) ? raw["paper"] : raw
        resolved = resolved_identifier(paper, raw, requested)
        if resolved[:base_id].downcase != requested[:base_id].downcase
          raise InvalidResponse,
            "Hugging Face returned #{resolved[:base_id]} for #{requested[:base_id]}"
        end
        hf_authors = normalize_authors(value_from(paper, raw, "authors"))
        authors = hf_authors.map { |author| author[:name] }
        summary = value_from(paper, raw, "summary", "abstract")
        ai_summary = value_from(paper, raw, "ai_summary", "aiSummary", "aiGeneratedSummary")
        ai_keywords = array_from(paper, raw, "ai_keywords", "aiKeywords", "keywords")
        project_page = value_from(paper, raw, "project_page", "projectPage")
        github_repo = value_from(paper, raw, "github_repo", "githubRepo", "github")
        organization = paper["organization"] || raw["organization"]
        media_urls = array_from(paper, raw, "mediaUrls", "media_urls", "media")
        models = array_from(paper, raw, "linkedModels", "models")
        datasets = array_from(paper, raw, "linkedDatasets", "datasets")
        spaces = array_from(paper, raw, "linkedSpaces", "spaces")
        hf_url = "https://huggingface.co/papers/#{resolved[:base_id]}"
        title = value_from(paper, raw, "title")
        upvotes = integer_or_nil(value_from(paper, raw, "upvotes", "likes"))
        enrichment = {
          title: title,
          authors: hf_authors,
          summary: summary,
          ai_summary: ai_summary,
          ai_keywords: ai_keywords,
          upvotes: upvotes,
          project_page: project_page,
          github_repo: github_repo,
          organization: organization,
          media_urls: media_urls,
          models: models,
          datasets: datasets,
          spaces: spaces,
          url: hf_url,
          raw: raw
        }

        metadata = {
          provider: "hugging_face",
          canonical_key: "arxiv:#{resolved[:base_id]}",
          base_id: resolved[:base_id],
          requested_id: requested[:requested_id],
          resolved_id: resolved[:resolved_id],
          resolved_version: resolved[:resolved_version],
          title: title,
          authors: authors,
          hf_authors: hf_authors,
          abstract: summary,
          summary: summary,
          ai_summary: ai_summary,
          ai_keywords: ai_keywords,
          upvotes: upvotes,
          project_page: project_page,
          github_repo: github_repo,
          organization: organization,
          media_urls: media_urls,
          models: models,
          datasets: datasets,
          spaces: spaces,
          hf_url: hf_url,
          aliases: [requested[:requested_id], resolved[:base_id], hf_url].compact.uniq,
          provider_data: { hugging_face: enrichment }
        }
        if requested[:has_requested_version]
          metadata[:requested_version] = requested[:requested_version]
        end
        metadata
      rescue JSON::ParserError => error
        raise InvalidResponse, "invalid Hugging Face JSON response: #{error.message}"
      rescue Arxiv::InvalidIdentifier => error
        raise InvalidResponse, "invalid paper ID in Hugging Face response: #{error.message}"
      end

      private

      def build_http_client
        uri = URI.parse(@api_url)
        http_hosts = if uri.scheme == "http" && LOOPBACK_HOSTS.include?(uri.host)
          [uri.host]
        else
          []
        end
        HTTPClient.new(allowed_hosts: [uri.host], allow_http_hosts: http_hosts)
      rescue URI::InvalidURIError => error
        raise ArgumentError, "invalid Hugging Face endpoint: #{error.message}"
      end

      def paper_url(identifier)
        "#{@api_url}/#{URI.encode_www_form_component(identifier)}"
      end

      def request_headers
        headers = { "Accept" => "application/json" }
        token = @token.to_s.strip
        if @token_allowed && !token.empty?
          headers["Authorization"] = "Bearer #{token}"
        end
        headers
      end

      def token_allowed_for_endpoint?
        uri = URI.parse(@api_url)
        host = uri.host.to_s.downcase
        uri.scheme.to_s.downcase == "https" &&
          ["huggingface.co", "www.huggingface.co"].include?(host)
      rescue URI::InvalidURIError
        false
      end

      def normalize_authors(value)
        return [] unless value.is_a?(Array)

        value.map do |author|
          if author.is_a?(Hash)
            name = first_value(author, "name", "fullname", "fullName")
            username = first_value(author, "user", "username", "hfUsername")
            next nil unless name || username

            { name: name || username, username: username }
          else
            text = author.to_s.strip
            text.empty? ? nil : { name: text, username: nil }
          end
        end.compact
      end

      def first_value(hash, *keys)
        keys.each do |key|
          value = hash[key]
          return value unless value.nil?
        end
        nil
      end

      def value_from(primary, fallback, *keys)
        first_value(primary, *keys) || first_value(fallback, *keys)
      end

      def array_from(primary, fallback, *keys)
        value = value_from(primary, fallback, *keys)
        value.is_a?(Array) ? value : []
      end

      def resolved_identifier(paper, raw, requested)
        candidates = [
          first_value(paper, "arxivId", "arxiv_id"),
          first_value(raw, "arxivId", "arxiv_id"),
          first_value(paper, "id"),
          first_value(raw, "id")
        ].compact
        candidates.each do |candidate|
          begin
            return Arxiv.normalize_identifier(candidate)
          rescue Arxiv::InvalidIdentifier
          end
        end
        Arxiv.normalize_identifier(requested[:base_id])
      end

      def integer_or_nil(value)
        return nil if value.nil?

        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
