const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const builtin = @import("builtin");
const assert = std.debug.assert;
const query_mod = @import("query.zig");
const Archetype = @import("Archetype.zig");
const ArchetypeTree = @import("ArchetypeTree.zig");

/// An entity ID uniquely identifies an entity globally within an Entities set.
pub const EntityID = u64;

fn byTypeId(context: void, lhs: Archetype.Column, rhs: Archetype.Column) bool {
    _ = context;
    return lhs.type_id < rhs.type_id;
}

/// A database of entities. For example, all player, monster, etc. entities in a game world.
///
/// ```
/// const world = Entities.init(allocator); // all entities in our world.
/// defer world.deinit();
///
/// const player1 = world.new(); // our first "player" entity
/// const player2 = world.new(); // our second "player" entity
/// ```
///
/// Entities are divided into archetypes for optimal, CPU cache efficient storage. For example, all
/// entities with two components `Location` and `Name` are stored in the same table dedicated to
/// densely storing `(Location, Name)` rows in contiguous memory. This not only ensures CPU cache
/// efficiency (leveraging data oriented design) which improves iteration speed over entities for
/// example, but makes queries like "find all entities with a Location component" ridiculously fast
/// because one need only find the tables which have a column for storing Location components and it
/// is then guaranteed every entity in the table has that component (entities do not need to be
/// checked one by one to determine if they have a Location component.)
///
/// Components can be added and removed to entities at runtime as you please:
///
/// ```
/// try player1.set("rotation", Rotation{ .degrees = 90 });
/// try player1.remove("rotation");
/// ```
///
/// When getting a component value, you must know it's type or undefined behavior will occur:
/// TODO: improve this!
///
/// ```
/// if (player1.get("rotation", Rotation)) |rotation| {
///     // player1 had a rotation component!
/// }
/// ```
///
/// When a component is added or removed from an entity, it's archetype is said to change. For
/// example player1 may have had the archetype `(Location, Name)` before, and after adding the
/// rotation component has the archetype `(Location, Name, Rotation)`. It will be automagically
/// "moved" from the table that stores entities with `(Location, Name)` components to the table that
/// stores `(Location, Name, Rotation)` components for you.
///
/// You can have 65,535 archetypes in total, and 4,294,967,295 entities total. Entities which are
/// deleted are merely marked as "unused" and recycled
///
/// Database equivalents:
/// * Entities is a database of tables, where each table represents a single archetype.
/// * Archetype is a table, whose rows are entities and columns are components.
/// * EntityID is a mere 32-bit array index, pointing to a 16-bit archetype table index and 32-bit
///   row index, enabling entities to "move" from one archetype table to another seamlessly and
///   making lookup by entity ID a few cheap array indexing operations.
/// * ComponentStorage(T) is a column of data within a table for a single type of component `T`.
pub fn Entities(comptime all_components: anytype) type {
    // TODO: validate all_components is a namespaced component set in the form we expect
    return struct {
        allocator: Allocator,

        /// TODO!
        counter: EntityID = 0,

        /// A mapping of entity IDs (array indices) to where an entity's component values are actually
        /// stored.
        entities: std.AutoHashMapUnmanaged(EntityID, Pointer) = .{},

        /// A generational tree of archetypes
        tree: ArchetypeTree,

        const Self = @This();

        /// Points to where an entity is stored, specifically in which archetype table and in which row
        /// of that table. That is, the entity's component values are stored at:
        ///
        /// ```
        /// Entities.tree.index(ptr.archetype_index).archetype.?.rows[ptr.row_index]
        /// ```
        ///
        pub const Pointer = struct {
            archetype_index: u32,
            row_index: u32,
        };

        /// A complex query for entities matching a given criteria
        pub const Query = query_mod.Query(all_components);
        pub const QueryTag = query_mod.QueryTag;

        pub fn init(allocator: Allocator) !Self {
            // TODO: make capacity configurable
            var tree = try ArchetypeTree.initCapacity(allocator, 512);
            errdefer tree.deinit(allocator);

            var entities = Self{ .allocator = allocator, .tree = tree };

            const columns = try allocator.alloc(Archetype.Column, 1);
            columns[0] = .{
                .name = "id",
                .type_id = Archetype.typeId(EntityID),
                .size = @sizeOf(EntityID),
                .alignment = @alignOf(EntityID),
                .values = undefined,
            };

            entities.tree.index(0).archetype = .{
                .len = 0,
                .capacity = 0,
                .columns = columns,
            };
            return entities;
        }

        pub fn deinit(entities: *Self) void {
            entities.entities.deinit(entities.allocator);
            entities.tree.deinit(entities.allocator);
        }

        /// Returns a new entity.
        pub fn new(entities: *Self) !EntityID {
            const new_id = entities.counter;
            entities.counter += 1;

            var void_archetype = &entities.tree.index(0).archetype.?;
            const new_row = try void_archetype.append(entities.allocator, .{ .id = new_id });
            const void_pointer = Pointer{
                .archetype_index = 0, // void archetype is guaranteed to be first index
                .row_index = new_row,
            };
            errdefer void_archetype.undoAppend();

            try entities.entities.put(entities.allocator, new_id, void_pointer);
            return new_id;
        }

        /// Removes an entity.
        pub fn remove(entities: *Self, entity: EntityID) !void {
            var archetype = entities.archetypeByID(entity);
            const ptr = entities.entities.get(entity).?;

            // A swap removal will be performed, update the entity stored in the last row of the
            // archetype table to point to the row the entity we are removing is currently located.
            if (archetype.len > 1) {
                const last_row_entity_id = archetype.get(entities.allocator, archetype.len - 1, "id", EntityID).?;
                try entities.entities.put(entities.allocator, last_row_entity_id, Pointer{
                    .archetype_index = ptr.archetype_index,
                    .row_index = ptr.row_index,
                });
            }

            // Perform a swap removal to remove our entity from the archetype table.
            archetype.remove(ptr.row_index);

            _ = entities.entities.remove(entity);
        }

        /// Returns the archetype storage for the given entity.
        pub inline fn archetypeByID(entities: *Self, entity: EntityID) *Archetype {
            const ptr = entities.entities.get(entity).?;
            return &entities.tree.index(ptr.archetype_index).archetype.?;
        }

        /// Sets the named component to the specified value for the given entity,
        /// moving the entity from it's current archetype table to the new archetype
        /// table if required.
        pub fn setComponent(
            entities: *Self,
            entity: EntityID,
            comptime namespace_name: std.meta.FieldEnum(@TypeOf(all_components)),
            comptime component_name: std.meta.FieldEnum(@TypeOf(@field(all_components, @tagName(namespace_name)))),
            component: @field(
                @field(all_components, @tagName(namespace_name)),
                @tagName(component_name),
            ),
        ) !void {
            const name = @tagName(namespace_name) ++ "." ++ @tagName(component_name);

            // TODO: use a name set, not hashing, for names.
            const name_hash = @as(u32, @truncate(std.hash_map.hashString(name)));
            const prev_archetype_idx = entities.entities.get(entity).?.archetype_index;
            var prev_archetype = &entities.tree.index(prev_archetype_idx).archetype.?;
            const archetype_idx = try entities.tree.add(entities.allocator, prev_archetype_idx, name_hash);
            const archetype_node = entities.tree.index(archetype_idx);

            if (archetype_node.archetype == null) {
                const columns = try entities.allocator.alloc(Archetype.Column, prev_archetype.columns.len + 1);
                std.mem.copy(Archetype.Column, columns, prev_archetype.columns);
                for (columns) |*column| {
                    column.values = undefined;
                }
                columns[columns.len - 1] = .{
                    .name = name,
                    .type_id = Archetype.typeId(@TypeOf(component)),
                    .size = @sizeOf(@TypeOf(component)),
                    .alignment = if (@sizeOf(@TypeOf(component)) == 0) 1 else @alignOf(@TypeOf(component)),
                    .values = undefined,
                };
                std.sort.pdq(Archetype.Column, columns, {}, byTypeId);

                archetype_node.archetype = .{
                    .len = 0,
                    .capacity = 0,
                    .columns = columns,
                };
            }

            // Either new storage (if the entity moved between storage tables due to having a new
            // component) or the prior storage (if the entity already had the component and it's value
            // is merely being updated.)
            var current_archetype_storage = &archetype_node.archetype.?;

            if (archetype_idx == prev_archetype_idx) {
                // Update the value of the existing component of the entity.
                const ptr = entities.entities.get(entity).?;
                current_archetype_storage.set(entities.allocator, ptr.row_index, name, component);
                return;
            }

            // Copy to all component values for our entity from the old archetype storage (archetype)
            // to the new one (current_archetype_storage).
            const new_row = try current_archetype_storage.appendUndefined(entities.allocator);
            const old_ptr = entities.entities.get(entity).?;

            // Update the storage/columns for all of the existing components on the entity.
            current_archetype_storage.set(entities.allocator, new_row, "id", entity);
            for (prev_archetype.columns) |column| {
                if (std.mem.eql(u8, column.name, "id")) continue;
                for (current_archetype_storage.columns) |corresponding| {
                    if (std.mem.eql(u8, column.name, corresponding.name)) {
                        const old_value_raw = prev_archetype.getRaw(old_ptr.row_index, column);
                        current_archetype_storage.setRaw(new_row, corresponding, old_value_raw) catch |err| {
                            current_archetype_storage.undoAppend();
                            return err;
                        };
                        break;
                    }
                }
            }

            // Update the storage/column for the new component.
            current_archetype_storage.set(entities.allocator, new_row, name, component);

            prev_archetype.remove(old_ptr.row_index);
            const swapped_entity_id = prev_archetype.get(entities.allocator, old_ptr.row_index, "id", EntityID).?;
            // TODO: try is wrong here and below?
            // if we removed the last entry from archetype, then swapped_entity_id == entity
            // so the second entities.put will clobber this one
            try entities.entities.put(entities.allocator, swapped_entity_id, old_ptr);

            try entities.entities.put(entities.allocator, entity, Pointer{
                .archetype_index = archetype_idx,
                .row_index = new_row,
            });
            return;
        }

        /// gets the named component of the given type (which must be correct, otherwise undefined
        /// behavior will occur). Returns null if the component does not exist on the entity.
        pub fn getComponent(
            entities: *Self,
            entity: EntityID,
            comptime namespace_name: std.meta.FieldEnum(@TypeOf(all_components)),
            comptime component_name: std.meta.FieldEnum(@TypeOf(@field(all_components, @tagName(namespace_name)))),
        ) ?@field(
            @field(all_components, @tagName(namespace_name)),
            @tagName(component_name),
        ) {
            const Component = comptime @field(
                @field(all_components, @tagName(namespace_name)),
                @tagName(component_name),
            );
            const name = @tagName(namespace_name) ++ "." ++ @tagName(component_name);
            var archetype = entities.archetypeByID(entity);

            const ptr = entities.entities.get(entity).?;
            return archetype.get(entities.allocator, ptr.row_index, name, Component);
        }

        /// Removes the named component from the entity, or noop if it doesn't have such a component.
        pub fn removeComponent(
            entities: *Self,
            entity: EntityID,
            comptime namespace_name: std.meta.FieldEnum(@TypeOf(all_components)),
            comptime component_name: std.meta.FieldEnum(@TypeOf(@field(all_components, @tagName(namespace_name)))),
        ) !void {
            const name = @tagName(namespace_name) ++ "." ++ @tagName(component_name);

            // TODO: use a name set, not hashing, for names.
            const name_hash = @as(u32, @truncate(std.hash_map.hashString(name)));
            const prev_archetype_idx = entities.entities.get(entity).?.archetype_index;
            var prev_archetype = &entities.tree.index(prev_archetype_idx).archetype.?;
            const archetype_idx = try entities.tree.remove(entities.allocator, prev_archetype_idx, name_hash);
            const archetype_node = entities.tree.index(archetype_idx);
            if (prev_archetype_idx == archetype_idx) return;

            if (archetype_node.archetype == null) {
                const columns = try entities.allocator.alloc(Archetype.Column, prev_archetype.columns.len - 1);
                var i: usize = 0;
                for (prev_archetype.columns) |old_column| {
                    if (std.mem.eql(u8, old_column.name, name)) continue;
                    columns[i] = old_column;
                    columns[i].values = undefined;
                    i += 1;
                }

                archetype_node.archetype = Archetype{
                    .len = 0,
                    .capacity = 0,
                    .columns = columns,
                };
            }

            var current_archetype_storage = &archetype_node.archetype.?;

            // Copy to all component values for our entity from the old archetype storage (archetype)
            // to the new one (current_archetype_storage).
            const new_row = try current_archetype_storage.appendUndefined(entities.allocator);
            const old_ptr = entities.entities.get(entity).?;

            // Update the storage/columns for all of the existing components on the entity that exist in
            // the new archetype table (i.e. excluding the component to remove.)
            current_archetype_storage.set(entities.allocator, new_row, "id", entity);
            for (current_archetype_storage.columns) |column| {
                if (std.mem.eql(u8, column.name, "id")) continue;
                for (prev_archetype.columns) |corresponding| {
                    if (std.mem.eql(u8, column.name, corresponding.name)) {
                        const old_value_raw = prev_archetype.getRaw(old_ptr.row_index, column);
                        current_archetype_storage.setRaw(new_row, column, old_value_raw) catch |err| {
                            current_archetype_storage.undoAppend();
                            return err;
                        };
                        break;
                    }
                }
            }

            prev_archetype.remove(old_ptr.row_index);
            const swapped_entity_id = prev_archetype.get(entities.allocator, old_ptr.row_index, "id", EntityID).?;
            // TODO: try is wrong here and below?
            // if we removed the last entry from archetype, then swapped_entity_id == entity
            // so the second entities.put will clobber this one
            try entities.entities.put(entities.allocator, swapped_entity_id, old_ptr);

            try entities.entities.put(entities.allocator, entity, Pointer{
                .archetype_index = archetype_idx,
                .row_index = new_row,
            });
        }

        // Queries for archetypes matching the given query.
        pub fn query(
            entities: *Self,
            q: Query,
        ) ArchetypeIterator(all_components) {
            return ArchetypeIterator(all_components).init(entities, q);
        }

        // TODO: iteration over all entities
        // TODO: iteration over all entities with components (U, V, ...)
        // TODO: iteration over all entities with type T
        // TODO: iteration over all entities with type T and components (U, V, ...)

        // TODO: "indexes" - a few ideas we could express:
        //
        // * Graph relations index: e.g. parent-child entity relations for a DOM / UI / scene graph.
        // * Spatial index: "give me all entities within 5 units distance from (x, y, z)"
        // * Generic index: "give me all entities where arbitraryFunction(e) returns true"
        //

        // TODO: ability to remove archetype entirely, deleting all entities in it
        // TODO: ability to remove archetypes with no entities (garbage collection)
    };
}

