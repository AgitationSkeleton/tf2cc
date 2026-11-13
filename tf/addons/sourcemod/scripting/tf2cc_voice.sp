/**
 * tf2cc_voice - role voice personas.
 *
 * Stock speech of a role player (response rules - e.g. a server's legacy
 * class-10 talker that maps them to Soldier scenes - pain/death sounds from
 * the class-10 class data, auto lines) is rewritten to the persona's line for
 * the same concept, or blocked (Hook_StockSpeech). This module also speaks:
 *  - voicemenu commands (routed by tf2cc_core after interactive uses),
 *  - "Spy!" callouts keyed by the spotted spy's disguise class (TF2C/OF
 *    CloakedSpyIdentify01-09 ordering),
 *  - pain, death, ignition, domination/revenge, capture events,
 *  - the stock "(Voice)" chat subtitle via the VoiceSubtitle user message.
 * Concept names are the keys of the legacy voicechanger.cfg so its curated
 * line lists are reused verbatim (config/tf2cc/voice.cfg).
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2>
#include <tf2_stocks>
#include <tf2cc>

public Plugin myinfo =
{
	name = "TF2CC Voice",
	author = "tf2cc-rework",
	description = "Voice personas for custom roles",
	version = TF2CC_VERSION,
	url = ""
};

#define CONFIG_VOICE "configs/tf2cc/voice.cfg"

KeyValues g_kv;
StringMap g_MenuMap;        // "menu item" -> concept
StringMap g_Concepts;       // "persona/concept" -> ArrayList of samples

ConVar g_cvDelay;
ConVar g_cvLevel;
ConVar g_cvSubtitles;
ConVar g_cvStockDelay;     // tf_max_voice_speak_delay

float g_flNextSpeak[MAXPLAYERS + 1];   // voice-menu cooldown only
float g_flLastStock[MAXPLAYERS + 1];   // last rewritten stock line
float g_flLastEvent[MAXPLAYERS + 1];   // last event-driven line
bool g_bOwnEmit;
bool g_bDiedLastLife[MAXPLAYERS + 1];
int g_iForcedSpyTarget = -1;     // sm_tf2cc_spytest
char g_sLastSpyConcept[64];
StringMap g_PersonaSamples;           // "persona|sample" -> true
float g_flNextPain[MAXPLAYERS + 1];

// Disguise class (TFClassType) -> CloakedSpyIdentify index used by TF2C/OF lines.
// TFClassType -> TF2C cloakedspyidentify number (TF2C talker: scout 01, soldier 02,
// heavy 03, pyro 04, demoman 05, spy 06, medic 07, engineer 08, sniper 09).
static const int g_iSpyIdentify[] = { 0, 1, 9, 2, 5, 7, 3, 4, 6, 8 };

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNative("TF2CC_Speak", Native_Speak);
	RegPluginLibrary("tf2cc_voice");
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvDelay = CreateConVar("tf2cc_voice_delay", "-1", "Seconds between voice-menu lines per player; -1 = follow tf_max_voice_speak_delay (negative there = no delay).");
	g_cvSubtitles = CreateConVar("tf2cc_voice_subtitles", "0", "Send the stock (Voice) chat subtitle for role voice-menu lines.", _, true, 0.0, true, 1.0);
	g_cvStockDelay = FindConVar("tf_max_voice_speak_delay");
	AddNormalSoundHook(Hook_StockSpeech);
	g_cvLevel = CreateConVar("tf2cc_voice_level", "95", "Sound level (dB) for role voice lines (TF2 voice uses 95).");
	AutoExecConfig(true, "tf2cc_voice");

	RegAdminCmd("sm_tf2cc_voice_reload", Cmd_Reload, ADMFLAG_CONFIG, "Reload voice.cfg.");
	RegAdminCmd("sm_tf2cc_spyaim", Cmd_SpyAim, ADMFLAG_CHEATS, "sm_tf2cc_spyaim <speaker> <target> - aim the speaker at the target and run the normal Spy! callout (real targeting).");
	RegAdminCmd("sm_tf2cc_spytest", Cmd_SpyTest, ADMFLAG_CHEATS, "sm_tf2cc_spytest <speaker> <target> - run the Spy! callout logic and report the chosen concept.");
	RegAdminCmd("sm_tf2cc_speak", Cmd_Speak, ADMFLAG_CHEATS, "sm_tf2cc_speak <concept> - test a concept on yourself.");

	HookEvent("player_hurt", Event_PlayerHurt);
	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("player_ignited", Event_PlayerIgnited);
	HookEvent("teamplay_point_captured", Event_PointCaptured);
	HookEvent("teamplay_flag_event", Event_FlagEvent);
	AddCommandListener(Listener_StockVoice, "voicemenu");
	AddCommandListener(Listener_Taunt, "taunt");
	AddCommandListener(Listener_Taunt, "+taunt");

	LoadVoice();
}

public void OnMapStart()
{
	PrecacheAll();
}

public void OnClientPutInServer(int client)
{
	g_flNextSpeak[client] = 0.0;
	g_flNextPain[client] = 0.0;
	g_flLastStock[client] = 0.0;
	g_flLastEvent[client] = 0.0;
}

public Action Cmd_Reload(int client, int args)
{
	LoadVoice();
	PrecacheAll();
	ReplyToCommand(client, "[TF2CC] voice.cfg reloaded.");
	return Plugin_Handled;
}

public Action Cmd_Speak(int client, int args)
{
	if (!client || args < 1)
		return Plugin_Handled;
	char concept[64];
	GetCmdArg(1, concept, sizeof(concept));
	if (!Speak(client, concept))
		ReplyToCommand(client, "[TF2CC] No lines for '%s' in your persona.", concept);
	return Plugin_Handled;
}

/** Reads "targeted" (cursor on it) into g_Concepts as "@targeted/<speaker>/<role>/<kind>". */
void LoadTargeted()
{
	char speaker[32], role[32], kind[32], key[160], sample[PLATFORM_MAX_PATH];
	if (!g_kv.GotoFirstSubKey())
		return;
	do
	{
		g_kv.GetSectionName(speaker, sizeof(speaker));
		if (!g_kv.GotoFirstSubKey())
			continue;
		do
		{
			g_kv.GetSectionName(role, sizeof(role));
			if (!g_kv.GotoFirstSubKey())
				continue;
			do
			{
				g_kv.GetSectionName(kind, sizeof(kind));
				ArrayList list = new ArrayList(PLATFORM_MAX_PATH);
				if (g_kv.GotoFirstSubKey(false))
				{
					do
					{
						g_kv.GetString(NULL_STRING, sample, sizeof(sample));
						if (sample[0])
							list.PushString(sample);
					}
					while (g_kv.GotoNextKey(false));
					g_kv.GoBack();
				}
				FormatEx(key, sizeof(key), "@targeted/%s/%s/%s", speaker, role, kind);
				g_Concepts.SetValue(key, list);
			}
			while (g_kv.GotoNextKey());
			g_kv.GoBack();
		}
		while (g_kv.GotoNextKey());
		g_kv.GoBack();
	}
	while (g_kv.GotoNextKey());
	g_kv.GoBack();
}

