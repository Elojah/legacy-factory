# Legacy Factory

An online 2D RPG (Golden-Sun-style) with **slow, real-time PvEvP combat** built in
**Godot 4.7 (GDScript)**. The defining feature is its netcode: an authoritative
dedicated server with **client-side prediction, server reconciliation, and entity
interpolation** (the Gabriel-Gambetta model).

The client and the server are the **same Godot project**, with the role selected
at launch — so the simulation code is shared, and prediction stays in lock-step
with authority.

## Status — Milestone 1 (combat prototype)

Working end-to-end:
- Headless authoritative server + clients connect over ENet/UDP.
- One predicted, server-reconciled player entity per client; remote entities
  interpolated.
- One slow real-time **melee ability** (windup → active → recovery → cooldown),
  client-predicted and **server-validated**, with damage applied authoritatively.
- Placeholder **AI monsters** that hunt and attack through the same simulation,
  giving the PvE/PvP shape.
- F3 network-debug overlay (ping, ticks, reconciliation error, etc.).

## Run it

Needs a Godot 4.7 binary (e.g. `/snap/bin/godot-4`).

```bash
# Terminal 1 — authoritative server (headless)
godot-4 --headless --path . -- --server --port 24565

# Terminal 2 & 3 — clients
godot-4 --path . -- --client --connect 127.0.0.1 --port 24565

# Test the netcode under poor conditions:
godot-4 --path . -- --client --connect 127.0.0.1 --port 24565 --lag 150 --jitter 40 --loss 0.05
```

Controls: **WASD/arrows** move, **J/Space** attack, **E/K** interact, **F3** toggles the debug overlay.

## Layout & conventions

See [`CLAUDE.md`](CLAUDE.md) for the architecture map, the authoritative-server
golden rules, the determinism requirements for `shared/`, and the netcode
conventions every change must follow.
