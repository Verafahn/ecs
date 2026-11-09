//! Archetype ECS storage.
//!
//! Entities with the same component signature share an archetype. Each
//! archetype stores an entity array plus one contiguous byte column per
//! component, so iterating a component walks packed memory and adding a
//! component moves the entity to the matching archetype.
const std = @import("std");

const root = @import("root.zig");
const Allocator = std.mem.Allocator;
const meta = std.meta;

/// Creates a world that groups entities into archetypes.
pub fn Archetype(comptime Entry: type, comptime Components: type) type {
    root.validateTypes(Entry, Components);

    const fields = @typeInfo(Components).@"struct";
    const component_count = fields.field_types.len;
    const Signature = std.StaticBitSet(component_count);

    return struct {
        const Self = @This();

        pub const Entity = Entry;
        pub const Component = meta.FieldEnum(Components);
        pub const EntityGenerator = root.EntryGenerator(Entry);

        pub fn Iterator(comptime component: Component) type {
            const T = ComponentType(component);
            return struct {
                world: *Self,
                archetype_index: usize = 0,
                row: usize = 0,

                pub const Item = root.ComponentItem(Entity, T);

                pub fn next(self: *@This()) ?Item {
                    const component_index = @backingInt(component);

                    while (self.archetype_index < self.world.archetypes.items.len) {
                        const archetype = &self.world.archetypes.items[self.archetype_index];
                        if (archetype.columnIndex(component_index)) |column_index| {
                            if (self.row < archetype.entities.items.len) {
                                const row = self.row;
                                self.row += 1;
                                return .{
                                    .entity = archetype.entities.items[row],
                                    .value_ptr = archetype.columns.items[column_index].ptr(T, row),
                                };
                            }
                        }

                        self.archetype_index += 1;
                        self.row = 0;
                    }

                    return null;
                }
            };
        }

        const max_alignment = blk: {
            var alignment: std.mem.Alignment = .@"1";
            for (fields.field_types) |T| alignment = alignment.max(.of(T));
            break :blk alignment;
        };

        const Location = struct {
            archetype: usize,
            row: usize,
        };

        allocator: Allocator,
        generator: EntityGenerator = .{},
        archetypes: std.ArrayList(ArchetypeData) = .empty,
        signatures: std.AutoHashMap(Signature, usize),
        locations: std.AutoHashMap(Entry, Location),

        pub fn ComponentType(comptime component: Component) type {
            return root.fieldType(Components, component);
        }

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .signatures = .init(allocator),
                .locations = .init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.archetypes.items) |*archetype| archetype.deinit(self.allocator);
            self.archetypes.deinit(self.allocator);
            self.signatures.deinit();
            self.locations.deinit();
        }

        pub fn create(self: *Self) Entity {
            return self.generator.next();
        }

        /// Inserts or overwrites `value` for `component`.
        ///
        /// If the entity does not have the component yet, it is moved to the
        /// archetype that contains the new signature. Other component values
        /// are copied along.
        pub fn add(
            self: *Self,
            entity: Entity,
            comptime component: Component,
            value: ComponentType(component),
        ) Allocator.Error!void {
            const component_index = @backingInt(component);

            if (self.locations.get(entity)) |location| {
                const archetype = &self.archetypes.items[location.archetype];
                if (archetype.signature.isSet(component_index)) {
                    archetype.columns.items[archetype.columnIndex(component_index).?]
                        .ptr(ComponentType(component), location.row).* = value;
                    return;
                }

                var signature = archetype.signature;
                signature.set(component_index);
                const target_index = try self.getOrCreateArchetype(signature);
                try self.moveEntity(entity, location, target_index, component, value);
                return;
            }

            var signature: Signature = .empty;
            signature.set(component_index);
            const target_index = try self.getOrCreateArchetype(signature);
            const target = &self.archetypes.items[target_index];

            try target.reserveRow(self.allocator);
            try self.locations.ensureUnusedCapacity(1);

            const row = target.entities.items.len;
            target.entities.appendAssumeCapacity(entity);
            inline for (fields.field_types, 0..) |T, i| {
                if (i == component_index) {
                    const column = &target.columns.items[target.columnIndex(i).?];
                    column.appendAssumeCapacity(T, value);
                }
            }
            self.locations.putAssumeCapacity(entity, .{ .archetype = target_index, .row = row });
        }

        /// Removes `component` from `entity` and returns its old value.
        ///
        /// If it was the last component, the entity is forgotten; otherwise it
        /// moves to the archetype without that component.
        pub fn remove(
            self: *Self,
            entity: Entity,
            comptime component: Component,
        ) Allocator.Error!?ComponentType(component) {
            const location = self.locations.get(entity) orelse return null;
            const component_index = @backingInt(component);
            const old_index = location.archetype;
            const old = &self.archetypes.items[old_index];
            const column_index = old.columnIndex(component_index) orelse return null;

            const T = ComponentType(component);
            const removed = old.columns.items[column_index].ptr(T, location.row).*;

            var new_signature = old.signature;
            new_signature.unset(component_index);

            if (new_signature.count() == 0) {
                self.removeRow(old_index, location.row);
                _ = self.locations.remove(entity);
                return removed;
            }

            const target_index = try self.getOrCreateArchetype(new_signature);
            const target = &self.archetypes.items[target_index];
            try target.reserveRow(self.allocator);

            // `getOrCreateArchetype` may have reallocated the archetype list.
            const source = &self.archetypes.items[old_index];
            const target_row = target.entities.items.len;
            target.entities.appendAssumeCapacity(entity);

            inline for (fields.field_types, 0..) |FieldType, i| {
                if (source.signature.isSet(i) and i != component_index) {
                    const source_column = &source.columns.items[source.columnIndex(i).?];
                    const target_column = &target.columns.items[target.columnIndex(i).?];
                    target_column.appendAssumeCapacity(
                        FieldType,
                        source_column.ptr(FieldType, location.row).*,
                    );
                }
            }

            self.locations.getPtr(entity).?.* = .{
                .archetype = target_index,
                .row = target_row,
            };
            self.removeRow(old_index, location.row);
            return removed;
        }

        pub fn get(
            self: *Self,
            entity: Entity,
            comptime component: Component,
        ) ?ComponentType(component) {
            const pointer = getPtr(self, entity, component) orelse return null;
            return pointer.*;
        }

        pub fn getPtr(
            self: *Self,
            entity: Entity,
            comptime component: Component,
        ) ?*ComponentType(component) {
            const location = self.locations.get(entity) orelse return null;
            const archetype = &self.archetypes.items[location.archetype];
            const column_index = archetype.columnIndex(@backingInt(component)) orelse return null;
            return archetype.columns.items[column_index].ptr(
                ComponentType(component),
                location.row,
            );
        }

        pub fn has(self: *Self, entity: Entity, comptime component: Component) bool {
            const location = self.locations.get(entity) orelse return false;
            return self.archetypes.items[location.archetype]
                .signature.isSet(@backingInt(component));
        }

        pub fn count(self: *Self, comptime component: Component) usize {
            const component_index = @backingInt(component);
            var total: usize = 0;
            for (self.archetypes.items) |*archetype| {
                if (archetype.signature.isSet(component_index))
                    total += archetype.entities.items.len;
            }
            return total;
        }

        /// Yields every entity with `component`. Adding or removing components
        /// may invalidate the iterator.
        pub fn iterator(self: *Self, comptime component: Component) Iterator(component) {
            return .{ .world = self };
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

        fn getOrCreateArchetype(self: *Self, signature: Signature) !usize {
            if (self.signatures.get(signature)) |index| return index;

            const index = self.archetypes.items.len;
            var archetype = try ArchetypeData.init(self.allocator, signature);
            errdefer archetype.deinit(self.allocator);

            try self.archetypes.append(self.allocator, archetype);
            errdefer _ = self.archetypes.pop();

            try self.signatures.put(signature, index);
            return index;
        }

        fn moveEntity(
            self: *Self,
            entity: Entity,
            location: Location,
            target_index: usize,
            comptime component: Component,
            value: ComponentType(component),
        ) !void {
            const target = &self.archetypes.items[target_index];
            try target.reserveRow(self.allocator);

            const source = &self.archetypes.items[location.archetype];
            const target_row = target.entities.items.len;
            target.entities.appendAssumeCapacity(entity);

            // Copy every component the entity already had.
            inline for (fields.field_types, 0..) |T, i| {
                if (source.signature.isSet(i)) {
                    const source_column = &source.columns.items[source.columnIndex(i).?];
                    const target_column = &target.columns.items[target.columnIndex(i).?];
                    target_column.appendAssumeCapacity(
                        T,
                        source_column.ptr(T, location.row).*,
                    );
                }
            }

            // Then append the component that triggered the move.
            const T = ComponentType(component);
            const target_column = &target.columns.items[target.columnIndex(@backingInt(component)).?];
            target_column.appendAssumeCapacity(T, value);

            self.locations.getPtr(entity).?.* = .{
                .archetype = target_index,
                .row = target_row,
            };
            self.removeRow(location.archetype, location.row);
        }

        /// Swap-removes `row` and fixes up the location of the entity that was
        /// moved into the hole.
        fn removeRow(self: *Self, archetype_index: usize, row: usize) void {
            const archetype = &self.archetypes.items[archetype_index];
            const last = archetype.entities.items.len - 1;

            for (archetype.columns.items) |*column| column.swapRemove(row);
            _ = archetype.entities.swapRemove(row);

            if (row != last) {
                const moved = archetype.entities.items[row];
                self.locations.getPtr(moved).?.* = .{
                    .archetype = archetype_index,
                    .row = row,
                };
            }
        }

        const ArchetypeData = struct {
            signature: Signature,
            entities: std.ArrayList(Entity) = .empty,
            columns: std.ArrayList(Column) = .empty,

            fn init(allocator: Allocator, signature: Signature) !ArchetypeData {
                var self: ArchetypeData = .{ .signature = signature };
                errdefer self.deinit(allocator);

                inline for (fields.field_types, 0..) |T, i| {
                    if (signature.isSet(i)) {
                        try self.columns.append(allocator, Column.init(allocator, T));
                    }
                }
                return self;
            }

            fn deinit(self: *ArchetypeData, allocator: Allocator) void {
                for (self.columns.items) |*column| column.deinit();
                self.columns.deinit(allocator);
                self.entities.deinit(allocator);
            }

            /// Returns the dense column index for a component, if present.
            fn columnIndex(self: *const ArchetypeData, component_index: usize) ?usize {
                if (!self.signature.isSet(component_index)) return null;

                var index: usize = 0;
                var i: usize = 0;
                while (i < component_index) : (i += 1) {
                    if (self.signature.isSet(i)) index += 1;
                }
                return index;
            }

            /// Reserves one row in the entity list and every column.
            fn reserveRow(self: *ArchetypeData, allocator: Allocator) !void {
                try self.entities.ensureTotalCapacity(allocator, self.entities.items.len + 1);
                for (self.columns.items) |*column| try column.reserveRow();
            }
        };

        const Column = struct {
            allocator: Allocator,
            bytes: std.ArrayListAligned(u8, max_alignment) = .empty,
            /// Bytes per row. Zero-sized component types still get one byte so
            /// every row has a distinct address.
            stride: usize,
            size: usize,

            fn init(allocator: Allocator, comptime T: type) Column {
                return .{
                    .allocator = allocator,
                    .stride = if (@sizeOf(T) == 0) @max(@alignOf(T), 1) else @sizeOf(T),
                    .size = @sizeOf(T),
                };
            }

            fn deinit(self: *Column) void {
                self.bytes.deinit(self.allocator);
            }

            fn reserveRow(self: *Column) !void {
                try self.bytes.ensureTotalCapacity(
                    self.allocator,
                    self.bytes.items.len + self.stride,
                );
            }

            fn appendAssumeCapacity(self: *Column, comptime T: type, value: T) void {
                if (@sizeOf(T) == 0) {
                    self.bytes.appendNTimesAssumeCapacity(undefined, self.stride);
                } else {
                    self.bytes.appendSliceAssumeCapacity(std.mem.asBytes(&value));
                }
            }

            fn ptr(self: *Column, comptime T: type, row: usize) *T {
                const offset = row * self.stride;
                std.debug.assert(offset + self.size <= self.bytes.items.len);
                return @ptrCast(@alignCast(&self.bytes.items[offset]));
            }

            fn swapRemove(self: *Column, row: usize) void {
                const last = self.bytes.items.len / self.stride - 1;
                if (row != last) {
                    @memcpy(
                        self.bytes.items[row * self.stride ..][0..self.stride],
                        self.bytes.items[last * self.stride ..][0..self.stride],
                    );
                }
                self.bytes.shrinkRetainingCapacity(self.bytes.items.len - self.stride);
            }
        };
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
const TestWorld = Archetype(TestEntity, TestComponents);

const Marker = struct {};
const MarkerComponents = struct {
    position: Position,
    marker: Marker,
};
const MarkerWorld = Archetype(u32, MarkerComponents);

test "archetype supports zero-sized marker components" {
    var world: MarkerWorld = .init(std.testing.allocator);
    defer world.deinit();

    const entity = world.create();
    try world.add(entity, .marker, .{});
    try std.testing.expect(world.has(entity, .marker));
    try std.testing.expectEqual(@as(usize, 1), world.count(.marker));

    try world.add(entity, .position, .{ .x = 4, .y = 5 });
    try std.testing.expect(world.getPtr(entity, .marker) != null);
    try std.testing.expectEqual(@as(f32, 4), world.get(entity, .position).?.x);

    _ = try world.remove(entity, .marker);
    try std.testing.expect(!world.has(entity, .marker));
    try std.testing.expectEqual(@as(f32, 4), world.get(entity, .position).?.x);
}

test "archetype moves entities between signatures" {
    var world: TestWorld = .init(std.testing.allocator);
    defer world.deinit();

    const entity = world.create();
    try world.add(entity, .position, .{ .x = 1, .y = 2 });
    try std.testing.expectEqual(@as(f32, 1), world.get(entity, .position).?.x);

    // Adding a component moves the entity but preserves its existing values.
    try world.add(entity, .velocity, .{ .x = 3, .y = 4 });
    try std.testing.expectEqual(@as(f32, 1), world.get(entity, .position).?.x);
    try std.testing.expectEqual(@as(f32, 4), world.get(entity, .velocity).?.y);

    world.getPtr(entity, .position).?.x = 10;
    try std.testing.expectEqual(@as(f32, 10), world.get(entity, .position).?.x);

    try world.add(entity, .position, .{ .x = 20, .y = 2 });
    try std.testing.expectEqual(@as(f32, 20), world.get(entity, .position).?.x);

    // Removing a component also moves the entity and preserves the rest.
    const removed = try world.remove(entity, .position);
    try std.testing.expectEqual(@as(f32, 20), removed.?.x);
    try std.testing.expect(!world.has(entity, .position));
    try std.testing.expectEqual(@as(f32, 4), world.get(entity, .velocity).?.y);

    // Removing the last component forgets the entity.
    _ = try world.remove(entity, .velocity);
    try std.testing.expect(!world.has(entity, .velocity));
    try std.testing.expectEqual(@as(usize, 0), world.count(.velocity));
}

test "archetype swap-remove keeps other entities addressable" {
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

test "archetype iterator walks every matching archetype" {
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

test "archetype executes systems in conflict order" {
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
