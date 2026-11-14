/**
 * tf2cc_weapons - loadouts, Mercenary 3-slot inventory, ammo, pickups, arms.
 *
 * Key mechanisms (see docs/ARCHITECTURE.md for the evidence):
 *  - Weapons are created as real econ weapons of a *coherent* stock donor and
 *    equipped with EquipPlayerWeapon; switching always goes through the game's
 *    own Weapon_Switch ("use <classname>"). No m_hActiveWeapon writes.
 *  - First-person arms: the weapon's networked m_nCustomViewmodelModelIndex
 *    (CBaseCombatWeapon::SetViewModel, shared/predicted code) points at the
 *    role's donor-family arms. Set once at grant time - no per-frame writes.
 *  - Class 10's class-data max ammo is 0 for every type (retail civilian.ctx),
 *    so reserve ammo is an authoritative per-slot pool owned here.
 *  - Stock ValidateWeapons removes every class-10 weapon on resupply; the
 *    inventory record re-materialises them on post_inventory_application.
 *    Weapons carry the owner's account id so the stock code never spawns
 *    tf_dropped_weapon copies of them.
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

public Plugin myinfo =
{
	name = "TF2CC Weapons",
	author = "tf2cc-rework",
	description = "Custom-class loadouts, Mercenary inventory, ammo and pickups",
	version = TF2CC_VERSION,
	url = ""
};

#define CONFIG_WEAPONS "configs/tf2cc/weapons.cfg"
#define ITEMS_GAME     "scripts/items/items_game.txt"

#define EF_PARENT_ANIMATES 0x200   // const.h (not in SourceMod)
#define SLOT_PRIMARY   0
#define SLOT_SECONDARY 1
#define SLOT_MELEE     2
#define SLOT_UTILITY   3       // legacy MarxVee "Merc_4" items (grapple, Hoarder's Stash); not a combat slot
#define SLOT_COUNT     4
#define STASH_WEAPON 1
#define STASH_STOCK  2
#define STASH_HEALTH 3
#define STASH_AMMO   4


#define WEAPON_NONE    -1
#define STOCK_ITEM     -2      // record holds a stock item picked up by defindex

#define EF_BONEMERGE          0x001
#define EF_NODRAW             0x020
#define EF_NORECEIVESHADOW    0x040
#define EF_BONEMERGE_FASTCULL 0x080

#define TF_AMMO_PRIMARY   1
#define TF_AMMO_SECONDARY 2

static const char g_sSlotNames[][] = { "primary", "secondary", "melee", "utility" };
GlobalForward g_fwdPerk;
ConVar g_cvProfile;

// Index = TFClassType. Raw names used by arms files and items_game used_by_classes.
static const char g_sClassArmsName[][] = { "", "scout", "sniper", "soldier", "demo", "medic", "heavy", "pyro", "spy", "engineer" };
static const char g_sClassSchemaName[][] = { "", "scout", "sniper", "soldier", "demoman", "medic", "heavy", "pyro", "spy", "engineer" };
// Retail scripts/playerclasses/*.ctx AmmoMax (decrypted with tools/icedecrypt.py).
static const int g_iClassAmmoMax[][] =
{
	{ 0, 0 }, { 32, 36 }, { 25, 75 }, { 20, 32 }, { 16, 24 }, { 150, 150 }, { 200, 32 }, { 200, 32 }, { 20, 24 }, { 32, 200 }
};

/* ---------------- configured custom weapons ---------------- */

enum struct WeaponDef
{
	char id[48];
	char name[64];
	char roles[128];
	int slot;
	char classname[64];
	int itemdef;
	int family;               // TFClassType whose arms/animations the donor uses
	char worldModel[PLATFORM_MAX_PATH];
	char viewModel[PLATFORM_MAX_PATH];  // source self-contained OF/TF2C v_model
	char viewModelGen[PLATFORM_MAX_PATH]; // donor-retargeted copy (tools/gen_viewmodels.py)
	char stockClasses[160];   // stock pickups of these classnames use this viewmodel ("stock_classes")
	char stockModel[64];      // ... when their schema model contains this ("stock_model")
	char vmMode[16];          // per-weapon override: auto | custom | family
	int tier;                 // 0 common (C), 1 uncommon (B), 2 rare (A), 3 ultra (S)
	char special[32];         // tf2cc_specials behaviour id
	float specialValue;
	int clip;                 // -1 = donor default
	int reserve;              // max reserve; -1 = donor-class default
	float pickupWeight;       // ammo-pack grant weight (0 = never)
	bool droppable;
	bool alwaysDrop;          // drops on death even from a default loadout / non-pickup role
	bool noAltFire;           // donor alt-fire blocked (e.g. the Shortstop shove)
	int attrStart;            // index into g_Attrs
	int attrCount;
	ArrayList sounds;         // pairs: normalised find, replace
	bool soundsLoop;          // replacements loop (cue points): stop them when firing stops
}

enum struct AttrDef
{
	char name[96];
	float value;
}

ArrayList g_Weapons;
ArrayList g_Attrs;

/* ---------------- schema (items_game.txt) ---------------- */

enum struct SchemaItem
{
	char itemClass[64];
	char itemSlot[16];
	char usedBy[96];
	char model[PLATFORM_MAX_PATH];
	char prefab[96];
	char animSlot[16];
}

StringMap g_SchemaItems;     // defindex -> SchemaItem (raw, unresolved)
StringMap g_SchemaPrefabs;   // prefab name -> SchemaItem
bool g_bSchemaLoaded;

/* ---------------- per-client inventory ---------------- */

enum struct SlotRecord
{
	int weapon;      // index into g_Weapons, STOCK_ITEM or WEAPON_NONE
	int itemdef;
	int entRef;
	int clip;
	int reserve;
	int maxReserve;
}

SlotRecord g_Inv[MAXPLAYERS + 1][SLOT_COUNT];
int g_iArmsWearable[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
int g_iWeaponWearable[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
int g_iLastActive[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
bool g_bGranting[MAXPLAYERS + 1];
float g_flNextPickupHint[MAXPLAYERS + 1];

/* ---------------- pickups ---------------- */

enum struct PickupData
{
	int weapon;
	int itemdef;
	int clip;
	int reserve;
	float expires;
	int dropper;      // userid that dropped it (cannot re-take it before readyAt)
	float readyAt;
}

StringMap g_Pickups;   // entref string -> PickupData
float g_flPackReady[2049];
float g_flNextPackTouch[MAXPLAYERS + 1];
float g_flDiedAt[MAXPLAYERS + 1];
float g_vecDiedAt[MAXPLAYERS + 1][3];
int g_iDiedDefs[MAXPLAYERS + 1][4];   // item defs of the custom weapons held at death
ConVar g_cvStripForeign;
ConVar g_cvBotSwapChance;
KeyValues g_kvVariants;   // configs/tf2cc/model_variants.cfg
ConVar g_cvModelVariants;
ConVar g_cvOwnerSounds;
char g_sPackLog[PLATFORM_MAX_PATH];
float g_flRematBurstStart;   // round-restart burst staggering (Event_Inventory)
int g_iRematBurst;
bool g_bEchoing;
bool g_bUseHeld[MAXPLAYERS + 1];
int g_iWorldWearable[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };  // per-entity cooldown in case a pack ignores Disable

ConVar g_cvPackWeapons;
ConVar g_cvPackRespawn;
ConVar g_cvPickupLifetime;
ConVar g_cvAutoPickupEmpty;
ConVar g_cvDropOnDeath;
ConVar g_cvStockPickups;
ConVar g_cvCustomVM;

bool g_bTF2Attributes;
char g_sPickupSound[PLATFORM_MAX_PATH] = "items/gunpickup2.wav";
char g_sAmmoSound[PLATFORM_MAX_PATH] = "items/ammo_pickup.wav";

bool g_bLateLoad;
char g_sLoopSnd[MAXPLAYERS + 1][PLATFORM_MAX_PATH];
int g_iLoopEnt[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
int g_iLoopChan[MAXPLAYERS + 1];
float g_flLoopAt[MAXPLAYERS + 1];

/** Stop a "sounds_loop" replacement (e.g. the lightning gun zap). */
void StopLoopSound(int client)
{
	if (!g_sLoopSnd[client][0])
		return;
	int ent = EntRefToEntIndex(g_iLoopEnt[client]);
	if (ent > 0)
		StopSound(ent, g_iLoopChan[client], g_sLoopSnd[client]);
	g_sLoopSnd[client][0] = '\0';
	g_iLoopEnt[client] = INVALID_ENT_REFERENCE;
}
float g_flForceDonorSync[MAXPLAYERS + 1];

/** tf2cc_taunts after a taunt: rebuild the viewmodel overlay and world model. */
public any Native_RefreshWeaponVisuals(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client)
		|| TF2CC_GetRole(client) == TF2CC_ROLE_NONE || !IsRoleClass(client))
		return false;
	UpdateOverlay(client);
	g_flForceDonorSync[client] = GetGameTime() + 1.0;
	return true;
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_bLateLoad = late;
	CreateNative("TF2CC_GetWeaponSpecial", Native_GetWeaponSpecial);
	CreateNative("TF2CC_ClientHasSpecial", Native_ClientHasSpecial);
	CreateNative("TF2CC_GetWeaponId", Native_GetWeaponId);
	CreateNative("TF2CC_RefreshWeaponVisuals", Native_RefreshWeaponVisuals);
	// forward void TF2CC_OnPerkChanged(int client, const char[] special, bool gained);
	g_fwdPerk = new GlobalForward("TF2CC_OnPerkChanged", ET_Ignore, Param_Cell, Param_String, Param_Cell);
	RegPluginLibrary("tf2cc_weapons");
	return APLRes_Success;
}

/** native bool TF2CC_GetWeaponSpecial(int weapon, char[] special, int maxlen, float &value) */
public any Native_GetWeaponSpecial(Handle plugin, int numParams)
{
	int weapon = GetNativeCell(1);
	if (weapon <= MaxClients || !IsValidEntity(weapon) || !HasEntProp(weapon, Prop_Send, "m_hOwnerEntity"))
		return false;
	int owner = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
	if (owner < 1 || owner > MaxClients)
		return false;
	int slot = SlotOfEntity(owner, weapon);
	if (slot < 0 || g_Inv[owner][slot].weapon < 0)
		return false;
	WeaponDef w;
	g_Weapons.GetArray(g_Inv[owner][slot].weapon, w);
	if (!w.special[0])
		return false;
	SetNativeString(2, w.special, GetNativeCell(3));
	SetNativeCellRef(4, w.specialValue);
	return true;
}

/** native bool TF2CC_ClientHasSpecial(int client, const char[] special) - any slot record. */
public any Native_ClientHasSpecial(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients || g_Weapons == null)
		return false;
	char want[32];
	GetNativeString(2, want, sizeof(want));
	WeaponDef w;
	for (int s = 0; s < SLOT_COUNT; s++)
	{
		if (g_Inv[client][s].weapon < 0)
			continue;
		g_Weapons.GetArray(g_Inv[client][s].weapon, w);
		if (StrEqual(w.special, want, false))
			return true;
	}
	return false;
}

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	AddCommandListener(Listener_Inspect, "+inspect");
	g_cvOwnerSounds = CreateConVar("tf2cc_owner_weapon_sounds", "1", "1 = the shooter also hears a weapon's replacement sounds (sent with the same channel, level, volume and pitch as everyone else; the client's own stock sound still plays).", _, true, 0.0, true, 1.0);
	g_cvModelVariants = CreateConVar("tf2cc_model_variants", "1", "1 = switch the role player model per held weapon (exact OF 3P animation sets, model_variants.cfg); 0 = always the role's base model.", _, true, 0.0, true, 1.0);
	g_cvModelVariants.AddChangeHook(OnVariantsCvarChanged);
	g_cvBotSwapChance = CreateConVar("tf2cc_bot_pickup_swap_chance", "0.1", "Role bots standing on a weapon: chance per 0.2 s to pick it up, swapping their current one.", _, true, 0.0, true, 1.0);
	g_cvStripForeign = CreateConVar("tf2cc_strip_foreign_weapons", "1", "Remove weapons other plugins equip on role players (e.g. GiveBotsMoreWeapons).", _, true, 0.0, true, 1.0);
	g_cvPackWeapons = CreateConVar("tf2cc_ammopack_weapon_chance", "1.0", "Chance that a map ammo pack also drops a Mercenary weapon on the floor (MarxVee sm_btm_ammoweapondrops). Dropped player packs never do.", _, true, 0.0, true, 1.0);
	g_cvPackRespawn = CreateConVar("tf2cc_ammopack_respawn", "10.0", "Seconds before a map ammo pack consumed by a role player reappears.");
	g_cvPickupLifetime = CreateConVar("tf2cc_pickup_lifetime", "30.0", "Seconds a dropped Mercenary weapon stays on the ground.");
	g_cvAutoPickupEmpty = CreateConVar("tf2cc_pickup_auto_empty_slot", "1", "Touching a weapon whose slot is empty picks it up automatically (OF behaviour).", _, true, 0.0, true, 1.0);
	g_cvDropOnDeath = CreateConVar("tf2cc_drop_on_death", "1", "Mercenary drops his active non-default weapon on death.", _, true, 0.0, true, 1.0);
	g_cvStockPickups = CreateConVar("tf2cc_stock_pickups", "1", "Mercenary may pick up weapons dropped by any class (tf_dropped_weapon).", _, true, 0.0, true, 1.0);
	g_cvCustomVM = CreateConVar("tf2cc_viewmodel_mode", "auto", "First-person viewmodels: auto (OF/TF2C v_model when generated, else role arms) | custom | family. Per-weapon \"viewmodel_mode\" overrides.");
	AutoExecConfig(true, "tf2cc_weapons");

	RegConsoleCmd("sm_dropweapon", Cmd_Drop, "Mercenary: drop the active weapon.");
	RegConsoleCmd("sm_stash", Cmd_Stash, "Hoarder's Stash: use stored items.");
	AddCommandListener(Listener_StashKey, "+use_action_slot_item");
	RegAdminCmd("sm_tf2cc_givestock", Cmd_GiveStock, ADMFLAG_CHEATS, "sm_tf2cc_givestock <item def index> <target> - give a role player a stock item the way a pickup does (testing).");
	RegAdminCmd("sm_tf2cc_give", Cmd_Give, ADMFLAG_CHEATS, "sm_tf2cc_give <weapon id> [target] - give a configured tf2cc weapon (yourself by default).");
	RegAdminCmd("sm_tf2cc_weapons", Cmd_ListWeapons, ADMFLAG_GENERIC, "List configured tf2cc weapons and their validation status.");
	RegAdminCmd("sm_tf2cc_inv", Cmd_Inventory, ADMFLAG_GENERIC, "Dump role players' inventory records and live weapon state.");
	RegAdminCmd("sm_tf2cc_entleak", Cmd_EntLeak, ADMFLAG_GENERIC, "Count tf_weapon_*/tf_wearable* entities by owner state (held / owned-not-held / orphan) to find leaks.");
	RegAdminCmd("sm_tf2cc_vmstate", Cmd_VMState, ADMFLAG_GENERIC, "sm_tf2cc_vmstate <target> - viewmodel, active weapon flags and owned wearables (logs/tf2cc_vmtrace.log).");
	RegAdminCmd("sm_tf2cc_vmtrace", Cmd_VMTrace, ADMFLAG_GENERIC, "sm_tf2cc_vmtrace <target> [seconds] - log viewmodel sequence/parity/model every 0.1 s to logs/tf2cc_vmtrace.log.");
	AddCommandListener(Listener_DropItem, "dropitem");

	HookEvent("post_inventory_application", Event_Inventory);
	BuildPath(Path_SM, g_sPackLog, sizeof(g_sPackLog), "logs/tf2cc_packs.log");
	CreateTimer(0.2, Timer_PickupScan, _, TIMER_REPEAT);
	HookEvent("player_death", Event_PlayerDeath);

	g_Pickups = new StringMap();
	g_cvProfile = CreateConVar("tf2cc_weapon_profile", "source", "Weapon behaviour profile: source (Open Fortress / TF2 Classic accurate) | marxvee (legacy MarxVee tuning). Per-weapon \"profile\" in weapons.cfg overrides. Applies from the next spawn.");
	g_cvProfile.AddChangeHook(OnProfileChanged);
	LoadWeapons();
	AddNormalSoundHook(Hook_Sound);

	if (g_bLateLoad)
		LateLoad();
	else
		for (int client = 1; client <= MaxClients; client++)
			if (IsClientInGame(client))
				OnClientPutInServer(client);
}

public void OnAllPluginsLoaded()
{
	g_bTF2Attributes = LibraryExists("tf2attributes");
	ValidateAttributes(0, false);
}
public void OnLibraryAdded(const char[] name) { if (StrEqual(name, "tf2attributes")) g_bTF2Attributes = true; }
public void OnLibraryRemoved(const char[] name) { if (StrEqual(name, "tf2attributes")) g_bTF2Attributes = false; }

void LateLoad()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client))
			continue;
		OnClientPutInServer(client);
		if (IsPlayerAlive(client) && TF2CC_GetRole(client) != TF2CC_ROLE_NONE)
		{
			AdoptInventory(client);
			UpdateOverlay(client);
		}
	}
	// Map packs/kits only hook in OnEntityCreated, which already ran for them.
	char cls[64];
	for (int e = MaxClients + 1; e < GetMaxEntities(); e++)
	{
		if (!IsValidEntity(e))
			continue;
		GetEntityClassname(e, cls, sizeof(cls));
		if (StrContains(cls, "item_ammopack_") == 0 || StrEqual(cls, "tf_ammo_pack") || StrContains(cls, "item_healthkit_") == 0)
			OnEntityCreated(e, cls);
	}
}

public void OnPluginEnd()
{
	for (int client = 1; client <= MaxClients; client++)
		if (IsClientInGame(client))
			RemoveOverlay(client);
	StringMapSnapshot snap = g_Pickups.Snapshot();
	char key[16];
	for (int i = 0; i < snap.Length; i++)
	{
		snap.GetKey(i, key, sizeof(key));
		int ent = EntRefToEntIndex(StringToInt(key));
		if (ent > MaxClients)
			RemoveEntity(ent);
	}
	delete snap;
}

public void OnMapStart()
{
	PrecacheSound(g_sPickupSound, true);
	PrecacheSound(g_sAmmoSound, true);
	LoadModelVariants();
	g_Pickups.Clear();
	for (int i = 0; i < sizeof(g_flPackReady); i++)
		g_flPackReady[i] = 0.0;
	PrecacheWeaponModels();
}

public void OnConfigsExecuted()
{
	if (!g_bSchemaLoaded)
		LoadSchema();
	ValidateWeapons(0, false);
}

/**
 * Per-weapon player-model variants (Merc: exact Open Fortress 3P sets per
 * weapon; TF2 picks 3P animations by the donor item's slot group, so one
 * model cannot hold them all - tools/gen_merc_variants.py).
 * configs/tf2cc/model_variants.cfg: "model_variants" { "<role>" { "<weapon id>" "<model>" "default" "<model>" } }
 */
void LoadModelVariants()
{
	delete g_kvVariants;
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/tf2cc/model_variants.cfg");
	if (!FileExists(path))
		return;
	g_kvVariants = new KeyValues("model_variants");
	if (!g_kvVariants.ImportFromFile(path))
	{
		delete g_kvVariants;
		return;
	}
	int n = 0;
	char model[PLATFORM_MAX_PATH];
	if (g_kvVariants.GotoFirstSubKey())
	{
		do
		{
			if (g_kvVariants.GotoFirstSubKey(false))
			{
				do
				{
					g_kvVariants.GetString(NULL_STRING, model, sizeof(model));
					if (model[0] && FileExists(model, true) && PrecacheModel(model, true))
						n++;
				}
				while (g_kvVariants.GotoNextKey(false));
				g_kvVariants.GoBack();
			}
		}
		while (g_kvVariants.GotoNextKey());
		g_kvVariants.Rewind();
	}
	LogMessage("tf2cc_weapons: %d model variant entries precached", n);
}

