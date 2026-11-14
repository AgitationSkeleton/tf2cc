/**
 * tf2cc_core - role coordinator for Civilian / Mercenary on stock class 10.
 *
 * Owns: role selection (menu, !class, joinclass random), the class-10 spawn
 * transition, client-safety presentation, model/health/speed, and lifecycle
 * forwards for feature modules.
 *
 * Design rules (see docs/ARCHITECTURE.md):
 *  - The network class only ever changes through the game's own ForceRespawn
 *    (desired class 10 is injected for the duration of that one call).
 *  - Clients never see class 10 in m_iDesiredPlayerClass or the player resource,
 *    which are the inputs of the stock loadout-panel and scoreboard OOB reads.
 *  - No per-action or per-frame class spoofing.
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2>
#include <tf2_stocks>
#include <dhooks>
#undef REQUIRE_PLUGIN
#include <tf2attributes>
#define REQUIRE_PLUGIN
#include <tf2cc>

public Plugin myinfo =
{
	name = "TF2CC Core",
	author = "tf2cc-rework",
	description = "Civilian / Mercenary roles on stock TF2 class 10",
	version = TF2CC_VERSION,
	url = ""
};

#define CONFIG_ROLES "configs/tf2cc/roles.cfg"
#define LOG_FILE     "logs/tf2cc.log"
#define CONFIG_DOWNLOADS "configs/tf2cc/downloads.txt"

enum struct RoleDef
{
	char key[TF2CC_ROLE_KEY_LEN];
	char name[64];
	char desc[256];
	char model[PLATFORM_MAX_PATH];
	bool useClassAnims;
	bool fallDamage;
	int health;
	float speed;
	int scoreboardClass;     // value shown in the player resource instead of 10
	float randomWeight;
	int teamLimit;           // 0 = unlimited, -1 = disabled
	bool allowBots;
	char adminFlags[32];
	char denyMapPrefixes[256];
}

ArrayList g_Roles;
KeyValues g_kvRoles;

int g_iRole[MAXPLAYERS + 1] = { TF2CC_ROLE_NONE, ... };        // active role
int g_iPending[MAXPLAYERS + 1] = { TF2CC_ROLE_NONE, ... };     // selected role for next spawns
bool g_bRandomEachLife[MAXPLAYERS + 1];
int g_iSafeClass[MAXPLAYERS + 1];                              // stock class shown as desired
bool g_bInForceRespawn[MAXPLAYERS + 1];
int g_iSpawnSerial[MAXPLAYERS + 1];
bool g_bInRespawnRoom[MAXPLAYERS + 1];
bool g_bInternalJoin[MAXPLAYERS + 1];
bool g_bJustRolled[MAXPLAYERS + 1];
bool g_bFixedClassBot[MAXPLAYERS + 1];
bool g_bBotAddHasClass;
int g_iBotAddRole = TF2CC_ROLE_NONE;
ConVar g_cvBotGuard;
bool g_bReevalSuppressed;
int g_iReevalOriginal = 1;
ConVar g_cvBotKeepClass;
int g_iRespawnRoomTouches[MAXPLAYERS + 1];
float g_flLastSelect[MAXPLAYERS + 1];

ConVar g_cvEnabled;
ConVar g_cvRandomMenu;
ConVar g_cvBaseHealth;
ConVar g_cvBaseSpeed;
ConVar g_cvDebug;
ConVar g_cvNoFallScope;
ConVar g_cvSafeClass;
ConVar g_cvSanitizeAll;
ConVar g_cvDownloads;
ConVar g_cvBotChance;
ConVar g_cvMvmUpgrades;
ConVar g_cvMvmDefenders;
ConVar g_cvHudModelGuard;
bool g_bHudPlayermodel[MAXPLAYERS + 1];
ConVar g_cvBossPrefixes;
ConVar g_cvBossTeam;
ConVar g_cvVipEnabled;
ConVar g_cvVipPrefixes;
ConVar g_cvVipRoles;
ConVar g_cvVipTeam;

DynamicHook g_hForceRespawn;
bool g_bForceRespawnHook;
bool g_bTF2Attributes;

GlobalForward g_fwdSpawned;
GlobalForward g_fwdCleared;
GlobalForward g_fwdVoicePre;
GlobalForward g_fwdVoice;

char g_sLogPath[PLATFORM_MAX_PATH];

static const char g_sStockClassNames[][] =
{
	"", "scout", "sniper", "soldier", "demoman", "medic", "heavyweapons", "pyro", "spy", "engineer"
};
static const char g_sStockClassDisplay[][] =
{
	"", "Scout", "Sniper", "Soldier", "Demoman", "Medic", "Heavy", "Pyro", "Spy", "Engineer"
};

/* ------------------------------------------------------------------------- */
/* Plugin lifecycle                                                          */
/* ------------------------------------------------------------------------- */

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_TF2)
	{
		strcopy(error, err_max, "tf2cc only supports Team Fortress 2");
		return APLRes_Failure;
	}

	MarkNativeAsOptional("FF2_IsFF2Enabled");
	MarkNativeAsOptional("FF2_GetBossIndex");
	MarkNativeAsOptional("FF2R_GetGamemodeType");
	MarkNativeAsOptional("VSH_IsSaxtonHaleModeEnabled");
	MarkNativeAsOptional("VSH_GetSaxtonHaleUserId");
	CreateNative("TF2CC_GetRole", Native_GetRole);
	CreateNative("TF2CC_GetPendingRole", Native_GetPendingRole);
	CreateNative("TF2CC_GetRoleCount", Native_GetRoleCount);
	CreateNative("TF2CC_FindRole", Native_FindRole);
	CreateNative("TF2CC_GetRoleKey", Native_GetRoleKey);
	CreateNative("TF2CC_GetRoleName", Native_GetRoleName);
	CreateNative("TF2CC_GetRoleString", Native_GetRoleString);
	CreateNative("TF2CC_SetRole", Native_SetRole);
	CreateNative("TF2CC_IsRoleEligible", Native_IsRoleEligible);

	g_fwdSpawned = new GlobalForward("TF2CC_OnRoleSpawned", ET_Ignore, Param_Cell, Param_Cell);
	g_fwdCleared = new GlobalForward("TF2CC_OnRoleCleared", ET_Ignore, Param_Cell, Param_Cell);
	g_fwdVoicePre = new GlobalForward("TF2CC_OnVoiceMenuPre", ET_Hook, Param_Cell, Param_Cell, Param_Cell);
	g_fwdVoice = new GlobalForward("TF2CC_OnVoiceMenu", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);

	RegPluginLibrary(TF2CC_LIBRARY);
	return APLRes_Success;
}

