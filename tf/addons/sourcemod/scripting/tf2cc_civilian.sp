/**
 * tf2cc_civilian - TF2 Classic/Classified Civilian class abilities.
 *
 * Reference: tf2c-src shared/tf/tf_player_shared.cpp:5193-5256 (aura) and the
 * installed TF2 Classified build (scripts/playerclasses/civilian.txt,
 * scripts/tf2c_weapon_umbrella.txt). Intrinsic to the class, not VIP mode:
 *  - Aura: every 1.0 s, teammates within 450u (nearest hull point) get a
 *    1.2 s resistance buff (x0.8 damage taken) and regenerate 5 HP/s,
 *    ramping 1x -> 3x as time since last damage goes 10 s -> 15 s, no overheal.
 *    Skips self, dead, cloaked spies; enemy spies count when their disguise
 *    team matches (disguise fools the Civilian's team).
 *  - The Civilian regenerates himself at the same rate.
 *  - Umbrella alt-fire: give the teammate under the crosshair
 *    TF_COND_DAMAGE_BOOST (mini-crits) for 8 s; 16 s cooldown starting at
 *    spawn; failure plays a deny sound and does not start the cooldown.
 * VIP-mode-only behaviour (suicide block, VIP voting, escort win conditions) is
 * intentionally not implemented here.
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2>
#include <tf2_stocks>
#undef REQUIRE_PLUGIN
#include <tf2attributes>
#define REQUIRE_PLUGIN
#include <tf2cc>

native bool TF2CC_Speak(int client, const char[] concept, bool force = false);

public Plugin myinfo =
{
	name = "TF2CC Civilian",
	author = "tf2cc-rework",
	description = "Civilian aura, regeneration and umbrella boost",
	version = TF2CC_VERSION,
	url = ""
};

#define ROLE_KEY "civilian"
#define DENY_SOUND "common/wpn_denyselect.wav"
// TF2C TFPlayer.VIPBuffUp / VIPBuffDown (also MarxVee's boost "cha-ching").
#define BUFF_SOUND "player/vip_buff.wav"
#define BUFF_EXIT_SOUND "player/vip_buff_exit.wav"
#define BOOST_SOUND "player/vip_boost01.wav"   // TF2C TFPlayer.VIPBoost, the cha-ching
bool g_bBuffActive[MAXPLAYERS + 1];
int g_iBuffParticle[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
ConVar g_cvAuraParticle;
ConVar g_cvBotBoostChance;

ConVar g_cvRadius;
ConVar g_cvBuffTime;
ConVar g_cvResist;
ConVar g_cvRegen;
ConVar g_cvBoostTime;
ConVar g_cvBoostCooldown;
ConVar g_cvAuraCond;
ConVar g_cvCapValue;

float g_flBuffUntil[MAXPLAYERS + 1];
int g_iBuffProvider[MAXPLAYERS + 1];
float g_flLastDamage[MAXPLAYERS + 1];
float g_flRegenAccum[MAXPLAYERS + 1];
float g_flBoostReady[MAXPLAYERS + 1];
bool g_bAttack2Held[MAXPLAYERS + 1];
bool g_bVoice;
bool g_bTF2Attributes;
Handle g_hHud;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	MarkNativeAsOptional("TF2CC_Speak");
	MarkNativeAsOptional("TF2CC_GetWeaponId");
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvRadius = CreateConVar("tf2cc_civ_aura_radius", "450", "Civilian aura radius (TF2C 450).");
	g_cvBuffTime = CreateConVar("tf2cc_civ_aura_buff_time", "1.2", "Seconds an aura pulse lasts (TF2C 1.2).");
	g_cvResist = CreateConVar("tf2cc_civ_aura_damage_mult", "0.8", "Damage multiplier for buffed players (tf2c_vip_armor 0.8).");
	g_cvRegen = CreateConVar("tf2cc_civ_aura_regen", "5", "Base HP/s regeneration while buffed (tf2c_vip_regen 5).");
	g_cvBoostTime = CreateConVar("tf2cc_civ_boost_time", "8", "Umbrella boost duration (TF2C 8).");
	g_cvBoostCooldown = CreateConVar("tf2cc_civ_boost_cooldown", "16", "Umbrella boost cooldown (TF2C 16).");
	g_cvAuraCond = CreateConVar("tf2cc_civ_aura_visual_cond", "-1", "Optional stock TFCond applied for the pulse purely as a visual cue (-1 = none).");
	g_cvAuraParticle = CreateConVar("tf2cc_civ_aura_particle", "soldierbuff_%s_buffed", "Stock particle on aura-buffed players (%s = red/blue; TF2C civilianbuff_%s_buffed is a custom .pcf stock clients cannot load). Empty = none.");
	g_cvBotBoostChance = CreateConVar("tf2cc_civ_bot_boost_rate", "0.3", "Civilian bots: chance per second to boost the teammate they are looking at.", _, true, 0.0);
	g_cvCapValue = CreateConVar("tf2cc_civ_capture_value", "5", "Civilian control-point capture rate (TF2C 5).");
	AutoExecConfig(true, "tf2cc_civilian");

	g_hHud = CreateHudSynchronizer();
	CreateTimer(1.0, Timer_AuraPulse, _, TIMER_REPEAT);
	CreateTimer(0.25, Timer_Regen, _, TIMER_REPEAT);

	for (int client = 1; client <= MaxClients; client++)
		if (IsClientInGame(client))
			OnClientPutInServer(client);
}

public void OnAllPluginsLoaded()
{
	g_bVoice = LibraryExists("tf2cc_voice");
	g_bTF2Attributes = LibraryExists("tf2attributes");
}
public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "tf2cc_voice")) g_bVoice = true;
	if (StrEqual(name, "tf2attributes")) g_bTF2Attributes = true;
}
public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "tf2cc_voice")) g_bVoice = false;
	if (StrEqual(name, "tf2attributes")) g_bTF2Attributes = false;
}

public void OnMapStart()
{
	PrecacheSound(DENY_SOUND, true);
	PrecacheSound(BUFF_SOUND, true);
	PrecacheSound(BUFF_EXIT_SOUND, true);
	PrecacheSound(BOOST_SOUND, true);
}

public void OnClientPutInServer(int client)
{
	g_flBuffUntil[client] = 0.0;
	g_iBuffProvider[client] = 0;
	g_flLastDamage[client] = 0.0;
	g_flRegenAccum[client] = 0.0;
	g_flBoostReady[client] = 0.0;
	g_bAttack2Held[client] = false;
	g_bBuffActive[client] = false;
	g_iBuffParticle[client] = INVALID_ENT_REFERENCE;
	SDKHook(client, SDKHook_OnTakeDamage, Hook_OnTakeDamage);
	SDKHook(client, SDKHook_OnTakeDamagePost, Hook_OnTakeDamagePost);
}

bool IsCivilian(int client)
{
	return TF2CC_IsValidClient(client) && IsPlayerAlive(client) && TF2CC_RoleIs(client, ROLE_KEY);
}

public void TF2CC_OnRoleSpawned(int client, int role)
{
	if (!TF2CC_RoleIs(client, ROLE_KEY))
		return;
	g_flBoostReady[client] = GetGameTime() + g_cvBoostCooldown.FloatValue; // TF2C: cooldown starts at spawn
	if (g_bTF2Attributes)
	{
		// Stock capture value is 1; the attribute adds to it.
		TF2Attrib_SetByName(client, "increase player capture value", float(g_cvCapValue.IntValue - 1));
		TF2Attrib_ClearCache(client);
	}
}

public void TF2CC_OnRoleCleared(int client, int oldRole)
{
	if (g_bTF2Attributes && IsClientInGame(client))
	{
		TF2Attrib_RemoveByName(client, "increase player capture value");
		TF2Attrib_ClearCache(client);
	}
}

/* ------------------------------------------------------------------------- */
/* Aura                                                                      */
/* ------------------------------------------------------------------------- */

