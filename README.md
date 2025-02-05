# About
Similar to std.MultiArrayList() but backed by fixed size arrays with a
shared runtime length.

Each field of T becomes an array with max length `buffer_capacity`.  To
access the arrays as slices use `items(field)` or `constItems(field)`.

Useful when a struct of small arrays is desired with capacity that is
known at compile time.  Like std.BoundedArray, MultiBoundedArrays are only
values and thus may be copied.


# Usage

```console
$ zig fetch --save=multi-bounded-array git+https://github.com/travisstaloch/multi-bounded-array#main"
```

```zig
// build.zig
const dep = b.dependency("multi-bounded-array", .{ .optimize = optimize, .target = target });
exe.root_module.addImport("multi-bounded-array", dep.module("multi-bounded-array"));
```

```zig
// main.zig
const MultiBoundedArray = @import("multi-bounded-array").MultiBoundedArray;
var a = MultiBoundedArray(struct { int: u8, float: f32 }, 64){};
// ...
```

# Example

From tests in [lib.zig](lib.zig) which also contains more tests.

```zig
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
```