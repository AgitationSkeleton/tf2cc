# Cvar and command handbook

Generated from the plugin sources by `tools/gen_cvar_doc.py`; do not edit by hand.

Each plugin writes its cvars to `cfg/sourcemod/<file>.cfg` on first load (the file name is listed per plugin). Edit that file, or set the cvar in `server.cfg`, then change map.


## TF2CC Civilian (`tf2cc_civilian.smx`)

Config file: `cfg/sourcemod/tf2cc_civilian.cfg`

| Cvar | Default | Range | What it does |
|---|---|---|---|
| `tf2cc_civ_aura_radius` | `450` |  | Civilian aura radius (TF2C 450). |
| `tf2cc_civ_aura_buff_time` | `1.2` |  | Seconds an aura pulse lasts (TF2C 1.2). |
| `tf2cc_civ_aura_damage_mult` | `0.8` |  | Damage multiplier for buffed players (tf2c_vip_armor 0.8). |
| `tf2cc_civ_aura_regen` | `5` |  | Base HP/s regeneration while buffed (tf2c_vip_regen 5). |
| `tf2cc_civ_boost_time` | `8` |  | Umbrella boost duration (TF2C 8). |
| `tf2cc_civ_boost_cooldown` | `16` |  | Umbrella boost cooldown (TF2C 16). |
| `tf2cc_civ_aura_visual_cond` | `-1` |  | Optional stock TFCond applied for the pulse purely as a visual cue (-1 = none). |
| `tf2cc_civ_aura_particle` | `soldierbuff_%s_buffed` |  | Stock particle on aura-buffed players (%s = red/blue; TF2C civilianbuff_%s_buffed is a custom .pcf stock clients cannot load). Empty = none. |
| `tf2cc_civ_bot_boost_rate` | `0.3` | >= 0 | Civilian bots: chance per second to boost the teammate they are looking at. |
| `tf2cc_civ_capture_value` | `5` |  | Civilian control-point capture rate (TF2C 5). |

## TF2CC Core (`tf2cc_core.smx`)

Config file: `cfg/sourcemod/tf2cc_core.cfg`

| Cvar | Default | Range | What it does |
|---|---|---|---|
| `tf2cc_enabled` | `1` | 0 .. 1 | Enable custom roles. |
| `tf2cc_random_menu` | `1` | 0 .. 1 | Intercept the class menu's Random choice and show the role menu instead. |
| `tf2cc_class10_base_health` | `200` |  | Stock class-10 max health (retail scripts/playerclasses/civilian.ctx). |
| `tf2cc_class10_base_speed` | `250` |  | Stock class-10 max speed (retail scripts/playerclasses/civilian.ctx). |
| `tf2cc_safe_desired_class` | `1` | 1 .. 9 | Stock class (1-9) networked as the desired class for role players who never played a stock class. Keeps the loadout panel off class 10. |
| `tf2cc_sanitize_all_class10` | `1` | 0 .. 1 | Also hide class 10 in the player resource for non-role players (e.g. other plugins). |
| `tf2cc_hud_playermodel_guard` | `0` | 0 .. 1 | 1 = refuse roles to players with cl_hud_show_playermodel 1. The retail client crashed when it was toggled on mid-life as class 10; off by default. |
| `tf2cc_mvm_allow_defenders` | `0` | 0 .. 1 | Mann vs. Machine: allow roles on the RED defender team (the BLU invader/robot team is never eligible). |
| `tf2cc_vip_guard` | `1` | 0 .. 1 | Hunted/VIP/escort maps: deny tf2cc_vip_roles on the VIP team so the map's own Civilian/VIP stays unique. |
| `tf2cc_vip_map_prefixes` | `vip_,hunted_,escort_` |  | Map prefixes treated as hunted/VIP/escort maps. |
| `tf2cc_vip_roles` | `civilian` |  | Comma list of role keys denied on the VIP team on those maps. |
| `tf2cc_vip_team` | `0` |  | VIP team when it cannot be detected (2 = RED, 3 = BLU, 0 = deny the roles on both teams). |
| `tf2cc_boss_map_prefixes` | `vsh_,ff2_,saxton_` |  | Map prefixes treated as boss modes (Versus Saxton Hale / Freak Fortress). FF2, FF2R and SourceMod VSH are also detected through their natives. |
| `tf2cc_boss_team` | `3` |  | Team that hosts the boss in boss modes (3 = BLU, 2 = RED, 0 = none): never eligible for roles. Bosses reported by FF2/VSH natives are always excluded. |
| `tf2cc_mvm_upgrades` | `1` | 0 .. 1 | Allow role players to buy MvM upgrades at (VScript) upgrade stations (player upgrades only; class-10 weapons cannot take item upgrades). |
| `tf2cc_bot_role_chance` | `0.2` | 0 .. 1 | Chance per life that a bot (with allow_bots roles) spawns as a random role instead of its own class pick. |
| `tf2cc_downloads` | `1` | 0 .. 1 | Add every file in configs/tf2cc/downloads.txt (generated asset manifest) to the downloads table. |
| `tf2cc_no_fall_damage` | (empty) |  | Extra players without fall damage (beyond roles.cfg fall_damage 0): comma list of all, roles, role keys, class names. |
| `tf2cc_debug` | `0` | 0 .. 1 | Verbose logging to logs/tf2cc.log. |
| `tf2cc_bot_reevaluate_guard` | `1` | 0 .. 1 | While role bots exist, temporarily set tf_bot_reevaluate_class_in_spawnroom 0 (restored afterwards) so they don't suicide-loop in spawn. |

