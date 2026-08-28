# frozen_string_literal: true

require "net/http"
require "uri"
require_relative "sha256"

module Wrq
  # A deliberately small HTTP client for wrq's metadata providers.
  #
  # Every request is checked against an exact hostname allowlist, including
  # redirect targets. Plain HTTP is disabled unless a hostname is explicitly
  # included in +allow_http_hosts+ (intended for loopback fixture servers).
  class HTTPClient
    DEFAULT_USER_AGENT = "wrq/0.1 (+https://github.com/mohamedsobhi777/wrq)"
    DEFAULT_MAX_REDIRECTS = 3
    DEFAULT_OPEN_TIMEOUT = 10
    DEFAULT_READ_TIMEOUT = 60
    DEFAULT_BODY_LIMIT = 4 * 1024 * 1024

    SENSITIVE_HEADERS = [
      "authorization",
      "cookie",
      "proxy-authorization",
      "x-api-key"
    ].freeze

    class Error < StandardError; end
    class InvalidURL < Error; end
    class RedirectError < Error; end
    class ResponseTooLarge < Error; end
    class InvalidPDF < Error; end

    class HTTPError < Error
      attr_reader :status, :url, :body

      def initialize(status:, url:, body: nil)
        @status = status.to_i
        @url = url.to_s
        @body = body
        super("HTTP #{@status} for #{@url}")
      end
    end

    def initialize(
      allowed_hosts:,
      allow_http_hosts: [],
      user_agent: DEFAULT_USER_AGENT,
      max_redirects: DEFAULT_MAX_REDIRECTS,
      open_timeout: DEFAULT_OPEN_TIMEOUT,
      read_timeout: DEFAULT_READ_TIMEOUT
    )
      @allowed_hosts = normalize_hosts(allowed_hosts)
      @allow_http_hosts = normalize_hosts(allow_http_hosts)
      @user_agent = user_agent.to_s
      @max_redirects = Integer(max_redirects)
      @open_timeout = Float(open_timeout)
      @read_timeout = Float(read_timeout)

      raise ArgumentError, "allowed_hosts cannot be empty" if @allowed_hosts.empty?
      raise ArgumentError, "max_redirects must be non-negative" if @max_redirects.negative?
      raise ArgumentError, "timeouts must be positive" unless @open_timeout.positive? && @read_timeout.positive?
    end

    # Fetch a bounded response body. Returns a symbol-keyed Hash so callers do
    # not need to depend on Net::HTTP response classes.
    def get(url, headers: {}, max_bytes: DEFAULT_BODY_LIMIT)
      limit = normalize_limit(max_bytes)
      return get_buffered(url, headers, limit) unless defined?(RubyVM)

      perform(url, headers, 0) do |response, final_url|
        body, bytes = read_bounded_body(response, limit)
        {
          status: response.code.to_i,
          headers: response_headers(response),
          body: body,
          bytes: bytes,
          url: final_url
        }
      end
    end

    # Stream a PDF to +destination+ while hashing it. Partial files are removed
    # on every error. A successful response must begin with the PDF signature.
    def download_pdf(url, destination:, headers: {}, max_bytes: nil)
      limit = normalize_limit(max_bytes)
      path = File.expand_path(destination.to_s)
      staged_path = reserve_staging_path(path)

      unless defined?(RubyVM)
        return download_pdf_buffered(
          url,
          headers,
          limit,
          path,
          staged_path
        )
      end

      result = perform(url, headers, 0) do |response, final_url|
        declared_length = content_length(response)
        if limit && declared_length && declared_length > limit
          raise ResponseTooLarge, "response exceeds #{limit} bytes"
        end

        digest = SHA256.new
        byte_count = 0
        prefix = String.new

        begin
          File.open(staged_path, "wb") do |file|
            response.read_body do |chunk|
              byte_count += chunk.bytesize
              if limit && byte_count > limit
                raise ResponseTooLarge, "response exceeds #{limit} bytes"
              end

              prefix << chunk if prefix.bytesize < 5
              prefix = prefix.byteslice(0, 5) if prefix.bytesize > 5
              if prefix.bytesize >= 5 && !prefix.start_with?("%PDF-")
                raise InvalidPDF, "downloaded response is not a PDF"
              end
              digest.update(chunk)
              file.write(chunk)
            end
            file.flush
          end

          unless prefix.start_with?("%PDF-")
            raise InvalidPDF, "downloaded response is not a PDF"
          end
          File.rename(staged_path, path)
        rescue StandardError, Interrupt
          begin
            File.delete(staged_path) if File.exist?(staged_path)
          rescue SystemCallError
          end
          raise
        end

        {
          status: response.code.to_i,
          headers: response_headers(response),
          path: path,
          bytes: byte_count,
          sha256: digest.hexdigest,
          content_type: response["content-type"],
          url: final_url
        }
      end

      result
    rescue StandardError, Interrupt
      begin
        File.delete(staged_path) if staged_path && File.exist?(staged_path)
      rescue SystemCallError
      end
      raise
    end

    private

    # Spinel's bundled Net::HTTP intentionally buffers response bodies and
    # does not implement Response#read_body. Keep MRI on the bounded streaming
    # path above, while the native binary consumes that runtime's body String.
    def get_buffered(url, headers, limit)
      response, final_url = perform_buffered(url, headers)
      body = response.body.to_s
      enforce_buffered_limit!(response, body, limit)
      {
        status: response.code.to_i,
        headers: response_headers(response),
        body: body,
        bytes: body.bytesize,
        url: final_url
      }
    end

    def download_pdf_buffered(url, headers, limit, path, staged_path)
      response, final_url = perform_buffered(url, headers)
      body = response.body.to_s
      enforce_buffered_limit!(response, body, limit)
      unless body.start_with?("%PDF-")
        raise InvalidPDF, "downloaded response is not a PDF"
      end

      digest = SHA256.new
      digest.update(body)
      File.open(staged_path, "wb") do |file|
        file.write(body)
        file.flush
      end
      File.rename(staged_path, path)
      {
        status: response.code.to_i,
        headers: response_headers(response),
        path: path,
        bytes: body.bytesize,
        sha256: digest.hexdigest,
        content_type: response["content-type"],
        url: final_url
      }
    rescue StandardError, Interrupt
      begin
        File.delete(staged_path) if File.exist?(staged_path)
      rescue SystemCallError
      end
      raise
    end

    def enforce_buffered_limit!(response, body, limit)
      declared_length = content_length(response)
      if limit && declared_length && declared_length > limit
        raise ResponseTooLarge, "response exceeds #{limit} bytes"
      end
      if limit && body.bytesize > limit
        raise ResponseTooLarge, "response exceeds #{limit} bytes"
      end
      nil
    end

    def normalize_hosts(hosts)
      Array(hosts).map { |host| host.to_s.downcase.strip }.reject(&:empty?).uniq.freeze
    end

    def normalize_limit(value)
      return nil if value.nil?

      limit = Integer(value)
      raise ArgumentError, "max_bytes must be positive" unless limit.positive?

      limit
    end

    def parse_and_validate_url(value)
      uri = URI.parse(value.to_s)
      host = uri.host.to_s.downcase

      unless uri.is_a?(URI::HTTP) && !host.empty?
        raise InvalidURL, "URL must be HTTP or HTTPS"
      end
      userinfo = uri.userinfo.to_s
      raise InvalidURL, "URL credentials are not allowed" unless userinfo.empty?
      raise InvalidURL, "host is not allowed: #{host}" unless @allowed_hosts.include?(host)

      scheme = uri.scheme.to_s.downcase
      if scheme != "https" && !(scheme == "http" && @allow_http_hosts.include?(host))
        raise InvalidURL, "HTTPS is required for #{host}"
      end

      uri
    rescue URI::InvalidURIError => error
      raise InvalidURL, "invalid URL: #{error.message}"
    end

    def perform(url, headers, redirect_count, &reader)
      uri = parse_and_validate_url(url)
      request_headers = normalized_headers(headers)
      request_headers["User-Agent"] ||= @user_agent
      request = Net::HTTP::Get.new(uri.request_uri, request_headers)
      result = nil
      redirect = nil

      begin
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout

        http.start do |connection|
          connection.request(request) do |response|
            status = response.code.to_i
            if status >= 300 && status < 400
              location = response["location"]
              raise RedirectError, "redirect without Location from #{uri}" if location.nil? || location.empty?
              raise RedirectError, "too many redirects from #{uri}" if redirect_count >= @max_redirects

              redirect = URI.join(uri.to_s, location).to_s
            elsif status >= 200 && status < 300
              result = reader.call(response, uri.to_s)
            else
              body, = read_bounded_body(response, 8192)
              raise HTTPError.new(status: status, url: uri.to_s, body: body)
            end
          end
        end
      rescue Error
        raise
      rescue StandardError => error
        raise Error, "request failed for #{uri}: #{error.message}"
      end

      if redirect
        return perform(redirect, strip_sensitive_headers(request_headers), redirect_count + 1, &reader)
      end

      result
    end

    def perform_buffered(url, headers)
      current_url = url.to_s
      request_headers = normalized_headers(headers)
      request_headers["User-Agent"] ||= @user_agent
      redirect_count = 0

      while true
        uri = parse_and_validate_url(current_url)
        request = Net::HTTP::Get.new(uri.request_uri, request_headers)
        response = nil
        http = nil
        begin
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = @open_timeout
          http.read_timeout = @read_timeout
          http.start
          response = http.request(request)
        rescue Error
          raise
        rescue StandardError => error
          raise Error, "request failed for #{uri}: #{error.message}"
        ensure
          if http
            begin
              http.finish if http.started?
            rescue StandardError
            end
          end
        end

        status = response.code.to_i
        if status >= 300 && status < 400
          location = response["location"]
          if location.nil? || location.empty?
            raise RedirectError, "redirect without Location from #{uri}"
          end
          if redirect_count >= @max_redirects
            raise RedirectError, "too many redirects from #{uri}"
          end

          current_url = URI.join(uri.to_s, location).to_s
          request_headers = strip_sensitive_headers(request_headers)
          redirect_count += 1
          next
        end

        if status >= 200 && status < 300
          return [response, uri.to_s]
        end

        error_body = response.body.to_s
        error_body = error_body.byteslice(0, 8192) if error_body.bytesize > 8192
        raise HTTPError.new(status: status, url: uri.to_s, body: error_body)
      end
    end

    def normalized_headers(headers)
      result = {}
      headers.each do |name, value|
        next if value.nil?

        result[name.to_s] = value.to_s
      end
      result
    end

    def strip_sensitive_headers(headers)
      clean = {}
      headers.each do |name, value|
        next if SENSITIVE_HEADERS.include?(name.to_s.downcase)

        clean[name] = value
      end
      clean
    end

    def read_bounded_body(response, limit)
      declared_length = content_length(response)
      if limit && declared_length && declared_length > limit
        raise ResponseTooLarge, "response exceeds #{limit} bytes"
      end

      body = String.new
      byte_count = 0
      response.read_body do |chunk|
        byte_count += chunk.bytesize
        raise ResponseTooLarge, "response exceeds #{limit} bytes" if limit && byte_count > limit

        body << chunk
      end
      [body, byte_count]
    end

    def content_length(response)
      value = response["content-length"]
      return nil unless value && value.match?(/\A\d+\z/)

      value.to_i
    end

    def response_headers(response)
      headers = {}
      response.each_header { |name, value| headers[name.downcase] = value }
      headers
    end

    def reserve_staging_path(destination)
      index = 0
      loop do
        candidate = "#{destination}.part-#{Process.pid}-#{index}"
        begin
          File.open(candidate, File::WRONLY | File::CREAT | File::EXCL, 0o600) {}
          return candidate
        rescue Errno::EEXIST
          index += 1
        end
      end
    end
  end
end
