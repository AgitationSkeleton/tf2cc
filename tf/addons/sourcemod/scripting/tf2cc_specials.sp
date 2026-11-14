/**
 * tf2cc_specials - behaviours of legacy MarxVee items that the stock donor
 * cannot provide through attributes alone (previously CW3 "marxveeattribs").
 * Weapons opt in with "special" in weapons.cfg; everything is cvar-tunable.
 *
 *  medkit  - primary fire: heal the teammate in front of you, or infect
 *            (bleed) an enemy; alt fire: slowly heal yourself.
 *  cashwad - the thrown jar buffs teammates where it lands (mini-crits, speed,
 *            a little health) instead of only applying the donor's effect.
 *  bomblets_dynamite / bomblets_gib - when the weapon's projectile explodes it
 *            scatters stock pipe grenades re-skinned as OF bomblets (OF
 *            SpawnBomblets, tf_projectile_bomblet.cpp); special_value > 0
 *            overrides the count.
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2>
#include <tf2_stocks>
#include <tf2cc>

native bool TF2CC_GetWeaponSpecial(int weapon, char[] special, int maxlen, float &value);
native bool TF2CC_ClientHasSpecial(int client, const char[] special);

public Plugin myinfo =
{
	name = "TF2CC Specials",
	author = "tf2cc-rework",
	description = "Legacy MarxVee item behaviours (medkit, cash wad)",
	version = TF2CC_VERSION,
	url = ""
};

#define HEAL_SOUND "items/smallmedkit1.wav"

ConVar g_cvMedRange, g_cvMedHeal, g_cvMedSelf, g_cvMedDelay, g_cvMedBleed;
ConVar g_cvCashRadius, g_cvCashDuration, g_cvCashHeal;
ConVar g_cvLgDamage, g_cvLgRange, g_cvLgWidth, g_cvLgBlastDamage, g_cvLgBlastRange, g_cvLgBlastAmmo, g_cvLgBlastDelay;
ConVar g_cvHookBash, g_cvHookKnock;
float g_flNextBlast[MAXPLAYERS + 1];
int g_iBeamLaser, g_iBeamGlow;
int g_iBackpack[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
bool g_bHoarder[MAXPLAYERS + 1];
#define ZAP_SOUND "weapons/barret_arm_zap.wav"
#define HOOK_HIT_SOUND "weapons/grappling_hook_impact_flesh.wav"
#define BACKPACK_MODEL "models/weapons/customclasses/w_models/merc_bp.mdl"
float g_flNextMed[MAXPLAYERS + 1];
float g_flInfectEnd[MAXPLAYERS + 1];
int g_iInfector[MAXPLAYERS + 1];
ConVar g_cvPf2Delay, g_cvPf2Heal, g_cvPf2Damage, g_cvPf2Range, g_cvPf2InfectTime, g_cvPf2InfectDmg, g_cvPf2InfectTick;

#define BOMBLET_MODEL "models/weapons/customclasses/w_models/w_grenade_bomblet.mdl"
#define DYNAMITE_MODEL "models/weapons/customclasses/w_models/w_dynamite.mdl"
#define NAIL_MODEL "models/weapons/w_models/w_nail.mdl"
#define DRG_BALL_MODEL "models/weapons/w_models/w_drg_ball.mdl"
bool g_bModelDrgBall;
char g_sBombLog[PLATFORM_MAX_PATH];
bool g_bModelNail;
int g_iNailModelIndex;
int g_iBurstShots[MAXPLAYERS + 1];
float g_flBurstLast[MAXPLAYERS + 1];
int g_iBurstWeapon[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
bool g_bModelDynamite;
#define BOMBLET_DYNAMITE 1
#define BOMBLET_GIB 2
#define BOMBLET_VARIANTS 3
#define BOMBLET_MAX 12
ConVar g_cvBombCount[BOMBLET_VARIANTS], g_cvBombDamage[BOMBLET_VARIANTS], g_cvBombRadius[BOMBLET_VARIANTS];
ConVar g_cvBombFuse[BOMBLET_VARIANTS], g_cvBombFuseRandom[BOMBLET_VARIANTS], g_cvBombImpact[BOMBLET_VARIANTS];
int g_iBombParent[2048];   // 0, or BOMBLET_* kind of a tracked parent projectile
int g_iBombCount[2048];    // count override from special_value
int g_iBombExplodeTick[2048];   // tick its TFExplosion was sent (0 = none)
float g_vecBombNormal[2048][3];
int g_iBomblet[2048];      // 0, or the kind of a spawned bomblet
bool g_bModelBomblet;
int g_iBombLive;
ConVar g_cvBombMaxLive, g_cvDynamiteImpact;
ConVar g_cvSawDps, g_cvSawTime, g_cvSawRadius;
int g_iSawVictim[MAXPLAYERS + 1];      // attacker -> victim userid being ground
float g_flSawEnd[MAXPLAYERS + 1];
float g_vecSawPos[MAXPLAYERS + 1][3];
int g_iSawLauncher[MAXPLAYERS + 1];
ArrayList g_ImpactList;   // entrefs of grenades that detonate on their first contact

/* OF tf_weapon_gatlinggun: Weapon_Gatling.WindUp/Fire/FireCrit/WindDown (94 dB). */
#define GAT_SND_WINDUP ")weapons/chaingun_windup.wav"
#define GAT_SND_FIRE ")weapons/chaingun_fire.wav"
#define GAT_SND_FIRE_CRIT ")weapons/chaingun_fire_crit.wav"
#define GAT_SND_WINDDOWN ")weapons/chaingun_winddown.wav"
#define GAT_LEVEL 94
#define GAT_FIRE_LEN 3.72
char GAT_SOUNDS[][] = { GAT_SND_WINDUP, GAT_SND_FIRE, GAT_SND_FIRE_CRIT, GAT_SND_WINDDOWN };
int g_iGatWeapon[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
int g_iGatState[MAXPLAYERS + 1];
float g_flGatNextFire[MAXPLAYERS + 1];
char g_sGatFire[MAXPLAYERS + 1][48];

#define CS_IDLE 0
#define CS_WINDUP 1
#define CS_FIRING 2
#define CS_SND_IDLE "weapons/chainsaw_idle.wav"
#define CS_SND_WINDUP "weapons/chainsaw_attack.wav"
#define CS_SND_FIRE "weapons/chainsaw_attack_loop.wav"
#define CS_SND_FIRE_CRIT "weapons/chainsaw_attack_crit.wav"
#define CS_SND_WINDDOWN "weapons/chainsaw_winddown.wav"
#define CS_SND_CHARGE "weapons/chainsaw_charge.wav"
#define CS_SND_DING "weapons/chainsaw_recharge.wav"
char CS_SOUNDS[][] = { CS_SND_IDLE, CS_SND_WINDUP, CS_SND_FIRE, CS_SND_FIRE_CRIT, CS_SND_WINDDOWN, CS_SND_CHARGE, CS_SND_DING };

ConVar g_cvCsDamage, g_cvCsInterval, g_cvCsRange, g_cvCsWindup, g_cvCsCharge, g_cvCsRecharge;
int g_iCsState[MAXPLAYERS + 1];
int g_iCsWeapon[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };   // chainsaw currently held (rev sound source)
float g_flCsNext[MAXPLAYERS + 1];        // wind-up end / next hit
float g_flCsNextSound[MAXPLAYERS + 1];
char g_sCsFireSound[MAXPLAYERS + 1][48];
float g_flCsChargeEnd[MAXPLAYERS + 1];
float g_flCsChargeReady[MAXPLAYERS + 1];
bool g_bCsDing[MAXPLAYERS + 1];
bool g_bCsAttack2[MAXPLAYERS + 1];


public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	MarkNativeAsOptional("TF2CC_GetWeaponSpecial");
	MarkNativeAsOptional("TF2CC_ClientHasSpecial");
	RegPluginLibrary("tf2cc_specials");
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvMedRange = CreateConVar("tf2cc_medkit_range", "110", "Medkit reach (units).");
	g_cvMedHeal = CreateConVar("tf2cc_medkit_heal", "20", "Medkit heal per use on a teammate.");
	g_cvMedSelf = CreateConVar("tf2cc_medkit_self_heal", "8", "Medkit alt-fire self heal per use.");
	g_cvMedDelay = CreateConVar("tf2cc_medkit_delay", "0.5", "Seconds between medkit uses.");
	g_cvMedBleed = CreateConVar("tf2cc_medkit_infect_time", "4", "Bleed seconds applied to an enemy (\"infect\").");
	g_cvCashRadius = CreateConVar("tf2cc_cashwad_radius", "250", "Cash wad buff radius.");
	g_cvCashDuration = CreateConVar("tf2cc_cashwad_duration", "5", "Cash wad buff duration.");
	g_cvCashHeal = CreateConVar("tf2cc_cashwad_heal", "25", "Cash wad instant heal for teammates in radius.");
	g_cvLgDamage = CreateConVar("tf2cc_lightning_damage", "8", "Lightning gun damage per beam tick (OF 8 / 0.05 s).");
	g_cvLgRange = CreateConVar("tf2cc_lightning_range", "720", "Lightning gun beam range (OF 720).");
	g_cvLgWidth = CreateConVar("tf2cc_lightning_width", "10", "Lightning gun beam half-width used for hit detection.");
	g_cvLgBlastDamage = CreateConVar("tf2cc_lightning_blast_damage", "45", "Alt-fire blast damage.");
	g_cvLgBlastRange = CreateConVar("tf2cc_lightning_blast_range", "1000", "Alt-fire blast range.");
	g_cvLgBlastAmmo = CreateConVar("tf2cc_lightning_blast_ammo", "20", "Alt-fire blast ammo cost (MarxVee 20).");
	g_cvLgBlastDelay = CreateConVar("tf2cc_lightning_blast_delay", "1.0", "Seconds between alt-fire blasts.");
	g_cvHookBash = CreateConVar("tf2cc_grapple_bash_damage", "40", "Damage when the grapple hook hits an enemy (MarxVee bash).");
	g_cvHookKnock = CreateConVar("tf2cc_grapple_bash_knockback", "450", "Knockback speed applied by the hook bash.");
	// PF2 syringe (pf2-src tf_weapon_syringe.cpp; pf2 scripts/tf_weapon_syringe.txt;
	// infection TF_INFECTION_DMG 8 / TF_INFECTION_FREQUENCY 2 s / 14 s).
	g_cvPf2Delay = CreateConVar("tf2cc_medkit_pf2_delay", "0.8", "PF2-style medkit swing delay (PF2 syringe TimeFireDelay 0.8).");
	g_cvPf2Heal = CreateConVar("tf2cc_medkit_pf2_heal", "50", "PF2-style medkit heal per hit on a teammate (PF2 Heal 50).");
	g_cvPf2Damage = CreateConVar("tf2cc_medkit_pf2_damage", "50", "PF2-style medkit damage per hit on an enemy (PF2 Damage 50).");
	g_cvPf2Range = CreateConVar("tf2cc_medkit_pf2_range", "48", "PF2-style medkit swing reach (PF2 48).");
	g_cvPf2InfectTime = CreateConVar("tf2cc_medkit_pf2_infect_time", "14", "PF2 infection duration.");
	g_cvPf2InfectDmg = CreateConVar("tf2cc_medkit_pf2_infect_damage", "8", "PF2 infection damage per tick.");
	g_cvPf2InfectTick = CreateConVar("tf2cc_medkit_pf2_infect_interval", "2.0", "PF2 infection tick interval.");
	// OF items_game: tf_weapon_dynamite_bundle 3 x 70 / 124, timer 1 (+0-1 s),
	// bounce until fuse; tf_weapon_gib 6 x 45 / 124, timer 1, BombletImpact 1.
	CreateBombletCvars(BOMBLET_DYNAMITE, "dynamite", "3", "70", "124", "0");
	CreateBombletCvars(BOMBLET_GIB, "gib", "6", "45", "124", "1");
	g_cvBombMaxLive = CreateConVar("tf2cc_bomblets_max_live", "96", "Cap on simultaneously live bomblets server-wide (edict budget).", _, true, 0.0);
	g_cvDynamiteImpact = CreateConVar("tf2cc_dynamite_impact", "1", "Dynamite bundles explode on their first contact (OF ExplodeOnImpact 1).", _, true, 0.0, true, 1.0);
	g_ImpactList = new ArrayList();
	// OF Saw Ballista (of_weapon_ripper.cpp): the blade slows to 5% while inside a target
	// and deals its damage every 0.03 s think; approximated as damage over contact time.
	g_cvSawDps = CreateConVar("tf2cc_sawblade_dps", "200", "Saw Ballista grind damage per second while the target stays at the hit point.", _, true, 0.0);
	g_cvSawTime = CreateConVar("tf2cc_sawblade_grind_time", "0.6", "Saw Ballista grind duration after a hit.", _, true, 0.0);
	g_cvSawRadius = CreateConVar("tf2cc_sawblade_radius", "60", "Distance from the hit point within which the target keeps being ground.", _, true, 0.0);
	CreateTimer(0.05, Timer_SawGrind, _, TIMER_REPEAT);
	g_cvCsDamage = CreateConVar("tf2cc_chainsaw_damage", "12", "Chainsaw damage per hit (OF Damage 12).", _, true, 0.0);
	g_cvCsInterval = CreateConVar("tf2cc_chainsaw_interval", "0.05", "Chainsaw seconds between hits (OF TimeFireDelay 0.05).", _, true, 0.01);
	g_cvCsRange = CreateConVar("tf2cc_chainsaw_range", "100", "Chainsaw reach (OF MeleeRange 100).", _, true, 0.0);
	g_cvCsWindup = CreateConVar("tf2cc_chainsaw_windup", "1.0", "Chainsaw wind-up before it cuts (OF_CHAINSAW_WINDUP_TIME 1.0; halved while charging).", _, true, 0.0);
	g_cvCsCharge = CreateConVar("tf2cc_chainsaw_charge_time", "3.0", "Chainsaw alt-fire charge length (OF ChargeDuration 1.5, measured 2x in game).", _, true, 0.0);
	g_cvCsRecharge = CreateConVar("tf2cc_chainsaw_charge_recharge", "8.0", "Seconds for the chainsaw charge to refill (OF ChargeRechargeRate 8).", _, true, 0.0);
	AddNormalSoundHook(Hook_ChainsawSounds);
	AddTempEntHook("TFExplosion", TE_TFExplosion);
	AutoExecConfig(true, "tf2cc_specials");
	CreateTimer(0.5, Timer_Infection, _, TIMER_REPEAT);
	AddCommandListener(Listener_ActionSlot, "+use_action_slot_item");
	AddCommandListener(Listener_ActionSlotUp, "-use_action_slot_item");
	HookEvent("player_spawn", Event_Spawn);
	HookEvent("player_death", Event_DeathStopLoops);
	AddTempEntHook("EffectDispatch", TE_EffectDispatch);
	CreateTimer(0.5, Timer_Perks, _, TIMER_REPEAT);
}

