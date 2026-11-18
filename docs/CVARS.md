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
| `tf2cc_civ_boost_meter` | `1` | 0 .. 1 | Show the umbrella boost cooldown meter while a role player holds the umbrella. |
| `tf2cc_civ_boost_meter_x` | `0.73` |  | Umbrella boost meter X (0-1, -1 = centre); default sits under the tf2cc_hud item meters. |
| `tf2cc_civ_boost_meter_y` | `0.86` |  | Umbrella boost meter Y (0-1). |

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
| `tf2cc_exempt_autodetect` | `1` | 0 .. 1 | At map start, also exempt maps whose BSP pakfile carries VScript files under a 'mercenary' path (maps that simulate the Mercenary themselves). configs/tf2cc/exempt_maps.txt is always used. |
| `tf2cc_bot_reevaluate_guard` | `1` | 0 .. 1 | While role bots exist, temporarily set tf_bot_reevaluate_class_in_spawnroom 0 (restored afterwards) so they don't suicide-loop in spawn. |

| Command | Access | What it does |
|---|---|---|
| `sm_class` | everyone | Open the custom class menu. |
| `sm_classes` | everyone | Open the custom class menu. |
| `sm_merc` | everyone | Become the Mercenary. |
| `sm_mercenary` | everyone | Become the Mercenary. |
| `sm_civilian` | everyone | Become the Civilian. |
| `sm_tf2cc_reload` | admin: config | Reload roles.cfg. |
| `sm_tf2cc_selfcheck` | admin: generic | Check what tf2cc depends on after a TF2/SourceMod/TF2Attributes update (netprops, respawn hook, TF2Attributes). |
| `sm_tf2cc_test_nohook` | admin: root | sm_tf2cc_test_nohook <0\|1> - TESTING: run class-10 transitions through the fallback path as if the ForceRespawn offset were missing. |
| `sm_tf2cc_exempt` | admin: config | Show whether this map is exempt from custom classes; sm_tf2cc_exempt reload re-reads exempt_maps.txt. |
| `sm_tf2cc_status` | admin: generic | Show role state of every player. |
| `sm_tf2cc_setrole` | admin: slay | sm_tf2cc_setrole <target> <role\|none> - bots stay pinned to it until they leave. |

## tf2cc Eternal Shotgun meat hook (`tf2cc_hook.smx`)

Config file: `cfg/sourcemod/tf2cc_hook.cfg`

| Cvar | Default | Range | What it does |
|---|---|---|---|
| `tf2cc_eternal_hook_enable` | `1` | 0 .. 1 | Eternal Shotgun: alt-fire meat hook (OF). |
| `tf2cc_eternal_hook_speed` | `3500` | >= 1 | Hook flight speed (OF BOLT_AIR_VELOCITY 3500). |
| `tf2cc_eternal_hook_speed_water` | `1500` | >= 1 | Hook flight speed when the wielder is under water (OF 1500). |
| `tf2cc_eternal_hook_range` | `900` | >= 1 | Hook flight range (OF MAX_ROPE_LENGTH 900). |
| `tf2cc_eternal_hook_pull` | `720` | >= 1 | Minimum reel speed (OF HOOK_PULL 720). |
| `tf2cc_eternal_hook_aircontrol` | `150` | >= 0 | Air control while reeled (OF MEAT_HOOK_AIRCONTROL 150). |
| `tf2cc_eternal_hook_release_dist` | `140` | >= 0 | Released within this distance of the target (OF 140). |
| `tf2cc_eternal_hook_cooldown` | `1.0` | >= 0 | Seconds after a release before the next hook (OF 1). |
| `tf2cc_eternal_hook_los_time` | `0.15` | >= 0 | Released when the target is out of sight this long (OF 0.15). |
| `tf2cc_eternal_hook_blocked` | `0.75` | 0 .. 1 | Released when the wielder's speed falls this fraction below the pull (OF 0.75; 0 = never). |
| `tf2cc_eternal_hook_stun_mode` | `0` | 0 .. 2 | Hooked target: 0 = OF pin only (no moving or jumping, can still shoot), 1 = also a sandman-style small bonk (slowed, third person), 2 = also a full bonk (stuck, cannot attack). |
| `tf2cc_eternal_hook_stun_time` | `3.0` | >= 0.1 | Longest stun (stun modes 1/2); it ends with the hook anyway. |
| `tf2cc_eternal_hook_hold` | `0` | 0 .. 1 | 1 = letting go of right-click releases the hook (hold to reel); 0 = OF toggle. |
| `tf2cc_eternal_hook_world` | `0` | 0 .. 1 | 1 = the hook also latches on the world and pulls straight in (grappling hook); 0 = OF: players only. |
| `tf2cc_eternal_hook_beam` | `cable/cable.vmt` |  | Rope material (OF cable/cable_grey.vmt; stock HL2 cable here). |
| `tf2cc_eternal_hook_beam_width` | `1.5` | >= 0.1 | Rope width (OF 1). |
| `tf2cc_eternal_hook_hud` | `1` | 0 .. 1 | Show the hook's cooldown while the Eternal Shotgun is out (OF's 'Hook' meter). |
| `tf2cc_eternal_hook_debug` | `0` | 0 .. 2 | Log hook events to the server console (2: also logs/tf2cc_hookprobe.log). |