public Action Timer_AuraPulse(Handle timer)
{
	float radius = g_cvRadius.FloatValue;
	float until = GetGameTime() + g_cvBuffTime.FloatValue;
	int visual = g_cvAuraCond.IntValue;

	for (int civ = 1; civ <= MaxClients; civ++)
	{
		if (!IsCivilian(civ))
			continue;
		int team = GetClientTeam(civ);
		float civPos[3];
		GetClientAbsOrigin(civ, civPos);

		for (int target = 1; target <= MaxClients; target++)
		{
			if (target == civ || !IsClientInGame(target) || !IsPlayerAlive(target))
				continue;
			if (!AuraAllegiance(target, team))
				continue;
			if (TF2_IsPlayerInCondition(target, TFCond_Cloaked))
				continue;
			if (DistanceToHull(civPos, target) > radius)
				continue;

			g_flBuffUntil[target] = until;
			g_iBuffProvider[target] = civ;
			if (!g_bBuffActive[target])
				OnBuffStart(target);
			if (visual >= 0)
				TF2_AddCondition(target, view_as<TFCond>(visual), g_cvBuffTime.FloatValue, civ);
		}
	}
	for (int i = 1; i <= MaxClients; i++)
		if (g_bBuffActive[i] && (!IsClientInGame(i) || !IsPlayerAlive(i) || !IsBuffed(i)))
			OnBuffEnd(i);
	return Plugin_Continue;
}

