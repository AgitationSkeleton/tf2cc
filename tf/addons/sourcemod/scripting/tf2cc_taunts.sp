/**
 * tf2cc_taunts (EXPERIMENTAL) - taunts for roles on stock class 10.
 *
 * Stock class 10 has no taunt scenes, and OF/TF2C taunt VCDs live in packed
 * scenes.image files. The role models do contain named taunt sequences
 * (tools/mdlinfo.py: Merc taunt01-06 + taunt_bond; Civilian taunt01, taunt06,
 * taunt_sandvich, taunt_buy_a_life, taunt_laugh). This module plays one on a
 * clone while the player is hidden, frozen and in the stock taunt camera
 * (input SetForcedTauntCam). The clone is a tf_taunt_prop (a flex-capable
 * CBaseCombatCharacter with client-side animation, so EyeRefract eyes get
 * their iris projection; a prop_dynamic renders blank white eyes). Its
 * sequence index is resolved through a throwaway prop_dynamic of the same
 * model. No class or item spoofing is involved; attacks are blocked.
 *
 * Default mode "player" (tf2cc_taunts_mode): the player model itself plays the
 * sequence through a PlayerAnimEvent temp entity, PLAYERANIMEVENT_CUSTOM_SEQUENCE
 * (CMultiPlayerAnimState: m_nSpecificMainSequence until the sequence finishes).
 * The player is a flex entity, so eyes keep their irises and voice lines played
 * from the player (CHAN_VOICE, phoneme data) lip-sync; the clone could do
 * neither and left a reference pose behind when its animation ran out.
 *
 * roles.cfg: "taunts" "seq:seconds[:concept[:voice delay[:halloween]]],..."
 * OF Bond taunt (taunt_bond): at 1.6 s, a 500 u trace deals 500 bullet damage.
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2>
#include <tf2_stocks>
#include <tf2cc>

native bool TF2CC_Speak(int client, const char[] concept, bool force = false);
native bool TF2CC_GetWeaponId(int weapon, char[] id, int maxlen);
native bool TF2CC_RefreshWeaponVisuals(int client);

public Plugin myinfo =
{
	name = "TF2CC Taunts (experimental)",
	author = "tf2cc-rework",
	description = "Sequence taunts for custom roles",
	version = TF2CC_VERSION,
	url = ""
};

#define EF_NODRAW 0x020   // const.h
ConVar g_cvEnabled;
ConVar g_cvPropClass;
ConVar g_cvMode;
ConVar g_cvDebug;
// Entity playing the taunt: the clone, or the player itself in "player" mode.
int g_iProp[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
bool g_bPlayerMode[MAXPLAYERS + 1];
bool g_bTaunting[MAXPLAYERS + 1];   // explicit state: an entity reference to a client survives map changes
bool g_bWeaponWasHidden[MAXPLAYERS + 1];
int g_iTauntWeapon[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
#define PLAYERANIMEVENT_SPAWN 17            // multiplayer_animstate.h: ClearAnimationState()
#define PLAYERANIMEVENT_CUSTOM_SEQUENCE 21  // m_nSpecificMainSequence = nData
Handle g_hEndTimer[MAXPLAYERS + 1];
float g_flNextTaunt[MAXPLAYERS + 1];
float g_flTauntYaw[MAXPLAYERS + 1];
float g_flTauntStart[MAXPLAYERS + 1];
float g_flTauntLen[MAXPLAYERS + 1];
float g_flCycleIn[MAXPLAYERS + 1];    // part of the sequence the clone shows (TauntWindow)
float g_flCycleOut[MAXPLAYERS + 1];
bool g_bFlexClone[MAXPLAYERS + 1];
ArrayList g_aHidden[MAXPLAYERS + 1];   // wearables this taunt hid (restore only those)
// Joined partner / group taunts (JoinHostedTaunt)
bool g_bMimic[MAXPLAYERS + 1];        // group taunt (Conga, Kazotsky Kick, Mannrobics): loops, may move
float g_flMimicSpeed[MAXPLAYERS + 1]; // forward speed (Conga walks by itself), 0 = input
int g_iMimicHost[MAXPLAYERS + 1];
bool g_bMimicAuto[MAXPLAYERS + 1];
float g_flMimicLen[MAXPLAYERS + 1];
float g_flHostLock[MAXPLAYERS + 1];
float g_flMimicYaw[MAXPLAYERS + 1];  // body yaw, turned at taunt_turn_speed  // a stock host playing his success scene with a role partner  // loop length of the group-taunt sequence
StringMap g_PartnerScenes;            // "def|class" -> "scene;scene;..." (initiator success scenes)
StringMap g_PartnerSep;               // "def" -> forward separation

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	MarkNativeAsOptional("TF2CC_Speak");
	MarkNativeAsOptional("TF2CC_GetWeaponId");
	MarkNativeAsOptional("TF2CC_RefreshWeaponVisuals");
	CreateNative("TF2CC_PlayTaunt", Native_PlayTaunt);
	CreateNative("TF2CC_IsTaunting", Native_IsTaunting);
	RegPluginLibrary("tf2cc_taunts");
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvEnabled = CreateConVar("tf2cc_taunts_enabled", "1", "Enable experimental sequence taunts for roles.", _, true, 0.0, true, 1.0);
	// tf_taunt_prop crashed the server when driven without a scene (play-test 2026-11-10).
	g_cvPropClass = CreateConVar("tf2cc_taunts_prop_class", "funCBaseFlex", "Clone entity: funCBaseFlex (default: a flex entity, so the eyes look ahead; the plugin drives its animation) | prop_dynamic_override (eyes roll up, may show the reference pose at the end) | tf_taunt_prop (EXPERIMENTAL: crashed srcds in testing).");
	g_cvDebug = CreateConVar("tf2cc_taunts_debug", "0", "1 = log which weapon id and taunt each taunt picked.", _, true, 0.0, true, 1.0);
	g_cvMode = CreateConVar("tf2cc_taunts_mode", "clone", "clone = a prop copy plays the taunt while the player is hidden (default); player = the player model plays it (EXPERIMENTAL: eyes and lip-sync, but T-posed on a test client).");
	AutoExecConfig(true, "tf2cc_taunts");
	LoadTranslations("common.phrases");
	AddCommandListener(Listener_Taunt, "taunt");
	AddCommandListener(Listener_Taunt, "+taunt");
	HookEvent("player_death", Event_Death);
	HookEvent("player_spawn", Event_Death);
	// Weapon switching would re-show the donor or a custom world model mid-taunt.
	static const char switchCmds[][] = { "use", "lastinv", "invnext", "invprev", "slot1", "slot2", "slot3", "slot4", "slot5", "slot6", "slot7", "slot8", "slot9", "slot10" };
	for (int i = 0; i < sizeof(switchCmds); i++)
		AddCommandListener(Listener_Switch, switchCmds[i]);
	LoadPartnerTaunts();
	RegAdminCmd("sm_tf2cc_tauntstate", Cmd_TauntState, ADMFLAG_GENERIC, "Show taunt state of role players.");
	RegAdminCmd("sm_tf2cc_taunt", Cmd_Taunt, ADMFLAG_CHEATS, "sm_tf2cc_taunt <target> [sequence] - make a role player taunt (their normal pick, or a named sequence).");
}

public Action Listener_Switch(int client, const char[] command, int argc)
{
	return client > 0 && client <= MaxClients && IsTaunting(client) ? Plugin_Handled : Plugin_Continue;
}

/**
 * native bool TF2CC_PlayTaunt(int client, const char[] sequence, float duration)
 * Other modules' taunt-style actions (lunchbox eating/drinking, joined partner
 * taunts) through the normal clone taunt: camera, input lock, weapon hidden.
 */