| Command | Access | What it does |
|---|---|---|
| `sm_class` | everyone | Open the custom class menu. |
| `sm_classes` | everyone | Open the custom class menu. |
| `sm_merc` | everyone | Become the Mercenary. |
| `sm_mercenary` | everyone | Become the Mercenary. |
| `sm_civilian` | everyone | Become the Civilian. |
| `sm_tf2cc_reload` | admin: config | Reload roles.cfg. |
| `sm_tf2cc_status` | admin: generic | Show role state of every player. |
| `sm_tf2cc_setrole` | admin: slay | sm_tf2cc_setrole <target> <role\|none> |

## TF2CC HUD (`tf2cc_hud.smx`)

Config file: `cfg/sourcemod/tf2cc_hud.cfg`

| Cvar | Default | Range | What it does |
|---|---|---|---|
| `tf2cc_hud_meters` | `1` | 0 .. 1 | Show item meters (recharge, rage, charge, energy...) to role players. |
| `tf2cc_hud_meters_x` | `0.73` |  | Meter block X (0-1, -1 = centre). |
| `tf2cc_hud_meters_y` | `0.72` |  | Meter block Y (0-1). |

## TF2CC Movement (`tf2cc_movement.smx`)

Config file: `cfg/sourcemod/tf2cc_movement.cfg`

| Cvar | Default | Range | What it does |
|---|---|---|---|
| `tf2cc_movement_enabled` | `1` | 0 .. 1 | Enable tf2cc movement features. |
| `tf2cc_autohop_all` | `0` | 0 .. 1 | Give autojump/bunnyhop to every class (OF of_bunnyhop 1). |
| `tf2cc_autohop_stock_classes` | (empty) |  | Comma list of stock classes that get autohop (e.g. "scout,soldier"); ignored when tf2cc_autohop_all is 1. |
| `tf2cc_jump_sound_gate` | `0.5` |  | Minimum seconds between jump vocals (OF m_flJumpSoundDelay). |

| Command | Access | What it does |
|---|---|---|
| `sm_tf2cc_movement_reload` | admin: config | Reload movement.cfg. |

## TF2CC Specials (`tf2cc_specials.smx`)

Config file: `cfg/sourcemod/tf2cc_specials.cfg`