public void OnMapStart()
{
	g_iBombLive = 0;
	PrecacheSound(HEAL_SOUND, true);
	PrecacheSound(ZAP_SOUND, true);
	PrecacheSound(HOOK_HIT_SOUND, true);
	g_iBeamLaser = PrecacheModel("materials/sprites/laserbeam.vmt", true);
	g_iBeamGlow = PrecacheModel("materials/sprites/glow01.vmt", true);
	g_bModelBomblet = PrecacheModel(BOMBLET_MODEL, true) != 0;
	g_bModelDynamite = PrecacheModel(DYNAMITE_MODEL, true) != 0;
	g_iNailModelIndex = PrecacheModel(NAIL_MODEL, true);
	g_bModelNail = g_iNailModelIndex != 0;
	g_bModelDrgBall = PrecacheModel(DRG_BALL_MODEL, true) != 0;
	BuildPath(Path_SM, g_sBombLog, sizeof(g_sBombLog), "logs/tf2cc_bomblets.log");
	ParticleIndex("drg_cow_explosioncore_normal");
	ParticleIndex("drg_cow_explosioncore_normal_blue");
	ParticleIndex("drg_cow_rockettrail_normal");
	ParticleIndex("drg_cow_rockettrail_normal_blue");
	for (int i = 0; i < sizeof(CS_SOUNDS); i++)
		PrecacheSound(CS_SOUNDS[i], true);
	for (int i = 0; i < sizeof(GAT_SOUNDS); i++)
		PrecacheSound(GAT_SOUNDS[i], true);
}

bool ActiveSpecial(int client, char[] special, int maxlen)
{
	if (!LibraryExists("tf2cc_weapons") || TF2CC_GetRole(client) == TF2CC_ROLE_NONE)
		return false;
	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	float v;
	return weapon > MaxClients && TF2CC_GetWeaponSpecial(weapon, special, maxlen, v);
}

/* ---------------- medkit ---------------- */

/* ========================================================================= */
/* Burst fire (OF assault rifle: BurstSize 3, TimeFireDelay 0.07,            */
/* BurstFireDelay 0.30; one press fires the whole burst). Special "burst",   */
/* value = delay after a burst.                                              */
/* ========================================================================= */

/** Called per shot from TF2_CalcIsAttackCritical. */
void BurstOnAttack(int client, int weapon, const char[] special, float v)
{
	if (!StrEqual(special, "burst"))
		return;
	float now = GetGameTime();
	if (now - g_flBurstLast[client] > 0.25 || EntRefToEntIndex(g_iBurstWeapon[client]) != weapon)
		g_iBurstShots[client] = 0;
	g_flBurstLast[client] = now;
	g_iBurstWeapon[client] = EntIndexToEntRef(weapon);
	if (++g_iBurstShots[client] >= 3)
	{
		g_iBurstShots[client] = 0;
		// PrimaryAttack sets m_flNextPrimaryAttack after this forward: push it next frame.
		DataPack dp = new DataPack();
		dp.WriteCell(EntIndexToEntRef(weapon));
		dp.WriteFloat(now + 0.07 + (v > 0.0 ? v : 0.30));
		RequestFrame(Frame_BurstPause, dp);
	}
}