public void OnPluginStart()
{
	BuildPath(Path_SM, g_sLogPath, sizeof(g_sLogPath), LOG_FILE);

	g_cvEnabled = CreateConVar("tf2cc_enabled", "1", "Enable custom roles.", _, true, 0.0, true, 1.0);
	g_cvRandomMenu = CreateConVar("tf2cc_random_menu", "1", "Intercept the class menu's Random choice and show the role menu instead.", _, true, 0.0, true, 1.0);
	g_cvBaseHealth = CreateConVar("tf2cc_class10_base_health", "200", "Stock class-10 max health (retail scripts/playerclasses/civilian.ctx).");
	g_cvBaseSpeed = CreateConVar("tf2cc_class10_base_speed", "250", "Stock class-10 max speed (retail scripts/playerclasses/civilian.ctx).");
	g_cvSafeClass = CreateConVar("tf2cc_safe_desired_class", "1", "Stock class (1-9) networked as the desired class for role players who never played a stock class. Keeps the loadout panel off class 10.", _, true, 1.0, true, 9.0);
	g_cvSanitizeAll = CreateConVar("tf2cc_sanitize_all_class10", "1", "Also hide class 10 in the player resource for non-role players (e.g. other plugins).", _, true, 0.0, true, 1.0);
	g_cvHudModelGuard = CreateConVar("tf2cc_hud_playermodel_guard", "1", "Refuse roles to players with cl_hud_show_playermodel 1 (the retail client crashes drawing it for class 10).", _, true, 0.0, true, 1.0);
	CreateTimer(5.0, Timer_QueryHudModel, _, TIMER_REPEAT);
	g_cvMvmDefenders = CreateConVar("tf2cc_mvm_allow_defenders", "0", "Mann vs. Machine: allow roles on the RED defender team (the BLU invader/robot team is never eligible).", _, true, 0.0, true, 1.0);
	g_cvVipEnabled = CreateConVar("tf2cc_vip_guard", "1", "Hunted/VIP/escort maps: deny tf2cc_vip_roles on the VIP team so the map's own Civilian/VIP stays unique.", _, true, 0.0, true, 1.0);
	g_cvVipPrefixes = CreateConVar("tf2cc_vip_map_prefixes", "vip_,hunted_,escort_", "Map prefixes treated as hunted/VIP/escort maps.");
	g_cvVipRoles = CreateConVar("tf2cc_vip_roles", "civilian", "Comma list of role keys denied on the VIP team on those maps.");
	g_cvVipTeam = CreateConVar("tf2cc_vip_team", "0", "VIP team when it cannot be detected (2 = RED, 3 = BLU, 0 = deny the roles on both teams).");
	g_cvBossPrefixes = CreateConVar("tf2cc_boss_map_prefixes", "vsh_,ff2_,saxton_", "Map prefixes treated as boss modes (Versus Saxton Hale / Freak Fortress). FF2, FF2R and SourceMod VSH are also detected through their natives.");
	g_cvBossTeam = CreateConVar("tf2cc_boss_team", "3", "Team that hosts the boss in boss modes (3 = BLU, 2 = RED, 0 = none): never eligible for roles. Bosses reported by FF2/VSH natives are always excluded.");
	g_cvMvmUpgrades = CreateConVar("tf2cc_mvm_upgrades", "1", "Allow role players to buy MvM upgrades at (VScript) upgrade stations (player upgrades only; class-10 weapons cannot take item upgrades).", _, true, 0.0, true, 1.0);
	g_cvBotChance = CreateConVar("tf2cc_bot_role_chance", "0.2", "Chance per life that a bot (with allow_bots roles) spawns as a random role instead of its own class pick.", _, true, 0.0, true, 1.0);
	g_cvDownloads = CreateConVar("tf2cc_downloads", "1", "Add every file in configs/tf2cc/downloads.txt (generated asset manifest) to the downloads table.", _, true, 0.0, true, 1.0);
	g_cvNoFallScope = CreateConVar("tf2cc_no_fall_damage", "", "Extra players without fall damage (beyond roles.cfg fall_damage 0): comma list of all, roles, role keys, class names.");
	g_cvDebug = CreateConVar("tf2cc_debug", "0", "Verbose logging to logs/tf2cc.log.", _, true, 0.0, true, 1.0);
	AutoExecConfig(true, "tf2cc_core");

	RegConsoleCmd("sm_class", Cmd_Class, "Open the custom class menu.");
	RegConsoleCmd("sm_classes", Cmd_Class, "Open the custom class menu.");
	RegConsoleCmd("sm_merc", Cmd_Merc, "Become the Mercenary.");
	RegConsoleCmd("sm_mercenary", Cmd_Merc, "Become the Mercenary.");
	// No "sm_civ": the stock-pose plugin civilian.smx on every server owns it.
	RegConsoleCmd("sm_civilian", Cmd_Civ, "Become the Civilian.");
	RegAdminCmd("sm_tf2cc_reload", Cmd_Reload, ADMFLAG_CONFIG, "Reload roles.cfg.");
	RegAdminCmd("sm_tf2cc_status", Cmd_Status, ADMFLAG_GENERIC, "Show role state of every player.");
	RegAdminCmd("sm_tf2cc_setrole", Cmd_SetRoleAdmin, ADMFLAG_SLAY, "sm_tf2cc_setrole <target> <role|none>");

	LoadTranslations("common.phrases");
	AddCommandListener(Listener_JoinClass, "joinclass");
	AddCommandListener(Listener_JoinClass, "join_class");
	AddCommandListener(Listener_VoiceMenu, "voicemenu");
	AddCommandListener(Listener_BotAdd, "tf_bot_add");
	g_cvBotGuard = CreateConVar("tf2cc_bot_reevaluate_guard", "1", "While role bots exist, temporarily set tf_bot_reevaluate_class_in_spawnroom 0 (restored afterwards) so they don't suicide-loop in spawn.", _, true, 0.0, true, 1.0);
	CreateTimer(1.0, Timer_BotReevaluateGuard, _, TIMER_REPEAT);
	g_cvBotKeepClass = FindConVar("tf_bot_keep_class_after_death");

	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("post_inventory_application", Event_Inventory);
	HookEvent("player_team", Event_PlayerTeam);

	SetupForceRespawnHook();
	LoadRoles();
	HookPlayerResource();
	HookRespawnRooms();

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
			OnClientPutInServer(client);
	}
}

public void OnAllPluginsLoaded()
{
	g_bTF2Attributes = LibraryExists("tf2attributes");
}

public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "tf2attributes"))
		g_bTF2Attributes = true;
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "tf2attributes"))
		g_bTF2Attributes = false;
}

public void OnPluginEnd()
{
	if (g_bReevalSuppressed)
	{
		ConVar cv = FindConVar("tf_bot_reevaluate_class_in_spawnroom");
		if (cv != null)
			cv.SetInt(g_iReevalOriginal);
		g_bReevalSuppressed = false;
	}
	// Return every role player to a stock class through the game's own path.
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client))
			continue;
		if (g_iRole[client] != TF2CC_ROLE_NONE)
		{
			int old = g_iRole[client];
			ClearPresentation(client);
			g_iRole[client] = TF2CC_ROLE_NONE;
			g_iPending[client] = TF2CC_ROLE_NONE;
			FireCleared(client, old);
			SetDesiredClass(client, SafeClass(client));
			if (IsPlayerAlive(client))
				TF2_RespawnPlayer(client);
		}
	}
}

public void OnMapStart()
{
	PrecacheRoleModels();
	HookRespawnRooms();
	HookPlayerResource();
}

void HookPlayerResource()
{
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "tf_player_manager")) != -1)
	{
		SDKUnhook(ent, SDKHook_ThinkPost, Hook_PlayerResourceThinkPost);
		SDKHook(ent, SDKHook_ThinkPost, Hook_PlayerResourceThinkPost);
	}
}

public void OnConfigsExecuted()
{
	PrecacheRoleModels();
	if (g_cvDownloads.BoolValue)
		AddManifestDownloads();
}

/** One generated manifest (tools/stage.py) owns client downloads for the roles. */
void AddManifestDownloads()
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), CONFIG_DOWNLOADS);
	File f = OpenFile(path, "r");
	if (f == null)
	{
		LogError("tf2cc: %s missing; clients will not download role assets", path);
		return;
	}
	char line[PLATFORM_MAX_PATH];
	int added = 0, missing = 0;
	while (f.ReadLine(line, sizeof(line)))
	{
		TrimString(line);
		if (line[0] == '\0' || line[0] == '/' || line[0] == '#')
			continue;
		if (!FileExists(line, true))
		{
			missing++;
			continue;
		}
		AddFileToDownloadsTable(line);
		added++;
	}
	delete f;
	DebugLog("downloads: %d added, %d missing", added, missing);
	if (missing)
		LogError("tf2cc: %d manifest file(s) missing on this server", missing);
}

public void OnClientPutInServer(int client)
{
	g_bHudPlayermodel[client] = false;
	QueryHudModel(client);
	ResetClient(client);
	SDKHook(client, SDKHook_OnTakeDamage, Hook_FallDamage);
	// Bots created by "tf_bot_add ... <class>" (or a plugin issuing it) keep that class.
	g_bFixedClassBot[client] = IsFakeClient(client) && (g_bBotAddHasClass || g_iBotAddRole != TF2CC_ROLE_NONE);
	if (IsFakeClient(client) && g_iBotAddRole != TF2CC_ROLE_NONE)
		g_iPending[client] = g_iBotAddRole; // pinned role; RollBot skips fixed bots
	if (g_bForceRespawnHook)
	{
		g_hForceRespawn.HookEntity(Hook_Pre, client, Hook_ForceRespawnPre);
		g_hForceRespawn.HookEntity(Hook_Post, client, Hook_ForceRespawnPost);
	}
}

public void OnClientDisconnect(int client)
{
	if (g_iRole[client] != TF2CC_ROLE_NONE)
	{
		int old = g_iRole[client];
		g_iRole[client] = TF2CC_ROLE_NONE;
		FireCleared(client, old);
	}
	ResetClient(client);
}

void ResetClient(int client)
{
	g_iRole[client] = TF2CC_ROLE_NONE;
	g_iPending[client] = TF2CC_ROLE_NONE;
	g_bRandomEachLife[client] = false;
	g_iSafeClass[client] = 0;
	g_bInForceRespawn[client] = false;
	g_iSpawnSerial[client] = 0;
	g_bInRespawnRoom[client] = false;
	g_iRespawnRoomTouches[client] = 0;
	g_flLastSelect[client] = 0.0;
}

