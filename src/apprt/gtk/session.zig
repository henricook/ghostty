//! Session save/restore for the GTK apprt.
//!
//! This persists the set of open windows, their tabs, each tab's split
//! layout, each surface's working directory, and any user-set title
//! overrides to disk when Ghostty exits, and restores them on the next
//! launch. This brings a subset of the macOS-only `window-save-state`
//! behavior to Linux.
//!
//! Only titles the user explicitly set (tab and surface title overrides) are
//! persisted. Terminal-set (OSC 0/2) titles are deliberately not saved: they
//! would be restored as pinned overrides and never update again.
//!
//! Scrollback contents are persisted separately (see the bottom of this file)
//! and are opt-in via `window-save-state-scrollback-size`.
//!
//! The JSON schema is versioned and tolerant of unknown fields. This file
//! deliberately imports nothing from GTK so it can be unit tested in builds
//! without the GTK headers available.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

const internal_os = @import("../../os/main.zig");
const configpkg = @import("../../config.zig");
const CoreConfig = configpkg.Config;

const log = std.log.scoped(.gtk_session);

/// The subdirectory (under the XDG state directory) and filename we use. The
/// application id is appended to `subdir` so that instances with different ids
/// (a debug build alongside a release one, or a custom `class`) can run at the
/// same time without overwriting each other's state.
const subdir = "ghostty";
const filename = "session.json";
const filename_tmp = "session.json.tmp";

/// Maximum size of the session file we're willing to read. Session files are
/// tiny (a few KB at most) so this is a generous sanity bound.
const max_read_size = 1024 * 1024;

/// Session state records working directories, user-set titles and (opt-in)
/// verbatim terminal output, so everything we write is user-only.
const file_permissions: std.Io.File.Permissions =
    if (builtin.os.tag != .windows and std.posix.mode_t != u0)
        .fromMode(0o600)
    else
        .default_file;

const dir_permissions: std.Io.Dir.Permissions =
    if (builtin.os.tag != .windows and std.posix.mode_t != u0)
        .fromMode(0o700)
    else
        .default_dir;

/// Upper bounds applied when restoring. A session file is small in practice;
/// these exist so that a corrupt or hostile file can't ask us to map tens of
/// thousands of windows or construct tens of thousands of surfaces.
pub const max_restore_windows = 64;
pub const max_restore_tabs = 128;
pub const max_restore_nodes = 256;

/// The current schema version. Bump this when the structure changes in a way
/// that older Ghostty versions cannot understand. Readers reject mismatched
/// versions (treating them as "no session") and ignore unknown fields.
pub const version: u32 = 2;

pub const Session = struct {
    version: u32 = version,
    windows: []const Window = &.{},

    pub const Window = struct {
        /// Stable random identifier for this window (see `newId`). 0 means
        /// "unset" (e.g. a session file written before ids existed).
        id: u64 = 0,

        /// Window geometry. Restored via setDefaultSize when present.
        width: ?i32 = null,
        height: ?i32 = null,

        /// Whether the window was maximized.
        maximized: bool = false,

        /// The user-set window title override, if any.
        title: ?[]const u8 = null,

        /// The index (within `tabs`) of the tab that was selected/focused.
        focused_tab: ?u32 = null,

        tabs: []const Tab = &.{},
    };

    pub const Tab = struct {
        /// Stable random identifier for this tab (see `newId`). 0 means
        /// "unset".
        id: u64 = 0,

        /// The user-set tab title override, if any. Restored by re-applying
        /// it as an override.
        title: ?[]const u8 = null,

        /// The tab's split layout. If null (or empty) the tab is restored
        /// with a single default surface.
        tree: ?Tree = null,
    };

    /// A tab's split layout, mirroring `datastruct.SplitTree`: a flat array
    /// of nodes in which index 0 is the root and splits reference their
    /// children by index. Indices are preserved verbatim across a
    /// save/restore cycle so `zoomed` maps back 1:1.
    pub const Tree = struct {
        nodes: []const Node = &.{},

        /// The index of the zoomed node, if any.
        zoomed: ?u16 = null,
    };

    pub const Node = union(enum) {
        leaf: Leaf,
        split: Split,

        pub const Leaf = struct {
            /// Stable random identifier for this surface (see `newId`).
            /// This is the key for the surface's scrollback file
            /// (`<id>.vt`). 0 means "unset".
            id: u64 = 0,

            /// The surface's working directory, if known.
            pwd: ?[]const u8 = null,

            /// The user-set surface title override, if any.
            title_override: ?[]const u8 = null,

            /// True for the surface that was active within its tab.
            focused: bool = false,
        };

        pub const Split = struct {
            layout: Layout = .horizontal,

            /// The proportion of the split occupied by `left`. The
            /// datastruct stores this as an f16; f32 is used here because
            /// it round-trips cleanly through JSON tooling.
            ratio: f32 = 0.5,

            left: u16 = 0,
            right: u16 = 0,
        };

        pub const Layout = enum { horizontal, vertical };
    };
};

