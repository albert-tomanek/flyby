namespace JPS
{
    // From https://web.archive.org/web/20130806123742/https://paulbourke.net/dataformats/stereoimage/
    public enum Info
    {
        /* Media Types */
        MTYPE_MONOSCOPIC_IMAGE = 0x00,
        MTYPE_STEREOSCOPIC_IMAGE = 0x01,

        /* layout Options */
        LAYOUT_INTERLEAVED = 0x0100,
        LAYOUT_SIDEBYSIDE = 0x0200,
        LAYOUT_OVERUNDER = 0x0300,
        LAYOUT_ANAGLYPH = 0x0400,

        /* Misc Flags Bits */
        FULL_HEIGHT = 0x000000,
        HALF_HEIGHT = 0x010000,
        FULL_WIDTH = 0x000000,
        HALF_WIDTH = 0x020000,
        RIGHT_FIELD_FIRST = 0x000000,
        LEFT_FIELD_FIRST = 0x040000
    }

    public void implant_jps_header(ByteArray jpeg_file, JPS.Info flags)
    {
        // Check for jpeg format
        const uint8[] JPEG_START = {0xff, 0xd8};
        assert(Memory.cmp(jpeg_file.data, JPEG_START, 2) == 0);

        jpeg_file.remove_range(0, JPEG_START.length);

        const uint8[] JPS_HEADER = {
            0xff, 0xe3, // APP0 chunk
            0x00, 0x10, // 16b length of chunk including this
            '_', 'J', 'P', 'S', 'J', 'P', 'S', '_',
            0x00, 0x04, // 16b length of JPS data excluding this: just a 32bit bitfield
        };

        uint32 flags_i = ((uint32)flags).to_big_endian();
        var flags_b = new uint8[4]; // TODO: Make this byte order independent. Currently only works on intel.
        Memory.copy(flags_b, &flags_i, 4);

        jpeg_file.prepend(flags_b);
        jpeg_file.prepend(JPS_HEADER);

        jpeg_file.prepend(JPEG_START);
    }
}