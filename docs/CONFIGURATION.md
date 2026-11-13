# Configuration files

All tf2cc config files are in `tf/addons/sourcemod/configs/tf2cc/`. They use SourceMod's
KeyValues format (`"key" "value"`, `{ }` blocks, `//` comments), and each one documents
its keys in a comment at the top. After editing, change map or use the reload command
listed below. Server cvars are covered separately in [CVARS.md](CVARS.md).

| File | Controls | Reload without map change |
|---|---|---|
| `roles.cfg` | The roles themselves: name, model, health, speed, loadout, taunts, limits | `sm_tf2cc_reload` |
| `weapons.cfg` | Every weapon: donor, stats, models, sounds, special behaviour | change map |
| `voice.cfg` | Voice lines per persona and per situation | `sm_tf2cc_voice_reload` |
| `movement.cfg` | Bunny-hop and jump sounds per role or stock class | `sm_tf2cc_movement_reload` |
| `model_variants.cfg` | Which Mercenary player-model variant goes with each weapon | change map (generated, don't edit) |
| `downloads.txt` | Files players download | change map (generated, don't edit) |

## roles.cfg

One block per role (`"mercenary"`, `"civilian"`). The keys you're most likely to change:

| Key | Meaning |
|---|---|
| `health`, `speed` | Max health and run speed (Open Fortress Mercenary 150 / 320, TF2 Classic Civilian 200 / 280) |
| `team_limit` | Maximum players per team in this role (`0` = unlimited, `-1` = role disabled) |
| `random_weight` | How likely *Random* picks this role (each stock class counts 1) |
| `allow_bots` | `1` = bots may become this role |
| `admin_flags` | Restrict the role to admins with these SourceMod flags (empty = everyone) |
| `deny_map_prefixes` | Maps where the role is unavailable (default `mvm_`) |
| `fall_damage` | `0` = immune to fall damage |
| `loadout_primary`, `loadout_secondary`, `loadout_melee` | Spawn weapons (ids from `weapons.cfg`; empty = none) |
| `ammopack_weapons`, `can_pickup` | Mercenary rules: ammo packs can drop weapons; the role may pick up, drop and swap weapons |
| `taunts`, `weapon_taunts`, `taunt_events` | Taunt sequences, their length and voice lines, and per-weapon taunts |

The remaining keys are technical: `model`, `use_class_animations`, `scoreboard_class`,
`arms_mode`, `arms_model` and `voice`. Leave them unless you're replacing the model.

## weapons.cfg

One block per weapon id (`merc_pistol`, `civ_umbrella`, ...). Each weapon is a real
stock TF2 weapon (the *donor*, `classname` + `itemdef`). Its Open Fortress / TF2 Classic
model, sounds and stats are layered on top. Safe things to change:

| Key | Meaning |
|---|---|
| `enabled` | `0` takes the weapon out of the game. These ship disabled: the MarxVee-only extras (Medkit, Grappling Hook, Hoarder's Stash, Backup Plan, Cash Wad, Chainsaw (Backstab)) and the Quad Launcher, Machine Gun and Flamethrower. |
| `pack_weight` | How often ammo packs drop this weapon (`0` = never) |
| `attributes` | TF2 attributes (by name) that set damage, fire rate, clip and so on |
| `reserve`, `clip` | Ammo amounts |
| `roles` | Which roles may hold it |

Each weapon can also have a `"marxvee"` block with the legacy MarxVee balance. It's
used when `tf2cc_weapon_profile marxvee` is set. The default (`source`) follows the
Open Fortress and TF2 Classic numbers, noted in each weapon's `ref` comment.

Don't change `classname`, `itemdef`, `slot`, `arms_family` or `viewmodel_generated`
unless you're changing the donor. The models are generated to match the donor's
animations, and `sm_tf2cc_weapons` reports any mismatch.

## voice.cfg

Voice lines, grouped by persona (`mercenary`, `civilian`) and situation keys such as
`_painsharp`, `_battlecry`, `_cloakedspyidentify03` and `_respawn`. Each key lists one
or more sound files, and one is picked at random. The `targeted` section holds what
*stock* classes say about Mercenaries and Civilians, for example a Scout calling out a
spy disguised as a Mercenary. Volume and cooldowns are set with the `tf2cc_voice_*`
cvars.

## movement.cfg

Per role or stock class: `autohop` (hold jump to bunny-hop) and the jump vocal sounds.
The Quake-style air movement itself comes from the bundled Classic Movement plugin.
Its `cm_scope` setting, in `cfg/sourcemod/plugin.classicmovement.cfg`, chooses who
gets it:
- `mercenary` (default);
- `all`;
- a comma list of role keys and class names.