/// Generate a new stable random id for a window, tab or surface. Kept to 52
/// bits so it round-trips exactly through JSON (and tools like jq/python that
/// use f64), and is never 0 (which is the "unset" sentinel). Collisions across
/// the small number of live objects are astronomically unlikely.
pub fn newId(io: std.Io) u64 {
    const mask: u64 = (1 << 52) - 1;
    const source: std.Random.IoSource = .{ .io = io };
    const id = source.interface().int(u64) & mask;
    return if (id == 0) 1 else id;
}

/// Returns true if window state should be written to disk on exit.
///
/// On Linux there is no OS-level restoration mechanism, so `default` behaves
/// like `always` ("just works"). `never` disables saving entirely.
pub fn shouldSaveState(config: *const CoreConfig) bool {
    return switch (config.@"window-save-state") {
        .never => false,
        .default, .always => true,
    };
}

/// Returns true if a previously saved session should be restored on launch.
pub fn shouldRestoreState(config: *const CoreConfig) bool {
    return switch (config.@"window-save-state") {
        .never => false,
        .default, .always => true,
    };
}

/// Compute the absolute path to our state directory. Caller owns the memory.
fn stateDir(
    io: std.Io,
    alloc: Allocator,
    environ_map: *const Environ.Map,
    app_id: []const u8,
) ![]u8 {
    const sub = try std.fs.path.join(alloc, &.{ subdir, app_id });
    defer alloc.free(sub);

    const dir = try internal_os.xdg.state(io, alloc, environ_map, .{ .subdir = sub });
    errdefer alloc.free(dir);

    // `XDG_STATE_HOME` is used verbatim if set, and the absolute-path
    // functions below assert rather than error on a relative one.
    if (!std.fs.path.isAbsolute(dir)) return error.StateDirNotAbsolute;

    return dir;
}

/// Compute the absolute path to the session file. Caller owns the memory.
pub fn path(
    io: std.Io,
    alloc: Allocator,
    environ_map: *const Environ.Map,
    app_id: []const u8,
) ![]u8 {
    const dir = try stateDir(io, alloc, environ_map, app_id);
    defer alloc.free(dir);
    return try std.fs.path.join(alloc, &.{ dir, filename });
}

/// Serialize a session to indented JSON. Caller owns the returned memory.
pub fn serialize(alloc: Allocator, session: Session) ![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(alloc);
    errdefer buffer.deinit();
    try buffer.writer.print("{f}", .{std.json.fmt(
        session,
        .{ .whitespace = .indent_2 },
    )});
    return try buffer.toOwnedSlice();
}

/// Parse session bytes. Returns null if the bytes are malformed or were
/// written by an incompatible schema version. The result must be freed with
/// `.deinit()`.
pub fn parse(alloc: Allocator, bytes: []const u8) ?std.json.Parsed(Session) {
    const parsed = std.json.parseFromSlice(
        Session,
        alloc,
        bytes,
        .{
            .ignore_unknown_fields = true,
            // Copy all strings into the parsed arena so the result is fully
            // self-contained and the caller can free `bytes`.
            .allocate = .alloc_always,
        },
    ) catch |err| {
        log.warn("failed to parse session file, ignoring err={}", .{err});
        return null;
    };

    if (parsed.value.version != version) {
        log.info(
            "ignoring session file with unsupported version={}",
            .{parsed.value.version},
        );
        parsed.deinit();
        return null;
    }

    return parsed;
}

