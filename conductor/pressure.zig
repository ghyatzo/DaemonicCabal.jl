// SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
// SPDX-License-Identifier: MPL-2.0
//
// Host memory-pressure monitor for pressure-reactive worker caching. Resolves
// the best available signal once at startup (PSI stall where present, else the
// always-available free-memory level) and applies two-band hysteresis so a host
// hovering at the threshold doesn't flap in and out of eviction episodes.

const std = @import("std");
const platform = @import("platform/main.zig");
const config = @import("config.zig");

pub const Source = enum { psi, memfree, none };

pub const Monitor = struct {
    source: Source,
    under_pressure: bool = false,

    /// Resolve the active source (silently; call logResolution to report it).
    pub fn init(cfg: *const config.Config) Monitor {
        if (!cfg.memory_pressure) return .{ .source = .none };
        const source: Source = if (platform.readPsiSomeAvg10() != null)
            .psi
        else if (platform.readMemInfo() != null)
            .memfree
        else
            .none;
        return .{ .source = source };
    }

    /// Three-state startup report: which source resolved, the normal
    /// PSI-absent-but-level-OK case, or the loud no-signal warning.
    pub fn logResolution(self: *const Monitor, cfg: *const config.Config) void {
        if (!cfg.memory_pressure) {
            std.debug.print(" - Memory pressure: disabled (TTL-only)\n", .{});
            return;
        }
        switch (self.source) {
            .psi => std.debug.print(" - Memory pressure: PSI /proc/pressure/memory, some avg10 >= {d}%\n", .{cfg.psi_threshold}),
            .memfree => std.debug.print(" - Memory pressure: free-memory level (PSI unavailable, normal on stock Linux)\n", .{}),
            .none => std.debug.print(" - Memory pressure: no readable signal on this platform; running TTL-only\n", .{}),
        }
    }

    pub fn active(self: *const Monitor) bool {
        return self.source != .none;
    }

    /// Re-read the signal once and update the hysteresis state: enter pressure
    /// past the "low" band, leave only once recovered past the "high" band.
    pub fn poll(self: *Monitor, cfg: *const config.Config) bool {
        switch (self.source) {
            // PSI rises with pressure; single threshold, no hysteresis gap (the
            // 10s average is already smooth).
            .psi => self.under_pressure = (platform.readPsiSomeAvg10() orelse 0) >= cfg.psi_threshold,
            .memfree => if (platform.readMemInfo()) |m| {
                if (cfg.memfree_low.satisfied(m.available, m.total))
                    self.under_pressure = true
                else if (!cfg.memfree_high.satisfied(m.available, m.total))
                    self.under_pressure = false;
            },
            .none => {},
        }
        return self.under_pressure;
    }
};
