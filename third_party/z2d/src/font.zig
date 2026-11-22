// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2026 Chris Marchesi

//! Contains abstractions for font and collection data required for drawing
//! text.
//!
//! Font data can currently be loaded in from whole, single-font
//! TrueType/OpenType files, or from font collection files (aka TTC/TrueType
//! Font Collection files).
//!
//! Interactions with font enumeration or substitution subsystems like
//! fontconfig are not supported - this means that the font file to be used
//! must be located ahead of time and contain all of the fonts and glyphs
//! necessary to render the desired text (no falling back to other fonts).

const std = @import("std");

const readerInt = @import("internal/util.zig").readerInt;
const readerSeek = @import("internal/util.zig").readerSeek;

/// Errors associated with reading font file data, generally an alias for file
/// and stream read operations.
pub const ReaderError = error{ InvalidSeek, EndOfStream, ReadFailed };

/// Represents a full collection of fonts, loaded from either a single-font
/// file (e.g., .otf, .ttf), or font collection file (.ttc).
pub const File = struct {
    /// The type of the font file.
    pub const Type = enum {
        /// A file containing a single font (.otf, .ttf, etc).
        single,

        /// A file containing a collection (.ttc, etc).
        collection,
    };

    /// The binary font data.
    buffer: []const u8,

    /// The number of fonts in the font file.
    num_fonts: union(Type) {
        single: void,
        collection: u32,
    },

    /// Errors associated with loading a font from a file.
    pub const LoadFileError = LoadBufferError || std.Io.Dir.ReadFileAllocError;

    /// Opens the font or font collection file at `filename` and loads its
    /// offsets.
    ///
    /// `deinit` must be called to free the memory when you are finished with
    /// the font data.
    pub fn loadFile(io: std.Io, alloc: std.mem.Allocator, filename: []const u8) LoadFileError!File {
        return loadBuffer(try std.Io.Dir.cwd().readFileAlloc(io, filename, alloc, .unlimited));
    }

    /// Errors associated with loading a font from a buffer.
    pub const LoadBufferError = DetectFileTypeError || ReaderError;

    /// Loads and validates a font from a buffer. Expects the font to be a single
    /// font file (collections are not supported).
    ///
    /// Do not use `deinit` when using this function, as it will produce illegal
    /// behavior.
    pub fn loadBuffer(buffer: []const u8) LoadBufferError!File {
        var file = std.Io.Reader.fixed(buffer);
        switch (try detectFileType(&file)) {
            .single => return .{ .buffer = buffer, .num_fonts = .single },
            .collection => {
                // Our file type detection will leave the reader at the
                // numFonts entry, so we can just read that in.
                const num_fonts = try readerInt(&file, u32, .big);
                return .{
                    .buffer = buffer,
                    .num_fonts = .{ .collection = num_fonts },
                };
            },
        }
    }

    /// Frees the memory allocated when using `loadFile`. It's an illegal operation
    /// to use this with `loadBuffer`.
    pub fn deinit(self: *File, alloc: std.mem.Allocator) void {
        alloc.free(self.buffer);
        self.* = undefined;
    }

    /// Errors associated with loading a font from the file.
    pub const LoadFontIndexError = error{
        /// The index is out of range of the amount of fonts in the file.
        IndexOutOfRange,
    } || ReaderError || Font.LoadBufferOffsetError;

    /// Retrieves the font at `index` in the file. Performs checksum validation
    /// on the data.
    pub fn loadFontIndex(self: *const File, index: u32) LoadFontIndexError!Font {
        const offset: u32 = switch (self.num_fonts) {
            .single => single: {
                if (index != 0) {
                    return error.IndexOutOfRange;
                }
                break :single 0;
            },
            .collection => |num_fonts| collection: {
                if (index > num_fonts - 1) {
                    return error.IndexOutOfRange;
                }
                var reader: std.Io.Reader = .fixed(self.buffer);
                try readerSeek(&reader, 12 + 4 * index);
                break :collection try readerInt(&reader, u32, .big);
            },
        };

        return try Font.loadBufferOffset(self.buffer, offset);
    }

    /// Errors associated with validating the font file type.
    const DetectFileTypeError = error{
        /// The font file's magic number (first u32) does not match a supported
        /// format.
        InvalidFormat,
    } || ReaderError;

    fn detectFileType(file: *std.Io.Reader) DetectFileTypeError!Type {
        var header: [4]u8 = @splat(0);
        try file.readSliceAll(&header);

        // Font files

        if (std.mem.eql(u8, &header, &.{ '1', 0, 0, 0 })) return .single;
        if (std.mem.eql(u8, &header, "OTTO")) return .single;
        if (std.mem.eql(u8, &header, &.{ 0, 1, 0, 0 })) return .single;
        if (std.mem.eql(u8, &header, "true")) return .single;

        // Font collections
        if (std.mem.eql(u8, &header, "ttcf")) {
            // Validate the major/minor versions to ensure that they are of the
            // versions that we support.
            const major_version = try readerInt(file, u16, .big);
            const minor_version = try readerInt(file, u16, .big);
            if ((major_version == 1 or major_version == 2) and minor_version == 0) {
                return .collection;
            }
        }

        // Invalid or unrecognized format
        return error.InvalidFormat;
    }
};