public any Native_PlayTaunt(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client) || IsTaunting(client)
		|| TF2CC_GetRole(client) == TF2CC_ROLE_NONE)
		return false;
	char seq[64];
	GetNativeString(2, seq, sizeof(seq));
	float duration = GetNativeCell(3);
	StartTaunt(client, seq, duration > 0.5 ? duration : 1.0, "", 0.0);
	return IsTaunting(client);
}

public any Native_IsTaunting(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	return client > 0 && client <= MaxClients && IsTaunting(client);
}

public Action Cmd_Taunt(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "Usage: sm_tf2cc_taunt <target> [sequence]");
		return Plugin_Handled;
	}
	char arg[64], seq[64];
	GetCmdArg(1, arg, sizeof(arg));
	if (args >= 2)
		GetCmdArg(2, seq, sizeof(seq));
	int targets[MAXPLAYERS];
	char name[64];
	bool tn;
	int n = ProcessTargetString(arg, client, targets, sizeof(targets), COMMAND_FILTER_ALIVE, name, sizeof(name), tn);
	if (n <= 0)
	{
		ReplyToTargetError(client, n);
		return Plugin_Handled;
	}
	for (int i = 0; i < n; i++)
	{
		if (seq[0])
			StartTaunt(targets[i], seq, 3.0, "", 0.0);
		else
			Listener_Taunt(targets[i], "taunt", 0);
	}
	ReplyToCommand(client, "[TF2CC] taunt sent to %d player(s)", n);
	return Plugin_Handled;
}

public void OnPluginEnd()
{
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i))
			EndTaunt(i);
}

public void OnClientDisconnect(int client) { EndTaunt(client); }
public void OnClientPutInServer(int client) { g_flNextTaunt[client] = 0.0; g_flHostLock[client] = 0.0; }

void ReleaseHost(int client)
{
	g_flHostLock[client] = 0.0;
	if (IsClientInGame(client))
	{
		SetVariantInt(0);
		AcceptEntityInput(client, "SetForcedTauntCam");
		if (HasEntProp(client, Prop_Send, "m_hHighFivePartner"))
			SetEntPropEnt(client, Prop_Send, "m_hHighFivePartner", -1);
	}
}
public void TF2CC_OnRoleCleared(int client, int oldRole) { EndTaunt(client); }
public void Event_Death(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client)
		EndTaunt(client);
}

public Action Listener_Taunt(int client, const char[] command, int argc)
{
	int role = TF2CC_IsValidClient(client) ? TF2CC_GetRole(client) : TF2CC_ROLE_NONE;
	if (role == TF2CC_ROLE_NONE)
		return Plugin_Continue;
	// Game time restarts at every map change while connected players keep their
	// slot: a cooldown set late on the previous map would otherwise block taunts
	// for about as long as that map ran. No real cooldown exceeds a taunt + 1 s.
	float now = GetGameTime();
	if (g_flNextTaunt[client] - now > 30.0)
		g_flNextTaunt[client] = 0.0;
	// A second taunt press leaves a joined group taunt (like releasing it on a stock class).
	if (IsTaunting(client) && g_bMimic[client])
	{
		EndTaunt(client);
		return Plugin_Handled;
	}
	if (g_cvEnabled.BoolValue && IsPlayerAlive(client) && !IsTaunting(client) && (GetEntityFlags(client) & FL_ONGROUND)
		&& JoinHostedTaunt(client))
		return Plugin_Handled;
	if (!g_cvEnabled.BoolValue || !IsPlayerAlive(client) || IsTaunting(client)
		|| now < g_flNextTaunt[client] || !(GetEntityFlags(client) & FL_ONGROUND))
		return Plugin_Handled;

	// OF picks the taunt by held weapon (talker tf.txt): roles.cfg "weapon_taunts".
	char spec[96];
	if (WeaponTaunt(client, role, spec, sizeof(spec)))
	{
		if (g_cvDebug.BoolValue)
			LogMessage("taunt %N: weapon pick '%s'", client, spec);
		// Halloween: a "taunts" entry flagged halloween may replace the weapon
		// taunt at random (as the Civilian's list already does), but never a
		// taunt kill (roles.cfg "taunt_kills", e.g. the Merc's Bond pistol taunt).
		char hspec[96];
		if (!IsTauntKill(role, spec) && GetRandomInt(0, 1) == 1 && HalloweenTaunt(role, hspec, sizeof(hspec)))
			strcopy(spec, sizeof(spec), hspec);
		char p[5][64];
		ExplodeString(spec, ":", p, sizeof(p), sizeof(p[]));
		float dur = p[1][0] ? StringToFloat(p[1]) : 4.0;
		StartTaunt(client, p[0], dur > 0.5 ? dur : 4.0, p[2], p[3][0] ? StringToFloat(p[3]) : 0.0);
		return Plugin_Handled;
	}
	char list[512];
	if (!TF2CC_GetRoleString(role, "taunts", list, sizeof(list)) || !list[0])
		return Plugin_Handled;
	char entries[12][96];
	int n = ExplodeString(list, ",", entries, sizeof(entries), sizeof(entries[]));
	int usable[12], count = 0;
	bool halloween = TF2_IsHolidayActive(TFHoliday_Halloween);
	char parts[5][64];
	for (int i = 0; i < n; i++)
	{
		int k = ExplodeString(entries[i], ":", parts, sizeof(parts), sizeof(parts[]));
		if (k >= 5 && StrEqual(parts[4], "halloween", false) && !halloween)
			continue;
		usable[count++] = i;
	}
	if (count <= 0)
		return Plugin_Handled;
	for (int i = 0; i < sizeof(parts); i++)
		parts[i][0] = '\0';
	ExplodeString(entries[usable[GetRandomInt(0, count - 1)]], ":", parts, sizeof(parts), sizeof(parts[]));
	TrimString(parts[0]);
	float duration = parts[1][0] ? StringToFloat(parts[1]) : 4.0;
	if (duration <= 0.5)
		duration = 4.0;
	StartTaunt(client, parts[0], duration, parts[2], parts[3][0] ? StringToFloat(parts[3]) : 0.0);
	return Plugin_Handled;
}