// TODO: move this type somewhere else
pub fn ArchetypeIterator(comptime all_components: anytype) type {
    const EntitiesT = Entities(all_components);
    return struct {
        entities: *EntitiesT,
        query: EntitiesT.Query,
        index: usize,

        const Self = @This();

        pub fn init(entities: *EntitiesT, query: EntitiesT.Query) Self {
            return Self{
                .entities = entities,
                .query = query,
                .index = 0,
            };
        }

        // TODO: all_components is a superset of queried items, not type-safe.
        pub fn next(iter: *Self) ?Archetype.Slicer(all_components) {
            var nodes = iter.entities.tree.nodes.items;
            while (true) {
                if (iter.index == nodes.len - 1) return null;
                iter.index += 1;
                var node = &nodes[iter.index];
                if (node.archetype) |*archetype| {
                    if (iter.match(archetype)) return Archetype.Slicer(all_components){ .archetype = archetype };
                } else continue;
            }
        }

        pub fn match(iter: *Self, consideration: *Archetype) bool {
            if (consideration.len == 0) return false;
            var buf: [2048]u8 = undefined;
            switch (iter.query) {
                .all => {
                    for (iter.query.all) |namespace| {
                        switch (namespace) {
                            inline else => |components| {
                                for (components) |component| {
                                    const name = switch (component) {
                                        inline else => |c| std.fmt.bufPrint(&buf, "{s}.{s}", .{ @tagName(namespace), @tagName(c) }) catch break,
                                    };
                                    var has_column = false;
                                    for (consideration.columns) |column| {
                                        if (std.mem.eql(u8, name, column.name)) {
                                            has_column = true;
                                            break;
                                        }
                                    }
                                    if (!has_column) return false;
                                }
                            },
                        }
                    }
                    return true;
                },
                .any => @panic("TODO"),
            }
        }
    };
}

