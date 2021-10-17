#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>
#include <regex>
#include <gamma_colors>

public Plugin myinfo = 
{
	name = "Fortnite player hits", 
	author = "GAMMA CASE", 
	description = "Shows damage like in fortnite", 
	version = "1.2.0", 
	url = "http://steamcommunity.com/id/_GAMMACASE_/"
}

#define INVALID_ADMIN_ID view_as<AdminFlag>(-1)
#define x 0
#define y 1
#define z 2

#define ZC_COMMON "infected"
#define ZC_SMOKER 1
#define ZC_BOOMER 2
#define ZC_HUNTER 3
#define ZC_SPITTER 4
#define ZC_JOCKEY 5
#define ZC_CHARGER 6
#define ZC_WITCH 7
#define ZC_TANK 8 

#define FH_SPECIAL_ONLY 0
#define FH_ALL 1
#define FH_TANK_ONLY 2
#define FH_NONE 3

bool g_bIsFired[MAXPLAYERS + 1], 
g_bIsCrit[MAXPLAYERS + 1][MAXPLAYERS + 1], 
g_bIsFriendlyFire[MAXPLAYERS + 1][MAXPLAYERS + 1], 
g_bIsFirstTime[MAXPLAYERS + 1], 
g_bHasAccess[MAXPLAYERS + 1];
int g_iTotalSGDamage[MAXPLAYERS + 1][MAXPLAYERS + 1], 
g_bState[MAXPLAYERS + 1];
float g_fPlayerPosLate[MAXPLAYERS + 1][3];

AdminFlag g_afPermission = INVALID_ADMIN_ID;

ConVar g_cvAllowForBots, 
g_cvReconnectPlayer, 
g_cvCommands, 
g_cvDistanceMin, 
g_cvDistanceMax, 
g_cvDamageMin, 
g_cvPermission;
Handle g_hCookie;

enum HitGroup
{
	HITGROUP_GENERIC = 0, 
	HITGROUP_HEAD, 
	HITGROUP_CHEST, 
	HITGROUP_STOMACH, 
	HITGROUP_LEFTARM, 
	HITGROUP_RIGHTARM, 
	HITGROUP_LEFTLEG, 
	HITGROUP_RIGHTLEG
}

public void OnPluginStart()
{
	g_cvAllowForBots = CreateConVar("fortnite_hits_allowforbots", "1", "Allow bots to create hit particles (NOTE: Only will be visible when spectating a bot)", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvReconnectPlayer = CreateConVar("fortnite_hits_enableplayerreconnect", "1", "Enable this to force new players to reconnect to server, so they will see particle effects without need of waiting next map", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvCommands = CreateConVar("fortnite_hits_commandnames", "sm_fortnitehits;sm_hits;sm_damage;sm_fortnite;", "Set custom names here for toggle damage display command, don't add to many commands as it may overflow buffer. (NOTE: Write command names with \"sm_\" prefix, and don't use ! or any other symbol except A-Z and 0-9 and underline symbol \"_\", also server needs to be restarted to see changes!)", FCVAR_NONE);
	g_cvDistanceMin = CreateConVar("fortnite_hits_distance_min", "5.0", "Minimum distance between victim player and damage numbers (NOTE: Make that value lower to prevent numbers show up through the walls)", FCVAR_NONE, true, 0.0);
	g_cvDistanceMax = CreateConVar("fortnite_hits_distance_max", "50.0", "Maximum distance between victim player and damage numbers (NOTE: Make that value lower to prevent numbers show up through the walls)", FCVAR_NONE, true, 0.0);
	g_cvDamageMin = CreateConVar("fortnite_hits_damage_min", "0", "Minimum damage numbers to display.", FCVAR_NONE, true, 0.0);
	g_cvPermission = CreateConVar("fortnite_hits_flag", "", "Set any flag here if you want to restrict use of that plugin only to certain flag (NOTE: Leave it empty to allow anyone to use this plugin)", FCVAR_NONE);
	AutoExecConfig();
	
	g_cvPermission.AddChangeHook(Cvar_Permission_ChangeHook);
	LoadTranslations("fortnite_hits.phrases");
	
	RegConsoleCommands();
	g_hCookie = RegClientCookie("fortnite_hits_state", "Is showing damage disabled/enabled for a specific client", CookieAccess_Protected);
	
	HookEvent("player_connect_full", ConnectedFull_Hook);
	HookEvent("player_hurt", PlayerHurt_Event);
	HookEvent("infected_hurt", PlayerHurt_Event);
	
	//late load
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i))
			continue;
		
		if (AreClientCookiesCached(i))
			OnClientCookiesCached(i);
		
		SetAccess(i);
	}
}