public void Frame_BurstPause(DataPack dp)
{
	dp.Reset();
	int weapon = EntRefToEntIndex(dp.ReadCell());
	float next = dp.ReadFloat();
	delete dp;
	if (weapon > MaxClients && GetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack") < next)
		SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", next);
}

/** Mid-burst the trigger stays held (server-side) until the burst is out. */
bool BurstHold(int client, int &buttons)
{
	if (g_iBurstShots[client] <= 0 || GetGameTime() - g_flBurstLast[client] > 0.2 || (buttons & IN_ATTACK))
		return false;
	int act = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (act <= MaxClients || EntRefToEntIndex(g_iBurstWeapon[client]) != act || GetEntProp(act, Prop_Send, "m_iClip1") <= 0)
	{
		g_iBurstShots[client] = 0;
		return false;
	}
	buttons |= IN_ATTACK;
	return true;
}

/**
 * Syringe-gun projectiles are client-side temp entities drawn from the
 * "ClientProjectile_Syringe" effect, whose m_nMaterial is the model index
 * (the server entity is never sent). Nailgun shots get the nail model for
 * every other client; the shooter's own predicted copies stay syringes.
 */
public Action TE_EffectDispatch(const char[] te_name, const int[] players, int numClients, float delay)
{
	if (!g_bModelNail)
		return Plugin_Continue;
	static int table = INVALID_STRING_TABLE;
	static int syringeIdx = -1;
	if (table == INVALID_STRING_TABLE)
		table = FindStringTable("EffectDispatch");
	if (table == INVALID_STRING_TABLE)
		return Plugin_Continue;
	if (syringeIdx < 0)
		syringeIdx = FindStringIndex(table, "ClientProjectile_Syringe");
	if (syringeIdx < 0 || TE_ReadNum("m_iEffectName") != syringeIdx)
		return Plugin_Continue;
	int owner = TE_ReadNum("entindex");
	if (owner < 1 || owner > MaxClients || !IsClientInGame(owner))
		return Plugin_Continue;
	char special[32];
	if (ActiveSpecial(owner, special, sizeof(special)) && StrEqual(special, "nails"))
		TE_WriteNum("m_nMaterial", g_iNailModelIndex);
	return Plugin_Continue;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
	bool burstHeld = IsPlayerAlive(client) && BurstHold(client, buttons);
	Action r = RunCmdSpecials(client, buttons, impulse, weapon);
	return burstHeld && r == Plugin_Continue ? Plugin_Changed : r;
}

Action RunCmdSpecials(int client, int &buttons, int &impulse, int &weapon)
{
	if (IsPlayerAlive(client))
		GatlingThink(client);
	if (IsPlayerAlive(client) && ChainsawThink(client, buttons))
		return Plugin_Changed;
	if (!(buttons & (IN_ATTACK | IN_ATTACK2)) || !IsPlayerAlive(client))
		return Plugin_Continue;
	char special[32];
	if (!ActiveSpecial(client, special, sizeof(special)))
		return Plugin_Continue;
	if (StrContains(special, "lightning") == 0)
	{
		// Open Fortress has no alt-fire; the MarxVee profile adds the 20-ammo blast.
		if (StrEqual(special, "lightning_marxvee") && (buttons & IN_ATTACK2) && GetGameTime() >= g_flNextBlast[client])
			LightningBlast(client);
		return Plugin_Continue;
	}
	if (StrEqual(special, "medkit_pf2"))
	{
		if ((buttons & IN_ATTACK) && GetGameTime() >= g_flNextMed[client])
			MedkitPF2(client);
		return Plugin_Continue;
	}
	if (!StrEqual(special, "medkit") || GetGameTime() < g_flNextMed[client])
		return Plugin_Continue;

	g_flNextMed[client] = GetGameTime() + g_cvMedDelay.FloatValue;
	if (buttons & IN_ATTACK)
	{
		int target = TraceFront(client, g_cvMedRange.FloatValue);
		if (target > 0)
		{
			if (GetClientTeam(target) == GetClientTeam(client))
				Heal(target, g_cvMedHeal.IntValue);
			else
				TF2_MakeBleed(target, client, g_cvMedBleed.FloatValue);
			EmitSoundToAll(HEAL_SOUND, client);
		}
	}
	else
	{
		Heal(client, g_cvMedSelf.IntValue);
	}
	return Plugin_Continue;
}

int TraceFront(int client, float range)
{
	float eye[3], ang[3], dir[3], end[3];
	GetClientEyePosition(client, eye);
	GetClientEyeAngles(client, ang);
	GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(dir, range);
	AddVectors(eye, dir, end);
	Handle tr = TR_TraceHullFilterEx(eye, end, view_as<float>({ -12.0, -12.0, -12.0 }), view_as<float>({ 12.0, 12.0, 12.0 }),
		MASK_SHOT, Filter_NotSelf, client);
	int hit = TR_GetEntityIndex(tr);
	delete tr;
	return (hit >= 1 && hit <= MaxClients && IsPlayerAlive(hit)) ? hit : -1;
}

public bool Filter_NotSelf(int entity, int mask, int client)
{
	return entity != client;
}

void Heal(int client, int amount)
{
	int res = GetPlayerResourceEntity();
	int maxHealth = res != -1 ? GetEntProp(res, Prop_Send, "m_iMaxHealth", _, client) : 0;
	if (maxHealth <= 0)
		maxHealth = GetEntProp(client, Prop_Data, "m_iMaxHealth");
	int health = GetClientHealth(client);
	if (health >= maxHealth)
		return;
	int newHealth = health + amount > maxHealth ? maxHealth : health + amount;
	SetEntityHealth(client, newHealth);
	Event ev = CreateEvent("player_healonhit", true);
	if (ev != null)
	{
		ev.SetInt("amount", newHealth - health);
		ev.SetInt("entindex", client);
		ev.Fire();
	}
}

/* ---------------- cash wad ---------------- */

public void OnEntityCreated(int entity, const char[] classname)
{
	if (StrContains(classname, "tf_projectile_jar") == 0)
		SDKHook(entity, SDKHook_SpawnPost, Hook_JarSpawned);
	else if (StrEqual(classname, "tf_projectile_grapplinghook"))
		SDKHook(entity, SDKHook_SpawnPost, Hook_GrappleSpawned);
	else if (StrEqual(classname, "tf_projectile_rocket") || StrContains(classname, "tf_projectile_pipe") == 0)
		SDKHook(entity, SDKHook_SpawnPost, Hook_BombParentSpawned);
	else if (StrEqual(classname, "tf_projectile_healing_bolt") || StrEqual(classname, "tf_projectile_arrow"))
		SDKHook(entity, SDKHook_SpawnPost, Hook_SawSpawned);
	else if (StrEqual(classname, "tf_projectile_syringe"))
		SDKHook(entity, SDKHook_SpawnPost, Hook_NailSpawned);
}

/**
 * Loop sources live on the weapon and were only stopped from OnPlayerRunCmd
 * while alive: death, disconnect or removal of the weapon left the chaingun
 * fire / chainsaw idle playing for everyone.
 */
void StopLoopSounds(int client)
{
	int gat = EntRefToEntIndex(g_iGatWeapon[client]);
	if (gat > MaxClients)
		GatlingStop(client, gat, false);
	g_iGatWeapon[client] = INVALID_ENT_REFERENCE;
	g_iGatState[client] = 0;
	g_sGatFire[client][0] = '\0';
	int cs = EntRefToEntIndex(g_iCsWeapon[client]);
	if (cs > MaxClients)
		ChainsawStop(client, cs);
}

public void Event_DeathStopLoops(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client)
		StopLoopSounds(client);
}

public void OnEntityDestroyed(int entity)
{
	if (entity > MaxClients && IsValidEdict(entity))
	{
		int ref = EntIndexToEntRef(entity);
		for (int i = 1; i <= MaxClients; i++)
			if (g_iGatWeapon[i] == ref || g_iCsWeapon[i] == ref)
				StopLoopSounds(i);
	}
	if (entity <= MaxClients || entity >= sizeof(g_iBombParent))
		return;
	if (g_iBomblet[entity])
	{
		g_iBomblet[entity] = 0;
		if (g_iBombLive > 0)
			g_iBombLive--;
	}
	int kind = g_iBombParent[entity];
	if (!kind)
		return;
	g_iBombParent[entity] = 0;
	// Explode() removes the projectile in the tick it sends the explosion;
	// anything else (owner died, round reset, fizzle, a nearby blast) spawns nothing.
	if (g_iBombExplodeTick[entity] != GetGameTickCount())
		return;
	// Never create entities while one is being deleted: spawn next frame.
	DataPack dp = new DataPack();
	float pos[3];
	GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", pos);
	bool pipe = HasEntProp(entity, Prop_Send, "m_hThrower");
	int owner = GetEntPropEnt(entity, Prop_Send, pipe ? "m_hThrower" : "m_hOwnerEntity");
	dp.WriteCell(kind);
	dp.WriteCell(g_iBombCount[entity]);
	dp.WriteCell(owner > 0 && owner <= MaxClients ? GetClientUserId(owner) : 0);
	int launcher = GetEntPropEnt(entity, Prop_Send, "m_hOriginalLauncher");
	dp.WriteCell(launcher > MaxClients ? EntIndexToEntRef(launcher) : INVALID_ENT_REFERENCE);
	dp.WriteCell(GetEntProp(entity, Prop_Send, "m_iTeamNum"));
	dp.WriteCell(HasEntProp(entity, Prop_Send, "m_bCritical") ? GetEntProp(entity, Prop_Send, "m_bCritical") : 0);
	dp.WriteFloatArray(pos, 3);
	dp.WriteFloatArray(g_vecBombNormal[entity], 3);
	RequestFrame(Frame_SpawnBomblets, dp);
}

public void Hook_JarSpawned(int jar)
{
	RequestFrame(Frame_CheckJar, EntIndexToEntRef(jar));
}

public void Frame_CheckJar(int ref)
{
	int jar = EntRefToEntIndex(ref);
	if (jar <= MaxClients || !HasEntProp(jar, Prop_Send, "m_hThrower"))
		return;
	int owner = GetEntPropEnt(jar, Prop_Send, "m_hThrower");
	char special[32];
	if (owner < 1 || owner > MaxClients || !IsClientInGame(owner) || !ActiveSpecial(owner, special, sizeof(special))
		|| !StrEqual(special, "cashwad"))
		return;
	SDKHook(jar, SDKHook_StartTouchPost, Hook_JarTouch);
}

public void Hook_JarTouch(int jar, int other)
{
	if (!HasEntProp(jar, Prop_Send, "m_hThrower"))
		return;
	int owner = GetEntPropEnt(jar, Prop_Send, "m_hThrower");
	if (owner < 1 || owner > MaxClients || !IsClientInGame(owner))
		return;
	SDKUnhook(jar, SDKHook_StartTouchPost, Hook_JarTouch);

	float pos[3], tpos[3];
	GetEntPropVector(jar, Prop_Data, "m_vecAbsOrigin", pos);
	float radius = g_cvCashRadius.FloatValue, dur = g_cvCashDuration.FloatValue;
	int team = GetClientTeam(owner);
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != team)
			continue;
		GetClientAbsOrigin(i, tpos);
		if (GetVectorDistance(pos, tpos) > radius)
			continue;
		TF2_AddCondition(i, TFCond_Buffed, dur, owner);
		TF2_AddCondition(i, TFCond_SpeedBuffAlly, dur, owner);
		Heal(i, g_cvCashHeal.IntValue);
	}
}

/* ========================================================================= */
/* Lightning gun (port of MarxVee marxveeattribs FireLightning)              */
/* ========================================================================= */

/**
 * Donor: projectile-less, clipless syringe gun. Every shot the game makes
 * fires one beam; hits use a segment-distance test against players and
 * buildings, crits honoured (DMG_ACID is TF2's crit flag, MarxVee 1048576).
 */