void LoadVoice()
{
	if (g_Concepts != null)
	{
		StringMapSnapshot snap = g_Concepts.Snapshot();
		char key[128];
		for (int i = 0; i < snap.Length; i++)
		{
			snap.GetKey(i, key, sizeof(key));
			ArrayList list;
			g_Concepts.GetValue(key, list);
			delete list;
		}
		delete snap;
	}
	delete g_Concepts;
	delete g_MenuMap;
	delete g_kv;
	delete g_PersonaSamples;
	g_PersonaSamples = new StringMap();
	g_Concepts = new StringMap();
	g_MenuMap = new StringMap();

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), CONFIG_VOICE);
	g_kv = new KeyValues("tf2cc_voice");
	if (!g_kv.ImportFromFile(path))
	{
		LogError("tf2cc_voice: cannot read %s", path);
		return;
	}

	char section[64], concept[64], key[128], sample[PLATFORM_MAX_PATH];
	if (!g_kv.GotoFirstSubKey())
		return;
	do
	{
		g_kv.GetSectionName(section, sizeof(section));
		if (StrEqual(section, "voicemenu"))
		{
			if (g_kv.GotoFirstSubKey(false))
			{
				do
				{
					g_kv.GetSectionName(key, sizeof(key));
					g_kv.GetString(NULL_STRING, concept, sizeof(concept));
					g_MenuMap.SetString(key, concept);
				}
				while (g_kv.GotoNextKey(false));
				g_kv.GoBack();
			}
			continue;
		}
		if (StrEqual(section, "targeted"))
		{
			LoadTargeted();
			continue;
		}
		// persona section: concept -> numbered samples
		if (!g_kv.GotoFirstSubKey())
			continue;
		do
		{
			g_kv.GetSectionName(concept, sizeof(concept));
			ArrayList list = new ArrayList(PLATFORM_MAX_PATH);
			if (g_kv.GotoFirstSubKey(false))
			{
				do
				{
					g_kv.GetString(NULL_STRING, sample, sizeof(sample));
					if (sample[0])
					{
						list.PushString(sample);
						char pkey[PLATFORM_MAX_PATH + 64];
						FormatEx(pkey, sizeof(pkey), "%s|%s", section, sample);
						g_PersonaSamples.SetValue(pkey, true);
					}
				}
				while (g_kv.GotoNextKey(false));
				g_kv.GoBack();
			}
			FormatEx(key, sizeof(key), "%s/%s", section, concept);
			g_Concepts.SetValue(key, list);
		}
		while (g_kv.GotoNextKey());
		g_kv.GoBack();
	}
	while (g_kv.GotoNextKey());
	g_kv.Rewind();
}

