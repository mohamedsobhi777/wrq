# frozen_string_literal: true

require_relative "compat"

module Wrq
  # Canonical identity for an arXiv work. Versions identify assets, while the
  # versionless base ID identifies the logical paper record.
  class Identity
    MODERN_ID_RE = /\A(\d{2})(0[1-9]|1[0-2])\.(\d{4,5})(?:v([1-9]\d*))?\z/i
    LEGACY_ID_RE = /\A([a-z][a-z0-9.-]*)\/(\d{2})(0[1-9]|1[0-2])(\d{3})(?:v([1-9]\d*))?\z/i
    ARXIV_URL_RE = %r{\Ahttps?://(?:(?:www|export)\.)?arxiv\.org/(?:abs|pdf|html)/([^?#]+)(?:[?#].*)?\z}i
    HF_URL_RE = %r{\Ahttps?://(?:www\.)?huggingface\.co/papers/([^/?#]+(?:/[^/?#]+)?)/?(?:[?#].*)?\z}i
    SHA256_RE = /\A(?:sha256:)?([0-9a-f]{64})\z/i

    attr_reader :base_id, :version, :original, :provider

    def self.recognize(reference)
      parse(reference)
    rescue InvalidIdentity
      nil
    end

    def self.parse(reference)
      original = reference.to_s.strip
      raise InvalidIdentity, "paper reference is empty" if original.empty?

      hash_match = SHA256_RE.match(original)
      return local(hash_match[1], original: original) if hash_match

      candidate = extract_candidate(original)
      candidate = candidate.sub(/\.pdf\z/i, "")
      candidate = candidate.sub(/\/$/, "")
      candidate = candidate.sub(/\Aarxiv:\s*/i, "")
      base_id, version = parse_id(candidate)
      new(base_id: base_id, version: version, original: original)
    end

    def self.local(sha256, original: nil)
      new(base_id: sha256, original: original, provider: "local")
    end

    def self.extract_candidate(reference)
      arxiv = ARXIV_URL_RE.match(reference)
      return arxiv[1] if arxiv

      hugging_face = HF_URL_RE.match(reference)
      return hugging_face[1] if hugging_face

      if reference =~ %r{\A[a-z][a-z0-9+.-]*://}i
        raise InvalidIdentity, "unsupported paper URL: #{reference}"
      end
      reference
    end

    def self.parse_id(candidate)
      modern = MODERN_ID_RE.match(candidate)
      if modern
        base = "#{modern[1]}#{modern[2]}.#{modern[3]}"
        return [base, modern[4] ? modern[4].to_i : nil]
      end

      legacy = LEGACY_ID_RE.match(candidate)
      if legacy
        base = "#{legacy[1].downcase}/#{legacy[2]}#{legacy[3]}#{legacy[4]}"
        return [base, legacy[5] ? legacy[5].to_i : nil]
      end

      raise InvalidIdentity, "invalid arXiv identifier: #{candidate}"
    end

    def initialize(base_id:, version: nil, original: nil, provider: "arxiv")
      if provider.to_s == "local"
        match = SHA256_RE.match(base_id.to_s)
        raise InvalidIdentity, "local identity requires a SHA-256 hash" unless match
        raise InvalidIdentity, "local identities cannot have versions" if version

        @provider = "local"
        @base_id = match[1].downcase
        @version = nil
        @original = original
        return
      end
      unless provider.to_s == "arxiv"
        raise InvalidIdentity, "unsupported identity provider: #{provider}"
      end

      parsed_base, embedded_version = self.class.parse_id(base_id.to_s)
      if embedded_version && version && embedded_version != version.to_i
        raise InvalidIdentity, "conflicting arXiv versions"
      end

      resolved_version = version || embedded_version
      if resolved_version &&
         (!resolved_version.is_a?(Integer) && resolved_version.to_s !~ /\A[1-9]\d*\z/)
        raise InvalidIdentity, "arXiv version must be a positive integer"
      end
      if resolved_version && resolved_version.to_i < 1
        raise InvalidIdentity, "arXiv version must be positive"
      end

      @provider = "arxiv"
      @base_id = parsed_base
      @version = resolved_version ? resolved_version.to_i : nil
      @original = original
    end

    alias source provider

    def canonical_key
      arxiv? ? "arxiv:#{@base_id}" : "sha256:#{@base_id}"
    end

    def versioned_id
      @version ? "#{@base_id}v#{@version}" : @base_id
    end

    alias canonical_id versioned_id

    def modern?
      arxiv? && @base_id.index("/").nil?
    end

    def legacy?
      arxiv? && !modern?
    end

    def arxiv?
      @provider == "arxiv"
    end

    def local?
      @provider == "local"
    end

    def arxiv_abs_url
      raise InvalidIdentity, "local papers do not have an arXiv URL" unless arxiv?
      "https://arxiv.org/abs/#{versioned_id}"
    end

    def arxiv_pdf_url
      raise InvalidIdentity, "local papers do not have an arXiv URL" unless arxiv?
      "https://arxiv.org/pdf/#{versioned_id}.pdf"
    end

    def hugging_face_url
      raise InvalidIdentity, "local papers do not have a Hugging Face URL" unless arxiv?
      "https://huggingface.co/papers/#{versioned_id}"
    end

    def aliases
      if local?
        values = [canonical_key, @base_id]
        values << @original if @original && !@original.empty?
        return values.uniq
      end

      values = [
        canonical_key,
        @base_id,
        versioned_id,
        "arXiv:#{versioned_id}",
        arxiv_abs_url,
        arxiv_pdf_url,
        hugging_face_url,
      ]
      values << @original if @original && !@original.empty?
      values.uniq
    end

    def without_version
      self.class.new(base_id: @base_id, provider: @provider)
    end

    def with_version(version)
      raise InvalidIdentity, "local identities cannot have versions" if local?
      self.class.new(base_id: @base_id, version: version, provider: @provider)
    end

    def to_h
      {
        "provider" => provider,
        "base_id" => @base_id,
        "version" => @version,
      }
    end

    def self.from_h(value)
      unless value.is_a?(Hash) && ["arxiv", "local"].include?(value["provider"])
        raise InvalidIdentity, "unsupported paper identity"
      end
      new(
        base_id: value["base_id"],
        version: value["version"],
        provider: value["provider"]
      )
    end

    def ==(other)
      other.is_a?(Identity) && other.provider == @provider &&
        other.base_id == @base_id && other.version == @version
    end

    alias eql? ==

    def hash
      [provider, @base_id, @version].hash
    end

    def to_s
      versioned_id
    end
  end
end