/// Represents all static font data (loaded font based on family selection
/// data, table directory, metrics, etc), including any file handles associated
/// with the font.
pub const Font = struct {
    file: std.Io.Reader,
    dir: Directory,
    meta: Meta,

    /// Where this font's table directory starts in `file`: zero for a
    /// single-font file, and wherever the collection header says for a font
    /// out of a collection.
    offset: u32 = 0,

    /// Errors associated with loading a font from a buffer and selected offset.
    pub const LoadBufferOffsetError = ReaderError || Directory.InitError || Meta.InitError;

    /// Loads and validates a font from the supplied `buffer`, at the supplied
    /// `offset`. For single-font files, the offset should always be zero.
    ///
    /// Note that other than the checksum verification and the requirement for
    /// certain tables, there are no guarantees on this function with regards
    /// to correctness. Choosing the incorrect offset is likely to result in
    /// undefined behavior. It is recommended to use the functionality within
    /// `File` instead, which supplies a higher-level interface.
    pub fn loadBufferOffset(buffer: []const u8, offset: u32) LoadBufferOffsetError!Font {
        var file = std.Io.Reader.fixed(buffer);
        try readerSeek(&file, offset);
        const dir = try Directory.init(&file);
        const meta = try Meta.init(&file, dir);
        // Reset our stream before we return it
        try readerSeek(&file, 0);

        return .{
            .file = file,
            .dir = dir,
            .meta = meta,
            .offset = offset,
        };
    }

    /// How far below the `y` given to `show` or `outline` the baseline sits, at
    /// `size` pixels.
    ///
    /// Exactly one em, and the reason is worth stating because it is not the
    /// answer typography would give. `Glyph.Outline` turns the font's upward y
    /// axis into a downward one by reflecting it about the **em box**:
    ///
    /// ```zig
    /// path.transformation = path.transformation
    ///     .scale(1.0, -1.0)
    ///     .translate(0.0, @as(f64, @floatFromInt(font.meta.units_per_em)) * -1.0);
    /// ```
    ///
    /// so a font-unit y of zero -- which is the baseline -- comes out at
    /// `units_per_em`, and scaling by `size / units_per_em` makes that `size`. The
    /// ascender does not come into it at all: the run is placed by the top of the
    /// design space rather than by the top of the ink.
    ///
    /// A caller given the *baseline* instead therefore draws at `baseline -
    /// baselineOffset(size)`. SVG's `<text>` has a `y` that is the baseline, and
    /// so does PostScript and most of what grew out of it.
    pub fn baselineOffset(self: Font, size: f64) f64 {
        _ = self;
        return size;
    }

    /// The distance from one baseline to the next at `size` pixels, as the face
    /// asks for it: ascender, descender and the gap between lines.
    pub fn lineHeight(self: Font, size: f64) f64 {
        const units = @as(f64, @floatFromInt(self.meta.ascender)) -
            @as(f64, @floatFromInt(self.meta.descender)) +
            @as(f64, @floatFromInt(self.meta.line_gap));
        return units / @as(f64, @floatFromInt(self.meta.units_per_em)) * size;
    }

    /// The typographic measurements a face records beyond its outlines, in font
    /// units, for whoever positions decorations and shifted text: SVG's
    /// `text-decoration` and `baseline-shift`, CSS's `vertical-align`.
    ///
    /// Every field is null where the face does not say. They live in two optional
    /// tables -- `OS/2` and `post` -- that plenty of fonts omit or truncate, and a
    /// sensible default for each depends on what is being drawn, so that choice
    /// is left to the caller rather than made here.
    pub const Metrics = struct {
        /// `post.underlinePosition`: the top of the underline relative to the
        /// baseline, negative for below it.
        underline_position: ?i16 = null,
        /// `post.underlineThickness`.
        underline_thickness: ?i16 = null,
        /// `OS/2.yStrikeoutPosition`: the top of the strikeout stroke above the
        /// baseline.
        strikeout_position: ?i16 = null,
        /// `OS/2.yStrikeoutSize`: its thickness.
        strikeout_size: ?i16 = null,
        /// `OS/2.ySubscriptYOffset`: how far a subscript is dropped, positive
        /// downward.
        subscript_y_offset: ?i16 = null,
        /// `OS/2.ySuperscriptYOffset`: how far a superscript is raised, positive
        /// upward.
        superscript_y_offset: ?i16 = null,
        /// `OS/2.sxHeight`, from version 2 of the table: the height of a
        /// lowercase x.
        x_height: ?i16 = null,
    };

    /// Reads the face's `Metrics` out of its `OS/2` and `post` tables.
    ///
    /// Looked up on demand rather than when the font is loaded, and without
    /// checking the tables' checksums, so that a face with a damaged `OS/2` or
    /// `post` loads exactly as it did before this existed and merely has fewer
    /// metrics. Every read is bounds-checked against the buffer and the table's
    /// recorded length; a field past the end of either is null.
    pub fn metrics(self: Font) Metrics {
        const buf = self.file.buffer;
        var result: Metrics = .{};
        if (tableSlice(buf, self.offset, "OS/2")) |os2| {
            const version = beInt(u16, os2, 0) orelse 0;
            result.subscript_y_offset = beInt(i16, os2, 16);
            result.superscript_y_offset = beInt(i16, os2, 24);
            result.strikeout_size = beInt(i16, os2, 26);
            result.strikeout_position = beInt(i16, os2, 28);
            if (version >= 2) result.x_height = beInt(i16, os2, 86);
        }
        if (tableSlice(buf, self.offset, "post")) |post| {
            result.underline_position = beInt(i16, post, 8);
            result.underline_thickness = beInt(i16, post, 10);
        }
        return result;
    }

    /// The bytes of the table tagged `tag` in the table directory at `start`,
    /// cut to the length the directory records and to the buffer; null where
    /// there is no such table. Table offsets are from the start of the file,
    /// even for a font in a collection.
    fn tableSlice(buf: []const u8, start: usize, tag: *const [4]u8) ?[]const u8 {
        const num_tables = beInt(u16, buf, start + 4) orelse return null;
        for (0..num_tables) |i| {
            const entry = start + 12 + i * 16;
            if (entry > buf.len or buf.len - entry < 16) return null;
            if (!std.mem.eql(u8, buf[entry..][0..4], tag)) continue;
            const offset = beInt(u32, buf, entry + 8) orelse return null;
            const len = beInt(u32, buf, entry + 12) orelse return null;
            if (offset > buf.len) return null;
            return buf[offset..][0..@min(len, buf.len - offset)];
        }
        return null;
    }

    /// A big-endian integer at `at` in `bytes`, or null past the end.
    fn beInt(comptime T: type, bytes: []const u8, at: usize) ?T {
        const n = @sizeOf(T);
        if (at > bytes.len or bytes.len - at < n) return null;
        return std.mem.readInt(T, bytes[at..][0..n], .big);
    }

    /// Represents the table directory via offsets.
    const Directory = struct {
        cmap: u32,
        glyf: u32,
        head: u32,
        hhea: u32,
        hmtx: u32,
        loca: u32,

        // Kerning tables (optional)
        kern: u32,
        GPOS: u32,

        /// Errors associated while loading the font table directory.
        const InitError = error{
            /// A checksum failure happened in the font file (e.g., when validating a
            /// table).
            ChecksumMismatch,

            /// A required table is missing in the font's directory.
            MissingRequiredTable,
        } || ReaderError;

        fn init(file: *std.Io.Reader) InitError!Directory {
            var result: Directory = result: {
                var r: Directory = undefined;
                inline for (@typeInfo(Directory).@"struct".field_names) |f_name| {
                    @field(r, f_name) = 0;
                }

                break :result r;
            };

            // Directory offsets are taken from the font start index
            const font_start_offset = file.seek;
            const table_num_offset = 4;
            const table_dir_offset = 12;
            const table_dir_entry_len = 16;

            try readerSeek(file, font_start_offset + table_num_offset);
            const num_tables = try readerInt(file, u16, .big);

            try readerSeek(file, table_dir_offset);

            for (0..num_tables) |dir_idx| {
                try readerSeek(file, dir_idx * table_dir_entry_len + font_start_offset + table_dir_offset);
                var entry_tag: [4]u8 = undefined;
                try file.readSliceAll(&entry_tag);
                inline for (@typeInfo(Directory).@"struct".field_names) |f_name| {
                    if (std.mem.eql(u8, &entry_tag, f_name)) {
                        const checksum: u32 = try readerInt(file, u32, .big);
                        const offset: u32 = try readerInt(file, u32, .big);
                        const len: u32 = try readerInt(file, u32, .big);

                        // Validate the checksum of the table. This is a simple
                        // addition of the u32 (padded) words in the table,
                        // discarding overflow.
                        // Note that due to the way the "head" table is written
                        // (which includes a checksum adjustment written after the
                        // directory is written), we need to assume a
                        // checksumAdjustment value of zero when calculating for
                        // the "head" table.
                        var actual_checksum: u32 = 0;
                        try readerSeek(file, offset); // Table offsets are always absolute
                        const is_head = std.mem.eql(u8, f_name, "head");
                        for (0..((len + 3) / 4)) |j| {
                            if (is_head and j == 2)
                                _ = try readerInt(file, u32, .big)
                            else
                                actual_checksum, _ = @addWithOverflow(
                                    actual_checksum,
                                    try readerInt(file, u32, .big),
                                );
                        }

                        if (checksum != actual_checksum) {
                            return error.ChecksumMismatch;
                        }

                        @field(result, f_name) = offset;
                    }
                }
            }

            // We currently require all tables, so just go over them and make sure
            // all entries are present.
            inline for (@typeInfo(Directory).@"struct".field_names) |f_name| {
                comptime {
                    if (std.mem.eql(u8, f_name, "kern") or std.mem.eql(u8, f_name, "GPOS")) {
                        continue;
                    }
                }

                if (@field(result, f_name) == 0) {
                    return error.MissingRequiredTable;
                }
            }

            return result;
        }
    };

    /// Represents various metadata about the font that can be looked up ahead of
    /// time.
    const Meta = struct {
        const CmapSubtable = union(enum) {
            bmp: u32,
            full: u32,
        };

        const IndexToLocFormat = enum(u16) {
            short, // u16
            long, // u32
        };

        /// The type of the suitable cmap subtable that we found. We prefer the
        /// availability of a full repertoire table. Note that if the BMP is only
        /// supported, character ranges over U+FFFF will be unsupported and will be
        /// written as character 0 (unsupported block).
        cmap_subtable_offset: CmapSubtable,

        /// Denotes that the first phantom point (the left-side bearing point) is
        /// at x=0, found in the flags of the "head" table. When this is the case,
        /// xMin == lsb and we don't perform any more offsetting.
        lsb_is_at_x_zero: bool,

        /// The width of entries in the "loca" table.
        index_to_loc_format: IndexToLocFormat,

        /// The advanceWidthMax from the "hhea" table.
        advance_width_max: u16,

        /// The numberOfHMetrics from the "hhea" table,
        number_of_hmetrics: u16,

        /// The unitsPerEm value from the "head" table.
        units_per_em: u16,

        /// The ascender from the "hhea" table, in font units: how far the face
        /// reaches above the baseline.
        ///
        /// Worth having because `show` and `outline` take the top of the em box
        /// rather than the baseline, and a good many things that draw text are
        /// given the baseline instead -- SVG's `<text>` has a `y` that *is* the
        /// baseline, for one. `baselineOffset` is the conversion.
        ascender: i16,

        /// The descender from the "hhea" table, in font units. Negative for
        /// essentially every face, since it reaches below the baseline.
        descender: i16,

        /// The lineGap from the "hhea" table, in font units: what a face asks to
        /// be left between one line's descender and the next line's ascender.
        line_gap: i16,

        /// Errors associated with loading font file metadata.
        const InitError = error{
            /// No suitable cmap subtable could be found to load glyphs from.
            ///
            /// The "cmap" table must have one of the following subtables to work:
            ///
            /// * Unicode encoding (platform type 0): BMP (encoding type 3) or full
            /// (encoding type 4), or:
            ///
            /// * Windows encoding (platform type 3): BMP (encoding type 1) or full
            /// (encoding type 10).
            ///
            /// All other types are currently not supported by the library.
            NoSuitableCmapSubtable,

            /// The indexToLocFormat entry in the "head" table is an unsupported
            /// value (neither 0 or 1). This likely means that the font is
            /// corrupted.
            InvalidIndexToLocFormat,
        } || ReaderError;

        fn init(file: *std.Io.Reader, dir: Directory) InitError!Meta {
            const cmap_subtable_offset: CmapSubtable = cmap_subtable_offset: {
                // We don't really do a lot of hard work here to look for the table; we
                // just look for either Windows or Unicode platform with the appropriate
                // encoding, which will then either give us a type 4 or type 12 subtable,
                // which will be the kind that we return. We return the first match.
                var bmp_offset: u32 = 0;
                var full_offset: u32 = 0;

                const table_num_offset = dir.cmap + 2;

                const encoding_platform_unicode = 0;
                const encoding_platform_windows = 3;

                const unicode_encoding_bmp = 3;
                const unicode_encoding_full = 4;

                const windows_encoding_bmp = 1;
                const windows_encoding_full = 10;

                try readerSeek(file, table_num_offset);
                const num_tables = try readerInt(file, u16, .big);

                for (0..num_tables) |_| {
                    const platform_id = try readerInt(file, u16, .big);
                    const encoding_id = try readerInt(file, u16, .big);
                    const subtable_offset = try readerInt(file, u32, .big) + dir.cmap;

                    if (platform_id == encoding_platform_unicode) {
                        switch (encoding_id) {
                            unicode_encoding_bmp => bmp_offset = subtable_offset,
                            unicode_encoding_full => full_offset = subtable_offset,
                            else => continue,
                        }
                    }

                    if (platform_id == encoding_platform_windows) {
                        switch (encoding_id) {
                            windows_encoding_bmp => bmp_offset = subtable_offset,
                            windows_encoding_full => full_offset = subtable_offset,
                            else => continue,
                        }
                    }
                }

                break :cmap_subtable_offset if (full_offset != 0)
                    .{ .full = full_offset }
                else if (bmp_offset != 0)
                    .{ .bmp = bmp_offset }
                else
                    return error.NoSuitableCmapSubtable;
            };

            const head_flags = dir.head + 14;
            const units_per_em_offset = dir.head + 18;
            const index_to_loc_format_offset = dir.head + 50;
            try readerSeek(file, head_flags);
            const lsb_is_at_x_zero: bool = @bitCast(@as(
                u1,
                @intCast(try readerInt(file, u16, .big) & 2 >> 1),
            ));
            try readerSeek(file, index_to_loc_format_offset);
            const index_to_loc_format = try readerInt(file, u16, .big);
            try readerSeek(file, units_per_em_offset);
            const units_per_em = try readerInt(file, u16, .big);

            // The "hhea" table's vertical metrics, which sit in a row from offset
            // four: ascender, descender, lineGap, each a signed font-unit value.
            const ascender_offset = dir.hhea + 4;
            const advance_width_max_offset = dir.hhea + 10;
            const number_of_hmetrics_offset = dir.hhea + 34;
            try readerSeek(file, ascender_offset);
            const ascender = try readerInt(file, i16, .big);
            const descender = try readerInt(file, i16, .big);
            const line_gap = try readerInt(file, i16, .big);
            try readerSeek(file, advance_width_max_offset);
            const advance_width_max = try readerInt(file, u16, .big);
            try readerSeek(file, number_of_hmetrics_offset);
            const number_of_hmetrics = try readerInt(file, u16, .big);

            return .{
                .cmap_subtable_offset = cmap_subtable_offset,
                .lsb_is_at_x_zero = lsb_is_at_x_zero,
                .index_to_loc_format = switch (index_to_loc_format) {
                    0 => .short,
                    1 => .long,
                    else => return error.InvalidIndexToLocFormat,
                },
                .advance_width_max = advance_width_max,
                .number_of_hmetrics = number_of_hmetrics,
                .units_per_em = units_per_em,
                .ascender = ascender,
                .descender = descender,
                .line_gap = line_gap,
            };
        }
    };
};