void StartTaunt(int client, const char[] sequence, float duration, const char[] concept, float voiceDelay)
{
	char model[PLATFORM_MAX_PATH];
	GetEntPropString(client, Prop_Send, "m_iszCustomModel", model, sizeof(model));
	if (!model[0])
		return;
	char mode[16];
	g_cvMode.GetString(mode, sizeof(mode));
	bool playerMode = !StrEqual(mode, "clone", false);
	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	int prop;
	if (playerMode)
	{
		int seq = ResolveSequence(model, sequence);
		if (seq < 0)
		{
			LogError("tf2cc_taunts: sequence '%s' not found in %s", sequence, model);
			return;
		}
		prop = client;
		g_iProp[client] = EntIndexToEntRef(client);
		SendAnimEvent(client, PLAYERANIMEVENT_CUSTOM_SEQUENCE, seq);
		// Carried weapons ignore render mode; EF_NODRAW hides the stock model.
		if (weapon > MaxClients)
		{
			int fx = GetEntProp(weapon, Prop_Send, "m_fEffects");
			g_bWeaponWasHidden[client] = (fx & EF_NODRAW) != 0;
			g_iTauntWeapon[client] = EntIndexToEntRef(weapon);
			SetEntProp(weapon, Prop_Send, "m_fEffects", fx | EF_NODRAW);
		}
	}
	else
	{
		int skin = GetClientTeam(client) == view_as<int>(TFTeam_Blue) ? 1 : 0;
		prop = CreateTauntActor(model, sequence, skin);
		if (prop == -1)
			return;
		float pos[3], ang[3];
		GetClientAbsOrigin(client, pos);
		GetClientEyeAngles(client, ang);
		ang[0] = 0.0;
		ang[2] = 0.0;
		TeleportEntity(prop, pos, ang, NULL_VECTOR);
		g_iProp[client] = EntIndexToEntRef(prop);
		g_bFlexClone[client] = HasEntProp(prop, Prop_Send, "m_viewtarget");
		g_flTauntStart[client] = GetGameTime();
		g_flTauntLen[client] = duration;
		TauntWindow(client, sequence, g_flCycleIn[client], g_flCycleOut[client]);
		if (g_bFlexClone[client])
			SetEntPropFloat(prop, Prop_Data, "m_flCycle", g_flCycleIn[client]);
		if (g_bFlexClone[client])
		{
			// Eyes: a flex entity aims its eyeballs at m_viewtarget (prop_dynamic
			// cannot, so its eyes rolled up). A point ahead of the face.
			float fwd[3], target[3];
			GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
			target[0] = pos[0] + fwd[0] * 256.0;
			target[1] = pos[1] + fwd[1] * 256.0;
			target[2] = pos[2] + 64.0;
			SetEntPropVector(prop, Prop_Send, "m_viewtarget", target);
		}
		SetEntityRenderMode(client, RENDER_NONE);
		if (weapon > MaxClients)
			SetEntityRenderMode(weapon, RENDER_NONE);
	}
	float eyes[3];
	GetClientEyeAngles(client, eyes);
	g_flTauntYaw[client] = eyes[1];
	g_bPlayerMode[client] = playerMode;
	g_bTaunting[client] = true;
	SetWearablesHidden(client, true);   // custom world-model wearables ride the player
	// Like stock taunts only input is locked (OnPlayerRunCmd): no MOVETYPE_NONE,
	// so gravity, moving ground (m_hGroundEntity / m_vecBaseVelocity) and
	// platforms still carry the player. A grounded player stops walking.
	// Networked and predicted: the client stops predicting shots too.
	// Clone: the taunt ends with the sequence's last upright frame (TauntWindow),
	// where a scene would start blending back; the player model takes over.
	if (!playerMode && g_flCycleOut[client] < 1.0)
		duration *= g_flCycleOut[client];
	float until = GetGameTime() + duration;
	SetEntPropFloat(client, Prop_Send, "m_flNextAttack", until);
	if (weapon > MaxClients)
	{
		SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", until);
		SetEntPropFloat(weapon, Prop_Send, "m_flNextSecondaryAttack", until);
	}
	if (GetEntPropEnt(client, Prop_Send, "m_hGroundEntity") != -1)
	{
		// Drop only the walking velocity (relative to the ground); a falling or
		// jumping player keeps his momentum and lands normally.
		float v[3];
		GetEntPropVector(client, Prop_Data, "m_vecVelocity", v);
		v[0] = 0.0;
		v[1] = 0.0;
		TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, v);
	}
	SetVariantInt(1);
	AcceptEntityInput(client, "SetForcedTauntCam");

	if (concept[0] && LibraryExists("tf2cc_voice"))
	{
		if (voiceDelay <= 0.0)
			TF2CC_Speak(client, concept, true);
		else
		{
			DataPack dp;
			CreateDataTimer(voiceDelay, Timer_TauntVoice, dp, TIMER_FLAG_NO_MAPCHANGE);
			dp.WriteCell(GetClientUserId(client));
			dp.WriteString(concept);
		}
	}

	if (StrEqual(sequence, "taunt_bond"))
		CreateTimer(1.6, Timer_BondShot, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	ScheduleTauntEvents(client, sequence, prop);

	delete g_hEndTimer[client];
	g_hEndTimer[client] = CreateTimer(duration, Timer_End, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	g_flNextTaunt[client] = GetGameTime() + duration + 1.0;
}

public Action Timer_End(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client)
	{
		g_hEndTimer[client] = null;
		EndTaunt(client);
	}
	return Plugin_Stop;
}

bool IsTaunting(int client)
{
	return g_bTaunting[client] && EntRefToEntIndex(g_iProp[client]) > 0;
}

public void OnMapStart()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		g_bTaunting[i] = false;
		g_bPlayerMode[i] = false;
		g_iProp[i] = INVALID_ENT_REFERENCE;
		g_hEndTimer[i] = null;   // TIMER_FLAG_NO_MAPCHANGE timers are already gone
		g_flNextTaunt[i] = 0.0;  // game time restarts with the map
	}
}

public void Frame_EndMimic(int userid)
{
	int client = GetClientOfUserId(userid);
	if (client && IsTaunting(client) && g_bMimic[client])
		EndTaunt(client);
}