public void Cvar_Permission_ChangeHook(ConVar convar, const char[] oldValue, const char[] newValue)
{
	CheckPermission(newValue);
}

public void OnMapStart()
{
	PreCacheAll();
}

public void OnConfigsExecuted()
{
	char buff[8];
	g_cvPermission.GetString(buff, sizeof(buff));
	CheckPermission(buff);
}

public void CheckPermission(const char[] svalue)
{
	if (svalue[0] == '\0')
		g_afPermission = INVALID_ADMIN_ID;
	else
	{
		BitToFlag(ReadFlagString(svalue), g_afPermission);
		SetAccessAll();
	}
}

public void RegConsoleCommands()
{
	char buff[1024];
	g_cvCommands.GetString(buff, sizeof(buff));
	
	if (buff[0] == '\0')
		return;
	
	char error[64];
	RegexError ErrorCode;
	Regex reg = CompileRegex("[a-zA-Z_0-9]+", 0, error, sizeof(error), ErrorCode);
	if (error[0] != '\0')
		SetFailState("[RegConsoleCommands] Regex error: \"%s\",  with error code: %i", error, ErrorCode);
	
	int num = reg.MatchAll(buff, ErrorCode);
	if (ErrorCode != REGEX_ERROR_NONE)
		SetFailState("[RegConsoleCommands] Regex match error, error code: %i", ErrorCode);
	
	char sMatch[32];
	for (int i = 0; i < num; i++)
	{
		reg.GetSubString(0, sMatch, sizeof(sMatch), i);
		RegConsoleCmd(sMatch, ToggleHits, "Toggles hits display");
	}
}

public Action ToggleHits(int client, int args)
{
	if (g_bHasAccess[client])
	{
		char buff[16];
		
		if (args == 0) {
			if (g_bState[client] != FH_NONE) {
				g_bState[client] = FH_NONE;
			} else {
				g_bState[client] = FH_SPECIAL_ONLY;
			}
		} else {
			GetCmdArg(1, buff, sizeof(buff));
			if (StrEqual(buff,"special")){
				g_bState[client] = FH_SPECIAL_ONLY;
			} else if (StrEqual(buff,"all")){
				g_bState[client] = FH_ALL;
			} else if (StrEqual(buff,"tank")){
				g_bState[client] = FH_TANK_ONLY;
			} else if (StrEqual(buff,"none")){
				g_bState[client] = FH_NONE;
			} else {
				GCReplyToCommand(client, "%t", "display_help");
				return Plugin_Handled;
			}
		}
		
		static int state;
		state = g_bState[client];
		
		IntToString(state, buff, sizeof(buff));
		PrintToChat(client, (state == FH_ALL ? "display_all" : state == FH_SPECIAL_ONLY ? "display_special" : state == FH_TANK_ONLY ? "display_tank" : "display_toggle_off"));
		SetClientCookie(client, g_hCookie, buff);
		
		GCReplyToCommand(client, "%t", (state == FH_ALL ? "display_all" : state == FH_SPECIAL_ONLY ? "display_special" : state == FH_TANK_ONLY ? "display_tank" : "display_toggle_off"));
	}
	else
		GCReplyToCommand(client, "%t", "no_access");
	
	return Plugin_Handled;
}