public void OnVariantsCvarChanged(ConVar cv, const char[] oldValue, const char[] newValue)
{
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i))
			ApplyModelVariant(i);
}

/** Put the role player in the model variant for the active weapon (no-op if unchanged). */
void ApplyModelVariant(int client)
{
	if (!IsPlayerAlive(client) || (g_kvVariants == null && g_cvModelVariants.BoolValue))
		return;
	int role = TF2CC_GetRole(client);
	if (role == TF2CC_ROLE_NONE)
		return;
	char roleKey[32], id[48] = "default", model[PLATFORM_MAX_PATH], cur[PLATFORM_MAX_PATH];
	TF2CC_GetRoleKey(role, roleKey, sizeof(roleKey));
	if (!g_cvModelVariants.BoolValue)
	{
		// Same model for every weapon: the role's own model from roles.cfg.
		if (TF2CC_GetRoleString(role, "model", model, sizeof(model)) && model[0] && IsModelPrecached(model))
		{
			GetEntPropString(client, Prop_Send, "m_iszCustomModel", cur, sizeof(cur));
			if (!StrEqual(cur, model, false))
				SwapRoleModel(client, model);
		}
		return;
	}
	g_kvVariants.Rewind();
	if (!g_kvVariants.JumpToKey(roleKey))
		return;
	int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	int slot = active > MaxClients ? SlotOfEntity(client, active) : -1;
	if (slot >= 0)
	{
		if (g_Inv[client][slot].weapon >= 0)
		{
			WeaponDef w;
			g_Weapons.GetArray(g_Inv[client][slot].weapon, w);
			strcopy(id, sizeof(id), w.id);
		}
		else
			FormatEx(id, sizeof(id), "stock:%d", g_Inv[client][slot].itemdef);
	}
	g_kvVariants.GetString(id, model, sizeof(model));
	g_kvVariants.Rewind();
	if (!model[0] && slot >= 0 && g_Inv[client][slot].weapon < 0)
		StockVariant(client, active, slot, model, sizeof(model));
	if (!model[0] && g_kvVariants.JumpToKey(roleKey))
	{
		g_kvVariants.GetString("default", model, sizeof(model));
		g_kvVariants.Rewind();
	}
	if (!model[0] || !IsModelPrecached(model))
		return;
	GetEntPropString(client, Prop_Send, "m_iszCustomModel", cur, sizeof(cur));
	if (StrEqual(cur, model, false))
		return;
	SwapRoleModel(client, model);
}

/**
 * Model swap with a clean client animation restart. CMultiPlayerAnimState keeps
 * its main-sequence INDEX while the activity is unchanged, and every variant
 * numbers its sequences differently, so a swap mid-run left a stale index
 * pointing at an unrelated sequence (loser pose, swimming, wrong set). One
 * snapshot without class animations makes CTFPlayerAnimState::Update run
 * ClearAnimationState(); class animations come back 0.1 s later.
 */
void SwapRoleModel(int client, const char[] model)
{
	// InputSetCustomModel clears m_bUseClassAnimations; restore it the same tick.
	SetVariantString(model);
	AcceptEntityInput(client, "SetCustomModel");
	SetEntProp(client, Prop_Send, "m_bCustomModelRotates", 1);
	SetEntProp(client, Prop_Send, "m_bUseClassAnimations", 1);
}

public void OnClientPutInServer(int client)
{
	ClearInventory(client);
	g_iArmsWearable[client] = INVALID_ENT_REFERENCE;
	g_iWeaponWearable[client] = INVALID_ENT_REFERENCE;
	g_flNextPickupHint[client] = 0.0;
	SDKHook(client, SDKHook_WeaponSwitchPost, Hook_WeaponSwitchPost);
	SDKHook(client, SDKHook_WeaponEquipPost, Hook_WeaponEquipPost);
	SDKHook(client, SDKHook_PostThinkPost, Hook_HideDonor);
}

/**
 * Every tick: a role player's active donor stays hidden while its custom world
 * model rides a wearable. Deploy (SetWeaponVisible) clears EF_NODRAW on each
 * switch; re-hiding only every 0.2 s let quick switches show the stock model.
 */
public void Hook_HideDonor(int client)
{
	if (TF2CC_GetRole(client) == TF2CC_ROLE_NONE || !IsPlayerAlive(client) || EntRefToEntIndex(g_iWorldWearable[client]) <= MaxClients)
		return;
	int act = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (act <= MaxClients || !GetEntProp(act, Prop_Send, "m_bBeingRepurposedForTaunt"))
		return;
	int fx = GetEntProp(act, Prop_Send, "m_fEffects");
	if (!(fx & EF_NODRAW))
		fx |= EF_NODRAW;
	// The owner's client predicts Deploy and clears EF_NODRAW locally; the
	// server value never changes, so no update is sent and the owner keeps
	// seeing the donor (thirdperson). Toggling an unused bit for a second after
	// each switch forces m_fEffects (with EF_NODRAW) to be re-sent.
	if (GetGameTime() < g_flForceDonorSync[client])
		fx ^= EF_NORECEIVESHADOW;
	if (fx != GetEntProp(act, Prop_Send, "m_fEffects"))
		SetEntProp(act, Prop_Send, "m_fEffects", fx);
}

/** Late load (plugin reload mid-map): take over what role players already hold. */
void AdoptInventory(int client)
{
	for (int s = 0; s <= SLOT_MELEE; s++)
	{
		int ent = GetPlayerWeaponSlot(client, s);
		if (ent <= MaxClients)
			continue;
		char cls[64];
		GetEntityClassname(ent, cls, sizeof(cls));
		int itemdef = GetEntProp(ent, Prop_Send, "m_iItemDefinitionIndex");
		// Several configured weapons share a donor (umbrella and crowbar are both
		// tf_weapon_bat 0): the role's loadout weapon wins, then one the role may use.
		int role = TF2CC_GetRole(client);
		char key[32], loadout[48], roleKey[32];
		FormatEx(key, sizeof(key), "loadout_%s", g_sSlotNames[s]);
		if (!TF2CC_GetRoleString(role, key, loadout, sizeof(loadout)))
			loadout[0] = '\0';
		TF2CC_GetRoleKey(role, roleKey, sizeof(roleKey));
		int idx = WEAPON_NONE, score = -1;
		WeaponDef w;
		for (int i = 0; i < g_Weapons.Length; i++)
		{
			g_Weapons.GetArray(i, w);
			if (w.itemdef != itemdef || !StrEqual(w.classname, cls) || w.slot != s)
				continue;
			int sc = StrEqual(w.id, loadout) ? 2 : (StrContains(w.roles, roleKey) != -1 ? 1 : 0);
			if (sc > score)
			{
				score = sc;
				idx = i;
			}
		}
		if (idx >= 0)
			g_Weapons.GetArray(idx, w);
		int maxReserve = idx >= 0 && w.reserve > 0 ? w.reserve : DefaultReserve(ent, idx >= 0 ? w.family : 0);
		StoreSlot(client, s, idx >= 0 ? idx : STOCK_ITEM, itemdef, ent, maxReserve);
		int type = GetEntProp(ent, Prop_Send, "m_iPrimaryAmmoType");
		g_Inv[client][s].reserve = type > 0 ? GetEntProp(client, Prop_Send, "m_iAmmo", _, type) : 0;
	}
}

/**
 * Role players only hold what tf2cc granted: weapons equipped by other plugins
 * (e.g. GiveBotsMoreWeapons on post_inventory_application, keyed on class)
 * are removed next frame.
 */
public void Hook_WeaponEquipPost(int client, int weapon)
{
	if (g_bGranting[client] || weapon <= MaxClients || !g_cvStripForeign.BoolValue || TF2CC_GetRole(client) == TF2CC_ROLE_NONE)
		return;
	// Not in the same frame: GiveBotsMoreWeapons is still working on the weapon
	// it just equipped (removing it immediately crashed srcds on bot joins).
	CreateTimer(2.0, Timer_StripForeign, EntIndexToEntRef(weapon), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_StripForeign(Handle timer, int ref)
{
	Frame_StripForeign(ref);
	return Plugin_Stop;
}

public void Frame_StripForeign(int ref)
{
	int weapon = EntRefToEntIndex(ref);
	if (weapon <= MaxClients)
		return;
	int client = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || TF2CC_GetRole(client) == TF2CC_ROLE_NONE)
		return;
	if (SlotOfEntity(client, weapon) >= 0)
		return;   // ours after all
	if (GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") == weapon)
		SwitchToBest(client);
	// Its extra wearables (banner backpack, shield, ...) would otherwise linger.
	static const char extras[][] = { "m_hExtraWearable", "m_hExtraWearableViewModel" };
	for (int i = 0; i < sizeof(extras); i++)
	{
		if (!HasEntProp(weapon, Prop_Send, extras[i]))
			continue;
		int extra = GetEntPropEnt(weapon, Prop_Send, extras[i]);
		if (extra > MaxClients)
			AcceptEntityInput(extra, "Kill");
	}
	RemovePlayerItem(client, weapon);
	AcceptEntityInput(weapon, "Kill");
}

public void OnClientDisconnect(int client)
{
	RemoveOverlay(client);
	ClearInventory(client);
}

void ClearInventory(int client)
{
	for (int s = 0; s < SLOT_COUNT; s++)
	{
		g_Inv[client][s].weapon = WEAPON_NONE;
		g_Inv[client][s].itemdef = -1;
		g_Inv[client][s].entRef = INVALID_ENT_REFERENCE;
		g_Inv[client][s].clip = -1;
		g_Inv[client][s].reserve = 0;
		g_Inv[client][s].maxReserve = 0;
	}
	g_iLastActive[client] = INVALID_ENT_REFERENCE;
}

/* ========================================================================= */
/* Config                                                                    */
/* ========================================================================= */

void LoadWeapons()
{
	if (g_Weapons != null)
	{
		WeaponDef old;
		for (int i = 0; i < g_Weapons.Length; i++)
		{
			g_Weapons.GetArray(i, old);
			delete old.sounds;
		}
	}
	delete g_Weapons;
	delete g_Attrs;
	g_Weapons = new ArrayList(sizeof(WeaponDef));
	g_Attrs = new ArrayList(sizeof(AttrDef));

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), CONFIG_WEAPONS);
	KeyValues kv = new KeyValues("tf2cc_weapons");
	if (!kv.ImportFromFile(path))
	{
		LogError("tf2cc_weapons: cannot read %s", path);
		delete kv;
		return;
	}

	if (kv.GotoFirstSubKey())
	{
		do
		{
			WeaponDef w;
			kv.GetSectionName(w.id, sizeof(w.id));
			if (kv.GetNum("enabled", 1) == 0)
				continue;
			kv.GetString("name", w.name, sizeof(w.name), w.id);
			kv.GetString("roles", w.roles, sizeof(w.roles), "mercenary");
			char slot[16];
			kv.GetString("slot", slot, sizeof(slot), "primary");
			w.slot = SlotFromName(slot);
			kv.GetString("classname", w.classname, sizeof(w.classname));
			w.itemdef = kv.GetNum("itemdef", -1);
			char fam[16];
			kv.GetString("arms_family", fam, sizeof(fam));
			w.family = ClassFromName(fam);
			kv.GetString("worldmodel", w.worldModel, sizeof(w.worldModel));
			kv.GetString("viewmodel", w.viewModel, sizeof(w.viewModel));
			kv.GetString("viewmodel_generated", w.viewModelGen, sizeof(w.viewModelGen));
			kv.GetString("stock_classes", w.stockClasses, sizeof(w.stockClasses));
			kv.GetString("stock_model", w.stockModel, sizeof(w.stockModel));
			kv.GetString("viewmodel_mode", w.vmMode, sizeof(w.vmMode));
			char tierStr[4];
			kv.GetString("tier", tierStr, sizeof(tierStr), "C");
			w.tier = tierStr[0] == 'S' ? 3 : tierStr[0] == 'A' ? 2 : tierStr[0] == 'B' ? 1 : 0;
			kv.GetString("special", w.special, sizeof(w.special));
			w.specialValue = kv.GetFloat("special_value", 0.0);
			w.clip = kv.GetNum("clip", -1);
			w.reserve = kv.GetNum("reserve", -1);
			w.pickupWeight = kv.GetFloat("pack_weight", 0.0);
			w.droppable = kv.GetNum("droppable", 1) != 0;
			w.alwaysDrop = kv.GetNum("always_drop", 0) != 0;
			w.noAltFire = kv.GetNum("no_altfire", 0) != 0;
			w.attrStart = g_Attrs.Length;
			w.attrCount = 0;
			if (kv.JumpToKey("attributes"))
			{
				if (kv.GotoFirstSubKey(false))
				{
					do
					{
						AttrDef a;
						kv.GetSectionName(a.name, sizeof(a.name));
						a.value = kv.GetFloat(NULL_STRING);
						g_Attrs.PushArray(a);
						w.attrCount++;
					}
					while (kv.GotoNextKey(false));
					kv.GoBack();
				}
				kv.GoBack();
			}
			// Profile: "source" (OF/TF2C-accurate, default) or "marxvee" (legacy
			// MarxVee tuning from the weapon's "marxvee" block). Per-weapon
			// "profile" overrides tf2cc_weapon_profile.
			char prof[16];
			kv.GetString("profile", prof, sizeof(prof));
			if (!prof[0])
				g_cvProfile.GetString(prof, sizeof(prof));
			if (StrEqual(prof, "marxvee", false) && kv.JumpToKey("marxvee"))
			{
				w.clip = kv.GetNum("clip", w.clip);
				w.reserve = kv.GetNum("reserve", w.reserve);
				kv.GetString("special", w.special, sizeof(w.special), w.special);
				w.specialValue = kv.GetFloat("special_value", w.specialValue);
				if (kv.JumpToKey("attributes"))
				{
					w.attrStart = g_Attrs.Length;
					w.attrCount = 0;
					if (kv.GotoFirstSubKey(false))
					{
						do
						{
							AttrDef a;
							kv.GetSectionName(a.name, sizeof(a.name));
							a.value = kv.GetFloat(NULL_STRING);
							g_Attrs.PushArray(a);
							w.attrCount++;
						}
						while (kv.GotoNextKey(false));
						kv.GoBack();
					}
					kv.GoBack();
				}
				kv.GoBack();
			}

			w.sounds = null;
			w.soundsLoop = kv.GetNum("sounds_loop", 0) != 0;
			if (kv.JumpToKey("sounds"))
			{
				if (kv.GotoFirstSubKey())
				{
					w.sounds = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
					char find[PLATFORM_MAX_PATH], repl[PLATFORM_MAX_PATH];
					do
					{
						kv.GetString("find", find, sizeof(find));
						kv.GetString("replace", repl, sizeof(repl));
						if (!find[0] || !repl[0])
							continue;
						NormaliseSample(find);
						w.sounds.PushString(find);
						w.sounds.PushString(repl);
					}
					while (kv.GotoNextKey());
					kv.GoBack();
				}
				kv.GoBack();
			}
			if (w.slot < 0 || w.classname[0] == '\0' || w.itemdef < 0)
			{
				LogError("tf2cc_weapons: weapon '%s' needs slot, classname and itemdef", w.id);
				continue;
			}
			g_Weapons.PushArray(w);
		}
		while (kv.GotoNextKey());
	}
	delete kv;
}

int SlotFromName(const char[] name)
{
	for (int i = 0; i < SLOT_COUNT; i++)
		if (StrEqual(name, g_sSlotNames[i], false))
			return i;
	return -1;
}

int ClassFromName(const char[] name)
{
	if (name[0] == '\0')
		return 0;
	for (int i = 1; i <= 9; i++)
		if (StrEqual(name, g_sClassArmsName[i], false) || StrEqual(name, g_sClassSchemaName[i], false))
			return i;
	if (StrEqual(name, "heavyweapons", false))
		return 6;
	return 0;
}

int FindWeaponById(const char[] id)
{
	WeaponDef w;
	for (int i = 0; i < g_Weapons.Length; i++)
	{
		g_Weapons.GetArray(i, w);
		if (StrEqual(w.id, id, false))
			return i;
	}
	return WEAPON_NONE;
}

bool WeaponAllowedForRole(int weapon, int role)
{
	WeaponDef w;
	g_Weapons.GetArray(weapon, w);
	char key[TF2CC_ROLE_KEY_LEN];
	TF2CC_GetRoleKey(role, key, sizeof(key));
	char parts[8][TF2CC_ROLE_KEY_LEN];
	int n = ExplodeString(w.roles, ",", parts, sizeof(parts), sizeof(parts[]));
	for (int i = 0; i < n; i++)
	{
		TrimString(parts[i]);
		if (StrEqual(parts[i], key, false) || StrEqual(parts[i], "all", false))
			return true;
	}
	return false;
}

void PrecacheWeaponModels()
{
	if (g_Weapons == null)
		return;
	WeaponDef w;
	for (int i = 0; i < g_Weapons.Length; i++)
	{
		g_Weapons.GetArray(i, w);
		if (w.worldModel[0] && FileExists(w.worldModel, true))
			PrecacheModel(w.worldModel, true);
		if (w.viewModel[0] && FileExists(w.viewModel, true))
			PrecacheModel(w.viewModel, true);
		if (w.viewModelGen[0] && FileExists(w.viewModelGen, true))
			PrecacheModel(w.viewModelGen, true);
		if (w.stockClasses[0] && w.viewModelGen[0])
		{
			static const char roles[][] = { "primary", "secondary", "melee" };
			char alt[PLATFORM_MAX_PATH];
			for (int r = 0; r < sizeof(roles); r++)
				if (RoleViewModel(w.viewModelGen, roles[r], alt, sizeof(alt)) && FileExists(alt, true))
					PrecacheModel(alt, true);
		}
		if (w.sounds != null)
		{
			char repl[PLATFORM_MAX_PATH];
			for (int j = 1; j < w.sounds.Length; j += 2)
			{
				w.sounds.GetString(j, repl, sizeof(repl));
				PrecacheSound(repl, true);
			}
		}
	}
}

/* ========================================================================= */
/* Schema: read items_game.txt from disk (auto-adapts to every TF2 update)   */
/* ========================================================================= */

void LoadSchema()
{
	delete g_SchemaItems;
	delete g_SchemaPrefabs;
	g_SchemaItems = new StringMap();
	g_SchemaPrefabs = new StringMap();

	float start = GetEngineTime();
	KeyValues kv = new KeyValues("items_game");
	if (!kv.ImportFromFile(ITEMS_GAME))
	{
		LogError("tf2cc_weapons: cannot parse %s; stock pickups disabled", ITEMS_GAME);
		delete kv;
		return;
	}

	if (kv.JumpToKey("prefabs"))
	{
		ReadSchemaSection(kv, g_SchemaPrefabs);
		kv.GoBack();
	}
	if (kv.JumpToKey("items"))
	{
		ReadSchemaSection(kv, g_SchemaItems);
		kv.GoBack();
	}
	delete kv;
	g_bSchemaLoaded = true;
	LogMessage("tf2cc_weapons: schema loaded (%d items, %d prefabs) in %.2fs",
		g_SchemaItems.Size, g_SchemaPrefabs.Size, GetEngineTime() - start);
}

void ReadSchemaSection(KeyValues kv, StringMap into)
{
	if (!kv.GotoFirstSubKey())
		return;
	char key[96];
	do
	{
		kv.GetSectionName(key, sizeof(key));
		SchemaItem it;
		kv.GetString("item_class", it.itemClass, sizeof(it.itemClass));
		kv.GetString("item_slot", it.itemSlot, sizeof(it.itemSlot));
		kv.GetString("model_player", it.model, sizeof(it.model));
		kv.GetString("prefab", it.prefab, sizeof(it.prefab));
		kv.GetString("anim_slot", it.animSlot, sizeof(it.animSlot));
		if (kv.JumpToKey("used_by_classes"))
		{
			if (kv.GotoFirstSubKey(false))
			{
				char cls[24];
				do
				{
					kv.GetSectionName(cls, sizeof(cls));
					if (it.usedBy[0])
						StrCat(it.usedBy, sizeof(it.usedBy), ",");
					StrCat(it.usedBy, sizeof(it.usedBy), cls);
				}
				while (kv.GotoNextKey(false));
				kv.GoBack();
			}
			kv.GoBack();
		}
		into.SetArray(key, it, sizeof(it));
	}
	while (kv.GotoNextKey());
	kv.GoBack();
}

