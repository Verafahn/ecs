# ecs

A small, backend-agnostic entity-component-system (ECS) library for Zig.

`ecs` separates storage from scheduling. Three interchangeable backends
(`Map`, `SparseSet`, `Archetype`) expose the same world API. Systems declare
component reads and writes at compile time; `MakeSystem` turns those
declarations into a staged schedule, and stages without conflicts run
concurrently through `std.Io`.

## Features

- One API, three storage backends: `Map`, `SparseSet`, `Archetype`.
- Component sets are plain structs; field names become a compile-time enum.
- Compile-time scheduling with automatic staging and cycle detection.
- Concurrent stage execution through `std.Io`.
- Only depends on the Zig standard library.

## Requirements

- Zig 0.17.0 or newer.
- Scheduling and execution use `std.Io`; examples use `std.process.Init`.

## Installation

Use the repository as a path dependency:

```zon
.dependencies = .{
    .ecs = .{ .path = "../ecs" },
},
```

Expose the module in `build.zig`:

```zig
const ecs = b.dependency("ecs", .{});
exe.root_module.addImport("ecs", ecs.module("ecs"));
```

The module name is `ecs`, matching `@import("ecs")` in the examples.

## Quick start

```zig
const std = @import("std");
const ecs = @import("ecs");

const Components = struct {
    position: struct { x: f32, y: f32 },
    velocity: struct { x: f32, y: f32 },
};

const World = ecs.SparseSet(u32, Components);

const Move = struct {
    pub const read = .{ .position, .velocity };
    pub const write = .{.position};

    pub fn execute(world: *World, dt: f32) void {
        var it = world.iterator(.velocity);
        while (it.next()) |item| {
            const velocity = item.value_ptr.*;
            if (world.getPtr(item.entity, .position)) |position| {
                position.x += velocity.x * dt;
                position.y += velocity.y * dt;
            }
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var world: World = .init(init.gpa);
    defer world.deinit();

    const player = world.create();
    try world.add(player, .position, .{ .x = 0, .y = 0 });
    try world.add(player, .velocity, .{ .x = 60, .y = 0 });

    const Frame = ecs.MakeSystem(&.{Move});
    try world.execute(Frame, init.io, 1.0 / 60.0);

    std.debug.print("x = {d}\n", .{world.get(player, .position).?.x});
}
```

Changing `SparseSet` to `Map` or `Archetype` switches storage backends; the
rest of the code does not change.

## Core concepts

### Entities

An entity is an integer index. `create()` returns the next generated value
(starting at `1`), but any integer value may be used directly. There is no
separate entity list: an entity exists as long as it has at least one component.
Under the `Archetype` backend, removing an entity's last component forgets it.

Entity indices are not versioned. Reusing an index after removing all of its
components is allowed, but stale handles cannot be detected.

### Components

The component set is a non-tuple struct. Its field names become the `Component`
enum, and its field types are the component types:

```zig
const Components = struct {
    position: struct { x: f32, y: f32 },
    health: u32,
    frozen: struct {}, // zero-sized marker component
};
```

Worlds expose `World.Component` and `World.ComponentType(.position)`.
Components may be zero-sized.

### World API

All backends provide the same methods:

| Method | Description |
| --- | --- |
| `init(allocator)` / `deinit()` | Create or release a world. |
| `create()` | Return the next generated entity index. |
| `add(entity, .component, value)` | Insert a component, or overwrite it. |
| `remove(entity, .component)` | Remove a component and return its old value. |
| `get(entity, .component)` | Copy a component value, if present. |
| `getPtr(entity, .component)` | Pointer into storage for in-place mutation. |
| `has(entity, .component)` | Whether the entity has the component. |
| `count(.component)` | Number of entities with that component. |
| `iterator(.component)` | Iterate `ComponentItem{ entity, value_ptr }`. |
| `execute(System, io, context)` | Run a schedule made by `MakeSystem`. |

`add`, `remove`, `init`, and `deinit` may allocate. Iterators and pointers from
`getPtr` may be invalidated by structural changes (adding or removing
components). Mutating the value behind a `value_ptr` during iteration is fine;
adding or removing components during iteration is not. Iteration order is
unspecified for every backend.

## Systems and scheduling

An executor declares the components it reads and writes and implements
`execute`:

```zig
const Move = struct {
    pub const read = .{ .position, .velocity };
    pub const write = .{.position};

    pub fn execute(world: *World, context: Context) void {
        // Mutate components here.
    }
};

const Frame = ecs.MakeSystem(&.{ Move, Render });
try world.execute(Frame, io, context);
```

`read` and `write` must be tuples of component enum literals (use `.{}` for an
empty set). `execute` must return `void`.

`MakeSystem` produces a type with:

- `stages`: a `[stage_count][stage_width]type` array, padded with `void`.
- `stage_lengths`: a `[stage_count]usize` array with each stage's width.

Scheduling rules:

- A system that writes a component runs before systems that read it.
- Multiple writers of the same component run in declaration order.
- Systems in the same stage have no write/write or read/write conflict and may
  run concurrently.
- Dependency cycles are reported as compile errors naming the systems involved.
- Component names are validated against `World.Component` when the schedule is
  executed, so typos fail at compile time.

Concurrency constraints:

- A stage with one executor runs inline; a stage with several executors spawns
  them with `io.concurrent` and awaits the whole stage.
- Every executor receives the same `context`. Executors running concurrently
  must not mutate shared context state without synchronization.
- Do not add or remove components while a schedule is running.
- Only mutate components listed in the executor's `write` set. The library does
  not lock component storage; correctness depends on the declarations.

## Backends

| Backend | Storage | Strengths | Trade-offs |
| --- | --- | --- | --- |
| `Map` | One `AutoHashMap(Entity, T)` per component. | Simplest layout; only entities that have a component pay for it. | Lookups hash; iteration jumps across buckets. |
| `SparseSet` | Sparse map from entity to dense row, plus dense entity/value arrays. | Contiguous iteration; O(1) lookup plus array index; cheap swap-remove. | Removing an element moves the last element and invalidates outstanding pointers. |
| `Archetype` | Entities grouped by component signature; packed byte columns per component. | Cache-friendly scans over packed columns; cheap to scan a component across many entities. | `add`/`remove` move the entity between archetypes and copy its other components. |

All backends pass the same conformance test in `src/root.zig`.

## Limitations

This is version `0.1.0`; the API is pre-1.0 and may change.

- Iteration is single-component; there are no joins or multi-component queries.
- Executors return `void`, so systems cannot report errors. `execute` only
  returns `std.Io.ConcurrentError` from spawning and awaiting tasks.
- No entity generation or versioning, and no explicit `destroy` operation.
- No serialization, events, change detection, or command buffers.
- The `std.Io`-based scheduling API follows recent Zig releases.

## Building and testing

```sh
zig build test           # run unit tests
zig build check-examples # compile examples without running them
zig build run-map        # run the Map example
zig build run-sparse_set
zig build run-archetype
```

The examples are endless simulation loops that print positions every 200 ticks;
stop them with `Ctrl+C`. They are only defined when this repository is the root
package.

## License

Released under the [MIT License](LICENSE).