/// Atomically write pre-serialized session bytes to the session file,
/// creating the state directory (and any missing parents) if needed. Errors
/// are returned to the caller, which is expected to log and swallow them.
pub fn writeBytes(
    io: std.Io,
    alloc: Allocator,
    environ_map: *const Environ.Map,
    app_id: []const u8,
    bytes: []const u8,
) !void {
    const dir_path = try stateDir(io, alloc, environ_map, app_id);
    defer alloc.free(dir_path);

    var dir = try openDirCreate(io, dir_path, .{});
    defer dir.close(io);

    // Write to a temp file then rename over the target so a crash mid-write
    // never leaves a corrupt session file.
    try dir.writeFile(io, .{
        .sub_path = filename_tmp,
        .data = bytes,
        .flags = .{ .permissions = file_permissions },
    });
    try dir.rename(filename_tmp, dir, filename, io);

    log.info("session written to {s}/{s} ({d} bytes)", .{ dir_path, filename, bytes.len });
}

/// Load and parse the session file. Returns null if there is no session file,
/// it can't be read/parsed, or its version doesn't match the current schema.
/// The returned value must be freed with `.deinit()`.
pub fn load(
    io: std.Io,
    alloc: Allocator,
    environ_map: *const Environ.Map,
    app_id: []const u8,
) !?std.json.Parsed(Session) {
    const dir_path = try stateDir(io, alloc, environ_map, app_id);
    defer alloc.free(dir_path);

    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            log.info("no session directory at {s}", .{dir_path});
            return null;
        },
        else => return err,
    };
    defer dir.close(io);

    const bytes = dir.readFileAlloc(
        io,
        filename,
        alloc,
        .limited(max_read_size),
    ) catch |err| switch (err) {
        error.FileNotFound => {
            log.info("no session file at {s}/{s}", .{ dir_path, filename });
            return null;
        },
        else => return err,
    };
    defer alloc.free(bytes);

    log.info("loading session from {s}/{s}", .{ dir_path, filename });

    const parsed = parse(alloc, bytes) orelse return null;

    // Snapshot the file we just successfully restored from. Restore time is
    // the one moment the file is both known-good and known-valuable (it holds
    // the previous session's full layout), and the save path never writes to
    // the backup directory, so a later clobbered session.json can be
    // recovered by copying a backup over it.
    backupRestored(io, alloc, dir_path, bytes);

    return parsed;
}

/// Delete the session file if it exists. Used when saving is disabled
/// (`window-save-state = never`) so that a stale file is not restored.
pub fn delete(
    io: std.Io,
    alloc: Allocator,
    environ_map: *const Environ.Map,
    app_id: []const u8,
) void {
    const p = path(io, alloc, environ_map, app_id) catch return;
    defer alloc.free(p);
    std.Io.Dir.deleteFileAbsolute(io, p) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            log.warn("failed to delete session file err={}", .{err});
            return;
        },
    };
    log.info("deleted session file {s}", .{p});
}

/// Open an absolute directory, creating it (and any missing parents) first.
fn openDirCreate(
    io: std.Io,
    dir_path: []const u8,
    options: std.Io.Dir.OpenOptions,
) !std.Io.Dir {
    _ = std.Io.Dir.cwd().createDirPathStatus(
        io,
        dir_path,
        dir_permissions,
    ) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return try std.Io.Dir.openDirAbsolute(io, dir_path, options);
}

// ---------------------------------------------------------------------------
// Restore-time backups
//
// Every successful restore snapshots the session file into
// `backup/<unix timestamp>.json` next to it. The save path never writes
// there, so a session.json that is later overwritten with something
// throwaway (e.g. opening and closing a single fresh window) can be
// recovered by copying a backup back over it. Only the most recent
// `max_backups` snapshots are kept.

const backup_subdir = "backup";
const max_backups = 10;

fn backupRestored(
    io: std.Io,
    alloc: Allocator,
    state_dir_path: []const u8,
    bytes: []const u8,
) void {
    const full = std.fs.path.join(
        alloc,
        &.{ state_dir_path, backup_subdir },
    ) catch return;
    defer alloc.free(full);

    var dir = openDirCreate(io, full, .{ .iterate = true }) catch |err| {
        log.warn("failed to open session backup dir err={}", .{err});
        return;
    };
    defer dir.close(io);

    const ts: u64 = @intCast(@max(
        0,
        @divTrunc(
            std.Io.Timestamp.now(io, .real).toMicroseconds(),
            std.time.us_per_s,
        ),
    ));
    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(
        &name_buf,
        "{d:0>10}.json",
        .{ts},
    ) catch return;

    dir.writeFile(io, .{
        .sub_path = name,
        .data = bytes,
        .flags = .{ .permissions = file_permissions },
    }) catch |err| {
        log.warn("failed to write session backup err={}", .{err});
        return;
    };
    log.info(
        "session backup written to {s}/{s}/{s}",
        .{ state_dir_path, backup_subdir, name },
    );

    pruneBackups(io, alloc, &dir);
}