public void OnClientCookiesCached(int client)
{
	if (IsFakeClient(client))
		return;
	
	char buff[4];
	GetClientCookie(client, g_hCookie, buff, sizeof(buff));
	
	if (buff[0] == '\0')
	{
		SetClientCookie(client, g_hCookie, "1");
		g_bState[client] = FH_ALL;
		g_bIsFirstTime[client] = true;
	}
	else
	{
		g_bState[client] = view_as<int>(StringToInt(buff));
		g_bIsFirstTime[client] = false;
	}
}

public void OnRebuildAdminCache(AdminCachePart part)
{
	if (part == AdminCache_Admins)
		SetAccessAll();
}

public void OnClientPostAdminCheck(int client)
{
	if (!IsFakeClient(client))
		SetAccess(client);
}

public void ConnectedFull_Hook(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	
	if (IsFakeClient(client))
		return;
	
	if (g_bIsFirstTime[client] && g_cvReconnectPlayer.BoolValue)
		ReconnectClient(client);
}

public void PlayerHurt_Event(Event event, const char[] name, bool dontBroadcast)
{
	static int attacker, client, damage, zClass;
	static HitGroup hitgroup;
	static char sWeapon[32];
	static char modelname[255];
	static int dmgType;
	static bool friendlyFire;
	
	attacker = GetClientOfUserId(event.GetInt("attacker")), 
	client = GetClientOfUserId(event.GetInt("userid")), 
	damage = event.GetInt("dmg_health");
	hitgroup = view_as<HitGroup>(event.GetInt("hitgroup"));
	event.GetString("weapon", sWeapon, sizeof(sWeapon));
	dmgType = event.GetInt("type");
	if (dmgType & DMG_BLAST) {
		//PrintToChatAll("explosion");
	}
	if (dmgType & DMG_BURN) {
		//PrintToChatAll("fire");
	}
	
	int entity = event.GetInt("entityid", -1);
	if (entity != -1) {
		damage = event.GetInt("amount");
	}
	
	if (entity == -1) {
		zClass = GetEntProp(client, Prop_Send, "m_zombieClass");
	} else {
		zClass = -1;
		GetEntityClassname(entity, modelname, sizeof(modelname));
		
		if (StrEqual(modelname, "witch")) {
			zClass = ZC_WITCH;
		}
	}
	if (g_bState[client] != FH_ALL && zClass == -1) {
		//ignore common
		//PrintToChatAll("no common");
		return;
	}
	
	if (attacker == client || attacker == 0)
		return;
	
	if (!g_cvAllowForBots.BoolValue && IsFakeClient(attacker))
		return;
	
	friendlyFire = zClass == 9;
	
	if (IsMultipleHitWeapon(sWeapon))
	{
		if (!g_bIsFired[attacker])
		{
			CreateTimer(0.2, TimerHit_CallBack, GetClientUserId(attacker), TIMER_FLAG_NO_MAPCHANGE);
			
			g_bIsFired[attacker] = true;
			if (entity == -1) {
				g_iTotalSGDamage[attacker][client] = damage;
			} else {
				g_iTotalSGDamage[attacker][entity] = damage;
			}
		}
		else {
			if (entity == -1) {
				g_iTotalSGDamage[attacker][client] += damage;
			} else {
				g_iTotalSGDamage[attacker][entity] += damage;
			}
		}
		g_bIsCrit[attacker][client] = hitgroup == HITGROUP_HEAD;
		g_bIsFriendlyFire[attacker][client] = friendlyFire;
		GetAbsOrigin(client, entity, g_fPlayerPosLate[client]);
	}
	else {
		ShowPRTDamage(attacker, client, entity, damage, (hitgroup == HITGROUP_HEAD), friendlyFire);
	}
}

public Action TimerHit_CallBack(Handle timer, int userid)
{
	static int client;
	client = GetClientOfUserId(userid);
	
	if (client == 0)
		return Plugin_Stop;
	
	g_bIsFired[client] = false;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i, false))
			continue;
		
		if (g_iTotalSGDamage[client][i] != 0)
		{
			ShowPRTDamage(client, i, i, g_iTotalSGDamage[client][i], g_bIsCrit[client][i], g_bIsFriendlyFire[client][i], true);
			g_iTotalSGDamage[client][i] = 0;
			g_bIsCrit[client][i] = false;
		}
	}
	
	return Plugin_Continue;
}