public Action TF2_CalcIsAttackCritical(int client, int weapon, char[] weaponname, bool &result)
{
	if (client < 1 || client > MaxClients || weapon <= MaxClients || !LibraryExists("tf2cc_weapons"))
		return Plugin_Continue;
	char special[32];
	float value;
	if (!TF2CC_GetWeaponSpecial(weapon, special, sizeof(special), value))
		return Plugin_Continue;
	BurstOnAttack(client, weapon, special, value);
	if (StrContains(special, "lightning") != 0)
		return Plugin_Continue;
	FireBeam(client, weapon, g_cvLgDamage.FloatValue, g_cvLgRange.FloatValue, g_cvLgWidth.FloatValue, 0.06, result || IsCritBoosted(client));
	return Plugin_Continue;
}

void LightningBlast(int client)
{
	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (weapon <= MaxClients)
		return;
	int type = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
	int cost = g_cvLgBlastAmmo.IntValue;
	if (type <= 0 || GetEntProp(client, Prop_Send, "m_iAmmo", _, type) < cost)
		return;
	SetEntProp(client, Prop_Send, "m_iAmmo", GetEntProp(client, Prop_Send, "m_iAmmo", _, type) - cost, _, type);
	g_flNextBlast[client] = GetGameTime() + g_cvLgBlastDelay.FloatValue;
	FireBeam(client, weapon, g_cvLgBlastDamage.FloatValue, g_cvLgBlastRange.FloatValue, g_cvLgWidth.FloatValue * 1.6, 0.25, IsCritBoosted(client));
	EmitSoundToAll(ZAP_SOUND, client);
}

void FireBeam(int client, int weapon, float damage, float range, float width, float life, bool crit)
{
	float eye[3], ang[3], dir[3], end[3];
	GetClientEyePosition(client, eye);
	GetClientEyeAngles(client, ang);
	GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
	end = dir;
	ScaleVector(end, range);
	AddVectors(eye, end, end);
	Handle tr = TR_TraceRayFilterEx(eye, end, MASK_SOLID_BRUSHONLY, RayType_EndPoint, Filter_NotSelf, client);
	TR_GetEndPosition(end, tr);
	delete tr;

	int team = GetClientTeam(client);
	int dmgType = DMG_SHOCK | (crit ? DMG_ACID : 0);
	float pos[3];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == client || !IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) == team)
			continue;
		GetClientEyePosition(i, pos);
		pos[2] -= 24.0;
		if (SegmentDistance(pos, eye, end) <= width + 24.0)
			SDKHooks_TakeDamage(i, client, client, damage, dmgType, weapon);
	}
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "obj_*")) != -1)
	{
		if (GetEntProp(ent, Prop_Send, "m_iTeamNum") == team)
			continue;
		GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", pos);
		pos[2] += 20.0;
		if (SegmentDistance(pos, eye, end) <= width + 20.0)
			SDKHooks_TakeDamage(ent, client, client, damage * 2.0, dmgType, weapon);
	}

	// Visuals: four layered team-coloured beams plus a glow (MarxVee palette).
	int r = 240, g = 129, b = 73;                       // RED F08149
	if (team == 3) { r = 239; g = 152; b = 73; }        // BLU EF9849
	if (crit) { if (team == 2) { r = 184; g = 56; b = 59; } else { r = 88; g = 133; b = 162; } }
	float start[3], right[3], fwd[3];
	start = eye;
	GetAngleVectors(ang, fwd, right, NULL_VECTOR);
	ScaleVector(right, 8.0);
	ScaleVector(fwd, 16.0);
	AddVectors(start, right, start);
	AddVectors(start, fwd, start);
	start[2] -= 10.0;
	int color[4];
	for (int l = 0; l < 4; l++)
	{
		int k = 4 + l;  // outer layers lighter, inner layer the team colour
		color[0] = (r * k + 255 * (7 - k)) / 7;
		color[1] = (g * k + 255 * (7 - k)) / 7;
		color[2] = (b * k + 255 * (7 - k)) / 7;
		color[3] = 255;
		float w = width * (0.3 + 0.23 * float(l)) * 1.28;
		TE_SetupBeamPoints(start, end, g_iBeamLaser, 0, 0, 0, life, w, w, 0, 1.0, color, 3);
		TE_SendToAll();
	}
	color[0] = r; color[1] = g; color[2] = b; color[3] = 255;
	TE_SetupBeamPoints(start, end, g_iBeamGlow, 0, 0, 0, life, width * 1.28, width * 1.28, 0, 5.0, color, 0);
	TE_SendToAll();
}

float SegmentDistance(const float p[3], const float a[3], const float b[3])
{
	float ab[3], ap[3], proj[3];
	SubtractVectors(b, a, ab);
	SubtractVectors(p, a, ap);
	float len2 = GetVectorDotProduct(ab, ab);
	float t = len2 > 0.0 ? GetVectorDotProduct(ap, ab) / len2 : 0.0;
	if (t < 0.0) t = 0.0;
	if (t > 1.0) t = 1.0;
	proj = ab;
	ScaleVector(proj, t);
	AddVectors(a, proj, proj);
	return GetVectorDistance(p, proj);
}

/* ========================================================================= */
/* Grappling hook (MarxVee "O.G. Kit": stock hook in the utility slot)       */
/* ========================================================================= */

// The stock action-slot key only switches to the hook when Mannpower
// (tf_grapplinghook_enable) is on; for role players with a hook we switch to it
// directly through Weapon_Switch ("use") and back on release. The pull itself
// (TF_COND_GRAPPLINGHOOK) is shared movement code and needs no cvar.
public Action Listener_ActionSlot(int client, const char[] command, int argc)
{
	if (!TF2CC_IsValidClient(client) || !IsPlayerAlive(client) || !HasHook(client))
		return Plugin_Continue;
	FakeClientCommandEx(client, "use tf_weapon_grapplinghook");
	return Plugin_Handled;
}

public Action Listener_ActionSlotUp(int client, const char[] command, int argc)
{
	if (!TF2CC_IsValidClient(client) || !IsPlayerAlive(client) || !HasHook(client))
		return Plugin_Continue;
	int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	char cls[48];
	if (active > MaxClients && GetEntityClassname(active, cls, sizeof(cls)) && StrEqual(cls, "tf_weapon_grapplinghook"))
		FakeClientCommandEx(client, "lastinv");
	return Plugin_Handled;
}

bool HasHook(int client)
{
	return LibraryExists("tf2cc_weapons") && TF2CC_GetRole(client) != TF2CC_ROLE_NONE && TF2CC_ClientHasSpecial(client, "grapple");
}

public void Hook_GrappleSpawned(int hook)
{
	SDKHook(hook, SDKHook_StartTouchPost, Hook_GrappleTouch);
}

public void Hook_GrappleTouch(int hook, int other)
{
	if (other < 1 || other > MaxClients || !IsPlayerAlive(other))
		return;
	int owner = GetEntPropEnt(hook, Prop_Send, "m_hOwnerEntity");
	if (owner < 1 || owner > MaxClients || !IsClientInGame(owner) || GetClientTeam(owner) == GetClientTeam(other) || !HasHook(owner))
		return;
	SDKUnhook(hook, SDKHook_StartTouchPost, Hook_GrappleTouch);
	// MarxVee: a hook that hits an enemy bashes them for high damage and knockback.
	float a[3], b[3], v[3];
	GetClientAbsOrigin(owner, a);
	GetClientAbsOrigin(other, b);
	MakeVectorFromPoints(a, b, v);
	NormalizeVector(v, v);
	ScaleVector(v, g_cvHookKnock.FloatValue);
	v[2] += 250.0;
	SDKHooks_TakeDamage(other, owner, owner, g_cvHookBash.FloatValue, DMG_CLUB);
	TeleportEntity(other, NULL_VECTOR, NULL_VECTOR, v);
	EmitSoundToAll(HOOK_HIT_SOUND, other);
}

/* ========================================================================= */
/* Hoarder's Stash perk: backpack visual and no autohop (tf2cc_movement asks */
/* TF2CC_ClientHasSpecial); the ammo bonus lives in tf2cc_weapons.          */
/* ========================================================================= */

public Action Timer_Perks(Handle timer)
{
	if (!LibraryExists("tf2cc_weapons"))
		return Plugin_Continue;
	for (int i = 1; i <= MaxClients; i++)
	{
		bool want = IsClientInGame(i) && IsPlayerAlive(i) && TF2CC_GetRole(i) != TF2CC_ROLE_NONE && TF2CC_ClientHasSpecial(i, "hoarder");
		if (want == g_bHoarder[i])
			continue;
		g_bHoarder[i] = want;
		if (want)
			AttachBackpack(i);
		else
			RemoveBackpack(i);
	}
	return Plugin_Continue;
}

public void Event_Spawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client)
	{
		RemoveBackpack(client);
		g_bHoarder[client] = false;
	}
}

void AttachBackpack(int client)
{
	if (!FileExists(BACKPACK_MODEL, true))
		return;
	PrecacheModel(BACKPACK_MODEL, true);
	int prop = CreateEntityByName("prop_dynamic_override");
	if (prop == -1)
		return;
	DispatchKeyValue(prop, "model", BACKPACK_MODEL);
	DispatchKeyValue(prop, "solid", "0");
	DispatchSpawn(prop);
	SetEntProp(prop, Prop_Send, "m_fEffects", 0x001 | 0x080);   // bonemerge + fastcull; merc_bp is rigged to the soldier skeleton the Merc uses
	SetVariantString("!activator");
	AcceptEntityInput(prop, "SetParent", client);
	SDKHook(prop, SDKHook_SetTransmit, Hook_BackpackTransmit);
	g_iBackpack[client] = EntIndexToEntRef(prop);
}

public Action Hook_BackpackTransmit(int prop, int viewer)
{
	// The owner in first person must not see his own backpack.
	int owner = GetEntPropEnt(prop, Prop_Data, "m_pParent");
	if (viewer == owner && GetEntProp(owner, Prop_Send, "m_nForceTauntCam") == 0)
		return Plugin_Handled;
	return Plugin_Continue;
}

