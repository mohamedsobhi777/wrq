# frozen_string_literal: true

require "digest"

module Wrq
  # Small incremental SHA-256 implementation used for streamed PDFs. Spinel's
  # bundled Digest surface intentionally exposes one-shot helpers only; keeping
  # the state machine here avoids loading an entire (potentially large) paper
  # into memory and produces identical hashes on MRI and native builds.
  class PortableSHA256
    INITIAL_STATE = [
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ].freeze

    ROUND_CONSTANTS = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
      0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
      0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
      0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
      0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
      0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
      0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
      0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
      0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ].freeze

    MASK = 0xffffffff
    HEX = "0123456789abcdef"

    def self.hexdigest(value)
      new.update(value).hexdigest
    end

    def self.file(path, chunk_size = 1024 * 1024)
      digest = new
      File.open(path.to_s, "rb") do |file|
        loop do
          begin
            chunk = file.readpartial(chunk_size)
          rescue EOFError
            break
          end
          digest.update(chunk)
        end
      end
      digest.hexdigest
    end

    def initialize
      @state = INITIAL_STATE.dup
      @buffer = String.new
      @byte_length = 0
      @finished = false
      @hex = nil
    end

    def update(value)
      raise ArgumentError, "cannot update a finished SHA-256 digest" if @finished

      bytes = value.to_s
      @byte_length += bytes.bytesize
      combined = @buffer + bytes
      offset = 0
      while offset + 64 <= combined.bytesize
        compress(combined.byteslice(offset, 64))
        offset += 64
      end
      remaining = combined.bytesize - offset
      @buffer = remaining.positive? ? combined.byteslice(offset, remaining) : String.new
      self
    end

    def hexdigest
      finish unless @finished
      @hex
    end

    private

    def finish
      bit_length = @byte_length * 8
      padding = "\x80".b
      zero_count = (56 - ((@byte_length + 1) % 64)) % 64
      padding << ("\x00".b * zero_count)
      padding << [((bit_length >> 32) & MASK), (bit_length & MASK)].pack("N2")

      combined = @buffer + padding
      offset = 0
      while offset < combined.bytesize
        compress(combined.byteslice(offset, 64))
        offset += 64
      end

      raw = @state.pack("N8")
      encoded = String.new
      raw.each_byte do |byte|
        encoded << HEX[(byte >> 4) & 0x0f, 1]
        encoded << HEX[byte & 0x0f, 1]
      end
      @hex = encoded
      @buffer = String.new
      @finished = true
    end

    def compress(block)
      words = block.unpack("N16")
      index = 16
      while index < 64
        a = words[index - 15]
        b = words[index - 2]
        sigma0 = rotate_right(a, 7) ^ rotate_right(a, 18) ^ (a >> 3)
        sigma1 = rotate_right(b, 17) ^ rotate_right(b, 19) ^ (b >> 10)
        words << ((words[index - 16] + sigma0 + words[index - 7] + sigma1) & MASK)
        index += 1
      end

      a = @state[0]
      b = @state[1]
      c = @state[2]
      d = @state[3]
      e = @state[4]
      f = @state[5]
      g = @state[6]
      h = @state[7]

      index = 0
      while index < 64
        upper = rotate_right(e, 6) ^ rotate_right(e, 11) ^ rotate_right(e, 25)
        choice = (e & f) ^ ((~e) & g)
        temporary1 = (h + upper + choice + ROUND_CONSTANTS[index] + words[index]) & MASK
        lower = rotate_right(a, 2) ^ rotate_right(a, 13) ^ rotate_right(a, 22)
        majority = (a & b) ^ (a & c) ^ (b & c)
        temporary2 = (lower + majority) & MASK

        h = g
        g = f
        f = e
        e = (d + temporary1) & MASK
        d = c
        c = b
        b = a
        a = (temporary1 + temporary2) & MASK
        index += 1
      end

      @state[0] = (@state[0] + a) & MASK
      @state[1] = (@state[1] + b) & MASK
      @state[2] = (@state[2] + c) & MASK
      @state[3] = (@state[3] + d) & MASK
      @state[4] = (@state[4] + e) & MASK
      @state[5] = (@state[5] + f) & MASK
      @state[6] = (@state[6] + g) & MASK
      @state[7] = (@state[7] + h) & MASK
    end

    def rotate_right(value, amount)
      ((value >> amount) | ((value << (32 - amount)) & MASK)) & MASK
    end
  end

  # Select MRI's optimized C implementation when RubyVM proves it is
  # available, otherwise use the portable state machine above. Spinel folds
  # the RubyVM guard at compile time, so unsupported incremental Digest calls
  # never reach its native program while MRI hashes large PDFs at full speed.
  class SHA256
    NATIVE = !!(defined?(RubyVM) && Digest::SHA256.new.respond_to?(:update))

    def self.hexdigest(value)
      new.update(value).hexdigest
    end

    def self.file(path, chunk_size = 1024 * 1024)
      if defined?(RubyVM) && NATIVE
        Digest::SHA256.file(path.to_s).hexdigest
      else
        PortableSHA256.file(path, chunk_size)
      end
    end

    def initialize
      @engine = if defined?(RubyVM) && NATIVE
                  Digest::SHA256.new
                else
                  PortableSHA256.new
                end
      @finished = false
      @hex = nil
    end

    def update(value)
      raise ArgumentError, "cannot update a finished SHA-256 digest" if @finished
      @engine.update(value.to_s)
      self
    end

    def hexdigest
      unless @finished
        @hex = @engine.hexdigest
        @finished = true
      end
      @hex
    end
  end
end