/** Resolve an item through its (possibly multiple, space-separated) prefabs. */
bool ResolveSchemaItem(int itemdef, SchemaItem out)
{
	if (!g_bSchemaLoaded)
		return false;
	char key[16];
	IntToString(itemdef, key, sizeof(key));
	SchemaItem it;
	if (!g_SchemaItems.GetArray(key, it, sizeof(it)))
		return false;
	out = it;
	MergePrefabs(out, it.prefab, 0);
	return true;
}

void MergePrefabs(SchemaItem out, const char[] prefabList, int depth)
{
	if (depth > 8 || prefabList[0] == '\0')
		return;
	char names[6][96];
	int n = ExplodeString(prefabList, " ", names, sizeof(names), sizeof(names[]));
	for (int i = 0; i < n; i++)
	{
		if (names[i][0] == '\0')
			continue;
		SchemaItem p;
		if (!g_SchemaPrefabs.GetArray(names[i], p, sizeof(p)))
			continue;
		if (!out.itemClass[0]) strcopy(out.itemClass, sizeof(out.itemClass), p.itemClass);
		if (!out.itemSlot[0]) strcopy(out.itemSlot, sizeof(out.itemSlot), p.itemSlot);
		if (!out.usedBy[0]) strcopy(out.usedBy, sizeof(out.usedBy), p.usedBy);
		if (!out.model[0]) strcopy(out.model, sizeof(out.model), p.model);
		if (!out.animSlot[0]) strcopy(out.animSlot, sizeof(out.animSlot), p.animSlot);
		MergePrefabs(out, p.prefab, depth + 1);
	}
}

/** Pick the donor class for a stock item: preferred class if allowed, else first user. */
int DonorClassForItem(SchemaItem it, int preferred = 0)
{
	char parts[10][24];
	int n = ExplodeString(it.usedBy, ",", parts, sizeof(parts), sizeof(parts[]));
	int first = 0;
	for (int i = 0; i < n; i++)
	{
		int c = ClassFromName(parts[i]);
		if (!c)
			continue;
		if (!first)
			first = c;
		if (c == preferred)
			return c;
	}
	return first;
}

/** Mirror of stock TranslateWeaponEntForClass (tf_shareddefs.cpp). */
void TranslateItemClass(const char[] itemClass, int cls, char[] out, int maxlen)
{
	strcopy(out, maxlen, itemClass);
	if (StrEqual(itemClass, "tf_weapon_shotgun"))
	{
		switch (cls)
		{
			case 3: strcopy(out, maxlen, "tf_weapon_shotgun_soldier");
			case 6: strcopy(out, maxlen, "tf_weapon_shotgun_hwg");
			case 7: strcopy(out, maxlen, "tf_weapon_shotgun_pyro");
			default: strcopy(out, maxlen, "tf_weapon_shotgun_primary");
		}
	}
	else if (StrEqual(itemClass, "tf_weapon_pistol"))
	{
		strcopy(out, maxlen, cls == 1 ? "tf_weapon_pistol_scout" : "tf_weapon_pistol");
	}
	else if (StrEqual(itemClass, "tf_weapon_shovel") || StrEqual(itemClass, "tf_weapon_bottle"))
	{
		strcopy(out, maxlen, cls == 4 ? "tf_weapon_bottle" : "tf_weapon_shovel");
	}
	else if (StrEqual(itemClass, "saxxy"))
	{
		static const char saxxy[][] = { "tf_weapon_bat", "tf_weapon_bat", "tf_weapon_club", "tf_weapon_shovel", "tf_weapon_bottle",
			"tf_weapon_bonesaw", "tf_weapon_fireaxe", "tf_weapon_fireaxe", "tf_weapon_knife", "tf_weapon_wrench" };
		strcopy(out, maxlen, saxxy[cls < 0 || cls > 9 ? 0 : cls]);
	}
	else if (StrEqual(itemClass, "tf_weapon_throwable"))
	{
		strcopy(out, maxlen, cls == 5 ? "tf_weapon_throwable_primary" : "tf_weapon_throwable_secondary");
	}
	else if (StrEqual(itemClass, "tf_weapon_parachute"))
	{
		strcopy(out, maxlen, cls == 4 ? "tf_weapon_parachute_primary" : "tf_weapon_parachute_secondary");
	}
	else if (StrEqual(itemClass, "tf_weapon_revolver"))
	{
		strcopy(out, maxlen, cls == 9 ? "tf_weapon_revolver_secondary" : "tf_weapon_revolver");
	}
}

/** Map a stock item_slot to the Mercenary's three combat slots. */
int MercSlotForStockItem(SchemaItem it)
{
	// Merc's shotgun is a secondary: the Engineer-only shotguns (primary for
	// him) are granted as the Soldier's secondary shotgun (GiveStockItem).
	if (StrEqual(it.itemClass, "tf_weapon_shotgun_primary") || StrEqual(it.itemClass, "tf_weapon_shotgun"))
		return SLOT_SECONDARY;
	if (StrEqual(it.itemSlot, "primary"))   return SLOT_PRIMARY;
	if (StrEqual(it.itemSlot, "secondary")) return SLOT_SECONDARY;
	if (StrEqual(it.itemSlot, "melee"))     return SLOT_MELEE;
	return -1; // pda, building, action, taunt... are not combat slots
}

/** Classnames that need class-specific engine code a class-10 owner cannot run. */
bool IsBlockedStockClassname(const char[] classname)
{
	static const char blocked[][] =
	{
		"tf_weapon_builder", "tf_weapon_sapper", "tf_weapon_pda_engineer_build",
		"tf_weapon_pda_engineer_destroy", "tf_weapon_pda_spy", "tf_weapon_invis",
		"tf_weapon_spellbook", "tf_weapon_grapplinghook", "tf_weapon_rocketpack",
		"tf_weapon_parachute_primary", "tf_weapon_parachute_secondary", "tf_wearable",
		"tf_wearable_demoshield", "tf_wearable_razorback", "tf_powerup_bottle"
	};
	for (int i = 0; i < sizeof(blocked); i++)
		if (StrEqual(classname, blocked[i]))
			return true;
	return false;
}

/* ========================================================================= */
/* Weapon creation                                                           */
/* ========================================================================= */

/**
 * Create, configure and equip a weapon. family = donor class for arms/ammo.
 * Returns the entity or -1.
 */
int CreateAndEquip(int client, const char[] classname, int itemdef, int family, int weaponIdx)
{
	int ent = CreateEntityByName(classname);
	if (ent == -1)
	{
		LogError("tf2cc_weapons: CreateEntityByName(%s) failed", classname);
		return -1;
	}

	SetEntProp(ent, Prop_Send, "m_iItemDefinitionIndex", itemdef);
	SetEntProp(ent, Prop_Send, "m_bInitialized", 1);
	SetEntProp(ent, Prop_Send, "m_iEntityQuality", 0);
	SetEntProp(ent, Prop_Send, "m_iEntityLevel", 1);
	// Owner's account id: stock ValidateWeapons would otherwise spawn
	// tf_dropped_weapon copies of every class-10 weapon on resupply.
	SetEntProp(ent, Prop_Send, "m_iAccountID", GetSteamAccountID(client, false));
	SetEntProp(ent, Prop_Send, "m_bValidatedAttachedEntity", 1);

	g_bGranting[client] = true;
	if (!DispatchSpawn(ent))
	{
		g_bGranting[client] = false;
		RemoveEntity(ent);
		return -1;
	}
	EquipPlayerWeapon(client, ent);
	g_bGranting[client] = false;

	WeaponDef w;
	bool custom = weaponIdx >= 0;
	if (custom)
		g_Weapons.GetArray(weaponIdx, w);

	// Attributes.
	if (custom && g_bTF2Attributes)
	{
		AttrDef a;
		for (int i = 0; i < w.attrCount; i++)
		{
			g_Attrs.GetArray(w.attrStart + i, a);
			ApplyAttr(ent, a.name, a.value);
		}
		TF2Attrib_ClearCache(ent);
	}

	// First-person arms.
	char stockVM[PLATFORM_MAX_PATH];
	if (!custom)
		StockViewModel(classname, itemdef, stockVM, sizeof(stockVM));
	ApplyArms(client, ent, family, custom ? (w.viewModelGen[0] ? w.viewModelGen : w.viewModel) : stockVM, custom ? w.vmMode : "");

	// Third-person / dropped world model.
	if (custom && w.worldModel[0] && IsModelPrecached(w.worldModel))
	{
		// m_iWorldModelIndex only: C_BaseCombatWeapon::CalcOverrideModelIndex
		// uses it for third person. m_nModelIndexOverrides[0] would replace the
		// owner's first-person weapon model too (C_BaseEntity::ValidateModelIndex)
		// and client prediction would pick viewmodel sequences from the w_model.
		SetEntProp(ent, Prop_Send, "m_iWorldModelIndex", PrecacheModel(w.worldModel));
	}
	return ent;
}

/** Set the predicted custom viewmodel for this weapon from the role's arms config. */
/**
 * First-person viewmodel selection (tf2cc_viewmodel_mode / per-weapon
 * "viewmodel_mode"):
 *  custom - the weapon's donor-retargeted OF/TF2C v_model (arms + weapon baked
 *           in, tools/gen_viewmodels.py) via the predicted
 *           m_nCustomViewmodelModelIndex, and m_bBeingRepurposedForTaunt so the
 *           client does not also bonemerge the donor's stock c_model
 *           (CTFWeaponBase::AttachmentModelsShouldBeVisible, tf_weaponbase.h:588).
 *  family - donor-family role arms + the donor's stock weapon model.
 *  auto   - custom when a generated v_model exists, otherwise family.
 */
void ApplyArms(int client, int weapon, int family, const char[] customVM, const char[] perWeaponMode = "")
{
	char vmode[16];
	if (perWeaponMode[0])
		strcopy(vmode, sizeof(vmode), perWeaponMode);
	else
		g_cvCustomVM.GetString(vmode, sizeof(vmode));

	if (customVM[0] && !StrEqual(vmode, "family", false) && IsModelPrecached(customVM))
	{
		SetWeaponViewModel(weapon, customVM);
		SetEntProp(weapon, Prop_Send, "m_bBeingRepurposedForTaunt", 1);
		return;
	}
	if (HasEntProp(weapon, Prop_Send, "m_bBeingRepurposedForTaunt"))
		SetEntProp(weapon, Prop_Send, "m_bBeingRepurposedForTaunt", 0);

	int role = TF2CC_GetRole(client);
	if (role == TF2CC_ROLE_NONE || family < 1 || family > 9)
		return;

	char mode[16], dir[PLATFORM_MAX_PATH], path[PLATFORM_MAX_PATH];
	TF2CC_GetRoleString(role, "arms_mode", mode, sizeof(mode));

	if (StrEqual(mode, "family", false) && TF2CC_GetRoleString(role, "arms_family_dir", dir, sizeof(dir)))
	{
		FormatEx(path, sizeof(path), "%s/c_%s_arms.mdl", dir, g_sClassArmsName[family]);
		if (FileExists(path, true))
		{
			SetWeaponViewModel(weapon, path);
			return;
		}
		LogError("tf2cc_weapons: donor arms missing: %s", path);
	}

	// overlay (and fallback): stock donor arms animate, role arms are bonemerged on top.
	FormatEx(path, sizeof(path), "models/weapons/c_models/c_%s_arms.mdl", g_sClassArmsName[family]);
	SetWeaponViewModel(weapon, path);
}

/**
 * CBaseCombatWeapon::SetIdealActivity picks the sequence NUMBER from the
 * weapon entity's own model and sends that number to the viewmodel. Equip set
 * the weapon's model to GetViewModel() = the class-10 hands (c_medic_arms), so
 * the numbers came from the wrong model: invalid indices on the custom
 * viewmodel (endless draw restarts) and -1 for missing activities (no reload).
 * Keep the weapon's own model identical to what the viewmodel draws.
 */
void SetWeaponViewModel(int weapon, const char[] path)
{
	int idx = PrecacheModel(path, true);
	SetEntProp(weapon, Prop_Send, "m_nCustomViewmodelModelIndex", idx);
	// C_TFWeaponBase::UpdateModelIndex gives the client's first-person weapon
	// m_iViewModelIndex; it still held the class hands, so client prediction
	// used c_medic_arms sequences (flicker on every idle loop / switch).
	SetEntProp(weapon, Prop_Send, "m_iViewModelIndex", idx);
	SetEntityModel(weapon, path);
}

/* ========================================================================= */
/* Loadout & inventory                                                       */
/* ========================================================================= */

public void TF2CC_OnRoleSpawned(int client, int role)
{
	ClearInventory(client);
	TF2_RemoveAllWeapons(client);
	RemoveOverlay(client);

	char key[32], id[48];
	for (int s = 0; s < SLOT_COUNT; s++)
	{
		FormatEx(key, sizeof(key), "loadout_%s", g_sSlotNames[s]);
		if (!TF2CC_GetRoleString(role, key, id, sizeof(id)) || !id[0])
			continue;
		int idx = FindWeaponById(id);
		if (idx == WEAPON_NONE)
		{
			LogError("tf2cc_weapons: role loadout references unknown weapon '%s'", id);
			continue;
		}
		GiveCustomWeapon(client, idx, -1, -1, false);
	}
	SwitchToBest(client);
	UpdateOverlay(client);
	RequestFrame(Frame_ApplyVariant, GetClientUserId(client));
}