void RemoveBackpack(int client)
{
	int prop = EntRefToEntIndex(g_iBackpack[client]);
	if (prop > MaxClients)
		RemoveEntity(prop);
	g_iBackpack[client] = INVALID_ENT_REFERENCE;
}

bool IsCritBoosted(int client)
{
	static const TFCond crits[] = { TFCond_Kritzkrieged, TFCond_CritOnFirstBlood, TFCond_CritOnWin, TFCond_CritOnFlagCapture,
		TFCond_CritOnKill, TFCond_CritMmmph, TFCond_CritOnDamage, TFCond_CritCanteen, TFCond_HalloweenCritCandy, TFCond_CritRuneTemp };
	for (int i = 0; i < sizeof(crits); i++)
		if (TF2_IsPlayerInCondition(client, crits[i]))
			return true;
	return false;
}

/* ========================================================================= */
/* PF2-style medkit (default): CTFSyringe::OnEntityHit                        */
/* ========================================================================= */

float g_flNextInfectTick[MAXPLAYERS + 1];

void MedkitPF2(int client)
{
	g_flNextMed[client] = GetGameTime() + g_cvPf2Delay.FloatValue;
	float eye[3], ang[3], dir[3], end[3];
	GetClientEyePosition(client, eye);
	GetClientEyeAngles(client, ang);
	GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(dir, g_cvPf2Range.FloatValue);
	AddVectors(eye, dir, end);
	Handle tr = TR_TraceRayFilterEx(eye, end, MASK_SOLID, RayType_EndPoint, Filter_NotSelf, client);
	if (!TR_DidHit(tr))
	{
		delete tr;
		tr = TR_TraceHullFilterEx(eye, end, view_as<float>({ -18.0, -18.0, -18.0 }), view_as<float>({ 18.0, 18.0, 18.0 }),
			MASK_SOLID, Filter_NotSelf, client);
	}
	int hit = TR_GetEntityIndex(tr);
	delete tr;
	if (hit < 1 || hit > MaxClients || !IsPlayerAlive(hit))
		return;

	if (GetClientTeam(hit) != GetClientTeam(client))
	{
		SDKHooks_TakeDamage(hit, client, client, g_cvPf2Damage.FloatValue, DMG_CLUB);
		g_iInfector[hit] = GetClientUserId(client);
		g_flInfectEnd[hit] = GetGameTime() + g_cvPf2InfectTime.FloatValue;
		g_flNextInfectTick[hit] = GetGameTime() + g_cvPf2InfectTick.FloatValue;
		return;
	}
	// Teammate: cleanse, then heal up to max health (no overheal).
	TF2_RemoveCondition(hit, TFCond_OnFire);
	TF2_RemoveCondition(hit, TFCond_Bleeding);
	g_flInfectEnd[hit] = 0.0;
	Heal(hit, g_cvPf2Heal.IntValue);
	EmitSoundToAll(HEAL_SOUND, hit);
	Event ev = CreateEvent("player_healed", true);
	if (ev != null)
	{
		ev.SetInt("priority", 1);
		ev.SetInt("patient", GetClientUserId(hit));
		ev.SetInt("healer", GetClientUserId(client));
		ev.SetInt("amount", g_cvPf2Heal.IntValue);
		ev.Fire();
	}
}

public Action Timer_Infection(Handle timer)
{
	float now = GetGameTime();
	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_flInfectEnd[i] <= now || !IsClientInGame(i) || !IsPlayerAlive(i))
		{
			g_flInfectEnd[i] = 0.0;
			continue;
		}
		if (now < g_flNextInfectTick[i])
			continue;
		g_flNextInfectTick[i] = now + g_cvPf2InfectTick.FloatValue;
		int attacker = GetClientOfUserId(g_iInfector[i]);
		SDKHooks_TakeDamage(i, attacker ? attacker : i, attacker ? attacker : i, g_cvPf2InfectDmg.FloatValue, DMG_PREVENT_PHYSICS_FORCE | DMG_POISON);
	}
	return Plugin_Continue;
}

/* ========================================================================= */
/* Bomblets (OF DropBomblets: tf_projectile_bomblet.cpp SpawnBomblets)       */
/* ========================================================================= */

/**
 * The parent's explosion is recognised by TF2's own TFExplosion temp entity
 * at the projectile's position, which also carries the impact normal OF fans
 * the bomblets around. Projectiles removed without exploding spawn nothing.
 * Bomblets are stock tf_projectile_pipe grenades (server-side physics, no
 * client prediction involved) with the OF bomblet model, damage, radius and
 * fuse written to their networked/datamap fields; kill credit goes to the
 * thrower with the donor launcher. No gamedata, no SDKCalls.
 */
void CreateBombletCvars(int v, const char[] name, const char[] count, const char[] damage, const char[] radius, const char[] impact)
{
	char cv[64], desc[160];
	FormatEx(cv, sizeof(cv), "tf2cc_bomblets_%s_count", name);
	FormatEx(desc, sizeof(desc), "Bomblets per %s explosion (0 disables; max %d).", name, BOMBLET_MAX);
	g_cvBombCount[v] = CreateConVar(cv, count, desc, _, true, 0.0, true, float(BOMBLET_MAX));
	FormatEx(cv, sizeof(cv), "tf2cc_bomblets_%s_damage", name);
	g_cvBombDamage[v] = CreateConVar(cv, damage, "Damage of each bomblet.", _, true, 0.0);
	FormatEx(cv, sizeof(cv), "tf2cc_bomblets_%s_radius", name);
	g_cvBombRadius[v] = CreateConVar(cv, radius, "Blast radius of each bomblet.", _, true, 0.0);
	FormatEx(cv, sizeof(cv), "tf2cc_bomblets_%s_fuse", name);
	g_cvBombFuse[v] = CreateConVar(cv, "1.0", "Bomblet fuse (OF BombletTimer).", _, true, 0.0);
	FormatEx(cv, sizeof(cv), "tf2cc_bomblets_%s_fuse_random", name);
	g_cvBombFuseRandom[v] = CreateConVar(cv, "1.0", "Random extra fuse 0..N seconds per bomblet (OF adds 0-1).", _, true, 0.0);
	FormatEx(cv, sizeof(cv), "tf2cc_bomblets_%s_impact", name);
	g_cvBombImpact[v] = CreateConVar(cv, impact, "1 = bomblets explode on any impact (OF BombletImpact), 0 = bounce until the fuse.", _, true, 0.0, true, 1.0);
}

int BombletVariant(const char[] special)
{
	if (StrEqual(special, "bomblets_dynamite"))
		return BOMBLET_DYNAMITE;
	if (StrEqual(special, "bomblets_gib"))
		return BOMBLET_GIB;
	return 0;
}

public void Hook_BombParentSpawned(int entity)
{
	if (entity < sizeof(g_iBombParent) && !g_iBomblet[entity])
		RequestFrame(Frame_CheckBombParent, EntIndexToEntRef(entity));
}

public void Frame_CheckBombParent(int ref)
{
	int entity = EntRefToEntIndex(ref);
	if (entity <= MaxClients || g_iBomblet[entity] || !LibraryExists("tf2cc_weapons")
		|| !HasEntProp(entity, Prop_Send, "m_hOriginalLauncher"))
		return;
	int launcher = GetEntPropEnt(entity, Prop_Send, "m_hOriginalLauncher");
	char special[32];
	float value;
	if (launcher <= MaxClients || !TF2CC_GetWeaponSpecial(launcher, special, sizeof(special), value))
		return;
	int kind = BombletVariant(special);
	if (!kind)
		return;
	g_iBombParent[entity] = kind;
	g_iBombCount[entity] = value > 0.0 ? RoundToFloor(value) : 0;
	char cls[64];
	GetEntityClassname(entity, cls, sizeof(cls));
	if (kind == BOMBLET_DYNAMITE && g_cvDynamiteImpact.BoolValue && StrEqual(cls, "tf_projectile_pipe"))
		g_ImpactList.Push(EntIndexToEntRef(entity));
	// The thrown bundle looks like dynamite (OF ProjectileModel w_dynamite).
	if (kind == BOMBLET_DYNAMITE && g_bModelDynamite)
		SetEntityModel(entity, DYNAMITE_MODEL);
	// OF GIB fires an energy ball (ProjectileType projectile_coom): Cow Mangler
	// ball model + its team-coloured trail as the stock stand-in.
	if (kind == BOMBLET_GIB && StrEqual(cls, "tf_projectile_rocket"))
	{
		if (g_bModelDrgBall)
			SetEntityModel(entity, DRG_BALL_MODEL);
		AttachTrail(entity, GetEntProp(entity, Prop_Send, "m_iTeamNum") == 3 ? "drg_cow_rockettrail_normal_blue" : "drg_cow_rockettrail_normal");
	}
	LogToFileEx(g_sBombLog, "parent %d %s kind %d launcher %d", entity, cls, kind, launcher);
	g_iBombExplodeTick[entity] = 0;
}

public Action TE_TFExplosion(const char[] te_name, const int[] players, int numClients, float delay)
{
	float origin[3], normal[3], pos[3];
	origin[0] = TE_ReadFloat("m_vecOrigin[0]");
	origin[1] = TE_ReadFloat("m_vecOrigin[1]");
	origin[2] = TE_ReadFloat("m_vecOrigin[2]");
	TE_ReadVector("m_vecNormal", normal);
	int entity = -1;
	while ((entity = FindEntityByClassname(entity, "tf_projectile_*")) != -1)
	{
		// OF GIB ExplosionEffect mlg_explosion_primary (bomblets too): team-coloured
		// energy blast; stock clients cannot load OF's .pcf, the Cow Mangler's is closest.
		if (entity < sizeof(g_iBomblet) && (g_iBomblet[entity] == BOMBLET_GIB || g_iBombParent[entity] == BOMBLET_GIB))
		{
			GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", pos);
			if (GetVectorDistance(pos, origin, true) <= 48.0 * 48.0)
			{
				int fx = ParticleIndex(GetEntProp(entity, Prop_Send, "m_iTeamNum") == 3 ? "drg_cow_explosioncore_normal_blue" : "drg_cow_explosioncore_normal");
				if (fx != INVALID_STRING_INDEX)
					TE_WriteNum("m_iCustomParticleIndex", fx);
			}
		}
		if (entity >= sizeof(g_iBombParent) || !g_iBombParent[entity] || g_iBombExplodeTick[entity] == GetGameTickCount())
			continue;
		GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", pos);
		if (GetVectorDistance(pos, origin, true) > 48.0 * 48.0)
			continue;
		g_iBombExplodeTick[entity] = GetGameTickCount();
		for (int i = 0; i < 3; i++)
			g_vecBombNormal[entity][i] = normal[i];
		LogToFileEx(g_sBombLog, "explosion matched parent %d kind %d", entity, g_iBombParent[entity]);
		break;
	}
	return Plugin_Continue;
}