test "entity ID size" {
    try testing.expectEqual(8, @sizeOf(EntityID));
}

test "example" {
    const allocator = testing.allocator;

    const Location = struct {
        x: f32 = 0,
        y: f32 = 0,
        z: f32 = 0,
    };

    const Rotation = struct { degrees: f32 };

    const all_components = .{
        .entity = .{
            .id = EntityID,
        },
        .game = .{
            .location = Location,
            .name = []const u8,
            .rotation = Rotation,
        },
    };

    //-------------------------------------------------------------------------
    // Create a world.
    var world = try Entities(all_components).init(allocator);
    defer world.deinit();

    //-------------------------------------------------------------------------
    // Create first player entity.
    var player1 = try world.new();
    try world.setComponent(player1, .game, .name, "jane"); // add .name component
    try world.setComponent(player1, .game, .name, "joe"); // update .name component
    try world.setComponent(player1, .game, .location, .{}); // add .location component

    // Create second player entity.
    var player2 = try world.new();
    try testing.expect(world.getComponent(player2, .game, .location) == null);
    try testing.expect(world.getComponent(player2, .game, .name) == null);

    //-------------------------------------------------------------------------
    // We can add new components at will.
    try world.setComponent(player2, .game, .rotation, .{ .degrees = 90 });
    try world.setComponent(player2, .game, .rotation, .{ .degrees = 91 }); // update .rotation component
    try testing.expect(world.getComponent(player1, .game, .rotation) == null); // player1 has no rotation

    //-------------------------------------------------------------------------
    // Remove a component from any entity at will.
    // TODO: add a way to "cleanup" truly unused archetypes
    try world.removeComponent(player1, .game, .name);
    try world.removeComponent(player1, .game, .location);
    try world.removeComponent(player1, .game, .location); // doesn't exist? no problem.

    //-------------------------------------------------------------------------
    // Introspect things.
    //
    // Archetype IDs, these are our "table names" - they're just hashes of all the component names
    // within the archetype table.
    var archetypes = world.tree.nodes.items;
    try testing.expectEqual(@as(usize, 5), archetypes.len);
    try testing.expectEqual(@as(u32, 0), archetypes[0].name);
    try testing.expectEqual(@as(u32, 163538855), archetypes[1].name);
    try testing.expectEqual(@as(u32, 177100276), archetypes[2].name);
    try testing.expectEqual(@as(u32, 934892538), archetypes[3].name);
    try testing.expectEqual(@as(u32, 177100276), archetypes[4].name);

    // Number of (living) entities stored in an archetype table.
    try testing.expectEqual(@as(usize, 1), archetypes[0].archetype.?.len);
    try testing.expectEqual(@as(usize, 0), archetypes[1].archetype.?.len);
    try testing.expectEqual(@as(usize, 0), archetypes[2].archetype.?.len);
    try testing.expectEqual(@as(usize, 1), archetypes[3].archetype.?.len);
    try testing.expectEqual(@as(usize, 0), archetypes[4].archetype.?.len);

    // Resolve archetype by entity ID and print column names
    var columns = world.archetypeByID(player2).columns;
    try testing.expectEqual(@as(usize, 2), columns.len);
    try testing.expectEqualStrings("id", columns[0].name);
    try testing.expectEqualStrings("game.rotation", columns[1].name);

    //-------------------------------------------------------------------------
    // Query for archetypes that have all of the given components
    var iter = world.query(.{ .all = &.{
        .{ .game = &.{.rotation} },
    } });
    while (iter.next()) |archetype| {
        var ids = archetype.slice(.entity, .id);
        try testing.expectEqual(@as(usize, 1), ids.len);
        try testing.expectEqual(player2, ids[0]);
    }

    // TODO: iterating components an entity has not currently supported.

    //-------------------------------------------------------------------------
    // Remove an entity whenever you wish. Just be sure not to try and use it later!
    try world.remove(player1);
}