stock void ShowPRTDamage(int attacker, int client, int entity, int damage, bool crit, bool ff, bool late = false)
{
	if (!IsValidClient(client, false))
		return;
	
	if (!IsValidClient(attacker, false))
		return;
	
	static float pos[3], pos2[3], ang[3], fwd[3], right[3], temppos[3], dist, d, dif;
	static int ent, l, count, dmgnums[8];
	static char buff[16];
	int minDmg = g_cvDamageMin.IntValue;
	
	count = 0;
	
	while (damage > minDmg)
	{
		dmgnums[count++] = damage % 10;
		damage /= 10;
	}
	
	GetClientEyeAngles(attacker, ang);
	GetClientAbsOrigin(attacker, pos2);
	
	if (late)
		pos = g_fPlayerPosLate[client];
	else
		GetAbsOrigin(client, entity, pos);
	GetAngleVectors(ang, fwd, right, NULL_VECTOR);
	
	l = RoundToCeil(float(count) / 2.0);
	
	dist = GetVectorDistance(pos2, pos);
	if (dist > 700.0)
		d = dist / 700.0 * 6.0;
	else
		d = 6.0;
	
	pos[x] += right[x] * d * l * GetRandomFloat(-0.5, 1.0);
	pos[y] += right[y] * d * l * GetRandomFloat(-0.5, 1.0);
	if (entity == -1 && GetEntProp(client, Prop_Send, "m_bDucked")) {
		if (crit) {
			pos[z] += 45.0 + GetRandomFloat(0.0, 10.0);
		} else {
			pos[z] += 25.0 + GetRandomFloat(0.0, 20.0); }
	} else {
		if (crit) {
			pos[z] += 60.0 + GetRandomFloat(0.0, 10.0);
		} else {
			pos[z] += 35.0 + GetRandomFloat(0.0, 20.0);
		}
	}
	dif = dist / 4;
	if (dif < g_cvDistanceMin.FloatValue) {
		dif = g_cvDistanceMin.FloatValue
	}
	if (dif > g_cvDistanceMax.FloatValue) {
		dif = g_cvDistanceMax.FloatValue
	}
	if (count == 0) {
		count = 1;
		dmgnums[0] = 0;
	}
	for (int i = count - 1; i >= 0; i--)
	{
		temppos = pos;
		
		temppos[x] -= fwd[x] * dif + right[x] * d * l;
		temppos[y] -= fwd[y] * dif + right[y] * d * l;
		
		ent = CreateEntityByName("info_particle_system");
		
		if (ent == -1) {
			SetFailState("Error creating \"info_particle_system\" entity!");
		}
		
		TeleportEntity(ent, temppos, ang, NULL_VECTOR);
		FormatEx(buff, sizeof(buff), "%s_num%i_f%s", (ff ? "ff" : crit ? "crit" : "def"), dmgnums[i], (l-- > 0 ? "l" : "r"));
		
		DispatchKeyValue(ent, "effect_name", buff);
		DispatchKeyValue(ent, "start_active", "1");
		DispatchSpawn(ent);
		ActivateEntity(ent);
		
		SetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity", attacker);
		SDKHook(ent, SDKHook_SetTransmit, SetTransmit_Hook);
		
		SetVariantString("OnUser1 !self:kill::3:-1");
		AcceptEntityInput(ent, "AddOutput");
		AcceptEntityInput(ent, "FireUser1");
	}
}

public Action SetTransmit_Hook(int entity, int client)
{
	if (GetEdictFlags(entity) & FL_EDICT_ALWAYS)
		SetEdictFlags(entity, (GetEdictFlags(entity) ^ FL_EDICT_ALWAYS));
	
	if (g_bHasAccess[client] && g_bState[client]!=FH_NONE && (GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity") == client || (GetEntPropEnt(client, Prop_Send, "m_hObserverTarget") == GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity") && (GetEntProp(client, Prop_Send, "m_iObserverMode") == 4 || GetEntProp(client, Prop_Send, "m_iObserverMode") == 5))))
		return Plugin_Continue;
	
	return Plugin_Stop;
}