public void TF2CC_OnRoleCleared(int client, int oldRole)
{
	RemoveOverlay(client);
	// Our weapons carry the owner's account id (so resupply keeps them), which
	// also makes them survive a change to a stock class: remove them here.
	if (IsClientInGame(client))
	{
		for (int s = 0; s < SLOT_COUNT; s++)
		{
			int ent = EntRefToEntIndex(g_Inv[client][s].entRef);
			if (ent > MaxClients && GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity") == client)
			{
				RemovePlayerItem(client, ent);
				AcceptEntityInput(ent, "Kill");
			}
		}
		int vm = GetEntPropEnt(client, Prop_Send, "m_hViewModel");
		if (vm > MaxClients)
			SetEntProp(vm, Prop_Send, "m_fEffects", GetEntProp(vm, Prop_Send, "m_fEffects") & ~EF_NODRAW);
	}
	ClearInventory(client);
}

/** Grant a configured weapon into its slot, replacing (and optionally dropping) the occupant. */
bool GiveCustomWeapon(int client, int weaponIdx, int clip, int reserve, bool dropOld)
{
	WeaponDef w;
	g_Weapons.GetArray(weaponIdx, w);
	ReplaceSlot(client, w.slot, dropOld);

	int family = w.family;
	if (!family)
	{
		SchemaItem it;
		if (ResolveSchemaItem(w.itemdef, it))
			family = DonorClassForItem(it);
	}

	// Entity-less perks (legacy utility items such as Hoarder's Stash): only the
	// inventory record exists; tf2cc_specials implements the effect.
	if (StrEqual(w.classname, "none"))
	{
		g_Inv[client][w.slot].weapon = weaponIdx;
		g_Inv[client][w.slot].itemdef = -1;
		g_Inv[client][w.slot].entRef = INVALID_ENT_REFERENCE;
		g_Inv[client][w.slot].maxReserve = 0;
		Call_StartForward(g_fwdPerk);
		Call_PushCell(client);
		Call_PushString(w.special);
		Call_PushCell(true);
		Call_Finish();
		return true;
	}

	int ent = CreateAndEquip(client, w.classname, w.itemdef, family, weaponIdx);
	if (ent == -1)
		return false;

	int maxReserve = w.reserve >= 0 ? w.reserve : DefaultReserve(ent, family);
	StoreSlot(client, w.slot, weaponIdx, w.itemdef, ent, maxReserve);
	if (w.clip >= 0)
		SetEntProp(ent, Prop_Send, "m_iClip1", clip >= 0 ? clip : w.clip);
	else if (clip >= 0)
		SetEntProp(ent, Prop_Send, "m_iClip1", clip);
	else
	{
		// The weapon spawned with the base clip; our clip attributes raised the max.
		int base = GetEntProp(ent, Prop_Send, "m_iClip1");
		float mult = ClipMultiplier(weaponIdx);
		if (base > 0 && mult != 1.0)
			SetEntProp(ent, Prop_Send, "m_iClip1", RoundToFloor(float(base) * mult + 0.001));
	}
	SetSlotReserve(client, w.slot, reserve >= 0 ? reserve : maxReserve);
	RequestFrame(Frame_PostGrant, GetClientUserId(client));
	return true;
}

/** Grant a stock item by definition index (Mercenary pickup of any class's weapon). */
bool GiveStockItem(int client, int itemdef, int preferredClass, int clip, int reserve, bool dropOld)
{
	SchemaItem it;
	if (!ResolveSchemaItem(itemdef, it))
		return false;
	int slot = MercSlotForStockItem(it);
	if (slot < 0)
		return false;
	int family = DonorClassForItem(it, preferredClass);
	if (!family)
		return false;
	char classname[64];
	TranslateItemClass(it.itemClass, family, classname, sizeof(classname));
	if (!classname[0] || IsBlockedStockClassname(classname))
		return false;
	if (slot == SLOT_SECONDARY && StrEqual(classname, "tf_weapon_shotgun_primary"))
	{
		strcopy(classname, sizeof(classname), "tf_weapon_shotgun_soldier");
		family = 3;   // TFClass_Soldier: secondary-slot shotgun script, ammo and arms
	}

	ReplaceSlot(client, slot, dropOld);
	int ent = CreateAndEquip(client, classname, itemdef, family, STOCK_ITEM);
	if (ent == -1)
		return false;
	int maxReserve = DefaultReserve(ent, family);
	if (IsConsumable(ent))
	{
		// Class 10's max ammo is 0 for every type, so stock GiveAmmo would leave
		// throwables/lunchboxes empty: carry one charge.
		if (maxReserve < 1)
			maxReserve = 1;
		reserve = maxReserve;
	}
	StoreSlot(client, slot, STOCK_ITEM, itemdef, ent, maxReserve);
	if (clip >= 0)
		SetEntProp(ent, Prop_Send, "m_iClip1", clip);
	SetSlotReserve(client, slot, reserve >= 0 ? reserve : maxReserve);
	RequestFrame(Frame_PostGrant, GetClientUserId(client));
	return true;
}

/** Recharging single-use items (jars, cleaver, lunchboxes): effect-bar weapons using ammo. */
bool IsConsumable(int ent)
{
	char cls[64];
	GetEntityClassname(ent, cls, sizeof(cls));
	return StrContains(cls, "tf_weapon_jar") == 0 || StrEqual(cls, "tf_weapon_cleaver")
		|| StrContains(cls, "tf_weapon_lunchbox") == 0 || StrEqual(cls, "tf_weapon_bat_wood") || StrEqual(cls, "tf_weapon_bat_giftwrap");
}

/**
 * The effect bar's recharge ends in GiveAmmo(1), clamped to class 10's max 0;
 * give the charge back ourselves once m_flEffectBarRegenTime has passed.
 */
void RechargeConsumables(int client)
{
	float now = GetGameTime();
	for (int s = 0; s < SLOT_COUNT; s++)
	{
		int ent = EntRefToEntIndex(g_Inv[client][s].entRef);
		if (ent <= MaxClients || !HasEntProp(ent, Prop_Send, "m_flEffectBarRegenTime") || !IsConsumable(ent))
			continue;
		int type = GetEntProp(ent, Prop_Send, "m_iPrimaryAmmoType");
		if (type <= 0 || GetEntProp(client, Prop_Send, "m_iAmmo", _, type) > 0)
			continue;
		float regen = GetEntPropFloat(ent, Prop_Send, "m_flEffectBarRegenTime");
		if (regen > 0.0 && now >= regen)
			SetSlotReserve(client, s, g_Inv[client][s].maxReserve > 0 ? g_Inv[client][s].maxReserve : 1);
	}
}

int DefaultReserve(int weapon, int family)
{
	int type = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
	if (family < 1 || family > 9)
		return 0;
	if (type == TF_AMMO_PRIMARY)
		return g_iClassAmmoMax[family][0];
	if (type == TF_AMMO_SECONDARY)
		return g_iClassAmmoMax[family][1];
	return 0;
}

void StoreSlot(int client, int slot, int weaponIdx, int itemdef, int ent, int maxReserve)
{
	g_Inv[client][slot].weapon = weaponIdx;
	g_Inv[client][slot].itemdef = itemdef;
	g_Inv[client][slot].entRef = EntIndexToEntRef(ent);
	g_Inv[client][slot].maxReserve = maxReserve;
	g_Inv[client][slot].clip = -1;
}

/** Remove the occupant of a slot through the game's own RemovePlayerItem. */
void ReplaceSlot(int client, int slot, bool dropOld)
{
	int ent = EntRefToEntIndex(g_Inv[client][slot].entRef);
	if (ent > MaxClients && IsValidEntity(ent))
	{
		SyncAmmoFromEntity(client, slot);
		if (dropOld)
			SpawnPickupFromSlot(client, slot, 0.0);
		RemovePlayerItem(client, ent);
		RemoveEntity(ent);
	}
	else
	{
		// Something else may own a weapon in this engine slot; remove it so the
		// Mercenary never exceeds one weapon per slot.
		int other = slot <= SLOT_MELEE ? GetPlayerWeaponSlot(client, slot) : -1;
		if (other > MaxClients)
		{
			RemovePlayerItem(client, other);
			RemoveEntity(other);
		}
	}
	g_Inv[client][slot].weapon = WEAPON_NONE;
	g_Inv[client][slot].itemdef = -1;
	g_Inv[client][slot].entRef = INVALID_ENT_REFERENCE;
}

int SlotOfEntity(int client, int ent)
{
	int ref = EntIndexToEntRef(ent);
	for (int s = 0; s < SLOT_COUNT; s++)
		if (g_Inv[client][s].entRef == ref)
			return s;
	return -1;
}

void SwitchToBest(int client)
{
	for (int s = 0; s < SLOT_COUNT; s++)
	{
		int ent = EntRefToEntIndex(g_Inv[client][s].entRef);
		if (ent > MaxClients)
		{
			SwitchTo(client, ent);
			return;
		}
	}
}

/** Switch through the game's own Weapon_Switch path. */
void SwitchTo(int client, int weapon)
{
	char classname[64];
	GetEntityClassname(weapon, classname, sizeof(classname));
	FakeClientCommandEx(client, "use %s", classname);
}

/* ---------------- reserve ammo pool ---------------- */

void SyncAmmoFromEntity(int client, int slot)
{
	int ent = EntRefToEntIndex(g_Inv[client][slot].entRef);
	if (ent <= MaxClients)
		return;
	int type = GetEntProp(ent, Prop_Send, "m_iPrimaryAmmoType");
	int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (type > 0 && active == ent)
		g_Inv[client][slot].reserve = GetEntProp(client, Prop_Send, "m_iAmmo", _, type);
	g_Inv[client][slot].clip = GetEntProp(ent, Prop_Send, "m_iClip1");
}

void SetSlotReserve(int client, int slot, int amount)
{
	if (amount < 0) amount = 0;
	if (g_Inv[client][slot].maxReserve > 0 && amount > g_Inv[client][slot].maxReserve)
		amount = g_Inv[client][slot].maxReserve;
	g_Inv[client][slot].reserve = amount;
	int ent = EntRefToEntIndex(g_Inv[client][slot].entRef);
	if (ent <= MaxClients)
		return;
	int type = GetEntProp(ent, Prop_Send, "m_iPrimaryAmmoType");
	if (type <= 0)
		return;
	// Load into m_iAmmo when this weapon owns the ammo type right now.
	int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (active == ent || !OtherSlotSharesType(client, slot, type))
		SetEntProp(client, Prop_Send, "m_iAmmo", amount, _, type);
}

bool OtherSlotSharesType(int client, int slot, int type)
{
	for (int s = 0; s < SLOT_COUNT; s++)
	{
		if (s == slot)
			continue;
		int ent = EntRefToEntIndex(g_Inv[client][s].entRef);
		if (ent > MaxClients && GetEntProp(ent, Prop_Send, "m_iPrimaryAmmoType") == type)
			return true;
	}
	return false;
}

public void Hook_WeaponSwitchPost(int client, int weapon)
{
	g_flForceDonorSync[client] = GetGameTime() + 1.0;
	if (TF2CC_GetRole(client) == TF2CC_ROLE_NONE || !IsRoleClass(client))
		return;

	// Save the reserve of the weapon we left, load the reserve of the new one
	// (two Mercenary weapons may share an ammo type).
	int last = EntRefToEntIndex(g_iLastActive[client]);
	if (last > MaxClients && last != weapon)
	{
		int ls = SlotOfEntity(client, last);
		if (ls >= 0)
		{
			int type = GetEntProp(last, Prop_Send, "m_iPrimaryAmmoType");
			if (type > 0)
				g_Inv[client][ls].reserve = GetEntProp(client, Prop_Send, "m_iAmmo", _, type);
		}
	}
	if (weapon > MaxClients)
	{
		int ns = SlotOfEntity(client, weapon);
		if (ns >= 0)
		{
			int type = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
			if (type > 0)
				SetEntProp(client, Prop_Send, "m_iAmmo", g_Inv[client][ns].reserve, _, type);
		}
		g_iLastActive[client] = EntIndexToEntRef(weapon);
		ApplyModelVariant(client);

		// Deploy points the viewmodel at GetViewModel() = the class-10 hands
		// (c_medic_arms) first; go straight to the weapon's own viewmodel.
		int idx = GetEntProp(weapon, Prop_Send, "m_nCustomViewmodelModelIndex");
		int vm = GetEntPropEnt(client, Prop_Send, "m_hViewModel");
		if (idx > 0 && vm > MaxClients && GetEntProp(vm, Prop_Send, "m_nModelIndex") != idx)
		{
			char path[PLATFORM_MAX_PATH];
			ModelIndexToString(idx, path, sizeof(path));
			if (path[0])
				SetEntityModel(vm, path);
		}
	}
	UpdateOverlay(client);
}

/** Resupply/regenerate: stock ValidateWeapons removed every class-10 weapon. */
public void Event_Inventory(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!TF2CC_IsValidClient(client) || TF2CC_GetRole(client) == TF2CC_ROLE_NONE || g_bGranting[client])
		return;
	// Role players are class 10. Map scripts that cycle SetPlayerClass(1..9) +
	// Regenerate on round start (ctf_2fort_mvm_v4, trade_minecraft) fire this
	// event once per temporary class in a single frame; rebuilding the loadout
	// each time created ~40 entities per role player per round, all freed only
	// at frame end, and with ~10 role bots the burst passed the 2048-edict limit
	// (FATAL ERROR: ED_Alloc: no free edicts). Only the final class-10 pass counts.
	if (!IsRoleClass(client))
		return;
	// Same tick: post_inventory_application fires right after ValidateWeapons,
	// so the class-10 default hands (c_medic_arms) are never drawn - except in a
	// round-restart burst (see tf2cc_core ScheduleFinishRoleSpawn), where the
	// rebuilds are spread out so freed edicts can be reused in between.
	float now = GetEngineTime();
	if (now - g_flRematBurstStart > 1.0)
	{
		g_flRematBurstStart = now;
		g_iRematBurst = 0;
	}
	if (++g_iRematBurst > 3)
	{
		CreateTimer(0.6 + 0.06 * float(g_iRematBurst - 3), Timer_Rematerialize, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
		return;
	}
	Frame_Rematerialize(GetClientUserId(client));
}

public Action Timer_Rematerialize(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client && IsRoleClass(client))
		Frame_Rematerialize(userid);
	return Plugin_Stop;
}

public void Frame_Rematerialize(int userid)
{
	int client = GetClientOfUserId(userid);
	if (!client || !IsPlayerAlive(client) || TF2CC_GetRole(client) == TF2CC_ROLE_NONE)
		return;

	bool any = false;
	for (int s = 0; s < SLOT_COUNT; s++)
	{
		if (g_Inv[client][s].weapon == WEAPON_NONE)
			continue;
		int ent = EntRefToEntIndex(g_Inv[client][s].entRef);
		if (ent > MaxClients && GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity") == client)
		{
			SetSlotReserve(client, s, g_Inv[client][s].maxReserve); // resupply = full
			// Regenerate refilled the clip to the max WITHOUT our clip attributes
			// (they were wiped with the runtime attribute list): scale it back up.
			if (g_Inv[client][s].weapon >= 0 && ReapplyCustomAttributes(ent, g_Inv[client][s].weapon))
			{
				int clip = GetEntProp(ent, Prop_Send, "m_iClip1");
				float mult = ClipMultiplier(g_Inv[client][s].weapon);
				if (clip > 0 && mult != 1.0)
					SetEntProp(ent, Prop_Send, "m_iClip1", RoundToFloor(float(clip) * mult + 0.001));
			}
			continue;
		}
		int weaponIdx = g_Inv[client][s].weapon;
		int itemdef = g_Inv[client][s].itemdef;
		g_Inv[client][s].entRef = INVALID_ENT_REFERENCE;
		if (weaponIdx >= 0)
			GiveCustomWeapon(client, weaponIdx, -1, -1, false);
		else if (weaponIdx == STOCK_ITEM)
			GiveStockItem(client, itemdef, 0, -1, -1, false);
		any = true;
	}
	// Resupply restores the default loadout (DM pistol, crowbar) where a slot is
	// empty; the undroppable Fists count as a missing melee.
	int fists = FindWeaponById("merc_fists");
	for (int s = 0; s < SLOT_COUNT; s++)
	{
		bool fallback = s == SLOT_MELEE && fists != WEAPON_NONE && g_Inv[client][s].weapon == fists;
		if (g_Inv[client][s].weapon != WEAPON_NONE && !fallback)
			continue;
		char key[32], id[48];
		FormatEx(key, sizeof(key), "loadout_%s", g_sSlotNames[s]);
		if (!TF2CC_GetRoleString(TF2CC_GetRole(client), key, id, sizeof(id)) || !id[0])
			continue;
		int idx = FindWeaponById(id);
		if (idx == WEAPON_NONE || idx == g_Inv[client][s].weapon)
			continue;
		if (fallback)
			ReplaceSlot(client, s, false);
		if (GiveCustomWeapon(client, idx, -1, -1, false))
			any = true;
	}
	if (any)
		SwitchToBest(client);
	UpdateOverlay(client);
	// tf2cc_core re-applies the base role model on post_inventory_application.
	RequestFrame(Frame_ApplyVariant, GetClientUserId(client));
}

public void Frame_ApplyVariant(int userid)
{
	int client = GetClientOfUserId(userid);
	if (client)
		ApplyModelVariant(client);
}

/* ========================================================================= */
/* Overlay arms (roles without donor-family arm models, e.g. Civilian)       */
/* ========================================================================= */

void UpdateOverlay(int client)
{
	int role = TF2CC_GetRole(client);
	if (role == TF2CC_ROLE_NONE || !IsPlayerAlive(client))
	{
		RemoveOverlay(client);
		return;
	}
	// A map script is cycling the player through stock classes (see
	// Event_Inventory): no overlay/world-model churn until class 10 is back.
	if (!IsRoleClass(client))
		return;
	char mode[16], arms[PLATFORM_MAX_PATH];
	TF2CC_GetRoleString(role, "arms_mode", mode, sizeof(mode));
	if (!TF2CC_GetRoleString(role, "arms_model", arms, sizeof(arms)) || !FileExists(arms, true))
	{
		RemoveOverlay(client);
		return;
	}

	int vm = GetEntPropEnt(client, Prop_Send, "m_hViewModel");
	if (vm <= MaxClients)
		return;
	int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	// Bots have no view, and a hidden viewmodel breaks them: CBaseCombatCharacter::
	// Weapon_Switch re-deploys the held weapon when !IsWeaponVisible() (viewmodel
	// EF_NODRAW), and TFBot calls Weapon_Switch(gun) every update, so overlaid
	// stock pickups (minigun, grenade launcher...) never got past their deploy.
	if (IsFakeClient(client))
	{
		int e = EntRefToEntIndex(g_iArmsWearable[client]);
		if (e > MaxClients)
			RemoveEntity(e);
		e = EntRefToEntIndex(g_iWeaponWearable[client]);
		if (e > MaxClients)
			RemoveEntity(e);
		g_iArmsWearable[client] = INVALID_ENT_REFERENCE;
		g_iWeaponWearable[client] = INVALID_ENT_REFERENCE;
		SetEntProp(vm, Prop_Send, "m_fEffects", GetEntProp(vm, Prop_Send, "m_fEffects") & ~EF_NODRAW);
		UpdateWorldModel(client, active);
		return;
	}
	int armsIdx = PrecacheModel(arms, true);
	int armsEnt = EntRefToEntIndex(g_iArmsWearable[client]);

	// Custom OF/TF2C v_models are weapon-only (arm skeleton, no arm mesh): OF
	// bonemerges the class arm_model onto them. Same here, viewmodel visible.
	if (active > MaxClients && GetEntProp(active, Prop_Send, "m_bBeingRepurposedForTaunt"))
	{
		int wpn = EntRefToEntIndex(g_iWeaponWearable[client]);
		if (wpn > MaxClients)
			RemoveEntity(wpn);
		g_iWeaponWearable[client] = INVALID_ENT_REFERENCE;
		SetEntProp(vm, Prop_Send, "m_fEffects", GetEntProp(vm, Prop_Send, "m_fEffects") & ~EF_NODRAW);
		if (armsEnt <= MaxClients || GetEntProp(armsEnt, Prop_Send, "m_nModelIndex") != armsIdx)
		{
			if (armsEnt > MaxClients)
				RemoveEntity(armsEnt);
			armsEnt = CreateVMWearable(client, vm, armsIdx);
			g_iArmsWearable[client] = armsEnt > 0 ? EntIndexToEntRef(armsEnt) : INVALID_ENT_REFERENCE;
		}
		// An association with a repurposed weapon hides the wearable (CTFWearable::ShouldDraw).
		if (armsEnt > MaxClients)
			SetEntPropEnt(armsEnt, Prop_Send, "m_hWeaponAssociatedWith", -1);
		UpdateWorldModel(client, active);
		return;
	}
	UpdateWorldModel(client, active);
	if (!StrEqual(mode, "overlay", false))
	{
		RemoveOverlay(client);   // family arms already carry the role skin
		return;
	}

	// Stock donor arms keep animating (bones) but are hidden; role arms and the
	// weapon model are bonemerged on top (proven pattern, FortyTwo Randomizer).
	SetEntProp(vm, Prop_Send, "m_fEffects", GetEntProp(vm, Prop_Send, "m_fEffects") | EF_NODRAW);

	if (armsEnt <= MaxClients || GetEntProp(armsEnt, Prop_Send, "m_nModelIndex") != armsIdx)
	{
		if (armsEnt > MaxClients)
			RemoveEntity(armsEnt);
		armsEnt = CreateVMWearable(client, vm, armsIdx);
		g_iArmsWearable[client] = armsEnt > 0 ? EntIndexToEntRef(armsEnt) : INVALID_ENT_REFERENCE;
	}

	int wpnEnt = EntRefToEntIndex(g_iWeaponWearable[client]);
	if (active > MaxClients)
	{
		int wIdx = GetEntProp(active, Prop_Send, "m_iWorldModelIndex");
		if (wpnEnt <= MaxClients || GetEntProp(wpnEnt, Prop_Send, "m_nModelIndex") != wIdx)
		{
			if (wpnEnt > MaxClients)
				RemoveEntity(wpnEnt);
			wpnEnt = CreateVMWearable(client, vm, wIdx);
			g_iWeaponWearable[client] = wpnEnt > 0 ? EntIndexToEntRef(wpnEnt) : INVALID_ENT_REFERENCE;
		}
		if (wpnEnt > MaxClients)
			SetEntPropEnt(wpnEnt, Prop_Send, "m_hWeaponAssociatedWith", active);
		if (armsEnt > MaxClients)
			SetEntPropEnt(armsEnt, Prop_Send, "m_hWeaponAssociatedWith", active);
	}
	else if (wpnEnt > MaxClients)
	{
		RemoveEntity(wpnEnt);
		g_iWeaponWearable[client] = INVALID_ENT_REFERENCE;
	}
}

int CreateVMWearable(int client, int vm, int modelIndex)
{
	return CreateWearable(client, "tf_wearable_vm", modelIndex, vm);
}

/**
 * Cosmetic wearable (tf_wearable_vm on the viewmodel, tf_wearable on the
 * player), parented with bonemerge exactly like the Randomizer plugin does.
 * Never equipped through CBasePlayer::EquipWearable: an item-less wearable in
 * the player's wearable list crashed srcds (play-test 2026-11-10). Never tied
 * to a weapon with m_hWeaponAssociatedWith either: custom weapons carry
 * m_bBeingRepurposedForTaunt, which hides associated wearables
 * (CTFWearable::ShouldDraw); tf2cc adds/removes them on weapon switch.
 */
int CreateWearable(int client, const char[] classname, int modelIndex, int parent)
{
	int ent = CreateEntityByName(classname);
	if (ent == -1)
		return -1;
	float pos[3], ang[3];
	GetEntPropVector(client, Prop_Send, "m_vecOrigin", pos);
	GetEntPropVector(client, Prop_Send, "m_angRotation", ang);
	TeleportEntity(ent, pos, ang, NULL_VECTOR);
	SetEntProp(ent, Prop_Send, "m_bValidatedAttachedEntity", 1);
	SetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity", client);
	SetEntProp(ent, Prop_Send, "m_iTeamNum", GetClientTeam(client));
	SetEntProp(ent, Prop_Send, "m_fEffects", EF_BONEMERGE | EF_BONEMERGE_FASTCULL);
	DispatchSpawn(ent);
	SetEntProp(ent, Prop_Send, "m_nModelIndex", modelIndex);   // after spawn (CEconItemView resets it)
	// Team skin explicitly: a bonemerged wearable would otherwise follow skins
	// such as australium (index 2+) that the arms model does not have -> red.
	SetEntProp(ent, Prop_Send, "m_nSkin", GetClientTeam(client) == view_as<int>(TFTeam_Blue) ? 1 : 0);
	SetVariantString("!activator");
	AcceptEntityInput(ent, "SetParent", parent);
	return ent;
}

/**
 * Third person: the donor's own model is hidden (EF_NODRAW) and the custom
 * world model rides a bonemerged tf_wearable on the player (not drawn for its
 * owner in first person, like any cosmetic).
 */
void UpdateWorldModel(int client, int active)
{
	int cur = EntRefToEntIndex(g_iWorldWearable[client]);
	char want[PLATFORM_MAX_PATH];
	if (active > MaxClients && GetEntProp(active, Prop_Send, "m_bBeingRepurposedForTaunt"))
	{
		int slot = SlotOfEntity(client, active);
		if (slot >= 0 && g_Inv[client][slot].weapon >= 0)
		{
			WeaponDef w;
			g_Weapons.GetArray(g_Inv[client][slot].weapon, w);
			if (w.worldModel[0] && IsModelPrecached(w.worldModel))
				strcopy(want, sizeof(want), w.worldModel);
		}
	}
	if (cur > MaxClients)
	{
		if (!want[0] || GetEntProp(cur, Prop_Send, "m_nModelIndex") != PrecacheModel(want))
		{
			AcceptEntityInput(cur, "Kill");
			cur = -1;
			g_iWorldWearable[client] = INVALID_ENT_REFERENCE;
		}
	}
	if (!want[0])
		return;
	SetEntProp(active, Prop_Send, "m_fEffects", GetEntProp(active, Prop_Send, "m_fEffects") | EF_NODRAW);
	if (cur > MaxClients)
		return;
	// tf_wearable parented Randomizer-style (no item, no EquipWearable). The
	// 2026-11-10 crashes were the same-frame foreign-weapon strip, not this;
	// a bonemerged prop_dynamic did not render on players.
	int wear = CreateWearable(client, "tf_wearable", PrecacheModel(want), client);
	g_iWorldWearable[client] = wear > 0 ? EntIndexToEntRef(wear) : INVALID_ENT_REFERENCE;
}

/** Hidden from its owner in first person (taunt cam / thirdperson still see it). */
public Action Hook_WorldModelTransmit(int prop, int viewer)
{
	int owner = GetEntPropEnt(prop, Prop_Send, "m_hOwnerEntity");
	if (viewer != owner || owner < 1 || owner > MaxClients || !IsClientInGame(owner))
		return Plugin_Continue;
	if (GetEntProp(owner, Prop_Send, "m_nForceTauntCam") || TF2_IsPlayerInCondition(owner, TFCond_Taunting))
		return Plugin_Continue;
	return Plugin_Handled;
}

void RemoveOverlay(int client)
{
	int ww = EntRefToEntIndex(g_iWorldWearable[client]);
	if (ww > MaxClients) AcceptEntityInput(ww, "Kill");
	g_iWorldWearable[client] = INVALID_ENT_REFERENCE;
	int e = EntRefToEntIndex(g_iArmsWearable[client]);
	if (e > MaxClients) RemoveEntity(e);
	e = EntRefToEntIndex(g_iWeaponWearable[client]);
	if (e > MaxClients) RemoveEntity(e);
	g_iArmsWearable[client] = INVALID_ENT_REFERENCE;
	g_iWeaponWearable[client] = INVALID_ENT_REFERENCE;
	if (IsClientInGame(client))
	{
		int vm = GetEntPropEnt(client, Prop_Send, "m_hViewModel");
		if (vm > MaxClients)
			SetEntProp(vm, Prop_Send, "m_fEffects", GetEntProp(vm, Prop_Send, "m_fEffects") & ~EF_NODRAW);
	}
}

/* ========================================================================= */
/* Ammo packs (and pack weapon grants)                                       */
/* ========================================================================= */

public void OnEntityCreated(int entity, const char[] classname)
{
	// Touch (every tick while overlapping), not StartTouch: a player standing
	// on a pack when it becomes useful must still get it.
	if (StrContains(classname, "item_ammopack_") == 0 || StrEqual(classname, "tf_ammo_pack"))
		SDKHook(entity, SDKHook_Touch, Hook_AmmoTouch);
	else if (StrEqual(classname, "tf_dropped_weapon"))
		SDKHook(entity, SDKHook_SpawnPost, Hook_StockDropSpawned);
	else if (StrContains(classname, "item_healthkit_") == 0)
		SDKHook(entity, SDKHook_StartTouch, Hook_HealthTouch);
}

float PackFraction(const char[] classname)
{
	if (StrEqual(classname, "item_ammopack_small"))  return 0.2;
	if (StrEqual(classname, "item_ammopack_medium")) return 0.5;
	if (StrEqual(classname, "item_ammopack_full"))   return 1.0;
	return 0.5; // tf_ammo_pack (dropped by dead players)
}

public Action Hook_AmmoTouch(int pack, int other)
{
	if (other < 1 || other > MaxClients || !IsPlayerAlive(other) || TF2CC_GetRole(other) == TF2CC_ROLE_NONE)
		return Plugin_Continue;
	float now = GetGameTime();
	if ((GetEntProp(pack, Prop_Send, "m_fEffects") & EF_NODRAW) || now < g_flPackReady[pack] || now < g_flNextPackTouch[other])
		return Plugin_Continue;
	g_flNextPackTouch[other] = now + 0.25;

	char classname[64];
	GetEntityClassname(pack, classname, sizeof(classname));
	float frac = PackFraction(classname);
	bool used = false;

	for (int s = 0; s < SLOT_COUNT; s++)
	{
		if (g_Inv[other][s].weapon == WEAPON_NONE || g_Inv[other][s].maxReserve <= 0)
			continue;
		SyncAmmoFromEntity(other, s);
		if (g_Inv[other][s].reserve >= g_Inv[other][s].maxReserve)
			continue;
		int add = RoundToCeil(g_Inv[other][s].maxReserve * frac);
		SetSlotReserve(other, s, g_Inv[other][s].reserve + add);
		used = true;
	}

	// MarxVee OnAmmoPickup: only MAP packs (never a dropped tf_ammo_pack) may
	// drop a weapon, which appears on the floor at the pack to be picked up.
	bool mapPack = StrContains(classname, "item_ammopack_") == 0, roleOk = RolePackWeapons(other);
	float roll = GetURandomFloat();
	bool spawned = false;
	if (mapPack && roleOk && roll < g_cvPackWeapons.FloatValue)
		spawned = SpawnPackWeapon(other, pack);
	if (spawned)
		used = true;
	LogToFileEx(g_sPackLog, "%N touched %s (#%d): ammo used=%d mappack=%d roleweapons=%d roll=%.2f/%.2f spawned=%d",
		other, classname, pack, used, mapPack, roleOk, roll, g_cvPackWeapons.FloatValue, spawned);

	// Hoarder's Stash: an unneeded ammo pack is carried for later.
	if (!used && StashAdd(other, STASH_AMMO, WEAPON_NONE, -1, -1, -1, frac))
		used = true;
	if (!used)
		return Plugin_Continue;

	EmitSoundToAll(g_sAmmoSound, other);
	ConsumePack(pack, classname);
	return Plugin_Handled;
}

bool SpawnPackWeapon(int client, int pack)
{
	char packClass[64];
	GetEntityClassname(pack, packClass, sizeof(packClass));
	int idx = PickPackWeapon(client, RollPackTier(packClass));
	if (idx == WEAPON_NONE)
		return false;
	WeaponDef w;
	g_Weapons.GetArray(idx, w);
	char model[PLATFORM_MAX_PATH];
	if (w.worldModel[0] && IsModelPrecached(w.worldModel))
		strcopy(model, sizeof(model), w.worldModel);
	else if (!ItemWorldModel(w.itemdef, model, sizeof(model)))
		return false;
	float pos[3];
	GetEntPropVector(pack, Prop_Data, "m_vecAbsOrigin", pos);
	pos[2] += 16.0;
	return SpawnGroundPickup(idx, w.itemdef, -1, -1, model, pos, view_as<float>({ 0.0, 0.0, 120.0 }), 0) > MaxClients;
}

/** Stock world model for an item def (schema model_player). */
bool ItemWorldModel(int itemdef, char[] out, int maxlen)
{
	SchemaItem it;
	if (!ResolveSchemaItem(itemdef, it) || !it.model[0])
		return false;
	strcopy(out, maxlen, it.model);
	if (!IsModelPrecached(out))
		PrecacheModel(out, true);
	return true;
}

/**
 * Walk-over pickups. tf_dropped_weapon and our debris props never touch
 * players, so role players near one try it (empty slot: take it; occupied:
 * stash or hint to press MEDIC! to swap), as OF/MarxVee touch pickups did.
 */
public Action Timer_PickupScan(Handle timer)
{
	float pos[3], epos[3];
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !IsPlayerAlive(client) || TF2CC_GetRole(client) == TF2CC_ROLE_NONE)
			continue;
		RechargeConsumables(client);
		RestoreAttributes(client);
		// SetWeaponVisible(true) (deploy, taunt end) clears EF_NODRAW: re-hide the donor.
		int act = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		if (act > MaxClients && EntRefToEntIndex(g_iWorldWearable[client]) > MaxClients
			&& GetEntProp(act, Prop_Send, "m_bBeingRepurposedForTaunt") && !(GetEntProp(act, Prop_Send, "m_fEffects") & EF_NODRAW))
			SetEntProp(act, Prop_Send, "m_fEffects", GetEntProp(act, Prop_Send, "m_fEffects") | EF_NODRAW);
		if (!RoleCanPickup(client))
			continue;
		GetClientAbsOrigin(client, pos);
		pos[2] += 24.0;
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, "tf_dropped_weapon")) != -1)
		{
			GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", epos);
			if (GetVectorDistance(pos, epos, true) <= 56.0 * 56.0 && g_cvStockPickups.BoolValue && TryPickupStock(client, ent, BotWantsSwap(client)))
				break;
		}
		ent = -1;
		while ((ent = FindEntityByClassname(ent, "prop_physics*")) != -1)
		{
			GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", epos);
			if (GetVectorDistance(pos, epos, true) <= 56.0 * 56.0 && TryPickupOurs(client, ent, BotWantsSwap(client)))
				break;
		}
	}
	return Plugin_Continue;
}