/* ------------------------------------------------------------------------- */
/* Config                                                                    */
/* ------------------------------------------------------------------------- */

void LoadRoles()
{
	delete g_Roles;
	delete g_kvRoles;
	g_Roles = new ArrayList(sizeof(RoleDef));

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), CONFIG_ROLES);
	g_kvRoles = new KeyValues("tf2cc_roles");
	if (!g_kvRoles.ImportFromFile(path))
	{
		LogError("tf2cc: cannot read %s - no roles available", path);
		return;
	}

	if (!g_kvRoles.GotoFirstSubKey())
		return;

	do
	{
		RoleDef role;
		g_kvRoles.GetSectionName(role.key, sizeof(role.key));
		if (g_kvRoles.GetNum("enabled", 1) == 0)
			continue;
		g_kvRoles.GetString("name", role.name, sizeof(role.name), role.key);
		g_kvRoles.GetString("description", role.desc, sizeof(role.desc));
		g_kvRoles.GetString("model", role.model, sizeof(role.model));
		// 1 = normal player animation (CTFPlayerAnimState) on the model's own ACT_MP_*
		// sequences. 0 stops player animation entirely (ShouldUpdateAnimState) - prop use only.
		role.useClassAnims = g_kvRoles.GetNum("use_class_animations", 1) != 0;
		role.fallDamage = g_kvRoles.GetNum("fall_damage", 1) != 0;
		role.health = g_kvRoles.GetNum("health", g_cvBaseHealth.IntValue);
		role.speed = g_kvRoles.GetFloat("speed", g_cvBaseSpeed.FloatValue);
		role.scoreboardClass = g_kvRoles.GetNum("scoreboard_class", 0);
		if (role.scoreboardClass < 0 || role.scoreboardClass > 9)
			role.scoreboardClass = 0;
		role.randomWeight = g_kvRoles.GetFloat("random_weight", 1.0);
		role.teamLimit = g_kvRoles.GetNum("team_limit", 0);
		role.allowBots = g_kvRoles.GetNum("allow_bots", 0) != 0;
		g_kvRoles.GetString("admin_flags", role.adminFlags, sizeof(role.adminFlags));
		g_kvRoles.GetString("deny_map_prefixes", role.denyMapPrefixes, sizeof(role.denyMapPrefixes), "mvm_");

		if (g_Roles.Length >= TF2CC_MAX_ROLES)
		{
			LogError("tf2cc: more than %d roles configured; ignoring '%s'", TF2CC_MAX_ROLES, role.key);
			continue;
		}
		g_Roles.PushArray(role);
	}
	while (g_kvRoles.GotoNextKey());
	g_kvRoles.Rewind();

	DebugLog("loaded %d role(s) from %s", g_Roles.Length, path);
}

void PrecacheRoleModels()
{
	if (g_Roles == null)
		return;
	RoleDef role;
	for (int i = 0; i < g_Roles.Length; i++)
	{
		g_Roles.GetArray(i, role);
		if (role.model[0] == '\0')
			continue;
		if (!FileExists(role.model, true))
		{
			LogError("tf2cc: role '%s' model missing on server: %s", role.key, role.model);
			continue;
		}
		PrecacheModel(role.model, true);
	}
}

bool GetRoleDef(int index, RoleDef role)
{
	if (g_Roles == null || index < 0 || index >= g_Roles.Length)
		return false;
	g_Roles.GetArray(index, role);
	return true;
}

int FindRoleByKey(const char[] key)
{
	if (g_Roles == null)
		return TF2CC_ROLE_NONE;
	RoleDef role;
	for (int i = 0; i < g_Roles.Length; i++)
	{
		g_Roles.GetArray(i, role);
		if (StrEqual(role.key, key, false))
			return i;
	}
	return TF2CC_ROLE_NONE;
}

/* ------------------------------------------------------------------------- */
/* ForceRespawn hook: the only place the network class becomes 10            */
/* ------------------------------------------------------------------------- */

void SetupForceRespawnHook()
{
	// Offset maintained by SourceMod itself (used by TF2_RespawnPlayer).
	GameData gd = new GameData("sm-tf2.games");
	if (gd == null)
	{
		LogError("tf2cc: sm-tf2.games gamedata missing; class-10 transitions use the fallback path");
		return;
	}
	int offset = gd.GetOffset("ForceRespawn");
	delete gd;
	if (offset == -1)
	{
		LogError("tf2cc: ForceRespawn offset missing for this platform; using fallback path");
		return;
	}
	g_hForceRespawn = new DynamicHook(offset, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity);
	g_bForceRespawnHook = (g_hForceRespawn != null);
}

public MRESReturn Hook_ForceRespawnPre(int client)
{
	if (!g_cvEnabled.BoolValue || !IsClientInGame(client))
		return MRES_Ignored;

	if (g_bRandomEachLife[client] && !g_bJustRolled[client])
		RollRandom(client);
	else if (IsFakeClient(client) && !g_bJustRolled[client])
		RollBot(client);
	g_bJustRolled[client] = false;

	int want = g_iPending[client];
	if (want == TF2CC_ROLE_NONE)
		return MRES_Ignored;

	if (!IsRoleEligible(client, want, true))
	{
		PrintToChat(client, "\x04[TF2CC]\x01 That class is no longer available; spawning as %s.", g_sStockClassDisplay[SafeClass(client)]);
		g_iPending[client] = TF2CC_ROLE_NONE;
		SetDesiredClass(client, SafeClass(client));
		return MRES_Ignored;
	}

	g_bInForceRespawn[client] = true;
	SetDesiredClass(client, TF2CC_CLASS_INDEX);
	return MRES_Ignored;
}

public MRESReturn Hook_ForceRespawnPost(int client)
{
	if (g_bInForceRespawn[client])
	{
		g_bInForceRespawn[client] = false;
		// The class is already initialised; hide class 10 from the client again.
		if (IsClientInGame(client))
			SetDesiredClass(client, SafeClass(client));
	}
	return MRES_Ignored;
}

/* ------------------------------------------------------------------------- */
/* Spawn handling                                                            */
/* ------------------------------------------------------------------------- */

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!TF2CC_IsValidClient(client))
		return;

	int cls = view_as<int>(TF2_GetPlayerClass(client));
	if (cls >= 1 && cls <= 9)
	{
		g_iSafeClass[client] = cls;
		if (g_iRole[client] != TF2CC_ROLE_NONE)
		{
			int old = g_iRole[client];
			g_iRole[client] = TF2CC_ROLE_NONE;
			ClearPresentation(client);
			FireCleared(client, old);
		}
		else
		{
			// Defensive: never let a stale custom model survive on a stock class.
			ClearPresentationIfOurs(client);
		}

		// Fallback path when the ForceRespawn hook is unavailable: convert now.
		if (!g_bForceRespawnHook && g_iPending[client] != TF2CC_ROLE_NONE && g_cvEnabled.BoolValue)
			FallbackConvert(client);
		return;
	}

	if (cls != TF2CC_CLASS_INDEX)
		return;

	int want = g_iPending[client];
	if (want == TF2CC_ROLE_NONE)
		return; // class 10 owned by something else; leave it alone

	int old = g_iRole[client];
	if (old != TF2CC_ROLE_NONE && old != want)
		FireCleared(client, old);
	g_iRole[client] = want;

	int serial = ++g_iSpawnSerial[client];
	ScheduleFinishRoleSpawn(client, serial);
}

/*
 * Round restarts respawn everyone in one frame, and some map scripts
 * (ctf_2fort_mvm_v4: SetPlayerClass 1..9 + Regenerate per player) create and
 * free several hundred entities in that frame. The engine does not reuse a
 * freed edict immediately, so role setup (presentation, loadout grant) for
 * many role players in the same window pushed the server past 2048 edicts
 * (FATAL ERROR: ED_Alloc: no free edicts). The first few finish next frame as
 * before; the rest of a burst are spread out after the window.
 */
float g_flBurstStart;
int g_iBurstCount;

int BurstSlot()
{
	float now = GetEngineTime();
	if (now - g_flBurstStart > 1.0)
	{
		g_flBurstStart = now;
		g_iBurstCount = 0;
	}
	return ++g_iBurstCount;
}

