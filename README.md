# tf2cc: Mercenary and Civilian for Team Fortress 2 servers

tf2cc is a set of SourceMod plugins for **stock Team Fortress 2 servers**. It adds two
playable classes:

- the **Mercenary** from Open Fortress;
- the **Civilian** from TF2 Classic (TF2 Classified).

Players don't need to install anything. Everything runs on the server, and the models,
sounds and textures download to players like any custom map content. Clients stay
unmodified and VAC-secured.

> **Status:** public playtest. It runs on live servers and is still being polished; please
> report bugs through GitHub issues.

## What players get

**Mercenary** (Open Fortress)
- A three-slot deathmatch arsenal with Open Fortress stats, viewmodels, world models and
  sounds:
  - melee: Crowbar, Lead Pipe, Combat Knife, Fists/Berserk, Chainsaw;
  - secondary: Pistol and Akimbo Pistols, Revolver, Shotgun, Combat SMG, Tommy Gun;
  - primary: Super Shotgun, Assault Rifle, Rocket Launcher, Grenade Launcher (China
    Lake), Dynamite, Nailgun, Gatling Gun, Railgun, Lightning Gun, G.I.B., Saw Ballista.
- Weapon pickups:
  - weapons drop on death;
  - walking over a weapon picks it up if that slot is empty;
  - **Use** or **Inspect** swaps it for the one you hold;
  - a second Pistol becomes Akimbo Pistols;
  - map ammo packs can drop a random weapon on the floor;
  - weapons dropped by *any* stock class can be picked up and used.
- Open Fortress third-person animation sets for every weapon.
- Bunny-hopping (hold jump), and no fall damage.
- Open Fortress voice lines:
  - voice menu, pain and death;
  - respawn and flag-pickup lines;
  - Spy callouts that name the disguised class.
- Open Fortress taunts, picked by the held weapon. The Bond taunt with a pistol is a
  taunt kill.

**Civilian** (TF2 Classic)
- An aura that heals nearby teammates and reduces the damage they take.
- Umbrella alt-fire gives a teammate a mini-crit boost.
- Counts as 5 players when capturing control points.
- TF2 Classic voice lines, Spy callouts and taunts.
- The umbrella drops on death, and a Mercenary can pick it up and boost with it too.

**Both:**
- chosen from a class menu (`!class`, `!merc`, `!civilian`, or *Random* in the normal
  class menu);
- usable by bots;
- aware of game modes: off on Mann vs. Machine maps by default, and kept off the VIP
  team on VIP/hunted maps and the boss team on VSH/FF2 maps;
- item meters on the HUD for charge, rage and recharge items.

## How it works (short version)

Stock TF2 already contains an unused **class number 10**. tf2cc spawns the player as
class 10 and gives them the Mercenary or Civilian model, health, speed, weapons, voice
and abilities. All of it is built from things the game and SourceMod already
support:

- **Class switch:** a DHooks hook on `CTFPlayer::ForceRespawn` (offset from SourceMod's
  own gamedata).
- **Weapons:** real stock weapon entities, plus attributes and networked model indices.
- **Temp entities and sound hooks** for the rest.

tf2cc ships **no signatures and no custom gamedata**, so a TF2 update only needs
SourceMod's own gamedata to be current.

Every Mercenary weapon rides on a stock "donor" weapon whose firing logic is closest to
the Open Fortress original. tf2cc then corrects the rest:
- first-person models are retargeted to the donor's animation names;
- the stock world model is hidden and the Open Fortress one is attached;
- stats are set with attributes;
- sounds are swapped;
- behaviours stock TF2 can't express are done by the plugin itself: chainsaw sawing,
  bomblets, the lightning beam, nails, the medkit, Saw Ballista grinding, gatling
  sounds, and the Civilian aura and boost.