/// Delete the oldest backups beyond `max_backups`. Only files matching the
/// `<timestamp>.json` shape are considered; anything else in the directory
/// (e.g. a copy a user made by hand) is left alone.
fn pruneBackups(io: std.Io, alloc: Allocator, dir: *std.Io.Dir) void {
    var stamps: std.ArrayListUnmanaged(u64) = .empty;
    defer stamps.deinit(alloc);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const stem = entry.name[0 .. entry.name.len - ".json".len];
        const ts = std.fmt.parseInt(u64, stem, 10) catch continue;
        stamps.append(alloc, ts) catch return;
    }
    if (stamps.items.len <= max_backups) return;

    std.mem.sort(u64, stamps.items, {}, std.sort.asc(u64));
    for (stamps.items[0 .. stamps.items.len - max_backups]) |ts| {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(
            &name_buf,
            "{d:0>10}.json",
            .{ts},
        ) catch continue;
        dir.deleteFile(io, name) catch {};
    }
}

// ---------------------------------------------------------------------------
// Scrollback persistence
//
// Each surface's scrollback is stored in its own file under a `scrollback`
// subdirectory, named `<id>.vt` (keyed by the surface's stable id), holding
// styled VT bytes. Keying by a stable id (rather than an enumeration index)
// means a surface always reads/writes the same file regardless of how
// windows/tabs/splits are added or reordered, and lets the save path safely
// skip never-realized surfaces.

const scrollback_subdir = "scrollback";

/// Floor for the scrollback read limit, so a shrunken (or zeroed)
/// `window-save-state-scrollback-size` still lets us read back what a previous
/// run wrote.
const min_scrollback_read_size = 1024 * 1024;

/// Open the scrollback directory, creating it only when `create` is set: the
/// read and cleanup paths must not bring it into existence. Caller closes the
/// Dir.
fn scrollbackDir(
    io: std.Io,
    alloc: Allocator,
    environ_map: *const Environ.Map,
    app_id: []const u8,
    options: std.Io.Dir.OpenOptions,
    create: bool,
) !std.Io.Dir {
    const dir_path = try stateDir(io, alloc, environ_map, app_id);
    defer alloc.free(dir_path);

    const full = try std.fs.path.join(alloc, &.{ dir_path, scrollback_subdir });
    defer alloc.free(full);

    return if (create)
        try openDirCreate(io, full, options)
    else
        try std.Io.Dir.openDirAbsolute(io, full, options);
}

/// Write a surface's scrollback bytes to its id-keyed file.
pub fn writeScrollback(
    io: std.Io,
    alloc: Allocator,
    environ_map: *const Environ.Map,
    app_id: []const u8,
    id: u64,
    bytes: []const u8,
) !void {
    var dir = try scrollbackDir(io, alloc, environ_map, app_id, .{}, true);
    defer dir.close(io);

    var name_buf: [32]u8 = undefined;
    var tmp_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{d}.vt", .{id});
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{d}.vt.tmp", .{id});

    try dir.writeFile(io, .{
        .sub_path = tmp,
        .data = bytes,
        .flags = .{ .permissions = file_permissions },
    });
    try dir.rename(tmp, dir, name, io);
    log.info("scrollback id {d} written ({d} bytes)", .{ id, bytes.len });
}

/// Read a surface's scrollback bytes from its id-keyed file. Returns null if
/// there is no scrollback for that id. `max_size` is the currently configured
/// write budget; the read limit is derived from it so that raising the budget
/// never makes previously written files unreadable. Caller owns the returned
/// memory.
pub fn readScrollback(
    io: std.Io,
    alloc: Allocator,
    environ_map: *const Environ.Map,
    app_id: []const u8,
    max_size: usize,
    id: u64,
) !?[]u8 {
    var dir = scrollbackDir(io, alloc, environ_map, app_id, .{}, false) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io);

    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{d}.vt", .{id});

    // `readFileAlloc` fails when the limit is *reached*, so allow one byte
    // more than a full-budget dump.
    const limit = @max(max_size, min_scrollback_read_size) +| 1;

    const bytes = dir.readFileAlloc(
        io,
        name,
        alloc,
        .limited(limit),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (bytes.len == 0) {
        alloc.free(bytes);
        return null;
    }
    return bytes;
}