public void SetAccessAll()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i))
			continue;
		
		SetAccess(i);
	}
}

public void SetAccess(int client)
{
	g_bHasAccess[client] = (g_afPermission == INVALID_ADMIN_ID || GetUserAdmin(client).HasFlag(g_afPermission));
}

stock bool IsValidClient(int client, bool botcheck = true)
{
	return true;
	//return (1 <= client && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client) && (botcheck ? !IsFakeClient(client) : true));
}

public void GetAbsOrigin(int client, int entity, float vec[3]) {
	if (entity == -1) {
		GetClientAbsOrigin(client, vec);
	} else {
		GetEntPropVector(entity, Prop_Send, "m_vecOrigin", vec);
	}
}

public bool IsMultipleHitWeapon(char[] sWeapon) {
	bool r = StrEqual(sWeapon, "xm1014") || StrEqual(sWeapon, "nova") || StrEqual(sWeapon, "mag7") || StrEqual(sWeapon, "sawedoff") || StrEqual(sWeapon, "shotgun_chrome") || StrEqual(sWeapon, "shotgun_spas") || StrEqual(sWeapon, "autoshotgun") || StrEqual(sWeapon, "pumpshotgun") || StrEqual(sWeapon, "melee") || StrEqual(sWeapon, "chainsaw");
	return r;
}

public void PreCacheAll() {
	char buff[16];
	
	int table = INVALID_STRING_TABLE;
	int index;
	
	if (table == INVALID_STRING_TABLE)
	{
		table = FindStringTable("ParticleEffectNames");
	}
	
	// def fl
	for (int i = 0; i <= 9; i++)
	{
		FormatEx(buff, sizeof(buff), "def_num%i_fl", i);
		index = FindStringIndex(table, buff);
		if (index == INVALID_STRING_INDEX)
		{
			bool save = LockStringTables(false);
			AddToStringTable(table, buff);
			LockStringTables(save);
		}
	}
	
	// def fr
	for (int i = 0; i <= 9; i++)
	{
		FormatEx(buff, sizeof(buff), "def_num%i_fr", i);
		index = FindStringIndex(table, buff);
		if (index == INVALID_STRING_INDEX)
		{
			bool save = LockStringTables(false);
			AddToStringTable(table, buff);
			LockStringTables(save);
		}
	}
	
	// crit fl
	for (int i = 0; i <= 9; i++)
	{
		FormatEx(buff, sizeof(buff), "crit_num%i_fl", i);
		index = FindStringIndex(table, buff);
		if (index == INVALID_STRING_INDEX)
		{
			bool save = LockStringTables(false);
			AddToStringTable(table, buff);
			LockStringTables(save);
		}
	}
	
	// crit fr
	for (int i = 0; i <= 9; i++)
	{
		FormatEx(buff, sizeof(buff), "crit_num%i_fr", i);
		index = FindStringIndex(table, buff);
		if (index == INVALID_STRING_INDEX)
		{
			bool save = LockStringTables(false);
			AddToStringTable(table, buff);
			LockStringTables(save);
		}
	}
	
	// ff fl
	for (int i = 0; i <= 9; i++)
	{
		FormatEx(buff, sizeof(buff), "ff_num%i_fl", i);
		index = FindStringIndex(table, buff);
		if (index == INVALID_STRING_INDEX)
		{
			bool save = LockStringTables(false);
			AddToStringTable(table, buff);
			LockStringTables(save);
		}
	}
	
	// ff fl
	for (int i = 0; i <= 9; i++)
	{
		FormatEx(buff, sizeof(buff), "ff_num%i_fr", i);
		index = FindStringIndex(table, buff);
		if (index == INVALID_STRING_INDEX)
		{
			bool save = LockStringTables(false);
			AddToStringTable(table, buff);
			LockStringTables(save);
		}
	}
} 