void PrecacheAll()
{
	if (g_Concepts == null)
		return;
	StringMapSnapshot snap = g_Concepts.Snapshot();
	char key[128], sample[PLATFORM_MAX_PATH];
	for (int i = 0; i < snap.Length; i++)
	{
		snap.GetKey(i, key, sizeof(key));
		ArrayList list;
		g_Concepts.GetValue(key, list);
		for (int j = 0; j < list.Length; j++)
		{
			list.GetString(j, sample, sizeof(sample));
			PrecacheSound(sample, true);
		}
	}
	delete snap;
}

/** Persona for a client = role's "voice" key, default the role key. */
bool GetPersona(int client, char[] persona, int maxlen)
{
	int role = TF2CC_GetRole(client);
	if (role == TF2CC_ROLE_NONE)
		return false;
	if (!TF2CC_GetRoleString(role, "voice", persona, maxlen) || !persona[0])
		TF2CC_GetRoleKey(role, persona, maxlen);
	return true;
}

float MenuDelay()
{
	float d = g_cvDelay.FloatValue;
	if (d < 0.0)
		d = g_cvStockDelay != null ? g_cvStockDelay.FloatValue : 1.5;
	return d < 0.0 ? 0.0 : d;
}

/** Persona line list for a concept; legacy keys may carry a trailing "0" (_medic0). */
ArrayList ConceptList(const char[] persona, const char[] concept)
{
	char key[128];
	ArrayList list;
	FormatEx(key, sizeof(key), "%s/%s", persona, concept);
	if (g_Concepts.GetValue(key, list) && list.Length)
		return list;
	FormatEx(key, sizeof(key), "%s/%s0", persona, concept);
	if (g_Concepts.GetValue(key, list) && list.Length)
		return list;
	return null;
}