/** TF2C CTFPlayerShared::OnAddResistanceBuff: sound to the player, a positive line, the buff particle. */
void OnBuffStart(int client)
{
	g_bBuffActive[client] = true;
	EmitSoundToClient(client, BUFF_SOUND);
	if (TF2CC_GetRole(client) != TF2CC_ROLE_NONE)
	{
		if (g_bVoice)
			TF2CC_Speak(client, "_positivevocalization");
	}
	else
	{
		SetVariantString("TLK_PLAYER_POSITIVE");
		AcceptEntityInput(client, "SpeakResponseConcept");
	}
	char fmt[64], effect[64];
	g_cvAuraParticle.GetString(fmt, sizeof(fmt));
	if (!fmt[0])
		return;
	FormatEx(effect, sizeof(effect), fmt, GetClientTeam(client) == view_as<int>(TFTeam_Blue) ? "blue" : "red");
	int p = CreateEntityByName("info_particle_system");
	if (p == -1)
		return;
	float pos[3];
	GetClientAbsOrigin(client, pos);
	TeleportEntity(p, pos, NULL_VECTOR, NULL_VECTOR);
	DispatchKeyValue(p, "effect_name", effect);
	DispatchSpawn(p);
	SetVariantString("!activator");
	AcceptEntityInput(p, "SetParent", client);
	ActivateEntity(p);
	AcceptEntityInput(p, "Start");
	g_iBuffParticle[client] = EntIndexToEntRef(p);
}

void OnBuffEnd(int client)
{
	g_bBuffActive[client] = false;
	int p = EntRefToEntIndex(g_iBuffParticle[client]);
	g_iBuffParticle[client] = INVALID_ENT_REFERENCE;
	if (p > MaxClients)
		RemoveEntity(p);
	if (IsClientInGame(client))
		EmitSoundToClient(client, BUFF_EXIT_SOUND);
}

bool AuraAllegiance(int target, int team)
{
	if (GetClientTeam(target) == team)
		return true;
	// Enemy spy whose disguise fools the Civilian's team.
	return TF2_GetPlayerClass(target) == TFClass_Spy
		&& TF2_IsPlayerInCondition(target, TFCond_Disguised)
		&& GetEntProp(target, Prop_Send, "m_nDisguiseTeam") == team;
}

/** Distance from a point to the nearest point of the target's bounding box. */
float DistanceToHull(const float point[3], int target)
{
	float origin[3], mins[3], maxs[3], nearest[3];
	GetClientAbsOrigin(target, origin);
	GetClientMins(target, mins);
	GetClientMaxs(target, maxs);
	for (int i = 0; i < 3; i++)
	{
		float lo = origin[i] + mins[i], hi = origin[i] + maxs[i];
		nearest[i] = point[i] < lo ? lo : (point[i] > hi ? hi : point[i]);
	}
	return GetVectorDistance(point, nearest);
}

bool IsBuffed(int client)
{
	return g_flBuffUntil[client] > GetGameTime();
}

public Action Hook_OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if (!IsBuffed(victim) || damage <= 0.0)
		return Plugin_Continue;
	damage *= g_cvResist.FloatValue;
	return Plugin_Changed;
}

public void Hook_OnTakeDamagePost(int victim, int attacker, int inflictor, float damage, int damagetype)
{
	if (damage > 0.0)
		g_flLastDamage[victim] = GetGameTime();
}