public void Frame_SpawnBomblets(DataPack dp)
{
	dp.Reset();
	int kind = dp.ReadCell();
	int count = dp.ReadCell();
	int owner = GetClientOfUserId(dp.ReadCell());
	int launcher = EntRefToEntIndex(dp.ReadCell());
	int team = dp.ReadCell();
	bool crit = dp.ReadCell() != 0;
	float pos[3], normal[3];
	dp.ReadFloatArray(pos, 3);
	dp.ReadFloatArray(normal, 3);
	delete dp;

	if (count <= 0)
		count = g_cvBombCount[kind].IntValue;
	if (count > BOMBLET_MAX)
		count = BOMBLET_MAX;
	LogToFileEx(g_sBombLog, "spawn bomblets kind %d count %d owner %d", kind, count, owner);
	if (count <= 0 || owner < 1 || !IsClientInGame(owner))
		return;
	if (NormalizeVector(normal, normal) < 0.5)
	{
		normal[0] = 0.0;   // mid-air / sticky det traces down
		normal[1] = 0.0;
		normal[2] = 1.0;
	}

	// OF: spawn 4 units off the surface, pitch the normal by 40-60 degrees and
	// rotate it evenly around the normal, 275-300 u/s each.
	float base[3], ang[3], src[3];
	GetVectorAngles(normal, ang);
	ang[0] += GetRandomFloat(40.0, 60.0);
	GetAngleVectors(ang, base, NULL_VECTOR, NULL_VECTOR);
	for (int i = 0; i < 3; i++)
		src[i] = pos[i] + normal[i] * 4.0;
	for (int b = 0; b < count; b++)
	{
		float rot = DegToRad(360.0 / float(count) * float(b));
		float c = Cosine(rot), s = Sine(rot), speed = GetRandomFloat(275.0, 300.0);
		float cross[3], vel[3];
		GetVectorCrossProduct(normal, base, cross);
		float dot = GetVectorDotProduct(normal, base);
		for (int i = 0; i < 3; i++)
			vel[i] = (base[i] * c + cross[i] * s + normal[i] * dot * (1.0 - c)) * speed;
		SpawnBomblet(kind, owner, launcher, team, crit, src, vel);
	}
}

void SpawnBomblet(int kind, int owner, int launcher, int team, bool crit, const float pos[3], const float vel[3])
{
	if (g_iBombLive >= g_cvBombMaxLive.IntValue)
		return;
	int bomb = CreateEntityByName("tf_projectile_pipe");
	if (bomb <= MaxClients)
		return;
	if (bomb >= sizeof(g_iBomblet))
	{
		RemoveEntity(bomb);
		return;
	}
	g_iBomblet[bomb] = kind;   // before spawn: never tracked as a parent
	g_iBombLive++;
	SetEntProp(bomb, Prop_Send, "m_iTeamNum", team);
	SetEntPropEnt(bomb, Prop_Send, "m_hOwnerEntity", owner);
	SetEntPropEnt(bomb, Prop_Send, "m_hThrower", owner);
	if (launcher > MaxClients)
	{
		SetEntPropEnt(bomb, Prop_Send, "m_hLauncher", launcher);
		SetEntPropEnt(bomb, Prop_Send, "m_hOriginalLauncher", launcher);
	}
	SetEntProp(bomb, Prop_Send, "m_bCritical", crit);
	DispatchSpawn(bomb);
	// Spawn() resets model and fuse; write ours afterwards.
	if (g_bModelBomblet)
	{
		SetEntityModel(bomb, BOMBLET_MODEL);
		SetEntProp(bomb, Prop_Send, "m_nSkin", team == 3 ? 1 : 0);
	}
	SetEntPropFloat(bomb, Prop_Send, "m_flDamage", g_cvBombDamage[kind].FloatValue);
	SetEntPropFloat(bomb, Prop_Send, "m_DmgRadius", g_cvBombRadius[kind].FloatValue);
	SetEntPropFloat(bomb, Prop_Data, "m_flDetonateTime",
		GetGameTime() + g_cvBombFuse[kind].FloatValue + GetRandomFloat(0.0, g_cvBombFuseRandom[kind].FloatValue));
	SetEntPropVector(bomb, Prop_Send, "m_vInitialVelocity", vel);
	TeleportEntity(bomb, pos, NULL_VECTOR, vel);
	// OF GIB BombletParticleTrail mlg_trail_secondary (team coloured): Cow Mangler trail.
	if (kind == BOMBLET_GIB)
		AttachTrail(bomb, team == 3 ? "drg_cow_rockettrail_normal_blue" : "drg_cow_rockettrail_normal");
	SDKHook(bomb, SDKHook_Touch, Hook_BombletTouch);
	if (g_cvBombImpact[kind].BoolValue)
		g_ImpactList.Push(EntIndexToEntRef(bomb));
}

/**
 * The stock pipe's direct-hit path explodes with m_flFullDamage, which only
 * the launcher's Create() fills in (a plugin-made pipe would deal 0). So
 * contacts never run it: in impact mode any touch arms an immediate
 * DetonateThink (normal radius damage with m_flDamage); otherwise bomblets
 * just bounce/roll until the fuse, as OF dynamite bomblets do.
 */
public Action Hook_BombletTouch(int bomb, int other)
{
	if (bomb >= sizeof(g_iBomblet) || !g_iBomblet[bomb])
		return Plugin_Continue;
	if (other == GetEntPropEnt(bomb, Prop_Send, "m_hThrower"))
		return Plugin_Handled;
	if (g_cvBombImpact[g_iBomblet[bomb]].BoolValue)
	{
		SetEntPropFloat(bomb, Prop_Data, "m_flDetonateTime", GetGameTime());
		SetEntProp(bomb, Prop_Data, "m_nNextThinkTick", GetGameTickCount());
	}
	return other > 0 ? Plugin_Handled : Plugin_Continue;   // world: let it bounce
}

/**
 * Grenades hitting the world bounce through VPhysicsCollision, which sets
 * m_bTouched but never calls Touch; poll it and detonate on the next think.
 */
public void OnGameFrame()
{
	for (int i = g_ImpactList.Length - 1; i >= 0; i--)
	{
		int ent = EntRefToEntIndex(g_ImpactList.Get(i));
		if (ent <= MaxClients)
		{
			g_ImpactList.Erase(i);
			continue;
		}
		if (!GetEntProp(ent, Prop_Send, "m_bTouched"))
			continue;
		SetEntPropFloat(ent, Prop_Data, "m_flDetonateTime", GetGameTime());
		SetEntProp(ent, Prop_Data, "m_nNextThinkTick", GetGameTickCount());
		g_ImpactList.Erase(i);
	}
}

/* ========================================================================= */
/* Saw Ballista grind (special "sawblade")                                   */
/* ========================================================================= */

public void Hook_SawSpawned(int bolt)
{
	RequestFrame(Frame_CheckSaw, EntIndexToEntRef(bolt));
}

public void Frame_CheckSaw(int ref)
{
	int bolt = EntRefToEntIndex(ref);
	if (bolt <= MaxClients || !LibraryExists("tf2cc_weapons") || !HasEntProp(bolt, Prop_Send, "m_hLauncher"))
		return;
	int launcher = GetEntPropEnt(bolt, Prop_Send, "m_hLauncher");
	char special[32];
	float v;
	if (launcher <= MaxClients || !TF2CC_GetWeaponSpecial(launcher, special, sizeof(special), v) || !StrEqual(special, "sawblade"))
		return;
	SDKHook(bolt, SDKHook_StartTouchPost, Hook_SawTouch);
}

public void Hook_SawTouch(int bolt, int other)
{
	if (other < 1 || other > MaxClients || !IsPlayerAlive(other))
		return;
	int owner = GetEntPropEnt(bolt, Prop_Send, "m_hOwnerEntity");
	if (owner < 1 || owner > MaxClients || !IsClientInGame(owner) || GetClientTeam(owner) == GetClientTeam(other))
		return;
	SDKUnhook(bolt, SDKHook_StartTouchPost, Hook_SawTouch);
	g_iSawVictim[owner] = GetClientUserId(other);
	g_flSawEnd[owner] = GetGameTime() + g_cvSawTime.FloatValue;
	GetEntPropVector(bolt, Prop_Data, "m_vecAbsOrigin", g_vecSawPos[owner]);
	g_iSawLauncher[owner] = EntIndexToEntRef(GetEntPropEnt(bolt, Prop_Send, "m_hLauncher"));
}

public Action Timer_SawGrind(Handle timer)
{
	float now = GetGameTime(), pos[3];
	for (int a = 1; a <= MaxClients; a++)
	{
		if (!g_iSawVictim[a])
			continue;
		int victim = GetClientOfUserId(g_iSawVictim[a]);
		if (now > g_flSawEnd[a] || !victim || !IsPlayerAlive(victim) || !IsClientInGame(a))
		{
			g_iSawVictim[a] = 0;
			continue;
		}
		GetClientAbsOrigin(victim, pos);
		pos[2] += 40.0;
		if (GetVectorDistance(pos, g_vecSawPos[a]) > g_cvSawRadius.FloatValue)
			continue;
		int launcher = EntRefToEntIndex(g_iSawLauncher[a]);
		SDKHooks_TakeDamage(victim, a, a, g_cvSawDps.FloatValue * 0.05, DMG_SLASH, launcher > MaxClients ? launcher : -1);
	}
	return Plugin_Continue;
}