/** menu = voice-menu line (cooldown applies); other lines never touch the menu cooldown. */
bool Speak(int client, const char[] concept, bool menu = false)
{
	char persona[64];
	if (!GetPersona(client, persona, sizeof(persona)))
		return false;
	float now = GetGameTime();
	if (menu && now < g_flNextSpeak[client])
		return false;
	ArrayList list = ConceptList(persona, concept);
	if (list == null)
		return false;
	strcopy(g_sLastSpyConcept, sizeof(g_sLastSpyConcept), concept);

	char sample[PLATFORM_MAX_PATH];
	list.GetString(GetRandomInt(0, list.Length - 1), sample, sizeof(sample));
	g_bOwnEmit = true;
	EmitSoundToAll(sample, client, SNDCHAN_VOICE, g_cvLevel.IntValue);
	g_bOwnEmit = false;
	if (menu)
		g_flNextSpeak[client] = now + MenuDelay();
	else
		g_flLastEvent[client] = now;
	return true;
}

/**
 * Stock speech from a role player: TF2 still runs response rules, class-10
 * death sounds and auto lines for class 10 (some servers ship a legacy talker mapping them
 * to Soldier scenes). vo/<class>_<concept>NN -> persona "_<concept>", else blocked.
 */
public Action Hook_StockSpeech(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH], int &entity, int &channel, float &volume, int &level, int &pitch, int &flags, char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
	if (g_bOwnEmit || entity < 1 || entity > MaxClients || !IsClientInGame(entity) || TF2CC_GetRole(entity) == TF2CC_ROLE_NONE)
		return Plugin_Continue;
	int start = 0;
	while (sample[start] == ')' || sample[start] == '^' || sample[start] == '*' || sample[start] == '#' || sample[start] == '<' || sample[start] == '>')
		start++;
	if (StrContains(sample[start], "vo/", false) != 0 || StrContains(sample[start], "vo/tf2cc/", false) == 0)
		return Plugin_Continue;
	char persona[64];
	if (!GetPersona(entity, persona, sizeof(persona)))
		return Plugin_Continue;
	if (IsPersonaSample(persona, sample[start]))
		return Plugin_Continue;

	float now = GetGameTime();
	if (now - g_flLastEvent[entity] < 0.3)
		return Plugin_Stop;   // our event line already covers it
	char concept[64];
	if (!StockConcept(sample[start], concept, sizeof(concept)))
		return Plugin_Stop;
	ArrayList list = ConceptList(persona, concept);
	if (list == null)
		return Plugin_Stop;
	list.GetString(GetRandomInt(0, list.Length - 1), sample, sizeof(sample));
	g_flLastStock[entity] = now;
	return Plugin_Changed;
}

/** "vo/taunts/soldier_painsharp03.mp3" -> "_painsharp". */
bool StockConcept(const char[] path, char[] concept, int maxlen)
{
	int slash = FindCharInString(path, '/', true);
	char base[96];
	strcopy(base, sizeof(base), path[slash + 1]);
	int us = FindCharInString(base, '_');
	if (us < 0)
		return false;
	int dot = FindCharInString(base, '.', true);
	if (dot > 0)
		base[dot] = '\0';
	int end = strlen(base);
	while (end > us + 1 && IsCharNumeric(base[end - 1]))
		end--;
	base[end] = '\0';
	FormatEx(concept, maxlen, "_%s", base[us + 1]);
	return end > us + 1;
}

bool IsPersonaSample(const char[] persona, const char[] sample)
{
	if (g_PersonaSamples == null)
		return false;
	char key[PLATFORM_MAX_PATH + 64];
	FormatEx(key, sizeof(key), "%s|%s", persona, sample);
	bool v;
	return g_PersonaSamples.GetValue(key, v);
}

public any Native_Speak(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	char concept[64];
	GetNativeString(2, concept, sizeof(concept));
	if (!TF2CC_IsValidClient(client))
		return false;
	return Speak(client, concept);
}

/* ------------------------------------------------------------------------- */

