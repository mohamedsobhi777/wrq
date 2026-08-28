# frozen_string_literal: true

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

      # Read either symbol or string keys, falling back to a public reader on
      # record objects. This intentionally avoids Hash#dig so simple Hash-like
      # implementations work too.
      def value(record, *keys)
        data = record_data(record)

        keys.each do |key|
          found, candidate = value_from(data, key)
          return candidate if found && !candidate.nil?

          if !record.equal?(data) && record.respond_to?(key)
            begin
              candidate = record.public_send(key)
              return candidate unless candidate.nil?
            rescue ArgumentError, NoMethodError
            end
          end
        end

        metadata = value_from(data, :metadata)
        if metadata[0] && metadata[1]
          keys.each do |key|
            found, candidate = value_from(metadata[1], key)
            return candidate if found && !candidate.nil?
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
        text = reference.to_s.strip.downcase
        text = text.split(/[?#]/, 2)[0].to_s

        marker = "arxiv.org/abs/"
        if text.include?(marker)
          text = text.split(marker, 2)[1].to_s
        else
          marker = "arxiv.org/pdf/"
          if text.include?(marker)
            text = text.split(marker, 2)[1].to_s
          else
            marker = "huggingface.co/papers/"
            text = text.split(marker, 2)[1].to_s if text.include?(marker)
          end
        end

        text = text.sub(/\Aarxiv\s*:\s*/i, "")
        text = text.sub(/\.pdf\z/i, "")
        text = text.sub(/v\d+\z/i, "")
        text.strip
      end

      private

      def record_data(record)
        return record unless record.respond_to?(:to_h)

        begin
          converted = record.to_h
          converted || record
        rescue ArgumentError, NoMethodError, TypeError
          record
        end
      end

      def value_from(data, key)
        return [false, nil] unless data.respond_to?(:[])

        variants = [key]
        begin
          variants << key.to_sym
        rescue NoMethodError
        end
        variants << key.to_s
        variants.uniq.each do |variant|
          if data.respond_to?(:key?)
            return [true, data[variant]] if data.key?(variant)
          else
            begin
              candidate = data[variant]
              return [true, candidate] unless candidate.nil?
            rescue ArgumentError, IndexError, TypeError
            end
          end
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

      return nil unless best_score

      Result.new(record, best_score + recency, title_match ? title_match[1] : [], best_field)
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
      text.strip.gsub(/[[:space:]]+/, " ")
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
      return value.to_time if value.respond_to?(:to_time)

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
