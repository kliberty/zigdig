const std = @import("std");
const dns = @import("./lib.zig");

const Name = dns.Name;
const ResourceType = dns.ResourceType;
const ResourceClass = dns.ResourceClass;

const logger = std.log.scoped(.dns_packet);

pub const ResponseCode = enum(u4) {
    NoError = 0,

    /// Format error - The name server was unable to interpret the query.
    FormatError = 1,

    /// Server failure - The name server was unable to process this query
    /// due to a problem with the name server.
    ServerFailure = 2,

    /// Name Error - Meaningful only for responses from an authoritative name
    /// server, this code signifies that the domain name referenced in
    /// the query does not exist.
    NameError = 3,

    /// Not Implemented - The name server does not support the requested
    /// kind of query.
    NotImplemented = 4,

    /// Refused - The name server refuses to perform the specified
    /// operation for policy reasons.  For example, a name server may not
    /// wish to provide the information to the particular requester,
    /// or a name server may not wish to perform a particular operation
    /// (e.g., zone transfer) for particular data.
    Refused = 5,
};

pub const OpCode = enum(u4) {
    Query = 0,
    InverseQuery = 1,
    ServerStatusRequest = 2,

    // rest is unused as per RFC1035
};

/// Describes the header of a DNS packet.
pub const Header = packed struct {
    /// The ID of the packet. Replies to a packet MUST have the same ID.
    id: u16 = 0,

    /// Query/Response flag
    /// Defines if this is a response packet or not.
    is_response: bool = false,

    /// specifies kind of query in this message.
    opcode: OpCode = .Query,

    /// Authoritative Answer flag
    /// Only valid in response packets. Specifies if the server
    /// replying is an authority for the domain name.
    aa_flag: bool = false,

    /// TC flag - TrunCation.
    /// If the packet was truncated.
    truncated: bool = false,

    /// RD flag - Recursion Desired.
    /// Must be copied to a response packet. If set, the server
    /// handling the request can pursue the query recursively.
    wanted_recursion: bool = false,

    /// RA flag - Recursion Available
    /// Whether recursive query support is available on the server.
    recursion_available: bool = false,

    /// DO NOT USE. RFC1035 has not assigned anything to the Z bits
    z: u3 = 0,

    /// Response code.
    response_code: ResponseCode = .NoError,

    /// Amount of questions in the packet.
    question_length: u16 = 0,

    /// Amount of answers in the packet.
    answer_length: u16 = 0,

    /// Amount of nameservers in the packet.
    nameserver_length: u16 = 0,

    /// Amount of additional records in the packet.
    additional_length: u16 = 0,

    const Self = @This();

    pub fn readFrom(byte_reader: anytype) !Self {
        var self = Self{};

        // turn incoming reader into a bitReader so that we can extract
        // non-u8-aligned data from it
        var reader = std.io.bitReader(.Big, byte_reader);

        const fields = @typeInfo(Self).Struct.fields;
        inline for (fields) |field| {
            var out_bits: usize = undefined;
            @field(self, field.name) = switch (field.type) {
                bool => (try reader.readBits(u1, 1, &out_bits)) > 0,
                u3 => try reader.readBits(u3, 3, &out_bits),
                u4 => try reader.readBits(u4, 4, &out_bits),
                OpCode, ResponseCode => blk: {
                    const tag_int = try reader.readBits(u4, 4, &out_bits);
                    break :blk try std.meta.intToEnum(field.type, tag_int);
                },
                u16 => try byte_reader.readIntBig(field.type),
                else => @compileError(
                    "unsupported type on header " ++ @typeName(field.type),
                ),
            };
        }
        return self;
    }

    pub fn writeTo(self: Self, byte_writer: anytype) !usize {
        var writer = std.io.bitWriter(.Big, byte_writer);

        var written_bits: usize = 0;

        const fields = @typeInfo(Self).Struct.fields;
        inline for (fields) |field| {
            const value = @field(self, field.name);
            written_bits += @bitSizeOf(field.type);
            switch (field.type) {
                bool => try writer.writeBits(@as(u1, if (value) 1 else 0), 1),
                u3 => try writer.writeBits(value, 3),
                u4 => try writer.writeBits(value, 4),
                OpCode, ResponseCode => try writer.writeBits(@enumToInt(value), 4),
                u16 => try writer.writeBits(value, 16),
                else => @compileError(
                    "unsupported type on header " ++ @typeName(field.type),
                ),
            }
        }

        try writer.flushBits();
        const written_bytes = written_bits / 8;
        std.debug.assert(written_bytes == 12);
        return written_bytes;
    }
};

