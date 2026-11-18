# Changelog

Server-side changes that matter to server owners and players. Newest first.

## 2026-11-18

- **Saw Ballista** rebuilt as Open Fortress has it (new plugin `tf2cc_saw`): it now rides on the
  stock rocket launcher, and its rocket becomes a saw blade that never explodes. The blade
  flies through players and buildings dealing 4 damage every 0.03 s (at most 200 per blade per
  target, slowed while inside someone), ricochets off walls without losing speed, can hurt its
  owner after the first bounce, and sticks in a wall after 6 bounces. Fire 0.4 s, one blade,
  1.2 s reload, 10 in reserve. `tf2cc_saw_*` cvars.
- **Quad Launcher** reload: the whole clip now reloads in 3.84 s, Open Fortress's 2.67 s times
  the item's reload multiplier 1.44 (was 2.9 s).

## 2026-11-17

- **Phlogistinator for the Mercenary:** burn damage fills the Mmmph meter (stock Pyro values),
  alt-fire at 100 % activates it, and a HUD meter shows the charge (`tf2cc_phlog*` cvars;
  `phlog_taunt` in roles.cfg).
- **Inspect-key pickups** are read from the inspect key itself
  (`OnClientCommandKeyValues` / `+inspect_server`), so swapping weapons with Inspect works
  for everyone.
- **Eternal Shotgun** (new): Open Fortress's Super Shotgun with the meat hook on alt-fire (new
  plugin `tf2cc_hook`). The hook latches onto enemy players and pulls the wielder in. Optional
  cvars add a stun, hold-to-reel and hooking the world.
- **Bouncer** (new): Open Fortress's ricocheting grenade launcher, with its own grenade model
  and impact sounds.
- **Quad Launcher** is handed out by default, with Open Fortress parity: four-rocket burst,
  homing toggle on alt-fire with a ping, and the blast radius growing with each rocket fired
  since the last reload.
- Voice: a chainsaw-charge yell set (`_chargeyell`) in voice.cfg.

## 2026-11-15

- Maps that run their own Mercenary are exempt from custom classes (exempt_maps.txt plus
  automatic VScript detection).
- The Mercenary keeps his ubercharge through weapon switches, taunts and resupply.
