const std = @import("std");
const sqlite = @import("sqlite");
const Text = sqlite.Text;

pub fn realpath(allocator: std.mem.Allocator, pathname: []const u8) ![:0]u8 {
    var full_path: []u8 = std.fs.realpathAlloc(allocator, pathname) catch |err| {
        std.log.err("Could not find the path to the file (try using relative references)...\n", .{});
        return err;
    };
    defer allocator.free(full_path);

    return try std.fs.path.joinZ(allocator, &[_][]const u8{full_path});
}

fn db_exists(db_path: [:0]u8) bool {
    var file: std.fs.File = std.fs.openFileAbsoluteZ(db_path, .{}) catch {
        return false;
    };

    file.close();
    return true;
}

pub fn main() !void {
    // Setup Allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get the absolute path of the database
    var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var db_path_tmp = try std.fs.realpath(".", &buffer);
    var db_path: [:0]u8 = try std.fs.path.joinZ(allocator, &[_][]const u8{ db_path_tmp, "data.db" });
    defer allocator.free(db_path);

    // If the database is new, we need to create a table later
    var is_new = !db_exists(db_path);

    // Create|Open the database
    var init_options = .{
        .mode = sqlite.Db.Mode{ .File = db_path },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    };

    var db = try sqlite.Db.init(init_options);
    defer db.deinit();

    // Create a table if the database is new
    if (is_new) {
        const query =
            \\CREATE TABLE files (
            \\    file_id INTEGER PRIMARY KEY,
            \\    local_path TEXT NOT NULL UNIQUE
            \\);
        ;

        var diags = sqlite.Diagnostics{};
        var stmt_create = db.prepareWithDiags(query, .{ .diags = &diags }) catch |err| {
            std.log.err("unable to prepare statement, got error {}. diagnostics: {s}\n", .{ err, diags });
            std.log.debug("Deleting db...\n", .{});

            try std.fs.deleteFileAbsolute(db_path);

            return err;
        };
        defer stmt_create.deinit();

        try stmt_create.exec(.{}, .{});
    }

    // Couldn't bother to make it autoincrement
    const next_id_query =
        \\SELECT MAX(file_id)+1 FROM files;
    ;

    var diags = sqlite.Diagnostics{};
    var stmt2 = db.prepareWithDiags(next_id_query, .{ .diags = &diags }) catch |err| {
        std.log.err("unable to prepare statement, got error {}. diagnostics: {s}\n", .{ err, diags });
        return err;
    };
    defer stmt2.deinit();

    var next_id = try stmt2.one(
        u32,
        .{},
        .{},
    ) orelse 0;

    // For each argument...
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    for (args[1..]) |arg| {
        // Get the absolute path
        var p = try realpath(allocator, arg);
        defer allocator.free(p);

        // And try to insert it
        var stmt = try db.prepareWithDiags("INSERT INTO files(file_id, local_path) VALUES (?{u32}, ?{text});", .{ .diags = &diags });
        defer stmt.deinit();

        // The path is UNIQUE, so this could fail
        stmt.exec(.{}, .{ next_id, Text{ .data = p } }) catch |err| {
            std.log.err("Error while inserting file:\n\tError: {}\n\tDiags: {s}\n", .{ err, diags });
        };

        // Just for debugging
        std.debug.print("File inserted\n", .{});

        next_id += 1;
    }
}