bool RolePackWeapons(int client)
{
	char v[8];
	return TF2CC_GetRoleString(TF2CC_GetRole(client), "ammopack_weapons", v, sizeof(v)) && StringToInt(v) != 0;
}

/**
 * MarxVee RollChances: ultra 1%, then rare/uncommon by pack size
 * (small 0.1/0.4, medium 0.2/0.5, full 0.3/0.6), otherwise common.
 */
int RollPackTier(const char[] packClass)
{
	float rare = 0.1, uncommon = 0.4;
	if (StrEqual(packClass, "item_ammopack_medium")) { rare = 0.2; uncommon = 0.5; }
	else if (StrEqual(packClass, "item_ammopack_full")) { rare = 0.3; uncommon = 0.6; }
	float r = GetURandomFloat();
	if (r < 0.01)
		return 3;
	r = GetURandomFloat();
	if (r < rare)
		return 2;
	if (r < uncommon)
		return 1;
	return 0;
}

/** Weighted pick within the tier; falls back to the nearest non-empty tier (MarxVee DropRandomWeapon). */
int PickPackWeapon(int client, int tier = -1)
{
	if (tier >= 0)
	{
		for (int t = tier; t >= 0; t--)
		{
			int idx = PickPackWeaponInTier(client, t);
			if (idx != WEAPON_NONE)
				return idx;
		}
		for (int t = tier + 1; t <= 3; t++)
		{
			int idx = PickPackWeaponInTier(client, t);
			if (idx != WEAPON_NONE)
				return idx;
		}
		return WEAPON_NONE;
	}
	return PickPackWeaponInTier(client, -1);
}

int PickPackWeaponInTier(int client, int tier)
{
	int role = TF2CC_GetRole(client);
	float total = 0.0;
	WeaponDef w;
	for (int i = 0; i < g_Weapons.Length; i++)
	{
		g_Weapons.GetArray(i, w);
		if (w.pickupWeight > 0.0 && (tier < 0 || w.tier == tier) && WeaponAllowedForRole(i, role) && !SlotHolds(client, w.slot, i))
			total += w.pickupWeight;
	}
	if (total <= 0.0)
		return WEAPON_NONE;
	float pick = GetURandomFloat() * total;
	for (int i = 0; i < g_Weapons.Length; i++)
	{
		g_Weapons.GetArray(i, w);
		if (w.pickupWeight <= 0.0 || (tier >= 0 && w.tier != tier) || !WeaponAllowedForRole(i, role) || SlotHolds(client, w.slot, i))
			continue;
		if (pick < w.pickupWeight)
			return i;
		pick -= w.pickupWeight;
	}
	return WEAPON_NONE;
}

bool SlotHolds(int client, int slot, int weaponIdx)
{
	return g_Inv[client][slot].weapon == weaponIdx;
}

void ConsumePack(int pack, const char[] classname)
{
	if (StrEqual(classname, "tf_ammo_pack"))
	{
		RemoveEntity(pack);
		return;
	}
	g_flPackReady[pack] = GetGameTime() + g_cvPackRespawn.FloatValue;
	AcceptEntityInput(pack, "Disable");
	CreateTimer(g_cvPackRespawn.FloatValue, Timer_EnablePack, EntIndexToEntRef(pack), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_EnablePack(Handle timer, int ref)
{
	int pack = EntRefToEntIndex(ref);
	if (pack > MaxClients)
		AcceptEntityInput(pack, "Enable");
	return Plugin_Stop;
}

/* ========================================================================= */
/* Ground pickups (our drops and stock tf_dropped_weapon)                    */
/* ========================================================================= */

bool RoleCanPickup(int client)
{
	char v[8];
	return TF2CC_GetRoleString(TF2CC_GetRole(client), "can_pickup", v, sizeof(v)) && StringToInt(v) != 0;
}

/** Spawn a ground pickup for the weapon in a slot (owner keeps nothing). */
int SpawnPickupFromSlot(int client, int slot, float upVel, bool deathDrop = false)
{
	int weaponIdx = g_Inv[client][slot].weapon;
	int ent = EntRefToEntIndex(g_Inv[client][slot].entRef);
	if (weaponIdx == WEAPON_NONE || ent <= MaxClients)
		return -1;
	if (weaponIdx >= 0)
	{
		WeaponDef w;
		g_Weapons.GetArray(weaponIdx, w);
		// "always_drop" (Civilian umbrella) overrides "droppable 0" on death.
		if (!w.droppable && !(deathDrop && w.alwaysDrop))
			return -1;
	}

	char model[PLATFORM_MAX_PATH];
	int widx = GetEntProp(ent, Prop_Send, "m_iWorldModelIndex");
	if (widx > 0)
		ModelIndexToString(widx, model, sizeof(model));
	float pos[3], ang[3], vel[3];
	GetClientEyePosition(client, pos);
	GetClientEyeAngles(client, ang);
	GetAngleVectors(ang, vel, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(vel, 220.0);
	vel[2] += upVel + 120.0;
	pos[2] -= 16.0;
	return SpawnGroundPickup(weaponIdx, g_Inv[client][slot].itemdef, GetEntProp(ent, Prop_Send, "m_iClip1"),
		g_Inv[client][slot].reserve, model, pos, vel, GetClientUserId(client));
}

/**
 * A weapon lying on the ground (prop_physics debris + PickupData). Debris does
 * not touch players, so pickups are found by Timer_PickupScan proximity.
 * clip/reserve -1 = the weapon's defaults.
 */
int SpawnGroundPickup(int weaponIdx, int itemdef, int clip, int reserve, const char[] model, const float pos[3], const float vel[3], int dropper)
{
	if (!model[0])
		return -1;
	int prop = CreateEntityByName("prop_physics_override");
	if (prop == -1)
		return -1;
	DispatchKeyValue(prop, "model", model);
	DispatchKeyValue(prop, "spawnflags", "6"); // debris + no damage
	DispatchKeyValue(prop, "targetname", "tf2cc_pickup");
	SetEntProp(prop, Prop_Data, "m_CollisionGroup", 1); // COLLISION_GROUP_DEBRIS
	if (!DispatchSpawn(prop))
	{
		RemoveEntity(prop);
		return -1;
	}
	TeleportEntity(prop, pos, NULL_VECTOR, vel);

	PickupData d;
	d.weapon = weaponIdx;
	d.itemdef = itemdef;
	d.clip = clip;
	d.reserve = reserve;
	d.expires = GetGameTime() + g_cvPickupLifetime.FloatValue;
	d.dropper = dropper;
	d.readyAt = GetGameTime() + 1.5;

	char key[16];
	IntToString(EntIndexToEntRef(prop), key, sizeof(key));
	g_Pickups.SetArray(key, d, sizeof(d));
	CreateTimer(g_cvPickupLifetime.FloatValue, Timer_ExpirePickup, EntIndexToEntRef(prop), TIMER_FLAG_NO_MAPCHANGE);
	return prop;
}

void ModelIndexToString(int index, char[] out, int maxlen)
{
	static int table = INVALID_STRING_TABLE;
	if (table == INVALID_STRING_TABLE)
		table = FindStringTable("modelprecache");
	out[0] = '\0';
	if (table != INVALID_STRING_TABLE)
		ReadStringTable(table, index, out, maxlen);
}

public Action Timer_ExpirePickup(Handle timer, int ref)
{
	int ent = EntRefToEntIndex(ref);
	char key[16];
	IntToString(ref, key, sizeof(key));
	g_Pickups.Remove(key);
	if (ent > MaxClients)
		RemoveEntity(ent);
	return Plugin_Stop;
}

public Action Hook_PickupTouch(int prop, int other)
{
	if (other < 1 || other > MaxClients || !IsPlayerAlive(other) || !RoleCanPickup(other))
		return Plugin_Continue;
	TryPickupOurs(other, prop, false);
	return Plugin_Continue;
}

/** force = player pressed the swap key. */
bool TryPickupOurs(int client, int prop, bool force)
{
	char key[16];
	IntToString(EntIndexToEntRef(prop), key, sizeof(key));
	PickupData d;
	if (!g_Pickups.GetArray(key, d, sizeof(d)))
		return false;
	if (!force && GetGameTime() < d.readyAt && GetClientUserId(client) == d.dropper)
		return false;

	int slot;
	if (d.weapon >= 0)
	{
		if (!WeaponAllowedForRole(d.weapon, TF2CC_GetRole(client)))
			return false;
		WeaponDef w;
		g_Weapons.GetArray(d.weapon, w);
		slot = w.slot;
	}
	else
	{
		SchemaItem it;
		if (!ResolveSchemaItem(d.itemdef, it))
			return false;
		slot = MercSlotForStockItem(it);
	}
	if (slot < 0)
		return false;

	if (TryAkimboUpgrade(client, slot, d.weapon, d.clip, d.reserve))
	{
		g_Pickups.Remove(key);
		RemoveEntity(prop);
		return true;
	}

	bool occupied = SlotOccupied(client, slot);
	if (occupied && !force)
	{
		if (StashAdd(client, d.weapon >= 0 ? STASH_WEAPON : STASH_STOCK, d.weapon, d.itemdef, d.clip, d.reserve, 0.0))
		{
			g_Pickups.Remove(key);
			RemoveEntity(prop);
			return true;
		}
		PickupHint(client);
		return false;
	}
	if (!occupied && !force && !g_cvAutoPickupEmpty.BoolValue)
	{
		PickupHint(client);
		return false;
	}

	bool ok = d.weapon >= 0
		? GiveCustomWeapon(client, d.weapon, d.clip, d.reserve, occupied)
		: GiveStockItem(client, d.itemdef, 0, d.clip, d.reserve, occupied);
	if (!ok)
		return false;

	g_Pickups.Remove(key);
	RemoveEntity(prop);
	EmitSoundToClient(client, g_sPickupSound);
	int ent = EntRefToEntIndex(g_Inv[client][slot].entRef);
	if (ent > MaxClients)
		SwitchTo(client, ent);
	return true;
}

public Action Hook_DroppedWeaponTouch(int dropped, int other)
{
	if (other < 1 || other > MaxClients || !IsPlayerAlive(other) || !RoleCanPickup(other) || !g_cvStockPickups.BoolValue)
		return Plugin_Continue;
	TryPickupStock(other, dropped, false);
	return Plugin_Continue;
}

bool TryPickupStock(int client, int dropped, bool force)
{
	int itemdef = GetEntProp(dropped, Prop_Send, "m_iItemDefinitionIndex");
	SchemaItem it;
	if (!ResolveSchemaItem(itemdef, it))
		return false;
	int slot = MercSlotForStockItem(it);
	if (slot < 0)
		return false;

	// The real stock weapon is kept. Third person: the client picks the Merc
	// model's own set for the weapon's role (knife -> his MELEE set incl. the
	// combat-knife backstab, minigun -> PRIMARY + PRIMARY_DEPLOYED spin, ...).
	// First person: Merc arms on the donor class's animations (MarxVee rule).
	bool occupied = SlotOccupied(client, slot);
	if (occupied && !force && StashAdd(client, STASH_STOCK, STOCK_ITEM, itemdef, -1, -1, 0.0))
	{
		RemoveEntity(dropped);
		return true;
	}
	if ((occupied || !g_cvAutoPickupEmpty.BoolValue) && !force)
	{
		PickupHint(client);
		return false;
	}

	// TF2 keeps a dropped weapon's clip/reserve in fields it neither networks nor
	// exposes in the datamap (checked 2026-11-14), so the pickup gets a full clip
	// and the default reserve; the reads stay for a future TF2 that exposes them.
	int clip = HasEntProp(dropped, Prop_Send, "m_nClip") ? GetEntProp(dropped, Prop_Send, "m_nClip") : -1;
	int reserve = HasEntProp(dropped, Prop_Send, "m_nAmmo") ? GetEntProp(dropped, Prop_Send, "m_nAmmo") : -1;
	ItemSnapshot snap;
	SnapshotItem(dropped, snap);
	if (!GiveStockItem(client, itemdef, 0, clip, reserve, occupied))
		return false;
	int given = EntRefToEntIndex(g_Inv[client][slot].entRef);
	if (given > MaxClients)
		ApplySnapshot(given, snap);
	RemoveEntity(dropped);
	EmitSoundToClient(client, g_sPickupSound);
	int ent = EntRefToEntIndex(g_Inv[client][slot].entRef);
	if (ent > MaxClients)
		SwitchTo(client, ent);
	return true;
}

void PickupHint(int client)
{
	float now = GetGameTime();
	if (now < g_flNextPickupHint[client])
		return;
	g_flNextPickupHint[client] = now + 2.0;
	PrintHintText(client, "Press USE or INSPECT (F) to swap weapons");
}

/** +use or +inspect near a weapon swaps it (MarxVee inspect-key flow). */
public Action Listener_Inspect(int client, const char[] command, int argc)
{
	if (TF2CC_IsValidClient(client) && TF2CC_GetRole(client) != TF2CC_ROLE_NONE && TrySwapNearby(client))
		return Plugin_Handled;
	return Plugin_Continue;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
	if (IsPlayerAlive(client) && TF2CC_GetRole(client) != TF2CC_ROLE_NONE)
		ClampReserves(client);
	if (g_sLoopSnd[client][0] && (!IsPlayerAlive(client) || EntRefToEntIndex(g_iLoopEnt[client]) != GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon")
		|| (!(buttons & IN_ATTACK) && GetGameTime() - g_flLoopAt[client] > 0.15)))
		StopLoopSound(client);
	if ((buttons & IN_ATTACK2) && TF2CC_GetRole(client) != TF2CC_ROLE_NONE)
	{
		int act = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		int sl = act > MaxClients ? SlotOfEntity(client, act) : -1;
		if (sl >= 0 && g_Inv[client][sl].weapon >= 0)
		{
			WeaponDef aw;
			g_Weapons.GetArray(g_Inv[client][sl].weapon, aw);
			if (aw.noAltFire)
			{
				buttons &= ~IN_ATTACK2;
				SetEntPropFloat(act, Prop_Send, "m_flNextSecondaryAttack", GetGameTime() + 0.5);
			}
		}
	}
	bool use = (buttons & IN_USE) != 0;
	bool edge = use && !g_bUseHeld[client];
	g_bUseHeld[client] = use;
	if (edge && TF2CC_GetRole(client) != TF2CC_ROLE_NONE)
		TrySwapNearby(client);
	return Plugin_Changed;
}

bool TrySwapNearby(int client)
{
	if (!IsPlayerAlive(client) || !RoleCanPickup(client))
		return false;

	float eye[3], best = 9999.0;
	GetClientEyePosition(client, eye);
	int target = -1;
	bool ours = false;

	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "prop_physics*")) != -1)
	{
		char key[16];
		IntToString(EntIndexToEntRef(ent), key, sizeof(key));
		PickupData d;
		if (!g_Pickups.GetArray(key, d, sizeof(d)))
			continue;
		float dist = DistanceToEntity(eye, ent);
		if (dist < 110.0 && dist < best)
		{
			best = dist;
			target = ent;
			ours = true;
		}
	}
	if (g_cvStockPickups.BoolValue)
	{
		ent = -1;
		while ((ent = FindEntityByClassname(ent, "tf_dropped_weapon")) != -1)
		{
			float dist = DistanceToEntity(eye, ent);
			if (dist < 110.0 && dist < best)
			{
				best = dist;
				target = ent;
				ours = false;
			}
		}
	}
	if (target == -1)
		return false;
	return ours ? TryPickupOurs(client, target, true) : TryPickupStock(client, target, true);
}