pub const Question = struct {
    name: ?dns.Name,
    typ: ResourceType,
    class: ResourceClass,

    const Self = @This();

    pub fn readFrom(reader: anytype, options: dns.ParserOptions) !Self {
        logger.debug(
            "reading question at {d} bytes",
            .{reader.context.ctx.current_byte_count},
        );

        var name = try Name.readFrom(reader, options);
        var qtype = try reader.readEnum(ResourceType, .Big);
        var qclass = try ResourceClass.readFrom(reader);

        return Self{
            .name = name,
            .typ = qtype,
            .class = qclass,
        };
    }
};

/// DNS resource
pub const Resource = struct {
    name: ?dns.Name,
    typ: ResourceType,
    class: ResourceClass,

    ttl: i32,

    /// Opaque Resource Data.
    /// Parsing of the data in this is done by a separate package, dns.rdata
    opaque_rdata: ?dns.ResourceData.Opaque,

    const Self = @This();

    /// Extract an RDATA. This only spits out a slice of u8.
    /// Parsing of RDATA sections are in the dns.rdata module.
    ///
    /// Caller owns returned memory.
    fn readResourceDataFrom(
        reader: anytype,
        options: dns.ParserOptions,
    ) !?dns.ResourceData.Opaque {
        if (options.allocator) |allocator| {
            const rdata_length = try reader.readIntBig(u16);
            const rdata_index = reader.context.ctx.current_byte_count;

            var opaque_rdata = try allocator.alloc(u8, rdata_length);
            const read_bytes = try reader.read(opaque_rdata);
            std.debug.assert(read_bytes == opaque_rdata.len);
            return .{
                .data = opaque_rdata,
                .current_byte_count = rdata_index,
            };
        } else {
            return null;
        }
    }

    pub fn readFrom(reader: anytype, options: dns.ParserOptions) !Self {
        logger.debug("reading resource at {d} bytes", .{reader.context.ctx.current_byte_count});
        var name = try Name.readFrom(reader, options);
        var typ = try ResourceType.readFrom(reader);
        var class = try ResourceClass.readFrom(reader);
        var ttl = try reader.readIntBig(i32);
        var opaque_rdata = try Self.readResourceDataFrom(reader, options);

        return Self{
            .name = name,
            .typ = typ,
            .class = class,
            .ttl = ttl,
            .opaque_rdata = opaque_rdata,
        };
    }

    pub fn writeTo(self: @This(), writer: anytype) !usize {
        const name_size = try self.name.?.writeTo(writer);
        const typ_size = try self.typ.writeTo(writer);
        const class_size = try self.class.writeTo(writer);
        const ttl_size = 32 / 8;
        try writer.writeIntBig(i32, self.ttl);

        const rdata_prefix_size = 16 / 8;
        try writer.writeIntBig(u16, @intCast(u16, self.opaque_rdata.?.data.len));
        const rdata_size = try writer.write(self.opaque_rdata.?.data);

        return name_size + typ_size + class_size + ttl_size + rdata_prefix_size + rdata_size;
    }
};

const ByteList = std.ArrayList(u8);
const StringList = std.ArrayList([]u8);
const ManyStringList = std.ArrayList([][]const u8);

pub const LabelComponent = union(enum) {
    Full: []const u8,
    /// Holds the first offset component of that pointer.
    ///
    /// You still have to read a byte for the second component and assemble
    /// it into the final packet offset.
    Pointer: u8,
    Null: void,
};

const NameList = std.ArrayList(Name);