void ScheduleFinishRoleSpawn(int client, int serial)
{
	int slot = BurstSlot();
	if (slot <= 3)
	{
		DataPack pack = new DataPack();
		pack.WriteCell(GetClientUserId(client));
		pack.WriteCell(serial);
		RequestFrame(Frame_FinishRoleSpawn, pack);
		return;
	}
	DataPack dp;
	CreateDataTimer(0.6 + 0.06 * float(slot - 3), Timer_FinishRoleSpawn, dp, TIMER_FLAG_NO_MAPCHANGE);
	dp.WriteCell(GetClientUserId(client));
	dp.WriteCell(serial);
}

public Action Timer_FinishRoleSpawn(Handle timer, DataPack dp)
{
	dp.Reset();
	int userid = dp.ReadCell();
	FinishRoleSpawn(GetClientOfUserId(userid), dp.ReadCell());
	return Plugin_Stop;
}

public void Frame_FinishRoleSpawn(DataPack pack)
{
	pack.Reset();
	int client = GetClientOfUserId(pack.ReadCell());
	int serial = pack.ReadCell();
	delete pack;
	FinishRoleSpawn(client, serial);
}

void FinishRoleSpawn(int client, int serial)
{
	if (!client || !IsPlayerAlive(client) || serial != g_iSpawnSerial[client])
		return;
	if (TF2_GetPlayerClass(client) != view_as<TFClassType>(TF2CC_CLASS_INDEX))
		return;
	int role = g_iRole[client];
	if (role == TF2CC_ROLE_NONE)
		return;

	ApplyPresentation(client, role);

	Call_StartForward(g_fwdSpawned);
	Call_PushCell(client);
	Call_PushCell(role);
	Call_Finish();

	RoleDef def;
	GetRoleDef(role, def);
	DebugLog("%L spawned as role %s", client, def.key);
}

public void Event_Inventory(Event event, const char[] name, bool dontBroadcast)
{
	// Resupply/regenerate re-runs class setup; re-apply stats (attributes on the
	// player survive, but health is reset to the class-data value).
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!TF2CC_IsValidClient(client) || g_iRole[client] == TF2CC_ROLE_NONE)
		return;
	if (TF2_GetPlayerClass(client) != view_as<TFClassType>(TF2CC_CLASS_INDEX))
		return;
	ApplyStats(client, g_iRole[client], false);
	// VScript MvM maps (ctf_2fort_mvm_v4, trade_minecraft_b38_mvm) cycle
	// SetPlayerClass on first spawn; make sure the role model survives.
	RoleDef def;
	char cur[PLATFORM_MAX_PATH];
	GetEntPropString(client, Prop_Send, "m_iszCustomModel", cur, sizeof(cur));
	if (GetRoleDef(g_iRole[client], def) && def.model[0] && !StrEqual(cur, def.model, false))
		ApplyPresentation(client, g_iRole[client]);
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!TF2CC_IsValidClient(client))
		return;
	int team = event.GetInt("team");
	if (team < 2)
	{
		// Spectator/unassigned: drop the selection so they return to the stock menu flow.
		g_iPending[client] = TF2CC_ROLE_NONE;
		g_bRandomEachLife[client] = false;
	}
}

void FallbackConvert(int client)
{
	// Without the hook we must transition after a stock spawn. This flashes the
	// stock class for one frame and leaves m_iDesiredPlayerClass correct.
	LogError("tf2cc: using fallback class-10 conversion for %L (ForceRespawn hook unavailable)", client);
	TF2_SetPlayerClass(client, view_as<TFClassType>(TF2CC_CLASS_INDEX), false, false);
	SetDesiredClass(client, SafeClass(client));
	TF2_RegeneratePlayer(client);

	int serial = ++g_iSpawnSerial[client];
	g_iRole[client] = g_iPending[client];
	ScheduleFinishRoleSpawn(client, serial);
}

/* ------------------------------------------------------------------------- */
/* Presentation: model, health, speed                                        */
/* ------------------------------------------------------------------------- */

void ApplyPresentation(int client, int role)
{
	RoleDef def;
	if (!GetRoleDef(role, def))
		return;

	if (def.model[0] != '\0' && IsModelPrecached(def.model))
	{
		SetVariantString(def.model);
		AcceptEntityInput(client, "SetCustomModel");
		SetEntProp(client, Prop_Send, "m_bUseClassAnimations", def.useClassAnims ? 1 : 0);
		SetEntProp(client, Prop_Send, "m_bCustomModelRotates", 1);
	}

	ApplyStats(client, role, true);
}

void ApplyStats(int client, int role, bool fillHealth)
{
	RoleDef def;
	if (!GetRoleDef(role, def))
		return;

	float baseSpeed = g_cvBaseSpeed.FloatValue;
	int baseHealth = g_cvBaseHealth.IntValue;

	if (g_bTF2Attributes)
	{
		// Player attributes are networked, so client movement prediction agrees.
		TF2Attrib_SetByName(client, "max health additive penalty", float(def.health - baseHealth));
		if (baseSpeed > 0.0)
			TF2Attrib_SetByName(client, "move speed penalty", def.speed / baseSpeed);
		TF2Attrib_ClearCache(client);
		// Max speed is only recalculated on condition/state changes; nudge it.
		TF2_AddCondition(client, TFCond_SpeedBuffAlly, 0.001);
	}
	else
	{
		SDKUnhook(client, SDKHook_GetMaxHealth, Hook_GetMaxHealth);
		SDKHook(client, SDKHook_GetMaxHealth, Hook_GetMaxHealth);
		SDKUnhook(client, SDKHook_PreThinkPost, Hook_SpeedThink);
		SDKHook(client, SDKHook_PreThinkPost, Hook_SpeedThink);
	}

	if (fillHealth)
		SetEntityHealth(client, def.health);
}

public Action Hook_GetMaxHealth(int client, int &maxHealth)
{
	RoleDef def;
	if (g_iRole[client] == TF2CC_ROLE_NONE || !GetRoleDef(g_iRole[client], def))
		return Plugin_Continue;
	maxHealth = def.health;
	return Plugin_Changed;
}

public void Hook_SpeedThink(int client)
{
	RoleDef def;
	if (g_iRole[client] == TF2CC_ROLE_NONE || !GetRoleDef(g_iRole[client], def))
		return;
	// Only raise/lower the base value; slowdowns (aiming, stun) apply on top in
	// the game's own calculation the next time it runs.
	float cur = GetEntPropFloat(client, Prop_Send, "m_flMaxspeed");
	if (cur > 1.0 && FloatAbs(cur - g_cvBaseSpeed.FloatValue) < 0.5)
		SetEntPropFloat(client, Prop_Send, "m_flMaxspeed", def.speed);
}

void ClearPresentation(int client)
{
	if (!IsClientInGame(client))
		return;
	SetVariantString("");
	AcceptEntityInput(client, "SetCustomModel");
	SetEntProp(client, Prop_Send, "m_bUseClassAnimations", 1);
	if (g_bTF2Attributes)
	{
		TF2Attrib_RemoveByName(client, "max health additive penalty");
		TF2Attrib_RemoveByName(client, "move speed penalty");
		TF2Attrib_ClearCache(client);
	}
	SDKUnhook(client, SDKHook_GetMaxHealth, Hook_GetMaxHealth);
	SDKUnhook(client, SDKHook_PreThinkPost, Hook_SpeedThink);
}

void ClearPresentationIfOurs(int client)
{
	char model[PLATFORM_MAX_PATH];
	GetEntPropString(client, Prop_Send, "m_iszCustomModel", model, sizeof(model));
	if (model[0] == '\0' || g_Roles == null)
		return;
	RoleDef def;
	for (int i = 0; i < g_Roles.Length; i++)
	{
		g_Roles.GetArray(i, def);
		if (StrEqual(def.model, model, false))
		{
			ClearPresentation(client);
			return;
		}
	}
}

void FireCleared(int client, int oldRole)
{
	Call_StartForward(g_fwdCleared);
	Call_PushCell(client);
	Call_PushCell(oldRole);
	Call_Finish();
}

/* ------------------------------------------------------------------------- */
/* Client safety: never expose class 10 to stock client array consumers      */
/* ------------------------------------------------------------------------- */

int SafeClass(int client)
{
	int c = g_iSafeClass[client];
	if (c < 1 || c > 9)
		c = g_cvSafeClass.IntValue;
	return c;
}

void SetDesiredClass(int client, int cls)
{
	SetEntProp(client, Prop_Send, "m_iDesiredPlayerClass", cls);
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (StrEqual(classname, "tf_player_manager"))
		SDKHook(entity, SDKHook_ThinkPost, Hook_PlayerResourceThinkPost);
	else if (StrEqual(classname, "func_respawnroom"))
		SDKHook(entity, SDKHook_SpawnPost, Hook_RespawnRoomSpawned);
}

