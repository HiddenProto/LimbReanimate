# How the reanimate works

## The problem it solves

Roblox gives your client authority over your own character's physics — you own
the network for your parts, so the CFrames you write for them are believed. It
does **not** give you authority over your character's *animation*. An `Animator`
sits on your Humanoid and overwrites every joint every frame from whatever
animation tracks the game is playing. Anything you write to a joint is gone one
frame later.

A reanimate takes the animation authority away.

---

## The five steps

### 1. Die

The script forces your Humanoid into the `Dead` state:

```
Humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, true)
Humanoid:ChangeState(Enum.HumanoidStateType.Dead)
```

The client is allowed to declare its own death, and the server believes it. The
server breaks the joints on the corpse and queues a respawn. That is the "kill"
half of kill-and-respawn.

### 2. Respawn, and gut the new character

`CharacterAdded` fires. Before anything else runs on it, the script:

- **destroys the `Animator`.** This is the single most important line in the
  file. Leave it and it will overwrite every joint you write, one frame at a
  time, and it will win.
- destroys the `Animate` LocalScript so a new Animator is not created.
- disables every other `LocalScript` in the character, and re-disables them if
  the game turns them back on.
- forces `CanCollide = false` on every part, and re-forces it on change.
- walks every `Motor6D` and matches it against the limb map by
  `(Part0.Name, Part1.Name)`. Anything that matches gets remembered. Anything
  that does not gets pinned to identity so it cannot drift on its own.

The camera is also snapped back to where it was before the respawn, in
`PreRender`, so the respawn is not visible as a camera jolt.

Not every game can be reanimated. Games that recreate the Animator
automatically — most "modern" ones do — will keep fighting you. That is not a
bug in the script; it is the limit of the technique.

### 3. Build a fake rig

The script creates a plain R6 model **locally**: a Humanoid, six invisible
parts, six `Motor6D` joints, a hidden ForceField. It is client-only — no other
player will ever see it, and the server does not know it exists.

This rig is what you actually walk around as. Movement comes off the stock
`PlayerModule` ControlModule (`Controls:GetMoveVector()`), so keyboard, gamepad
and the mobile thumbstick all work, and `Camera.CameraSubject` is pointed at the
rig's Humanoid every frame.

The rig's part CFrames are the **source poses**. Your real limbs are going to be
driven to match them.

### 4. Park the real root part in the void

Your real character is still there, still yours, and now has loose joints. The
script picks a spot for its `HumanoidRootPart` — by default Y ≈ −70,000 with
random X/Z out to ±65,536 — and writes the root there every frame.

Two details make that possible:

- **`workspace.FallenPartsDestroyHeight = 0/0`**, re-applied every frame. A part
  cannot sit below the destroy plane; NaN'ing the plane means there is no plane.
  The original value is cached *before* the first NaN write, because anything
  read back afterwards is also NaN, and it is restored on unload.
- **`Player.ReplicationFocus = workspace`**, so a root that far from your camera
  still replicates instead of being culled.

The X/Z randomisation exists so two people running this in the same server do
not park their roots on top of each other.

Also every frame: `Humanoid:ChangeState(Freefall)` and `AutoRotate = false`, so
the server does not run walk/land logic that would try to correct the root.

### 5. Drive the real joints from the fake rig

This is the actual trick.

`Motor6D.Transform` is an **unbounded** relative CFrame. The engine never clamps
it, never sanity-checks its magnitude. For each mapped joint the script computes
where the corresponding rig part is, relative to the joint's Part0, and writes
that:

```
cf = p0.CFrame:ToObjectSpace(p1.CFrame)     -- R6
motor.Transform = motor.C0:Inverse() * cf * motor.C1
```

For the **root joint** specifically, `Part0` is your real root part — 70,000
studs down in the void — and `Part1` is the fake rig's torso, standing where you
appear to be. So that one joint's transform is ~70,000 studs long, and it
absorbs the entire void offset by itself. Every other joint hangs off the torso
normally.

