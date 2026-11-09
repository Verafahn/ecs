const std = @import("std");
const ecs = @import("ecs");

pub const Context = struct {
    dt: f32,
    tick: u64,
};

pub const Components = struct {
    pos: struct { x: f32, y: f32 },
    vel: struct { x: f32, y: f32 },
};

pub const MoveSystem = struct {
    pub const read = .{ .pos, .vel };
    pub const write = .{.pos};

    pub fn execute(self: *ecs.SparseSet(usize, Components), context: Context) void {
        var query = self.query(.{ .pos, .vel });
        while (query.next()) |item| {
            item.pos.x += item.vel.x * context.dt;
            item.pos.y += item.vel.y * context.dt;
        }
    }
};

pub const Render = struct {
    pub const read = .{.pos};
    pub const write = .{};

    pub fn execute(self: *ecs.SparseSet(usize, Components), ctx: Context) void {
        if (ctx.tick % 200 != 0) return;
        std.debug.print("--------tick: {d}--------\n", .{ctx.tick});
        var iter = self.iterator(.pos);
        while (iter.next()) |item| {
            std.debug.print("entity={d}, position=({:2},{:2})\n", .{
                item.entity,
                item.value_ptr.x,
                item.value_ptr.y,
            });
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var id: ecs.EntryGenerator(usize) = .{};
    var world: ecs.SparseSet(usize, Components) = .init(init.gpa);
    defer world.deinit();

    const a = id.next();
    try world.add(a, .pos, .{ .x = 0, .y = 0 });
    try world.add(a, .vel, .{ .x = 1, .y = 0 });
    const b = id.next();
    try world.add(b, .pos, .{ .x = 0, .y = 0 });
    try world.add(b, .vel, .{ .x = 0, .y = 1 });
    const c = id.next();
    try world.add(c, .pos, .{ .x = 0, .y = 0 });
    try world.add(c, .vel, .{ .x = 1, .y = 1 });
    const d = id.next();
    try world.add(d, .pos, .{ .x = 0, .y = 0 });

    const Graph = ecs.MakeSystem(&.{ MoveSystem, Render });

    var tick: u64 = 0;
    while (true) : (tick +%= 1) {
        const dt = 1;
        try io.sleep(.fromMilliseconds(dt), .awake);
        try world.execute(
            Graph,
            io,
            Context{ .dt = @as(f32, @floatFromInt(dt)) / 1000.0, .tick = tick },
        );
    }
}
