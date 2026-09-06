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
loadstring(game:HttpGet("https://raw.githubusercontent.com/HiddenProto/LimbReanimate/v1.9.0/src/LimbReanimate.lua"))()
```

Current release: **v1.9.0**

---

## The menu

Same options as Uhhhhhh's Limbs page.

| Control | What it does |
|---|---|
| `* Reanimate *` / `* Deanimate *` | Start / stop. Deanimate kills you once more so the server respawns you clean — except in **No Kill**, where it restores the body you already have. |
| Show Reanimate Hitboxes | Wireframes your real root part for 5 seconds. |
| Refresh Reanimate Character | Rebuilds the fake rig in place without deanimating. |
| **RootPart Mode** | Where the real root part gets parked. 5 options — see below. |
| **RootPart Velocity** | What velocity the parked root is given each frame. |
| **Init Mode** | How the character enters the reanimated state — including **No Kill**, which never kills you. |
| **Rig Source** | `Built-in` or `Origin Only` — see below. Built-in adapts to your rig type: hardcoded R6 skeleton on R6, auto-built skeleton on R15. |
| **Animate Fake Rig** | Plays your own character animations on the rig, which your real limbs then copy. On for Built-in; **forced off when Origin Only starts**, since that mode exists to hand the rig to your own script. The Animator is there either way. |
| Show me how I look! | Throttles joint writes to 10/s, so you see roughly what other players receive. |
| Target Fling Enabled | Lets `Fling()` queue targets. Touching a player takes network ownership of them. |
| Use NaN State Fling | Uses a NaN `MoveDirectionInternal` instead of a huge velocity to do the flinging. |
| Root Jitter | Nudges the root 0.005 studs on Z every frame so identical CFrames aren't dropped before replicating. **Default off** — it visibly shakes the torso. Turn it on only if a game is dropping your root writes. |
| **Hide Limbs** | Fold-out panel, one row per joint. Click to send that limb away; click again to bring it back. |

### Hide Limbs

A collapsible panel listing every joint the reanimate is actually driving,
**built from your real rig** — so it shows R6 names on an R6 character, R15
names on R15, and the full joint set in Origin Only. The head is just another
row in it.

Hiding a limb drives its joint to a hold position tens of thousands of studs
away instead of to the rig. It is deliberately **not** a deletion:

- nothing is destroyed and no joint is broken, so clicking again restores it
  instantly and exactly;
- the choice is keyed by joint name, so it survives a respawn and a
  re-reanimate;
- each limb gets its own deterministic hold spot, so the same limb always goes
  to the same place and they never pile up.

Hiding a parent takes its children with it — hiding `LeftUpperArm` on R15 takes
the lower arm and hand too, because they hang off it.

The **root entry is not listed**. Hiding it would take the entire body, which is
already what `RootPart Mode → RootPart in very void` does, properly. There is no
separate "hide HRP" switch for the same reason: that mode *is* it.

### Diagnostics

The menu shows live numbers while running:

```
your rig    : R15
rig source  : Skeleton (auto)
joints      : 14 driven, 0 pinned
your body   : 14 joints, Running
body health : 100/100   respawns: 1
root goes to: on rig torso  (y 4)
rig parts   : 15
root drift  : 1.84 now, 2.03 max
replicating : yes
```

`root goes to` is the RootPart Mode that is **actually being applied**, not the
one you picked. If those disagree, the mode is failing to resolve — that is
exactly how R15 used to end up at `y -70000` no matter what was selected.

Read `driven` against `your body`:

| What you see | What it means |
|---|---|
| `driven` matches `your body` | everything your character has is being posed |
| `0 driven`, healthy `your body` | the joints exist but were never matched — a mapping problem |
| **`your body : 0 joints`** | **the body is a corpse.** Death destroys Motor6Ds and they never come back. The root is still written, but every limb falls away — the character flashes into view and vanishes. Use `Init Mode → No Kill`, which never kills you |
| `respawns: 0` | the kill never produced a new character at all |

**Root drift** is the distance between where the root was written last frame and
where it actually is now. **~2 studs is the normal settle band.** Hundreds means
something is winning against the writes — the readout turns red past 50.

`joints: N driven` is how many of your real Motor6Ds are actually being posed.
`pinned` are ones with no mapping, held at identity. On R15 with the built-in R6
rig you would see only **6 driven, 8 pinned** — elbows, wrists, knees, ankles and the waist
have no R6 equivalent, so they stay at rest.

**Rig Source** and **Init Mode** apply on the next reanimate. Everything else is
read every frame and applies live.

### Rig Source

| | Built-in (R6 character) | Built-in (R15 character) | Origin Only |
|---|---|---|---|
| The rig is | a hardcoded R6 skeleton | a **skeleton auto-built from your rig** | a **clone of your character** |
| Mapping | conversion table | **identity** | **identity** |
| Part & joint names | R6 (`Torso`, `Left Arm`) | **your real ones** | **your real ones** |
| Proportions | generic R6 | your avatar's | your avatar's |
| Meshes / accessories | none | none | yes, cloned |
| Animator | yes | yes | yes |
| Built-in driver | on | on | **off** — the rig is yours |

Origin Only makes the rig **pass for a real character** — real part names, real
joint names, real proportions, a real Humanoid and a real Animator, plus your
actual meshes and accessories. An external animation script written against a
reanimated character can point at it and work, with no conversion to reason
about. Whatever you do to a rig joint happens to the matching real joint.

The auto skeleton gives you the same names and mapping without the meshes, so
prefer Origin Only when something needs to *look* like your character, and the
skeleton when you only need it to *move* like it.

### R15

**R15 is first class. Everything that works on R6 works on R15.**

The only thing that was ever R6-specific was the rig, and `Built-in` is no
longer R6-only — it picks by your rig type:

| Your character | Built-in gives you | Mapping |
|---|---|---|
| R6 | the hardcoded R6 skeleton | conversion table |
| R15 | a **skeleton auto-built from your own rig** | identity |

The auto skeleton is a plain-part copy of your rig's *structure* — same part
names, same sizes, same joints with the same `C0`/`C1`, and nothing else. No
meshes, no accessories, no clothing. Built from whatever rig you actually have,
so R6, R15 and custom rigs all work, and every joint is driven rather than the
6 an R6 rig could reach.

It is also cheaper and less fragile than cloning: no `Archivable` problem and
nothing to strip afterwards. If it ever fails it falls back to the origin clone,
and if that fails too the reanimate **stops** rather than driving your body at a
rig that cannot resolve — which would strand it in the void.

Everything else — RootPart Mode, Velocity, Init Mode, fling, the Hide Limbs
panel — was already rig-agnostic. The panel builds its list from your real
joints, so on R15 it lists all of them.

### Driving the rig yourself

Pose or animate the **rig**, never the real character — the joint loop
overwrites the real character's motors every frame from the rig, so anything
written there is gone before it can replicate.

```lua
local LR  = _G.LimbReanimate
local rig = LR.Reanimate.Character   -- the Model to drive

