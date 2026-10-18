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
pub const desktop_bg: u32 = 0x2e3440;
pub const accent: u32 = 0x88c0d0;
pub const fg: u32 = 0xd8dee9;
pub const fg_bright: u32 = 0xeceff4;
pub const fg_dim: u32 = 0xa9b3c6;
pub const terminal = "xterm";

// Claude Code in a fresh terminal, rooted at ~/Proyectos. (claude lives in ~/.local/bin, which a
// display-manager session does not always have on PATH.)
pub const claude_cmd = "xterm -T claude -e sh -c 'cd \"$HOME/Proyectos\" 2>/dev/null; PATH=\"$HOME/.local/bin:$PATH\" exec claude'";

// Animation. Frames are paced at anim_hz while something moves (idle = no wakeups).
// The k values are decay rates in 1/s: larger = snappier (95% of the way in ~3/k s).
pub const anim_hz: i64 = 144;
pub const k_window: f32 = 26;
pub const k_workspace: f32 = 22;
pub const k_pill: f32 = 32;
pub const k_panel: f32 = 24;
pub const k_toast: f32 = 26;
pub const k_launcher: f32 = 30;

pub const Dir4 = enum { left, up, right, down };
pub const workspaces = 5;

pub const Action = enum { spawn_terminal, close, quit, focus, swap, resize, workspace, send_to, toggle_panel, music_toggle, music_next, music_prev, volume, launcher, spawn };

// Extra modifier bits on top of mod_mask.
const shift: u16 = 1;
const alt: u16 = 8;

// `mod = false` grabs the key without the Super modifier (media keys). `cmd` is for .volume.
pub const Bind = struct { extra: u16 = 0, mod: bool = true, keysym: u32, action: Action, dir: Dir4 = .left, n: u8 = 0, cmd: [*:0]const u8 = "" };

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
    .{ .keysym = 'c', .action = .spawn, .cmd = claude_cmd }, // Super+C: new Claude session
    .{ .keysym = ' ', .action = .toggle_panel },
    .{ .mod = false, .extra = alt, .keysym = ' ', .action = .launcher }, // Alt+Space

    // Media keys (no modifier): XF86Audio{Mute,LowerVolume,RaiseVolume,Prev,Play,Next}.
    .{ .mod = false, .keysym = 0x1008ff12, .action = .volume, .cmd = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle" },
    .{ .mod = false, .keysym = 0x1008ff11, .action = .volume, .cmd = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-" },
    .{ .mod = false, .keysym = 0x1008ff13, .action = .volume, .cmd = "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+" },
    .{ .mod = false, .keysym = 0x1008ff16, .action = .music_prev },
    .{ .mod = false, .keysym = 0x1008ff14, .action = .music_toggle },
    .{ .mod = false, .keysym = 0x1008ff17, .action = .music_next },
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