public void TF2CC_OnVoiceMenu(int client, int menu, int item)
{
	if (!IsPlayerAlive(client))
		return;
	char key[8], concept[64];
	FormatEx(key, sizeof(key), "%d %d", menu, item);
	if (!g_MenuMap.GetString(key, concept, sizeof(concept)))
		return;

	if (menu == 0 && item == 0)
	{
		// Stock only raises the medic bubble when a response rule fires, which
		// never happens for class 10 (CTFPlayer::SpeakConceptIfAllowed ->
		// SaveMe). Toggle the networked parity like SaveMe() does.
		SetEntProp(client, Prop_Send, "m_bSaveMeParity", !GetEntProp(client, Prop_Send, "m_bSaveMeParity"));
	}

	if (StrEqual(concept, "@spy"))
	{
		SpyCallout(client);
	}
	else if (!Speak(client, concept, true))
	{
		return;
	}
	if (g_cvSubtitles.BoolValue)
		SendVoiceSubtitle(client, menu, item);
}

/**
 * "Spy!" aimed at an enemy: like stock TF2 the line names the class under the
 * crosshair (a disguised spy's disguise class; an enemy role player's role).
 * Persona keys "_spy_<class|role>" (class-named, OF-verified) win; legacy
 * numbered "_cloakedspyidentifyNN" keys (TF2C ordering) are the fallback.
 */
public Action Cmd_SpyTest(int client, int args)
{
	char a[64], b[64];
	GetCmdArg(1, a, sizeof(a));
	GetCmdArg(2, b, sizeof(b));
	int sp = FindTarget(client, a, false, false), tg = FindTarget(client, b, false, false);
	if (sp <= 0 || tg <= 0)
		return Plugin_Handled;
	g_flNextSpeak[sp] = 0.0;
	g_iForcedSpyTarget = tg;
	g_sLastSpyConcept[0] = '\0';
	SpyCallout(sp);
	g_iForcedSpyTarget = -1;
	ReplyToCommand(client, "[TF2CC] %N -> %N (class %d, role %d): played '%s'", sp, tg, view_as<int>(TF2_GetPlayerClass(tg)), TF2CC_GetRole(tg), g_sLastSpyConcept[0] ? g_sLastSpyConcept : "(nothing)");
	return Plugin_Handled;
}

void SpyCallout(int client)
{
	static const char names[][] = { "", "scout", "sniper", "soldier", "demoman", "medic", "heavy", "pyro", "spy", "engineer" };
	int target = SpyTarget(client);
	if (target > 0)
	{
		char concept[64];
		int targetRole = TF2CC_GetRole(target);
		if (targetRole != TF2CC_ROLE_NONE)
		{
			char roleKey[TF2CC_ROLE_KEY_LEN];
			TF2CC_GetRoleKey(targetRole, roleKey, sizeof(roleKey));
			FormatEx(concept, sizeof(concept), "_spy_%s", roleKey);
			if (Speak(client, concept))
				return;
		}
		else
		{
			int cls = view_as<int>(TF2_GetPlayerClass(target));
			if (TF2_GetPlayerClass(target) == TFClass_Spy && TF2_IsPlayerInCondition(target, TFCond_Disguised))
				cls = GetEntProp(target, Prop_Send, "m_nDisguiseClass");
			if (cls >= 1 && cls <= 9)
			{
				FormatEx(concept, sizeof(concept), "_spy_%s", names[cls]);
				if (Speak(client, concept, true))
					return;
				FormatEx(concept, sizeof(concept), "_cloakedspyidentify%02d", g_iSpyIdentify[cls]);
				if (Speak(client, concept, true))
					return;
			}
		}
	}
	Speak(client, "_cloakedspy", true);
}

/**
 * Enemy under the crosshair, or failing an exact hit (cosmetics, robot
 * models and attachments often catch the trace) the visible enemy whose
 * head, chest or feet is closest to the crosshair within ~18 degrees.
 */