| Command | Access | What it does |
|---|---|---|
| `sm_tf2cc_hook_reload` | admin: config | Reload the Eternal Shotgun item definition (TF2 Classified). |

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

## tf2cc Saw Ballista blade (`tf2cc_saw.smx`)

Config file: `cfg/sourcemod/tf2cc_saw.cfg`

| Cvar | Default | Range | What it does |
|---|---|---|---|
| `tf2cc_saw_enable` | `1` | 0 .. 1 | Saw Ballista: OF ricocheting saw blade. |
| `tf2cc_saw_damage` | `4` | >= 0 | Damage per tick to everything the blade overlaps (crits x3). |
| `tf2cc_saw_tick` | `0.03` | >= 0.015 | Damage tick (OF FlyThink 0.03 s). |
| `tf2cc_saw_cap` | `200` | >= 0 | Most damage one blade deals to one target (0 = no cap). |
| `tf2cc_saw_slow` | `0.15` | 0 .. 1 | Blade speed while inside a target, fraction of its speed (OF of_ripper_slowed_speed_perc 0.05). |
| `tf2cc_saw_box` | `50` | >= 1 | Half width of the damage box (OF of_ripper_boxsize 50). |
| `tf2cc_saw_box_height` | `10` | >= 1 | Half height of the damage box (OF of_ripper_boxsize_height 10). |
| `tf2cc_saw_bounces` | `6` | >= 0 | Counted bounces before the blade sticks (OF of_ripper_bounces 6). |
| `tf2cc_saw_count_after` | `1.0` | >= 0 | Bounces count only after this long, the first excepted (OF of_ripper_projectile_lifetime 1). |
| `tf2cc_saw_stick_time` | `5.0` | >= 0 | A stuck blade stays this long (OF of_ripper_prop_lifetime 5). |
| `tf2cc_saw_lifetime` | `6.0` | >= 0 | Safety: a flying blade is removed after this long (0 = never). |
| `tf2cc_saw_scale` | `2.0` | >= 0.1 | Blade model scale (OF SetModelScale 2). |
| `tf2cc_saw_debug` | `0` | 0 .. 1 | Log blade events to the server console. |