public void Hook_PlayerResourceThinkPost(int entity)
{
	// tf_clientscoreboard.cpp and tf_teamstatus.cpp index 19-entry icon arrays
	// with (class + 9) for dead players: class 10 reads past the end.
	bool sanitizeAll = g_cvSanitizeAll.BoolValue;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client))
			continue;
		int shown = 0;
		bool rolePlayer = g_iRole[client] != TF2CC_ROLE_NONE;
		if (rolePlayer)
		{
			RoleDef def;
			if (GetRoleDef(g_iRole[client], def))
				shown = def.scoreboardClass;
		}
		else if (!sanitizeAll)
		{
			continue;
		}

		if (GetEntProp(entity, Prop_Send, "m_iPlayerClass", _, client) == TF2CC_CLASS_INDEX)
			SetEntProp(entity, Prop_Send, "m_iPlayerClass", shown, _, client);
		if (GetEntProp(entity, Prop_Send, "m_iPlayerClassWhenKilled", _, client) == TF2CC_CLASS_INDEX)
			SetEntProp(entity, Prop_Send, "m_iPlayerClassWhenKilled", shown, _, client);
	}
}

/* ------------------------------------------------------------------------- */
/* Respawn-room tracking (stock instant-class-change rule)                   */
/* ------------------------------------------------------------------------- */

void HookRespawnRooms()
{
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "func_respawnroom")) != -1)
		Hook_RespawnRoomSpawned(ent);
}

public void Hook_RespawnRoomSpawned(int entity)
{
	SDKUnhook(entity, SDKHook_StartTouchPost, Hook_RoomStartTouch);
	SDKUnhook(entity, SDKHook_EndTouchPost, Hook_RoomEndTouch);
	SDKHook(entity, SDKHook_StartTouchPost, Hook_RoomStartTouch);
	SDKHook(entity, SDKHook_EndTouchPost, Hook_RoomEndTouch);
}

public void Hook_RoomStartTouch(int entity, int other)
{
	if (other < 1 || other > MaxClients || !IsClientInGame(other))
		return;
	int team = GetEntProp(entity, Prop_Send, "m_iTeamNum");
	if (team >= 2 && team != GetClientTeam(other))
		return;
	g_iRespawnRoomTouches[other]++;
	g_bInRespawnRoom[other] = true;
}

public void Hook_RoomEndTouch(int entity, int other)
{
	if (other < 1 || other > MaxClients || !IsClientInGame(other))
		return;
	int team = GetEntProp(entity, Prop_Send, "m_iTeamNum");
	if (team >= 2 && team != GetClientTeam(other))
		return;
	if (--g_iRespawnRoomTouches[other] <= 0)
	{
		g_iRespawnRoomTouches[other] = 0;
		g_bInRespawnRoom[other] = false;
	}
}

bool CanChangeInstantly(int client)
{
	if (!IsPlayerAlive(client))
		return true;
	return g_bInRespawnRoom[client];
}

/* ------------------------------------------------------------------------- */
/* Eligibility & selection                                                   */
/* ------------------------------------------------------------------------- */

bool IsRoleEligible(int client, int role, bool quiet = true, char[] reason = "", int reasonLen = 0)
{
	RoleDef def;
	if (!g_cvEnabled.BoolValue || !GetRoleDef(role, def))
	{
		if (reasonLen) strcopy(reason, reasonLen, "Custom classes are disabled.");
		return false;
	}
	if (IsFakeClient(client) && !def.allowBots)
	{
		if (reasonLen) strcopy(reason, reasonLen, "Bots cannot use this class.");
		return false;
	}
	if (def.teamLimit < 0)
	{
		if (reasonLen) strcopy(reason, reasonLen, "This class is disabled.");
		return false;
	}
	if (GameRules_GetProp("m_bPlayingMannVsMachine"))
	{
		// The invader (BLU robot) team is never touched; defenders only by opt-in.
		if (GetClientTeam(client) == view_as<int>(TFTeam_Blue) || !g_cvMvmDefenders.BoolValue)
		{
			if (reasonLen) strcopy(reason, reasonLen, "Not available in Mann vs. Machine.");
			return false;
		}
	}
	if (VipDenies(client, def.key))
	{
		if (reasonLen) strcopy(reason, reasonLen, "Not available on the VIP team on this map.");
		return false;
	}
	if (IsBossModeClient(client))
	{
		if (reasonLen) strcopy(reason, reasonLen, "Not available on the boss team.");
		return false;
	}

	char map[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));
	GetMapDisplayName(map, map, sizeof(map));
	if (def.denyMapPrefixes[0] != '\0')
	{
		char prefixes[16][32];
		int n = ExplodeString(def.denyMapPrefixes, ",", prefixes, sizeof(prefixes), sizeof(prefixes[]));
		for (int i = 0; i < n; i++)
		{
			TrimString(prefixes[i]);
			if (prefixes[i][0] != '\0' && StrContains(map, prefixes[i], false) == 0)
			{
				if (reasonLen) strcopy(reason, reasonLen, "Not available on this map.");
				return false;
			}
		}
	}

	if (def.adminFlags[0] != '\0')
	{
		int flags = ReadFlagString(def.adminFlags);
		if (flags != 0 && !CheckCommandAccess(client, "tf2cc_role_access", flags, true))
		{
			if (reasonLen) strcopy(reason, reasonLen, "You do not have access to this class.");
			return false;
		}
	}

	if (def.teamLimit > 0)
	{
		int team = GetClientTeam(client);
		int count = 0;
		for (int other = 1; other <= MaxClients; other++)
		{
			if (other == client || !IsClientInGame(other) || GetClientTeam(other) != team)
				continue;
			if (g_iPending[other] == role || g_iRole[other] == role)
				count++;
		}
		if (count >= def.teamLimit)
		{
			if (reasonLen) FormatEx(reason, reasonLen, "Team limit reached (%d).", def.teamLimit);
			return false;
		}
	}

	if (!quiet)
		DebugLog("%L eligible for %s", client, def.key);
	return true;
}

/* ------------------------------------------------------------------------- */
/* Boss modes: VScript VSH (vsh_ maps, Hale on BLU), Freak Fortress 2 /      */
/* FF2 Rewrite, SourceMod VSH. Roles never go to the boss team or a boss;    */
/* the check runs inside the ForceRespawn hook, so a boss respawned by its   */
/* plugin is never converted to class 10.                                     */
/* ------------------------------------------------------------------------- */

native bool FF2_IsFF2Enabled();
native int FF2_GetBossIndex(int client);
native int FF2R_GetGamemodeType();
native bool VSH_IsSaxtonHaleModeEnabled();
native int VSH_GetSaxtonHaleUserId();

bool NativeReady(const char[] name)
{
	return GetFeatureStatus(FeatureType_Native, name) == FeatureStatus_Available;
}

bool BossModeActive()
{
	if (NativeReady("FF2_IsFF2Enabled") && FF2_IsFF2Enabled())
		return true;
	if (NativeReady("FF2R_GetGamemodeType") && FF2R_GetGamemodeType() > 0)
		return true;
	if (NativeReady("VSH_IsSaxtonHaleModeEnabled") && VSH_IsSaxtonHaleModeEnabled())
		return true;

	char map[PLATFORM_MAX_PATH], prefixes[256];
	GetCurrentMap(map, sizeof(map));
	GetMapDisplayName(map, map, sizeof(map));
	g_cvBossPrefixes.GetString(prefixes, sizeof(prefixes));
	char parts[16][32];
	int n = ExplodeString(prefixes, ",", parts, sizeof(parts), sizeof(parts[]));
	for (int i = 0; i < n; i++)
	{
		TrimString(parts[i]);
		if (parts[i][0] && StrContains(map, parts[i], false) == 0)
			return true;
	}
	return false;
}

/* ------------------------------------------------------------------------- */
/* Hunted / VIP / escort maps: the map's own Civilian/VIP must stay unique,  */
/* so listed roles (default "civilian") are denied on the VIP team. The VIP  */
/* team is detected as the team holding a class-10 player that is not a     */
/* tf2cc role (e.g. vip_tfc_hunted makes its VIP TF_CLASS_CIVILIAN); if it   */
/* cannot be detected the roles are denied on both teams.                    */
/* ------------------------------------------------------------------------- */
bool IsVipMap()
{
	char map[PLATFORM_MAX_PATH], prefixes[256];
	GetCurrentMap(map, sizeof(map));
	GetMapDisplayName(map, map, sizeof(map));
	g_cvVipPrefixes.GetString(prefixes, sizeof(prefixes));
	char parts[16][32];
	int n = ExplodeString(prefixes, ",", parts, sizeof(parts), sizeof(parts[]));
	for (int i = 0; i < n; i++)
	{
		TrimString(parts[i]);
		if (parts[i][0] && StrContains(map, parts[i], false) == 0)
			return true;
	}
	return false;
}

