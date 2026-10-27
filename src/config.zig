// Compile-time config. Edit and rebuild.

pub const mod_mask: u16 = 64; // Super. (8 = Alt)
pub const gap: u16 = 6;
pub const border: u16 = 2;
pub const border_focus: u32 = 0x4796d9; // ok: bright blue
pub const border_normal: u32 = 0x636c7e; // ok: black / dark gray
pub const resize_step: f32 = 0.03;

// Bar. Height + gap above is reserved at the top of the screen.
pub const bar_h: u16 = 32;
pub const bar_radius: u16 = 10;
pub const bar_bg: u32 = 0x161a22; // ok bg lifted a step, so the bar reads as a surface
pub const desktop_bg: u32 = 0x0b0d10; // ok: background
pub const accent: u32 = 0x4796d9; // ok: bright blue
pub const fg: u32 = 0xb5cdbd; // ok: gray
pub const fg_bright: u32 = 0xd2daf4; // ok: white
pub const fg_dim: u32 = 0x636c7e; // ok: dark gray
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

// Synced lyrics on the desktop (from lrclib.net, cached in ~/.cache/zwm/lyrics). Turning it off
// stops the lookups: the song's title and artist are sent to lrclib to find its lyrics.
pub const lyrics: bool = true;
pub const lyrics_lead_ms: i64 = 200; // show each line this early: Spotify's position is already stale when it arrives
pub const k_lyrics: f32 = 11; // scroll spring stiffness (1/s): larger = snappier, ~0.4 s to settle at 11

pub const Dir4 = enum { left, up, right, down };
pub const workspaces = 5;

pub const Action = enum { spawn_terminal, close, quit, focus, swap, resize, workspace, send_to, toggle_panel, music_toggle, music_next, music_prev, volume, brightness, launcher, lock, spawn };

// Extra modifier bits on top of mod_mask.
const shift: u16 = 1;
const alt: u16 = 8;

// `mod = false` grabs the key without the Super modifier (media keys). `cmd` is the shell command for .volume and .spawn.
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
    .{ .keysym = 'l', .action = .lock }, // Super+L: lock screen (password)

    // Media keys (no modifier): XF86Audio{Mute,LowerVolume,RaiseVolume,Prev,Play,Next}.
    .{ .mod = false, .keysym = 0x1008ff12, .action = .volume, .cmd = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle" },
    .{ .mod = false, .keysym = 0x1008ff11, .action = .volume, .cmd = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-" },
    .{ .mod = false, .keysym = 0x1008ff13, .action = .volume, .cmd = "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+" },
    .{ .mod = false, .keysym = 0x1008ff16, .action = .music_prev },
    .{ .mod = false, .keysym = 0x1008ff14, .action = .music_toggle },
    .{ .mod = false, .keysym = 0x1008ff17, .action = .music_next },
    // Brightness keys
    .{ .mod = false, .keysym = 0x1008ff02, .action = .brightness, .cmd = "brightnessctl set +5%" },  // XF86KbdBrightnessUp
    .{ .mod = false, .keysym = 0x1008ff03, .action = .brightness, .cmd = "brightnessctl set 5%-" },  // XF86KbdBrightnessDown
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