int SpyTarget(int client)
{
	if (g_iForcedSpyTarget > 0)
		return g_iForcedSpyTarget;
	int target = GetClientAimTarget(client, true);
	if (target > 0 && GetClientTeam(target) != GetClientTeam(client))
		return target;
	float eye[3], ang[3], fwd[3], origin[3], pos[3], dir[3];
	GetClientEyePosition(client, eye);
	GetClientEyeAngles(client, ang);
	GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
	float best = 0.95;   // cos(~18 deg)
	int found = -1;
	static const float heights[3] = { 64.0, 40.0, 12.0 };
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == client || !IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) == GetClientTeam(client))
			continue;
		GetClientAbsOrigin(i, origin);
		for (int h = 0; h < 3; h++)
		{
			pos[0] = origin[0];
			pos[1] = origin[1];
			pos[2] = origin[2] + heights[h];
			MakeVectorFromPoints(eye, pos, dir);
			float dist = NormalizeVector(dir, dir);
			if (dist > 2500.0)
				break;
			float dot = GetVectorDotProduct(fwd, dir);
			if (dot <= best)
				continue;
			// World brushes only: players' cosmetics/attachments must not count as walls.
			Handle tr = TR_TraceRayFilterEx(eye, pos, MASK_SOLID_BRUSHONLY, RayType_EndPoint, Filter_OnlyWorld);
			bool visible = !TR_DidHit(tr);
			delete tr;
			if (!visible)
				continue;
			best = dot;
			found = i;
		}
	}
	return found;
}

public bool Filter_OnlyWorld(int entity, int mask)
{
	return entity == 0;
}

void SendVoiceSubtitle(int client, int menu, int item)
{
	// Stock client renders "(Voice) Name: <line>" from (client, menu, item)
	// (hud_basechat.cpp:958); stock sends it to teammates only.
	int clients[MAXPLAYERS];
	int count = 0;
	int team = GetClientTeam(client);
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == team)
			clients[count++] = i;
	if (!count)
		return;
	Handle msg = StartMessage("VoiceSubtitle", clients, count, USERMSG_RELIABLE);
	if (msg == null)
		return;
	BfWrite bf = UserMessageToBfWrite(msg);
	bf.WriteByte(client);
	bf.WriteByte(menu);
	bf.WriteByte(item);
	EndMessage();
}