/* Nailgun (special "nails"): syringes look like OF nails. */
public void Hook_NailSpawned(int ent)
{
	RequestFrame(Frame_CheckNail, EntIndexToEntRef(ent));
}

public void Frame_CheckNail(int ref)
{
	int ent = EntRefToEntIndex(ref);
	if (ent <= MaxClients || !g_bModelNail || !LibraryExists("tf2cc_weapons") || !HasEntProp(ent, Prop_Send, "m_hOriginalLauncher"))
		return;
	int launcher = GetEntPropEnt(ent, Prop_Send, "m_hOriginalLauncher");
	char special[32];
	float v;
	if (launcher > MaxClients && TF2CC_GetWeaponSpecial(launcher, special, sizeof(special), v) && StrEqual(special, "nails"))
		SetEntityModel(ent, NAIL_MODEL);
}

/* ========================================================================= */
/* Chainsaw (OF CTFChainsaw, of_weapon_chainsaw.cpp)                          */
/*  idle: rev loop (Chainsaw.Idle) | hold fire: 1 s wind-up (cs_rev_up,       */
/*  Chainsaw.WindUp), then a hit every 0.05 s (12 dmg, 100 reach) with the    */
/*  cs_rev_fire loop + Chainsaw.Fire | release: cs_rev_down + WindDown.       */
/*  Alt-fire with a full meter: shield charge (crit-boosted, auto-fires,      */
/*  Chainsaw.Charge, no Demoman scream), refills in 8 s (ChargeFilled.Ding). */
/* The stock fireaxe donor only drives the looping viewmodel/3P swing: its    */
/* fire rate equals the 0.6 s cs_rev_fire loop and its own hit does nothing   */
/* (a 0.05 s melee never lands - each swing pushes the 0.2 s smack back).     */
/* ========================================================================= */

/** Returns true when buttons were changed (auto-fire while charging). */
bool ChainsawThink(int client, int &buttons)
{
	int held = EntRefToEntIndex(g_iCsWeapon[client]);
	int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	char special[32];
	bool isSaw = active > MaxClients && ActiveSpecial(client, special, sizeof(special)) && StrEqual(special, "chainsaw");
	float now = GetGameTime();

	if (!isSaw)
	{
		if (held > MaxClients || g_iCsState[client] != CS_IDLE)
			ChainsawStop(client, held);
		ChainsawChargeTick(client, now);
		return false;
	}
	if (held != active)
	{
		ChainsawStop(client, held);
		g_iCsWeapon[client] = EntIndexToEntRef(active);
		EmitSoundToAll(CS_SND_IDLE, active, SNDCHAN_STATIC, SNDLEVEL_NORMAL);
		if (g_flCsChargeReady[client] <= 0.0)
			g_flCsChargeReady[client] = now;
	}
	bool changed = false;
	bool charging = ChainsawChargeTick(client, now);

	// Alt-fire: shield charge when the meter is full (CTFWeaponBaseMelee::SecondaryAttack).
	bool attack2 = (buttons & IN_ATTACK2) != 0;
	if (attack2 && !g_bCsAttack2[client] && !charging && now >= g_flCsChargeReady[client]
		&& g_cvCsCharge.FloatValue > 0.0)
	{
		float len = g_cvCsCharge.FloatValue;
		g_flCsChargeEnd[client] = now + len;
		g_flCsChargeReady[client] = now + len + g_cvCsRecharge.FloatValue;
		g_bCsDing[client] = true;
		SetEntPropFloat(client, Prop_Send, "m_flChargeMeter", 100.0);
		TF2_AddCondition(client, TFCond_Charging, len);
		TF2_AddCondition(client, TFCond_CritDemoCharge, len);   // CritOnChargeLevel 1
		EmitSoundToAll(CS_SND_CHARGE, client, SNDCHAN_AUTO, SNDLEVEL_NORMAL);
		charging = true;
	}
	g_bCsAttack2[client] = attack2;
	if (charging && !(buttons & IN_ATTACK))
	{
		buttons |= IN_ATTACK;   // OF: PrimaryAttack() every frame while charging
		changed = true;
	}

	bool want = (buttons & IN_ATTACK) != 0;
	switch (g_iCsState[client])
	{
		case CS_IDLE:
		{
			// Keep the donor from swinging (and the client from predicting a
			// swing) until the wind-up is over.
			SetEntPropFloat(active, Prop_Send, "m_flNextPrimaryAttack", now + 0.2);
			if (want && GetEntPropFloat(client, Prop_Send, "m_flNextAttack") <= now)
			{
				float windup = g_cvCsWindup.FloatValue * (charging ? 0.5 : 1.0);
				g_iCsState[client] = CS_WINDUP;
				g_flCsNext[client] = now + windup;
				SetEntPropFloat(active, Prop_Send, "m_flNextPrimaryAttack", now + windup);
				StopSound(active, SNDCHAN_STATIC, CS_SND_IDLE);
				EmitSoundToAll(CS_SND_WINDUP, active, SNDCHAN_WEAPON, SNDLEVEL_NORMAL);
				PlayViewSequence(client, active, "cs_rev_up", windup > 0.0 ? 1.0 / (windup / g_cvCsWindup.FloatValue) : 1.0, windup + 0.1);
			}
		}
		case CS_WINDUP:
		{
			if (!want)
				ChainsawWindDown(client, active);
			else if (now >= g_flCsNext[client])
			{
				g_iCsState[client] = CS_FIRING;
				g_flCsNext[client] = now;
				g_flCsNextSound[client] = 0.0;
				SetEntPropFloat(active, Prop_Send, "m_flNextPrimaryAttack", now);
			}
			else
				SetEntPropFloat(active, Prop_Send, "m_flNextPrimaryAttack", g_flCsNext[client]);
		}
		case CS_FIRING:
		{
			if (!want)
			{
				ChainsawWindDown(client, active);
				return changed;
			}
			bool crit = TF2_IsPlayerInCondition(client, TFCond_CritDemoCharge) || IsCritBoosted(client);
			char snd[48];
			strcopy(snd, sizeof(snd), crit ? CS_SND_FIRE_CRIT : CS_SND_FIRE);
			if (now >= g_flCsNextSound[client] || !StrEqual(snd, g_sCsFireSound[client]))
			{
				if (g_sCsFireSound[client][0])
					StopSound(active, SNDCHAN_WEAPON, g_sCsFireSound[client]);
				StopSound(active, SNDCHAN_WEAPON, CS_SND_WINDUP);
				EmitSoundToAll(snd, active, SNDCHAN_WEAPON, SNDLEVEL_NORMAL);
				strcopy(g_sCsFireSound[client], sizeof(g_sCsFireSound[]), snd);
				g_flCsNextSound[client] = now + (crit ? 3.3 : 0.598);
			}
			while (g_flCsNext[client] <= now)
			{
				g_flCsNext[client] += g_cvCsInterval.FloatValue;
				ChainsawHit(client, active, crit);
			}
		}
	}
	return changed;
}

/** OF DoSwingTrace: a line from the shoot position, then the duck hull. */
void ChainsawHit(int client, int weapon, bool crit)
{
	float eye[3], ang[3], dir[3], end[3];
	GetClientEyePosition(client, eye);
	GetClientEyeAngles(client, ang);
	GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(dir, g_cvCsRange.FloatValue);
	AddVectors(eye, dir, end);
	Handle tr = TR_TraceRayFilterEx(eye, end, MASK_SOLID, RayType_EndPoint, Filter_NotSelf, client);
	if (!TR_DidHit(tr) || TR_GetEntityIndex(tr) <= 0)
	{
		delete tr;
		tr = TR_TraceHullFilterEx(eye, end, view_as<float>({ -18.0, -18.0, -18.0 }), view_as<float>({ 18.0, 18.0, 18.0 }),
			MASK_SOLID, Filter_NotSelf, client);
	}
	int hit = TR_GetEntityIndex(tr);
	delete tr;
	if (hit <= 0 || !IsValidEntity(hit))
		return;
	bool player = hit <= MaxClients;
	if (player && (!IsPlayerAlive(hit) || GetClientTeam(hit) == GetClientTeam(client)))
		return;
	if (!player)
	{
		char cls[32];
		GetEntityClassname(hit, cls, sizeof(cls));
		if (StrContains(cls, "obj_") != 0 || GetEntProp(hit, Prop_Send, "m_iTeamNum") == GetClientTeam(client))
			return;
	}
	SDKHooks_TakeDamage(hit, client, client, g_cvCsDamage.FloatValue, DMG_CLUB | (crit ? DMG_ACID : 0), weapon);
}

void ChainsawWindDown(int client, int weapon)
{
	g_iCsState[client] = CS_IDLE;
	if (g_sCsFireSound[client][0])
		StopSound(weapon, SNDCHAN_WEAPON, g_sCsFireSound[client]);
	g_sCsFireSound[client][0] = '\0';
	StopSound(weapon, SNDCHAN_WEAPON, CS_SND_WINDUP);
	EmitSoundToAll(CS_SND_WINDDOWN, weapon, SNDCHAN_WEAPON, SNDLEVEL_NORMAL);
	EmitSoundToAll(CS_SND_IDLE, weapon, SNDCHAN_STATIC, SNDLEVEL_NORMAL);
	PlayViewSequence(client, weapon, "cs_rev_down", 1.0, 1.4);
}

void ChainsawStop(int client, int held)
{
	if (held > MaxClients)
	{
		StopSound(held, SNDCHAN_STATIC, CS_SND_IDLE);
		StopSound(held, SNDCHAN_WEAPON, CS_SND_WINDUP);
		if (g_sCsFireSound[client][0])
			StopSound(held, SNDCHAN_WEAPON, g_sCsFireSound[client]);
	}
	g_sCsFireSound[client][0] = '\0';
	g_iCsState[client] = CS_IDLE;
	g_iCsWeapon[client] = INVALID_ENT_REFERENCE;
	// OF CTFPlayer: the charge ends when the chainsaw is put away.
	if (g_flCsChargeEnd[client] > GetGameTime())
	{
		g_flCsChargeEnd[client] = 0.0;
		TF2_RemoveCondition(client, TFCond_Charging);
		TF2_RemoveCondition(client, TFCond_CritDemoCharge);
	}
}