test "Font.loadBufferOffset" {
    const actual: Font = try .loadBufferOffset(TestSingleFont.data, 0);
    try std.testing.expectEqualDeep(TestSingleFont.expected.directory, actual.dir);
    try std.testing.expectEqualDeep(TestSingleFont.expected.meta, actual.meta);
}

test "File.loadFile, loadBuffer, loadFontIndex e2e (single font)" {
    // NOTE: This test assumes cwd is the project root. This will possibly fail
    // if running outside of it, and is done for simplicity's sake - I don't
    // want to have to ship any sort of cwd info or what not down here from
    // build.zig just for testing purposes. Just run this using "zig build
    // test". :P
    var file: File = try .loadFile(std.testing.io, std.testing.allocator, TestSingleFont.filename);
    defer file.deinit(std.testing.allocator);
    const actual: Font = try file.loadFontIndex(0);
    try std.testing.expectEqualDeep(TestSingleFont.expected.directory, actual.dir);
    try std.testing.expectEqualDeep(TestSingleFont.expected.meta, actual.meta);
}

test "File.loadBuffer, loadFontIndex e2e (font collection)" {
    var file: File = try .loadBuffer(TestFontCollection.data);
    const actual_regular: Font = try file.loadFontIndex(0);
    try std.testing.expectEqualDeep(TestFontCollection.expected_regular.directory, actual_regular.dir);
    try std.testing.expectEqualDeep(TestFontCollection.expected_regular.meta, actual_regular.meta);
    const actual_bold: Font = try file.loadFontIndex(1);
    try std.testing.expectEqualDeep(TestFontCollection.expected_bold.directory, actual_bold.dir);
    try std.testing.expectEqualDeep(TestFontCollection.expected_bold.meta, actual_bold.meta);
}

