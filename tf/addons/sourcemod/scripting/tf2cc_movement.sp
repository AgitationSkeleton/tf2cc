/**
 * tf2cc_movement - Mercenary autojump/bunnyhop, optional for every class, plus
 * the single authoritative "successful jump" event and jump vocals.
 *
 * Parity notes (Open Fortress 09-25-24, shared/tf/tf_gamemovement.cpp):
 *  - of_bunnyhop -1 (default) = Mercenary only; holding jump re-jumps on landing
 *    by ignoring the "jump must be released" latch (CheckJumpButton).
 *  - The speed cap is PreventBunnyJumping(): 1.2 x maxspeed. Stock TF2 has the
 *    identical function and factor, so the cap needs no server code.
 *  - Air acceleration in OF's default movement mode uses sv_airaccelerate, the
 *    same as stock TF2; nothing to emulate.
 *  - Jump vocal: class "jump_sound", 0.5 s gate, plays for everyone.
 * Server-side autohop works by clearing IN_JUMP from m_nOldButtons before
 * the game processes movement. The client does not predict this, so a hop can
 * show a small prediction correction; this is inherent to server-only bhop.
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <tf2>
#include <tf2_stocks>
#include <tf2cc>

native bool TF2CC_ClientHasSpecial(int client, const char[] special);
native bool CM_IsActive(int client);   // tf2cc fork of Classic Movement (src/compat)

public Plugin myinfo =
{
	name = "TF2CC Movement",
	author = "tf2cc-rework",
	description = "Autojump/bunnyhop and jump vocals for custom roles (and optionally all classes)",
	version = TF2CC_VERSION,
	url = ""
};

#define CONFIG_MOVEMENT "configs/tf2cc/movement.cfg"
#define MAX_JUMP_SOUNDS 8

ConVar g_cvEnabled;
ConVar g_cvAllClasses;
ConVar g_cvStockClassMask;
ConVar g_cvJumpGate;

bool g_bWasOnGround[MAXPLAYERS + 1];
bool g_bHeldJump[MAXPLAYERS + 1];
bool g_bAutoHopped[MAXPLAYERS + 1];
float g_flNextJumpSound[MAXPLAYERS + 1];

// role key -> ArrayList of sound paths; role key -> autohop flag
StringMap g_RoleSounds;
StringMap g_RoleAutohop;
StringMap g_RoleSoundVolume;

GlobalForward g_fwdJumped;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_fwdJumped = new GlobalForward("TF2CC_OnPlayerJumped", ET_Ignore, Param_Cell, Param_Cell);
	MarkNativeAsOptional("TF2CC_ClientHasSpecial");
	MarkNativeAsOptional("CM_IsActive");
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvEnabled = CreateConVar("tf2cc_movement_enabled", "1", "Enable tf2cc movement features.", _, true, 0.0, true, 1.0);
	g_cvAllClasses = CreateConVar("tf2cc_autohop_all", "0", "Give autojump/bunnyhop to every class (OF of_bunnyhop 1).", _, true, 0.0, true, 1.0);
	g_cvStockClassMask = CreateConVar("tf2cc_autohop_stock_classes", "", "Comma list of stock classes that get autohop (e.g. \"scout,soldier\"); ignored when tf2cc_autohop_all is 1.");
	g_cvJumpGate = CreateConVar("tf2cc_jump_sound_gate", "0.5", "Minimum seconds between jump vocals (OF m_flJumpSoundDelay).");
	AutoExecConfig(true, "tf2cc_movement");

	RegAdminCmd("sm_tf2cc_movement_reload", Cmd_Reload, ADMFLAG_CONFIG, "Reload movement.cfg.");
	LoadMovementConfig();
}

public void OnMapStart()
{
	PrecacheJumpSounds();
}

public void OnClientPutInServer(int client)
{
	g_bWasOnGround[client] = false;
	g_bHeldJump[client] = false;
	g_bAutoHopped[client] = false;
	g_flNextJumpSound[client] = 0.0;
}

public Action Cmd_Reload(int client, int args)
{
	LoadMovementConfig();
	PrecacheJumpSounds();
	ReplyToCommand(client, "[TF2CC] movement.cfg reloaded.");
	return Plugin_Handled;
}

void LoadMovementConfig()
{
	if (g_RoleSounds != null)
	{
		StringMapSnapshot snap = g_RoleSounds.Snapshot();
		char key[64];
		for (int i = 0; i < snap.Length; i++)
		{
			snap.GetKey(i, key, sizeof(key));
			ArrayList list;
			g_RoleSounds.GetValue(key, list);
			delete list;
		}
		delete snap;
	}
	delete g_RoleSounds;
	delete g_RoleAutohop;
	delete g_RoleSoundVolume;
	g_RoleSounds = new StringMap();
	g_RoleAutohop = new StringMap();
	g_RoleSoundVolume = new StringMap();

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), CONFIG_MOVEMENT);
	KeyValues kv = new KeyValues("tf2cc_movement");
	if (!kv.ImportFromFile(path))
	{
		LogError("tf2cc_movement: cannot read %s", path);
		delete kv;
		return;
	}
	if (kv.GotoFirstSubKey())
	{
		char key[64];
		do
		{
			// Section name is a role key or a stock class name.
			kv.GetSectionName(key, sizeof(key));
			g_RoleAutohop.SetValue(key, kv.GetNum("autohop", 0) != 0);
			g_RoleSoundVolume.SetValue(key, kv.GetFloat("jump_volume", 0.6));
			ArrayList list = new ArrayList(PLATFORM_MAX_PATH);
			if (kv.JumpToKey("jump_sounds"))
			{
				if (kv.GotoFirstSubKey(false))
				{
					char snd[PLATFORM_MAX_PATH];
					do
					{
						kv.GetString(NULL_STRING, snd, sizeof(snd));
						if (snd[0])
							list.PushString(snd);
					}
					while (kv.GotoNextKey(false));
					kv.GoBack();
				}
				kv.GoBack();
			}
			g_RoleSounds.SetValue(key, list);
		}
		while (kv.GotoNextKey());
	}
	delete kv;
}

void PrecacheJumpSounds()
{
	if (g_RoleSounds == null)
		return;
	StringMapSnapshot snap = g_RoleSounds.Snapshot();
	char key[64], snd[PLATFORM_MAX_PATH];
	for (int i = 0; i < snap.Length; i++)
	{
		snap.GetKey(i, key, sizeof(key));
		ArrayList list;
		g_RoleSounds.GetValue(key, list);
		for (int j = 0; j < list.Length; j++)
		{
			list.GetString(j, snd, sizeof(snd));
			PrecacheSound(snd, true);
		}
	}
	delete snap;
}

/** Config key for this client: role key, else stock class name. */
bool ClientKey(int client, char[] key, int maxlen)
{
	int role = TF2CC_GetRole(client);
	if (role != TF2CC_ROLE_NONE)
	{
		TF2CC_GetRoleKey(role, key, maxlen);
		return true;
	}
	static const char names[][] = { "", "scout", "sniper", "soldier", "demoman", "medic", "heavy", "pyro", "spy", "engineer" };
	int cls = view_as<int>(TF2_GetPlayerClass(client));
	if (cls < 1 || cls > 9)
		return false;
	strcopy(key, maxlen, names[cls]);
	return true;
}