void EndTaunt(int client)
{
	g_bMimic[client] = false;
	g_iMimicHost[client] = 0;
	delete g_hEndTimer[client];
	int prop = EntRefToEntIndex(g_iProp[client]);
	g_iProp[client] = INVALID_ENT_REFERENCE;
	bool was = g_bTaunting[client];
	g_bTaunting[client] = false;
	// Restore the player even when the clone is already gone (a round restart
	// removes it): returning early left them invisible, frozen in the taunt
	// camera and with their wearables hidden.
	if (!was)
		return;
	if (g_bPlayerMode[client])
	{
		g_bPlayerMode[client] = false;
		if (!IsClientInGame(client))
			return;
		if (IsPlayerAlive(client))
			SendAnimEvent(client, PLAYERANIMEVENT_SPAWN, 0);   // back to normal animation
		int w = EntRefToEntIndex(g_iTauntWeapon[client]);
		g_iTauntWeapon[client] = INVALID_ENT_REFERENCE;
		// Custom weapons keep their donor hidden (tf2cc_weapons world-model wearable).
		if (w > MaxClients && !g_bWeaponWasHidden[client])
			SetEntProp(w, Prop_Send, "m_fEffects", GetEntProp(w, Prop_Send, "m_fEffects") & ~EF_NODRAW);
	}
	else
	{
		if (prop > MaxClients)
			RemoveEntity(prop);
		if (!IsClientInGame(client))
			return;
		SetEntityRenderMode(client, RENDER_NORMAL);
		int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		if (weapon > MaxClients)
			SetEntityRenderMode(weapon, RENDER_NORMAL);
	}
	SetWearablesHidden(client, false);
	// A taunt cut short (a group taunt left early, a stun) gives attacks back now,
	// not at the planned end.
	float now = GetGameTime();
	if (GetEntPropFloat(client, Prop_Send, "m_flNextAttack") > now)
		SetEntPropFloat(client, Prop_Send, "m_flNextAttack", now);
	int aw = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (aw > MaxClients && HasEntProp(aw, Prop_Send, "m_flNextPrimaryAttack"))
	{
		if (GetEntPropFloat(aw, Prop_Send, "m_flNextPrimaryAttack") > now + 0.1)
			SetEntPropFloat(aw, Prop_Send, "m_flNextPrimaryAttack", now + 0.1);
		if (GetEntPropFloat(aw, Prop_Send, "m_flNextSecondaryAttack") > now + 0.1)
			SetEntPropFloat(aw, Prop_Send, "m_flNextSecondaryAttack", now + 0.1);
	}
	if (g_flNextTaunt[client] > now + 1.0)
		g_flNextTaunt[client] = now + 1.0;
	if (IsPlayerAlive(client))
		SetEntityMoveType(client, MOVETYPE_WALK);
	SetVariantInt(0);
	AcceptEntityInput(client, "SetForcedTauntCam");
	// Back in first person the Merc/Civ arms overlay sometimes stayed hidden.
	// Again once the client's taunt camera has swung back into first person.
	if (IsPlayerAlive(client) && LibraryExists("tf2cc_weapons"))
	{
		static const float delays[] = { 0.1, 0.4, 0.8, 1.3, 2.0 };
		for (int i = 0; i < sizeof(delays); i++)
			CreateTimer(delays[i], Timer_RefreshVisuals, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action Timer_RefreshVisuals(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client && !IsTaunting(client))
		TF2CC_RefreshWeaponVisuals(client);
	return Plugin_Stop;
}

/**
 * OF Mercenary Bond taunt (tf_player.cpp TF_TAUNT_BOND, SetTauntEffect 1.6 s):
 * a 500 u line along the eye angles; an enemy player takes 500 DMG_BULLET from
 * the active weapon with a 25000 force pitched 45 degrees up.
 */
public Action Timer_BondShot(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (!client || !IsPlayerAlive(client) || !IsTaunting(client))
		return Plugin_Stop;
	float eye[3], ang[3], dir[3], end[3];
	GetClientEyePosition(client, eye);
	// Along the taunt's facing: in clone mode the view orbits freely.
	ang[1] = g_flTauntYaw[client];
	GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(dir, 500.0);
	AddVectors(eye, dir, end);
	Handle tr = TR_TraceRayFilterEx(eye, end, MASK_SOLID | CONTENTS_HITBOX, RayType_EndPoint, Filter_NotSelf, client);
	int hit = TR_GetEntityIndex(tr);
	float pos[3];
	TR_GetEndPosition(pos, tr);
	delete tr;
	if (hit < 1 || hit > MaxClients || !IsPlayerAlive(hit) || GetClientTeam(hit) == GetClientTeam(client))
		return Plugin_Stop;
	float force[3], fang[3];
	fang[0] = -45.0;
	fang[1] = ang[1];
	GetAngleVectors(fang, force, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(force, 25000.0);
	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	SDKHooks_TakeDamage(hit, client, client, 500.0, DMG_BULLET, weapon > MaxClients ? weapon : -1, force, pos);
	return Plugin_Stop;
}

public bool Filter_NotSelf(int entity, int mask, int client)
{
	return entity != client;
}

public Action Timer_TauntVoice(Handle timer, DataPack dp)
{
	dp.Reset();
	int client = GetClientOfUserId(dp.ReadCell());
	char concept[64];
	dp.ReadString(concept, sizeof(concept));
	if (client && IsTaunting(client))
		TF2CC_Speak(client, concept, true);
	return Plugin_Stop;
}

/**
 * Flex clones have no animation think of their own: advance the cycle every
 * frame over the taunt's length and hold the last frame (no reference pose
 * between the end of the sequence and the end of the taunt).
 */
public void OnGameFrame()
{
	float now = GetGameTime();
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!g_bTaunting[i] || g_bPlayerMode[i])
			continue;
		int prop = EntRefToEntIndex(g_iProp[i]);
		if (prop <= MaxClients)
			continue;
		// The player still falls and rides platforms while taunting (only input
		// is locked): keep the clone on the player's current origin.
		if (IsClientInGame(i))
		{
			float pos[3];
			GetClientAbsOrigin(i, pos);
			TeleportEntity(prop, pos, NULL_VECTOR, NULL_VECTOR);
		}
		if (!g_bFlexClone[i])
			continue;
		// The taunt keeps its own timeline (voice lines, the Bond shot and model
		// events are timed against it); only the shown frame is held inside the
		// sequence's window, so the blend-in/out frames are never drawn.
		float cycle = g_flTauntLen[i] > 0.0 ? (now - g_flTauntStart[i]) / g_flTauntLen[i] : 1.0;
		if (g_bMimic[i])
		{
			cycle = g_flMimicLen[i] > 0.0 ? (now - g_flTauntStart[i]) / g_flMimicLen[i] : 0.0;
			// Looping dance: wrap the cycle and turn with the player.
			cycle -= RoundToFloor(cycle);
			float eye[3];
			GetClientEyeAngles(i, eye);
			eye[0] = 0.0;
			eye[2] = 0.0;
			TeleportEntity(prop, NULL_VECTOR, eye, NULL_VECTOR);
		}
		else
		{
			if (cycle < g_flCycleIn[i])
				cycle = g_flCycleIn[i];
			if (cycle > g_flCycleOut[i])
				cycle = g_flCycleOut[i];
		}
		SetEntPropFloat(prop, Prop_Send, "m_flCycle", cycle);
		// m_flAnimTime is networked as an int: the Prop_Send write threw every
		// frame and aborted the loop before any later taunting player.
		SetEntPropFloat(prop, Prop_Data, "m_flAnimTime", now);
		SetEntPropFloat(prop, Prop_Send, "m_flPlaybackRate", 0.0);
	}
}

/** No attacking, reloading or alt-fire while taunting. */
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
	if (g_flHostLock[client] > 0.0)
	{
		if (GetGameTime() < g_flHostLock[client] && IsPlayerAlive(client))
		{
			// Stand still for the success scene, as TF_COND_TAUNTING would hold him.
			buttons &= ~(IN_ATTACK | IN_ATTACK2 | IN_ATTACK3 | IN_JUMP | IN_DUCK
				| IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT);
			vel[0] = vel[1] = vel[2] = 0.0;
			return Plugin_Changed;
		}
		ReleaseHost(client);
	}
	if (!IsTaunting(client))
		return Plugin_Continue;
	if (g_bMimic[client])
	{
		// Group taunts move like on a stock class: Conga walks forward by itself,
		// Kazotsky Kick / Mannrobics take forward/back input; mouse turns.
		buttons &= ~(IN_ATTACK | IN_ATTACK2 | IN_ATTACK3 | IN_RELOAD | IN_JUMP | IN_DUCK | IN_MOVELEFT | IN_MOVERIGHT);
		float sp = g_flMimicSpeed[client];
		if (g_bMimicAuto[client])
			vel[0] = sp;
		else if (vel[0] > sp)
			vel[0] = sp;
		else if (vel[0] < -sp)
			vel[0] = -sp;
		vel[1] = vel[2] = 0.0;
		weapon = 0;
		// items_game taunt_turn_speed 50 (deg/s) for all three.
		float d = angles[1] - g_flMimicYaw[client];
		while (d > 180.0) d -= 360.0;
		while (d < -180.0) d += 360.0;
		float maxd = 50.0 * GetTickInterval();
		if (d > maxd) d = maxd;
		else if (d < -maxd) d = -maxd;
		g_flMimicYaw[client] += d;
		angles[1] = g_flMimicYaw[client];
		// The host left his group taunt: so do we (stock mimics keep going on their own,
		// but a clone without the host's item has nothing to keep it).
		int host = g_iMimicHost[client];
		if (host > 0 && (!IsClientInGame(host) || !IsPlayerAlive(host) || !TF2_IsPlayerInCondition(host, TFCond_Taunting)))
			RequestFrame(Frame_EndMimic, GetClientUserId(client));
		return Plugin_Changed;
	}
	buttons &= ~(IN_ATTACK | IN_ATTACK2 | IN_ATTACK3 | IN_RELOAD | IN_JUMP | IN_DUCK
		| IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT);
	vel[0] = vel[1] = vel[2] = 0.0;
	weapon = 0;
	return Plugin_Changed;
}

