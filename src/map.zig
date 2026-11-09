/// Hash-map ECS storage.
///
/// Every component gets one `AutoHashMap(Entity, T)`. This is the simplest
/// backend: sparse component sets cost only the entities that have the
/// component, but a component lookup is a hash lookup and iterating a component
/// jumps across hash buckets.
const std = @import("std");

const root = @import("root.zig");
const Allocator = std.mem.Allocator;
const meta = std.meta;

/// Creates a world that stores each component in its own hash map.
pub fn Map(comptime Entry: type, comptime Components: type) type {
    root.validateTypes(Entry, Components);

    return struct {
        const Self = @This();

        pub const Entity = Entry;
        pub const Component = meta.FieldEnum(Components);
        pub const EntityGenerator = root.EntryGenerator(Entry);

        /// The iterator returned by `iterator`.
        pub fn Iterator(comptime component: Component) type {
            const T = ComponentType(component);
            return struct {
                inner: std.AutoHashMap(Entry, T).Iterator,

                pub const Item = root.ComponentItem(Entry, T);

                pub fn next(self: *@This()) ?Item {
                    const entry = self.inner.next() orelse return null;
                    return .{
                        .entity = entry.key_ptr.*,
                        .value_ptr = entry.value_ptr,
                    };
                }
            };
        }

        generator: EntityGenerator = .{},
        data: Data,

        const Data = root.StorageStruct(Components, Storage);

        fn Storage(comptime T: type) type {
            return std.AutoHashMap(Entry, T);
        }

        pub fn ComponentType(comptime component: Component) type {
            return root.fieldType(Components, component);
        }

        pub fn init(allocator: Allocator) Self {
            var data: Data = undefined;
            inline for (@typeInfo(Data).@"struct".field_names) |name| {
                @field(data, name) = .init(allocator);
            }
            return .{ .data = data };
        }

        pub fn deinit(self: *Self) void {
            inline for (@typeInfo(Data).@"struct".field_names) |name| {
                @field(self.data, name).deinit();
            }
        }

        /// Returns a fresh entity index from the embedded generator.
        pub fn create(self: *Self) Entity {
            return self.generator.next();
        }

        /// Inserts or overwrites `value` for `component`.
        pub fn add(
            self: *Self,
            entity: Entity,
            comptime component: Component,
            value: ComponentType(component),
        ) Allocator.Error!void {
            const map = &@field(self.data, @tagName(component));
            try map.put(entity, value);
        }

        /// Removes `component` from `entity` and returns its old value.
        pub fn remove(
            self: *Self,
            entity: Entity,
            comptime component: Component,
        ) Allocator.Error!?ComponentType(component) {
            const map = &@field(self.data, @tagName(component));
            const entry = map.fetchRemove(entity) orelse return null;
            return entry.value;
        }

        pub fn get(
            self: *Self,
            entity: Entity,
            comptime component: Component,
        ) ?ComponentType(component) {
            return @field(self.data, @tagName(component)).get(entity);
        }

        pub fn getPtr(
            self: *Self,
            entity: Entity,
            comptime component: Component,
        ) ?*ComponentType(component) {
            return @field(self.data, @tagName(component)).getPtr(entity);
        }

        pub fn has(self: *Self, entity: Entity, comptime component: Component) bool {
            return @field(self.data, @tagName(component)).contains(entity);
        }

        /// Number of entities that currently have `component`.
        pub fn count(self: *Self, comptime component: Component) usize {
            return @field(self.data, @tagName(component)).count();
        }

        /// Iterates over entities that currently have `component`.
        ///
        /// Adding or removing components invalidates the iterator.
        pub fn iterator(self: *Self, comptime component: Component) Iterator(component) {
            const map = &@field(self.data, @tagName(component));
            return .{ .inner = map.iterator() };
        }

        /// Runs a schedule produced by `root.MakeSystem`.
        pub fn execute(
            self: *Self,
            comptime System: type,
            io: std.Io,
            context: anytype,
        ) std.Io.ConcurrentError!void {
            try root.execute(Self, self, System, io, context);
        }
    };
}

const Position = struct {
    x: f32,
    y: f32,
};

const Velocity = struct {
    x: f32,
    y: f32,
};

const Health = struct {
    value: i32,
};

const TestComponents = struct {
    position: Position,
    velocity: Velocity,
    health: Health,
};

const TestEntity = u32;
const TestWorld = Map(TestEntity, TestComponents);

