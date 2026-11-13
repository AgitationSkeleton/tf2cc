# How tf2cc works

tf2cc is eight SourceMod plugins plus a small fork of Classic Movement. It runs
entirely on the server: players use an unmodified TF2 client and only download content
files.

| Plugin | Job |
|---|---|
| `tf2cc_core` | Roles, class menu, spawning as class 10, health/speed, limits, map-mode rules, downloads |
| `tf2cc_weapons` | Weapons: donors, models, stats, ammo, sounds, inventory, pickups, drops, model variants |
| `tf2cc_specials` | Weapon behaviours stock TF2 has no equivalent for |
| `tf2cc_civilian` | Civilian aura, umbrella boost, capture value |
| `tf2cc_voice` | Voice lines, voice menu, Spy callouts, stock-class lines about the roles |
| `tf2cc_taunts` | Taunts and the Bond taunt kill |
| `tf2cc_movement` | Bunny-hop and jump vocals |
| `tf2cc_hud` | Item meters (recharge, rage, charge) |
| `classicmovement` (fork) | Quake-style air movement for the roles chosen by `cm_scope` |

The plugins talk to each other through natives and forwards declared in
`scripting/include/tf2cc.inc`. Only `tf2cc_core` decides who is which role; every other
module asks it.

## 1. Becoming a Mercenary or Civilian

Stock TF2 has a tenth class, `TF_CLASS_CIVILIAN`, that the game never offers. It
still works as a player class: health, speed, model, hands. tf2cc uses it as a blank
slate for both roles.

- **Spawning as class 10.** The game refuses class 10 from the class menu. tf2cc hooks
  `CTFPlayer::ForceRespawn` with DHooks, using the offset from SourceMod's own
  `sm-tf2.games` gamedata. Inside that one call it sets the player's desired class
  to 10, so the game runs its full, native class change. Straight after, it puts a
  normal class number back.
- **Keeping clients from crashing.** Several client screens read past the end of their
  9-class tables when they see class 10: the loadout panel, scoreboard icons and team
  status. tf2cc never lets class 10 reach them. The desired class on the wire is
  always a stock class (`tf2cc_safe_desired_class`). The scoreboard class in the player
  resource is rewritten to 0 (no icon).
- **The role on top.** Once spawned, the role's model is set with
  `SetCustomModel` (using the normal class animations), and its health and speed are
  applied as attributes. Its weapons, voice and abilities follow.
- **Mode rules.** Roles are kept off teams where they'd break a game mode: Mann vs.
  Machine robots, the boss in VSH/FF2, and the VIP on VIP/hunted maps.

## 2. Weapons

### Donors

TF2 can only run weapon logic it already has. So every Open Fortress or TF2 Classic
weapon is built on a **donor**: a real stock weapon whose slot, firing method and
animation family match the original. The Shotgun uses the Soldier's shotgun, the
Gatling the minigun, the Railgun a sniper rifle, and so on. At startup, tf2cc checks
every donor against the game's `items_game.txt` (`sm_tf2cc_weapons` shows the result).

On top of the donor:

- **Stats** come from TF2 attributes (damage, fire rate, clip, reload, spread) tuned to
  the Open Fortress / TF2 Classic values. `tf2cc_weapon_profile marxvee` switches to
  the legacy MarxVee tuning instead.
- **First person:**
  - The weapon's networked custom-viewmodel index points at the original Open Fortress
    or TF2 Classic viewmodel. The client's own prediction picks it up, so there's no
    flicker.
  - Those viewmodels name their animations by *their* weapon type, but TF2 asks for
    animations by the *donor's* type (the item's animation slot). tf2cc's build
    tools therefore ship copies of each viewmodel with its animations renamed for its
    donor (`models/weapons/tf2cc_<rev>/`).
  - The role's arms are attached on top.
  - The donor's own stock model is suppressed with the weapon's "repurposed" flag.
- **Third person:** the donor is hidden, and the Open Fortress / TF2 Classic world model
  is attached to the player as a wearable.
