# Installing tf2cc on a TF2 server

This guide takes a TF2 dedicated server from nothing to playable Mercenaries and
Civilians. It assumes you can copy files to the server and edit its config files. Set up
the [FastDL](FASTDL.md) download host as well: without it, players download about 300 MB
from the game server itself, which is slow.

## 1. Requirements

| Needed | Version | Where to get it |
|---|---|---|
| TF2 dedicated server | current, 64-bit (`srcds_win64.exe` / `srcds_linux64`) | SteamCMD, app 232250 |
| Metamod:Source | 1.11 or newer, 64-bit build | https://www.metamodsource.net/downloads.php |
| SourceMod | 1.12 or newer, 64-bit build | https://www.sourcemod.net/downloads.php |
| TF2Attributes | 1.7.5 or newer (plugin **and** its `gamedata/tf2.attributes.txt`) | https://github.com/FlaminSarge/tf2attributes/releases |

DHooks is part of SourceMod 1.12, so it needs no separate install. tf2cc ships no
gamedata of its own.

Check the platform before you start. Type these into the server console:

```
meta version
sm version
sm plugins list        // TF2Attributes must be listed and running
```

## 2. Stop the server and back up

Stop the server. Back up `tf/addons/sourcemod/` and `tf/cfg/`, so you can roll back by
copying them back.

## 3. Remove conflicting plugins

These plugins do the same job as tf2cc and must not run alongside it. Move them out of
`tf/addons/sourcemod/plugins/`, for example into `plugins/disabled/`:

| Remove | Why |
|---|---|
| `customclasses.smx`, `customclasses/modules/bethemercnew.smx`, `customclasses/modules/bethecivilian.smx` | The original MarxVee custom-class setup. tf2cc replaces all of it. |
| `tf2_custom_taunts.smx` | Its class-10 taunt handling conflicts with tf2cc's taunts. |
| `tf2items_randomizer.smx`, if it was only there for the MarxVee setup | Not needed by tf2cc. |
| Any older `classicmovement.smx` | tf2cc ships a fork that knows about Mercenaries (step 4). |

If you use **GiveBotsMoreWeapons**, tf2cc already removes the weapons it hands to
Mercenary/Civilian bots (`tf2cc_strip_foreign_weapons 1`). That plugin has crashed
servers with about 22 bots even without tf2cc, so keep bot counts modest while it
is loaded.

## 4. Copy the files

Copy the **contents** of this repository's `tf/` folder into your server's `tf/` folder.
Merge the folders and overwrite when asked. You should end up with:

```
tf/addons/sourcemod/plugins/tf2cc/tf2cc_core.smx        (and 7 more tf2cc_*.smx)
tf/addons/sourcemod/plugins/classicmovement.smx
tf/addons/sourcemod/configs/tf2cc/roles.cfg             (weapons.cfg, voice.cfg, movement.cfg,
                                                         model_variants.cfg, downloads.txt)
tf/cfg/sourcemod/plugin.classicmovement.cfg
tf/models/..., tf/materials/..., tf/sound/...           client content
```

`addons/sourcemod/scripting/` holds the source code. The server doesn't need it; it's
only for recompiling (see step 9).

The client content must exist **on the game server** as well as on the FastDL. The
plugin checks every file in `downloads.txt` against the server's disk and only offers
files that are there.

## 5. Allow downloads

Add these lines to `tf/cfg/server.cfg`:

```
sv_allowdownload 1
sv_allowupload 1
net_maxfilesize 64           // one texture is 22 MB; the default limit is 16 MB
sv_downloadurl "https://your.fastdl.host/tf/"   // see FASTDL.md; leave out until it is set up
```

`sv_pure` can stay as it is. None of tf2cc's files replace a stock TF2 file, so pure
servers accept them.

## 6. Start and check

Start the server, then run:

```
sm plugins list
```

You should see **TF2CC Core, Weapons, Voice, Civilian, Movement, Specials, Taunts and
HUD**, plus **Classic Movement**, all without errors.

Then:

```
sm_tf2cc_weapons       // every configured weapon should be listed as valid
sm_tf2cc_status        // role state of each player (empty until someone picks a role)
```