The full explanation is in [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

## Relationship to the original MarxVee plugin

This project is a **clean-room rewrite** of MarxVee's 2022–2023 "Custom Classes" setup
(`customclasses`, `bethemercnew`, `bethecivilian` and its Custom Weapons 3 modules).
MarxVee's source code was never available, and **tf2cc contains none of MarxVee's
code**.

The original's *behaviour* was reverse-engineered from:
- the compiled plugins' string tables and native-import lists;
- the configuration files it shipped (class definitions, weapon lists, voice packs);
- decompiler output, which was read as a description of behaviour and never copied;
- observing the old setup in play.

Every system was then written from scratch against the TF2 source code (the 2025 TF2
SDK), Open Fortress's source, and TF2 Classic's game data. Details:
[docs/HOW-IT-WORKS.md#clean-room-rebuild-of-the-marxvee-setup](docs/HOW-IT-WORKS.md#clean-room-rebuild-of-the-marxvee-setup).

The **assets are not original work**. tf2cc includes models, textures and sounds from:
- MarxVee's asset pack;
- Open Fortress;
- TF2 Classic.

They are credited per game in [CREDITS.md](CREDITS.md).

## Installing

Step-by-step instructions for server owners, covering the server and the FastDL
download host:

1. [docs/INSTALL.md](docs/INSTALL.md): requirements, copying files, first start,
   checking it works.
2. [docs/FASTDL.md](docs/FASTDL.md): making players download the content quickly.
3. [docs/CONFIGURATION.md](docs/CONFIGURATION.md): roles, weapons, voice and movement
   config files.
4. [docs/CVARS.md](docs/CVARS.md): every cvar and command.

**Requirements:**
- a 64-bit TF2 dedicated server;
- Metamod:Source 1.11 or newer;
- SourceMod 1.12 or newer;
- the [TF2Attributes](https://github.com/FlaminSarge/tf2attributes) plugin.

Tested on SourceMod 1.12.0.7200 with TF2Attributes 1.7.5.

## Repository layout

```
tf/                                  copy this folder over your server's tf/ folder
  addons/sourcemod/plugins/tf2cc/    the eight tf2cc plugins (compiled)
  addons/sourcemod/plugins/classicmovement.smx   bunny-hop (fork of mphe's Classic Movement)
  addons/sourcemod/scripting/        complete source code
  addons/sourcemod/configs/tf2cc/    roles, weapons, voice, movement, variants, downloads list
  cfg/sourcemod/                     default Classic Movement settings
  models/ materials/ sound/          client content (also goes on your FastDL)
docs/                                installation, FastDL, configuration, cvars, internals
tools/make_fastdl.py                 builds the compressed FastDL tree
THIRD-PARTY/                         licences of bundled third-party code
```

## Known limitations

These are limits of an unmodified TF2 client:
- **Scoreboard and killfeed:** they can't show Mercenary or Civilian class icons or
  portraits. The client's tables have no art for class 10.
- **Your own gunshots:** your game plays the donor weapon's stock sound locally. tf2cc
  plays the Open Fortress sound to you as well, mixed exactly as other players hear
  it.
- **Particles:** Open Fortress and TF2 Classic particle files can't load on stock
  clients. The closest stock effects are used instead, for example the Cow Mangler's
  energy blast for the G.I.B.
- **Spies:** they can't disguise as a Mercenary or Civilian.

## Credits

See [CREDITS.md](CREDITS.md). In short:
- the original Custom Class plugin is by **MarxVee**;
- the Civilian and its content are by the **TF2 Classic team**;
- the Mercenary and its content are by the **Open Fortress team**.

## Licensing

The tf2cc code (plugins, configs, tools and documentation) is licensed under the
**GNU General Public License v3.0** ([LICENSE](LICENSE)), like SourceMod itself.

The bundled Classic Movement fork stays under its original **GPL-3.0** licence
([THIRD-PARTY/classicmovement-LICENSE](THIRD-PARTY/classicmovement-LICENSE)).

Assets from Open Fortress, TF2 Classic and the MarxVee pack belong to their creators
and are included here with credit. Check each project's redistribution terms before
re-hosting them.