float DistanceToEntity(const float eye[3], int ent)
{
	float pos[3];
	GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", pos);
	return GetVectorDistance(eye, pos);
}

/* ========================================================================= */
/* Dropping                                                                  */
/* ========================================================================= */

public Action Cmd_Drop(int client, int args)
{
	if (client && IsPlayerAlive(client) && RoleCanPickup(client))
		DropActive(client);
	return Plugin_Handled;
}

public Action Listener_DropItem(int client, const char[] command, int argc)
{
	if (!TF2CC_IsValidClient(client) || !IsPlayerAlive(client) || !RoleCanPickup(client))
		return Plugin_Continue;
	// Keep the stock meaning (drop the intelligence / ball / rune) when carrying an objective.
	if (CarryingObjective(client))
		return Plugin_Continue;
	DropActive(client);
	return Plugin_Handled;
}

bool CarryingObjective(int client)
{
	if (GetEntPropEnt(client, Prop_Send, "m_hItem") != -1)
		return true;
	if (HasEntProp(client, Prop_Send, "m_bHasPasstimeBall") && GetEntProp(client, Prop_Send, "m_bHasPasstimeBall"))
		return true;
	return false;
}

/**
 * MarxVee manual drop: the held weapon goes to the floor; an emptied melee
 * slot gets the (undroppable) Fists, other slots stay empty. Weapons with
 * "droppable" "0" (Fists) cannot be dropped.
 */
void DropActive(int client)
{
	if (CarryingObjective(client) || TF2_IsPlayerInCondition(client, TFCond_Taunting))
		return;
	int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	int slot = active > MaxClients ? SlotOfEntity(client, active) : -1;
	if (slot < 0 || slot == SLOT_UTILITY)
		return;
	SyncAmmoFromEntity(client, slot);
	if (SpawnPickupFromSlot(client, slot, 0.0) == -1)
		return;
	RemovePlayerItem(client, active);
	RemoveEntity(active);
	g_Inv[client][slot].weapon = WEAPON_NONE;
	g_Inv[client][slot].entRef = INVALID_ENT_REFERENCE;

	if (slot == SLOT_MELEE)
	{
		int fists = FindWeaponById("merc_fists");
		if (fists != WEAPON_NONE && WeaponAllowedForRole(fists, TF2CC_GetRole(client)))
			GiveCustomWeapon(client, fists, -1, -1, false);
		else
			RefillDefault(client, slot);
	}
	SwitchToBest(client);
}

bool IsDefaultLoadoutWeapon(int client, int slot)
{
	char key[32], id[48];
	FormatEx(key, sizeof(key), "loadout_%s", g_sSlotNames[slot]);
	if (!TF2CC_GetRoleString(TF2CC_GetRole(client), key, id, sizeof(id)) || !id[0])
		return false;
	int idx = FindWeaponById(id);
	return idx != WEAPON_NONE && g_Inv[client][slot].weapon == idx;
}

void RefillDefault(int client, int slot)
{
	char key[32], id[48];
	FormatEx(key, sizeof(key), "loadout_%s", g_sSlotNames[slot]);
	if (!TF2CC_GetRoleString(TF2CC_GetRole(client), key, id, sizeof(id)) || !id[0])
		return;
	int idx = FindWeaponById(id);
	if (idx != WEAPON_NONE)
		GiveCustomWeapon(client, idx, -1, -1, false);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!TF2CC_IsValidClient(client) || TF2CC_GetRole(client) == TF2CC_ROLE_NONE)
		return;
	StopLoopSound(client);
	// Remember custom weapons so the stock death drop of their donors is removed.
	g_flDiedAt[client] = GetGameTime();
	GetClientAbsOrigin(client, g_vecDiedAt[client]);
	for (int s = 0; s < SLOT_COUNT; s++)
		g_iDiedDefs[client][s] = g_Inv[client][s].weapon >= 0 ? g_Inv[client][s].itemdef : -1;
	if (event.GetInt("death_flags") & 32) // TF_DEATHFLAG_DEADRINGER
		return;

	int dActive = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	int dSlot = dActive > MaxClients ? SlotOfEntity(client, dActive) : -1;
	bool always = false;
	if (dSlot >= 0 && g_Inv[client][dSlot].weapon >= 0)
	{
		WeaponDef dw;
		g_Weapons.GetArray(g_Inv[client][dSlot].weapon, dw);
		always = dw.alwaysDrop;
	}
	if (g_cvDropOnDeath.BoolValue && (RoleCanPickup(client) || always))
	{

		int slot = dSlot;
		if (slot >= 0 && (always || !IsDefaultLoadoutWeapon(client, slot)))
		{
			SyncAmmoFromEntity(client, slot);
			SpawnPickupFromSlot(client, slot, 60.0, true);
		}
	}
	RemoveOverlay(client);
	ClearInventory(client); // next life starts from the role loadout
	StashClear(client);
}

/* ========================================================================= */
/* Admin / validation                                                        */
/* ========================================================================= */

public Action Cmd_GiveStock(int client, int args)
{
	if (args < 2)
	{
		ReplyToCommand(client, "Usage: sm_tf2cc_givestock <item def index> <target>");
		return Plugin_Handled;
	}
	char a[16], t[64];
	GetCmdArg(1, a, sizeof(a));
	GetCmdArg(2, t, sizeof(t));
	int target = FindTarget(client, t, false, false);
	if (target <= 0)
		return Plugin_Handled;
	if (TF2CC_GetRole(target) == TF2CC_ROLE_NONE || !IsPlayerAlive(target))
	{
		ReplyToCommand(client, "[TF2CC] %N is not an alive role player.", target);
		return Plugin_Handled;
	}
	int itemdef = StringToInt(a);
	bool ok = GiveStockItem(target, itemdef, 0, -1, -1, true);
	SchemaItem it;
	int slot = ResolveSchemaItem(itemdef, it) ? MercSlotForStockItem(it) : -1;
	int ent = slot >= 0 ? EntRefToEntIndex(g_Inv[target][slot].entRef) : -1;
	if (ok && ent > MaxClients)
		SwitchTo(target, ent);
	ReplyToCommand(client, "[TF2CC] givestock %d -> %N: %s (slot %d)", itemdef, target, ok ? "ok" : "failed", slot);
	return Plugin_Handled;
}

public Action Cmd_Give(int client, int args)
{
	if (args < 1 || (!client && args < 2))
	{
		ReplyToCommand(client, "[TF2CC] Usage: sm_tf2cc_give <weapon id|item def> [target]");
		return Plugin_Handled;
	}
	char id[48], pattern[64], tname[MAX_TARGET_LENGTH];
	GetCmdArg(1, id, sizeof(id));
	int targets[MAXPLAYERS], count = 1;
	targets[0] = client;
	if (args >= 2)
	{
		bool ml;
		GetCmdArg(2, pattern, sizeof(pattern));
		count = ProcessTargetString(pattern, client, targets, sizeof(targets), COMMAND_FILTER_ALIVE, tname, sizeof(tname), ml);
		if (count <= 0)
		{
			ReplyToTargetError(client, count);
			return Plugin_Handled;
		}
	}
	int idx = FindWeaponById(id), def = StringToInt(id);
	if (idx == WEAPON_NONE && def <= 0)
	{
		ReplyToCommand(client, "[TF2CC] Unknown weapon '%s'.", id);
		return Plugin_Handled;
	}
	for (int t = 0; t < count; t++)
	{
		if (idx != WEAPON_NONE)
			GiveCustomWeapon(targets[t], idx, -1, -1, true);
		else if (GiveStockItem(targets[t], def, 0, -1, -1, true))
			ReplyToCommand(client, "[TF2CC] Gave stock item %d to %N.", def, targets[t]);
	}
	return Plugin_Handled;
}

public Action Cmd_Inventory(int client, int args)
{
	char cls[64], id[48];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || TF2CC_GetRole(i) == TF2CC_ROLE_NONE)
			continue;
		int active = GetEntPropEnt(i, Prop_Send, "m_hActiveWeapon");
		int vm = GetEntPropEnt(i, Prop_Send, "m_hViewModel");
		ReplyToCommand(client, "%N alive=%d hp=%d maxspeed=%.0f active=%d vmModel=%d", i, IsPlayerAlive(i), GetClientHealth(i),
			GetEntPropFloat(i, Prop_Send, "m_flMaxspeed"), active, vm > MaxClients ? GetEntProp(vm, Prop_Send, "m_nModelIndex") : -1);
		for (int s = 0; s < SLOT_COUNT; s++)
		{
			int ent = EntRefToEntIndex(g_Inv[i][s].entRef);
			cls = "-";
			id = "-";
			if (ent > MaxClients)
				GetEntityClassname(ent, cls, sizeof(cls));
			if (g_Inv[i][s].weapon >= 0)
			{
				WeaponDef w;
				g_Weapons.GetArray(g_Inv[i][s].weapon, w);
				strcopy(id, sizeof(id), w.id);
			}
			else if (g_Inv[i][s].weapon == STOCK_ITEM)
				FormatEx(id, sizeof(id), "stock:%d", g_Inv[i][s].itemdef);
			ReplyToCommand(client, "   %-9s %-18s %-30s clip=%d reserve=%d/%d customVM=%d", g_sSlotNames[s], id, cls,
				ent > MaxClients ? GetEntProp(ent, Prop_Send, "m_iClip1") : -1, g_Inv[i][s].reserve, g_Inv[i][s].maxReserve,
				ent > MaxClients ? GetEntProp(ent, Prop_Send, "m_nCustomViewmodelModelIndex") : -1);
		}
	}
	return Plugin_Handled;
}

public void OnProfileChanged(ConVar cv, const char[] oldValue, const char[] newValue)
{
	LoadWeapons();
	PrecacheWeaponModels();
	ValidateWeapons(0, false);
}

public Action Cmd_ListWeapons(int client, int args)
{
	ValidateWeapons(client, true);
	return Plugin_Handled;
}

/**
 * Validate every configured donor against the live schema: the donor item must
 * exist, its item_class must be compatible with the configured classname, and
 * its schema slot should match. Never guesses; reports only.
 */
void ValidateWeapons(int reply, bool doReply)
{
	if (g_Weapons == null)
		return;
	WeaponDef w;
	int bad = 0;
	for (int i = 0; i < g_Weapons.Length; i++)
	{
		g_Weapons.GetArray(i, w);
		char status[128] = "ok";
		SchemaItem it;
		if (StrEqual(w.classname, "none"))
			strcopy(status, sizeof(status), "ok");   // entity-less perk, nothing to validate
		else if (!g_bSchemaLoaded)
			strcopy(status, sizeof(status), "schema not loaded");
		else if (!ResolveSchemaItem(w.itemdef, it))
			FormatEx(status, sizeof(status), "MISSING itemdef %d in items_game", w.itemdef);
		else
		{
			int fam = w.family ? w.family : DonorClassForItem(it);
			char translated[64];
			TranslateItemClass(it.itemClass, fam, translated, sizeof(translated));
			if (!StrEqual(translated, w.classname) && !StrEqual(it.itemClass, w.classname))
				FormatEx(status, sizeof(status), "classname %s != schema %s", w.classname, translated);
		}
		if (!StrEqual(status, "ok"))
		{
			bad++;
			LogError("tf2cc_weapons: '%s' %s", w.id, status);
		}
		if (doReply)
			ReplyToCommand(reply, "%-20s %-10s %-34s def=%-6d %s", w.id, g_sSlotNames[w.slot], w.classname, w.itemdef, status);
	}
	if (doReply)
		ReplyToCommand(reply, "[TF2CC] %d weapon(s), %d problem(s).", g_Weapons.Length, bad);
	ValidateAttributes(reply, doReply);
}

/**
 * Item schema updates can rename or retire attributes; TF2Attrib_SetByName then
 * fails and the weapon silently loses that stat. Check every configured name
 * (all profiles) against the live schema. Returns the problem count, -1 when
 * TF2Attributes (or its name check) is unavailable.
 */
int ValidateAttributes(int reply, bool doReply)
{
	if (g_Attrs == null || !g_bTF2Attributes
		|| GetFeatureStatus(FeatureType_Native, "TF2Attrib_IsValidAttributeName") != FeatureStatus_Available)
	{
		if (doReply)
			ReplyToCommand(reply, "[TF2CC] attribute names not checked (TF2Attributes unavailable).");
		return -1;
	}
	StringMap seen = new StringMap();
	AttrDef a;
	int bad = 0, total = 0;
	for (int i = 0; i < g_Attrs.Length; i++)
	{
		g_Attrs.GetArray(i, a);
		if (!seen.SetValue(a.name, true, false))
			continue;
		total++;
		if (TF2Attrib_IsValidAttributeName(a.name))
			continue;
		bad++;
		LogError("tf2cc_weapons: attribute '%s' is not in the item schema (renamed or removed by a TF2 update?)", a.name);
		if (doReply)
			ReplyToCommand(reply, "  UNKNOWN attribute '%s'", a.name);
	}
	delete seen;
	if (doReply)
		ReplyToCommand(reply, "[TF2CC] %d attribute name(s), %d unknown.", total, bad);
	return bad;
}

/** TF2Attrib_SetByName, logging each rejected name once. */
void ApplyAttr(int ent, const char[] name, float value)
{
	static StringMap s_bad;
	if (TF2Attrib_SetByName(ent, name, value))
		return;
	if (s_bad == null)
		s_bad = new StringMap();
	if (s_bad.SetValue(name, true, false))
		LogError("tf2cc_weapons: TF2Attributes rejected attribute '%s' (value %.3f)", name, value);
}

/* ========================================================================= */
/* Per-weapon sound replacement (legacy CW3 "find"/"replace")                */
/* ========================================================================= */

/** Strip Source sound-character prefixes, lowercase, forward slashes. */
void NormaliseSample(char[] sample)
{
	int start = 0;
	while (sample[start] != '\0' && FindCharInString(")^#*@<>!?$&~`+", sample[start]) != -1)
		start++;
	if (start)
		strcopy(sample, PLATFORM_MAX_PATH, sample[start]);
	ReplaceString(sample, PLATFORM_MAX_PATH, "\\", "/");
	int len = strlen(sample);
	for (int i = 0; i < len; i++)
		sample[i] = CharToLower(sample[i]);
}

/**
 * Server-emitted weapon sounds of role players are swapped for the weapon's
 * configured replacements. The shooter's own fire sound is client-predicted and
 * never reaches the server, so the shooter hears the donor sound while everyone
 * else hears the replacement (same limitation as the legacy stack).
 */
public Action Hook_Sound(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH],
	int &entity, int &channel, float &volume, int &level, int &pitch, int &flags,
	char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
	if (entity < 1 || g_Weapons == null)
		return Plugin_Continue;
	int owner = entity;
	if (entity > MaxClients)
	{
		if (!IsValidEntity(entity) || !HasEntProp(entity, Prop_Send, "m_hOwnerEntity"))
			return Plugin_Continue;
		owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
	}
	if (owner < 1 || owner > MaxClients || !IsClientInGame(owner) || TF2CC_GetRole(owner) == TF2CC_ROLE_NONE)
		return Plugin_Continue;

	int active = GetEntPropEnt(owner, Prop_Send, "m_hActiveWeapon");
	int slot = active > MaxClients ? SlotOfEntity(owner, active) : -1;
	if (slot < 0 || g_Inv[owner][slot].weapon < 0)
		return Plugin_Continue;
	WeaponDef w;
	g_Weapons.GetArray(g_Inv[owner][slot].weapon, w);
	if (w.sounds == null)
		return Plugin_Continue;

	char norm[PLATFORM_MAX_PATH], find[PLATFORM_MAX_PATH];
	strcopy(norm, sizeof(norm), sample);
	NormaliseSample(norm);
	for (int i = 0; i + 1 < w.sounds.Length; i += 2)
	{
		w.sounds.GetString(i, find, sizeof(find));
		if (StrEqual(norm, find))
		{
			w.sounds.GetString(i + 1, sample, sizeof(sample));
			if (w.soundsLoop)
			{
				strcopy(g_sLoopSnd[owner], sizeof(g_sLoopSnd[]), sample);
				g_iLoopEnt[owner] = EntIndexToEntRef(entity);
				g_iLoopChan[owner] = channel;
				g_flLoopAt[owner] = GetGameTime();
			}
			EchoToOwner(owner, clients, numClients, sample, entity, channel, volume, level, pitch, flags);
			return Plugin_Changed;
		}
	}
	return Plugin_Continue;
}