public Action Timer_Regen(Handle timer)
{
	float now = GetGameTime();
	float base = g_cvRegen.FloatValue * 0.25;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !IsPlayerAlive(client))
			continue;
		if (!IsBuffed(client) && !IsCivilian(client))
			continue;

		// Combat-scaled: 1x until 10 s after damage, ramping to 3x at 15 s.
		float since = now - g_flLastDamage[client];
		float mult = 1.0;
		if (since >= 15.0) mult = 3.0;
		else if (since > 10.0) mult = 1.0 + 2.0 * ((since - 10.0) / 5.0);

		g_flRegenAccum[client] += base * mult;
		int heal = RoundToFloor(g_flRegenAccum[client]);
		if (heal < 1)
			continue;
		g_flRegenAccum[client] -= float(heal);

		int maxHealth = GetEntProp(client, Prop_Data, "m_iMaxHealth");
		int resMax = GetPlayerResourceMaxHealth(client);
		if (resMax > 0)
			maxHealth = resMax;
		int health = GetClientHealth(client);
		if (health >= maxHealth)
			continue;
		int newHealth = health + heal > maxHealth ? maxHealth : health + heal;
		SetEntityHealth(client, newHealth);
		Event ev = CreateEvent("player_healonhit", true);
		if (ev != null)
		{
			ev.SetInt("amount", newHealth - health);
			ev.SetInt("entindex", client);
			ev.Fire();
		}
	}
	return Plugin_Continue;
}

int GetPlayerResourceMaxHealth(int client)
{
	int res = GetPlayerResourceEntity();
	if (res == -1)
		return 0;
	return GetEntProp(res, Prop_Send, "m_iMaxHealth", _, client);
}

/* ------------------------------------------------------------------------- */
/* Umbrella boost (alt-fire)                                                 */
/* ------------------------------------------------------------------------- */

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
	bool pressed = (buttons & IN_ATTACK2) != 0;
	bool edge = pressed && !g_bAttack2Held[client];
	g_bAttack2Held[client] = pressed;
	if (!IsCivilian(client) && !HoldsUmbrella(client))
		return Plugin_Continue;

	// Bots: now and then boost the teammate they are looking at.
	if (IsFakeClient(client) && !edge && GetGameTime() >= g_flBoostReady[client]
		&& GetURandomFloat() < g_cvBotBoostChance.FloatValue * GetTickInterval())
	{
		int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		if (active != -1 && GetPlayerWeaponSlot(client, 2) == active && TraceBoostTarget(client) > 0)
			TryBoost(client);
		return Plugin_Continue;
	}
	if (!edge)
		return Plugin_Continue;
	TryBoost(client);
	return Plugin_Continue;
}

void TryBoost(int client)
{
	int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (active == -1 || GetPlayerWeaponSlot(client, 2) != active)
		return; // boost only with the melee (umbrella) out

	float now = GetGameTime();
	if (now < g_flBoostReady[client])
	{
		EmitSoundToClient(client, DENY_SOUND);
		ShowCooldown(client, g_flBoostReady[client] - now);
		return;
	}

	int target = TraceBoostTarget(client);
	if (target <= 0)
	{
		EmitSoundToClient(client, DENY_SOUND);
		return;
	}

	TF2_AddCondition(target, TFCond_Buffed, g_cvBoostTime.FloatValue, client);
	g_flBoostReady[client] = now + g_cvBoostCooldown.FloatValue;
	// TF2C CTFUmbrella: TFPlayer.VIPBoost from the boosted player to everyone in PVS
	// (both of them hear it), the target's battle cry and the Civilian's "Go!".
	EmitSoundToAll(BOOST_SOUND, target, SNDCHAN_STATIC, SNDLEVEL_NORMAL);
	if (TF2CC_GetRole(target) != TF2CC_ROLE_NONE)
	{
		if (g_bVoice)
			TF2CC_Speak(target, "_battlecry", true);
	}
	else
	{
		SetVariantString("TLK_PLAYER_BATTLECRY");
		AcceptEntityInput(target, "SpeakResponseConcept");
	}
	if (g_bVoice && !TF2CC_Speak(client, "_umbrellaboost", true) && !TF2CC_Speak(client, "_go", true))
		TF2CC_Speak(client, "_battlecry", true);
	PlayPointAnimation(client, active);
	if (!IsFakeClient(client))
		PrintHintText(client, "Boosted %N!", target);
}