int DetectVipTeam()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) >= 2 && g_iRole[i] == TF2CC_ROLE_NONE && g_iPending[i] == TF2CC_ROLE_NONE
			&& view_as<int>(TF2_GetPlayerClass(i)) == TF2CC_CLASS_INDEX)
			return GetClientTeam(i);
	}
	return g_cvVipTeam.IntValue;
}

bool VipDenies(int client, const char[] roleKey)
{
	if (!g_cvVipEnabled.BoolValue || !IsVipMap())
		return false;
	char list[128];
	g_cvVipRoles.GetString(list, sizeof(list));
	char parts[8][TF2CC_ROLE_KEY_LEN];
	int n = ExplodeString(list, ",", parts, sizeof(parts), sizeof(parts[]));
	bool listed = false;
	for (int i = 0; i < n; i++)
	{
		TrimString(parts[i]);
		if (StrEqual(parts[i], roleKey, false))
			listed = true;
	}
	if (!listed)
		return false;
	int vipTeam = DetectVipTeam();
	return vipTeam < 2 || GetClientTeam(client) == vipTeam;
}

int DetectHaleTeam()
{
	char model[PLATFORM_MAX_PATH];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) < 2)
			continue;
		GetEntPropString(i, Prop_Send, "m_iszCustomModel", model, sizeof(model));
		if (StrContains(model, "saxton", false) != -1 || StrContains(model, "hale", false) != -1)
			return GetClientTeam(i);
	}
	return 0;
}

bool IsBossModeClient(int client)
{
	// Individual bosses, whatever their team.
	if (NativeReady("FF2_GetBossIndex") && FF2_GetBossIndex(client) >= 0)
		return true;
	if (NativeReady("VSH_GetSaxtonHaleUserId") && VSH_GetSaxtonHaleUserId() == GetClientUserId(client))
		return true;
	if (!BossModeActive())
		return false;
	// Prefer the team actually hosting Hale (official VScript VSH and SM VSH
	// give the boss a Saxton Hale custom model); else tf2cc_boss_team.
	int bossTeam = DetectHaleTeam();
	if (bossTeam < 2)
		bossTeam = g_cvBossTeam.IntValue;
	return bossTeam >= 2 && GetClientTeam(client) == bossTeam;
}

/** Select a role (or TF2CC_ROLE_NONE for stock). Returns false if refused. */
/**
 * The retail client crashes drawing its HUD player model (cl_hud_show_playermodel 1)
 * for class 10 (no class entry for it). Servers cannot set that client cvar, so
 * players who have it on are kept off roles. Re-queried every few seconds.
 */
void QueryHudModel(int client)
{
	if (IsClientInGame(client) && !IsFakeClient(client))
		QueryClientConVar(client, "cl_hud_show_playermodel", OnHudModelQueried);
}

public void OnHudModelQueried(QueryCookie cookie, int client, ConVarQueryResult result, const char[] name, const char[] value)
{
	g_bHudPlayermodel[client] = result == ConVarQuery_Okay && StringToInt(value) != 0;
}

public Action Timer_QueryHudModel(Handle timer)
{
	if (g_cvHudModelGuard.BoolValue)
		for (int i = 1; i <= MaxClients; i++)
			QueryHudModel(i);
	return Plugin_Continue;
}

bool SelectRole(int client, int role, bool respawnNow, bool fromRandom = false)
{
	if (role != TF2CC_ROLE_NONE && g_cvHudModelGuard.BoolValue && g_bHudPlayermodel[client])
	{
		PrintToChat(client, "\x04[TF2CC]\x01 Set cl_hud_show_playermodel 0 first: the game client crashes drawing that HUD model for these classes.");
		return false;
	}
	if (role != TF2CC_ROLE_NONE)
	{
		char reason[128];
		if (!IsRoleEligible(client, role, false, reason, sizeof(reason)))
		{
			PrintToChat(client, "\x04[TF2CC]\x01 %s", reason);
			return false;
		}
	}

	if (!fromRandom)
		g_bRandomEachLife[client] = false;
	g_iPending[client] = role;

	if (role == TF2CC_ROLE_NONE)
		return true;

	RoleDef def;
	GetRoleDef(role, def);

	if (GetClientTeam(client) < 2)
	{
		PrintToChat(client, "\x04[TF2CC]\x01 You will spawn as the %s after joining a team.", def.name);
		return true;
	}

	if (g_iRole[client] == role && IsPlayerAlive(client))
		return true;

	if (respawnNow && CanChangeInstantly(client))
	{
		TF2_RespawnPlayer(client);
	}
	else if (IsPlayerAlive(client))
	{
		PrintToChat(client, "\x04[TF2CC]\x01 You will respawn as the %s.", def.name);
	}
	else
	{
		// Dead and waiting: the next wave's ForceRespawn applies the role.
		PrintToChat(client, "\x04[TF2CC]\x01 You will respawn as the %s.", def.name);
	}
	return true;
}

/** Pick uniformly-weighted from the nine stock classes plus eligible roles. */
void RollRandom(int client)
{
	float total = 9.0;
	RoleDef def;
	int count = g_Roles == null ? 0 : g_Roles.Length;
	float weights[TF2CC_MAX_ROLES];
	for (int i = 0; i < count; i++)
	{
		g_Roles.GetArray(i, def);
		weights[i] = IsRoleEligible(client, i) ? def.randomWeight : 0.0;
		total += weights[i];
	}

	float pick = GetURandomFloat() * total;
	if (pick < 9.0)
	{
		int cls = 1 + RoundToFloor(pick);
		if (cls > 9) cls = 9;
		g_iPending[client] = TF2CC_ROLE_NONE;
		g_iSafeClass[client] = cls;
		SetDesiredClass(client, cls);
		return;
	}
	pick -= 9.0;
	for (int i = 0; i < count; i++)
	{
		if (pick < weights[i])
		{
			g_iPending[client] = i;
			return;
		}
		pick -= weights[i];
	}
	g_iPending[client] = TF2CC_ROLE_NONE;
}

/**
 * Bots: each life, with tf2cc_bot_role_chance, become a random eligible role
 * (roles need allow_bots 1); otherwise keep the class the TFBot AI picked.
 * TFBots change class through HandleCommand_JoinClass, which only sets the
 * desired class, so this pre-ForceRespawn roll composes with tf_bot_* cvars.
 */
void RollBot(int client)
{
	if (g_bFixedClassBot[client] || (g_cvBotKeepClass != null && g_cvBotKeepClass.BoolValue))
		return; // explicit class (tf_bot_add <class>) or server keeps bot classes: leave as is
	g_iPending[client] = TF2CC_ROLE_NONE;
	if (GetURandomFloat() >= g_cvBotChance.FloatValue || g_Roles == null)
		return;
	int eligible[TF2CC_MAX_ROLES], n = 0;
	for (int i = 0; i < g_Roles.Length; i++)
		if (IsRoleEligible(client, i))
			eligible[n++] = i;
	if (n)
		g_iPending[client] = eligible[GetURandomInt() % n];
}

/**
 * tf_bot_add creates its bots synchronously inside the command, so a flag set
 * here and cleared next frame marks exactly those bots (OnClientPutInServer).
 */
public Action Listener_BotAdd(int client, const char[] command, int argc)
{
	if (client != 0)
		return Plugin_Continue;
	char arg[64];

	// "tf_bot_add 1 blue mercenary normal": strip the role word, run the stock
	// command synchronously, and pin every bot it creates to that role.
	if (g_iBotAddRole == TF2CC_ROLE_NONE)
	{
		char rest[256];
		int role = TF2CC_ROLE_NONE;
		for (int i = 1; i <= argc; i++)
		{
			GetCmdArg(i, arg, sizeof(arg));
			int r = RoleFromBotArg(arg);
			if (r != TF2CC_ROLE_NONE && role == TF2CC_ROLE_NONE)
			{
				role = r;
				continue;
			}
			Format(rest, sizeof(rest), "%s \"%s\"", rest, arg);
		}
		if (role != TF2CC_ROLE_NONE)
		{
			// tf_bot_add treats the unknown word as the bot name and creates the
			// bots synchronously after this listener; tag exactly those bots.
			// (Re-issuing via ServerExecute would flush unrelated queued commands.)
			g_iBotAddRole = role;
			RequestFrame(Frame_ClearBotAdd);
			return Plugin_Continue;
		}
	}

	for (int i = 1; i <= argc; i++)
	{
		GetCmdArg(i, arg, sizeof(arg));
		for (int c = 1; c <= 9; c++)
		{
			if (StrEqual(arg, g_sStockClassNames[c], false) || StrEqual(arg, g_sStockClassDisplay[c], false)
				|| (c == 6 && StrEqual(arg, "heavy", false)) || (c == 4 && StrEqual(arg, "demo", false)))
			{
				g_bBotAddHasClass = true;
				RequestFrame(Frame_ClearBotAdd);
				return Plugin_Continue;
			}
		}
	}
	return Plugin_Continue;
}