/** Sequence index of a named sequence in a model (via a throwaway prop_dynamic). */
int ResolveSequence(const char[] model, const char[] sequence)
{
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
	int seq = GetEntProp(tmp, Prop_Send, "m_nSequence");
	RemoveEntity(tmp);
	if (seq >= 65535)
		seq = -1;
	return seq;
}

int CreateTauntActor(const char[] model, const char[] sequence, int skin)
{
	int seq = ResolveSequence(model, sequence);
	if (seq < 0)
	{
		LogError("tf2cc_taunts: sequence '%s' not found in %s", sequence, model);
		return -1;
	}
	char cls[64];
	g_cvPropClass.GetString(cls, sizeof(cls));
	int prop = StrEqual(cls, "tf_taunt_prop") || StrEqual(cls, "funCBaseFlex") ? CreateEntityByName(cls) : -1;
	if (prop != -1)
	{
		PrecacheModel(model);
		DispatchKeyValue(prop, "model", model);
		DispatchSpawn(prop);
		PrecacheModel(model);
		SetEntityModel(prop, model);
		SetEntProp(prop, Prop_Send, "m_nSkin", skin);
		SetEntProp(prop, Prop_Send, "m_nSolidType", 0);
		SetEntityMoveType(prop, MOVETYPE_NONE);
		SetEntProp(prop, Prop_Send, "m_nSequence", seq);
		SetEntPropFloat(prop, Prop_Send, "m_flPlaybackRate", 1.0);
		SetEntPropFloat(prop, Prop_Data, "m_flCycle", 0.0);
		SetEntProp(prop, Prop_Send, "m_nNewSequenceParity", (GetEntProp(prop, Prop_Send, "m_nNewSequenceParity") + 1) & 7);
		SetEntProp(prop, Prop_Send, "m_nResetEventsParity", (GetEntProp(prop, Prop_Send, "m_nResetEventsParity") + 1) & 7);
		return prop;
	}
	prop = CreateEntityByName("prop_dynamic_override");
	if (prop == -1)
		return -1;
	char sk[4];
	IntToString(skin, sk, sizeof(sk));
	DispatchKeyValue(prop, "model", model);
	DispatchKeyValue(prop, "solid", "0");
	DispatchKeyValue(prop, "DefaultAnim", sequence);
	DispatchKeyValue(prop, "HoldAnimation", "1");
	DispatchKeyValue(prop, "skin", sk);
	if (!DispatchSpawn(prop))
	{
		RemoveEntity(prop);
		return -1;
	}
	SetVariantString(sequence);
	AcceptEntityInput(prop, "SetAnimation");
	return prop;
}

/**
 * OF/TF2C (and stock) taunt sequences are made to be blended in and out by a
 * scene: their first and last few percent ramp from a collapsed pose at the
 * model origin (the player lying on his back in the floor) up to the taunt.
 * Measured on the test server with VScript GetBoneOrigin(bip_head), head
 * height over the origin: Merc taunt01 0 at cycle 0, 72 by 0.05, 68 at 0.89,
 * 0 at 1.0; every Merc and Civilian taunt has the same ramps (lengths differ).
 * Playing the clone to cycle 0.999 showed that collapse at the end of every
 * taunt before the player model came back ("sinks to the floor on his back").
 * roles.cfg "taunt_windows" "seq=in-out;..." gives the upright part of each
 * sequence; sequences not listed use 0.03-0.97.
 */
void TauntWindow(int client, const char[] sequence, float &cin, float &cout)
{
	cin = 0.03;
	cout = 0.97;
	int role = TF2CC_GetRole(client);
	char map[1024];
	if (role == TF2CC_ROLE_NONE || !TF2CC_GetRoleString(role, "taunt_windows", map, sizeof(map)) || !map[0])
		return;
	char entries[24][48];
	int n = ExplodeString(map, ";", entries, sizeof(entries), sizeof(entries[]));
	for (int i = 0; i < n; i++)
	{
		TrimString(entries[i]);
		int eq = FindCharInString(entries[i], '=');
		if (eq <= 0)
			continue;
		entries[i][eq] = '\0';
		if (!StrEqual(entries[i], sequence, false))
			continue;
		char p[2][16];
		if (ExplodeString(entries[i][eq + 1], "-", p, sizeof(p), sizeof(p[])) != 2)
			return;
		float a = StringToFloat(p[0]), b = StringToFloat(p[1]);
		if (a >= 0.0 && b <= 1.0 && a < b)
		{
			cin = a;
			cout = b > 0.999 ? 0.999 : b;
		}
		return;
	}
}