/**
 * TF2C SendWeaponAnim(ACT_VM_SECONDARYATTACK): the umbrella viewmodel's
 * "umbrella_gesture_point". The weapon's own model is the viewmodel model, so
 * the sequence index is looked up on a throwaway prop of it.
 */
void PlayPointAnimation(int client, int weapon)
{
	int vm = GetEntPropEnt(client, Prop_Send, "m_hViewModel");
	if (vm <= MaxClients)
		return;
	char model[PLATFORM_MAX_PATH];
	GetEntPropString(vm, Prop_Data, "m_ModelName", model, sizeof(model));
	int seq = LookupSequenceOnModel(model, "umbrella_gesture_point");
	if (seq < 0)
		return;
	SetEntProp(vm, Prop_Send, "m_nSequence", seq);
	SetEntPropFloat(vm, Prop_Send, "m_flPlaybackRate", 1.0);
	SetEntPropFloat(vm, Prop_Data, "m_flCycle", 0.0);
	SetEntProp(vm, Prop_Send, "m_nNewSequenceParity", (GetEntProp(vm, Prop_Send, "m_nNewSequenceParity") + 1) & 7);
	SetEntProp(vm, Prop_Send, "m_nResetEventsParity", (GetEntProp(vm, Prop_Send, "m_nResetEventsParity") + 1) & 7);
	// Keep the weapon from snapping back to idle before the gesture plays out.
	if (HasEntProp(weapon, Prop_Data, "m_flTimeWeaponIdle"))
		SetEntPropFloat(weapon, Prop_Data, "m_flTimeWeaponIdle", GetGameTime() + 1.2);
	float next = GetGameTime() + 0.6;
	if (GetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack") < next)
		SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", next);
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
	DispatchKeyValue(tmp, "model", model);
	DispatchKeyValue(tmp, "solid", "0");
	if (!DispatchSpawn(tmp))
	{
		RemoveEntity(tmp);
		return -1;
	}
	SetEntProp(tmp, Prop_Send, "m_nSequence", -1);
	SetVariantString(sequence);
	AcceptEntityInput(tmp, "SetAnimation");
	seq = GetEntProp(tmp, Prop_Send, "m_nSequence");
	RemoveEntity(tmp);
	cache.SetValue(key, seq);
	return seq;
}

int TraceBoostTarget(int client)
{
	float eye[3], ang[3], dir[3], end[3];
	GetClientEyePosition(client, eye);
	GetClientEyeAngles(client, ang);
	GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(dir, 8192.0);
	AddVectors(eye, dir, end);
	// TF2C: trace ignores the owner and enemies, except spies (so disguised spies can be boosted).
	Handle tr = TR_TraceRayFilterEx(eye, end, MASK_SHOT, RayType_EndPoint, Filter_Boost, client);
	int hit = TR_GetEntityIndex(tr);
	delete tr;
	if (hit < 1 || hit > MaxClients || !IsPlayerAlive(hit))
		return -1;
	if (!AuraAllegiance(hit, GetClientTeam(client)))
		return -1;
	return hit;
}

public bool Filter_Boost(int entity, int contentsMask, int client)
{
	if (entity == client)
		return false;
	if (entity >= 1 && entity <= MaxClients && GetClientTeam(entity) != GetClientTeam(client)
		&& TF2_GetPlayerClass(entity) != TFClass_Spy)
		return false;
	return true;
}

void ShowCooldown(int client, float remaining)
{
	SetHudTextParams(-1.0, 0.62, 1.0, 255, 220, 120, 255);
	ShowSyncHudText(client, g_hHud, "Umbrella boost ready in %.0f s", remaining);
}

native bool TF2CC_GetWeaponId(int weapon, char[] id, int maxlen);

/** Any role player holding the Civilian umbrella (e.g. a Merc who picked it up). */
bool HoldsUmbrella(int client)
{
	if (!TF2CC_IsValidClient(client) || !IsPlayerAlive(client) || TF2CC_GetRole(client) == TF2CC_ROLE_NONE || !LibraryExists("tf2cc_weapons"))
		return false;
	int w = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	char id[48];
	return w > MaxClients && TF2CC_GetWeaponId(w, id, sizeof(id)) && StrEqual(id, "civ_umbrella");
}
