/// Sparse-set ECS storage.
///
/// Each component owns a sparse map from entity to a dense row, plus two dense
/// arrays: the entities and their component values. Lookups are one hash map
/// lookup followed by an array index, iteration is contiguous, and removing a
/// component is a swap-remove.
const std = @import("std");

const root = @import("root.zig");
const Allocator = std.mem.Allocator;
const meta = std.meta;

/// Creates a world that stores each component in a sparse set.
pub fn SparseSet(comptime Entry: type, comptime Components: type) type {
    root.validateTypes(Entry, Components);

    return struct {
        const Self = @This();

        pub const Entity = Entry;
        pub const Component = meta.FieldEnum(Components);
        pub const EntityGenerator = root.EntryGenerator(Entry);

        pub fn Iterator(comptime component: Component) type {
            const T = ComponentType(component);
            return struct {
                entities: []const Entity,
                values: []T,
                index: usize = 0,

                pub const Item = root.ComponentItem(Entity, T);

                pub fn next(self: *@This()) ?Item {
                    if (self.index >= self.entities.len) return null;

                    const index = self.index;
                    self.index += 1;
                    return .{
                        .entity = self.entities[index],
                        .value_ptr = &self.values[index],
                    };
                }
            };
        }

        allocator: Allocator,
        generator: EntityGenerator = .{},
        data: Data,

        const Data = root.StorageStruct(Components, Storage);

        fn Storage(comptime T: type) type {
            return ComponentStorage(Entry, T);
        }

        pub fn ComponentType(comptime component: Component) type {
            return root.fieldType(Components, component);
        }

        pub fn init(allocator: Allocator) Self {
            var data: Data = undefined;
            inline for (@typeInfo(Data).@"struct".field_names) |name| {
                @field(data, name) = .init(allocator);
            }
            return .{ .allocator = allocator, .data = data };
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
            const storage = &@field(self.data, @tagName(component));
            try storage.add(entity, value);
        }

        /// Removes `component` from `entity` and returns its old value.
        pub fn remove(
            self: *Self,
            entity: Entity,
            comptime component: Component,
        ) Allocator.Error!?ComponentType(component) {
            const storage = &@field(self.data, @tagName(component));
            return storage.remove(entity);
        }

        pub fn get(
            self: *Self,
            entity: Entity,
            comptime component: Component,
        ) ?ComponentType(component) {
            const storage = &@field(self.data, @tagName(component));
            return storage.get(entity);
        }

        pub fn getPtr(
            self: *Self,
            entity: Entity,
            comptime component: Component,
        ) ?*ComponentType(component) {
            const storage = &@field(self.data, @tagName(component));
            return storage.getPtr(entity);
        }

        pub fn has(self: *Self, entity: Entity, comptime component: Component) bool {
            const storage = &@field(self.data, @tagName(component));
            return storage.has(entity);
        }

        /// Number of entities that currently have `component`.
        pub fn count(self: *Self, comptime component: Component) usize {
            const storage = &@field(self.data, @tagName(component));
            return storage.dense_entities.items.len;
        }

        /// Iterates over entities that currently have `component`.
        ///
        /// Adding or removing components invalidates the iterator.
        pub fn iterator(self: *Self, comptime component: Component) Iterator(component) {
            const storage = &@field(self.data, @tagName(component));
            return .{
                .entities = storage.dense_entities.items,
                .values = storage.dense_values.items,
            };
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

fn ComponentStorage(comptime Entry: type, comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        sparse: std.AutoHashMap(Entry, usize),
        dense_entities: std.ArrayList(Entry) = .empty,
        dense_values: std.ArrayList(T) = .empty,

        fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .sparse = .init(allocator),
            };
        }

        fn deinit(self: *Self) void {
            self.sparse.deinit();
            self.dense_entities.deinit(self.allocator);
            self.dense_values.deinit(self.allocator);
        }

        fn add(self: *Self, entity: Entry, value: T) !void {
            if (self.sparse.get(entity)) |index| {
                self.dense_values.items[index] = value;
                return;
            }

            const index = self.dense_entities.items.len;
            try self.dense_entities.append(self.allocator, entity);
            errdefer _ = self.dense_entities.pop();

            try self.dense_values.append(self.allocator, value);
            errdefer _ = self.dense_values.pop();

            try self.sparse.put(entity, index);
        }

        fn remove(self: *Self, entity: Entry) ?T {
            const entry = self.sparse.fetchRemove(entity) orelse return null;
            const index = entry.value;

            const removed = self.dense_values.swapRemove(index);
            _ = self.dense_entities.swapRemove(index);

            if (index < self.dense_entities.items.len) {
                const moved = self.dense_entities.items[index];
                self.sparse.getPtr(moved).?.* = index;
            }

            return removed;
        }

        fn get(self: *Self, entity: Entry) ?T {
            const index = self.sparse.get(entity) orelse return null;
            return self.dense_values.items[index];
        }

        fn getPtr(self: *Self, entity: Entry) ?*T {
            const index = self.sparse.get(entity) orelse return null;
            return &self.dense_values.items[index];
        }

        fn has(self: *Self, entity: Entry) bool {
            return self.sparse.contains(entity);
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
const TestWorld = SparseSet(TestEntity, TestComponents);

test "sparse set stores, overwrites, and removes components" {
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
    try std.testing.expectEqual(@as(usize, 0), world.count(.health));

    const removed = try world.remove(entity, .position);
    try std.testing.expectEqual(@as(f32, 20), removed.?.x);
    try std.testing.expect(!world.has(entity, .position));
    try std.testing.expectEqual(@as(?Position, null), try world.remove(entity, .position));
}

test "sparse set swap-remove keeps other entities addressable" {
    var world: TestWorld = .init(std.testing.allocator);
    defer world.deinit();

    const a = world.create();
    const b = world.create();
    const c = world.create();
    try world.add(a, .position, .{ .x = 1, .y = 1 });
    try world.add(b, .position, .{ .x = 2, .y = 2 });
    try world.add(c, .position, .{ .x = 3, .y = 3 });

    _ = try world.remove(a, .position);

    try std.testing.expectEqual(@as(f32, 2), world.get(b, .position).?.x);
    try std.testing.expectEqual(@as(f32, 3), world.get(c, .position).?.x);
    try std.testing.expectEqual(@as(usize, 2), world.count(.position));
}

test "sparse set iterator visits every entity with a component" {
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

test "sparse set executes systems in conflict order" {
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
    try std.testing.expectEqual(@as(f32, 7), world.get(entity, .position).?.x);
}