public void Frame_ClearBotAdd()
{
	g_bBotAddHasClass = false;
	g_iBotAddRole = TF2CC_ROLE_NONE;
}

/**
 * TFBots in a spawn room re-evaluate their class and CommitSuicide() when the
 * current class name differs from their next pick (tf_bot_behavior.cpp:152-172,
 * tf_bot.cpp:1382-1398). "civilian" never matches, so role bots would suicide-
 * loop. CommitSuicide calls Event_Killed directly (no damage hook), so while
 * any role bot is alive we temporarily disable that stock re-evaluation and
 * restore the server's own value afterwards. Bots still pick classes on death.
 */
public Action Timer_BotReevaluateGuard(Handle timer)
{
	ConVar cv = FindConVar("tf_bot_reevaluate_class_in_spawnroom");
	if (cv == null)
		return Plugin_Continue;
	bool need = false;
	if (g_cvBotGuard.BoolValue)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && IsFakeClient(i) && (g_iRole[i] != TF2CC_ROLE_NONE || g_iPending[i] != TF2CC_ROLE_NONE))
			{
				need = true;
				break;
			}
		}
	}
	if (need && !g_bReevalSuppressed)
	{
		g_iReevalOriginal = cv.IntValue;
		g_bReevalSuppressed = true;
		cv.SetInt(0);
	}
	else if (!need && g_bReevalSuppressed)
	{
		g_bReevalSuppressed = false;
		cv.SetInt(g_iReevalOriginal);
	}
	return Plugin_Continue;
}

int RoleFromBotArg(const char[] arg)
{
	int role = FindRoleByKey(arg);
	if (role != TF2CC_ROLE_NONE)
		return role;
	if (StrEqual(arg, "merc", false))
		return FindRoleByKey("mercenary");
	if (StrEqual(arg, "civ", false))
		return FindRoleByKey("civilian");
	return TF2CC_ROLE_NONE;
}

/* ------------------------------------------------------------------------- */
/* Commands and menus                                                        */
/* ------------------------------------------------------------------------- */

public Action Cmd_Class(int client, int args)
{
	if (!client)
		return Plugin_Handled;
	if (args >= 1)
	{
		char arg[32];
		GetCmdArg(1, arg, sizeof(arg));
		HandleClassArg(client, arg);
		return Plugin_Handled;
	}
	ShowRoleMenu(client);
	return Plugin_Handled;
}

public Action Cmd_Merc(int client, int args)
{
	if (client)
		HandleClassArg(client, "mercenary");
	return Plugin_Handled;
}

public Action Cmd_Civ(int client, int args)
{
	if (client)
		HandleClassArg(client, "civilian");
	return Plugin_Handled;
}

void HandleClassArg(int client, const char[] arg)
{
	if (StrEqual(arg, "random", false))
	{
		StartRandom(client);
		return;
	}
	int role = FindRoleByKey(arg);
	if (role != TF2CC_ROLE_NONE)
	{
		SelectRole(client, role, true);
		return;
	}
	for (int c = 1; c <= 9; c++)
	{
		if (StrEqual(arg, g_sStockClassNames[c], false) || StrEqual(arg, g_sStockClassDisplay[c], false))
		{
			JoinStockClass(client, c);
			return;
		}
	}
	PrintToChat(client, "\x04[TF2CC]\x01 Unknown class '%s'.", arg);
}

void ShowRoleMenu(int client)
{
	Menu menu = new Menu(Menu_Role);
	menu.SetTitle("Choose a class");
	RoleDef def;
	char info[8];
	int count = g_Roles == null ? 0 : g_Roles.Length;
	for (int i = 0; i < count; i++)
	{
		g_Roles.GetArray(i, def);
		IntToString(i, info, sizeof(info));
		bool ok = IsRoleEligible(client, i);
		menu.AddItem(info, def.name, ok ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	}
	menu.AddItem("random", "Random");
	menu.ExitButton = true;
	menu.Display(client, 20);
}

public int Menu_Role(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		if (StrEqual(info, "random"))
		{
			StartRandom(client);
		}
		else if (StrEqual(info, "stock"))
		{
			ShowStockClassPanel(client);
		}
		else
		{
			SelectRole(client, StringToInt(info), true);
		}
	}
	return 0;
}

void ShowStockClassPanel(int client)
{
	int team = GetClientTeam(client);
	if (team == view_as<int>(TFTeam_Red))
		ShowVGUIPanel(client, "class_red");
	else if (team == view_as<int>(TFTeam_Blue))
		ShowVGUIPanel(client, "class_blue");
}

void StartRandom(int client)
{
	g_bRandomEachLife[client] = true;
	RollRandom(client);
	g_bJustRolled[client] = true; // the respawn below must not roll again
	if (g_iPending[client] != TF2CC_ROLE_NONE)
	{
		SelectRole(client, g_iPending[client], true, true);
	}
	else
	{
		int cls = g_iSafeClass[client];
		JoinStockClass(client, cls, true);
	}
}

void JoinStockClass(int client, int cls, bool keepRandom = false)
{
	if (!keepRandom)
		g_bRandomEachLife[client] = false;
	g_iPending[client] = TF2CC_ROLE_NONE;
	g_iSafeClass[client] = cls;
	// joinclass returns early when the class equals the desired class; role
	// players keep a stock "safe" desired class, so clear it first.
	if (g_iRole[client] != TF2CC_ROLE_NONE)
		SetDesiredClass(client, 0);
	g_bInternalJoin[client] = true;
	FakeClientCommand(client, "joinclass %s", g_sStockClassNames[cls]);
	g_bInternalJoin[client] = false;
}

public Action Listener_JoinClass(int client, const char[] command, int argc)
{
	if (!TF2CC_IsValidClient(client) || !g_cvEnabled.BoolValue || g_bInternalJoin[client])
		return Plugin_Continue;

	char arg[32];
	GetCmdArg(1, arg, sizeof(arg));

	if ((StrEqual(arg, "random", false) || StrEqual(arg, "auto", false)) && g_cvRandomMenu.BoolValue
		&& g_Roles != null && g_Roles.Length > 0 && GetClientTeam(client) >= 2)
	{
		ShowRoleMenu(client);
		return Plugin_Handled;
	}

	// Any explicit stock class choice ends the role selection.
	if (g_iPending[client] != TF2CC_ROLE_NONE || g_iRole[client] != TF2CC_ROLE_NONE || g_bRandomEachLife[client])
	{
		g_bRandomEachLife[client] = false;
		g_iPending[client] = TF2CC_ROLE_NONE;
		for (int c = 1; c <= 9; c++)
		{
			if (StrEqual(arg, g_sStockClassNames[c], false))
			{
				g_iSafeClass[client] = c;
				break;
			}
		}
		if (g_iRole[client] != TF2CC_ROLE_NONE)
			SetDesiredClass(client, 0);
	}
	return Plugin_Continue;
}

public Action Listener_VoiceMenu(int client, const char[] command, int argc)
{
	if (!TF2CC_IsValidClient(client) || g_iRole[client] == TF2CC_ROLE_NONE || argc < 2)
		return Plugin_Continue;

	char a[8], b[8];
	GetCmdArg(1, a, sizeof(a));
	GetCmdArg(2, b, sizeof(b));
	int menu = StringToInt(a), item = StringToInt(b);

	Action result = Plugin_Continue;
	Call_StartForward(g_fwdVoicePre);
	Call_PushCell(client);
	Call_PushCell(menu);
	Call_PushCell(item);
	Call_Finish(result);
	if (result >= Plugin_Handled)
		return Plugin_Handled;

	Call_StartForward(g_fwdVoice);
	Call_PushCell(client);
	Call_PushCell(menu);
	Call_PushCell(item);
	Call_Finish();
	// Stock voice rules have no class-10 responses; the voice module speaks.
	return Plugin_Handled;
}