/// Delete a surface's scrollback file, if it exists (e.g. a realized surface
/// whose scrollback is now empty).
pub fn deleteScrollback(
    io: std.Io,
    alloc: Allocator,
    environ_map: *const Environ.Map,
    app_id: []const u8,
    id: u64,
) void {
    var dir = scrollbackDir(io, alloc, environ_map, app_id, .{}, false) catch return;
    defer dir.close(io);
    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{d}.vt", .{id}) catch return;
    dir.deleteFile(io, name) catch {};
}

/// Delete any scrollback files whose id is not in `keep`. Used to clean up
/// files for surfaces that no longer exist, and (with an empty `keep`) to
/// discard every dump when scrollback persistence is turned off. We collect
/// names first and delete afterwards so we never mutate the directory
/// mid-iteration.
pub fn pruneScrollback(
    io: std.Io,
    alloc: Allocator,
    environ_map: *const Environ.Map,
    app_id: []const u8,
    keep: []const u64,
) void {
    var dir = scrollbackDir(io, alloc, environ_map, app_id, .{ .iterate = true }, false) catch return;
    defer dir.close(io);

    var to_delete: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (to_delete.items) |n| alloc.free(n);
        to_delete.deinit(alloc);
    }

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        const del = del: {
            // Remove stale temp files unconditionally.
            if (std.mem.endsWith(u8, name, ".vt.tmp")) break :del true;
            // Only "<id>.vt" files are candidates.
            if (!std.mem.endsWith(u8, name, ".vt")) break :del false;
            const id = std.fmt.parseInt(u64, name[0 .. name.len - 3], 10) catch
                break :del false;
            for (keep) |k| if (k == id) break :del false;
            break :del true;
        };
        if (del) {
            const dup = alloc.dupe(u8, name) catch continue;
            to_delete.append(alloc, dup) catch alloc.free(dup);
        }
    }

    for (to_delete.items) |n| dir.deleteFile(io, n) catch {};
}

test "session shouldSaveState mapping" {
    const testing = std.testing;
    var c = try CoreConfig.default(testing.allocator);
    defer c.deinit();

    c.@"window-save-state" = .never;
    try testing.expect(!shouldSaveState(&c));
    try testing.expect(!shouldRestoreState(&c));

    c.@"window-save-state" = .default;
    try testing.expect(shouldSaveState(&c));
    try testing.expect(shouldRestoreState(&c));

    c.@"window-save-state" = .always;
    try testing.expect(shouldSaveState(&c));
    try testing.expect(shouldRestoreState(&c));
}