public Action Listener_Taunt(int client, const char[] command, int argc)
{
	if (!TF2CC_IsValidClient(client) || TF2CC_GetRole(client) == TF2CC_ROLE_NONE || !IsPlayerAlive(client))
		return Plugin_Continue;
	// Stock class-10 taunts have no scenes. Until tf2cc_taunts provides scene
	// playback, speak a taunt line and swallow the command (legacy
	// "blocknormaltaunt"), so no half-initialised taunt state is created.
	if (!LibraryExists("tf2cc_taunts"))
	{
		if (!Speak(client, "_taunts"))
			Speak(client, "_laughlong");
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

/* ------------------------------------------------------------------------- */
/* Event-driven lines                                                        */
/* ------------------------------------------------------------------------- */

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (!TF2CC_IsValidClient(victim) || TF2CC_GetRole(victim) == TF2CC_ROLE_NONE || event.GetInt("health") <= 0)
		return;
	float now = GetGameTime();
	if (now < g_flNextPain[victim])
		return;
	g_flNextPain[victim] = now + 1.0;
	int dmg = event.GetInt("damageamount");
	if (now - g_flLastStock[victim] < 0.3)
		return;   // the stock pain line was already rewritten
	Speak(victim, dmg >= 30 ? "_painsevere" : "_painsharp");
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	int deathFlags = event.GetInt("death_flags");

	if (TF2CC_IsValidClient(victim) && !(deathFlags & 32))
		g_bDiedLastLife[victim] = true;
	if (TF2CC_IsValidClient(victim) && TF2CC_GetRole(victim) != TF2CC_ROLE_NONE && !(deathFlags & 32))
	{
		bool crit = event.GetInt("customkill") == 1 || event.GetInt("crit_type") == 2;
		if (GetGameTime() - g_flLastStock[victim] >= 0.3)
			Speak(victim, crit ? "_paincrticialdeath" : "_painsevere");
	}

	if (TF2CC_IsValidClient(attacker) && attacker != victim && TF2CC_GetRole(attacker) != TF2CC_ROLE_NONE && IsPlayerAlive(attacker))
	{
		if (deathFlags & 1)       // TF_DEATHFLAG_KILLERDOMINATION
			Speak(attacker, "_domination");
		else if (deathFlags & 4)  // TF_DEATHFLAG_KILLERREVENGE
			Speak(attacker, "_revenge");
	}

	// Stock classes' Open Fortress lines about a role victim (e.g. Scout
	// dominating a Mercenary). Played just after the stock line so it takes
	// over the speaker's voice channel.
	if (TF2CC_IsValidClient(attacker) && attacker != victim && TF2CC_GetRole(attacker) == TF2CC_ROLE_NONE
		&& TF2CC_IsValidClient(victim) && TF2CC_GetRole(victim) != TF2CC_ROLE_NONE && (deathFlags & (1 | 4)))
	{
		DataPack pack = new DataPack();
		pack.WriteCell(GetClientUserId(attacker));
		pack.WriteCell(TF2CC_GetRole(victim));
		pack.WriteString((deathFlags & 1) ? "domination" : "revenge");
		CreateTimer(0.15, Timer_TargetedLine, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
	}
}

public Action Timer_TargetedLine(Handle timer, DataPack pack)
{
	pack.Reset();
	int speaker = GetClientOfUserId(pack.ReadCell());
	int role = pack.ReadCell();
	char kind[16];
	pack.ReadString(kind, sizeof(kind));
	if (speaker && IsPlayerAlive(speaker))
		SpeakTargeted(speaker, role, kind);
	return Plugin_Stop;
}

static const char g_sStockVoiceClass[][] = { "", "scout", "sniper", "soldier", "demoman", "medic", "heavy", "pyro", "spy", "engineer" };

/** voice.cfg "targeted" { <speaker class> { <role key> { <kind> { "1" "file" } } } } */
bool SpeakTargeted(int speaker, int role, const char[] kind)
{
	int cls = view_as<int>(TF2_GetPlayerClass(speaker));
	if (cls < 1 || cls > 9 || g_kv == null)
		return false;
	char roleKey[TF2CC_ROLE_KEY_LEN], key[160];
	TF2CC_GetRoleKey(role, roleKey, sizeof(roleKey));
	FormatEx(key, sizeof(key), "@targeted/%s/%s/%s", g_sStockVoiceClass[cls], roleKey, kind);
	ArrayList list;
	if (!g_Concepts.GetValue(key, list) || list.Length == 0)
		return false;
	char sample[PLATFORM_MAX_PATH];
	list.GetString(GetRandomInt(0, list.Length - 1), sample, sizeof(sample));
	EmitSoundToAll(sample, speaker, SNDCHAN_VOICE, g_cvLevel.IntValue);
	return true;
}

/** Stock players calling "Spy!" at an enemy role player use the OF line for that role. */
public Action Listener_StockVoice(int client, const char[] command, int argc)
{
	if (!TF2CC_IsValidClient(client) || !IsPlayerAlive(client) || TF2CC_GetRole(client) != TF2CC_ROLE_NONE || argc < 2)
		return Plugin_Continue;
	char a[8], b[8];
	GetCmdArg(1, a, sizeof(a));
	GetCmdArg(2, b, sizeof(b));
	if (StringToInt(a) != 1 || StringToInt(b) != 1)
		return Plugin_Continue;
	int target = SpyTarget(client);
	if (target <= 0 || TF2CC_GetRole(target) == TF2CC_ROLE_NONE)
		return Plugin_Continue;
	float now = GetGameTime();
	if (now < g_flNextSpeak[client])
		return Plugin_Handled;
	if (!SpeakTargeted(client, TF2CC_GetRole(target), "cloakedspy"))
		return Plugin_Continue; // no OF line for this speaker: keep the stock generic "Spy!"
	g_flNextSpeak[client] = now + MenuDelay();
	if (g_cvSubtitles.BoolValue)
		SendVoiceSubtitle(client, 1, 1);
	return Plugin_Handled;
}

public void Event_PlayerIgnited(Event event, const char[] name, bool dontBroadcast)
{
	int victim = event.GetInt("victim_entindex");
	if (TF2CC_IsValidClient(victim) && TF2CC_GetRole(victim) != TF2CC_ROLE_NONE && IsPlayerAlive(victim))
		Speak(victim, "_autoonfire");
}

public void Event_PointCaptured(Event event, const char[] name, bool dontBroadcast)
{
	char cappers[64];
	event.GetString("cappers", cappers, sizeof(cappers));
	for (int i = 0; cappers[i] != '\0'; i++)
	{
		int client = cappers[i];
		if (TF2CC_IsValidClient(client) && TF2CC_GetRole(client) != TF2CC_ROLE_NONE && IsPlayerAlive(client))
			Speak(client, "_autocappedcontrolpoint");
	}
}

public void Event_FlagEvent(Event event, const char[] name, bool dontBroadcast)
{
	int type = event.GetInt("eventtype");
	if (type == 1) // TF_FLAGEVENT_PICKEDUP: OF/TF2C ConceptPlayerGrabbedIntelligence
	{
		int grabber = event.GetInt("player");
		if (TF2CC_IsValidClient(grabber) && TF2CC_GetRole(grabber) != TF2CC_ROLE_NONE && IsPlayerAlive(grabber))
			Speak(grabber, "_autograbbedintelligence");
		return;
	}
	if (type != 2) // TF_FLAGEVENT_CAPTURED
		return;
	int client = event.GetInt("player");
	if (TF2CC_IsValidClient(client) && TF2CC_GetRole(client) != TF2CC_ROLE_NONE && IsPlayerAlive(client))
		Speak(client, "_autocappedintelligence");
}

public Action Cmd_SpyAim(int client, int args)
{
	char a[64], b[64];
	GetCmdArg(1, a, sizeof(a));
	GetCmdArg(2, b, sizeof(b));
	int sp = FindTarget(client, a, false, false), tg = FindTarget(client, b, false, false);
	if (sp <= 0 || tg <= 0)
		return Plugin_Handled;
	float eye[3], pos[3], dir[3], ang[3];
	GetClientEyePosition(sp, eye);
	GetClientAbsOrigin(tg, pos);
	pos[2] += 40.0;
	MakeVectorFromPoints(eye, pos, dir);
	GetVectorAngles(dir, ang);
	TeleportEntity(sp, NULL_VECTOR, ang, NULL_VECTOR);
	g_flNextSpeak[sp] = 0.0;
	g_sLastSpyConcept[0] = '\0';
	int aim = GetClientAimTarget(sp, true);
	int picked = SpyTarget(sp);
	SpyCallout(sp);
	ReplyToCommand(client, "[TF2CC] %N -> %N (class %d role %d): aim=%d picked=%d played '%s'", sp, tg, view_as<int>(TF2_GetPlayerClass(tg)), TF2CC_GetRole(tg), aim, picked, g_sLastSpyConcept[0] ? g_sLastSpyConcept : "(nothing)");
	return Plugin_Handled;
}

/* OF PlayerRespawn(Killed)Mercenary: 30% on spawn, "killed" set after a death. */

public void TF2CC_OnRoleSpawned(int client, int role)
{
	bool killed = g_bDiedLastLife[client];
	g_bDiedLastLife[client] = false;
	if (GetURandomFloat() >= 0.3)
		return;
	DataPack dp;
	CreateDataTimer(0.5, Timer_RespawnLine, dp, TIMER_FLAG_NO_MAPCHANGE);
	dp.WriteCell(GetClientUserId(client));
	dp.WriteCell(killed);
}

public Action Timer_RespawnLine(Handle timer, DataPack dp)
{
	dp.Reset();
	int client = GetClientOfUserId(dp.ReadCell());
	bool killed = dp.ReadCell() != 0;
	if (client && IsPlayerAlive(client) && !(killed && Speak(client, "_respawnkilled")))
		Speak(client, "_respawn");
	return Plugin_Stop;
}
