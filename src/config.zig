// Compile-time config. Edit and rebuild.

pub const mod_mask: u16 = 64; // Super. (8 = Alt)
pub const gap: u16 = 6;
pub const border: u16 = 2;
pub const border_focus: u32 = 0x88c0d0;
pub const border_normal: u32 = 0x3b4252;
pub const resize_step: f32 = 0.03;

// Bar. Height + gap above is reserved at the top of the screen.
pub const bar_h: u16 = 32;
pub const bar_radius: u16 = 10;
pub const bar_bg: u32 = 0x3b4252;
pub const accent: u32 = 0x88c0d0;
pub const fg: u32 = 0xd8dee9;
pub const fg_bright: u32 = 0xeceff4;
pub const fg_dim: u32 = 0xa9b3c6;
pub const terminal = "xterm";

pub const Dir4 = enum { left, up, right, down };
pub const workspaces = 5;

pub const Action = enum { spawn_terminal, close, quit, focus, swap, resize, workspace, send_to };

// Extra modifier bits on top of mod_mask.
const shift: u16 = 1;
const alt: u16 = 8;

pub const Bind = struct { extra: u16 = 0, keysym: u32, action: Action, dir: Dir4 = .left, n: u8 = 0 };

const left = 0xff51;
const up = 0xff52;
const right = 0xff53;
const down = 0xff54;

fn wsBinds(extra: u16, action: Action) [workspaces]Bind {
    var out: [workspaces]Bind = undefined;
    for (&out, 0..) |*b, i| b.* = .{ .extra = extra, .keysym = '1' + i, .action = action, .n = i };
    return out;
}

pub const binds = base ++ wsBinds(0, .workspace) ++ wsBinds(shift, .send_to);

const base = [_]Bind{
    .{ .keysym = 0xff0d, .action = .spawn_terminal }, // Return
    .{ .keysym = 'q', .action = .close },
    .{ .extra = shift, .keysym = 'e', .action = .quit },

    .{ .keysym = left, .action = .focus, .dir = .left },
    .{ .keysym = up, .action = .focus, .dir = .up },
    .{ .keysym = right, .action = .focus, .dir = .right },
    .{ .keysym = down, .action = .focus, .dir = .down },

    .{ .extra = shift, .keysym = left, .action = .swap, .dir = .left },
    .{ .extra = shift, .keysym = up, .action = .swap, .dir = .up },
    .{ .extra = shift, .keysym = right, .action = .swap, .dir = .right },
    .{ .extra = shift, .keysym = down, .action = .swap, .dir = .down },

    .{ .extra = alt, .keysym = left, .action = .resize, .dir = .left },
    .{ .extra = alt, .keysym = up, .action = .resize, .dir = .up },
    .{ .extra = alt, .keysym = right, .action = .resize, .dir = .right },
    .{ .extra = alt, .keysym = down, .action = .resize, .dir = .down },
};
