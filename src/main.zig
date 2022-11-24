const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const PoolAllocator = struct {
    arena: std.heap.ArenaAllocator,
    child_allocator: Allocator,
    map: Map,
    lock: @TypeOf(lock_init),

    pub fn allocator(self: *@This()) Allocator {
        self.child_allocator = self.arena.allocator();
        self.map = Map.init(self.child_allocator);
        return Allocator.init(self, alloc, Allocator.NoResize(@This()).noResize, free);
    }

    pub fn init(child_allocator: Allocator) @This() {
        return .{
            .arena = std.heap.ArenaAllocator.init(child_allocator),
            .child_allocator = undefined,
            .map = undefined,
            .lock = lock_init,
        };
    }

    pub fn deinit(self: @This()) void {
        self.arena.deinit();
    }

    fn alloc(self: *@This(), n: usize, ptr_align: u29, len_align: u29, ra: usize) ![]u8 {
        _ = len_align;
        const key = alignkey(n, ptr_align);
        if (!self.map.contains(key)) {
            acquire(&self.lock);
            defer release(&self.lock);
            if (!self.map.contains(key)) {
                try self.map.put(key, Pool.init(self.child_allocator, &self.lock, n, ptr_align));
            }
        }
        var pool = self.map.get(key) orelse unreachable;
        return pool.new(ra);
    }

    fn free(self: *@This(), buf: []u8, buf_align: u29, ret_addr: usize) void {
        _ = ret_addr;
        const key = alignkey(buf.len, buf_align);
        var pool = self.map.get(key) orelse unreachable;
        pool.delete(buf);
    }
};

const usize_bits = @typeInfo(usize).Int.bits;
const U = @Type(.{
    .Int = .{
        .signedness = .unsigned,
        .bits = usize_bits + 29,
    },
});

const Map = std.AutoHashMap(U, Pool);

inline fn alignkey(n: usize, ptr_align: u29) U {
    return (@as(U, ptr_align) << usize_bits) | n;
}

const lock_init = if (builtin.single_threaded)
{} else false;

inline fn acquire(lock: *@TypeOf(lock_init)) void {
    if (!builtin.single_threaded) {
        while (@atomicRmw(bool, lock, .Xchg, true, .SeqCst)) {}
    }
}

inline fn release(lock: *@TypeOf(lock_init)) void {
    if (!builtin.single_threaded)
        assert(@atomicRmw(bool, lock, .Xchg, false, .SeqCst));
}

inline fn max(a: anytype, b: anytype) @TypeOf(a, b) {
    return if (a > b) a else b;
}

const Pool = struct {
    const List = std.atomic.Stack([]u8);

    free: List,
    lock: *@TypeOf(lock_init),
    ptr_align: u29,
    n: usize,
    ntotal: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator, lock: *@TypeOf(lock_init), n: usize, ptr_align: u29) @This() {
        var rtn = @This(){
            .free = List.init(),
            .lock = lock,
            .ptr_align = max(ptr_align, @alignOf(List.Node)),
            .n = n,
            .ntotal = undefined,
            .allocator = allocator,
        };
        rtn.ntotal = std.mem.alignForward(n, rtn.ptr_align) + @sizeOf(List.Node);
        return rtn;
    }

    pub inline fn new(self: *@This(), ra: usize) ![]u8 {
        const obj = if (self.free.pop()) |item|
            item
        else
            try self.alloc(ra);
        return obj.data;
    }

    pub inline fn delete(self: *@This(), buf: []u8) void {
        self.free.push(self.node_from_buf(buf));
    }

    inline fn node_from_buf(self: *@This(), buf: []u8) *List.Node {
        const buf_end_i = @ptrToInt(buf.ptr) + buf.len; // first byte after buf
        const node_ptr_i = std.mem.alignForward(buf_end_i, self.ptr_align);
        return @intToPtr(*List.Node, node_ptr_i);
    }

    fn alloc(self: *@This(), ra: usize) !*List.Node {
        acquire(self.lock);
        defer release(self.lock);
        var buf = try self.allocator.allocBytes(self.ptr_align, self.ntotal, 0, ra);
        var node = self.node_from_buf(buf);
        node.* = .{
            .next = null,
            .data = buf[0..self.n],
        };
        return node;
    }
};

test "doesn't crash" {
    var pool = PoolAllocator.init(std.testing.allocator);
    defer pool.deinit();
    const allocator = pool.allocator();

    const x = try allocator.alloc(u8, 12);
    const y = try allocator.alignedAlloc(u8, 4, 3);
    allocator.free(x);
    allocator.free(y);
    const z = try allocator.create(Pool);
    allocator.destroy(z);
}