/* ========================================================================= */
/* Joining partner and group taunts hosted by someone else                   */
/*  Stock: CTFPlayer::Taunt -> FindPartnerTauntInitiator (a player within     */
/*  tf_highfive_max_range who IsReadyToTauntWithPartner, i.e.                */
/*  m_bIsReadyToHighFive, both facing each other, nothing in between) ->      */
/*  AcceptTauntWithPartner (receiver moved to the host's taunt separation,   */
/*  facing him; host plays an initiator success scene of his class) or, for  */
/*  "taunt mimic" items (Conga, Kazotsky Kick, Mannrobics), MimicTaunt-      */
/*  FromPartner (the joiner plays the same taunt). The scenes are per class, */
/*  so class 10 never joined. Here the Mercenary/Civilian side plays the     */
/*  matching Soldier sequence on the tf2cc clone (the role models include    */
/*  the Soldier taunt animations), and the host's success scene comes from   */
/*  items_game through VScript (CTFPlayer.StopTaunt / PlayScene). The role   */
/*  never hosts; without a host nearby pressing taunt does the role's own.   */
/*  Soldier VO never plays (the clone runs no scenes); the role's own line   */
/*  does (roles.cfg persona concepts).                                       */
/* ========================================================================= */

#define PARTNER_DEFS_COUNT 8
int g_iPartnerDefs[PARTNER_DEFS_COUNT] = { 167, 1106, 1107, 1110, 1111, 1118, 1157, 1162 };

void LoadPartnerTaunts()
{
	delete g_PartnerScenes;
	delete g_PartnerSep;
	g_PartnerScenes = new StringMap();
	g_PartnerSep = new StringMap();
	KeyValues kv = new KeyValues("items_game");
	if (!kv.ImportFromFile("scripts/items/items_game.txt") || !kv.JumpToKey("items"))
	{
		delete kv;
		LogError("tf2cc_taunts: items_game.txt not readable; joining partner taunts is off");
		return;
	}
	char def[16], cls[16], scene[PLATFORM_MAX_PATH], list[1024], key[32];
	for (int d = 0; d < PARTNER_DEFS_COUNT; d++)
	{
		IntToString(g_iPartnerDefs[d], def, sizeof(def));
		if (!kv.JumpToKey(def))
			continue;
		if (kv.JumpToKey("taunt"))
		{
			g_PartnerSep.SetValue(def, kv.GetFloat("taunt_separation_forward_distance", 0.0));
			if (kv.JumpToKey("custom_partner_taunt_initiator_per_class") || kv.JumpToKey("custom_partner_taunt_per_class"))
			{
				if (kv.GotoFirstSubKey())
				{
					do
					{
						kv.GetSectionName(cls, sizeof(cls));
						list[0] = '\0';
						if (kv.GotoFirstSubKey(false))
						{
							do
							{
								kv.GetString(NULL_STRING, scene, sizeof(scene));
								if (scene[0])
								{
									if (list[0])
										StrCat(list, sizeof(list), ";");
									StrCat(list, sizeof(list), scene);
								}
							}
							while (kv.GotoNextKey(false));
							kv.GoBack();
						}
						FormatEx(key, sizeof(key), "%s|%s", def, cls);
						g_PartnerScenes.SetString(key, list);
					}
					while (kv.GotoNextKey());
					kv.GoBack();
				}
				kv.GoBack();
			}
			kv.GoBack();
		}
		kv.GoBack();
	}
	delete kv;
}

/** Role sequence, length and own voice concept for a hosted taunt item; false = not joinable. */
bool PartnerSequence(int def, int rpsResult, char[] seq, int maxlen, float &len, char[] concept, int clen, bool &mimic, float &speed, bool &autoMove)
{
	mimic = false;
	speed = 0.0;
	autoMove = false;
	static const char rps[][] = { "rock", "paper", "scissors" };
	switch (def)
	{
		case 167:  { strcopy(seq, maxlen, "taunt_highfiveSuccess"); len = 4.17; strcopy(concept, clen, "_cheers"); }
		case 1106: { strcopy(seq, maxlen, "taunt_dosido_dance"); len = 8.3; strcopy(concept, clen, "_laughhappy"); }
		case 1107: { strcopy(seq, maxlen, "taunt_flip_success_receiver"); len = 3.83; strcopy(concept, clen, "_flip_exert"); }
		case 1110:
		{
			// rpsResult: 0..2 the role wins with rock/paper/scissors, 3..5 loses with them
			FormatEx(seq, maxlen, "taunt_rps_%s_%s", rps[rpsResult % 3], rpsResult < 3 ? "win" : "lose");
			len = 6.8;
			strcopy(concept, clen, rpsResult < 3 ? "_cheers" : "_rps_lose");
		}
		case 1111: { strcopy(seq, maxlen, "taunt_headbutt_success"); len = 4.5; strcopy(concept, clen, "_battlecry"); }
		case 1118: { strcopy(seq, maxlen, "taunt_conga"); len = 11.49; strcopy(concept, clen, "_cong_fun"); mimic = true; speed = 50.0; autoMove = true; }
		case 1157: { strcopy(seq, maxlen, "taunt_russian"); len = 11.73; strcopy(concept, clen, "_laughhappy"); mimic = true; speed = 50.0; }
		case 1162: { strcopy(seq, maxlen, "taunt_aerobic_A"); len = 7.5; strcopy(concept, clen, "_laughhappy"); mimic = true; speed = 50.0; }
		default: return false;
	}
	return true;
}

int FindTauntHost(int client)
{
	ConVar allTeams = FindConVar("tf_allow_all_team_partner_taunt");
	ConVar range = FindConVar("tf_highfive_max_range");
	float maxr = range != null ? range.FloatValue : 150.0;
	float eye[3], fwd[3], pos[3], hpos[3], to[3];
	GetClientEyeAngles(client, eye);
	eye[0] = 0.0;
	GetAngleVectors(eye, fwd, NULL_VECTOR, NULL_VECTOR);
	GetClientAbsOrigin(client, pos);
	int best = -1;
	float bestd = maxr * maxr;
	for (int h = 1; h <= MaxClients; h++)
	{
		if (h == client || !IsClientInGame(h) || !IsPlayerAlive(h) || !TF2_IsPlayerInCondition(h, TFCond_Taunting))
			continue;
		if ((allTeams == null || !allTeams.BoolValue) && GetClientTeam(h) != GetClientTeam(client))
			continue;
		int def = HasEntProp(h, Prop_Send, "m_iTauntItemDefIndex") ? GetEntProp(h, Prop_Send, "m_iTauntItemDefIndex") : -1;
		bool mimicDef = def == 1118 || def == 1157 || def == 1162;
		if (!mimicDef && !GetEntProp(h, Prop_Send, "m_bIsReadyToHighFive"))
			continue;
		GetClientAbsOrigin(h, hpos);
		SubtractVectors(hpos, pos, to);
		to[2] = 0.0;
		float d = GetVectorLength(to, true);
		if (d > bestd)
			continue;
		NormalizeVector(to, to);
		if (GetVectorDotProduct(to, fwd) < 0.6)
			continue;   // we are not looking at that player
		if (!mimicDef)
		{
			float hang[3], hfwd[3];
			GetClientAbsAngles(h, hang);
			hang[0] = 0.0;
			GetAngleVectors(hang, hfwd, NULL_VECTOR, NULL_VECTOR);
			if (GetVectorDotProduct(to, hfwd) > -0.6)
				continue;   // the host is not facing us
		}
		best = h;
		bestd = d;
	}
	return best;
}