test "map stores, overwrites, and removes components" {
    var world: TestWorld = .init(std.testing.allocator);
    defer world.deinit();

    const entity = world.create();
    try std.testing.expectEqual(@as(TestEntity, 1), entity);

    try world.add(entity, .position, .{ .x = 1, .y = 2 });
    try world.add(entity, .velocity, .{ .x = 3, .y = 4 });

    try std.testing.expect(world.has(entity, .position));
    try std.testing.expectEqual(@as(f32, 1), world.get(entity, .position).?.x);
    try std.testing.expectEqual(@as(f32, 4), world.get(entity, .velocity).?.y);

    world.getPtr(entity, .position).?.x = 10;
    try std.testing.expectEqual(@as(f32, 10), world.get(entity, .position).?.x);

    try world.add(entity, .position, .{ .x = 20, .y = 2 });
    try std.testing.expectEqual(@as(f32, 20), world.get(entity, .position).?.x);

    try std.testing.expectEqual(@as(usize, 1), world.count(.position));
    try std.testing.expectEqual(@as(usize, 1), world.count(.velocity));
    try std.testing.expectEqual(@as(usize, 0), world.count(.health));

    const removed = try world.remove(entity, .position);
    try std.testing.expectEqual(@as(f32, 20), removed.?.x);
    try std.testing.expect(!world.has(entity, .position));
    try std.testing.expectEqual(@as(?Position, null), try world.remove(entity, .position));
}

test "map iterator visits every entity with a component" {
    var world: TestWorld = .init(std.testing.allocator);
    defer world.deinit();

    const first = world.create();
    try world.add(first, .position, .{ .x = 1, .y = 1 });
    const second = world.create();
    try world.add(second, .position, .{ .x = 2, .y = 2 });
    try world.add(second, .health, .{ .value = 5 });

    var seen: u32 = 0;
    var iterator = world.iterator(.position);
    while (iterator.next()) |item| {
        seen += 1;
        item.value_ptr.x += 1;
    }

    try std.testing.expectEqual(@as(u32, 2), seen);
    try std.testing.expectEqual(@as(f32, 2), world.get(first, .position).?.x);
    try std.testing.expectEqual(@as(f32, 3), world.get(second, .position).?.x);
}

test "map executes systems in conflict order" {
    const Double = struct {
        pub const read = .{.position};
        pub const write = .{.position};

        pub fn execute(world: *TestWorld, _: anytype) void {
            var iterator = world.iterator(.position);
            while (iterator.next()) |item| item.value_ptr.x *= 2;
        }
    };
    const AddOne = struct {
        pub const read = .{.position};
        pub const write = .{.position};

        pub fn execute(world: *TestWorld, context: anytype) void {
            var iterator = world.iterator(.position);
            while (iterator.next()) |item| item.value_ptr.x += context.amount;
        }
    };

    const System = root.MakeSystem(&.{ Double, AddOne });

    var world: TestWorld = .init(std.testing.allocator);
    defer world.deinit();

    const entity = world.create();
    try world.add(entity, .position, .{ .x = 3, .y = 0 });

    try world.execute(System, std.testing.io, .{ .amount = 1 });

    // Double is declared first, so it wins the write-write conflict.
    try std.testing.expectEqual(@as(f32, 7), world.get(entity, .position).?.x);
}

test "map runs independent systems in one stage" {
    const CopyX = struct {
        pub const read = .{.position};
        pub const write = .{.velocity};

        pub fn execute(world: *TestWorld, _: anytype) void {
            var iterator = world.iterator(.position);
            while (iterator.next()) |item| {
                world.getPtr(item.entity, .velocity).?.x = item.value_ptr.x;
            }
        }
    };
    const CopyY = struct {
        pub const read = .{.position};
        pub const write = .{.health};

        pub fn execute(world: *TestWorld, _: anytype) void {
            var iterator = world.iterator(.position);
            while (iterator.next()) |item| {
                world.getPtr(item.entity, .health).?.value = @intFromFloat(item.value_ptr.y);
            }
        }
    };

    const System = root.MakeSystem(&.{ CopyX, CopyY });

    var world: TestWorld = .init(std.testing.allocator);
    defer world.deinit();

    const entity = world.create();
    try world.add(entity, .position, .{ .x = 2, .y = 3 });
    try world.add(entity, .velocity, .{ .x = 0, .y = 0 });
    try world.add(entity, .health, .{ .value = 0 });

    try world.execute(System, std.testing.io, .{});

    try std.testing.expectEqual(@as(f32, 2), world.get(entity, .velocity).?.x);
    try std.testing.expectEqual(@as(i32, 3), world.get(entity, .health).?.value);
}