| Cvar | Default | Range | What it does |
|---|---|---|---|
| `tf2cc_medkit_range` | `110` |  | Medkit reach (units). |
| `tf2cc_medkit_heal` | `20` |  | Medkit heal per use on a teammate. |
| `tf2cc_medkit_self_heal` | `8` |  | Medkit alt-fire self heal per use. |
| `tf2cc_medkit_delay` | `0.5` |  | Seconds between medkit uses. |
| `tf2cc_medkit_infect_time` | `4` |  | Bleed seconds applied to an enemy ("infect"). |
| `tf2cc_cashwad_radius` | `250` |  | Cash wad buff radius. |
| `tf2cc_cashwad_duration` | `5` |  | Cash wad buff duration. |
| `tf2cc_cashwad_heal` | `25` |  | Cash wad instant heal for teammates in radius. |
| `tf2cc_lightning_damage` | `8` |  | Lightning gun damage per beam tick (OF 8 / 0.05 s). |
| `tf2cc_lightning_range` | `720` |  | Lightning gun beam range (OF 720). |
| `tf2cc_lightning_width` | `10` |  | Lightning gun beam half-width used for hit detection. |
| `tf2cc_lightning_blast_damage` | `45` |  | Alt-fire blast damage. |
| `tf2cc_lightning_blast_range` | `1000` |  | Alt-fire blast range. |
| `tf2cc_lightning_blast_ammo` | `20` |  | Alt-fire blast ammo cost (MarxVee 20). |
| `tf2cc_lightning_blast_delay` | `1.0` |  | Seconds between alt-fire blasts. |
| `tf2cc_grapple_bash_damage` | `40` |  | Damage when the grapple hook hits an enemy (MarxVee bash). |
| `tf2cc_grapple_bash_knockback` | `450` |  | Knockback speed applied by the hook bash. |
| `tf2cc_medkit_pf2_delay` | `0.8` |  | PF2-style medkit swing delay (PF2 syringe TimeFireDelay 0.8). |
| `tf2cc_medkit_pf2_heal` | `50` |  | PF2-style medkit heal per hit on a teammate (PF2 Heal 50). |
| `tf2cc_medkit_pf2_damage` | `50` |  | PF2-style medkit damage per hit on an enemy (PF2 Damage 50). |
| `tf2cc_medkit_pf2_range` | `48` |  | PF2-style medkit swing reach (PF2 48). |
| `tf2cc_medkit_pf2_infect_time` | `14` |  | PF2 infection duration. |
| `tf2cc_medkit_pf2_infect_damage` | `8` |  | PF2 infection damage per tick. |
| `tf2cc_medkit_pf2_infect_interval` | `2.0` |  | PF2 infection tick interval. |
| `tf2cc_bomblets_max_live` | `96` | >= 0 | Cap on simultaneously live bomblets server-wide (edict budget). |
| `tf2cc_dynamite_impact` | `1` | 0 .. 1 | Dynamite bundles explode on their first contact (OF ExplodeOnImpact 1). |
| `tf2cc_sawblade_dps` | `200` | >= 0 | Saw Ballista grind damage per second while the target stays at the hit point. |
| `tf2cc_sawblade_grind_time` | `0.6` | >= 0 | Saw Ballista grind duration after a hit. |
| `tf2cc_sawblade_radius` | `60` | >= 0 | Distance from the hit point within which the target keeps being ground. |
| `tf2cc_chainsaw_damage` | `12` | >= 0 | Chainsaw damage per hit (OF Damage 12). |
| `tf2cc_chainsaw_interval` | `0.05` | >= 0.01 | Chainsaw seconds between hits (OF TimeFireDelay 0.05). |
| `tf2cc_chainsaw_range` | `100` | >= 0 | Chainsaw reach (OF MeleeRange 100). |
| `tf2cc_chainsaw_windup` | `1.0` | >= 0 | Chainsaw wind-up before it cuts (OF_CHAINSAW_WINDUP_TIME 1.0; halved while charging). |
| `tf2cc_chainsaw_charge_time` | `3.0` | >= 0 | Chainsaw alt-fire charge length (OF ChargeDuration 1.5, measured 2x in game). |
| `tf2cc_chainsaw_charge_recharge` | `8.0` | >= 0 | Seconds for the chainsaw charge to refill (OF ChargeRechargeRate 8). |