bool JoinHostedTaunt(int client)
{
	if (g_PartnerScenes == null)
		return false;
	int host = FindTauntHost(client);
	if (host < 1)
		return false;
	int def = GetEntProp(host, Prop_Send, "m_iTauntItemDefIndex");
	int winner = GetRandomInt(0, 2), loser = ((winner + 2) % 3) + 3;
	bool roleWins = GetRandomInt(0, 1) == 1;
	int roleResult = roleWins ? winner : loser;
	int hostResult = roleWins ? loser : winner;
	char seq[64], concept[32];
	float len, speed;
	bool mimic, autoMove;
	if (!PartnerSequence(def, roleResult, seq, sizeof(seq), len, concept, sizeof(concept), mimic, speed, autoMove))
		return false;

	if (!mimic)
	{
		// AcceptTauntWithPartner: in front of the host at his taunt separation, facing him.
		float hpos[3], hang[3], fwd[3], dest[3];
		GetClientAbsOrigin(host, hpos);
		GetClientAbsAngles(host, hang);
		hang[0] = 0.0;
		hang[2] = 0.0;
		GetAngleVectors(hang, fwd, NULL_VECTOR, NULL_VECTOR);
		char dkey[16];
		IntToString(def, dkey, sizeof(dkey));
		float sep = 0.0;
		g_PartnerSep.GetValue(dkey, sep);
		if (sep <= 0.0)
			sep = 70.0;
		for (int k = 0; k < 3; k++)
			dest[k] = hpos[k] + fwd[k] * sep;
		dest[2] = hpos[2];
		float face[3];
		face[1] = hang[1] + 180.0;
		TeleportEntity(client, dest, face, view_as<float>({ 0.0, 0.0, 0.0 }));
		HostSuccessScene(host, def, client, hostResult, len);
	}
	g_bMimic[client] = mimic;   // before the clone's first frame
	g_flMimicLen[client] = len;
	StartTaunt(client, seq, mimic ? 600.0 : len, concept, mimic ? 0.5 : 0.3);
	if (!IsTaunting(client))
	{
		g_bMimic[client] = false;
		return false;
	}
	g_flMimicSpeed[client] = speed;
	float eyes[3];
	GetClientEyeAngles(client, eyes);
	g_flMimicYaw[client] = eyes[1];
	g_bMimicAuto[client] = autoMove;
	g_iMimicHost[client] = mimic ? host : 0;
	if (g_cvDebug.BoolValue)
		LogMessage("taunt %N: joined %N's taunt %d as '%s'%s", client, host, def, seq, mimic ? " (group)" : "");
	return true;
}

/** The host's initiator success scene for his class (SelectPartnerTaunt), through VScript. */
void HostSuccessScene(int host, int def, int partner, int hostResult, float len)
{
	static const char classes[][] = { "", "scout", "sniper", "soldier", "demoman", "medic", "heavy", "pyro", "spy", "engineer" };
	int cls = view_as<int>(TF2_GetPlayerClass(host));
	if (cls < 1 || cls > 9)
		return;
	char key[32], list[1024], scenes[8][PLATFORM_MAX_PATH];
	FormatEx(key, sizeof(key), "%d|%s", def, classes[cls]);
	if (!g_PartnerScenes.GetString(key, list, sizeof(list)) || !list[0])
		return;
	int n = ExplodeString(list, ";", scenes, sizeof(scenes), sizeof(scenes[]));
	int pick = def == 1110 ? hostResult : GetRandomInt(0, n - 1);
	if (pick < 0 || pick >= n)
		pick = 0;
	char code[PLATFORM_MAX_PATH + 96];
	FormatEx(code, sizeof(code), "self.StopTaunt(false); self.PlayScene(\"%s\", 0.0)", scenes[pick]);
	SetVariantString(code);
	AcceptEntityInput(host, "RunScriptCode");
	SetEntProp(host, Prop_Send, "m_bIsReadyToHighFive", 0);
	SetEntPropEnt(host, Prop_Send, "m_hHighFivePartner", partner);
	// StopTaunt removed TF_COND_TAUNTING (its end time cannot be set from here):
	// hold him in third person for the scene instead.
	g_flHostLock[host] = GetGameTime() + len + 0.5;
	SetEntPropFloat(host, Prop_Send, "m_flNextAttack", GetGameTime() + len);
	SetVariantInt(1);
	AcceptEntityInput(host, "SetForcedTauntCam");
	if (g_cvDebug.BoolValue)
		LogMessage("taunt: host %N plays %s", host, scenes[pick]);
}

/** roles.cfg "taunt_kills" "seq,seq": sequences whose taunt deals a kill (never replaced at random). */
bool IsTauntKill(int role, const char[] spec)
{
	char seq[64], list[256];
	strcopy(seq, sizeof(seq), spec);
	int colon = FindCharInString(seq, ':');
	if (colon >= 0)
		seq[colon] = '\0';
	if (StrEqual(seq, "taunt_bond", false))
		return true;
	if (!TF2CC_GetRoleString(role, "taunt_kills", list, sizeof(list)) || !list[0])
		return false;
	char parts[12][64];
	int n = ExplodeString(list, ",", parts, sizeof(parts), sizeof(parts[]));
	for (int i = 0; i < n; i++)
	{
		TrimString(parts[i]);
		if (StrEqual(parts[i], seq, false))
			return true;
	}
	return false;
}

/** A random halloween-flagged entry of the role's "taunts" list while Halloween is on. */
bool HalloweenTaunt(int role, char[] out, int maxlen)
{
	if (!TF2_IsHolidayActive(TFHoliday_Halloween))
		return false;
	char list[512];
	if (!TF2CC_GetRoleString(role, "taunts", list, sizeof(list)) || !list[0])
		return false;
	char entries[12][96], parts[5][64];
	int n = ExplodeString(list, ",", entries, sizeof(entries), sizeof(entries[]));
	int pick[12], count = 0;
	for (int i = 0; i < n; i++)
	{
		if (ExplodeString(entries[i], ":", parts, sizeof(parts), sizeof(parts[])) >= 5 && StrEqual(parts[4], "halloween", false))
			pick[count++] = i;
	}
	if (count == 0)
		return false;
	strcopy(out, maxlen, entries[pick[GetRandomInt(0, count - 1)]]);
	TrimString(out);
	return true;
}

