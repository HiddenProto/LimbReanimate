# LimbReanimate

A standalone Roblox **limb reanimator**. It kills your character, lets the server
respawn it, then puppets the respawned limbs from an invisible client-side rig you
actually walk around as.

The limb-reanimation logic is lifted from the `LimbReanimator` section of the
**Uhhhhhh** script by STEVETHEREALONE. Nothing else came with it — no hat
reanimator, no movesets, no dances, no auto-updating remote module loader, and
none of the Pusher WebSocket code that let the original's author run arbitrary
Lua on anyone who executed it. This repo is the reanimate and nothing else.

Requires an executor with `sethiddenproperty` (or `setscriptable`). Without one
the rig still drives your limbs locally, but nobody else sees it — the script
says so in the menu.

---

## Load

**Always-latest.** Paste this once. It never changes, and it pulls the newest
build every execute (with a cache-buster, so a push is live immediately):

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/HiddenProto/LimbReanimate/main/loader.lua"))()
```

**Pinned to a release.** This one is frozen at an exact tag — it will never
change under you. A new one is published with every update:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/HiddenProto/LimbReanimate/v1.0.0/src/LimbReanimate.lua"))()
```

Current release: **v1.0.0**

---

## The menu

Same options as Uhhhhhh's Limbs page.

| Control | What it does |
|---|---|
| `* Reanimate *` / `* Deanimate *` | Start / stop. Deanimate kills you once more so the server respawns you clean. |
| Show Reanimate Hitboxes | Wireframes your real root part for 5 seconds. |
| Refresh Reanimate Character | Rebuilds the fake rig in place without deanimating. |
| **RootPart Mode** | Where the real root part gets parked. 5 options — see below. |
| **RootPart Velocity** | What velocity the parked root is given each frame. |
| **Init Mode** | How the character is killed to enter the loose-limb state. |
| Show me how I look! | Throttles joint writes to 10/s, so you see roughly what other players receive. |
| Target Fling Enabled | Lets `Fling()` queue targets. Touching a player takes network ownership of them. |
| Use NaN State Fling | Uses a NaN `MoveDirectionInternal` instead of a huge velocity to do the flinging. |
| Root Jitter | Nudges the root 0.005 studs on Z every frame so identical CFrames aren't dropped before replicating. Off = steadier torso. |

**Settings apply on the next reanimate**, not the current one.

### RootPart Mode

| Mode | Root goes | Notes |
|---|---|---|
| RootPart in very void | Y ≈ −70000, random X/Z ±65536 | Default. Furthest from anything. |
| RootPart in void | Just under `FallenPartsDestroyHeight`, random X/Z ±2048 | Only works because the destroy plane is NaN'd. |
| Keep RootPart Streamed | 16 studs under the rig | **Forced automatically when the game has StreamingEnabled** — a root 70k studs away unstreams and the writes stop landing. |
| CurrentAngle Style | Exactly on the rig's root | Root joint transform is ~0. |
| RootPart is Torso | Exactly on the rig's torso | Most interpolated / smoothest to others, least hidden. |

### Init Mode

| Mode | What it does |
|---|---|
| Reset Character | `Humanoid.Health = 0`, then the Dead state change. |
| CDSB + Reset | Fires `Player.ConnectDiedSignalBackend` first, then the above. |
| CDSB + SSE + Kill | CDSB, then `SetStateEnabled(Dead, true)` + `ChangeState(Dead)`. Default. |

`CDSB` is patched on current clients and is only attempted at all if your
executor exposes `replicatesignal`. It is kept for parity with the original.

---

## The GUI

- Square. There is not one `UICorner` in the file.
- **Move** it by dragging the title bar.
- **Collapse** it with `-` — it folds to just the title bar; `+` unfolds it.
- **Remove** it with `X` — that fully unloads: deanimates, destroys the rig,
  restores `FallenPartsDestroyHeight`, disconnects every hook and clears
  `_G.LimbReanimate`.
- `RightControl` hides and shows the window without unloading.

Re-executing the script unloads the previous instance first, so you never end up
with two.

---

## How it works

See **[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md)** for the mechanism.

---

## Layout

```
loader.lua              evergreen bootstrap (always-latest loadstring points here)
src/LimbReanimate.lua   the whole script, single file, no dependencies
tools/syntaxcheck.luau  Lune compile gate; nothing ships that does not compile
docs/HOW-IT-WORKS.md    the mechanism, written out
```

## Credit

Limb-reanimation technique: **STEVETHEREALONE** (Uhhhhhh). This is a
reimplementation of that one subsystem with its own UI, control layer and
packaging.
