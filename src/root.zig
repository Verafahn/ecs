//! Shared building blocks for the ECS implementations.
//!
//! `Map`, `SparseSet`, and `Archetype` are interchangeable storage backends
//! with the same world API. Type validation, component introspection,
//! joint-query row generation, system scheduling, and execution live here; the
//! backend modules contain only storage logic.
const std = @import("std");

const meta = std.meta;

pub const Map = @import("map.zig").Map;
pub const SparseSet = @import("sparse_set.zig").SparseSet;
pub const Archetype = @import("archetype.zig").Archetype;

/// Validates the two types that parameterize an ECS world.
pub fn validateTypes(comptime Entry: type, comptime Components: type) void {
    validateEntityType(Entry);
    validateComponentsType(Components);
}

/// Entity indices are plain integers. Signed and unsigned types are accepted.
pub fn validateEntityType(comptime Entry: type) void {
    switch (@typeInfo(Entry)) {
        .int => {},
        else => @compileError(
            "ECS entity index type must be an integer, found '" ++ @typeName(Entry) ++ "'",
        ),
    }
}

/// The component set must be a non-tuple struct. Its fields are the component
/// types and their names become the `Component` enum used for every access.
pub fn validateComponentsType(comptime Components: type) void {
    switch (@typeInfo(Components)) {
        .@"struct" => |info| if (info.is_tuple) {
            @compileError(
                "ECS component set must be a non-tuple struct, found '" ++
                    @typeName(Components) ++ "'",
            );
        },
        else => @compileError(
            "ECS component set must be a struct, found '" ++ @typeName(Components) ++ "'",
        ),
    }
}

pub fn fieldType(
    comptime Components: type,
    comptime component: meta.FieldEnum(Components),
) type {
    return @typeInfo(Components).@"struct".field_types[@backingInt(component)];
}

/// A row yielded by a component iterator.
///
/// `value_ptr` points into the world's storage and may be invalidated by
/// structural changes (adding or removing components).
pub fn ComponentItem(comptime Entry: type, comptime T: type) type {
    return struct {
        entity: Entry,
        value_ptr: *T,
    };
}

/// Converts one joint-query element to the world's component enum.
pub fn queryComponent(
    comptime Components: type,
    comptime component: anytype,
) meta.FieldEnum(Components) {
    const name = switch (@typeInfo(@TypeOf(component))) {
        .enum_literal, .@"enum" => @tagName(component),
        else => @compileError("query components must be enum literals"),
    };

    return comptime blk: {
        const field_names = @typeInfo(Components).@"struct".field_names;
        for (field_names, 0..) |field_name, i| {
            if (std.mem.eql(u8, field_name, name)) {
                const id: meta.FieldEnum(Components) = @fromBackingInt(@intCast(i));
                break :blk id;
            }
        }
        @compileError("query references unknown component '." ++ name ++ "'");
    };
}

/// Validates the component tuple passed to a world's `query` method.
///
/// A query is a non-empty tuple of distinct component enum literals. A
/// component named `entity` is rejected because it would collide with the
/// generated `entity` field.
pub fn validateQuery(comptime Components: type, comptime queried: anytype) void {
    comptime {
        const info = @typeInfo(@TypeOf(queried));
        if (info != .@"struct" or !info.@"struct".is_tuple)
            @compileError("query components must be a tuple of component enum literals");
        if (info.@"struct".field_types.len == 0)
            @compileError("query must include at least one component");

        var seen: [info.@"struct".field_types.len][]const u8 = undefined;
        var seen_count: usize = 0;
        for (queried) |component| {
            const id = queryComponent(Components, component);
            const name = @tagName(id);
            if (std.mem.eql(u8, name, "entity"))
                @compileError("query component 'entity' conflicts with the item's entity field");
            for (seen[0..seen_count]) |seen_name| {
                if (std.mem.eql(u8, seen_name, name))
                    @compileError("query contains duplicate component '." ++ name ++ "'");
            }
            seen[seen_count] = name;
            seen_count += 1;
        }
    }
}