## TF2CC Taunts (experimental) (`tf2cc_taunts.smx`)

Config file: `cfg/sourcemod/tf2cc_taunts.cfg`

| Cvar | Default | Range | What it does |
|---|---|---|---|
| `tf2cc_taunts_enabled` | `1` | 0 .. 1 | Enable experimental sequence taunts for roles. |
| `tf2cc_taunts_prop_class` | `prop_dynamic_override` |  | Clone entity: prop_dynamic_override (stable) or tf_taunt_prop (EXPERIMENTAL: crashed srcds in testing). |
| `tf2cc_taunts_debug` | `0` | 0 .. 1 | 1 = log which weapon id and taunt each taunt picked. |
| `tf2cc_taunts_mode` | `clone` |  | clone = a prop copy plays the taunt while the player is hidden (default); player = the player model plays it (EXPERIMENTAL: eyes and lip-sync, but T-posed on a test client). |

| Command | Access | What it does |
|---|---|---|
| `sm_tf2cc_tauntstate` | admin: generic | Show taunt state of role players. |
| `sm_tf2cc_taunt` | admin: cheats | sm_tf2cc_taunt <target> [sequence] - make a role player taunt (their normal pick, or a named sequence). |

## TF2CC Voice (`tf2cc_voice.smx`)

Config file: `cfg/sourcemod/tf2cc_voice.cfg`

| Cvar | Default | Range | What it does |
|---|---|---|---|
| `tf2cc_voice_delay` | `-1` |  | Seconds between voice-menu lines per player; -1 = follow tf_max_voice_speak_delay (negative there = no delay). |
| `tf2cc_voice_subtitles` | `0` | 0 .. 1 | Send the stock (Voice) chat subtitle for role voice-menu lines. |
| `tf2cc_voice_level` | `95` |  | Sound level (dB) for role voice lines (TF2 voice uses 95). |

| Command | Access | What it does |
|---|---|---|
| `sm_tf2cc_voice_reload` | admin: config | Reload voice.cfg. |
| `sm_tf2cc_spyaim` | admin: cheats | sm_tf2cc_spyaim <speaker> <target> - aim the speaker at the target and run the normal Spy! callout (real targeting). |
| `sm_tf2cc_spytest` | admin: cheats | sm_tf2cc_spytest <speaker> <target> - run the Spy! callout logic and report the chosen concept. |
| `sm_tf2cc_speak` | admin: cheats | sm_tf2cc_speak <concept> - test a concept on yourself. |

## TF2CC Weapons (`tf2cc_weapons.smx`)

Config file: `cfg/sourcemod/tf2cc_weapons.cfg`