/* ========================================================================= */
/* Hoarder's Stash (MarxVee Merc_4_Hoarders_Stash, rebuilt)                  */
/*  "Can carry up to 8 items such as health, ammo, and weapons! However, the */
/*   weight of it all makes your legs weak and unable to bunnyhop."          */
/* Carrier = a role player holding the "hoarder" utility perk; capacity =    */
/* its special_value. Weapons whose slot is occupied, health kits touched at */
/* full health and ammo packs that are not needed go into the stash; !stash  */
/* (or the action key) opens a menu to use them. Swapping a stashed weapon   */
/* in puts the current one into the stash.                                   */
/* ========================================================================= */


enum struct StashItem
{
	int type;
	int weapon;
	int itemdef;
	int clip;
	int reserve;
	float amount;
}

ArrayList g_Stash[MAXPLAYERS + 1];

int StashCapacity(int client)
{
	if (TF2CC_GetRole(client) == TF2CC_ROLE_NONE)
		return 0;
	WeaponDef w;
	for (int s = 0; s < SLOT_COUNT; s++)
	{
		if (g_Inv[client][s].weapon < 0)
			continue;
		g_Weapons.GetArray(g_Inv[client][s].weapon, w);
		if (StrEqual(w.special, "hoarder"))
			return w.specialValue > 0.0 ? RoundToFloor(w.specialValue) : 8;
	}
	return 0;
}

bool StashAdd(int client, int type, int weapon, int itemdef, int clip, int reserve, float amount)
{
	int cap = StashCapacity(client);
	if (cap <= 0)
		return false;
	if (g_Stash[client] == null)
		g_Stash[client] = new ArrayList(sizeof(StashItem));
	if (g_Stash[client].Length >= cap)
	{
		PrintHintText(client, "Hoarder's Stash is full (%d/%d) - !stash to use items", cap, cap);
		return false;
	}
	StashItem it;
	it.type = type;
	it.weapon = weapon;
	it.itemdef = itemdef;
	it.clip = clip;
	it.reserve = reserve;
	it.amount = amount;
	g_Stash[client].PushArray(it);
	char name[64];
	StashItemName(it, name, sizeof(name));
	PrintHintText(client, "Stashed %s (%d/%d) - !stash", name, g_Stash[client].Length, cap);
	EmitSoundToClient(client, g_sPickupSound);
	return true;
}

void StashClear(int client)
{
	delete g_Stash[client];
}

void StashItemName(StashItem it, char[] out, int maxlen)
{
	switch (it.type)
	{
		case STASH_HEALTH: FormatEx(out, maxlen, "Health (+%d%%)", RoundToFloor(it.amount * 100.0));
		case STASH_AMMO: FormatEx(out, maxlen, "Ammo (+%d%%)", RoundToFloor(it.amount * 100.0));
		case STASH_WEAPON:
		{
			WeaponDef w;
			g_Weapons.GetArray(it.weapon, w);
			strcopy(out, maxlen, w.name);
		}
		default:
		{
			SchemaItem si;
			if (ResolveSchemaItem(it.itemdef, si))
			{
				strcopy(out, maxlen, si.itemClass);
				ReplaceString(out, maxlen, "tf_weapon_", "");
			}
			else
				FormatEx(out, maxlen, "Item %d", it.itemdef);
		}
	}
}

public Action Hook_HealthTouch(int kit, int other)
{
	if (other < 1 || other > MaxClients || !IsPlayerAlive(other) || StashCapacity(other) <= 0)
		return Plugin_Continue;
	if ((GetEntProp(kit, Prop_Send, "m_fEffects") & EF_NODRAW) || GetGameTime() < g_flPackReady[kit])
		return Plugin_Continue;
	if (GetClientHealth(other) < ResourceMaxHealth(other))
		return Plugin_Continue; // let the kit heal normally
	char classname[64];
	GetEntityClassname(kit, classname, sizeof(classname));
	float frac = StrEqual(classname, "item_healthkit_small") ? 0.205 : (StrEqual(classname, "item_healthkit_medium") ? 0.5 : 1.0);
	if (!StashAdd(other, STASH_HEALTH, WEAPON_NONE, -1, -1, -1, frac))
		return Plugin_Continue;
	ConsumePack(kit, classname);
	return Plugin_Handled;
}

int ResourceMaxHealth(int client)
{
	int res = GetPlayerResourceEntity();
	return res != -1 ? GetEntProp(res, Prop_Send, "m_iMaxHealth", _, client) : GetEntProp(client, Prop_Data, "m_iMaxHealth");
}

public Action Cmd_Stash(int client, int args)
{
	if (!client || !IsPlayerAlive(client))
		return Plugin_Handled;
	if (StashCapacity(client) <= 0)
	{
		PrintToChat(client, "\x04[TF2CC]\x01 You are not carrying a Hoarder's Stash.");
		return Plugin_Handled;
	}
	ShowStashMenu(client);
	return Plugin_Handled;
}

/** Action key opens the stash for Hoarder carriers without a grappling hook. */
public Action Listener_StashKey(int client, const char[] command, int argc)
{
	if (!TF2CC_IsValidClient(client) || !IsPlayerAlive(client) || StashCapacity(client) <= 0 || ClientHasSpecialLocal(client, "grapple"))
		return Plugin_Continue;
	ShowStashMenu(client);
	return Plugin_Handled;
}

bool ClientHasSpecialLocal(int client, const char[] special)
{
	WeaponDef w;
	for (int s = 0; s < SLOT_COUNT; s++)
	{
		if (g_Inv[client][s].weapon < 0)
			continue;
		g_Weapons.GetArray(g_Inv[client][s].weapon, w);
		if (StrEqual(w.special, special))
			return true;
	}
	return false;
}

void ShowStashMenu(int client)
{
	Menu menu = new Menu(Menu_Stash);
	int n = g_Stash[client] == null ? 0 : g_Stash[client].Length;
	menu.SetTitle("Hoarder's Stash (%d/%d)", n, StashCapacity(client));
	char info[8], name[64];
	StashItem it;
	for (int i = 0; i < n; i++)
	{
		g_Stash[client].GetArray(i, it);
		StashItemName(it, name, sizeof(name));
		IntToString(i, info, sizeof(info));
		menu.AddItem(info, name);
	}
	if (!n)
		menu.AddItem("", "(empty)", ITEMDRAW_DISABLED);
	menu.Display(client, 20);
}

public int Menu_Stash(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
		delete menu;
	else if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(item, info, sizeof(info));
		UseStashItem(client, StringToInt(info));
	}
	return 0;
}

void UseStashItem(int client, int index)
{
	if (!IsPlayerAlive(client) || g_Stash[client] == null || index < 0 || index >= g_Stash[client].Length)
		return;
	StashItem it;
	g_Stash[client].GetArray(index, it);
	switch (it.type)
	{
		case STASH_HEALTH:
		{
			int maxh = ResourceMaxHealth(client);
			int h = GetClientHealth(client);
			if (h >= maxh)
			{
				PrintHintText(client, "Already at full health");
				return;
			}
			int add = RoundToCeil(maxh * it.amount);
			SetEntityHealth(client, h + add > maxh ? maxh : h + add);
			g_Stash[client].Erase(index);
		}
		case STASH_AMMO:
		{
			for (int s = 0; s < SLOT_COUNT; s++)
			{
				if (g_Inv[client][s].maxReserve <= 0)
					continue;
				SyncAmmoFromEntity(client, s);
				SetSlotReserve(client, s, g_Inv[client][s].reserve + RoundToCeil(g_Inv[client][s].maxReserve * it.amount));
			}
			EmitSoundToAll(g_sAmmoSound, client);
			g_Stash[client].Erase(index);
		}
		default:
		{
			// Swap: current occupant of the slot goes into the stash in its place.
			int slot;
			if (it.type == STASH_WEAPON)
			{
				WeaponDef w;
				g_Weapons.GetArray(it.weapon, w);
				slot = w.slot;
			}
			else
			{
				SchemaItem si;
				if (!ResolveSchemaItem(it.itemdef, si))
					return;
				slot = MercSlotForStockItem(si);
			}
			if (slot < 0)
				return;
			g_Stash[client].Erase(index);
			if (g_Inv[client][slot].weapon != WEAPON_NONE && !IsDefaultLoadoutWeapon(client, slot))
			{
				SyncAmmoFromEntity(client, slot);
				StashItem old;
				old.type = g_Inv[client][slot].weapon >= 0 ? STASH_WEAPON : STASH_STOCK;
				old.weapon = g_Inv[client][slot].weapon;
				old.itemdef = g_Inv[client][slot].itemdef;
				old.clip = g_Inv[client][slot].clip;
				old.reserve = g_Inv[client][slot].reserve;
				g_Stash[client].PushArray(old);
			}
			bool ok = it.type == STASH_WEAPON
				? GiveCustomWeapon(client, it.weapon, it.clip, it.reserve, false)
				: GiveStockItem(client, it.itemdef, 0, it.clip, it.reserve, false);
			int ent = EntRefToEntIndex(g_Inv[client][slot].entRef);
			if (ok && ent > MaxClients)
				SwitchTo(client, ent);
		}
	}
}

/* Diagnostics: viewmodel trace (draw-loop hunting). */
int g_iTraceUser;
float g_flTraceEnd;
int g_iTraceLastWeapon = -1, g_iTraceLastParity = -1, g_iTraceLastModel = -1, g_iTraceLastSeq = -1;

