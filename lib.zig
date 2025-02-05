const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const meta = std.meta;
const testing = std.testing;

///
/// Similar to std.MultiArrayList() but backed by fixed size arrays with a
/// shared runtime length.
///
/// Each field of T becomes an array with max length `buffer_capacity`.  To
/// access the arrays as slices use `items(field)` or `constItems(field)`.
///
/// Useful when a struct of small arrays is desired with capacity that is
/// known at compile time.  Like std.BoundedArray, MultiBoundedArrays are only
/// values and thus may be copied.
///
/// ```zig
/// test "basic" {
///    const T = struct { int: u8, float: f32 };
///    var a = MultiBoundedArray(T, 64){};
///    try testing.expectEqual(0, a.len);
///    try a.append(.{ .int = 1, .float = 1 });
///    const mut_ints = a.items(.int);
///    // items() slice constness is inherited
///    try testing.expectEqual([]u8, @TypeOf(mut_ints));
///    try testing.expectEqual(1, mut_ints.len);
///    try testing.expectEqual(1, mut_ints[0]);
///    mut_ints[0] = 2;
///    const a_const_copy = a;
///    mut_ints[0] = 3;
///    const const_ints = a_const_copy.items(.int);
///    // items() slice constness is inherited
///    try testing.expectEqual([]const u8, @TypeOf(const_ints));
///    try testing.expectEqual(2, const_ints[0]);
/// }
/// ```
pub fn MultiBoundedArray(comptime T: type, comptime buffer_capacity: usize) type {
    return struct {
        const Self = @This();
        soa: StructOfArrays = undefined,
        len: usize = 0,

        pub const Child = T;
        pub const byte_size = @sizeOf(Self);
        pub const StructOfArrays = blk: {
            var res: [fields.len]std.builtin.Type.StructField = undefined;
            for (0..fields.len) |i| {
                const f = fields[i];
                res[i] = .{
                    .name = f.name,
                    .type = [buffer_capacity]f.type,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = f.alignment, // FIXME: is this always correct to inherit the child alignment?
                };
            }

            // FIXME: not sure whether to inherit is_tuple since tuple fields can't have alignment.
            // this seems to work fine here, allowing for a.soa[0] syntax.  but i'm not sure if this
            // will lead to problems with different arrays and alignments.
            const is_tuple = switch (@typeInfo(T)) {
                .@"struct" => |s| s.is_tuple,
                else => false,
            };

            break :blk @Type(.{ .@"struct" = .{
                .fields = &res,
                .layout = .auto,
                .decls = &.{},
                .is_tuple = is_tuple,
            } });
        };

        pub fn Slices(StructOfArraysPtr: type) type {
            const soa_ptr = @typeInfo(StructOfArraysPtr).pointer;

            var res: [fields.len]std.builtin.Type.StructField = undefined;
            for (0..fields.len) |i| {
                const f = fields[i];
                res[i] = .{
                    .name = f.name,
                    .type = if (soa_ptr.is_const) []const f.type else []f.type,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = f.alignment,
                };
            }

            // can't inherit is_tuple since tuple fields can't have alignment
            return @Type(.{ .@"struct" = .{
                .fields = &res,
                .layout = .auto,
                .decls = &.{},
                .is_tuple = false,
            } });
        }

        const fields = meta.fields(T);
        const Field = meta.FieldEnum(T);
        fn FieldType(comptime field: Field) type {
            return meta.fieldInfo(StructOfArrays, field).type;
        }

        /// Init with a possibly runtime length.
        /// Returns error.Overflow if len exceeds buffer_capacity.
        pub fn init(len: usize) error{Overflow}!Self {
            if (len > buffer_capacity) return error.Overflow;
            return Self{ .len = len };
        }

        /// Return a struct where each field from T becomes a slice.
        /// If you need to access multiple fields, calling this may
        /// be more efficient than calling `items()` multiple times.
        pub fn slices(self: anytype) Slices(@TypeOf(&self.soa)) {
            var res: Slices(@TypeOf(&self.soa)) = undefined;
            inline for (fields) |f| {
                @field(res, f.name) = @field(self.soa, f.name)[0..self.len];
            }
            return res;
        }

        /// Get a slice of values for a specified field.
        /// If you need multiple fields, consider calling `slices()` instead.
        pub fn items(self: anytype, comptime field: Field) switch (@TypeOf(&@field(self.soa, @tagName(field)))) {
            *FieldType(field) => []meta.Elem(FieldType(field)),
            *const FieldType(field) => []const meta.Elem(FieldType(field)),
            else => @compileError("items() unexpected type: " ++ @typeName(@TypeOf(&@field(self.soa, @tagName(field)))) ++ ". expected " ++ @typeName(*[buffer_capacity]FieldType(field))),
        } {
            return @field(self.soa, @tagName(field))[0..self.len];
        }

        /// Get a const slice of values for a specified field.
        /// If you need multiple fields, consider calling `slices()` instead.
        pub fn constItems(self: *const Self, comptime field: Field) []const meta.Elem(FieldType(field)) {
            return self.items(field);
        }

        /// Set self.len to len.
        /// Return error.Overflow when len > buffer_capacity.
        pub fn resize(self: *Self, len: usize) error{Overflow}!void {
            if (len > buffer_capacity) return error.Overflow;
            self.len = len;
        }

        /// Set self.len = 0
        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        /// Copy contents of an existing slice.
        pub fn fromSlice(m: []const T) error{Overflow}!Self {
            var self = try init(m.len);
            inline for (fields) |f| {
                for (0..m.len) |i| {
                    @field(self.soa, f.name)[i] = @field(m[i], f.name);
                }
            }
            return self;
        }

        /// Copy contents of an existing struct of slices
        pub fn fromSoa(soa: Slices(*const StructOfArrays)) error{Overflow}!Self {
            var self: Self = .{};
            const src0 = @field(soa, fields[0].name);
            const len = src0.len;
            try self.resize(len);
            const dest0 = self.items(@enumFromInt(0))[0..len];
            @memcpy(dest0, src0);
            inline for (fields[1..], 1..) |f, fi| {
                const dest = self.items(@enumFromInt(fi))[0..len];
                const src = @field(soa, f.name);
                @memcpy(dest, src);
            }
            return self;
        }

        /// Construct and return the element at index `i`.
        pub fn get(self: Self, i: usize) T {
            assert(i < self.len);
            var t: T = undefined;
            inline for (fields) |f| {
                @field(t, f.name) = @field(self.soa, f.name)[i];
            }
            return t;
        }

        /// Set the value of the element at index `i`.
        pub fn set(self: *Self, i: usize, item: T) void {
            assert(i < self.len);
            inline for (fields) |f| {
                @field(self.soa, f.name)[i] = @field(item, f.name);
            }
        }

        /// Return the maximum length of a slice.
        pub fn capacity(_: Self) usize {
            return buffer_capacity;
        }

        /// Check that there is space for `additional_count` items.
        pub fn ensureUnusedCapacity(self: Self, additional_count: usize) error{Overflow}!void {
            if (self.len + additional_count > buffer_capacity) {
                return error.Overflow;
            }
        }

        /// Remove the last element return as a T.
        /// Asserts len > 0.
        pub fn pop(self: *Self) T {
            const new_len = self.len - 1;
            defer self.len = new_len;
            return self.get(new_len);
        }

        /// Remove and return the last element, or null if the slice is empty.
        pub fn popOrNull(self: *Self) ?T {
            return if (self.len == 0) null else self.pop();
        }

        /// Insert item at index `i` by moving slice[n .. slice.len] to make room.
        /// This operation is O(N*M) where M is the number of fields.
        pub fn insert(self: *Self, i: usize, item: T) error{Overflow}!void {
            if (i > self.len + 1) return error.Overflow;
            try self.resize(self.len + 1);
            inline for (fields, 0..) |f, fi| {
                const s = self.items(@enumFromInt(fi));
                mem.copyBackwards(f.type, s[i + 1 .. s.len], s[i .. s.len - 1]);
                s[i] = @field(item, f.name);
            }
        }

        /// For each field insert other.items(field) at index `i` and move slice[i .. slice.len] to make room.
        /// This operation is O(N*M) where M is the number of fields.
        /// `other` should be a MultiBoundedArray
        pub fn insertMulti(self: *Self, i: usize, other: anytype) error{Overflow}!void {
            try self.ensureUnusedCapacity(other.len);
            self.len += other.len;
            inline for (fields, 0..) |f, fi| {
                const field: Field = @enumFromInt(fi);
                const s = self.items(field);
                mem.copyBackwards(f.type, s[i + other.len .. self.len], self.constItems(field)[i .. self.len - other.len]);
                const src = other.items(field);
                @memcpy(self.items(field)[i..][0..other.len], src);
            }
        }

        // TODO
        // /// Replace range of elements slice[start..][0..len] with new_items.
        // /// Grows slice if len < new_items.len.
        // /// Shrinks slice if len > new_items.len.
        // pub fn replaceRange(
        //     self: *Self,
        //     start: usize,
        //     len: usize,
        //     new_items: []const T,
        // ) error{Overflow}!void {
        //     const after_range = start + len;
        //     var range = self.slice()[start..after_range];

        //     if (range.len == new_items.len) {
        //         @memcpy(range[0..new_items.len], new_items);
        //     } else if (range.len < new_items.len) {
        //         const first = new_items[0..range.len];
        //         const rest = new_items[range.len..];
        //         @memcpy(range[0..first.len], first);
        //         try self.insertSlice(after_range, rest);
        //     } else {
        //         @memcpy(range[0..new_items.len], new_items);
        //         const after_subrange = start + new_items.len;
        //         for (self.constItems()[after_range..], 0..) |item, i| {
        //             self.slice()[after_subrange..][i] = item;
        //         }
        //         self.len -= len - new_items.len;
        //     }
        // }

        /// Try to make room and then extend the slice by 1 element.
        pub fn append(self: *Self, item: T) error{Overflow}!void {
            const i = self.len;
            try self.resize(self.len + 1);
            inline for (fields) |f| {
                @field(self.soa, f.name)[i] = @field(item, f.name);
            }
        }

        /// Extend the slice by 1 element.  Asserts that there is space for it.
        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            assert(self.len < buffer_capacity);
            inline for (fields) |f| {
                @field(self.soa, f.name)[self.len] = @field(item, f.name);
            }
            self.len += 1;
        }

        /// Remove the element at index `i`, shift elements after `i` back, and
        /// return the removed element.
        /// Asserts the slice has at least one item.
        /// This operation is O(N*M) where M is the number of fields.
        pub fn orderedRemove(self: *Self, i: usize) T {
            const newlen = self.len - 1;
            if (newlen == i) return self.pop();
            const old_item = self.get(i);
            inline for (0..fields.len) |fi| {
                const field: Field = @enumFromInt(fi);
                for (self.items(field)[i..newlen], 0..) |*b, j| b.* = @field(self.get(i + 1 + j), @tagName(field));
            }
            self.set(newlen, undefined);
            self.len = newlen;
            return old_item;
        }

        /// Remove the element at index `i` and return it.
        /// The empty slot is replaced by the element the end of the slice.
        /// This operation is O(1).
        pub fn swapRemove(self: *Self, i: usize) T {
            if (self.len - 1 == i) return self.pop();
            const old_item = self.get(i);
            self.set(i, self.pop());
            return old_item;
        }

        /// Make room then append each slice of items from `other` to self.
        /// `other` may be a MultiBoundedArray of T and any buffer_capacity or a
        /// std.MultiArrayList(T).
        pub fn appendMulti(self: *Self, other: anytype) error{Overflow}!void {
            try self.ensureUnusedCapacity(other.len);
            self.appendMultiAssumeCapacity(other);
        }

        /// Append each slice from `other` to self.
        /// other may be a MultiBoundedArray of T and any buffer_capacity or a
        /// std.MultiArrayList(T).
        /// Asserts that there is room.
        pub fn appendMultiAssumeCapacity(self: *Self, other: anytype) void {
            assert(self.len + other.len <= buffer_capacity);
            const old_len = self.len;
            self.len += other.len;
            inline for (0..fields.len) |fi| {
                const field: Field = @enumFromInt(fi);
                const dest = self.items(field)[old_len..][0..other.len];
                const src = other.items(field);
                @memcpy(dest, src);
            }
        }

        /// Append contents of an existing struct of slices.
        /// Returns error.Overflow if there is not enough room.
        pub fn appendSoa(self: *Self, soa: Slices(*const StructOfArrays)) error{Overflow}!void {
            const src0 = @field(soa, fields[0].name);
            const len = src0.len;
            try self.resize(self.len + len);
            const dest0 = self.items(@enumFromInt(0))[0..len];
            @memcpy(dest0, src0);
            inline for (fields[1..], 1..) |f, fi| {
                const dest = self.items(@enumFromInt(fi))[0..len];
                const src = @field(soa, f.name);
                @memcpy(dest, src);
            }
        }

        /// Append `value` `n` times.
        pub fn appendNTimes(self: *Self, value: T, n: usize) error{Overflow}!void {
            const old_len = self.len;
            try self.resize(old_len + n);
            inline for (fields, 0..) |f, fi| {
                const dest = self.items(@enumFromInt(fi))[old_len..][0..n];
                @memset(dest, @field(value, f.name));
            }
        }

        /// Append `value` to the slice `n` times.  Asserts that there is room.
        pub fn appendNTimesAssumeCapacity(self: *Self, value: T, n: usize) void {
            const old_len = self.len;
            self.len += n;
            assert(self.len <= buffer_capacity);
            inline for (fields, 0..) |f, fi| {
                const dest = self.items(@enumFromInt(fi))[old_len..][0..n];
                @memset(dest, @field(value, f.name));
            }
        }
    };
}

