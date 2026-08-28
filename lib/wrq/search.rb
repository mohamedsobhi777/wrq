# frozen_string_literal: true

require_relative "identity"
require_relative "paper"

module Wrq
  # Weighted, field-aware fuzzy search for paper records.
  #
  # Records may be Hashes, Hash-like objects, or objects implementing #to_h.
  # The returned Result keeps the original record so callers never lose type
  # information while searching.
  class Search
    EXACT_ID_SCORE = 6_000.0
    FIELD_SCORES = {
      canonical_id: 3_500.0,
      title: 4_000.0,
      authors: 3_000.0,
      venue: 2_000.0,
      tags: 2_000.0,
      abstract: 1_000.0
    }.freeze

    RECENCY_SCORE = 10.0

    class Result
      attr_reader :record, :score, :highlight_positions, :matched_field

      def initialize(record, score, highlight_positions, matched_field)
        @record = record
        @score = score
        @highlight_positions = highlight_positions
        @matched_field = matched_field
      end

      def [](key)
        normalized = begin
          key.to_sym
        rescue NoMethodError
          key
        end

        case normalized
        when :record
          record
        when :score
          score
        when :highlight_positions, :title_highlight_positions
          highlight_positions
        when :matched_field
          matched_field
        else
          Search.value(record, key)
        end
      end

      alias title_highlight_positions highlight_positions

      def to_h
        {
          record: record,
          score: score,
          highlight_positions: highlight_positions,
          matched_field: matched_field
        }
      end
    end

    class << self
      def call(records, query = "", limit: nil, now: Time.now)
        new(records, now: now).call(query, limit: limit)
      end

      alias search call

      # Read either symbol or string keys from a Hash, Hash-like object, or an
      # object's #to_h representation. Avoid runtime method dispatch so the
      # same search implementation remains whole-program AOT compatible.
      def value(record, *keys)
        if record.is_a?(Paper)
          data = record.to_h
          metadata = record.metadata
        elsif record.is_a?(Hash)
          data = record
          metadata = data["metadata"]
          metadata ||= data[:metadata] if defined?(RubyVM)
        elsif defined?(RubyVM)
          data = record_data(record)
          keys.each do |key|
            found, candidate = value_from(data, key)
            return candidate if found && !candidate.nil?
          end

          nested = value_from(data, :metadata)
          if nested[0] && nested[1]
            keys.each do |key|
              found, candidate = value_from(nested[1], key)
              return candidate if found && !candidate.nil?
            end
          end
          return nil
        else
          return nil
        end

        keys.each do |key|
          candidate = data[key.to_s]
          return candidate unless candidate.nil?
          if defined?(RubyVM)
            candidate = data[key]
            return candidate unless candidate.nil?
          end
        end

        if metadata.is_a?(Hash)
          keys.each do |key|
            candidate = metadata[key.to_s]
            return candidate unless candidate.nil?
            if defined?(RubyVM)
              candidate = metadata[key]
              return candidate unless candidate.nil?
            end
          end
        end

        nil
      end

      def canonical_id(record)
        value(record, :canonical_id, :arxiv_id, :id, :paper_id, :key).to_s
      end

      def title(record)
        value(record, :title, :name).to_s
      end

      def author_names(record)
        authors = value(record, :authors, :author)
        list = authors.is_a?(Array) ? authors : [authors]
        names = []

        list.each do |author|
          next if author.nil?

          if author.respond_to?(:to_h) || author.respond_to?(:[])
            name = value(author, :name, :full_name, :display_name)
            name = author.to_s if name.nil? || name.to_s.empty?
            names << name.to_s
          else
            names << author.to_s
          end
        end

        names.reject { |name| name.empty? }
      end

      def text_value(value)
        case value
        when nil
          ""
        when Array
          value.map { |item| text_value(item) }.reject { |item| item.empty? }.join(" ")
        when Hash
          preferred = value[:name] || value["name"] || value[:title] || value["title"]
          preferred ? preferred.to_s : value.values.map(&:to_s).join(" ")
        else
          value.to_s
        end
      end

      # Convert arXiv URLs, HF paper URLs, arxiv: references, and versioned IDs
      # to the logical versionless identifier used for exact-ID matching.
      def normalize_reference(reference)
        identity = Identity.recognize(reference)
        return identity.canonical_key if identity

        # Identity owns every supported URL and identifier normalization. A
        # value that reaches this branch is ordinary fuzzy-search text, so it
        # only needs case and surrounding-space normalization. Keeping this
        # branch free of regexp-based String#split also avoids an incompatible
        # overload in the Spinel runtime.
        reference.to_s.strip.downcase
      end

      private

      def record_data(record)
        return record.to_h if record.is_a?(Paper)
        return record if record.is_a?(Hash)
        return record unless defined?(RubyVM) && record.respond_to?(:to_h)

        begin
          converted = record.to_h
          converted || record
        rescue ArgumentError, NoMethodError, TypeError
          record
        end
      end

      def value_from(data, key)
        if data.is_a?(Hash)
          return [true, data[key]] if data.key?(key)

          string_key = key.to_s
          return [true, data[string_key]] if data.key?(string_key)

          if defined?(RubyVM)
            begin
              symbol_key = key.to_sym
              return [true, data[symbol_key]] if data.key?(symbol_key)
            rescue NoMethodError
            end
          end
          return [false, nil]
        end

        return [false, nil] unless defined?(RubyVM) && data.respond_to?(:[])

        begin
          candidate = data[key]
          return [true, candidate] unless candidate.nil?
        rescue ArgumentError, IndexError, TypeError
        end

        [false, nil]
      end
    end

    def initialize(records, now: Time.now)
      @records = records ? records.to_a : []
      @now = now
    end

    def call(query = "", limit: nil)
      normalized_query = normalize_space(query.to_s)
      results = []

      @records.each do |record|
        result = result_for(record, normalized_query)
        results << result if result
      end

      results.sort_by! do |result|
        record = result.record
        [
          -result.score,
          self.class.title(record).downcase,
          self.class.normalize_reference(self.class.canonical_id(record)),
          self.class.author_names(record).join("\u0000").downcase,
          self.class.text_value(self.class.value(record, :venue, :conference)).downcase,
          self.class.text_value(self.class.value(record, :tags, :categories)).downcase,
          self.class.text_value(self.class.value(record, :abstract, :summary)).downcase
        ]
      end

      apply_limit(results, limit)
    end

    alias search call
    alias results call

    private

    def result_for(record, query)
      recency = recency_score(record)
      return Result.new(record, recency, [], nil) if query.empty?

      canonical = self.class.canonical_id(record)
      normalized_id = self.class.normalize_reference(canonical)
      normalized_query_id = self.class.normalize_reference(query)
      exact_id = !normalized_id.empty? && normalized_id == normalized_query_id

      title = self.class.title(record)
      title_match = fuzzy_match(title, query)

      if exact_id
        return Result.new(record, EXACT_ID_SCORE + recency, title_match ? title_match[1] : [], :canonical_id)
      end

      fields = [
        [:canonical_id, canonical],
        [:title, title],
        [:authors, self.class.author_names(record).join(" ")],
        [:venue, self.class.text_value(self.class.value(record, :venue, :conference, :journal_ref))],
        [:tags, self.class.text_value(self.class.value(record, :tags, :categories))],
        [:abstract, self.class.text_value(self.class.value(record, :abstract, :summary))]
      ]

      best_field = nil
      best_score = nil
      fields.each do |field, text|
        match = field == :title ? title_match : fuzzy_match(text, query)
        next unless match

        score = FIELD_SCORES[field] + match[0]
        if best_score.nil? || score > best_score
          best_field = field
          best_score = score
        end
      end

      title_positions = title_match ? title_match[1] : []
      if best_score.nil?
        tokens = query.split(" ").reject(&:empty?).uniq
        if tokens.length > 1
          token_scores = []
          token_fields = []
          token_title_positions = []
          tokens.each do |token|
            token_best_score = nil
            token_best_field = nil
            token_best_positions = []
            fields.each do |field, text|
              match = fuzzy_match(text, token)
              next unless match

              score = FIELD_SCORES[field] + match[0]
              if token_best_score.nil? || score > token_best_score
                token_best_score = score
                token_best_field = field
                token_best_positions = match[1]
              end
            end
            return nil unless token_best_score

            token_scores << token_best_score
            token_fields << token_best_field
            if token_best_field == :title
              token_title_positions.concat(token_best_positions)
            end
          end
          best_score = token_scores.inject(0.0) { |sum, score| sum + score } /
            token_scores.length
          unique_fields = token_fields.uniq
          best_field = unique_fields.length == 1 ? unique_fields.first : :multiple
          title_positions = token_title_positions.uniq.sort
        end
      end

      return nil unless best_score

      Result.new(record, best_score + recency, title_positions, best_field)
    end

    # Returns [quality, positions]. Quality stays below a field's 1,000-point
    # band so the documented field ordering is stable and easy to reason about.
    def fuzzy_match(text, query)
      candidate = text.to_s
      return nil if candidate.strip.empty?

      candidate_lower = candidate.downcase
      query_lower = query.downcase
      return nil if query_lower.empty?

      # Prefer the contiguous occurrence when one exists. A plain left-to-right
      # subsequence can otherwise highlight an earlier incidental character
      # (for example the "i" in "Attention" for the query "is all").
      substring_start = candidate_lower.index(query_lower)
      if substring_start
        positions = []
        index = 0
        while index < query_lower.length
          positions << substring_start + index
          index += 1
        end

        exact = candidate_lower == query_lower
        prefix = substring_start == 0
        length_fit = query_lower.length.to_f / [candidate_lower.length, 1].max
        quality = if exact
          900.0
        elsif prefix
          800.0 + (50.0 * length_fit)
        else
          700.0 + (50.0 * length_fit)
        end
        return [quality, positions]
      end

      positions = []
      scan_from = 0
      last = -1
      consecutive = 0
      boundaries = 0

      query_lower.each_char do |character|
        found = candidate_lower.index(character, scan_from)
        return nil unless found

        positions << found
        consecutive += 1 if last >= 0 && found == last + 1
        boundaries += 1 if found == 0 || !word_character?(candidate_lower[found - 1])
        last = found
        scan_from = found + 1
      end

      span = positions[-1] - positions[0] + 1
      density = query_lower.length.to_f / span
      length_fit = query_lower.length.to_f / [candidate_lower.length, 1].max
      quality = 400.0 + (200.0 * density) + (10.0 * boundaries) +
        (10.0 * length_fit) + (5.0 * consecutive)

      [quality, positions]
    end

    def normalize_space(text)
      normalized = String.new
      pending_space = false
      text.each_char do |character|
        if whitespace_character?(character)
          pending_space = !normalized.empty?
        else
          normalized << " " if pending_space
          normalized << character
          pending_space = false
        end
      end
      normalized
    end

    def whitespace_character?(character)
      character == " " || character == "\t" || character == "\n" ||
        character == "\r" || character == "\f" || character == "\v"
    end

    def word_character?(character)
      return false if character.nil? || character.empty?

      code = character.ord
      (code >= 48 && code <= 57) ||
        (code >= 65 && code <= 90) ||
        (code >= 97 && code <= 122) ||
        code >= 128
    end

    def recency_score(record)
      raw = self.class.value(
        record,
        :last_opened_at,
        :last_accessed_at,
        :accessed_at,
        :updated_at,
        :downloaded_at,
        :added_at,
        :created_at,
        :mtime
      )
      time = coerce_time(raw)
      return 0.0 unless time

      age = @now.to_f - time.to_f
      age = 0.0 if age < 0.0
      days = age / 86_400.0
      RECENCY_SCORE / Math.sqrt(days + 1.0)
    end

    def coerce_time(value)
      return value if value.is_a?(Time)
      return Time.at(value) if value.is_a?(Numeric)

      text = value.to_s
      return nil if text.empty?

      # JSON metadata uses ISO 8601. Parsing its stable leading components here
      # avoids a dependency on Date/Time.parse in the native build.
      match = /\A(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?)?(Z|[+-]\d{2}:?\d{2})?/.match(text)
      return nil unless match

      offset = match[7]
      offset = "+00:00" if offset == "Z"
      Time.new(
        match[1].to_i,
        match[2].to_i,
        match[3].to_i,
        (match[4] || "0").to_i,
        (match[5] || "0").to_i,
        (match[6] || "0").to_i,
        offset
      )
    rescue ArgumentError, TypeError
      nil
    end

    def apply_limit(results, limit)
      return results if limit.nil?

      count = begin
        Integer(limit)
      rescue ArgumentError, TypeError
        results.length
      end
      count = 0 if count < 0
      return results if count >= results.length

      results[0, count]
    end
  end
end