/// A DNS packet, as specified in RFC1035.
pub const Packet = struct {
    header: Header,
    questions: []Question,
    answers: []Resource,
    nameservers: []Resource,
    additionals: []Resource,

    /// Names that are held in RDATA sections are added here.
    ///
    /// This is an internal field that shouldn't be used by API consumers.
    extra_names: ?NameList = null,

    const Self = @This();

    fn writeResourceListTo(resource_list: []Resource, writer: anytype) !usize {
        var size: usize = 0;
        for (resource_list) |resource| {
            size += try resource.writeTo(writer);
        }
        return size;
    }

    /// Write the network representation of this packet into a Writer.
    pub fn writeTo(self: Self, writer: anytype) !usize {
        std.debug.assert(self.header.question_length == self.questions.len);
        std.debug.assert(self.header.answer_length == self.answers.len);
        std.debug.assert(self.header.nameserver_length == self.nameservers.len);
        std.debug.assert(self.header.additional_length == self.additionals.len);

        const header_size = try self.header.writeTo(writer);

        var question_size: usize = 0;

        for (self.questions) |question| {
            const question_name_size = try question.name.?.writeTo(writer);
            const question_typ_size = try question.typ.writeTo(writer);
            const question_class_size = try question.class.writeTo(writer);

            question_size += question_name_size + question_typ_size + question_class_size;
        }

        const answers_size = try Self.writeResourceListTo(self.answers, writer);
        const nameservers_size = try Self.writeResourceListTo(self.nameservers, writer);
        const additionals_size = try Self.writeResourceListTo(self.additionals, writer);

        logger.debug(
            "header = {d}, question_size = {d}, answers_size = {d}, nameservers_size = {d}, additionals_size = {d}",
            .{ header_size, question_size, answers_size, nameservers_size, additionals_size },
        );

        return header_size + question_size +
            answers_size + nameservers_size + additionals_size;
    }

    fn resolvePointer(
        self: Self,
        reader: anytype,
        first_offset_component: u8,
        allocator: std.mem.Allocator,
    ) ![][]const u8 {
        // we need to read another u8 and merge both that and first_offset_component
        // into a u16 we can use as an offset in the entire packet, etc.

        // the final offset is actually 14 bits, the first two are identification
        // of the offset itself.
        const second_offset_component = try reader.readIntBig(u8);

        // merge them together
        var offset: u16 = (first_offset_component << 7) | second_offset_component;

        // set first two bits of ptr_offset to zero as they're the
        // pointer prefix bits (which are always 1, which brings problems)
        offset &= ~@as(u16, 1 << 15);
        offset &= ~@as(u16, 1 << 14);

        // RFC1035 says:
        //
        // The OFFSET field specifies an offset from
        // the start of the message (i.e., the first octet of the ID field in the
        // domain header).  A zero offset specifies the first byte of the ID field,
        // etc.

        // algorithm:
        // - go through names in question, answer, nameserver, additional resources
        //   in that order
        // - when we find a name whose current_byte_count is within bounds of
        //   the given pointer offset, resolve it
        // - this means walk (current_byte_count - offset) bytes inside of the
        //    Name's labels, and create a new one from the pre-existing memory.
        //
        // make sure to dupe() the memory we get from a pre-existing label
        // or else we'll have double-free issues on IncomingPacket.deinit()
        //
        // the old implementation was recursive as pointers can point to other
        // pointers. this one does not have this issue as all pointers are
        // unfolded, and we use the unfolded results to unfold another
        // pointer.
        //
        // it also required holding the entire packet's bytes in memory, so
        // this new one has less memory usage as well, though it still requires
        // allocation.
        //
        // deserialization without allocation is hard as we need to take
        // a dynamic amount of bytes out of the Reader, HOWEVER, as we know
        // labels are 63 octets or less, we could create a Label struct
        // that has [63]u8 and a length pointer, so it can be safely operated
        // on in the stack.
        //
        // that also applies to names themselves, as they can have a maximum
        // size held on the stack.

        const fields_with_resources =
            .{ "questions", "answers", "nameservers", "additionals" };

        var maybe_referenced_name: ?dns.Name = null;

        inline for (fields_with_resources) |field_name| {
            const resource_list = @field(self, field_name);
            for (resource_list) |resource| {
                const name = resource.name;
                comptime std.debug.assert(@TypeOf(name) == dns.Name);
                const packet_index =
                    if (name.packet_index) |idx| idx else continue;

                const start_index = packet_index;
                var name_length: usize = 0;
                for (name.labels) |label| name_length += label.len;
                const end_index = packet_index + name_length;

                if (start_index <= offset and offset <= end_index) {
                    maybe_referenced_name = name;
                    break;
                }
            }

            if (maybe_referenced_name != null) break;
        }

        // TODO refactor copypaste

        if (self.extra_names) |names| {
            for (names.items) |name| {
                comptime std.debug.assert(@TypeOf(name) == dns.Name);
                const packet_index =
                    if (name.packet_index) |idx| idx else continue;

                const start_index = packet_index;
                var name_length: usize = 0;
                for (name.labels) |label| name_length += label.len;
                const end_index = packet_index + name_length;

                if (start_index <= offset and offset <= end_index) {
                    maybe_referenced_name = name;
                    break;
                }
            }
        }

        if (maybe_referenced_name) |referenced_name| {
            // now that we have a name that is within the given offset,
            // now we need to know which labels inside that name to dupe() from

            var new_labels = std.ArrayList([]const u8).init(allocator);
            defer new_labels.deinit();

            var label_cursor: usize = referenced_name.packet_index.?;
            var label_index: ?usize = null;

            for (referenced_name.labels) |label, idx| {
                // if cursor is in offset's range, select that
                // label onwards as our new label
                const label_start = label_cursor;
                if (label_start <= offset) {
                    label_index = idx;
                }
                label_cursor += label.len;
            }

            const referenced_labels = referenced_name.labels[label_index.?..];

            for (referenced_labels) |referenced_label| {
                const owned_label = try allocator.dupe(u8, referenced_label);
                try new_labels.append(owned_label);
            }

            return try new_labels.toOwnedSlice();
        } else {
            logger.warn("unknown pointer offset: pointer has offset={d}", .{offset});

            inline for (fields_with_resources) |field_name| {
                const resource_list = @field(self, field_name);
                for (resource_list) |resource| {
                    logger.warn(
                        "known name: {} at offset {?d}",
                        .{ resource.name, resource.name.packet_index },
                    );
                }
            }

            if (self.extra_names) |names| {
                for (names.items) |name| {
                    logger.warn(
                        "extra known name: {} at offset {?d}",
                        .{ name, name.packet_index },
                    );
                }
            }

            return error.UnknownPointerOffset;
        }
    }
    const ReadNameOptions = struct {
        max_label_count: usize = 128,
        is_rdata: bool = false,
    };

    /// You should not need to use this function unless you have a label to
    /// decode.
    ///
    /// This is used by ResourceData.fromOpaque so it can parse labels
    /// that are inside of the resource data section.
    pub fn readName(
        self: *Self,
        reader: anytype,
        allocator: std.mem.Allocator,
        options: ReadNameOptions,
    ) !Name {
        // RFC1035, 4.1.4 Message Compression:
        // The compression scheme allows a domain name in a message to be
        // represented as either:
        //
        //    - a sequence of labels ending in a zero octet
        //    - a pointer
        //    - a sequence of labels ending with a pointer
        //

        // To do that, we read incoming "components" and resolve pointers
        // when we find them, adding them into a final name_buffer

        var name_buffer = std.ArrayList([]const u8).init(allocator);
        defer name_buffer.deinit();

        const current_byte_count = reader.context.ctx.current_byte_count;

        while (true) {
            if (name_buffer.items.len > options.max_label_count)
                return error.Overflow;

            const component = try Self.readLabelComponent(reader, allocator);
            switch (component) {
                .Full => |label| try name_buffer.append(label),
                .Pointer => |first_offset_component| {
                    // as pointers are the end of a name, but they can appear
                    // after N Full labels, we need to copy the label array
                    // we allocated in resolvePointer() back to name_buffer.
                    //
                    // the old implementation just returned the full name, and
                    // required way more inner context for that to happen.
                    //
                    // and then we can break the loop, as that is the end of
                    // the DNS name

                    const labels = try self.resolvePointer(
                        reader,
                        first_offset_component,
                        allocator,
                    );
                    defer allocator.free(labels);

                    for (labels) |label| try name_buffer.append(label);
                    break;
                },
                .Null => break,
            }
        }

        const name = Name{
            .labels = try name_buffer.toOwnedSlice(),
            .packet_index = current_byte_count,
        };

        if (options.is_rdata) {
            try self.extra_names.?.append(name);
        }

        return name;
    }
};

/// Represents a Packet where all of its data was allocated dynamically
pub const IncomingPacket = struct {
    allocator: std.mem.Allocator,
    packet: *Packet,

    fn freeResource(
        self: @This(),
        resource: Resource,
        options: DeinitOptions,
    ) void {
        if (options.names)
            if (resource.name) |name| name.deinit(self.allocator);
        if (resource.opaque_rdata) |opaque_rdata|
            self.allocator.free(opaque_rdata.data);
    }

    fn freeResourceList(
        self: @This(),
        resource_list: []Resource,
        options: DeinitOptions,
    ) void {
        for (resource_list) |resource| self.freeResource(resource, options);
        self.allocator.free(resource_list);
    }

    pub const DeinitOptions = struct {
        names: bool = true,
    };

    pub fn deinit(self: @This(), options: DeinitOptions) void {
        if (options.names) for (self.packet.questions) |question| {
            if (question.name) |name| name.deinit(self.allocator);
        };

        self.allocator.free(self.packet.questions);
        self.freeResourceList(self.packet.answers, options);
        self.freeResourceList(self.packet.nameservers, options);
        self.freeResourceList(self.packet.additionals, options);

        self.allocator.destroy(self.packet);
    }
};