/** Keeps the stock charge (its 1.5 s meter drain) going for the OF length; ding when refilled. */
bool ChainsawChargeTick(int client, float now)
{
	if (g_bCsDing[client] && g_flCsChargeReady[client] > 0.0 && now >= g_flCsChargeReady[client])
	{
		g_bCsDing[client] = false;
		if (!IsFakeClient(client))
			EmitSoundToClient(client, CS_SND_DING);
	}
	if (g_flCsChargeEnd[client] <= now)
		return false;
	if (!TF2_IsPlayerInCondition(client, TFCond_Charging))
	{
		// Bumped into something / stopped by the game: end like OF does.
		g_flCsChargeEnd[client] = 0.0;
		TF2_RemoveCondition(client, TFCond_CritDemoCharge);
		return false;
	}
	SetEntPropFloat(client, Prop_Send, "m_flChargeMeter", 100.0);
	return true;
}

/** Server-driven viewmodel sequence (cs_rev_up / cs_rev_down have no stock activity). */
void PlayViewSequence(int client, int weapon, const char[] sequence, float rate, float hold)
{
	int vm = GetEntPropEnt(client, Prop_Send, "m_hViewModel");
	if (vm <= MaxClients)
		return;
	char model[PLATFORM_MAX_PATH];
	GetEntPropString(vm, Prop_Data, "m_ModelName", model, sizeof(model));
	int seq = LookupSequenceOnModel(model, sequence);
	if (seq < 0)
		return;
	SetEntProp(vm, Prop_Send, "m_nSequence", seq);
	SetEntPropFloat(vm, Prop_Send, "m_flPlaybackRate", rate);
	SetEntPropFloat(vm, Prop_Data, "m_flCycle", 0.0);
	SetEntProp(vm, Prop_Send, "m_nNewSequenceParity", (GetEntProp(vm, Prop_Send, "m_nNewSequenceParity") + 1) & 7);
	SetEntProp(vm, Prop_Send, "m_nResetEventsParity", (GetEntProp(vm, Prop_Send, "m_nResetEventsParity") + 1) & 7);
	if (HasEntProp(weapon, Prop_Data, "m_flTimeWeaponIdle"))
		SetEntPropFloat(weapon, Prop_Data, "m_flTimeWeaponIdle", GetGameTime() + hold);
}

int LookupSequenceOnModel(const char[] model, const char[] sequence)
{
	static StringMap cache;
	if (cache == null)
		cache = new StringMap();
	char key[PLATFORM_MAX_PATH + 64];
	FormatEx(key, sizeof(key), "%s|%s", model, sequence);
	int seq;
	if (cache.GetValue(key, seq))
		return seq;
	int tmp = CreateEntityByName("prop_dynamic_override");
	if (tmp == -1)
		return -1;
	// A fresh prop with DefaultAnim: SetAnimation after forcing m_nSequence to -1
	// left the sequence at 65535 (verified on the test server).
	DispatchKeyValue(tmp, "model", model);
	DispatchKeyValue(tmp, "solid", "0");
	DispatchKeyValue(tmp, "DefaultAnim", sequence);
	if (!DispatchSpawn(tmp))
	{
		RemoveEntity(tmp);
		return -1;
	}
	ActivateEntity(tmp);
	seq = GetEntProp(tmp, Prop_Send, "m_nSequence");
	RemoveEntity(tmp);
	if (seq >= 65535)
		seq = -1;
	cache.SetValue(key, seq);
	return seq;
}

/**
 * OF's charge only plays Chainsaw.Charge: drop the stock charge whoosh and
 * crit-charge on/off sounds for chainsaw charges; the donor's own swing/hit
 * sounds are silenced (the chainsaw loop replaces them).
 */
public Action Hook_ChainsawSounds(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH],
	int &entity, int &channel, float &volume, int &level, int &pitch, int &flags,
	char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
	if (entity < 1)
		return Plugin_Continue;
	int owner = entity;
	if (entity > MaxClients)
	{
		if (!IsValidEntity(entity) || !HasEntProp(entity, Prop_Send, "m_hOwnerEntity"))
			return Plugin_Continue;
		owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
		if (owner < 1 || owner > MaxClients)
			return Plugin_Continue;
	}
	if (StrContains(sample, "demo_charge_windup") != -1 || StrContains(sample, "weapon_crit_charged_o") != -1)
		return (g_flCsChargeEnd[owner] > 0.0 && GetGameTime() <= g_flCsChargeEnd[owner] + 0.5) ? Plugin_Stop : Plugin_Continue;
	if (g_iCsWeapon[owner] == INVALID_ENT_REFERENCE)
		return Plugin_Continue;
	if (StrContains(sample, "cbar_miss1") != -1 || StrContains(sample, "axe_hit_flesh") != -1 || StrContains(sample, "cbar_hit") != -1)
		return Plugin_Stop;
	return Plugin_Continue;
}

public void OnClientDisconnect(int client)
{
	StopLoopSounds(client);
	g_iCsState[client] = CS_IDLE;
	g_iCsWeapon[client] = INVALID_ENT_REFERENCE;
	g_flCsChargeEnd[client] = 0.0;
	g_flCsChargeReady[client] = 0.0;
	g_bCsDing[client] = false;
	g_sCsFireSound[client][0] = '\0';
}

int ParticleIndex(const char[] name)
{
	static int table = INVALID_STRING_TABLE;
	if (table == INVALID_STRING_TABLE)
		table = FindStringTable("ParticleEffectNames");
	if (table == INVALID_STRING_TABLE)
		return INVALID_STRING_INDEX;
	int idx = FindStringIndex(table, name);
	if (idx == INVALID_STRING_INDEX)
	{
		bool save = LockStringTables(false);
		AddToStringTable(table, name);
		LockStringTables(save);
		idx = FindStringIndex(table, name);
	}
	return idx;
}

/** TFParticleEffect following the entity (PATTACH_ABSORIGIN_FOLLOW). */
void AttachTrail(int entity, const char[] name)
{
	int idx = ParticleIndex(name);
	if (idx == INVALID_STRING_INDEX)
		return;
	float pos[3];
	GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", pos);
	TE_Start("TFParticleEffect");
	TE_WriteFloat("m_vecOrigin[0]", pos[0]);
	TE_WriteFloat("m_vecOrigin[1]", pos[1]);
	TE_WriteFloat("m_vecOrigin[2]", pos[2]);
	TE_WriteNum("m_iParticleSystemIndex", idx);
	TE_WriteNum("entindex", entity);
	TE_WriteNum("m_iAttachType", 1);
	TE_SendToAll();
}

/* ========================================================================= */
/* Gatling (OF CTFGatlingGun sounds on the stock minigun)                     */
/* The minigun's wind-up/fire/spin loops are client-side for every player,   */
/* so a server sound swap never applies; follow m_iWeaponState instead       */
/* (0 idle, 1 starting, 2 firing, 3 spinning, 4 dry) and send OF's sounds to  */
/* everyone, the shooter included. Fire is re-sent at its wave length.       */
/* ========================================================================= */

void GatlingThink(int client)
{
	int held = EntRefToEntIndex(g_iGatWeapon[client]);
	int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	char special[32];
	bool isGat = active > MaxClients && HasEntProp(active, Prop_Send, "m_iWeaponState")
		&& ActiveSpecial(client, special, sizeof(special)) && StrEqual(special, "gatling");
	if (!isGat)
	{
		if (held > MaxClients)
			GatlingStop(client, held, false);
		g_iGatWeapon[client] = INVALID_ENT_REFERENCE;
		g_iGatState[client] = 0;
		return;
	}
	if (held != active)
	{
		if (held > MaxClients)
			GatlingStop(client, held, false);
		g_iGatWeapon[client] = EntIndexToEntRef(active);
		g_iGatState[client] = 0;
	}
	int state = GetEntProp(active, Prop_Send, "m_iWeaponState");
	int old = g_iGatState[client];
	float now = GetGameTime();
	if (state == 1 && old == 0)
		EmitSoundToAll(GAT_SND_WINDUP, active, SNDCHAN_AUTO, GAT_LEVEL);
	if (state == 2)
	{
		bool crit = (HasEntProp(active, Prop_Send, "m_bCritShot") && GetEntProp(active, Prop_Send, "m_bCritShot") != 0) || IsCritBoosted(client);
		char snd[48];
		strcopy(snd, sizeof(snd), crit ? GAT_SND_FIRE_CRIT : GAT_SND_FIRE);
		if (old != 2 || now >= g_flGatNextFire[client] || !StrEqual(snd, g_sGatFire[client]))
		{
			if (g_sGatFire[client][0])
				StopSound(active, SNDCHAN_STATIC, g_sGatFire[client]);
			EmitSoundToAll(snd, active, SNDCHAN_STATIC, GAT_LEVEL);
			strcopy(g_sGatFire[client], sizeof(g_sGatFire[]), snd);
			g_flGatNextFire[client] = now + GAT_FIRE_LEN;
		}
	}
	else if (old == 2 && g_sGatFire[client][0])
	{
		StopSound(active, SNDCHAN_STATIC, g_sGatFire[client]);
		g_sGatFire[client][0] = '\0';
	}
	if (state == 0 && old != 0)
		EmitSoundToAll(GAT_SND_WINDDOWN, active, SNDCHAN_AUTO, GAT_LEVEL);
	g_iGatState[client] = state;
}

void GatlingStop(int client, int weapon, bool winddown)
{
	if (g_sGatFire[client][0])
		StopSound(weapon, SNDCHAN_STATIC, g_sGatFire[client]);
	g_sGatFire[client][0] = '\0';
	if (winddown)
		EmitSoundToAll(GAT_SND_WINDDOWN, weapon, SNDCHAN_AUTO, GAT_LEVEL);
}