test "basic" {
    const T = struct { int: u8, float: f32 };

    var a = MultiBoundedArray(T, 64){};
    try testing.expectEqual(0, a.len);
    try a.append(.{ .int = 1, .float = 1 });
    const mut_ints = a.items(.int);
    try testing.expectEqual([]u8, @TypeOf(mut_ints)); // items() slice constness is inherited
    try testing.expectEqual(1, mut_ints.len);
    try testing.expectEqual(1, mut_ints[0]);
    mut_ints[0] = 2;

    const a_const_copy = a;
    mut_ints[0] = 3;
    const const_ints = a_const_copy.items(.int);
    try testing.expectEqual([]const u8, @TypeOf(const_ints)); // items() slice constness is inherited
    try testing.expectEqual(2, const_ints[0]);
}

test MultiBoundedArray {
    const int_ones = [1]u8{1} ** 10;
    const float_ones = [1]f32{1} ** 10;
    const T = struct { int: u8, float: f32 };
    var ts: [20]T = undefined;
    inline for (0..ts.len) |i| {
        ts[i] = .{ .int = i, .float = i };
    }
    const ones = [1]T{.{ .int = 1, .float = 1.0 }} ** 10;

    const MBA = MultiBoundedArray(T, 64);
    var a: MBA = .{};

    try testing.expectEqual(64, a.capacity());
    try testing.expectEqual(0, a.items(.int).len);
    try testing.expectEqual(0, a.constItems(.float).len);
    const slices = a.slices();
    try testing.expectEqual(0, slices.int.len);
    try testing.expectEqual(0, slices.float.len);

    try a.resize(48);
    try testing.expectEqual(48, a.len);

    a = try MultiBoundedArray(T, 64).fromSlice(&ones);
    try testing.expectEqualSlices(u8, &int_ones, a.constItems(.int));
    try testing.expectEqualSlices(f32, &float_ones, a.constItems(.float));

    var a2 = a;
    try testing.expectEqualSlices(u8, a.constItems(.int), a2.constItems(.int));
    try testing.expectEqualSlices(f32, a.constItems(.float), a2.constItems(.float));
    a2.set(0, ts[0]);
    try testing.expect(a.get(0).int != a2.get(0).int);
    try testing.expect(a.get(0).float != a2.get(0).float);

    try testing.expectError(error.Overflow, a.resize(100));
    try testing.expectError(error.Overflow, MultiBoundedArray(T, ones.len - 1).fromSlice(&ones));
    try a.resize(64);
    try testing.expectError(error.Overflow, a.append(undefined));
    try testing.expectError(error.Overflow, a.ensureUnusedCapacity(1));
    try testing.expectError(error.Overflow, a.insert(0, undefined));

    try a.resize(0);
    try a.ensureUnusedCapacity(a.capacity());
    try a.append(ts[1]);
    try a.ensureUnusedCapacity(a.capacity() - 1);
    try testing.expectEqual(1, a.len);

    try a.append(ts[10]);
    try testing.expectEqual(2, a.len);
    try testing.expectEqual(ts[10], a.pop());

    a.appendAssumeCapacity(ts[10]);
    try testing.expectEqual(2, a.len);
    try testing.expectEqual(ts[10], a.pop());

    try a.resize(1);
    try testing.expectEqual(ts[1], a.popOrNull());
    try testing.expectEqual(null, a.popOrNull());

    try a.resize(10);
    try a.insert(5, ts[3]);
    try testing.expectEqual(11, a.len);
    try testing.expectEqual(ts[3], a.get(5));

    try a.insert(11, ts[4]);
    try testing.expectEqual(12, a.len);
    try testing.expectEqual(ts[4], a.pop());

    const soa = try MBA.fromSoa(.{ .int = &int_ones, .float = &float_ones });
    try a.appendMulti(soa);
    try testing.expectEqual(21, a.len);
    try a.appendSoa(.{ .int = &int_ones, .float = &float_ones });
    try testing.expectEqual(31, a.len);

    // appendMulti() with MultiArrayList
    try a.resize(11);
    var ma = std.MultiArrayList(T){};
    defer ma.deinit(testing.allocator);
    for (ts) |t| try ma.append(testing.allocator, t);
    try a.appendMulti(ma);
    try testing.expectEqual(31, a.len);

    // appendMulti() with MultiBoundedArray - same T different capacity
    try a.resize(11);
    const a_10 = try MultiBoundedArray(T, 10).fromSlice(&ones);
    try a.appendMulti(a_10);
    try testing.expectEqual(21, a.len);

    try a.appendNTimes(ts[6], 5);
    try testing.expectEqual(26, a.len);
    try testing.expectEqual(ts[6], a.pop());

    a.appendNTimesAssumeCapacity(ts[7], 5);
    try testing.expectEqual(30, a.len);
    try testing.expectEqual(ts[7], a.pop());

    try testing.expectEqual(29, a.len);
    try a.insertMulti(0, a_10);
    try testing.expectEqual(39, a.len);
    try testing.expectEqualSlices(
        u8,
        a.constItems(.int)[0..a_10.len],
        a_10.constItems(.int),
    );

    try a.resize(11);
    try a.insertMulti(11, a_10);
    try testing.expectEqual(21, a.len);

    try a.resize(11);
    try a.insertMulti(11, ma);
    try testing.expectEqual(31, a.len);

    try a.resize(11);
    try a.appendMulti(a_10);
    try testing.expectEqual(21, a.len);

    // try a.replaceRange(1, 5, &x);
    // try testing.expectEqual(a.len, 29 + x.len - 20 + x.len + x.len - 5);

    try a.resize(39);
    try testing.expectEqual(39, a.len);
    const ints = try testing.allocator.dupe(u8, a.constItems(.int));
    defer testing.allocator.free(ints);
    const floats = try testing.allocator.dupe(f32, a.constItems(.float));
    defer testing.allocator.free(floats);
    const removed = a.orderedRemove(5);
    try testing.expectEqual(removed, ts[1]);
    try testing.expectEqual(38, a.len);
    try testing.expectEqualSlices(u8, ints[0..5], a.constItems(.int)[0..5]);
    try testing.expectEqualSlices(u8, ints[6..], a.constItems(.int)[5..]);
    try testing.expectEqualSlices(f32, floats[0..5], a.constItems(.float)[0..5]);
    try testing.expectEqualSlices(f32, floats[6..], a.constItems(.float)[5..]);

    a.set(0, ts[0]);
    a.set(a.len - 1, ts[9]);
    const swapped = a.swapRemove(0);
    try testing.expectEqual(ts[0], swapped);
    try testing.expectEqual(ts[9], a.get(0));
}