-- Origin Only already did this for you when it started. On the built-in R6
-- rig you have to turn the driver off yourself or it fights you.
LR.Reanimate.AnimateRig = false

-- Play your own animation on it, exactly like a real character.
local track = LR.Reanimate.Animator:LoadAnimation(someAnimation)
track:Play()

-- Or pose joints directly. Origin Only uses your real joint names:
rig.UpperTorso.RightShoulder.Transform = CFrame.Angles(0, 0, math.rad(-90))
-- Built-in R6 rig is always R6 names:
rig.Torso["Right Shoulder"].Transform = CFrame.Angles(0, 0, math.rad(-90))
```

Also exposed: `LR.Reanimate.IsOrigin`, `.Animator`, `.Tracks`
(`idle/walk/run/jump/fall/climb/sit`), `.RigParts`.

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
| **No Kill (in-place)** | Never kills you at all. See below. |

`CDSB` is patched on current clients and is only attempted at all if your
executor exposes `replicatesignal`. It is kept for parity with the original.

### No Kill (in-place)

**This is not the permadeath "no respawn" reanimate.** It is the opposite: you
never die at all.

The kill was never the mechanism. The mechanism is **animation authority** — the
`Animator` is what overwrites your joints, and breaking joints is incidental,
because this design drives `Motor6D.Transform` and keeps the assembly intact
either way. So the kill can be skipped: take authority from the body you already
have, and hand it back when you are done.

Reanimating in place:

1. No `ChangeState(Dead)`, no waiting on `CharacterAdded`.
2. Destroy the live character's `Animator`; **disable** its `Animate` script
   rather than destroying it, so it can be switched back on.
3. Everything else is identical — joints mapped, root parked, transforms driven.

Deanimating restores instead of killing:

1. Every joint it touched goes back to `CFrame.identity`.
2. The body comes back out of the void to wherever the rig was standing.
3. Every hook is disconnected — the `CanCollide` and `LocalScript` forcers, and
   the character's `DescendantAdded` watcher.
4. Original `CanCollide` values and `LocalScript` enabled states are put back
   from what was recorded on the way in.
5. A fresh `Animator` is created and `AutoRotate` restored, so the game animates
   you again.

You end up standing where you were, alive, in a character the game controls
normally — no death, no respawn, no lost tools or state.

The trade-off: your body was never actually loosened, so anything that depends
on the server having broken your joints will not behave the same. And any game
script that re-creates the `Animator` will take you straight back, with no
respawn to clear it.

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