public Action Cmd_Reload(int client, int args)
{
	LoadRoles();
	PrecacheRoleModels();
	ReplyToCommand(client, "[TF2CC] Reloaded %d role(s).", g_Roles == null ? 0 : g_Roles.Length);
	return Plugin_Handled;
}

public Action Cmd_Status(int client, int args)
{
	ReplyToCommand(client, "[TF2CC] ForceRespawn hook: %s, TF2Attributes: %s", g_bForceRespawnHook ? "yes" : "NO (fallback)", g_bTF2Attributes ? "yes" : "no");
	RoleDef def;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;
		char active[32] = "-", pending[32] = "-";
		char model[PLATFORM_MAX_PATH];
		GetEntPropString(i, Prop_Send, "m_iszCustomModel", model, sizeof(model));
		if (GetRoleDef(g_iRole[i], def)) strcopy(active, sizeof(active), def.key);
		if (GetRoleDef(g_iPending[i], def)) strcopy(pending, sizeof(pending), def.key);
		ReplyToCommand(client, "  %N: class=%d desired=%d role=%s pending=%s random=%d safe=%d room=%d model=%s",
			i, view_as<int>(TF2_GetPlayerClass(i)), GetEntProp(i, Prop_Send, "m_iDesiredPlayerClass"),
			active, pending, g_bRandomEachLife[i], SafeClass(i), g_bInRespawnRoom[i], model);
	}
	return Plugin_Handled;
}

public Action Cmd_SetRoleAdmin(int client, int args)
{
	if (args < 2)
	{
		ReplyToCommand(client, "Usage: sm_tf2cc_setrole <target> <role|none>");
		return Plugin_Handled;
	}
	char targetArg[64], roleArg[32];
	GetCmdArg(1, targetArg, sizeof(targetArg));
	GetCmdArg(2, roleArg, sizeof(roleArg));
	int role = StrEqual(roleArg, "none", false) ? TF2CC_ROLE_NONE : FindRoleByKey(roleArg);
	if (role == TF2CC_ROLE_NONE && !StrEqual(roleArg, "none", false))
	{
		ReplyToCommand(client, "[TF2CC] Unknown role '%s'.", roleArg);
		return Plugin_Handled;
	}

	int targets[MAXPLAYERS];
	char targetName[MAX_TARGET_LENGTH];
	bool tnIsMl;
	int n = ProcessTargetString(targetArg, client, targets, sizeof(targets), COMMAND_FILTER_CONNECTED, targetName, sizeof(targetName), tnIsMl);
	if (n <= 0)
	{
		ReplyToTargetError(client, n);
		return Plugin_Handled;
	}
	for (int i = 0; i < n; i++)
	{
		if (role == TF2CC_ROLE_NONE)
			JoinStockClass(targets[i], SafeClass(targets[i]));
		else
			SelectRole(targets[i], role, true);
	}
	ReplyToCommand(client, "[TF2CC] Applied to %d player(s).", n);
	return Plugin_Handled;
}

/* ------------------------------------------------------------------------- */
/* Natives                                                                   */
/* ------------------------------------------------------------------------- */

public any Native_GetRole(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients)
		return TF2CC_ROLE_NONE;
	return g_iRole[client];
}

public any Native_GetPendingRole(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients)
		return TF2CC_ROLE_NONE;
	return g_iPending[client];
}

public any Native_GetRoleCount(Handle plugin, int numParams)
{
	return g_Roles == null ? 0 : g_Roles.Length;
}

public any Native_FindRole(Handle plugin, int numParams)
{
	char key[TF2CC_ROLE_KEY_LEN];
	GetNativeString(1, key, sizeof(key));
	return FindRoleByKey(key);
}

public any Native_GetRoleKey(Handle plugin, int numParams)
{
	RoleDef def;
	if (!GetRoleDef(GetNativeCell(1), def))
		def.key[0] = '\0';
	SetNativeString(2, def.key, GetNativeCell(3));
	return 0;
}

public any Native_GetRoleName(Handle plugin, int numParams)
{
	RoleDef def;
	if (!GetRoleDef(GetNativeCell(1), def))
		def.name[0] = '\0';
	SetNativeString(2, def.name, GetNativeCell(3));
	return 0;
}

public any Native_GetRoleString(Handle plugin, int numParams)
{
	RoleDef def;
	int maxlen = GetNativeCell(4);
	if (g_kvRoles == null || !GetRoleDef(GetNativeCell(1), def))
		return false;
	char key[64];
	GetNativeString(2, key, sizeof(key));
	char[] value = new char[maxlen];
	g_kvRoles.Rewind();
	bool found = false;
	if (g_kvRoles.JumpToKey(def.key))
	{
		g_kvRoles.GetString(key, value, maxlen, "\x01");
		found = !(value[0] == '\x01' && value[1] == '\0');
		if (!found)
			value[0] = '\0';
	}
	g_kvRoles.Rewind();
	SetNativeString(3, value, maxlen);
	return found;
}

public any Native_SetRole(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	int role = GetNativeCell(2);
	bool now = GetNativeCell(3);
	if (!TF2CC_IsValidClient(client))
		return false;
	if (role == TF2CC_ROLE_NONE)
	{
		JoinStockClass(client, SafeClass(client));
		return true;
	}
	return SelectRole(client, role, now);
}

public any Native_IsRoleEligible(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (!TF2CC_IsValidClient(client))
		return false;
	return IsRoleEligible(client, GetNativeCell(2));
}

/* ------------------------------------------------------------------------- */

void DebugLog(const char[] fmt, any ...)
{
	if (!g_cvDebug.BoolValue)
		return;
	char buffer[512];
	VFormat(buffer, sizeof(buffer), fmt, 2);
	LogToFileEx(g_sLogPath, "%s", buffer);
}

/* ------------------------------------------------------------------------- */
/* MvM upgrade stations (VScript PvP upgrade maps)                           */
/* ------------------------------------------------------------------------- */

// Role base stats use "max health additive penalty" / "move speed penalty" so
// purchased MvM player upgrades ("... bonus") stack instead of being overwritten.
// Item upgrades cannot apply to class-10 weapons (no class-10 loadout slot in the
// schema), so purchases are player upgrades only; tf2cc_mvm_upgrades 0 blocks
// role players from buying at all.
public Action OnClientCommandKeyValues(int client, KeyValues kv)
{
	if (g_cvMvmUpgrades.BoolValue || !TF2CC_IsValidClient(client) || g_iRole[client] == TF2CC_ROLE_NONE)
		return Plugin_Continue;
	char section[64];
	kv.GetSectionName(section, sizeof(section));
	if (StrEqual(section, "MVM_Upgrade", false))
	{
		PrintCenterText(client, "Upgrades are disabled for this class");
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

/**
 * No fall damage for roles with roles.cfg "fall_damage" "0" (OF Mercenary),
 * plus whoever tf2cc_no_fall_damage lists: "all", "roles", role keys or
 * stock class names (same syntax as the Classic Movement fork's cm_scope).
 */
public Action Hook_FallDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if (!(damagetype & DMG_FALL))
		return Plugin_Continue;
	bool immune = false;
	RoleDef def;
	if (g_iRole[victim] != TF2CC_ROLE_NONE && GetRoleDef(g_iRole[victim], def) && !def.fallDamage)
		immune = true;
	if (!immune)
		immune = InScopeList(victim, g_cvNoFallScope);
	if (!immune)
		return Plugin_Continue;
	damage = 0.0;
	return Plugin_Handled;
}

bool InScopeList(int client, ConVar cv)
{
	char list[256], parts[16][32];
	cv.GetString(list, sizeof(list));
	if (!list[0])
		return false;
	static const char names[][] = { "", "scout", "sniper", "soldier", "demoman", "medic", "heavy", "pyro", "spy", "engineer" };
	int n = ExplodeString(list, ",", parts, sizeof(parts), sizeof(parts[]));
	for (int i = 0; i < n; i++)
	{
		TrimString(parts[i]);
		if (StrEqual(parts[i], "all", false))
			return true;
		if (g_iRole[client] != TF2CC_ROLE_NONE)
		{
			RoleDef def;
			if (StrEqual(parts[i], "roles", false))
				return true;
			if (GetRoleDef(g_iRole[client], def) && StrEqual(parts[i], def.key, false))
				return true;
			continue;
		}
		int cls = view_as<int>(TF2_GetPlayerClass(client));
		if (cls >= 1 && cls <= 9 && StrEqual(parts[i], names[cls], false))
			return true;
	}
	return false;
}