test "empty_world" {
    const allocator = testing.allocator;
    //-------------------------------------------------------------------------
    var world = try Entities(.{}).init(allocator);
    // Create a world.
    defer world.deinit();
}

test "many entities" {
    const allocator = testing.allocator;

    const Location = struct {
        x: f32 = 0,
        y: f32 = 0,
        z: f32 = 0,
    };

    const Rotation = struct { degrees: f32 };

    const all_components = .{
        .entity = .{
            .id = EntityID,
        },
        .game = .{
            .location = Location,
            .name = []const u8,
            .rotation = Rotation,
        },
    };

    // Create many entities
    var world = try Entities(all_components).init(allocator);
    defer world.deinit();
    for (0..8192) |_| {
        var player = try world.new();
        try world.setComponent(player, .game, .name, "jane");
        try world.setComponent(player, .game, .location, .{});
    }

    // Confirm the number of archetypes created
    var archetypes = world.tree.nodes.items;
    try testing.expectEqual(@as(usize, 3), archetypes.len);

    // Confirm archetypes
    var columns = archetypes[0].archetype.?.columns;
    try testing.expectEqual(@as(usize, 1), columns.len);
    try testing.expectEqualStrings("id", columns[0].name);

    columns = archetypes[1].archetype.?.columns;
    try testing.expectEqual(@as(usize, 2), columns.len);
    try testing.expectEqualStrings("id", columns[0].name);
    try testing.expectEqualStrings("game.name", columns[1].name);

    columns = archetypes[2].archetype.?.columns;
    try testing.expectEqual(@as(usize, 3), columns.len);
    try testing.expectEqualStrings("id", columns[0].name);
    try testing.expectEqualStrings("game.name", columns[1].name);
    try testing.expectEqualStrings("game.location", columns[2].name);
}