test "File.loadFontIndex, out of range error cases" {
    {
        const file: File = try .loadBuffer(TestSingleFont.data);
        try std.testing.expectError(error.IndexOutOfRange, file.loadFontIndex(1));
    }
    {
        const file: File = try .loadBuffer(TestFontCollection.data);
        try std.testing.expectError(error.IndexOutOfRange, file.loadFontIndex(2));
    }
}

test "File.detectFileType, invalid format" {
    var invalid_file: std.Io.Reader = .fixed("NFNT"); // aka Not A Font ;)
    try std.testing.expectError(error.InvalidFormat, File.detectFileType(&invalid_file));
}

test "the baseline sits one em below where a run is placed" {
    const font: Font = try .loadBufferOffset(TestSingleFont.data, 0);

    // One em, not one ascender: the outline is reflected about the em box, so
    // the baseline lands at `units_per_em` and scales to exactly `size`.
    try std.testing.expectEqual(@as(f64, 32), font.baselineOffset(32));
    try std.testing.expectEqual(@as(f64, 16), font.baselineOffset(16));
    try std.testing.expectEqual(@as(f64, 0), font.baselineOffset(0));

    // Ascender minus descender plus the gap: this face asks for no gap, so
    // the line height is just the two.
    try std.testing.expectApproxEqAbs(
        @as(f64, (1984.0 + 494.0) / 2048.0 * 32.0),
        font.lineHeight(32),
        1e-9,
    );
    // And a line is taller than the ascender alone, which is the thing that
    // would be wrong if the descender's sign were mishandled.
    try std.testing.expect(font.lineHeight(32) > font.baselineOffset(32));
}

