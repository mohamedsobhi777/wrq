# frozen_string_literal: true

require "uri"
require_relative "../http_client"
require_relative "../identity"
require_relative "../throttle"
require_relative "arxiv_atom_cache"

module Wrq
  module Sources
    # Metadata and PDF access for modern and legacy arXiv identifiers.
    class Arxiv
      API_URL = "https://export.arxiv.org/api/query"
      PDF_URL = "https://arxiv.org/pdf"
      ABSTRACT_URL = "https://arxiv.org/abs"
      MAX_METADATA_BYTES = 2 * 1024 * 1024
      MAX_XML_DEPTH = 128
      MAX_XML_NODES = 100_000
      CACHE_DIRECTORY = "arxiv-atom"
      DEFAULT_CACHE_TTL = ArxivAtomCache::DEFAULT_TTL
      DEFAULT_CACHE_ENTRIES = ArxivAtomCache::DEFAULT_MAX_ENTRIES

      ATOM_NAMESPACE = "http://www.w3.org/2005/Atom"
      ARXIV_NAMESPACE = "http://arxiv.org/schemas/atom"
      XML_NAMESPACE = "http://www.w3.org/XML/1998/namespace"
      ARXIV_ELEMENTS = ["comment", "doi", "journal_ref", "primary_category"].freeze

      LOOPBACK_HOSTS = ["localhost", "127.0.0.1", "::1"].freeze

      class Error < StandardError; end
      class InvalidIdentifier < Error; end
      class NotFound < Error; end
      class InvalidResponse < Error; end

      # Minimal immutable-name XML node used by the bounded Atom parser. Text
      # and child nodes remain in document order so mixed content, CDATA, and
      # comments have predictable text semantics without a runtime XML gem.
      class AtomNode
        attr_reader :qualified_name, :local_name, :namespace_uri, :attributes,
          :children, :content, :namespaces

        def initialize(qualified_name:, local_name:, namespace_uri:, attributes:, namespaces:)
          @qualified_name = qualified_name
          @local_name = local_name
          @namespace_uri = namespace_uri
          @attributes = attributes
          @namespaces = namespaces
          @children = []
          @content = []
        end

        def append_text(value)
          @content << value unless value.empty?
        end

        def append_child(node)
          @children << node
          @content << node
        end
      end

      attr_reader :api_url, :pdf_url

      def initialize(http_client: nil, throttle: nil, api_url: nil, pdf_url: nil,
                     cache_path: nil, cache_ttl: DEFAULT_CACHE_TTL,
                     cache_max_entries: DEFAULT_CACHE_ENTRIES, clock: nil)
        @api_overridden = !api_url.nil? || env_endpoint_set?("WRQ_ARXIV_API_URL")
        @pdf_overridden = !pdf_url.nil? || env_endpoint_set?("WRQ_ARXIV_PDF_URL")
        @api_url = (api_url || ENV["WRQ_ARXIV_API_URL"] || API_URL).to_s.sub(%r{/+\z}, "")
        @pdf_url = (pdf_url || ENV["WRQ_ARXIV_PDF_URL"] || PDF_URL).to_s.sub(%r{/+\z}, "")
        # The concrete client remains in its own ivar so Spinel can resolve
        # get/download_pdf statically. MRI-only provider tests may still inject
        # a small fake transport through +http_client+.
        @http = build_http_client
        @http_override = http_client
        @throttle = throttle || Throttle.new(path: default_throttle_path)
        cache_root = cache_path || default_cache_path
        @cache = ArxivAtomCache.new(
          path: File.join(cache_root, CACHE_DIRECTORY),
          scope: @api_url,
          max_bytes: MAX_METADATA_BYTES,
          ttl: cache_ttl,
          max_entries: cache_max_entries,
          clock: clock
        )
      end

      # Return normalized arXiv metadata as a symbol-keyed Hash.
      def fetch(reference, refresh: false)
        identifier = self.class.normalize_identifier(reference)
        requested_id = identifier[:requested_id]
        cached = @cache.read(requested_id)
        if cached && cached.fresh? && !refresh
          metadata = parse_cached(cached, requested_id)
          return metadata if metadata
        end

        request_url = query_url(requested_id)
        begin
          if defined?(RubyVM) && @http_override
            response = @throttle.synchronize do
              @http_override.get(
                request_url,
                headers: { "Accept" => "application/atom+xml" },
                max_bytes: MAX_METADATA_BYTES
              )
            end
          else
            http = @http
            response = @throttle.synchronize do
              http.get(
                request_url,
                headers: { "Accept" => "application/atom+xml" },
                max_bytes: MAX_METADATA_BYTES
              )
            end
          end
          validate_http_response!(response)
        rescue HTTPClient::Error => network_error
          metadata = parse_cached(cached, requested_id) if cached && !refresh
          return metadata if metadata

          raise network_error
        end

        metadata = parse_atom(response[:body], requested_id: requested_id)
        @cache.write(requested_id, response[:body])
        metadata
      end

      # Explicit refresh entrypoint keeps dynamic provider doubles simple and
      # avoids dispatching a keyword argument through Spinel's polymorphic
      # command layer.
      def refresh(reference)
        fetch(reference, refresh: true)
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

        if defined?(RubyVM) && @http_override
          @throttle.synchronize do
            @http_override.download_pdf(
              url,
              destination: destination,
              headers: { "Accept" => "application/pdf" },
              max_bytes: max_bytes
            )
          end
        else
          http = @http
          @throttle.synchronize do
            http.download_pdf(
              url,
              destination: destination,
              headers: { "Accept" => "application/pdf" },
              max_bytes: max_bytes
            )
          end
        end
      end

      # Public for fixture consumers and import tooling that already has an
      # Atom response cached locally.
      def parse_atom(xml, requested_id:)
        requested = self.class.normalize_identifier(requested_id)
        document = sanitize_atom(xml)
        entry = xml_element(document, "entry")
        raise NotFound, "arXiv paper not found: #{requested[:requested_id]}" unless entry

        atom_id = required_xml_text(entry, "id")
        resolved = self.class.normalize_identifier(atom_id)
        if requested[:base_id].downcase != resolved[:base_id].downcase
          raise InvalidResponse,
            "arXiv returned #{resolved[:base_id]} for #{requested[:base_id]}"
        end
        if requested[:has_requested_version] &&
           requested[:requested_version] != resolved[:resolved_version]
          raise InvalidResponse,
            "arXiv returned #{resolved[:resolved_id]} for exact request #{requested[:requested_id]}"
        end
        title = compact_text(required_xml_text(entry, "title"))
        abstract = compact_text(required_xml_text(entry, "summary"))
        authors = xml_elements(entry, "author").map do |author|
          compact_text(required_xml_text(author, "name"))
        end.reject(&:empty?)
        categories = xml_tags(entry, "category").map do |tag|
          xml_attributes(tag)["term"].to_s.strip
        end.reject(&:empty?).uniq
        primary_tag = xml_tags(entry, "primary_category").first
        primary_category = primary_tag && xml_attributes(primary_tag)["term"].to_s.strip
        primary_category = nil if primary_category && primary_category.empty?

        abstract_url = normalized_abstract_url(atom_id, resolved[:resolved_id])
        pdf_link = pdf_link_from(entry)
        resolved_pdf_url = normalized_pdf_url(pdf_link, resolved[:resolved_id])
        publication_doi = optional_xml_text(entry, "doi")
        aliases = build_aliases(requested, resolved, abstract_url, resolved_pdf_url)

        metadata = {
          provider: "arxiv",
          canonical_key: "arxiv:#{resolved[:base_id]}",
          base_id: resolved[:base_id],
          requested_id: requested[:requested_id],
          resolved_id: resolved[:resolved_id],
          resolved_version: resolved[:resolved_version],
          title: title,
          authors: authors,
          abstract: abstract,
          categories: categories,
          primary_category: primary_category,
          published_at: optional_xml_text(entry, "published"),
          updated_at: optional_xml_text(entry, "updated"),
          comment: optional_xml_text(entry, "comment"),
          journal_ref: optional_xml_text(entry, "journal_ref"),
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
        if requested[:has_requested_version]
          metadata[:requested_version] = requested[:requested_version]
        end
        metadata
      rescue InvalidIdentifier, NotFound, InvalidResponse
        raise
      rescue StandardError => error
        raise InvalidResponse, "invalid arXiv Atom response: #{error.message}"
      end

      class << self
        # Accept IDs as well as canonical arXiv/Hugging Face paper URLs. The
        # returned version fields are integers so records can compare versions.
        def normalize_identifier(reference)
          identity = Identity.parse(reference)
          unless identity.arxiv?
            raise InvalidIdentifier, "invalid arXiv identifier: #{reference}"
          end
          version = identity.version
          base_id = identity.base_id
          requested_id = identity.versioned_id
          result = {
            requested_id: requested_id,
            has_requested_version: !version.nil?,
            base_id: base_id,
            resolved_id: requested_id
          }
          if version
            result[:requested_version] = version
            result[:resolved_version] = version
          end
          result
        rescue Wrq::InvalidIdentity => error
          raise InvalidIdentifier, error.message
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
        Throttle.default_path
      end

      def default_cache_path
        configured = ENV["WRQ_PATH"].to_s.strip
        root = configured.empty? ? File.expand_path("~/papers") : File.expand_path(configured)
        File.join(root, ".wrq", "cache")
      end

      def parse_cached(entry, requested_id)
        parse_atom(entry.body, requested_id: requested_id)
      rescue Error
        @cache.delete(requested_id)
        nil
      end

      def validate_http_response!(response)
        status = response.is_a?(Hash) ? response[:status].to_i : 0
        return if status >= 200 && status < 300

        url = response.is_a?(Hash) ? response[:url] : nil
        raise HTTPClient::HTTPError.new(
          status: status,
          url: url || @api_url,
          body: response.is_a?(Hash) ? response[:body] : nil
        )
      end

      def query_url(identifier)
        separator = @api_url.include?("?") ? "&" : "?"
        "#{@api_url}#{separator}#{URI.encode_www_form(id_list: identifier, max_results: 1)}"
      end

      # arXiv's Atom surface is deliberately small. This bounded parser reads
      # only the handful of elements/attributes wrq stores, accepts default or
      # prefixed namespaces, decodes XML entities, and refuses DTD/entity
      # declarations. It avoids a runtime REXML dependency, which also keeps
      # the same implementation available to Spinel.
      def sanitize_atom(xml)
        value = xml.to_s
        if value.bytesize > MAX_METADATA_BYTES
          raise InvalidResponse, "arXiv Atom response exceeds #{MAX_METADATA_BYTES} bytes"
        end

        parse_xml_document(value)
      end

      def parse_xml_document(value)
        roots = []
        stack = []
        offset = 0
        node_count = 0

        while offset < value.length
          opening = value.index("<", offset)
          unless opening
            append_xml_text(stack, value[offset...value.length])
            offset = value.length
            next
          end

          append_xml_text(stack, value[offset...opening]) if opening > offset
          offset = opening

          if value[offset, 4] == "<!--"
            closing = value.index("-->", offset + 4)
            raise InvalidResponse, "unterminated XML comment" unless closing

            body = value[(offset + 4)...closing]
            raise InvalidResponse, "invalid XML comment" if body.include?("--")

            offset = closing + 3
          elsif value[offset, 9] == "<![CDATA["
            raise InvalidResponse, "CDATA is not inside an element" if stack.empty?

            closing = value.index("]]>", offset + 9)
            raise InvalidResponse, "unterminated CDATA section" unless closing

            stack.last.append_text(value[(offset + 9)...closing])
            offset = closing + 3
          elsif value[offset, 2] == "<?"
            closing = value.index("?>", offset + 2)
            raise InvalidResponse, "unterminated XML processing instruction" unless closing

            offset = closing + 2
          elsif value[offset, 2] == "<!"
            raise InvalidResponse, "arXiv Atom response contains a forbidden declaration"
          elsif value[offset, 2] == "</"
            closing = find_xml_tag_end(value, offset + 2)
            name = parse_xml_closing_name(value[(offset + 2)...closing])
            current = stack.last
            raise InvalidResponse, "unexpected closing XML tag #{name}" unless current
            unless current.qualified_name == name
              raise InvalidResponse,
                "mismatched XML tag: expected #{current.qualified_name}, got #{name}"
            end

            stack.pop
            offset = closing + 1
          else
            closing = find_xml_tag_end(value, offset + 1)
            parent_namespaces = if stack.empty?
              { "xml" => XML_NAMESPACE }
            else
              stack.last.namespaces
            end
            parsed = parse_xml_start_tag(value[(offset + 1)...closing], parent_namespaces)
            node_count += 1
            if node_count > MAX_XML_NODES
              raise InvalidResponse, "arXiv Atom response has too many XML elements"
            end
            if stack.length + 1 > MAX_XML_DEPTH
              raise InvalidResponse, "arXiv Atom response exceeds XML nesting limit"
            end

            node = AtomNode.new(
              qualified_name: parsed[:qualified_name],
              local_name: parsed[:local_name],
              namespace_uri: parsed[:namespace_uri],
              attributes: parsed[:attributes],
              namespaces: parsed[:namespaces]
            )
            if stack.empty?
              roots << node
            else
              stack.last.append_child(node)
            end
            stack << node unless parsed[:self_closing]
            offset = closing + 1
          end
        end

        unless stack.empty?
          raise InvalidResponse, "unterminated XML tag #{stack.last.qualified_name}"
        end
        unless roots.length == 1 && xml_name_matches?(roots.first, "feed")
          raise InvalidResponse, "arXiv Atom response is not a complete Atom feed"
        end

        roots.first
      end

      def append_xml_text(stack, raw)
        value = raw.to_s
        return if value.empty?
        raise InvalidResponse, "invalid ]]> outside CDATA" if value.include?("]]>")

        decoded = decode_xml_entities(value)
        if stack.empty?
          unless decoded.strip.empty?
            raise InvalidResponse, "text appears outside the XML document element"
          end
        else
          stack.last.append_text(decoded)
        end
      end

      def find_xml_tag_end(value, offset)
        quote = nil
        index = offset
        while index < value.length
          character = value[index, 1]
          if quote
            quote = nil if character == quote
          elsif character == '"' || character == "'"
            quote = character
          elsif character == ">"
            return index
          elsif character == "<"
            raise InvalidResponse, "invalid < inside XML tag"
          end
          index += 1
        end

        if quote
          raise InvalidResponse, "unterminated quoted XML attribute"
        end
        raise InvalidResponse, "unterminated XML tag"
      end

      def parse_xml_closing_name(raw)
        value = raw.to_s
        raise InvalidResponse, "invalid closing XML tag" if xml_whitespace?(value[0, 1])

        name, offset = read_xml_name(value, 0)
        raise InvalidResponse, "invalid closing XML tag" unless name

        offset = skip_xml_whitespace(value, offset)
        unless offset == value.length
          raise InvalidResponse, "invalid content in closing XML tag #{name}"
        end
        name
      end

      def parse_xml_start_tag(raw, inherited_namespaces)
        value = raw.to_s
        raise InvalidResponse, "invalid XML start tag" if value.empty? || xml_whitespace?(value[0, 1])

        qualified_name, offset = read_xml_name(value, 0)
        raise InvalidResponse, "invalid XML start tag" unless qualified_name

        attributes = {}
        self_closing = false
        loop do
          before_whitespace = offset
          offset = skip_xml_whitespace(value, offset)
          break if offset == value.length

          if value[offset, 1] == "/"
            offset = skip_xml_whitespace(value, offset + 1)
            unless offset == value.length
              raise InvalidResponse, "invalid self-closing XML tag #{qualified_name}"
            end
            self_closing = true
            break
          end
          if offset == before_whitespace
            raise InvalidResponse, "XML attributes must be separated by whitespace"
          end

          attribute_name, offset = read_xml_name(value, offset)
          unless attribute_name
            raise InvalidResponse, "invalid attribute in XML tag #{qualified_name}"
          end
          if attributes.key?(attribute_name)
            raise InvalidResponse, "duplicate XML attribute #{attribute_name}"
          end

          offset = skip_xml_whitespace(value, offset)
          unless value[offset, 1] == "="
            raise InvalidResponse, "XML attribute #{attribute_name} has no value"
          end
          offset = skip_xml_whitespace(value, offset + 1)
          quote = value[offset, 1]
          unless quote == '"' || quote == "'"
            raise InvalidResponse, "XML attribute #{attribute_name} is not quoted"
          end

          ending = value.index(quote, offset + 1)
          raise InvalidResponse, "unterminated XML attribute #{attribute_name}" unless ending

          raw_attribute = value[(offset + 1)...ending]
          if raw_attribute.include?("<")
            raise InvalidResponse, "XML attribute #{attribute_name} contains <"
          end
          attributes[attribute_name] = decode_xml_entities(raw_attribute)
          offset = ending + 1
        end

        namespaces = inherited_namespaces.dup
        attributes.each do |name, attribute_value|
          if name == "xmlns"
            namespaces[""] = attribute_value
          elsif name.start_with?("xmlns:")
            prefix = name[6...name.length]
            if prefix.empty? || prefix == "xmlns" || attribute_value.empty?
              raise InvalidResponse, "invalid XML namespace declaration #{name}"
            end
            if prefix == "xml" && attribute_value != XML_NAMESPACE
              raise InvalidResponse, "invalid declaration for reserved XML namespace"
            end
            namespaces[prefix] = attribute_value
          end
        end

        prefix, local_name = split_xml_name(qualified_name)
        namespace_uri = prefix ? namespaces[prefix] : namespaces[""]
        if prefix && (namespace_uri.nil? || namespace_uri.empty?)
          raise InvalidResponse, "undeclared XML namespace prefix #{prefix}"
        end

        attributes.each_key do |attribute_name|
          next if attribute_name == "xmlns" || attribute_name.start_with?("xmlns:")

          attribute_prefix, = split_xml_name(attribute_name)
          if attribute_prefix && !namespaces.key?(attribute_prefix)
            raise InvalidResponse, "undeclared XML namespace prefix #{attribute_prefix}"
          end
        end

        {
          qualified_name: qualified_name,
          local_name: local_name,
          namespace_uri: namespace_uri,
          attributes: attributes,
          namespaces: namespaces,
          self_closing: self_closing
        }
      end

      def read_xml_name(value, offset)
        fragment = value[offset...value.length]
        match = /\A[A-Za-z_][A-Za-z0-9_.-]*(?::[A-Za-z_][A-Za-z0-9_.-]*)?/.match(fragment)
        return [nil, offset] unless match

        name = match[0]
        [name, offset + name.length]
      end

      def split_xml_name(name)
        separator = name.index(":")
        if separator
          [name[0...separator], name[(separator + 1)...name.length]]
        else
          [nil, name]
        end
      end

      def skip_xml_whitespace(value, offset)
        index = offset
        index += 1 while index < value.length && xml_whitespace?(value[index, 1])
        index
      end

      def xml_whitespace?(character)
        character == " " || character == "\t" || character == "\r" || character == "\n"
      end

      def xml_name_matches?(node, name)
        return false unless node.local_name == name.to_s

        expected_namespace = if ARXIV_ELEMENTS.include?(name.to_s)
          ARXIV_NAMESPACE
        else
          ATOM_NAMESPACE
        end
        node.namespace_uri == expected_namespace
      end

      def xml_element(node, name)
        node.children.find { |child| xml_name_matches?(child, name) }
      end

      def xml_elements(node, name)
        node.children.select { |child| xml_name_matches?(child, name) }
      end

      def xml_tags(node, name)
        xml_elements(node, name)
      end

      def xml_attributes(node)
        node.attributes
      end

      def required_xml_text(node, name)
        element = xml_element(node, name)
        value = element && extract_xml_text(element)
        if value.nil? || value.strip.empty?
          raise InvalidResponse, "arXiv response is missing #{name}"
        end
        value
      end

      def optional_xml_text(node, name)
        element = xml_element(node, name)
        return nil if element.nil?

        value = compact_text(extract_xml_text(element))
        value.empty? ? nil : value
      end

      def extract_xml_text(node)
        output = String.new
        node.content.each do |item|
          if item.is_a?(AtomNode)
            output << " "
            output << extract_xml_text(item)
            output << " "
          else
            output << item.to_s
          end
        end
        output
      end

      def decode_xml_entities(value)
        source = value.to_s
        output = String.new
        offset = 0
        while (opening = source.index("&", offset))
          output << source[offset...opening]
          closing = source.index(";", opening + 1)
          raise InvalidResponse, "unterminated XML entity" unless closing

          token = source[(opening + 1)...closing]
          output << decode_xml_entity(token)
          offset = closing + 1
        end
        output << source[offset...source.length]
        output
      end

      def decode_xml_entity(token)
        case token
        when "amp" then "&"
        when "lt" then "<"
        when "gt" then ">"
        when "quot" then '"'
        when "apos" then "'"
        else
          number = if token.match?(/\A#x[0-9A-Fa-f]+\z/)
            token[2...token.length].to_i(16)
          elsif token.match?(/\A#[0-9]+\z/)
            token[1...token.length].to_i(10)
          end
          unless number && valid_xml_codepoint?(number)
            raise InvalidResponse, "unknown or invalid XML entity &#{token};"
          end
          [number].pack("U")
        end
      end

      def valid_xml_codepoint?(number)
        number == 9 || number == 10 || number == 13 ||
          (number >= 32 && number <= 0xD7FF) ||
          (number >= 0xE000 && number <= 0xFFFD) ||
          (number >= 0x10000 && number <= 0x10FFFF)
      end

      def compact_text(value)
        value.to_s.gsub(/\s+/, " ").strip
      end

      def pdf_link_from(entry)
        links = xml_tags(entry, "link")
        link = links.find do |tag|
          attributes = xml_attributes(tag)
          attributes["title"].to_s.downcase == "pdf" ||
            attributes["type"].to_s.downcase == "application/pdf"
        end
        link && xml_attributes(link)["href"].to_s
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
