# Credits

tf2cc's code was written from scratch. The characters, models, animations, textures,
sounds and voice work were made by other people, credited below, and are included with
thanks.

## Original Custom Class plugin

**MarxVee**: the original TF2 Custom Class plugin and its Mercenary and Civilian setup.
*No original code is present* in tf2cc (see [README](README.md#relationship-to-the-original-marxvee-plugin)),
but its weapon and model assets are used.

## Team Fortress 2 Classic Team

| Role | Credit |
|---|---|
| Voice of Civilian | Benjamoose |
| Modeller | Maxxy |
| Concept Artist | Blaholtzen |

## Open Fortress Team

| Role | Credit |
|---|---|
| Programming | KayDemonLP |
| Voice of Mercenary | Stachekip |
| Modeller | Alaxe |
| Concept Artist | DrPyspy |
| Animators | Hex, Coolchou Zhao, Polybagel |
| Weapon Modellers | Mr. Big, Overpovered, DrPyspy |
| Particles | FissionMetroid101 |

## Where each asset comes from

| Content (under `tf/`) | Origin |
|---|---|
| `models/player/customclasses/civilian_new`, `models/player/tf2cc/civilian*`, `materials/models/player/civilian_new` | TF2 Classic: Civilian player model (via the MarxVee pack). `civilian.mdl` adds one animation include. |
| `sound/vo/custom/civilian_*` | TF2 Classic: Civilian voice (Benjamoose) |
| `sound/player/vip_*`, `sound/player/taunt_civilian_bill_*`, `sound/weapons/umbrella_snap2.wav` | TF2 Classic: aura, boost and taunt sounds |
| `models/weapons/customclasses/*umbrella*`, `materials/models/weapons/*umbrella2*` | TF2 Classic: Civilian umbrella |
| `models/weapons/w_models/w_nail.*`, `materials/models/weapons/nail` | TF2 Classic: nail projectile |
| `models/player/customclasses/mercenary`, `models/player/tf2cc/mercenary*`, `materials/models/player/mercenary` | Open Fortress: Mercenary player model and animations (via the MarxVee pack) |
| `models/player/tf2cc/variants_*` | Open Fortress: Mercenary animation sets (`merc_anim`), re-labelled per weapon by tf2cc's tools |
| `sound/vo/custom/mercenary_*`, `sound/vo/tf2cc/of` | Open Fortress: Mercenary voice (Stachekip) |
| `models/weapons/customclasses/v_models`, `models/weapons/customclasses/w_models` and the matching `materials/models/weapons/*`. Covers the Crowbar, Lead Pipe, Chainsaw, Pistol, Revolver, Shotgun, SMG, Tommy Gun, Super Shotgun, Assault Rifle, Rocket Launcher, Quad, Grenade Launcher, Dynamite and bomblets, Nailgun, Gatling, Railgun, Lightning Gun, BFG/G.I.B. and Saw Ballista | Open Fortress weapons (via the MarxVee pack) |
| `models/weapons/tf2cc_*` | Open Fortress / TF2 Classic viewmodels, with animations re-labelled for the stock donor weapons by tf2cc's tools |
| `sound/weapons/custom`, `sound/weapons/chainsaw_*`, `sound/weapons/chaingun_*`, `sound/weapons/nail_gun_draw.wav`, `sound/weapons/mlg_charge_up.wav`, `sound/weapons/draw_default.wav`, `sound/player/taunt_bond_pistol.wav` | Open Fortress weapon and taunt sounds (some via the MarxVee pack) |
| `sound/weapons/custom/hl1` | Half-Life crowbar sounds (Valve), used by the MarxVee pack for the Crowbar |
| `models/weapons/customclasses/customclassarms` | MarxVee pack: Mercenary and Civilian first-person arms on the stock class skeletons |
| `models/weapons/custom_new/backupplan`, `materials/advancedweaponiser/derringer` | MarxVee pack: Backup Plan derringer (Advanced Weaponiser community model) |
| `materials/models/custom/ivory` | MarxVee pack: grenade texture (community) |
| Remaining small material folders (`props_facemovie`, `workshop/player`, `effects/invun_blue`, `items`) | MarxVee pack: material dependencies of the models above |
| `sound/vo/custom/civilian_cloakedspyidentify11*.wav` | Civilian lines for spotting a disguised Mercenary, added for this project |

Some MarxVee-pack assets were made by community members who aren't named in the pack.
If you made one of them, please get in touch so you can be credited.

## Software

| Project | Use | Licence |
|---|---|---|
| [Classic Movement](https://github.com/mphe/TF2-ClassicMovement) by **mphe** | Mercenary bunny-hop. Bundled as a small fork that adds `cm_scope` (who gets it). | GPL-3.0 ([THIRD-PARTY/classicmovement-LICENSE](THIRD-PARTY/classicmovement-LICENSE)) |
| [SourceMod](https://www.sourcemod.net/) and [Metamod:Source](https://www.metamodsource.net/) | Plugin platform (not bundled) | GPL-3.0 / zlib |
| [TF2Attributes](https://github.com/FlaminSarge/tf2attributes) | Weapon and player attributes (not bundled) | see its repository |
| Open Fortress source code, TF2 Classic game data, the 2025 TF2 SDK | Behaviour reference for the rewrite (no code copied) | their respective terms |