test "a face's decoration and shift metrics come from OS/2 and post" {
    const font: Font = try .loadBufferOffset(TestSingleFont.data, 0);
    const m = font.metrics();
    // Inter records every one of them; what matters here is that each came
    // from where it should and is the right sign.
    try std.testing.expect(m.underline_position.? < 0);
    try std.testing.expect(m.underline_thickness.? > 0);
    try std.testing.expect(m.strikeout_position.? > 0);
    try std.testing.expect(m.strikeout_size.? > 0);
    try std.testing.expect(m.subscript_y_offset.? > 0);
    try std.testing.expect(m.superscript_y_offset.? > 0);
    try std.testing.expect(m.x_height.? > 0 and m.x_height.? < font.meta.ascender);
}

test "each font in a collection has its own decoration metrics" {
    // The two faces share an OS/2 layout but not a weight, and the bold one's
    // strokes are heavier: which one was read says whose table directory the
    // lookup started from.
    const file: File = try .loadBuffer(TestFontCollection.data);
    const regular = (try file.loadFontIndex(0)).metrics();
    const bold = (try file.loadFontIndex(1)).metrics();
    try std.testing.expectEqual(@as(?i16, 140), regular.underline_thickness);
    try std.testing.expectEqual(@as(?i16, 140), regular.strikeout_size);
    try std.testing.expectEqual(@as(?i16, 190), bold.underline_thickness);
    try std.testing.expectEqual(@as(?i16, 190), bold.strikeout_size);
    try std.testing.expectEqual(@as(?i16, -348), regular.underline_position);
    try std.testing.expectEqual(@as(?i16, -323), bold.underline_position);
    try std.testing.expectEqual(@as(?i16, 1118), bold.x_height);
}