bool HasAutohop(int client)
{
	// The Classic Movement fork owns jumping for the players in its cm_scope.
	if (LibraryExists("classicmovement") && CM_IsActive(client))
		return false;
	if (TF2CC_GetRole(client) != TF2CC_ROLE_NONE && LibraryExists("tf2cc_weapons") && TF2CC_ClientHasSpecial(client, "hoarder"))
		return false; // MarxVee Hoarder's Stash: too heavy to bunnyhop
	if (g_cvAllClasses.BoolValue)
		return true;
	char key[64];
	if (!ClientKey(client, key, sizeof(key)))
		return false;
	bool on;
	if (g_RoleAutohop.GetValue(key, on) && on)
		return true;
	if (TF2CC_GetRole(client) == TF2CC_ROLE_NONE)
	{
		char list[256];
		g_cvStockClassMask.GetString(list, sizeof(list));
		if (list[0] && StrContains(list, key, false) != -1)
			return true;
	}
	return false;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
	if (!g_cvEnabled.BoolValue || !IsPlayerAlive(client))
		return Plugin_Continue;

	bool onGround = (GetEntityFlags(client) & FL_ONGROUND) != 0;
	g_bWasOnGround[client] = onGround;
	g_bAutoHopped[client] = false;

	if ((buttons & IN_JUMP) && onGround && HasAutohop(client)
		&& GetEntityMoveType(client) == MOVETYPE_WALK && GetEntProp(client, Prop_Data, "m_nWaterLevel") < 2
		&& !TF2_IsPlayerInCondition(client, TFCond_Taunting))
	{
		int old = GetEntProp(client, Prop_Data, "m_nOldButtons");
		if (old & IN_JUMP)
		{
			SetEntProp(client, Prop_Data, "m_nOldButtons", old & ~IN_JUMP);
			g_bAutoHopped[client] = true;
		}
	}
	return Plugin_Continue;
}

public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3], int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
	if (!IsClientInGame(client) || !IsPlayerAlive(client))
		return;

	bool onGround = (GetEntityFlags(client) & FL_ONGROUND) != 0;
	if (g_bWasOnGround[client] && !onGround && (buttons & IN_JUMP))
	{
		float v[3];
		GetEntPropVector(client, Prop_Data, "m_vecVelocity", v);
		if (v[2] > 100.0)
			OnJumped(client, g_bAutoHopped[client]);
	}
	g_bHeldJump[client] = (buttons & IN_JUMP) != 0;
}

void OnJumped(int client, bool autoHop)
{
	Call_StartForward(g_fwdJumped);
	Call_PushCell(client);
	Call_PushCell(autoHop);
	Call_Finish();

	float now = GetGameTime();
	if (now < g_flNextJumpSound[client])
		return;
	g_flNextJumpSound[client] = now + g_cvJumpGate.FloatValue;

	char key[64];
	if (!ClientKey(client, key, sizeof(key)))
		return;
	ArrayList list;
	if (!g_RoleSounds.GetValue(key, list) || list.Length == 0)
		return;
	char snd[PLATFORM_MAX_PATH];
	list.GetString(GetRandomInt(0, list.Length - 1), snd, sizeof(snd));
	float volume = 0.6;
	g_RoleSoundVolume.GetValue(key, volume);
	// OF: SNDLVL 95, CHAN_NONE. Spies disguised as a role are not handled here
	// because stock spies cannot disguise as class 10.
	EmitSoundToAll(snd, client, SNDCHAN_AUTO, SNDLEVEL_SCREAMING, SND_NOFLAGS, volume);
}