| Cvar | Default | Range | What it does |
|---|---|---|---|
| `tf2cc_owner_weapon_sounds` | `1` | 0 .. 1 | 1 = the shooter also hears a weapon's replacement sounds (sent with the same channel, level, volume and pitch as everyone else; the client's own stock sound still plays). |
| `tf2cc_model_variants` | `1` | 0 .. 1 | 1 = switch the role player model per held weapon (exact OF 3P animation sets, model_variants.cfg); 0 = always the role's base model. |
| `tf2cc_bot_pickup_swap_chance` | `0.1` | 0 .. 1 | Role bots standing on a weapon: chance per 0.2 s to pick it up, swapping their current one. |
| `tf2cc_strip_foreign_weapons` | `1` | 0 .. 1 | Remove weapons other plugins equip on role players (e.g. GiveBotsMoreWeapons). |
| `tf2cc_ammopack_weapon_chance` | `1.0` | 0 .. 1 | Chance that a map ammo pack also drops a Mercenary weapon on the floor (MarxVee sm_btm_ammoweapondrops). Dropped player packs never do. |
| `tf2cc_ammopack_respawn` | `10.0` |  | Seconds before a map ammo pack consumed by a role player reappears. |
| `tf2cc_pickup_lifetime` | `30.0` |  | Seconds a dropped Mercenary weapon stays on the ground. |
| `tf2cc_pickup_auto_empty_slot` | `1` | 0 .. 1 | Touching a weapon whose slot is empty picks it up automatically (OF behaviour). |
| `tf2cc_drop_on_death` | `1` | 0 .. 1 | Mercenary drops his active non-default weapon on death. |
| `tf2cc_stock_pickups` | `1` | 0 .. 1 | Mercenary may pick up weapons dropped by any class (tf_dropped_weapon). |
| `tf2cc_viewmodel_mode` | `auto` |  | First-person viewmodels: auto (OF/TF2C v_model when generated, else role arms) \| custom \| family. Per-weapon "viewmodel_mode" overrides. |
| `tf2cc_weapon_profile` | `source` |  | Weapon behaviour profile: source (Open Fortress / TF2 Classic accurate) \| marxvee (legacy MarxVee tuning). Per-weapon "profile" in weapons.cfg overrides. Applies from the next spawn. |

| Command | Access | What it does |
|---|---|---|
| `sm_dropweapon` | everyone | Mercenary: drop the active weapon. |
| `sm_stash` | everyone | Hoarder's Stash: use stored items. |
| `sm_tf2cc_give` | admin: cheats | sm_tf2cc_give <weapon id> [target] - give a configured tf2cc weapon (yourself by default). |
| `sm_tf2cc_weapons` | admin: generic | List configured tf2cc weapons and their validation status. |
| `sm_tf2cc_inv` | admin: generic | Dump role players' inventory records and live weapon state. |
| `sm_tf2cc_entleak` | admin: generic | Count tf_weapon_*/tf_wearable* entities by owner state (held / owned-not-held / orphan) to find leaks. |
| `sm_tf2cc_vmstate` | admin: generic | sm_tf2cc_vmstate <target> - viewmodel, active weapon flags and owned wearables (logs/tf2cc_vmtrace.log). |
| `sm_tf2cc_vmtrace` | admin: generic | sm_tf2cc_vmtrace <target> [seconds] - log viewmodel sequence/parity/model every 0.1 s to logs/tf2cc_vmtrace.log. |

## Classic Movement (`classicmovement.smx`)

| Cvar | Default | Range | What it does |
|---|---|---|---|
| `cm_enabled` | `1` |  | Enable/Disable Classic Movement. |
| `cm_allow_autohop` | `1` |  | Allow users to jump automatically by holding jump. |
| `cm_speedo` | `0` |  | Show speedometer by default. |
| `cm_duckjump` | `1` |  | Allow jumping while being fully crouched. |
| `cm_doubleduck` | `1` |  | Allow double ducking. |
| `cm_speedcap` | `-1.0` |  | The maximum speed players can reach. -1 for unlimited. |
| `cm_frametime` | `0.009` |  | Virtual frametime (in seconds) to simulate a higher tickrate. 0 to disable. Values higher than 0.015 have no effect. |
| `cm_use_nice_hud` | `1` |  | Whether or not to use a nicer speedometer HUD. |
| `cm_hud_color` | `255 255 0` |  | Speedometer HUD color. Syntax: cm_hud_color "R G B" |
| `cm_scope` | `mercenary` |  | Who gets classic movement: comma list of all, roles, tf2cc role keys (mercenary, civilian) and class names (scout..engineer). |

| Command | Access | What it does |
|---|---|---|
| `sm_speed` | everyone | Toggle speedometer on/off |
| `sm_autohop` | everyone | Toggle autohopping on/off |
| `sm_fov` | everyone | Set Field of View to a custom value |