test "metrics past the end of a truncated table are null, not read" {
    var bytes = TestSingleFont.data.*;
    const font: Font = try .loadBufferOffset(&bytes, 0);
    const whole = font.metrics();
    // Shorten OS/2 in the directory to twenty bytes: the offsets past it are
    // gone, the one inside it stays.
    const num_tables = std.mem.readInt(u16, bytes[4..6], .big);
    for (0..num_tables) |i| {
        const entry = 12 + i * 16;
        if (std.mem.eql(u8, bytes[entry..][0..4], "OS/2")) std.mem.writeInt(u32, bytes[entry + 12 ..][0..4], 20, .big);
    }
    const cut = (try Font.loadBufferOffset(&bytes, 0)).metrics();
    try std.testing.expectEqual(whole.subscript_y_offset, cut.subscript_y_offset);
    try std.testing.expectEqual(@as(?i16, null), cut.superscript_y_offset);
    try std.testing.expectEqual(@as(?i16, null), cut.x_height);
    try std.testing.expectEqual(whole.underline_position, cut.underline_position);
    // And a buffer that is nothing but a header has none at all.
    try std.testing.expectEqual(Font.Metrics{}, tableless: {
        var tiny = [_]u8{ 0, 1, 0, 0, 0, 0 };
        break :tableless (Font{ .file = std.Io.Reader.fixed(&tiny), .dir = undefined, .meta = undefined }).metrics();
    });
}