/** "weapon_taunts" "id=seq:secs[:concept[:delay]];id=...;default=..." for the active weapon. */
bool WeaponTaunt(int client, int role, char[] spec, int maxlen)
{
	char map[2048];
	if (!TF2CC_GetRoleString(role, "weapon_taunts", map, sizeof(map)) || !map[0])
		return false;
	char id[48] = "default";
	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (weapon > MaxClients && LibraryExists("tf2cc_weapons"))
		TF2CC_GetWeaponId(weapon, id, sizeof(id));
	if (g_cvDebug.BoolValue)
		LogMessage("taunt %N: active %d id '%s'", client, weapon, id);
	char entries[40][96];
	int n = ExplodeString(map, ";", entries, sizeof(entries), sizeof(entries[]));
	char fallback[96];
	for (int i = 0; i < n; i++)
	{
		TrimString(entries[i]);
		int eq = FindCharInString(entries[i], '=');
		if (eq <= 0)
			continue;
		entries[i][eq] = '\0';
		if (StrEqual(entries[i], id, false))
		{
			strcopy(spec, maxlen, entries[i][eq + 1]);
			return true;
		}
		if (StrEqual(entries[i], "default", false))
			strcopy(fallback, sizeof(fallback), entries[i][eq + 1]);
	}
	if (!fallback[0])
		return false;
	strcopy(spec, maxlen, fallback);
	return true;
}

/** Hide/show the player's third-person wearables (tf_wearable, not viewmodel ones) for the taunt. */
void SetWearablesHidden(int client, bool hide)
{
	if (!hide)
	{
		if (g_aHidden[client] != null)
		{
			for (int i = 0; i < g_aHidden[client].Length; i++)
			{
				int w = EntRefToEntIndex(g_aHidden[client].Get(i));
				if (w > MaxClients)
					SetEntProp(w, Prop_Send, "m_fEffects", GetEntProp(w, Prop_Send, "m_fEffects") & ~EF_NODRAW);
			}
		}
		delete g_aHidden[client];
		return;
	}
	delete g_aHidden[client];
	g_aHidden[client] = new ArrayList();
	int e = -1;
	while ((e = FindEntityByClassname(e, "tf_wearable")) != -1)
	{
		if (GetEntPropEnt(e, Prop_Send, "m_hOwnerEntity") != client)
			continue;
		int fx = GetEntProp(e, Prop_Send, "m_fEffects");
		if (fx & EF_NODRAW)
			continue;   // hidden by someone else (e.g. a holstered weapon's model): leave it
		SetEntProp(e, Prop_Send, "m_fEffects", fx | EF_NODRAW);
		g_aHidden[client].Push(EntIndexToEntRef(e));
	}
}

/**
 * Sounds/particles from the taunt sequence's own model events whose sound
 * scripts only exist in OF/TF2C (stock clients play the stock ones such as
 * Taunt.Soldier* themselves). roles.cfg "taunt_events":
 * "<seq>=<seconds>:snd:<wav>|<seconds>:fx:<particle>:<attachment>;<seq>=..."
 * (seconds = event cycle x sequence length).
 */
void ScheduleTauntEvents(int client, const char[] sequence, int prop)
{
	int role = TF2CC_GetRole(client);
	char map[2048];
	if (role == TF2CC_ROLE_NONE || !TF2CC_GetRoleString(role, "taunt_events", map, sizeof(map)) || !map[0])
		return;
	char seqs[16][512];
	int n = ExplodeString(map, ";", seqs, sizeof(seqs), sizeof(seqs[]));
	for (int i = 0; i < n; i++)
	{
		TrimString(seqs[i]);
		int eq = FindCharInString(seqs[i], '=');
		if (eq <= 0)
			continue;
		seqs[i][eq] = '\0';
		if (!StrEqual(seqs[i], sequence, false))
			continue;
		char evs[16][160];
		int m = ExplodeString(seqs[i][eq + 1], "|", evs, sizeof(evs), sizeof(evs[]));
		for (int e = 0; e < m; e++)
		{
			char p[4][128];
			if (ExplodeString(evs[e], ":", p, sizeof(p), sizeof(p[])) < 3)
				continue;
			DataPack dp;
			CreateDataTimer(StringToFloat(p[0]), Timer_TauntEvent, dp, TIMER_FLAG_NO_MAPCHANGE);
			dp.WriteCell(GetClientUserId(client));
			dp.WriteCell(EntIndexToEntRef(prop));
			dp.WriteString(p[1]);
			dp.WriteString(p[2]);
			dp.WriteString(p[3]);
		}
	}
}

public Action Timer_TauntEvent(Handle timer, DataPack dp)
{
	dp.Reset();
	int client = GetClientOfUserId(dp.ReadCell());
	int prop = EntRefToEntIndex(dp.ReadCell());
	char kind[8], a[128], b[64];
	dp.ReadString(kind, sizeof(kind));
	dp.ReadString(a, sizeof(a));
	dp.ReadString(b, sizeof(b));
	if (!client || prop <= 0 || EntRefToEntIndex(g_iProp[client]) != prop)
		return Plugin_Stop;
	if (StrEqual(kind, "snd"))
	{
		PrecacheSound(a, true);
		EmitSoundToAll(a, prop, SNDCHAN_AUTO, SNDLEVEL_NORMAL);
	}
	else if (StrEqual(kind, "fx"))
	{
		int fx = CreateEntityByName("info_particle_system");
		if (fx != -1)
		{
			float pos[3];
			GetEntPropVector(prop, Prop_Data, "m_vecAbsOrigin", pos);
			TeleportEntity(fx, pos, NULL_VECTOR, NULL_VECTOR);
			DispatchKeyValue(fx, "effect_name", a);
			DispatchSpawn(fx);
			SetVariantString("!activator");
			AcceptEntityInput(fx, "SetParent", prop);
			if (b[0])
			{
				SetVariantString(b);
				AcceptEntityInput(fx, "SetParentAttachment");
			}
			ActivateEntity(fx);
			AcceptEntityInput(fx, "Start");
			SetVariantString("OnUser1 !self:Kill::3:1");
			AcceptEntityInput(fx, "AddOutput");
			AcceptEntityInput(fx, "FireUser1");
		}
	}
	return Plugin_Stop;
}

/** PlayerAnimEvent temp entity (DT_TEPlayerAnimEvent) to every client. */
void SendAnimEvent(int client, int event, int data)
{
	TE_Start("PlayerAnimEvent");
	TE_WriteNum("m_hPlayer", EntIndexToEHandle(client));
	TE_WriteNum("m_iEvent", event);
	TE_WriteNum("m_nData", data);
	TE_SendToAll();
}

/** CBaseHandle value of an edict (serial << 12 | index), as networked EHANDLEs are. */
int EntIndexToEHandle(int entity)
{
	return EntIndexToEntRef(entity) & ~(1 << 31);
}

public Action Cmd_TauntState(int client, int args)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || TF2CC_GetRole(i) == TF2CC_ROLE_NONE)
			continue;
		ReplyToCommand(client, "%N: taunting=%d prop=%d player=%d timer=%d movetype=%d next=%.1f (now %.1f)", i, g_bTaunting[i],
			EntRefToEntIndex(g_iProp[i]), g_bPlayerMode[i], g_hEndTimer[i] != null, view_as<int>(GetEntityMoveType(i)), g_flNextTaunt[i], GetGameTime());
	}
	return Plugin_Handled;
}