test "with a tuple struct" {
    var a = try MultiBoundedArray(struct { u8, u16 }, 16).init(0);
    try a.append(.{ 0, 0 });
    try a.append(.{ 0, 0 });
    try a.append(.{ 255, 255 });
    try a.append(.{ 255, 255 });

    try testing.expectEqual(0, a.constItems(.@"0")[0]);
    try testing.expectEqual(0, a.soa[0][0]); // tuple indexing works here
    try testing.expectEqual(255, a.slices().@"0"[2]); // but not here
}

test "byte size" {
    const T = struct { u8, u16, u32, u64 };
    // compare the byte size of [64]T vs MultiBoundedArray(T) to show
    // that the MultiBoundedArray(T) struct has no padding and that [64]T
    // requries 6% more memory.
    const cap = 64;
    const MBA = MultiBoundedArray(T, cap);
    try testing.expectEqual(968, MBA.byte_size);
    try testing.expectEqual(
        MBA.byte_size,
        @sizeOf(usize) +
            cap * @sizeOf(u8) +
            cap * @sizeOf(u16) +
            cap * @sizeOf(u32) +
            cap * @sizeOf(u64),
    );
    try testing.expectEqual(1032, @sizeOf(usize) + @sizeOf([cap]T));
    try testing.expectApproxEqAbs(@as(f32, 1.06), 1032.0 / 968.0, 0.01);
}