Look in `tf/addons/sourcemod/logs/errors_<date>.log`. The line
`tf2cc: N manifest file(s) missing on this server` means some client content wasn't
copied (step 4).

On the first start each plugin writes its settings file to `tf/cfg/sourcemod/`:
`tf2cc_core.cfg`, `tf2cc_weapons.cfg`, `tf2cc_voice.cfg`, `tf2cc_civilian.cfg`,
`tf2cc_movement.cfg`, `tf2cc_specials.cfg`, `tf2cc_taunts.cfg`, `tf2cc_hud.cfg`.
Every setting is described in [CVARS.md](CVARS.md).

## 7. Try it in game

Join the server. If FastDL works, the downloads finish quickly. Then try:

- `!class` (or `/class`, `sm_class`) opens the role menu; `!merc` or `!civilian` picks
  directly;
- choosing **Random** in the normal class-select screen also opens the role menu
  (`tf2cc_random_menu 1`);
- you respawn as the role at the next spawn (immediately when you are dead or in your
  team's spawn room);
- as the Mercenary, try **Use** (`+use`) or **Inspect** (`F`) on a weapon on the
  floor, `!dropweapon` to drop, and hold jump to bunny-hop;
- as the Civilian, stand near teammates to buff them, and use umbrella alt-fire on a
  teammate to boost them.

Bots become roles on their own; `tf2cc_bot_role_chance` (default 20% per life) sets
how often.

## 8. Common settings

| Goal | Setting |
|---|---|
| Turn roles off without unloading | `tf2cc_enabled 0` |
| Bunny-hop for every class, not just the Mercenary | `cm_scope "all"` in `cfg/sourcemod/plugin.classicmovement.cfg` |
| No fall damage for everyone | `tf2cc_no_fall_damage "all"` |
| Legacy MarxVee weapon balance instead of Open Fortress values | `tf2cc_weapon_profile marxvee` |
| Fewer floor weapons from ammo packs | `tf2cc_ammopack_weapon_chance 0.3` |
| One player model for all weapons (see below) | `tf2cc_model_variants 0` |
| Role limits, health, speed, which roles bots may use | `configs/tf2cc/roles.cfg` ([CONFIGURATION.md](CONFIGURATION.md)) |

`tf2cc_model_variants 0` uses less client memory and fewer downloads, but the
third-person animations are less exact.

## 9. Updating and recompiling

To update, stop the server and copy the new `tf/` folder over the old one, as in step
4. Read the release notes first. When client content changes, it moves to a new
revision folder (for example `models/weapons/tf2cc_r3/`), so players who cached the
old files still get the new ones. Run the FastDL steps again after every update.

To recompile, use SourceMod's compiler with `addons/sourcemod/scripting/` as the
working folder. You also need `tf2attributes.inc` from TF2Attributes on the include
path:

```
spcomp tf2cc_core.sp -i include -o ../plugins/tf2cc/tf2cc_core.smx
```

Do the same for the other `tf2cc_*.sp` files and `classicmovement.sp`.

## 10. Uninstalling

Unload or delete the `plugins/tf2cc/` folder and change map. Anyone playing a role
respawns as a normal class. The client content can stay; it does nothing on its own.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Purple-and-black checkerboard textures or `ERROR` models | The player didn't get the files. Check `sv_allowdownload 1`, `net_maxfilesize 64` and the FastDL paths ([FASTDL.md](FASTDL.md)). Make sure the files exist on the game server too. |
| `!class` does nothing | TF2CC Core isn't running (`sm plugins list`) or `tf2cc_enabled 0`. |
| Players can't become a role | They're on a team that can't have roles: the BLU robots in MvM, the boss team on VSH/FF2 maps, or the VIP team on VIP maps. See the `tf2cc_vip_*`, `tf2cc_boss_*` and `tf2cc_mvm_*` cvars. |
| Weapons have stock stats | TF2Attributes isn't loaded, or its gamedata is outdated after a TF2 update. |
| Everything broke after a TF2 update | Update SourceMod (its gamedata) and TF2Attributes. tf2cc itself needs no gamedata. |
| Errors mentioning a plugin other than tf2cc | Check the plugins listed in step 3. |
