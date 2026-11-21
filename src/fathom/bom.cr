module Fathom
  # Byte Order Mark (BOM) detection for Unicode encodings.
  module BOM
    # Inspects the leading bytes of *bytes* for a known Unicode BOM.
    #
    # Checks 4-byte UTF-32 BOMs before 2-byte UTF-16 BOMs because UTF-32LE's BOM
    # starts with the same two bytes (`0xFF 0xFE`) as UTF-16LE.
    def self.detect(bytes : Bytes) : Match?
      size = bytes.size
      ptr = bytes.to_unsafe

      if size >= 4
        b0 = ptr[0]
        b1 = ptr[1]
        b2 = ptr[2]
        b3 = ptr[3]
        return Match.new("UTF-32LE", 1.0, bom: true) if b0 == 0xFF_u8 && b1 == 0xFE_u8 && b2 == 0x00_u8 && b3 == 0x00_u8
        return Match.new("UTF-32BE", 1.0, bom: true) if b0 == 0x00_u8 && b1 == 0x00_u8 && b2 == 0xFE_u8 && b3 == 0xFF_u8
      end

      if size >= 3 && ptr[0] == 0xEF_u8 && ptr[1] == 0xBB_u8 && ptr[2] == 0xBF_u8
        return Match.new("UTF-8", 1.0, bom: true)
      end

      if size >= 2
        b0 = ptr[0]
        b1 = ptr[1]
        return Match.new("UTF-16LE", 1.0, bom: true) if b0 == 0xFF_u8 && b1 == 0xFE_u8
        return Match.new("UTF-16BE", 1.0, bom: true) if b0 == 0xFE_u8 && b1 == 0xFF_u8
      end

      nil
    end
  end
end
