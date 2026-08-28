# frozen_string_literal: true

require "time"
require_relative "identity"

module Wrq
  class Asset
    SHA256_RE = /\A[0-9a-f]{64}\z/

    attr_reader :version, :path, :sha256, :size, :source_url, :added_at

    def initialize(version:, path:, sha256:, size:, source_url: nil, added_at: nil)
      if version && (!version.is_a?(Integer) || version < 1)
        raise InvalidRecord, "asset version must be a positive integer"
      end
      unless safe_relative_path?(path)
        raise InvalidRecord, "asset path must be a safe relative path"
      end

      normalized_hash = sha256.to_s.downcase
      unless SHA256_RE.match?(normalized_hash)
        raise InvalidRecord, "asset sha256 is invalid"
      end
      unless size.is_a?(Integer) && size >= 0
        raise InvalidRecord, "asset size must be a non-negative integer"
      end

      @version = version
      @path = path.to_s
      @sha256 = normalized_hash
      @size = size
      @source_url = source_url && source_url.to_s
      @added_at = added_at ? added_at.to_s : Paper.timestamp
    end

    def self.from_h(value)
      raise InvalidRecord, "asset must be an object" unless value.is_a?(Hash)

      new(
        version: value["version"],
        path: value["path"],
        sha256: value["sha256"],
        size: value["size"],
        source_url: value["source_url"],
        added_at: value["added_at"]
      )
    end

    def to_h
      {
        "version" => @version,
        "path" => @path,
        "sha256" => @sha256,
        "size" => @size,
        "source_url" => @source_url,
        "added_at" => @added_at,
      }
    end

    def same_payload?(other)
      other.is_a?(Asset) && other.sha256 == @sha256
    end

    def ==(other)
      other.is_a?(Asset) && other.to_h == to_h
    end

    private

    def safe_relative_path?(value)
      string = value.to_s
      return false if string.empty? || string.include?("\0") || string.include?("\\")
      return false if string.start_with?("/")

      parts = string.split("/")
      !parts.empty? && parts.none? { |part| part.empty? || part == "." || part == ".." }
    end
  end

  # A schema-versioned logical paper record. A paper can retain several arXiv
  # versions without duplicating records or conflating an asset with a work.
  class Paper
    SCHEMA_VERSION = 1

    attr_reader :schema_version, :key, :identity, :metadata, :aliases,
                :assets, :created_at, :updated_at

    def self.timestamp(time = Time.now)
      time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def initialize(identity:, metadata: {}, aliases: [], assets: [],
                   created_at: nil, updated_at: nil, key: nil,
                   schema_version: SCHEMA_VERSION)
      unless schema_version == SCHEMA_VERSION
        raise InvalidRecord, "unsupported record schema: #{schema_version.inspect}"
      end
      raise InvalidRecord, "paper identity is invalid" unless identity.is_a?(Identity)

      @schema_version = schema_version
      @identity = identity.without_version
      @key = @identity.canonical_key
      if key && key.to_s != @key
        raise InvalidRecord, "record key does not match its identity"
      end

      @metadata = normalize_metadata(metadata)
      @aliases = []
      add_aliases!(@identity.aliases, touch: false)
      add_aliases!(aliases, touch: false)
      @assets = []
      assets.each do |asset|
        add_asset!(asset, touch: false)
      end
      @created_at = created_at ? created_at.to_s : self.class.timestamp
      @updated_at = updated_at ? updated_at.to_s : @created_at
    end

    def self.from_h(value)
      raise InvalidRecord, "paper record must be an object" unless value.is_a?(Hash)

      schema = value["schema_version"]
      unless schema == SCHEMA_VERSION
        raise InvalidRecord, "unsupported record schema: #{schema.inspect}"
      end
      identity = Identity.from_h(value["identity"])
      assets = value["assets"]
      aliases = value["aliases"]
      metadata = value["metadata"]
      raise InvalidRecord, "record assets must be an array" unless assets.is_a?(Array)
      raise InvalidRecord, "record aliases must be an array" unless aliases.is_a?(Array)
      raise InvalidRecord, "record metadata must be an object" unless metadata.is_a?(Hash)

      new(
        identity: identity,
        metadata: metadata,
        aliases: aliases,
        assets: assets.map { |asset| Asset.from_h(asset) },
        created_at: value["created_at"],
        updated_at: value["updated_at"],
        key: value["key"],
        schema_version: schema
      )
    end

    def title
      @metadata["title"].to_s
    end

    def authors
      value = @metadata["authors"]
      value.is_a?(Array) ? value : []
    end

    def add_alias!(value, touch: true)
      alias_value = value.to_s.strip
      return false if alias_value.empty? || @aliases.include?(alias_value)

      @aliases << alias_value
      touch! if touch
      true
    end

    def add_aliases!(values, touch: true)
      changed = false
      Array(values).each do |value|
        changed = add_alias!(value, touch: false) || changed
      end
      touch! if changed && touch
      changed
    end

    def merge_metadata!(values, touch: true)
      normalized = normalize_metadata(values)
      changed = false
      normalized.each do |key, value|
        next if @metadata[key] == value
        @metadata[key] = value
        changed = true
      end
      touch! if changed && touch
      changed
    end

    def add_asset!(asset, touch: true)
      raise InvalidRecord, "paper asset is invalid" unless asset.is_a?(Asset)

      existing = asset_for_version(asset.version)
      if existing
        return existing if existing.sha256 == asset.sha256
        label = asset.version ? "v#{asset.version}" : "unversioned asset"
        raise AssetConflict, "#{@key} already has a different #{label}"
      end

      @assets << asset
      touch! if touch
      asset
    end

    def asset_for_version(version)
      @assets.find { |asset| asset.version == version }
    end

    def asset_for_hash(sha256)
      normalized = sha256.to_s.downcase.sub(/\Asha256:/, "")
      @assets.find { |asset| asset.sha256 == normalized }
    end

    def current_asset
      @assets.max_by { |asset| [asset.version || 0, asset.added_at] }
    end

    def touch!(at = nil)
      @updated_at = at ? at.to_s : self.class.timestamp
      self
    end

    def to_h
      {
        "schema_version" => @schema_version,
        "key" => @key,
        "identity" => @identity.to_h,
        "metadata" => @metadata,
        "aliases" => @aliases,
        "assets" => @assets.map(&:to_h),
        "created_at" => @created_at,
        "updated_at" => @updated_at,
      }
    end

    def ==(other)
      other.is_a?(Paper) && other.to_h == to_h
    end

    private

    def normalize_metadata(value)
      raise InvalidRecord, "paper metadata must be an object" unless value.is_a?(Hash)

      normalized = {}
      value.each { |key, item| normalized[key.to_s] = item }
      normalized
    end
  end
end