- **Sounds:**
  - Each weapon lists stock samples to replace with its own; a sound hook swaps them for
    everyone.
  - The shooter's game plays the stock sound itself, through client prediction, so
    tf2cc also sends the replacement to the shooter with the same channel, level and
    pitch (`tf2cc_owner_weapon_sounds`).
  - Weapons whose sounds the client generates on its own (the minigun's spin loops) get
    their Open Fortress sounds driven from the weapon's state instead.

### Ammo

Class 10 has no ammo of its own in TF2, so tf2cc keeps a reserve for each weapon slot.
It swaps that reserve in and out when two weapons share an ammo type. It also clamps
the reserve to the weapon's own maximum, because dispensers, resupply and ammo packs
would otherwise fill it to the class-10 limit.

### Inventory, pickups and drops (Mercenary)

- One record per slot (primary, secondary, melee) is the single source of truth.
- Weapons drop on death as floor pickups.
- Touching a weapon picks it up when its slot is empty; **Use** or **Inspect** swaps.
- A second Pistol becomes Akimbo Pistols.
- Losing your melee falls back to Fists.
- Weapons that any stock class dropped can be picked up too. The item is looked up in
  the schema and given to the Mercenary as a real stock weapon. Stock shotguns show the
  Mercenary's shotgun viewmodel.
- Map ammo packs can roll a random weapon by rarity tier and put it on the floor (the
  MarxVee rule).
- Resupply restores the spawn loadout.
- Bots use all of this too.

### Third-person animation: model variants

TF2 picks a player's third-person animation set from the held weapon's *slot type*.
That gives about ten stock groups, while Open Fortress has a distinct set per weapon.
tf2cc ships several copies of the Mercenary model (`models/player/tf2cc/variants_<rev>/`).
In each copy, the stock groups map to a different set of Open Fortress animations,
and the player's model is swapped to the right copy when they switch weapons.
`tf2cc_model_variants 0` turns this off.

### Special behaviours (`tf2cc_specials`)

| Weapon | What the plugin adds |
|---|---|
| Chainsaw | Open Fortress's hold-to-saw: a 1 s wind-up, then 12 damage every 0.05 s at 100 units, with wind-up, loop and wind-down sounds and animations. Alt-fire charges (crit-boosted, 8 s recharge, no Demoman scream). |
| Gatling Gun | Open Fortress wind-up, fire and wind-down sounds following the minigun's state |
| Dynamite, G.I.B. | Bomblets scattered on explosion. Dynamite explodes on impact. The G.I.B. uses energy-blast effects. |
| Nailgun | Nail projectile model |
| Lightning Gun | Continuous beam: hit detection, damage, beam effect |
| Saw Ballista | The blade keeps grinding a target it hits |
| Medkit, Cash Wad, Grappling Hook, Hoarder's Stash | MarxVee extras (disabled by default) |

## 3. Civilian (`tf2cc_civilian`)

Recreated from TF2 Classic's code and class data:

- **Aura:** pulses every second within 450 units. Buffed teammates take 0.8× damage and
  regenerate health; the Civilian regenerates too.
- **Umbrella boost:** alt-fire on a teammate gives 8 s of mini-crits, with a 16 s
  cooldown. It plays TF2 Classic's boost sound and both players' lines.
- **Captures:** a Civilian counts as 5 players on control points.
- **Bots:** Civilian bots boost the teammates they look at.

## 4. Voice (`tf2cc_voice`)

The Mercenary and Civilian lines come from Open Fortress and TF2 Classic. They play on
the voice channel, so mouths move: the files carry phoneme data. Lines play for:

- the voice menu;
- pain, death, being set on fire, dominations and revenge;
- captures and flag pickups;
- respawns (Open Fortress's 30% rule, with a different set after a death);
- taunts.

**Spy callouts:** "Spy!" names the class the spotted spy is disguised as. The line set
follows TF2 Classic's mapping, plus Mercenary lines for spies disguised as a
Mercenary. Stock classes also get the Open Fortress lines for calling out or
dominating a Mercenary.

Any stock-class voice line the game still triggers for a class-10 player is either
replaced by the role's own line for the same situation or muted. That covers death
screams and automatic lines.

## 5. Taunts (`tf2cc_taunts`)

- **Which taunt:** taunts are picked the way Open Fortress picks them, by the held
  weapon. The Civilian uses TF2 Classic's umbrella taunt, plus a Halloween one.
- **How it plays:** the player model itself plays the taunt animation, through the
  game's custom-sequence animation event. Eyes, face and lip-sync stay intact. The
  player is held in place in the third-person taunt camera and can't attack.
- **Sounds and effects:** taunt sounds and effects defined by Open Fortress / TF2
  Classic play at their original times.
- **Bond taunt kill:** 1.6 s into the Mercenary's pistol (Bond) taunt, a 500-damage shot
  goes 500 units along the player's aim, exactly as in Open Fortress.

## 6. Movement

`tf2cc_movement` gives the Mercenary Open Fortress's hold-to-bunny-hop and jump vocals.
The bundled Classic Movement fork adds Quake-style air control. It's limited by
`cm_scope` to the Mercenary by default, the Open Fortress behaviour. Fall damage is off
for roles with `fall_damage 0`, and for anyone listed in `tf2cc_no_fall_damage`.

## Clean-room rebuild of the MarxVee setup

### What existed

In 2022–2023, MarxVee ran a "Custom Classes" setup on TF2 servers made of these parts:

- `customclasses` (the class framework);
- `bethemercnew` and `bethecivilian` (the two classes);
- Custom Weapons 3 with MarxVee's attribute modules;
- a viewmodel applicator, Classic Movement and a taunt plugin.

It relied on 32-bit-only native extensions and on TF2Items. TF2's move to 64-bit
servers broke it. **Its source code was never released.** Only the compiled `.smx`
plugins, their configuration files and the asset pack remained.

### How its behaviour was recovered

No MarxVee code was available to copy, and none was copied. The behaviour was
documented from four kinds of evidence:

1. **Compiled plugin string tables and native-import lists.** These show which game
   properties, commands, cvars, sounds, models and natives each plugin used. For
   example, they show the inspect-key pickup prompts, the Akimbo upgrade, the
   ammo-pack rarity tiers and the Fists fallback.
2. **The shipped configuration files:** class definitions, the weapon lists with
   their donors and attributes, and the voice-pack mappings. These are data, not code.
   The curated voice-line lists and weapon choices were carried over as data.
3. **Decompiler output**, read only as a description of what the plugins did, for
   example the ammo-pack drop chances or how arms models were attached. Decompiled
   code was never pasted or translated into tf2cc.
4. **Watching the old setup** being played.

Every tf2cc system was then written from scratch. Wherever possible, it's based on
the *original games* rather than on MarxVee's approximations:

- the TF2 source code (2025 SDK) for how the engine behaves;
- the Open Fortress source code and game data for the Mercenary: weapon stats,
  chainsaw, taunts, bunny-hop, voice rules;
- TF2 Classic's code and data for the Civilian: aura numbers, boost, capture value,
  voice mapping.

Where MarxVee's tuning differed, both are kept, and `tf2cc_weapon_profile` chooses
between them.

### What's different underneath

| MarxVee setup | tf2cc |
|---|---|
| 32-bit native extensions (class proxy, TF2Items) | None. DHooks and SDK tools only, 64-bit ready |
| Custom gamedata with signatures | No gamedata of its own; uses SourceMod's maintained `sm-tf2.games` |
| Weapons created through TF2Items | Plain entities, networked properties, TF2Attributes |
| Class-10 desired class sent to clients (client crashes) | Class 10 confined to one engine call; clients only ever see stock classes |
| Viewmodels via bonemerged wearables | The engine's own predicted custom-viewmodel slot, with retargeted models |
| One third-person animation set | Per-weapon Open Fortress animation sets (model variants) |
| Taunts via a scene/class spoof | The player model plays the sequence itself |

### What *is* reused

The **assets**: MarxVee's asset pack (the Mercenary and Civilian models, arms, weapon
models, textures and sounds), most of which came from Open Fortress and TF2 Classic,
plus further Open Fortress and TF2 Classic files tf2cc needed. Some are modified, for
example animations re-labelled or texture shaders made stock-compatible. Credits are in
[CREDITS.md](../CREDITS.md).