public Action Cmd_VMTrace(int client, int args)
{
	char pattern[64], secs[16];
	GetCmdArg(1, pattern, sizeof(pattern));
	int target = FindTarget(client, pattern, false, false);
	if (target <= 0)
		return Plugin_Handled;
	if (args >= 2)
		GetCmdArg(2, secs, sizeof(secs));
	g_iTraceUser = GetClientUserId(target);
	g_flTraceEnd = GetGameTime() + (args >= 2 ? StringToFloat(secs) : 10.0);
	g_iTraceLastWeapon = g_iTraceLastParity = g_iTraceLastModel = g_iTraceLastSeq = -1;
	CreateTimer(0.1, Timer_VMTrace, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	ReplyToCommand(client, "[TF2CC] tracing %N", target);
	return Plugin_Handled;
}

public Action Timer_VMTrace(Handle timer)
{
	int c = GetClientOfUserId(g_iTraceUser);
	if (!c || GetGameTime() > g_flTraceEnd)
		return Plugin_Stop;
	int vm = GetEntPropEnt(c, Prop_Send, "m_hViewModel");
	int w = GetEntPropEnt(c, Prop_Send, "m_hActiveWeapon");
	if (vm <= MaxClients)
		return Plugin_Continue;
	int seq = GetEntProp(vm, Prop_Send, "m_nSequence");
	int par = GetEntProp(vm, Prop_Send, "m_nNewSequenceParity");
	int mdl = GetEntProp(vm, Prop_Send, "m_nModelIndex");
	if (w != g_iTraceLastWeapon || par != g_iTraceLastParity || mdl != g_iTraceLastModel || seq != g_iTraceLastSeq)
	{
		char path[PLATFORM_MAX_PATH], wcls[64], mname[PLATFORM_MAX_PATH];
		GetEntPropString(vm, Prop_Data, "m_ModelName", mname, sizeof(mname));
		BuildPath(Path_SM, path, sizeof(path), "logs/tf2cc_vmtrace.log");
		if (w > MaxClients)
			GetEntityClassname(w, wcls, sizeof(wcls));
		LogToFileEx(path, "%N t=%.2f weapon=%d(%s) customVM=%d vmModel=%d(%s) seq=%d parity=%d cycle=%.2f",
			c, GetGameTime(), w, wcls, w > MaxClients ? GetEntProp(w, Prop_Send, "m_nCustomViewmodelModelIndex") : -1,
			mdl, mname, seq, par, GetEntPropFloat(vm, Prop_Data, "m_flCycle"));
		g_iTraceLastWeapon = w; g_iTraceLastParity = par; g_iTraceLastModel = mdl; g_iTraceLastSeq = seq;
	}
	return Plugin_Continue;
}

/* ------------------------------------------------------------------------- */
/* Item identity of picked-up stock weapons                                  */
/* ------------------------------------------------------------------------- */

#define SNAP_MAX 32

enum struct ItemSnapshot
{
	int quality;
	int level;
	int count;
	int defs[SNAP_MAX];
	float values[SNAP_MAX];
}

/**
 * Quality/level plus the item's own attributes: SOC (paint, australium,
 * festivizer, killstreak, unusual effect, war paint, botkiller, strange parts)
 * and runtime ones (MvM upgrades) from the dropped weapon's CEconItemView.
 * Schema (static) attributes come back with the item definition itself.
 */
void SnapshotItem(int dropped, ItemSnapshot snap)
{
	snap.count = 0;
	snap.quality = HasEntProp(dropped, Prop_Send, "m_iEntityQuality") ? GetEntProp(dropped, Prop_Send, "m_iEntityQuality") : -1;
	snap.level = HasEntProp(dropped, Prop_Send, "m_iEntityLevel") ? GetEntProp(dropped, Prop_Send, "m_iEntityLevel") : -1;
	if (!g_bTF2Attributes)
		return;
	int defs[SNAP_MAX];
	float vals[SNAP_MAX];
	int n = TF2Attrib_GetSOCAttribs(dropped, defs, vals, SNAP_MAX);
	for (int i = 0; i < n && snap.count < SNAP_MAX; i++)
	{
		snap.defs[snap.count] = defs[i];
		snap.values[snap.count++] = vals[i];
	}
	n = TF2Attrib_ListDefIndices(dropped, defs, SNAP_MAX);
	for (int i = 0; i < n && snap.count < SNAP_MAX; i++)
	{
		Address a = TF2Attrib_GetByDefIndex(dropped, defs[i]);
		if (a == Address_Null)
			continue;
		snap.defs[snap.count] = defs[i];
		snap.values[snap.count++] = TF2Attrib_GetValue(a);
	}
}

void ApplySnapshot(int weapon, ItemSnapshot snap)
{
	if (snap.quality >= 0)
		SetEntProp(weapon, Prop_Send, "m_iEntityQuality", snap.quality);
	if (snap.level >= 0)
		SetEntProp(weapon, Prop_Send, "m_iEntityLevel", snap.level);
	if (!g_bTF2Attributes || snap.count == 0)
		return;
	for (int i = 0; i < snap.count; i++)
		TF2Attrib_SetByDefIndex(weapon, snap.defs[i], snap.values[i]);
	TF2Attrib_ClearCache(weapon);
}

public Action Cmd_VMState(int client, int args)
{
	char pattern[64];
	GetCmdArg(1, pattern, sizeof(pattern));
	int t = FindTarget(client, pattern, false, false);
	if (t <= 0)
		return Plugin_Handled;
	char path[PLATFORM_MAX_PATH], m[PLATFORM_MAX_PATH], cls[64];
	BuildPath(Path_SM, path, sizeof(path), "logs/tf2cc_vmtrace.log");
	int vm = GetEntPropEnt(t, Prop_Send, "m_hViewModel");
	int w = GetEntPropEnt(t, Prop_Send, "m_hActiveWeapon");
	if (vm > MaxClients)
	{
		GetEntPropString(vm, Prop_Data, "m_ModelName", m, sizeof(m));
		LogToFileEx(path, "STATE %N vm=%d model=%s effects=%d", t, vm, m, GetEntProp(vm, Prop_Send, "m_fEffects"));
	}
	if (w > MaxClients)
	{
		GetEntityClassname(w, cls, sizeof(cls));
		GetEntPropString(w, Prop_Data, "m_ModelName", m, sizeof(m));
		LogToFileEx(path, "STATE %N weapon=%d %s model=%s customVM=%d vmIndex=%d worldIdx=%d repurposed=%d render=%d slot=%d",
			t, w, cls, m, GetEntProp(w, Prop_Send, "m_nCustomViewmodelModelIndex"), GetEntProp(w, Prop_Send, "m_iViewModelIndex"),
			GetEntProp(w, Prop_Send, "m_iWorldModelIndex"), GetEntProp(w, Prop_Send, "m_bBeingRepurposedForTaunt"),
			GetEntProp(w, Prop_Send, "m_nRenderMode"), SlotOfEntity(t, w));
	}
	int e = -1;
	while ((e = FindEntityByClassname(e, "tf_wearable*")) != -1)
	{
		if (GetEntPropEnt(e, Prop_Send, "m_hOwnerEntity") != t)
			continue;
		GetEntityClassname(e, cls, sizeof(cls));
		ModelIndexToString(GetEntProp(e, Prop_Send, "m_nModelIndex"), m, sizeof(m));
		LogToFileEx(path, "STATE %N wearable=%d %s model=%s effects=%d parent=%d assoc=%d", t, e, cls, m,
			GetEntProp(e, Prop_Send, "m_fEffects"), GetEntPropEnt(e, Prop_Data, "m_hMoveParent"),
			HasEntProp(e, Prop_Send, "m_hWeaponAssociatedWith") ? GetEntPropEnt(e, Prop_Send, "m_hWeaponAssociatedWith") : -2);
	}
	int wp = EntRefToEntIndex(g_iWorldWearable[t]);
	if (wp > MaxClients)
	{
		GetEntPropString(wp, Prop_Data, "m_ModelName", m, sizeof(m));
		LogToFileEx(path, "STATE %N worldprop=%d model=%s effects=%d parent=%d", t, wp, m,
			GetEntProp(wp, Prop_Send, "m_fEffects"), GetEntPropEnt(wp, Prop_Data, "m_hMoveParent"));
	}
	else
		LogToFileEx(path, "STATE %N worldprop=none", t);
	for (int s = 0; s < SLOT_COUNT; s++)
	{
		int se = EntRefToEntIndex(g_Inv[t][s].entRef);
		int type = se > MaxClients ? GetEntProp(se, Prop_Send, "m_iPrimaryAmmoType") : -1;
		char scls[64];
		if (se > MaxClients)
			GetEntityClassname(se, scls, sizeof(scls));
		LogToFileEx(path, "STATE %N slot%d weapon=%d %s def=%d ammotype=%d stored=%d max=%d m_iAmmo=%d", t, s, se, scls,
			g_Inv[t][s].itemdef, type, g_Inv[t][s].reserve, g_Inv[t][s].maxReserve,
			type > 0 ? GetEntProp(t, Prop_Send, "m_iAmmo", _, type) : -1);
	}
	ReplyToCommand(client, "[TF2CC] state of %N logged", t);
	return Plugin_Handled;
}

/**
 * TF2 drops a dead player's active weapon as a tf_dropped_weapon of the
 * DONOR item (a Civilian's umbrella would fall as a bat). Custom weapons are
 * never dropped that way: Merc drops are tf2cc ground pickups instead.
 */
public void Hook_StockDropSpawned(int entity)
{
	RequestFrame(Frame_CheckStockDrop, EntIndexToEntRef(entity));
}

public void Frame_CheckStockDrop(int ref)
{
	int ent = EntRefToEntIndex(ref);
	if (ent <= MaxClients || !HasEntProp(ent, Prop_Send, "m_iItemDefinitionIndex"))
		return;
	int def = GetEntProp(ent, Prop_Send, "m_iItemDefinitionIndex");
	float pos[3];
	GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", pos);
	float now = GetGameTime();
	for (int c = 1; c <= MaxClients; c++)
	{
		if (now - g_flDiedAt[c] > 1.0 || GetVectorDistance(pos, g_vecDiedAt[c]) > 200.0)
			continue;
		for (int s = 0; s < SLOT_COUNT; s++)
		{
			if (g_iDiedDefs[c][s] == def)
			{
				RemoveEntity(ent);
				return;
			}
		}
	}
}

/* ------------------------------------------------------------------------- */
/* Custom attributes survive regenerate / MvM upgrades                       */
/* ------------------------------------------------------------------------- */

/**
 * TF2 rebuilds a weapon's runtime attribute list on regenerate and when MvM
 * upgrades are (re)applied, which drops the attributes tf2cc set (a Merc
 * pistol fell from 15 to 12 rounds). Re-add them when the first one is gone.
 * Returns true when anything was re-applied.
 */
bool ReapplyCustomAttributes(int ent, int weaponIdx)
{
	if (!g_bTF2Attributes)
		return false;
	WeaponDef w;
	g_Weapons.GetArray(weaponIdx, w);
	if (w.attrCount <= 0)
		return false;
	AttrDef a;
	g_Attrs.GetArray(w.attrStart, a);
	if (TF2Attrib_GetByName(ent, a.name) != Address_Null)
		return false;
	for (int i = 0; i < w.attrCount; i++)
	{
		g_Attrs.GetArray(w.attrStart + i, a);
		ApplyAttr(ent, a.name, a.value);
	}
	TF2Attrib_ClearCache(ent);
	return true;
}

float ClipMultiplier(int weaponIdx)
{
	WeaponDef w;
	g_Weapons.GetArray(weaponIdx, w);
	AttrDef a;
	float mult = 1.0;
	for (int i = 0; i < w.attrCount; i++)
	{
		g_Attrs.GetArray(w.attrStart + i, a);
		if (StrEqual(a.name, "clip size bonus") || StrEqual(a.name, "clip size penalty"))
			mult *= a.value;
	}
	return mult;
}

void RestoreAttributes(int client)
{
	for (int s = 0; s < SLOT_COUNT; s++)
	{
		int ent = EntRefToEntIndex(g_Inv[client][s].entRef);
		if (ent <= MaxClients || g_Inv[client][s].weapon < 0)
			continue;
		if (!ReapplyCustomAttributes(ent, g_Inv[client][s].weapon))
			continue;
		// An upgrade re-application leaves the clip at the un-boosted maximum.
		int clip = GetEntProp(ent, Prop_Send, "m_iClip1");
		float mult = ClipMultiplier(g_Inv[client][s].weapon);
		if (clip > 0 && mult > 1.0)
			SetEntProp(ent, Prop_Send, "m_iClip1", RoundToFloor(float(clip) * mult + 0.001));
	}
}

/**
 * TF2 may auto-deploy a weapon inside Equip (no active weapon left after the
 * old one was removed) - before tf2cc stored the slot, set the custom
 * viewmodel and arms - and the later "use" then switches nothing. Re-run the
 * viewmodel/arms setup and load the active weapon's own reserve a frame later.
 */
public void Frame_PostGrant(int userid)
{
	int client = GetClientOfUserId(userid);
	if (!client || !IsPlayerAlive(client) || TF2CC_GetRole(client) == TF2CC_ROLE_NONE)
		return;
	int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (active > MaxClients)
	{
		int slot = SlotOfEntity(client, active);
		if (slot >= 0)
		{
			int type = GetEntProp(active, Prop_Send, "m_iPrimaryAmmoType");
			if (type > 0)
				SetEntProp(client, Prop_Send, "m_iAmmo", g_Inv[client][slot].reserve, _, type);
			g_iLastActive[client] = EntIndexToEntRef(active);
		}
		ApplyModelVariant(client);
		int idx = GetEntProp(active, Prop_Send, "m_nCustomViewmodelModelIndex");
		int vm = GetEntPropEnt(client, Prop_Send, "m_hViewModel");
		if (idx > 0 && vm > MaxClients && GetEntProp(vm, Prop_Send, "m_nModelIndex") != idx)
		{
			char path[PLATFORM_MAX_PATH];
			ModelIndexToString(idx, path, sizeof(path));
			if (path[0])
				SetEntityModel(vm, path);
		}
	}
	UpdateOverlay(client);
}

/** OF: holding the DM pistol and touching another becomes Akimbo (clips added). */
bool TryAkimboUpgrade(int client, int slot, int pickupWeapon, int pickupClip, int pickupReserve)
{
	static int pistol = -2, akimbo = -2;
	if (pistol == -2)
	{
		pistol = FindWeaponById("merc_pistol");
		akimbo = FindWeaponById("merc_akimbo");
	}
	if (pistol == WEAPON_NONE || akimbo == WEAPON_NONE || pickupWeapon != pistol || g_Inv[client][slot].weapon != pistol)
		return false;
	if (!WeaponAllowedForRole(akimbo, TF2CC_GetRole(client)))
		return false;
	SyncAmmoFromEntity(client, slot);
	int clip = g_Inv[client][slot].clip;
	int reserve = g_Inv[client][slot].reserve + (pickupReserve > 0 ? pickupReserve : 0);
	WeaponDef p;
	g_Weapons.GetArray(pistol, p);
	int add = pickupClip >= 0 ? pickupClip : (p.clip > 0 ? p.clip : 15);
	if (!GiveCustomWeapon(client, akimbo, clip >= 0 ? clip + add : -1, reserve, false))
		return false;
	EmitSoundToClient(client, g_sPickupSound);
	PrintCenterText(client, "Picked up a second Pistol: Akimbo Pistols");
	int ent = EntRefToEntIndex(g_Inv[client][slot].entRef);
	if (ent > MaxClients)
		SwitchTo(client, ent);
	return true;
}

/** Merc bots on top of a weapon swap to it now and then (per 0.2 s scan). */
bool BotWantsSwap(int client)
{
	return IsFakeClient(client) && GetURandomFloat() < g_cvBotSwapChance.FloatValue;
}

/** native bool TF2CC_GetWeaponId(int weapon, char[] id, int maxlen) - weapons.cfg id, or "stock:<def>". */
public any Native_GetWeaponId(Handle plugin, int numParams)
{
	int weapon = GetNativeCell(1);
	if (weapon <= MaxClients || !IsValidEntity(weapon) || !HasEntProp(weapon, Prop_Send, "m_hOwnerEntity"))
		return false;
	int client = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
	if (client < 1 || client > MaxClients)
		return false;
	int slot = SlotOfEntity(client, weapon);
	if (slot < 0)
		return false;
	char id[48];
	if (g_Inv[client][slot].weapon >= 0)
	{
		WeaponDef w;
		g_Weapons.GetArray(g_Inv[client][slot].weapon, w);
		strcopy(id, sizeof(id), w.id);
	}
	else
		FormatEx(id, sizeof(id), "stock:%d", g_Inv[client][slot].itemdef);
	SetNativeString(2, id, GetNativeCell(3));
	return true;
}

/** The undroppable Fists fallback counts as an empty melee slot (auto-pickup). */
bool SlotOccupied(int client, int slot)
{
	if (g_Inv[client][slot].weapon == WEAPON_NONE)
		return false;
	static int fists = -2;
	if (fists == -2)
		fists = FindWeaponById("merc_fists");
	return !(slot == SLOT_MELEE && fists != WEAPON_NONE && g_Inv[client][slot].weapon == fists);
}

/**
 * A stock pickup listed in some weapon's "stock_classes" (and matching its
 * "stock_model") shows that weapon's generated viewmodel, e.g. every stock
 * shotgun uses the Merc shotgun's. The generated file is retargeted per
 * animation role (tools/gen_viewmodels.py "extra_roles"): the item's anim_slot,
 * else primary for *_primary classnames, else the weapon's own role.
 */
bool StockViewModel(const char[] classname, int itemdef, char[] out, int maxlen)
{
	out[0] = '\0';
	if (g_Weapons == null)
		return false;
	SchemaItem it;
	bool haveSchema = ResolveSchemaItem(itemdef, it);
	WeaponDef w;
	char list[164];
	for (int i = 0; i < g_Weapons.Length; i++)
	{
		g_Weapons.GetArray(i, w);
		if (!w.stockClasses[0] || !w.viewModelGen[0])
			continue;
		FormatEx(list, sizeof(list), ",%s,", w.stockClasses);
		char needle[72];
		FormatEx(needle, sizeof(needle), ",%s,", classname);
		if (StrContains(list, needle, false) == -1)
			continue;
		if (w.stockModel[0] && (!haveSchema || StrContains(it.model, w.stockModel, false) == -1))
			continue;
		char role[16];
		if (haveSchema && it.animSlot[0] && !StrEqual(it.animSlot, "-2"))
			strcopy(role, sizeof(role), it.animSlot);
		else if (StrContains(classname, "_primary") != -1)
			strcopy(role, sizeof(role), "primary");
		else
			role[0] = '\0';
		if (role[0])
		{
			StringToLower(role);
			if (RoleViewModel(w.viewModelGen, role, out, maxlen) && IsModelPrecached(out))
				return true;
		}
		strcopy(out, maxlen, w.viewModelGen);
		return IsModelPrecached(out);
	}
	return false;
}

/** ".../name__secondary.mdl" -> ".../name__<role>.mdl" */
bool RoleViewModel(const char[] generated, const char[] role, char[] out, int maxlen)
{
	int sep = StrContains(generated, "__");
	if (sep == -1)
		return false;
	strcopy(out, maxlen, generated);
	if (sep + 2 < maxlen)
		out[sep + 2] = '\0';
	Format(out, maxlen, "%s%s.mdl", out, role);
	return true;
}

void StringToLower(char[] s)
{
	for (int i = 0; s[i]; i++)
		s[i] = CharToLower(s[i]);
}

/**
 * Stock ammo sources (dispensers, resupply, dropped weapons, carts) call
 * GiveAmmo, which caps at the class-10 script's AmmoMax (100 primary/secondary
 * in playerclasses/civilian.txt on some servers), not at the slot's own maximum. Clamp
 * to the slot maximum and keep the stored reserve in step, so refills still
 * work but a 32-round shotgun never shows 100. A type shared with another slot
 * only counts for the weapon in hand (the others are swapped in on switch).
 */
void ClampReserves(int client)
{
	int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	for (int s = 0; s < SLOT_COUNT; s++)
	{
		int ent = EntRefToEntIndex(g_Inv[client][s].entRef);
		if (ent <= MaxClients)
			continue;
		int type = GetEntProp(ent, Prop_Send, "m_iPrimaryAmmoType");
		if (type <= 0 || (ent != active && OtherSlotSharesType(client, s, type)))
			continue;
		int ammo = GetEntProp(client, Prop_Send, "m_iAmmo", _, type);
		int max = g_Inv[client][s].maxReserve;
		if (max > 0 && ammo > max)
		{
			ammo = max;
			SetEntProp(client, Prop_Send, "m_iAmmo", ammo, _, type);
		}
		g_Inv[client][s].reserve = ammo;
	}
}

/**
 * Predicted weapon sounds reach everyone except the shooter (the server's
 * filter drops the predicting player; their client plays the donor's stock
 * sound itself). Send the replacement to the shooter too, from the same
 * entity with the same channel/level/volume/pitch, so it sits in the world
 * mix like everyone else hears it.
 */
void EchoToOwner(int owner, const int[] clients, int numClients, const char[] sample, int entity, int channel,
	float volume, int level, int pitch, int flags)
{
	if (g_bEchoing || !g_cvOwnerSounds.BoolValue || IsFakeClient(owner))
		return;
	for (int i = 0; i < numClients; i++)
		if (clients[i] == owner)
			return;
	g_bEchoing = true;
	EmitSoundToClient(owner, sample, entity, channel, level, flags, volume, pitch);
	g_bEchoing = false;
}

public Action Cmd_EntLeak(int client, int args)
{
	int held = 0, notHeld = 0, orphan = 0, ourHeld = 0, wearOwned = 0, wearOrphan = 0, total = 0;
	char cls[64];
	int notHeldByRole = 0;
	for (int e = MaxClients + 1; e < GetMaxEntities(); e++)
	{
		if (!IsValidEntity(e))
			continue;
		total++;
		GetEntityClassname(e, cls, sizeof(cls));
		bool weapon = StrContains(cls, "tf_weapon_") == 0;
		bool wear = StrContains(cls, "tf_wearable") == 0;
		if (!weapon && !wear)
			continue;
		int owner = HasEntProp(e, Prop_Send, "m_hOwnerEntity") ? GetEntPropEnt(e, Prop_Send, "m_hOwnerEntity") : -1;
		if (wear)
		{
			if (owner >= 1 && owner <= MaxClients && IsClientInGame(owner)) wearOwned++; else wearOrphan++;
			continue;
		}
		if (owner < 1 || owner > MaxClients || !IsClientInGame(owner))
		{
			orphan++;
			continue;
		}
		bool inList = false;
		int size = GetEntPropArraySize(owner, Prop_Send, "m_hMyWeapons");
		for (int i = 0; i < size; i++)
			if (GetEntPropEnt(owner, Prop_Send, "m_hMyWeapons", i) == e)
				inList = true;
		if (inList)
		{
			held++;
			if (SlotOfEntity(owner, e) >= 0) ourHeld++;
		}
		else
		{
			notHeld++;
			if (TF2CC_GetRole(owner) != TF2CC_ROLE_NONE) notHeldByRole++;
		}
	}
	ReplyToCommand(client, "[TF2CC] entities %d | weapons held %d (tf2cc %d), owned-not-held %d (role owners %d), orphan %d | wearables owned %d, orphan %d",
		total, held, ourHeld, notHeld, notHeldByRole, orphan, wearOwned, wearOrphan);
	// Per role player: weapons in m_hMyWeapons and owned wearables.
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || TF2CC_GetRole(i) == TF2CC_ROLE_NONE)
			continue;
		int nw = 0, size = GetEntPropArraySize(i, Prop_Send, "m_hMyWeapons");
		char list[256];
		list[0] = '\0';
		for (int k = 0; k < size; k++)
		{
			int w = GetEntPropEnt(i, Prop_Send, "m_hMyWeapons", k);
			if (w <= MaxClients)
				continue;
			nw++;
			GetEntityClassname(w, cls, sizeof(cls));
			if (strlen(list) < 200)
				Format(list, sizeof(list), "%s %s", list, cls[10]);
		}
		int nwear = 0;
		for (int e = MaxClients + 1; e < GetMaxEntities(); e++)
		{
			if (!IsValidEntity(e)) continue;
			GetEntityClassname(e, cls, sizeof(cls));
			if (StrContains(cls, "tf_wearable") == 0 && GetEntPropEnt(e, Prop_Send, "m_hOwnerEntity") == i)
				nwear++;
		}
		int act = GetEntPropEnt(i, Prop_Send, "m_hActiveWeapon");
		char actId[48] = "-", model[PLATFORM_MAX_PATH], wmodel[PLATFORM_MAX_PATH] = "-";
		int asl = act > MaxClients ? SlotOfEntity(i, act) : -1;
		if (asl >= 0 && g_Inv[i][asl].weapon >= 0)
		{
			WeaponDef aw;
			g_Weapons.GetArray(g_Inv[i][asl].weapon, aw);
			strcopy(actId, sizeof(actId), aw.id);
		}
		else if (act > MaxClients)
			GetEntityClassname(act, actId, sizeof(actId));
		GetEntPropString(i, Prop_Send, "m_iszCustomModel", model, sizeof(model));
		int wear = EntRefToEntIndex(g_iWorldWearable[i]);
		if (wear > MaxClients)
			ModelIndexToString(GetEntProp(wear, Prop_Send, "m_nModelIndex"), wmodel, sizeof(wmodel));
		ReplyToCommand(client, "  %N: %d weapons [%s ], %d wearables | active %s | world %s | model %s", i, nw, list, nwear, actId, wmodel[0] ? wmodel : "-", model);
	}
	return Plugin_Handled;
}

/** Role players are class 10; anything else is a map script's temporary class. */
bool IsRoleClass(int client)
{
	return view_as<int>(TF2_GetPlayerClass(client)) == 10;
}

/**
 * Stock pickup: play the closest Merc weapon's OF animation set in the group
 * the item really animates in (schema anim_slot, else its slot), on whichever
 * variant maps that group to that set (model_variants.cfg "sets").
 */
void StockVariant(int client, int weapon, int slot, char[] model, int maxlen)
{
	char cls[64], analog[48], set[32], group[24];
	GetEntityClassname(weapon, cls, sizeof(cls));
	if (!AnalogWeapon(cls, analog, sizeof(analog)))
		return;
	g_kvVariants.Rewind();
	if (!g_kvVariants.JumpToKey("weapon_sets"))
		return;
	g_kvVariants.GetString(analog, set, sizeof(set));
	g_kvVariants.Rewind();
	if (!set[0])
		return;
	SchemaItem it;
	if (ResolveSchemaItem(g_Inv[client][slot].itemdef, it) && it.animSlot[0] && !StrEqual(it.animSlot, "-2"))
		strcopy(group, sizeof(group), it.animSlot);
	else
		strcopy(group, sizeof(group), slot == SLOT_PRIMARY ? "PRIMARY" : (slot == SLOT_SECONDARY ? "SECONDARY" : "MELEE"));
	StringToUpper(group);
	if (!g_kvVariants.JumpToKey("sets") || !g_kvVariants.GotoFirstSubKey())
	{
		g_kvVariants.Rewind();
		return;
	}
	char have[32];
	do
	{
		g_kvVariants.GetString(group, have, sizeof(have));
		if (StrEqual(have, set, false))
		{
			g_kvVariants.GetSectionName(model, maxlen);
			break;
		}
	}
	while (g_kvVariants.GotoNextKey());
	g_kvVariants.Rewind();
}

/** Closest configured Merc weapon for a stock classname (same donor class first, then families). */
bool AnalogWeapon(const char[] cls, char[] out, int maxlen)
{
	WeaponDef w;
	for (int i = 0; i < g_Weapons.Length; i++)
	{
		g_Weapons.GetArray(i, w);
		if (StrEqual(w.classname, cls) && StrContains(w.roles, "mercenary") != -1)
		{
			strcopy(out, maxlen, w.id);
			return true;
		}
	}
	static const char families[][][] = {
		{ "tf_weapon_shotgun", "merc_shotgun" }, { "tf_weapon_sentry_revenge", "merc_shotgun" },
		{ "tf_weapon_rocketlauncher", "merc_rocketlauncher" }, { "tf_weapon_particle_cannon", "merc_rocketlauncher" },
		{ "tf_weapon_grenadelauncher", "merc_chinalake" }, { "tf_weapon_cannon", "merc_chinalake" },
		{ "tf_weapon_pipebomblauncher", "merc_dynamite" },
		{ "tf_weapon_handgun_scout_secondary", "merc_pistol" }, { "tf_weapon_pistol", "merc_pistol" },
		{ "tf_weapon_handgun_scout_primary", "merc_assaultrifle" },
		{ "tf_weapon_charged_smg", "merc_smg" }, { "tf_weapon_smg", "merc_smg" },
		{ "tf_weapon_sniperrifle", "merc_railgun" }, { "tf_weapon_minigun", "merc_gatling" },
		{ "tf_weapon_scattergun", "merc_supershotgun" }, { "tf_weapon_soda_popper", "merc_supershotgun" },
		{ "tf_weapon_pep_brawler_blaster", "merc_supershotgun" },
		{ "tf_weapon_revolver", "merc_revolver" }, { "tf_weapon_syringegun", "merc_nailgun" },
		{ "tf_weapon_crossbow", "merc_sawballista" }, { "tf_weapon_knife", "merc_knife" },
		{ "tf_weapon_fists", "merc_fists" }
	};
	for (int i = 0; i < sizeof(families); i++)
	{
		if (StrContains(cls, families[i][0]) == 0)
		{
			strcopy(out, maxlen, families[i][1]);
			return true;
		}
	}
	// Any other melee weapon swings like the crowbar.
	static const char melee[][] = { "tf_weapon_bat", "tf_weapon_bottle", "tf_weapon_fireaxe", "tf_weapon_club", "tf_weapon_shovel",
		"tf_weapon_wrench", "tf_weapon_bonesaw", "tf_weapon_sword", "tf_weapon_katana", "tf_weapon_robot_arm",
		"tf_weapon_breakable_sign", "tf_weapon_stickbomb", "tf_weapon_slap", "tf_weapon_saxxy" };
	for (int i = 0; i < sizeof(melee); i++)
	{
		if (StrContains(cls, melee[i]) == 0)
		{
			strcopy(out, maxlen, "merc_crowbar");
			return true;
		}
	}
	return false;
}

void StringToUpper(char[] s)
{
	for (int i = 0; s[i]; i++)
		s[i] = CharToUpper(s[i]);
}
