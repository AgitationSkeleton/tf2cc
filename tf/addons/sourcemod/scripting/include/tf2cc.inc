/**
 * tf2cc - TF2 custom class framework (Civilian / Mercenary on stock class 10)
 *
 * Shared interface between tf2cc_core and feature modules.
 * Roles are logical identities layered on the stock TF_CLASS_CIVILIAN (10)
 * network class. Never infer a role from class index, model or weapon:
 * always ask the core.
 */
#if defined _tf2cc_included
 #endinput
#endif
#define _tf2cc_included

#define TF2CC_VERSION        "0.1.0"
#define TF2CC_LIBRARY        "tf2cc"

#define TF2CC_CLASS_INDEX    10      // stock TF_CLASS_CIVILIAN
#define TF2CC_ROLE_NONE      -1
#define TF2CC_MAX_ROLES      8
#define TF2CC_ROLE_KEY_LEN   32

/**
 * Logical role of a client, or TF2CC_ROLE_NONE.
 * Only valid while the client is (or is about to spawn as) class 10.
 */
native int TF2CC_GetRole(int client);

/** Role the client will become on their next spawn (TF2CC_ROLE_NONE = stock class). */
native int TF2CC_GetPendingRole(int client);

/** Number of configured roles. */
native int TF2CC_GetRoleCount();

/** Look up a role index by its config key ("mercenary", "civilian"). -1 if unknown. */
native int TF2CC_FindRole(const char[] key);

/** Copy a role's config key. */
native void TF2CC_GetRoleKey(int role, char[] buffer, int maxlen);

/** Copy a role's display name. */
native void TF2CC_GetRoleName(int role, char[] buffer, int maxlen);

/**
 * Read a string value from the role's section of roles.cfg (dotted paths are not
 * supported; nested sections are read by the owning module itself).
 * Returns false if the key is absent.
 */
native bool TF2CC_GetRoleString(int role, const char[] key, char[] buffer, int maxlen);

/**
 * Request a role change. role == TF2CC_ROLE_NONE returns the client to a stock class.
 * respawnNow: respawn immediately when the stock rules would allow an instant
 * class change (dead, or alive inside a friendly respawn room).
 * Returns false if the role is not currently eligible for the client.
 */
native bool TF2CC_SetRole(int client, int role, bool respawnNow = true);

/** True if the role may currently be chosen by the client (limits, map, mode). */
native bool TF2CC_IsRoleEligible(int client, int role);

/**
 * Called once per life after a role player spawned as class 10 and the core
 * applied model/health/speed. Modules grant loadouts and start abilities here.
 */
forward void TF2CC_OnRoleSpawned(int client, int role);

/**
 * Called when a client stops being a role (spawned as a stock class, disconnected,
 * or the core unloaded). Modules must release every entity/state they own.
 */
forward void TF2CC_OnRoleCleared(int client, int oldRole);

/**
 * voicemenu routing for role players, in two ordered phases so that
 * interactive uses (weapon pickup on the "MEDIC!" key) win over speech.
 * Return Plugin_Handled from the Pre phase to consume the command.
 */
forward Action TF2CC_OnVoiceMenuPre(int client, int menu, int item);
forward void TF2CC_OnVoiceMenu(int client, int menu, int item);

/**
 * Fired by tf2cc_movement once per successful ground jump (single authority for
 * jump-dependent features such as jump vocals).
 */
forward void TF2CC_OnPlayerJumped(int client, bool autoHop);

public SharedPlugin __pl_tf2cc =
{
	name = TF2CC_LIBRARY,
	file = "tf2cc_core.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_tf2cc_SetNTVOptional()
{
	MarkNativeAsOptional("TF2CC_GetRole");
	MarkNativeAsOptional("TF2CC_GetPendingRole");
	MarkNativeAsOptional("TF2CC_GetRoleCount");
	MarkNativeAsOptional("TF2CC_FindRole");
	MarkNativeAsOptional("TF2CC_GetRoleKey");
	MarkNativeAsOptional("TF2CC_GetRoleName");
	MarkNativeAsOptional("TF2CC_GetRoleString");
	MarkNativeAsOptional("TF2CC_SetRole");
	MarkNativeAsOptional("TF2CC_IsRoleEligible");
}
#endif

/* ---------- small shared helpers ---------- */

stock bool TF2CC_IsValidClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client);
}

/** True if the client currently is a role player (class 10 + role). */
stock bool TF2CC_IsRolePlayer(int client)
{
	return TF2CC_IsValidClient(client) && TF2CC_GetRole(client) != TF2CC_ROLE_NONE;
}

/** Case-insensitive role-key comparison helper. */
stock bool TF2CC_RoleIs(int client, const char[] key)
{
	int role = TF2CC_GetRole(client);
	if (role == TF2CC_ROLE_NONE)
		return false;
	char buf[TF2CC_ROLE_KEY_LEN];
	TF2CC_GetRoleKey(role, buf, sizeof(buf));
	return StrEqual(buf, key, false);
}