That is why the character stays **one intact assembly** the whole time. Nothing
is unwelded, nothing is shattered into sockets — the root joint just does an
enormous amount of work.

`motor.MaxVelocity = 9e9` is set on every write so the motor snaps across that
gap instead of interpolating toward it over several frames.

### Making other players see it

Writing `Motor6D.Transform` only drives the joint on your own client. What
replicates are two hidden properties the engine uses internally for Motor6D
replication:

```
ReplicateCurrentOffset6D   -- the positional half of the transform
ReplicateCurrentAngle6D    -- the rotational half, as axis * angle
```

Those need `sethiddenproperty` (or `setscriptable`), which is why an executor is
required. Without it the script falls back to writing `Transform` directly — you
see the reanimate, nobody else does, and the menu warns you.

The write happens **twice per frame**: once in `PreSimulation` (after
`Heartbeat`), and again in `PreRender`, after animation and immediately before
the draw — so the pose you are looking at is the pose that was sent.

---

## The smaller mechanisms

**Root jitter.** Each root write adds `math.random(0,1) * 0.005` on Z. The
replicator can drop a CFrame identical to the last one as "no change", and the
nudge guarantees it is never identical. The cost is that the torso — and
everything Motor6D-jointed to it — shakes slightly every frame. It is a toggle
here for that reason; the original hardcodes it on.

**`IsGrounded()`.** The root write is skipped when the root part is grounded
(welded into an anchored assembly), because a grounded part cannot be moved and
writing it just spams the physics solver. This gates the root only — the joint
loop still runs, so you keep animating while seated or welded.

**Streaming.** When `workspace.StreamingEnabled` is true, RootPart Mode is
forced to *Keep RootPart Streamed* regardless of what you picked. A part parked
70,000 studs away unstreams, and once it unstreams your writes stop landing.

**Placeholder transparency.** The rig's own parts are invisible while the real
limbs are following. If the reanimate is not working, they show at 0.5 instead —
so a broken reanimate looks broken rather than looking like nothing happened.

**Tools.** Your real Tool stays on the real, puppeted character. A stand-in
`faketool` is welded to the rig's right arm to carry the grip, the tool
animations and the touch events; `firetouchinterest` forwards touches from the
stand-in's handle to the real one.

---

## Flinging

With **Target Fling Enabled**, `LimbReanimate.LimbReanimator.Fling(target)`
queues a target. While a fling is active the joint loop pins every joint to
identity and the root is thrown at the target's predicted position instead of
its parked one.

The prediction leads the target by its own `AssemblyLinearVelocity` plus a
gravity term, so the root meets it rather than trailing it. Two flavours:

- **default** — root gets a huge velocity (`0, -16384, 0` linear and `16384`
  angular). Ordinary contact fling.
- **NaN State Fling** — root velocity is zeroed and the humanoid's hidden
  `MoveDirectionInternal` is set to `NaN, NaN, NaN` instead. The server's
  humanoid solver produces garbage from that, and the garbage is what flings.

Touching a player with the parked root takes network ownership of them away.

---

## What was deliberately not ported

From the original Uhhhhhh script:

- **The Pusher WebSocket backdoor.** The original connects to a Pusher channel
  and `loadstring`s whatever arrives on a `jumpscare` event, with full executor
  privileges. Anyone controlling that channel could run arbitrary code on every
  user of the script. Gone.
- **The disk-fingerprinting gag** that reads unrelated files to detect which
  other exploit scripts you have used.
- **The remote module loader** that pulls movesets and dances from GitHub at
  runtime and executes them unverified.
- **HatReanimator**, movesets, dances, the keybind system, the asset pipeline
  and the original's ~1700-line UI toolkit — none of it is limb reanimation.
- **`InternalBodyScale = 9e9`** and the original's death sequence, which exist
  to stop the server correcting a *dead* humanoid and are not needed here.