/// A row yielded by a joint query.
///
/// Contains the entity plus one pointer field per queried component, named
/// after the component. Pointers may be invalidated by structural changes.
pub fn QueryItem(
    comptime Entry: type,
    comptime Components: type,
    comptime queried: anytype,
) type {
    validateQuery(Components, queried);
    const count = @typeInfo(@TypeOf(queried)).@"struct".field_types.len;

    var names: [count + 1][]const u8 = undefined;
    var types: [count + 1]type = undefined;
    names[0] = "entity";
    types[0] = Entry;
    inline for (queried, 0..) |component, i| {
        const id = comptime queryComponent(Components, component);
        names[i + 1] = @tagName(id);
        types[i + 1] = *fieldType(Components, id);
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

/// Builds a struct with one storage field per component, named after the
/// component. `Storage` maps a component type to its container type.
pub fn StorageStruct(
    comptime Components: type,
    comptime Storage: fn (type) type,
) type {
    const info = @typeInfo(Components).@"struct";
    var storage_types: [info.field_types.len]type = undefined;
    inline for (info.field_types, 0..) |ComponentType, i| {
        storage_types[i] = Storage(ComponentType);
    }
    return @Struct(.auto, null, info.field_names, &storage_types, &@splat(.{}));
}

/// Optional entity index generator used by each world's `create`.
///
/// Any integer is a valid entity index, so the generator is a convenience.
/// `next` wraps on overflow; call `reset` to start over.
pub fn EntryGenerator(comptime Entry: type) type {
    validateEntityType(Entry);
    return struct {
        current: Entry = 0,

        pub fn next(self: *@This()) Entry {
            self.current +%= 1;
            return self.current;
        }

        pub fn peek(self: *const @This()) Entry {
            return self.current;
        }

        pub fn reset(self: *@This()) void {
            self.current = 0;
        }
    };
}

/// Sorts executors into a two-dimensional array of stages.
///
/// Every executor declares the components it reads and writes:
///
/// ```zig
/// const Move = struct {
///     pub const read = .{ .position, .velocity };
///     pub const write = .{ .position };
///
///     pub fn execute(world: anytype, context: anytype) void { ... }
/// };
///
/// const MoveSystem = MakeSystem(&.{ Move, ... });
/// try world.execute(MoveSystem, io, context);
/// ```
///
/// Scheduling rules:
///
/// - A system that writes a component runs before systems that read it.
/// - Systems that both write a component are ordered by their position in
///   `executors`, preserving declaration order for write-write conflicts.
/// - Systems in the same stage never write the same component or read a
///   component written by another system in that stage, so they may run
///   concurrently.
/// - If the read-after-write dependencies cannot be ordered, `MakeSystem`
///   raises a compile error listing the systems in the cycle.
///
/// The result is a type with a `stages` field (`[S][W]type`, padded with
/// `void`) and a `stage_lengths` field (`[S]usize`). Use `root.execute` or any
/// world's `execute` method to run it.
pub fn MakeSystem(comptime executors: []const type) type {
    @setEvalBranchQuota(100_000);

    inline for (executors) |Executor| {
        if (@typeInfo(Executor) != .@"struct")
            @compileError("not an ECS executor: " ++ @typeName(Executor));
        if (!@hasDecl(Executor, "read") or !@hasDecl(Executor, "write") or !@hasDecl(Executor, "execute"))
            @compileError("not an ECS executor: " ++ @typeName(Executor) ++ " (missing read, write or execute)");
    }

    const executor_count = executors.len;

    // Materialize the declared access tags as names. Scheduling only needs the
    // names, so MakeSystem does not have to know the component struct.
    var reads: [executor_count][]const []const u8 = undefined;
    var writes: [executor_count][]const []const u8 = undefined;
    inline for (executors, 0..) |Executor, i| {
        reads[i] = &AccessList(Executor.read).names;
        writes[i] = &AccessList(Executor.write).names;
    }

    const max_names = blk: {
        var total: usize = 0;
        inline for (executors) |Executor| {
            total += AccessList(Executor.read).names.len;
            total += AccessList(Executor.write).names.len;
        }
        break :blk total;
    };

    var component_names: [max_names][]const u8 = undefined;
    var component_name_count: usize = 0;
    for (0..executor_count) |i| {
        for (reads[i]) |name| {
            if (!containsName(component_names[0..component_name_count], name)) {
                component_names[component_name_count] = name;
                component_name_count += 1;
            }
        }
        for (writes[i]) |name| {
            if (!containsName(component_names[0..component_name_count], name)) {
                component_names[component_name_count] = name;
                component_name_count += 1;
            }
        }
    }

    // precedes[i][j] means executor i must run before executor j.
    var precedes: [executor_count][executor_count]bool = undefined;
    for (0..executor_count) |i| {
        for (0..executor_count) |j| precedes[i][j] = false;
    }
    for (0..executor_count) |i| {
        for (i + 1..executor_count) |j| {
            for (component_names[0..component_name_count]) |name| {
                const i_writes = containsName(writes[i], name);
                const j_writes = containsName(writes[j], name);
                const i_reads = containsName(reads[i], name);
                const j_reads = containsName(reads[j], name);

                if (i_writes and j_writes) {
                    // Write-write conflicts keep declaration order.
                    precedes[i][j] = true;
                } else if (i_writes and j_reads) {
                    precedes[i][j] = true;
                } else if (j_writes and i_reads) {
                    precedes[j][i] = true;
                }
            }
        }
    }

    // Levelize the dependency graph. A node is ready once every predecessor
    // has been assigned a stage; its stage is one past its last predecessor.
    var stage_of: [executor_count]usize = undefined;
    var done: [executor_count]bool = undefined;
    for (0..executor_count) |i| {
        stage_of[i] = 0;
        done[i] = false;
    }
    var done_count: usize = 0;
    var stage_count: usize = 0;
    while (done_count < executor_count) {
        var progressed = false;
        for (0..executor_count) |j| {
            if (done[j]) continue;

            var ready = true;
            for (0..executor_count) |i| {
                if (!done[i] and precedes[i][j]) {
                    ready = false;
                    break;
                }
            }
            if (!ready) continue;

            var stage: usize = 0;
            for (0..executor_count) |i| {
                if (done[i] and precedes[i][j]) stage = @max(stage, stage_of[i] + 1);
            }

            stage_of[j] = stage;
            done[j] = true;
            done_count += 1;
            stage_count = @max(stage_count, stage + 1);
            progressed = true;
        }

        if (!progressed) {
            var message: []const u8 = "ECS executor dependency cycle detected:";
            for (0..executor_count) |i| {
                if (!done[i]) message = message ++ "\n  " ++ @typeName(executors[i]);
            }
            @compileError(message);
        }
    }

    const stage_width = blk: {
        var widths: [stage_count]usize = undefined;
        for (0..stage_count) |s| widths[s] = 0;
        for (0..executor_count) |i| widths[stage_of[i]] += 1;

        var max: usize = 0;
        for (widths) |width| max = @max(max, width);
        break :blk max;
    };

    const slots = blk: {
        var result: [stage_count][stage_width]type = undefined;
        for (0..stage_count) |s| {
            for (0..stage_width) |i| result[s][i] = void;
        }

        var fill: [stage_count]usize = undefined;
        for (0..stage_count) |s| fill[s] = 0;
        for (0..executor_count) |i| {
            const stage = stage_of[i];
            result[stage][fill[stage]] = executors[i];
            fill[stage] += 1;
        }
        break :blk result;
    };

    const lengths = blk: {
        var result: [stage_count]usize = undefined;
        for (0..stage_count) |s| result[s] = 0;
        for (0..executor_count) |i| result[stage_of[i]] += 1;
        break :blk result;
    };

    return struct {
        pub const stages = slots;
        pub const stage_lengths = lengths;
    };
}

/// Runs the stages produced by `MakeSystem`.
///
/// Executors in one stage are spawned through `io.concurrent` and awaited
/// together; a stage with a single executor runs directly. The world must not
/// be structurally modified (component add/remove) while executors run. The
/// same `context` value is passed to every executor, so executors that run
/// concurrently must not mutate shared context state without synchronization.
pub fn execute(
    comptime World: type,
    world: *World,
    comptime System: type,
    io: std.Io,
    context: anytype,
) std.Io.ConcurrentError!void {
    comptime {
        @setEvalBranchQuota(100_000);
        if (!@hasDecl(World, "Component"))
            @compileError("type '" ++ @typeName(World) ++ "' is not an ECS world");
        if (!@hasDecl(System, "stages") or !@hasDecl(System, "stage_lengths"))
            @compileError("execute expects a system type returned by MakeSystem");

        for (0..System.stages.len) |s| {
            for (0..System.stage_lengths[s]) |i| {
                validateExecutor(World, System.stages[s][i]);
            }
        }
    }

    inline for (0..System.stages.len) |s| {
        const count = System.stage_lengths[s];
        if (count == 1) {
            System.stages[s][0].execute(world, context);
        } else if (count > 1) {
            var futures: [count]std.Io.Future(void) = undefined;
            var spawned: usize = 0;

            inline for (0..count) |i| {
                const Executor = System.stages[s][i];
                const Runner = struct {
                    world: *World,
                    context: @TypeOf(context),

                    fn call(self: @This()) void {
                        Executor.execute(self.world, self.context);
                    }
                };

                futures[i] = io.concurrent(Runner.call, .{Runner{
                    .world = world,
                    .context = context,
                }}) catch |err| {
                    for (futures[0..spawned]) |*future| _ = future.cancel(io);
                    return err;
                };
                spawned += 1;
            }

            for (&futures) |*future| _ = future.await(io);
        }
    }
}

/// Converts an executor's `read`/`write` tuple to a list of component names.
fn AccessList(comptime accesses: anytype) type {
    const info = @typeInfo(@TypeOf(accesses));
    if (info != .@"struct" or !info.@"struct".is_tuple)
        @compileError("executor 'read' and 'write' declarations must be tuples of component names");

    const len = info.@"struct".field_types.len;
    return struct {
        pub const names: [len][]const u8 = blk: {
            var result: [len][]const u8 = undefined;
            for (0..len) |i| {
                result[i] = switch (@typeInfo(info.@"struct".field_types[i])) {
                    .enum_literal, .@"enum" => @tagName(accesses[i]),
                    else => @compileError("executor component accesses must be enum literals"),
                };
            }
            break :blk result;
        };
    };
}

fn containsName(comptime names: []const []const u8, comptime name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn validateExecutor(comptime World: type, comptime Executor: type) void {
    if (@typeInfo(Executor) != .@"struct")
        @compileError("not an ECS executor: " ++ @typeName(Executor));
    if (!@hasDecl(Executor, "read") or !@hasDecl(Executor, "write") or !@hasDecl(Executor, "execute"))
        @compileError("not an ECS executor: " ++ @typeName(Executor));

    switch (@typeInfo(@TypeOf(Executor.execute))) {
        .@"fn" => |info| {
            const Return = info.return_type orelse
                @compileError("executor execute must have a concrete return type: " ++ @typeName(Executor));
            if (Return != void)
                @compileError("executor execute must return void, found '" ++ @typeName(Return) ++ "' in " ++ @typeName(Executor));
        },
        else => @compileError("executor execute is not a function: " ++ @typeName(Executor)),
    }

    validateAccessSet(World, Executor, "read", Executor.read);
    validateAccessSet(World, Executor, "write", Executor.write);
}

fn validateAccessSet(
    comptime World: type,
    comptime Executor: type,
    comptime label: []const u8,
    comptime accesses: anytype,
) void {
    const names = AccessList(accesses).names;
    for (names) |name| {
        if (std.meta.stringToEnum(World.Component, name) == null) {
            @compileError(
                "executor " ++ @typeName(Executor) ++ " declares unknown component '." ++
                    name ++ "' in its '" ++ label ++ "' set",
            );
        }
    }
}

test "entry generator wraps and can be reset" {
    const Generator = EntryGenerator(u8);

    var generator: Generator = .{};
    try std.testing.expectEqual(@as(u8, 1), generator.next());
    try std.testing.expectEqual(@as(u8, 2), generator.next());
    try std.testing.expectEqual(@as(u8, 2), generator.peek());

    generator.reset();
    try std.testing.expectEqual(@as(u8, 1), generator.next());
}

test "MakeSystem levelizes conflicting executors" {
    const ReadsPosition = struct {
        pub const read = .{.position};
        pub const write = .{};

        pub fn execute(_: anytype, _: anytype) void {}
    };
    const WritesPosition = struct {
        pub const read = .{};
        pub const write = .{.position};

        pub fn execute(_: anytype, _: anytype) void {}
    };
    const AlsoReadsPosition = struct {
        pub const read = .{.position};
        pub const write = .{};

        pub fn execute(_: anytype, _: anytype) void {}
    };

    const System = MakeSystem(&.{ ReadsPosition, WritesPosition, AlsoReadsPosition });

    try std.testing.expectEqual(@as(usize, 2), System.stages.len);
    try std.testing.expectEqual(@as(usize, 1), System.stage_lengths[0]);
    try std.testing.expectEqual(@as(usize, 2), System.stage_lengths[1]);
    try std.testing.expectEqualStrings(
        @typeName(WritesPosition),
        @typeName(System.stages[0][0]),
    );
    try std.testing.expectEqualStrings(
        @typeName(ReadsPosition),
        @typeName(System.stages[1][0]),
    );
    try std.testing.expectEqualStrings(
        @typeName(AlsoReadsPosition),
        @typeName(System.stages[1][1]),
    );
}

test "MakeSystem serializes write-write conflicts and readers afterward" {
    const First = struct {
        pub const read = .{};
        pub const write = .{.position};

        pub fn execute(_: anytype, _: anytype) void {}
    };
    const Second = struct {
        pub const read = .{};
        pub const write = .{.position};

        pub fn execute(_: anytype, _: anytype) void {}
    };
    const Reader = struct {
        pub const read = .{.position};
        pub const write = .{};

        pub fn execute(_: anytype, _: anytype) void {}
    };

    const System = MakeSystem(&.{ First, Second, Reader });

    try std.testing.expectEqual(@as(usize, 3), System.stages.len);
    try std.testing.expectEqual(@as(usize, 1), System.stage_lengths[0]);
    try std.testing.expectEqual(@as(usize, 1), System.stage_lengths[1]);
    try std.testing.expectEqual(@as(usize, 1), System.stage_lengths[2]);
    try std.testing.expectEqualStrings(@typeName(First), @typeName(System.stages[0][0]));
    try std.testing.expectEqualStrings(@typeName(Second), @typeName(System.stages[1][0]));
    try std.testing.expectEqualStrings(@typeName(Reader), @typeName(System.stages[2][0]));
}

const SharedPosition = struct {
    x: f32,
    y: f32,
};

const SharedVelocity = struct {
    x: f32,
    y: f32,
};

const SharedComponents = struct {
    position: SharedPosition,
    velocity: SharedVelocity,
    marker: struct {},
};

/// Exercises the common API without naming a concrete backend. If this stops
/// compiling for one implementation, that backend is no longer replaceable.
fn exerciseWorld(comptime World: type) !void {
    var world: World = .init(std.testing.allocator);
    defer world.deinit();

    const entity = world.create();
    try world.add(entity, .position, .{ .x = 1, .y = 2 });
    try world.add(entity, .velocity, .{ .x = 3, .y = 4 });
    try world.add(entity, .marker, .{});

    try std.testing.expect(world.has(entity, .position));
    try std.testing.expect(world.has(entity, .marker));
    try std.testing.expectEqual(@as(f32, 1), world.get(entity, .position).?.x);
    try std.testing.expectEqual(@as(usize, 1), world.count(.position));
    try std.testing.expectEqual(@as(usize, 1), world.count(.marker));

    world.getPtr(entity, .position).?.x = 5;
    try std.testing.expectEqual(@as(f32, 5), world.get(entity, .position).?.x);

    var iterator = world.iterator(.position);
    var seen: usize = 0;
    while (iterator.next()) |item| {
        seen += 1;
        item.value_ptr.y += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), seen);

    // Joint queries yield only entities that have every requested component.
    const Item = World.Query(.{ .position, .velocity }).Item;
    try std.testing.expect(@hasField(Item, "entity"));
    try std.testing.expect(@hasField(Item, "position"));
    try std.testing.expect(@hasField(Item, "velocity"));
    try std.testing.expect(@FieldType(Item, "position") == *SharedPosition);
    try std.testing.expect(@FieldType(Item, "velocity") == *SharedVelocity);

    const partial = world.create();
    try world.add(partial, .position, .{ .x = 100, .y = 100 });

    var query = world.query(.{ .position, .velocity });
    var query_seen: usize = 0;
    while (query.next()) |item| {
        query_seen += 1;
        item.position.x += item.velocity.x;
    }
    try std.testing.expectEqual(@as(usize, 1), query_seen);
    try std.testing.expectEqual(@as(f32, 8), world.get(entity, .position).?.x);

    var reversed = world.query(.{ .velocity, .position });
    var reversed_seen: usize = 0;
    while (reversed.next()) |item| {
        reversed_seen += 1;
        item.velocity.y += item.position.y;
    }
    try std.testing.expectEqual(@as(usize, 1), reversed_seen);
    try std.testing.expectEqual(@as(f32, 7), world.get(entity, .velocity).?.y);

    const removed = try world.remove(entity, .position);
    try std.testing.expectEqual(@as(f32, 3), removed.?.y);
    try std.testing.expect(!world.has(entity, .position));
    try std.testing.expect(world.has(entity, .velocity));

    _ = try world.remove(entity, .marker);
    try std.testing.expect(!world.has(entity, .marker));
}

test "all storage backends expose the same API" {
    const MapTest = Map(u32, SharedComponents);
    const SparseSetTest = SparseSet(u32, SharedComponents);
    const ArchetypeTest = Archetype(u32, SharedComponents);

    try exerciseWorld(MapTest);
    try exerciseWorld(SparseSetTest);
    try exerciseWorld(ArchetypeTest);

    const all_map_decls = @typeInfo(MapTest).@"struct".decl_names;
    const all_sparseset_decls = @typeInfo(SparseSetTest).@"struct".decl_names;
    const all_archetype_decls = @typeInfo(ArchetypeTest).@"struct".decl_names;

    inline for (all_map_decls) |name| {
        try std.testing.expect(@hasDecl(SparseSetTest, name));
        try std.testing.expect(@hasDecl(ArchetypeTest, name));
    }
    inline for (all_sparseset_decls) |name| {
        try std.testing.expect(@hasDecl(MapTest, name));
        try std.testing.expect(@hasDecl(ArchetypeTest, name));
    }
    inline for (all_archetype_decls) |name| {
        try std.testing.expect(@hasDecl(MapTest, name));
        try std.testing.expect(@hasDecl(SparseSetTest, name));
    }
}

test "empty component sets and empty schedules are valid" {
    const Empty = struct {};

    inline for (.{ Map(u8, Empty), SparseSet(u8, Empty), Archetype(u8, Empty) }) |World| {
        var world: World = .init(std.testing.allocator);
        world.deinit();
    }

    const EmptySystem = MakeSystem(&.{});
    try std.testing.expectEqual(@as(usize, 0), EmptySystem.stages.len);
}

test {
    std.testing.refAllDecls(@This());
}