const TestExpectedFontTableMeta = struct {
    directory: Font.Directory,
    meta: Font.Meta,
};

const TestSingleFont = struct {
    const path = "internal/test-fonts/Inter-Regular.subset.ttf";
    const filename = "src/" ++ path;
    const data = @embedFile(path);
    const expected: TestExpectedFontTableMeta = .{
        .directory = .{
            .cmap = 18720,
            .glyf = 236,
            .head = 17364,
            .hhea = 18588,
            .hmtx = 17420,
            .loca = 16776,
            .kern = 0,
            .GPOS = 19724,
        },
        .meta = .{
            .cmap_subtable_offset = .{ .bmp = 18740 },
            .lsb_is_at_x_zero = true,
            .index_to_loc_format = .short,
            .advance_width_max = 5492,
            .number_of_hmetrics = 292,
            .units_per_em = 2048,
            .ascender = 1984,
            .descender = -494,
            .line_gap = 0,
        },
    };
};

const TestFontCollection = struct {
    const data = @embedFile("internal/test-fonts/Inter-Regular-Bold.subset.ttc");
    const expected_regular: TestExpectedFontTableMeta = .{
        .directory = .{
            .cmap = 8504,
            .glyf = 304,
            .head = 8084,
            .hhea = 8372,
            .hmtx = 8140,
            .loca = 7964,
            .kern = 0,
            .GPOS = 13112,
        },
        .meta = .{
            .cmap_subtable_offset = .{ .bmp = 8524 },
            .lsb_is_at_x_zero = true,
            .index_to_loc_format = .short,
            .advance_width_max = 2018,
            .number_of_hmetrics = 58,
            .units_per_em = 2048,
            .ascender = 1984,
            .descender = -494,
            .line_gap = 0,
        },
    };
    const expected_bold: TestExpectedFontTableMeta = .{
        .directory = .{
            .cmap = 8504,
            .glyf = 15744,
            .head = 23580,
            .hhea = 23868,
            .hmtx = 23636,
            .loca = 23460,
            .kern = 0,
            .GPOS = 24644,
        },
        .meta = .{
            .cmap_subtable_offset = .{ .bmp = 8524 },
            .lsb_is_at_x_zero = true,
            .index_to_loc_format = .short,
            .advance_width_max = 2125,
            .number_of_hmetrics = 58,
            .units_per_em = 2048,
            .ascender = 1984,
            .descender = -494,
            .line_gap = 0,
        },
    };
};
