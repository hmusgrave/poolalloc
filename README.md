# poolalloc

arena allocator with object re-use

## Purpose

This allocator is ideally suited for creating/destroying the same sort of object over and over, as you might see in any sort of branching computation (sudoku solver, task scheduler, ...). You would tend to want to use this over other allocators when some combination of the following apply:

1. The total allocation count is much greater than the typical moment-in-time allocation count.

1. The total allocation count is much greater than the count of distinct object types being allocated (uniqued on length/alignment).

1. You don't need finer-grained control than re-using same-sized objects and destroying the underlying memory when you're done.

1. Thread-safety is important.

1. Allocation sizes tend to be more than just a few bytes (overhead for small pool-tracked objects is 24 bytes on 64-bit systems, and that might negate the benefits of object re-use if you only re-use each object a few times).

## Installation

Choose your favorite method for vendoring this code into your repository. I'm using [zigmod](https://github.com/nektro/zigmod) to vendor this into [byol](https://github.com/hmusgrave/byol), and it's pretty painless. I also generally like [git-subrepo](https://github.com/ingydotnet/git-subrepo), copy-paste is always a winner, and whenever the official package manager is up we'll be there too.


## Examples

```zig
test "PoolAllocator" {
    // You can init the pool with any allocator, but if you plan
    // to use that same allocator concurrently with pool allocations,
    // you should take care to use something thread-safe as the
    // backing memory, like the builtin GeneralPurposeAllocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var pool = PoolAllocator.init(gpa.allocator());
    defer pool.deinit();
    const allocator = pool.allocator();
        
    // 8-byte aligned slice
    const x = try allocator.alignedAlloc(u8, 8, 1234);

    // add that memory back to the pool
    allocator.free(x);

    // y requires 16-byte alignment, so we don't currently have any
    // objects in the pool of the right size/alignment to hand out.
    // This will create a new slice to give out.
    const y = try allocator.alignedAlloc(u8, 16, 1234);
    defer allocator.free(y);

    // This is the same size/alignment as the first slice
    // we allocated, so we quickly/cheaply hand that back
    // from the pool and don't touch the underlying allocator
    const z = try allocator.alignedAlloc(u8, 8, 1234);
    defer allocator.free(z);
}
```

## Status
Contributions welcome. I'll check back on this repo at least once per month. Currently targets Zig 0.10.

This works and does everything I need it to. It might be nice to have a better strategy for handling contention if you were only going to re-use each object a few times in a highly concurrent environment (all new allocations contend over a per-pool lock, so when not re-using objects many times you would expect highly concurrent (somewhere north of 1k-100k CPU cores) use to spend most of the time contending over those new allocations rather than reaping the benefits of object re-use).

## Credit
Inspired by [Felix](https://zig.news/xq/cool-zig-patterns-gotta-alloc-fast-23h), and modified to support multiple object types, handle dynamic alignment, and be thread-safe.
