# ecs

A small, backend-agnostic entity-component-system (ECS) library for Zig. Three backends (`Map`, `SparseSet`, `Archetype`) expose the same API and are freely interchangeable; it depends only on the Zig standard library.

Storage and scheduling are separated: systems declare component reads and writes at compile time, `MakeSystem` turns those declarations into a staged schedule, and stages without conflicts run concurrently through `std.Io`. The component set is a plain struct; field names become a compile-time enum. Every backend supports single-component iteration and generated multi-component queries. Dependency cycles and component-name typos are both reported at compile time.

## Requirements

- Zig 0.17.0 or newer.

## Installation

```sh
zig fetch --save git+https://github.com/Verafahn/ecs.git
```

Expose the module in `build.zig`:

```zig
const ecs = b.dependency("ecs", .{});
exe.root_module.addImport("ecs", ecs.module("ecs"));
```

Then import it with `@import("ecs")`.

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
        var query = world.query(.{ .position, .velocity });
        while (query.next()) |item| {
            item.position.x += item.velocity.x * dt;
            item.position.y += item.velocity.y * dt;
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

## Concepts

### Entity

An `Entity` is an integer index; the index type can be chosen freely. The module provides a default index generator, and you can also implement a custom one. Entities are not versioned: an index can be reused after all its components are removed, but stale handles cannot be detected.

### Component

A `Component` is data bound to an `Entity`. Declare all valid components with a plain struct; field names become the compile-time `Component` enum and field types are the component types. The backend's internal representation is generated at compile time. Zero-sized components are allowed.

### Joint queries

`query` yields only entities that have every requested component, with one pointer per component:

```zig
var query = world.query(.{ .position, .velocity });
while (query.next()) |item| {
    item.position.x += item.velocity.x * dt;
}
```

The generated row contains `entity` plus one `*T` field per queried component, named after the component and ordered like the query. At least one component is required; duplicate components and a component named `entity` are compile errors. `Map` uses the first queried component to drive the iteration, `SparseSet` picks the smallest component set, and `Archetype` visits only matching archetypes. Structural changes may invalidate the query.

### Systems and scheduling

A `System` must declare `read`, `write`, and `execute` (see `Move` in Quick start): `read`/`write` are tuples of component enum literals (use `.{}` for an empty set) that declare dependencies between systems; `execute` is the system body and must return `void`.

Before running, use `MakeSystem` to build a schedule for several systems; `World.execute` then calls each system's `execute` according to that schedule. The scheduling order is fixed; the passed `io` controls concurrent execution behavior. Rules:

- A system that writes a component runs before systems that read it.
- Multiple writers of the same component run in declaration order.
- Systems in the same stage have no write/write or read/write conflict and may run concurrently.
- Dependency cycles are reported as compile errors naming the systems involved.
- Component names are validated against `World.Component` when the schedule is executed, so typos fail at compile time.

Concurrency constraints: a stage with a single executor runs inline; a stage with multiple executors is spawned through `io.concurrent` and awaited as a whole. Concurrent executors share the same `context` and must not mutate shared state without synchronization. Do not add or remove components while a schedule is running. Only mutate components listed in the system's `write` set—the library does not lock storage, so correctness depends on the declarations.

## ECS API

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
| `query(.{ .position, .velocity })` | Iterate entities that have all listed components. |
| `execute(System, io, context)` | Run a schedule made by `MakeSystem`. |

`add`, `remove`, `init`, and `deinit` may allocate. Iterators and pointers returned by `getPtr` may be invalidated by structural changes (adding or removing components); mutating the value behind a `value_ptr` during iteration is safe, but adding or removing components is not. Iteration order is unspecified for all backends.

## Backend comparison

| Backend | Storage | Strengths | Trade-offs |
| --- | --- | --- | --- |
| `Map` | One hash map per component. | Simplest layout; only entities that have a component pay for it. | Lookups hash; iteration jumps across buckets; the first query component drives joins. |
| `SparseSet` | Sparse map + dense entity/value arrays. | Contiguous iteration; O(1) lookup; the smallest set drives joins; cheap swap-remove. | Removing an element moves the last element and invalidates outstanding pointers. |
| `Archetype` | Entities grouped by component signature; packed byte columns per component. | Cache-friendly scans; joins visit only matching archetypes. | `add`/`remove` move entities between archetypes and copy their other components. |

<details>
<summary>Full comparison table</summary>

| Dimension | `Map` | `SparseSet` | `Archetype` |
|---|---|---|---|
| Core data structure | One `AutoHashMap(Entity, T)` per component | Sparse array (Entity → dense index) + dense array | Grouped by component signature; SoA column storage |
| Single-component lookup | Average O(1), worst O(n) | O(1) | O(1) |
| Add/remove component | O(1) | O(1) amortized swap-remove | High: migrate between archetypes and copy all components |
| Single-component iteration | Poor: scattered nodes, frequent cache misses | Good: contiguous dense arrays | Excellent: contiguous packed columns |
| Joint query | First queried component drives; probes the rest | Smallest component set drives the loop | Scans only archetypes containing the full signature |
| Cache friendliness | Poor | Good | Excellent |
| Entity reference stability | May be invalidated on rehash | **Removing an element moves the last element and invalidates pointers to the moved entity** | Structural changes move entities |
| Implementation complexity | Lowest | Medium | Highest |
| Typical use cases | Prototyping, small object counts | Frequent dynamic composition, medium-scale iteration | Large numbers of homogeneous entities, infrequent structural changes |

</details>

## Building and testing

```sh
zig build test           # run unit tests
zig build check-examples # compile examples without running them
zig build run-map
zig build run-sparse_set
zig build run-archetype
```

The examples are endless simulation loops that print positions every 200 ticks; stop them with `Ctrl+C`. They are only defined when this repository is the root package.

## License

[MIT License](LICENSE)