| Command | Access | What it does |
|---|---|---|
| `sm_tf2cc_saw_reload` | admin: config | Reload the Saw Ballista item definition (TF2 Classified). |

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
| `tf2cc_quad_homing` | `1` | 0 .. 1 | Quad Launcher rockets home on the point the owner aims at while the Quad is out (OF m_bHoming / laser dot). |
| `tf2cc_quad_turn_rate` | `12.0` | >= 0 | Quad rocket steering per second (fraction of the way to the aim direction). 12 = the steering live servers had before the double-tracking fix (6 applied twice per tick); OF snaps fully every 0.1 s. |
| `tf2cc_quad_toggle` | `1` | 0 .. 1 | Quad Launcher alt-fire toggles homing on/off for the owner's rockets (OF SwitchHomingModes). |
| `tf2cc_quad_radius_step` | `25` | >= 0 | Quad Launcher: blast radius added per rocket fired since the last reload (OF ContinuousFire_BlastRadiusIncrease; 0 disables). |
| `tf2cc_quad_radius_base` | `100` | >= 1 | Quad Launcher: the OF base radius the step is relative to (OF DamageRadius 100). |
| `tf2cc_quad_ping` | `1` | 0 .. 1 | Quad Launcher: ping sound every second while homing is on and the Quad is out (OF Weapon_Quad.Ping). |
| `tf2cc_chinalake_impact_time` | `0.1` | >= 0 | China Lake: grenades explode on any impact within this many seconds of firing (OF ImpactBeforeTime 0.1). |
| `tf2cc_bouncer_elasticity` | `0.9` | 0 .. 1 | Bouncer: speed kept per bounce (OF SetElasticity 0.9). |
| `tf2cc_bouncer_min_speed` | `200` | >= 0 | Bouncer: impacts slower than this are left to the physics (OF: no bounce below 200 u/s). |
| `tf2cc_bouncer_gravity` | `1.5` | >= 0 | Bouncer: gravity scale (OF SetGravity 1.5; the pipe's physics gives 1.0, the rest is added per frame). |
| `tf2cc_bouncer_speed` | `750` | >= 0 | Bouncer: launch speed (OF ProjectileSpeed 750). |
| `tf2cc_bouncer_pitch` | `15` | -90 .. 90 | Bouncer: launch pitched up this many degrees from the aim (OF 15). |
| `tf2cc_bouncer_fuse` | `2.0` | >= 0.1 | Bouncer: fuse from firing (OF FuseTime 2). |
| `tf2cc_chinalake_enemy_touch` | `1` | 0 .. 1 | China Lake: grenades still explode on touching an enemy after they bounced (OF AlwaysEnableTouch 1). |
| `tf2cc_sawblade_dps` | `200` | >= 0 | Saw Ballista grind damage per second while the target stays at the hit point. |
| `tf2cc_sawblade_grind_time` | `0.6` | >= 0 | Saw Ballista grind duration after a hit. |
| `tf2cc_sawblade_radius` | `60` | >= 0 | Distance from the hit point within which the target keeps being ground. |
| `tf2cc_chainsaw_damage` | `12` | >= 0 | Chainsaw damage per hit (OF Damage 12). |
| `tf2cc_chainsaw_interval` | `0.05` | >= 0.01 | Chainsaw seconds between hits (OF TimeFireDelay 0.05). |
| `tf2cc_chainsaw_range` | `100` | >= 0 | Chainsaw reach (OF MeleeRange 100). |
| `tf2cc_chainsaw_windup` | `1.0` | >= 0 | Chainsaw wind-up before it cuts (OF_CHAINSAW_WINDUP_TIME 1.0; halved while charging). |
| `tf2cc_chainsaw_charge_time` | `3.0` | >= 0 | Chainsaw alt-fire charge length (OF ChargeDuration 1.5, measured 2x in game). |
| `tf2cc_chainsaw_charge_recharge` | `8.0` | >= 0 | Seconds for the chainsaw charge to refill (OF ChargeRechargeRate 8). |
| `tf2cc_chainsaw_charge_speed` | `720` | >= 1 | Chainsaw charge speed (OF of_shield_charge_speed 720; a demoknight charge is tf_max_charge_speed 750). |
| `tf2cc_chainsaw_charge_meter` | `1` | 0 .. 1 | Show the chainsaw charge meter (recharge / ready / charging) while the chainsaw is out. |
| `tf2cc_chainsaw_charge_meter_x` | `0.73` |  | Chainsaw charge meter X (0-1, -1 = centre); same spot as the umbrella boost meter. |
| `tf2cc_chainsaw_charge_meter_y` | `0.86` |  | Chainsaw charge meter Y (0-1). |
| `tf2cc_phlog` | `1` | 0 .. 1 | Phlogistinator Mmmph for role players: burn damage fills the rage meter and alt-fire at 100% activates it (stock Pyro values). |
| `tf2cc_phlog_meter` | `1` | 0 .. 1 | Show the Mmmph meter to role players who carry the Phlogistinator. |
| `tf2cc_phlog_meter_x` | `0.73` |  | Mmmph meter X (0-1, -1 = centre); same spot as the chainsaw / umbrella meters. |
| `tf2cc_phlog_meter_y` | `0.86` |  | Mmmph meter Y (0-1). |
| `tf2cc_phlog_debug` | `0` | 0 .. 1 | 1 = print Mmmph gain and activation to the server console. |

## TF2CC Taunts (experimental) (`tf2cc_taunts.smx`)

Config file: `cfg/sourcemod/tf2cc_taunts.cfg`

| Cvar | Default | Range | What it does |
|---|---|---|---|
| `tf2cc_taunts_enabled` | `1` | 0 .. 1 | Enable experimental sequence taunts for roles. |
| `tf2cc_taunts_prop_class` | `funCBaseFlex` |  | Clone entity: funCBaseFlex (default: a flex entity, so the eyes look ahead; the plugin drives its animation) \| prop_dynamic_override (eyes roll up, may show the reference pose at the end) \| tf_taunt_prop (EXPERIMENTAL: crashed srcds in testing). |
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
| `tf2cc_voice_coated_cooldown` | `6.0` | >= 0 | Seconds between a role player's negative/jeers lines when coated in Mad Milk, Jarate or Gas Passer. |

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
| `tf2cc_medigun_uber` | `1` | 0 .. 1 | Role players' deployed medigun charges (Medi Gun / Kritzkrieg / Quick-Fix) apply their effect; the game only applies them for Medics. |
| `tf2cc_medigun_beam` | `1` | 0 .. 1 | Draw the medigun heal beam for role players (the client only draws it for Medics). |
| `tf2cc_drop_on_death` | `1` | 0 .. 1 | Mercenary drops his active weapon on death. |
| `tf2cc_drop_default_on_death` | `1` | 0 .. 1 | 1 = like OF (CTFPlayer::Event_Killed/DropWeapon) the default pistol/crowbar drop too, and an undroppable active weapon (Fists) drops the best other weapon instead; 0 = only non-default active weapons. |
| `tf2cc_crit_glow` | `1` | 0 .. 1 | Show the stock crit/mini-crit weapon glow (critgun_weaponmodel_<team>) on custom weapons' world and view models while the holder is boosted. |
| `tf2cc_stock_pickups` | `1` | 0 .. 1 | Mercenary may pick up weapons dropped by any class (tf_dropped_weapon). |
| `tf2cc_viewmodel_mode` | `auto` |  | First-person viewmodels: auto (OF/TF2C v_model when generated, else role arms) \| custom \| family. Per-weapon "viewmodel_mode" overrides. |
| `tf2cc_weapon_profile` | `source` |  | Weapon behaviour profile: source (Open Fortress / TF2 Classic accurate) \| marxvee (legacy MarxVee tuning). Per-weapon "profile" in weapons.cfg overrides. Applies from the next spawn. |
| `tf2cc_civ_derringer` | `0` | 0 .. 1 | MarxVee Civilian derringer (civ_backupplan, "Backup Plan"): 1 = available (ammo packs, pickups, loadout), 0 = off and taken from anyone holding it. Overrides its weapons.cfg "enabled". |
| `tf2cc_civ_cashwad` | `0` | 0 .. 1 | MarxVee Civilian cash wad (civ_cashwad): 1 = available, 0 = off and taken from anyone holding it. Overrides its weapons.cfg "enabled". |

| Command | Access | What it does |
|---|---|---|
| `sm_dropweapon` | everyone | Mercenary: drop the active weapon. |
| `sm_stash` | everyone | Hoarder's Stash: use stored items. |
| `sm_tf2cc_givestock` | admin: cheats | sm_tf2cc_givestock <item def index> <target> - give a role player a stock item the way a pickup does (testing). |
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
