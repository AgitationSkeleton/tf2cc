/**
 * tf2cc_hud - item meters for role players.
 *
 * The stock client builds item effect meters per stock class
 * (CHudItemEffectMeter::CreateHudElementsForClass), so class 10 never gets
 * the Bonk/Cleaver/Jarate recharge, rage, hype, shield charge or energy
 * meters of weapons it picks up. This draws them as a small HUD text block
 * (netprops as in the Randomizer plugin's huds.cfg). Item state only; no
 * class identity text.
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <tf2>
#include <tf2_stocks>
#include <tf2cc>

public Plugin myinfo =
{
	name = "TF2CC HUD",
	author = "tf2cc-rework",
	description = "Item meters for custom roles",
	version = TF2CC_VERSION,
	url = ""
};

ConVar g_cvEnabled, g_cvX, g_cvY;
Handle g_hHud;

public void OnPluginStart()
{
	g_cvEnabled = CreateConVar("tf2cc_hud_meters", "1", "Show item meters (recharge, rage, charge, energy...) to role players.", _, true, 0.0, true, 1.0);
	g_cvX = CreateConVar("tf2cc_hud_meters_x", "0.73", "Meter block X (0-1, -1 = centre).");
	g_cvY = CreateConVar("tf2cc_hud_meters_y", "0.72", "Meter block Y (0-1).");
	AutoExecConfig(true, "tf2cc_hud");
	g_hHud = CreateHudSynchronizer();
	CreateTimer(0.2, Timer_Hud, _, TIMER_REPEAT);
}

public Action Timer_Hud(Handle timer)
{
	if (!g_cvEnabled.BoolValue || g_hHud == null)
		return Plugin_Continue;
	char text[256];
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client) || TF2CC_GetRole(client) == TF2CC_ROLE_NONE)
			continue;
		BuildMeters(client, text, sizeof(text));
		if (!text[0])
			continue;
		SetHudTextParams(g_cvX.FloatValue, g_cvY.FloatValue, 0.3, 255, 255, 255, 220, 0, 0.0, 0.0, 0.0);
		ShowSyncHudText(client, g_hHud, "%s", text);
	}
	return Plugin_Continue;
}

void AddLine(char[] text, int maxlen, const char[] fmt, any ...)
{
	char line[64];
	VFormat(line, sizeof(line), fmt, 4);
	if (text[0])
		StrCat(text, maxlen, "\n");
	StrCat(text, maxlen, line);
}

void BuildMeters(int client, char[] text, int maxlen)
{
	text[0] = '\0';
	float now = GetGameTime();
	bool rage, hype, items, decap, revenge;
	char cls[64];
	for (int i = 0; i < 8; i++)
	{
		int w = GetPlayerWeaponSlot(client, i);
		// tf2cc custom weapons (custom viewmodel, repurposed flag) never show their donor's meter.
		if (w <= MaxClients || GetEntProp(w, Prop_Send, "m_bBeingRepurposedForTaunt"))
			continue;
		GetEntityClassname(w, cls, sizeof(cls));

		if (HasEntProp(w, Prop_Send, "m_flEffectBarRegenTime") && (StrContains(cls, "tf_weapon_jar") == 0
			|| StrEqual(cls, "tf_weapon_cleaver") || StrEqual(cls, "tf_weapon_bat_wood") || StrEqual(cls, "tf_weapon_bat_giftwrap")
			|| StrContains(cls, "tf_weapon_lunchbox") == 0) && !StrEqual(cls, "tf_weapon_jar_gas"))
		{
			int type = GetEntProp(w, Prop_Send, "m_iPrimaryAmmoType");
			float regen = GetEntPropFloat(w, Prop_Send, "m_flEffectBarRegenTime");
			if (type > 0 && GetEntProp(client, Prop_Send, "m_iAmmo", _, type) > 0)
				AddLine(text, maxlen, "%s: Ready", ShortName(cls));
			else if (regen > now)
				AddLine(text, maxlen, "%s: %.0fs", ShortName(cls), regen - now);
		}
		if (StrEqual(cls, "tf_weapon_particle_cannon") || StrEqual(cls, "tf_weapon_raygun") || StrEqual(cls, "tf_weapon_drg_pomson"))
			AddLine(text, maxlen, "Energy: %.0f%%", GetEntPropFloat(w, Prop_Send, "m_flEnergy") * 5.0);
		if (StrEqual(cls, "tf_weapon_buff_item") || StrEqual(cls, "tf_weapon_flamethrower") || StrEqual(cls, "tf_weapon_sniperrifle"))
			rage = true;
		if (StrEqual(cls, "tf_weapon_soda_popper") || StrEqual(cls, "tf_weapon_pep_brawler_blaster"))
			hype = true;
		if (StrEqual(cls, "tf_weapon_rocketpack") || StrEqual(cls, "tf_weapon_jar_gas") || StrEqual(cls, "tf_weapon_lunchbox"))
			items = true;
		if (StrEqual(cls, "tf_weapon_sword") || StrEqual(cls, "tf_weapon_rocketlauncher_airstrike") || StrEqual(cls, "tf_weapon_sniperrifle_decap"))
			decap = true;
		if (StrEqual(cls, "tf_weapon_flaregun_revenge") || StrEqual(cls, "tf_weapon_sentry_revenge"))
			revenge = true;
		if (StrEqual(cls, "tf_weapon_medigun"))
			AddLine(text, maxlen, "ÜberCharge: %.0f%%", GetEntPropFloat(w, Prop_Send, "m_flChargeLevel") * 100.0);
		if (StrEqual(cls, "tf_weapon_pipebomblauncher") && HasEntProp(w, Prop_Send, "m_iPipebombCount"))
			AddLine(text, maxlen, "Stickies: %d", GetEntProp(w, Prop_Send, "m_iPipebombCount"));
		if (StrEqual(cls, "tf_weapon_charged_smg"))
			AddLine(text, maxlen, "Crikey: %.0f%%", GetEntPropFloat(w, Prop_Send, "m_flMinicritCharge"));
	}
	if (rage)
	{
		float v = PF(client, "m_flRageMeter");
		if (v > 0.0 || TF2_IsPlayerInCondition(client, TFCond_CritMmmph))
			AddLine(text, maxlen, "Rage: %.0f%%", v);
	}
	if (hype)
		AddLine(text, maxlen, "Hype: %.0f%%", PF(client, "m_flHypeMeter"));
	if (items)
		AddLine(text, maxlen, "Charge: %.0f%%", PF(client, "m_flItemChargeMeter", 1));
	if (decap)
		AddLine(text, maxlen, "Heads: %d", PI(client, "m_iDecapitations"));
	if (revenge)
		AddLine(text, maxlen, "Crits: %d", PI(client, "m_iRevengeCrits"));

	// Shields are wearables, not weapons.
	int shield = -1;
	while ((shield = FindEntityByClassname(shield, "tf_wearable_demoshield")) != -1)
	{
		if (GetEntPropEnt(shield, Prop_Send, "m_hOwnerEntity") == client)
		{
			AddLine(text, maxlen, "Shield: %.0f%%", PF(client, "m_flChargeMeter"));
			break;
		}
	}
}

char[] ShortName(const char[] cls)
{
	char name[24];
	if (StrEqual(cls, "tf_weapon_cleaver")) name = "Cleaver";
	else if (StrEqual(cls, "tf_weapon_bat_wood")) name = "Ball";
	else if (StrEqual(cls, "tf_weapon_bat_giftwrap")) name = "Ornament";
	else if (StrContains(cls, "tf_weapon_lunchbox_drink") == 0) name = "Drink";
	else if (StrContains(cls, "tf_weapon_lunchbox") == 0) name = "Lunchbox";
	else if (StrEqual(cls, "tf_weapon_jar_milk")) name = "Milk";
	else name = "Jar";
	return name;
}

float PF(int ent, const char[] prop, int element = 0)
{
	return HasEntProp(ent, Prop_Send, prop) ? GetEntPropFloat(ent, Prop_Send, prop, element) : 0.0;
}

int PI(int ent, const char[] prop)
{
	return HasEntProp(ent, Prop_Send, prop) ? GetEntProp(ent, Prop_Send, prop) : 0;
}