test "session serialize and parse round trip" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const nodes: []const Session.Node = &.{
        .{ .split = .{
            .layout = .vertical,
            .ratio = 0.25,
            .left = 1,
            .right = 2,
        } },
        .{ .leaf = .{
            .id = 111,
            .pwd = "/home/user/src",
            .title_override = "pinned",
            .focused = true,
        } },
        .{ .leaf = .{ .id = 222, .pwd = "/tmp" } },
    };

    const tabs: []const Session.Tab = &.{
        .{
            .id = 1234,
            .title = "build",
            .tree = .{ .nodes = nodes, .zoomed = 2 },
        },
        .{ .id = 5678 },
    };
    const windows: []const Session.Window = &.{.{
        .id = 42,
        .width = 1280,
        .height = 720,
        .maximized = true,
        .title = "work",
        .focused_tab = 1,
        .tabs = tabs,
    }};

    const bytes = try serialize(alloc, .{ .windows = windows });
    defer alloc.free(bytes);

    const parsed = parse(alloc, bytes) orelse return error.ParseFailed;
    defer parsed.deinit();

    try testing.expectEqual(version, parsed.value.version);
    try testing.expectEqual(@as(usize, 1), parsed.value.windows.len);

    const w = parsed.value.windows[0];
    try testing.expectEqual(@as(u64, 42), w.id);
    try testing.expectEqual(@as(?i32, 1280), w.width);
    try testing.expectEqual(@as(?i32, 720), w.height);
    try testing.expect(w.maximized);
    try testing.expectEqualStrings("work", w.title.?);
    try testing.expectEqual(@as(?u32, 1), w.focused_tab);
    try testing.expectEqual(@as(usize, 2), w.tabs.len);

    try testing.expectEqualStrings("build", w.tabs[0].title.?);

    const tree = w.tabs[0].tree.?;
    try testing.expectEqual(@as(?u16, 2), tree.zoomed);
    try testing.expectEqual(@as(usize, 3), tree.nodes.len);

    const split = tree.nodes[0].split;
    try testing.expectEqual(Session.Node.Layout.vertical, split.layout);
    try testing.expectEqual(@as(f32, 0.25), split.ratio);
    try testing.expectEqual(@as(u16, 1), split.left);
    try testing.expectEqual(@as(u16, 2), split.right);

    const leaf = tree.nodes[1].leaf;
    try testing.expectEqual(@as(u64, 111), leaf.id);
    try testing.expectEqualStrings("/home/user/src", leaf.pwd.?);
    try testing.expectEqualStrings("pinned", leaf.title_override.?);
    try testing.expect(leaf.focused);

    const leaf2 = tree.nodes[2].leaf;
    try testing.expectEqualStrings("/tmp", leaf2.pwd.?);
    try testing.expectEqual(@as(?[]const u8, null), leaf2.title_override);
    try testing.expect(!leaf2.focused);

    try testing.expectEqual(@as(?[]const u8, null), w.tabs[1].title);
    try testing.expectEqual(@as(?Session.Tree, null), w.tabs[1].tree);
}

test "session parse tolerates a tab with no tree" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const parsed = parse(
        alloc,
        \\{"version":2,"windows":[{"tabs":[{"id":7}]}]}
        ,
    ) orelse return error.ParseFailed;
    defer parsed.deinit();

    const w = parsed.value.windows[0];
    try testing.expectEqual(@as(usize, 1), w.tabs.len);
    try testing.expectEqual(@as(u64, 7), w.tabs[0].id);
    try testing.expect(w.tabs[0].tree == null);
    try testing.expect(!w.maximized);
}

test "session parse rejects other versions" {
    const testing = std.testing;
    const alloc = testing.allocator;

    try testing.expect(parse(alloc, "{\"version\":1,\"windows\":[]}") == null);
    try testing.expect(parse(alloc, "not json") == null);

    // Unknown fields are tolerated so newer files degrade gracefully once
    // the version matches again.
    const parsed = parse(
        alloc,
        "{\"version\":2,\"windows\":[],\"future_field\":true}",
    ) orelse return error.ParseFailed;
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.windows.len);
}

test "session newId is nonzero and fits 52 bits" {
    const testing = std.testing;
    for (0..64) |_| {
        const id = newId(std.testing.io);
        try testing.expect(id != 0);
        try testing.expect(id < (1 << 52));
    }
}

test "session path is namespaced by application id" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var environ_map = try testing.environ.createMap(alloc);
    defer environ_map.deinit();
    try environ_map.put("XDG_STATE_HOME", "/tmp/ghostty-test-state");

    const p = try path(testing.io, alloc, &environ_map, "com.example.ghostty");
    defer alloc.free(p);

    try testing.expectEqualStrings(
        "/tmp/ghostty-test-state/ghostty/com.example.ghostty/session.json",
        p,
    );
}

test "session path rejects a relative state dir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var environ_map = try testing.environ.createMap(alloc);
    defer environ_map.deinit();
    try environ_map.put("XDG_STATE_HOME", "relative/state");

    // The absolute-path APIs we use assert rather than error on this, so it
    // has to be caught before we ever build a Dir.
    try testing.expectError(
        error.StateDirNotAbsolute,
        path(testing.io, alloc, &environ_map, "com.example.ghostty"),
    );
}

test "session parse rejects an unknown node kind" {
    // Node kinds are a closed set, so an unrecognized one is a structural
    // error: the file is discarded rather than partially applied.
    try std.testing.expect(parse(std.testing.allocator,
        \\{"version":2,"windows":[{"tabs":[{"tree":{"nodes":[{"bogus":{}}]}}]}]}
    ) == null);
}
