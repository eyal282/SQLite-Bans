#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <basecomm>
#include <adminmenu>

#undef REQUIRE_PLUGIN
#undef REQUIRE_EXTENSIONS
#tryinclude <cURL>
#tryinclude <socket>
#tryinclude <steamtools>
#tryinclude <SteamWorks>
#tryinclude <updater>  // Comment out this line to remove updater support by force.
#tryinclude <autoexecconfig>
#define REQUIRE_PLUGIN
#define REQUIRE_EXTENSIONS

#include <sqlitebans>

#define UPDATE_URL    "https://raw.githubusercontent.com/eyal282/SQLite-Bans/master/addons/updatefile.txt"

#pragma newdecls required

#define PLUGIN_VERSION "2.9"


public Plugin myinfo = 
{
	name = "SQLite Bans",
	author = "Eyal282",
	description = "Banning system that works on SQLite",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?t=315623"
}

#define FPERM_ULTIMATE (FPERM_U_READ|FPERM_U_WRITE|FPERM_U_EXEC|FPERM_G_READ|FPERM_G_WRITE|FPERM_G_EXEC|FPERM_O_READ|FPERM_O_WRITE|FPERM_O_EXEC)

Handle dbLocal = INVALID_HANDLE;

Handle hcv_Website = INVALID_HANDLE;
Handle hcv_LogMethod = INVALID_HANDLE;
Handle hcv_LogBannedConnects = INVALID_HANDLE;
Handle hcv_DefaultGagTime = INVALID_HANDLE;
Handle hcv_DefaultMuteTime = INVALID_HANDLE;
Handle hcv_Deadtalk = INVALID_HANDLE;
Handle hcv_Alltalk = INVALID_HANDLE;

Handle fw_OnBanIdentity = INVALID_HANDLE;
Handle fw_OnBanIdentity_Post = INVALID_HANDLE;

float ExpireBreach = 0.0;

// Unix, setting to -1 makes it permanent.
int ExpirePenalty[MAXPLAYERS+1][enPenaltyType_LENGTH];

bool WasMutedLastCheck[MAXPLAYERS+1], WasGaggedLastCheck[MAXPLAYERS+1];

bool IsHooked = false;

public APLRes AskPluginLoad2(Handle myself, bool bLate, char[] error, int err_max)
{
	CreateNative("SQLiteBans_CommPunishClient", Native_CommPunishClient);
	CreateNative("SQLiteBans_CommPunishIdentity", Native_CommPunishIdentity);
	CreateNative("SQLiteBans_CommUnpunishClient", Native_CommUnpunishClient);
	CreateNative("SQLiteBans_CommUnpunishIdentity", Native_CommUnpunishIdentity);
	
	CreateNative("BaseComm_IsClientGagged", BaseCommNative_IsClientGagged);
	CreateNative("BaseComm_IsClientMuted",  BaseCommNative_IsClientMuted);
	CreateNative("BaseComm_SetClientGag",   BaseCommNative_SetClientGag);
	CreateNative("BaseComm_SetClientMute",  BaseCommNative_SetClientMute);
	
	RegPluginLibrary("basecomm");
	RegPluginLibrary("SQLiteBans");
}

public any Native_CommPunishClient(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	
	enPenaltyType PenaltyType = GetNativeCell(2);
		
	int time = GetNativeCell(3);
	
	char reason[256];
	GetNativeString(4, reason, sizeof(reason));
	
	int source = GetNativeCell(5);
	
	bool dontExtend = GetNativeCell(6);
	
	char AuthId[35], IPAddress[32];
	
	GetClientIP(client, IPAddress, sizeof(IPAddress), true);
	
	if(!GetClientAuthId(client, AuthId_Steam2, AuthId, sizeof(AuthId)))
		return false;
		
	char AdminAuthId[35], AdminName[64];
	
	if(source == 0)
	{
		AdminAuthId = "CONSOLE";
		AdminName = "CONSOLE";
	}
	else
	{
		GetClientAuthId(source, AuthId_Steam2, AdminAuthId, sizeof(AdminAuthId));
		GetClientName(source, AdminName, sizeof(AdminName));
	}
	
	char name[64];
	GetClientName(client, name, sizeof(name));
		
	if(PenaltyType == Penalty_Ban)
	{	
		ThrowNativeError(SP_ERROR_NATIVE, "PenaltyType cannot be equal to Penalty_Ban ( %i )", Penalty_Ban);
		return false;
	}
	else if (PenaltyType >= enPenaltyType_LENGTH)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid PenaltyType");
		return false;
	}
	
	bool Extend = !(ExpirePenalty[client][PenaltyType] == 0);
	
	if(Extend)
	{
		if(dontExtend)
			return 0;

		ExpirePenalty[client][PenaltyType] = ExpirePenalty[client][PenaltyType] + time * 60;
	}
	else
		ExpirePenalty[client][PenaltyType] = GetTime() + time * 60;
	
	if(time == 0) // Permanent doesn't obey extending
		ExpirePenalty[client][PenaltyType] = -1;
	
	if(IsClientVoiceMuted(client))
		SetClientListeningFlags(client, VOICE_MUTED);
	
	else
		SetClientListeningFlags(client, VOICE_NORMAL);
	
	char PenaltyAlias[32];
	
	PenaltyAliasByType(PenaltyType, PenaltyAlias);
		
	return SQLiteBans_CommPunishIdentity(AuthId, PenaltyType, name, time, reason, source, dontExtend);
}


public any Native_CommPunishIdentity(Handle plugin, int numParams)
{
	char identity[35];
	GetNativeString(1, identity, sizeof(identity));
	
	enPenaltyType PenaltyType = GetNativeCell(2);

	if(PenaltyType == Penalty_Ban)
	{	
		ThrowNativeError(SP_ERROR_NATIVE, "PenaltyType cannot be equal to Penalty_Ban ( %i )", Penalty_Ban);
		return false;
	}
	else if(PenaltyType >= enPenaltyType_LENGTH)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid PenaltyType");
		return false;
	}
	
	char name[64];
	GetNativeString(3, name, sizeof(name));
	
	int time = GetNativeCell(4);
	
	char reason[256];
	GetNativeString(5, reason, sizeof(reason));
	
	int source = GetNativeCell(6);
	
	bool dontExtend = GetNativeCell(7);
	
	char AdminAuthId[35], AdminName[64];
	
	if(source == 0)
	{
		AdminAuthId = "CONSOLE";
		AdminName = "CONSOLE";
	}
	else
	{
		GetClientAuthId(source, AuthId_Steam2, AdminAuthId, sizeof(AdminAuthId));
		GetClientName(source, AdminName, sizeof(AdminName));
	}
	
	char sQuery[1024];
	
	int UnixTime = GetTime();
	
	if(time == 0)
	{
		SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "INSERT OR REPLACE INTO SQLiteBans_players (AuthId, PlayerName, AdminAuthID, AdminName, Penalty, PenaltyReason, TimestampGiven, DurationMinutes) VALUES ('%s', '%s', '%s', '%s', %i, '%s', %i, %i)", identity, name, AdminAuthId, AdminName, PenaltyType, reason, UnixTime, time);
		SQL_TQuery(dbLocal, SQLCB_Error, sQuery, 1);
	}
	else
	{
		if(!dontExtend)
		{
			SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "UPDATE OR IGNORE SQLiteBans_players SET DurationMinutes = DurationMinutes + %i WHERE AuthId = '%s' AND Penalty = %i AND DurationMinutes != '0'", time, identity, PenaltyType);
			SQL_TQuery(dbLocal, SQLCB_Error, sQuery, 2);
		}
		SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "INSERT OR IGNORE INTO SQLiteBans_players (AuthId, PlayerName, AdminAuthID, AdminName, Penalty, PenaltyReason, TimestampGiven, DurationMinutes) VALUES ('%s', '%s', '%s', '%s', %i, '%s', %i, %i)", identity, name, AdminAuthId, AdminName, PenaltyType, reason, UnixTime, time);	
		SQL_TQuery(dbLocal, SQLCB_Error, sQuery, 3);
	}
	
	
	char PenaltyAlias[32];
	
	PenaltyAliasByType(PenaltyType, PenaltyAlias, false);
	
	if(time == 0)
		LogSQLiteBans("Admin %N [AuthId: %s] added a permanent %s on %s [AuthId: %s]. Reason: %s", source, AdminAuthId, PenaltyAlias, name, identity, reason);

	else
		LogSQLiteBans("Admin %N [AuthId: %s] added a %i minute %s on %s [AuthId: %s]. Reason: %s", source, AdminAuthId, time, PenaltyAlias, name, identity, reason);
	
	return true;
}

public any Native_CommUnpunishClient(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	
	enPenaltyType PenaltyType = GetNativeCell(2);
	
	int source = GetNativeCell(3);
	
	char AuthId[35], name[64];
	
	char AdminAuthId[35], AdminName[64];
	
	GetClientName(client, name, sizeof(name));
	if(source == 0)
	{
		AdminAuthId = "CONSOLE";
		AdminName = "CONSOLE";
	}
	else
	{
		GetClientAuthId(source, AuthId_Steam2, AdminAuthId, sizeof(AdminAuthId));
		GetClientName(source, AdminName, sizeof(AdminName));
	}
	if(!GetClientAuthId(client, AuthId_Steam2, AuthId, sizeof(AuthId)))
		return false;
		
	else if(PenaltyType == Penalty_Ban)
	{	
		ThrowNativeError(SP_ERROR_NATIVE, "PenaltyType cannot be equal to Penalty_Ban ( %i )", Penalty_Ban);
		return false;
	}
	else if(PenaltyType >= enPenaltyType_LENGTH)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid PenaltyType");
		return false;
	}
	
	ExpirePenalty[client][PenaltyType] = 0;
	
	if(IsClientVoiceMuted(client))
		SetClientListeningFlags(client, VOICE_MUTED);
	
	else
		SetClientListeningFlags(client, VOICE_NORMAL);
	
	char PenaltyAlias[32];
	
	PenaltyAliasByType(PenaltyType, PenaltyAlias);
	
	LogSQLiteBans("Admin %N [AuthId: %s] un%s %N [AuthId: %s].", source, AdminAuthId, PenaltyAlias, client, AuthId);
		
	return SQLiteBans_CommUnpunishIdentity(AuthId, PenaltyType, source, name);
}


public any Native_CommUnpunishIdentity(Handle plugin, int numParams)
{
	char identity[35];
	GetNativeString(1, identity, sizeof(identity));
	
	enPenaltyType PenaltyType = GetNativeCell(2);

	if(PenaltyType == Penalty_Ban)
	{	
		ThrowNativeError(SP_ERROR_NATIVE, "PenaltyType cannot be equal to Penalty_Ban ( %i )", Penalty_Ban);
		return false;
	}
	else if(PenaltyType >= enPenaltyType_LENGTH)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid PenaltyType");
		return false;
	}
	
	int source = GetNativeCell(3);
	int UserId = (source == 0 ? 0 : GetClientUserId(source));
	
	char name[64];
	GetNativeString(4, name, sizeof(name));
	
	Handle DP = CreateDataPack();
	
	WritePackCell(DP, UserId);
	WritePackCell(DP, GetCmdReplySource());
	WritePackString(DP, identity);
	
	char sQuery[1024];
	SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "DELETE FROM SQLiteBans_players WHERE Penalty = %i AND AuthId = '%s'", PenaltyType, identity);
	SQL_TQuery(dbLocal, SQLCB_Unpenalty, sQuery, DP);
	
	return true;
}

public int BaseCommNative_IsClientGagged(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if(client < 1 || client > MaxClients)
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d", client);
	
	if(!IsClientInGame(client))
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not in game", client);
	
	return IsClientChatGagged(client);
}

public int BaseCommNative_IsClientMuted(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if(client < 1 || client > MaxClients)
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d", client);
	
	if(!IsClientInGame(client))
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not in game", client);
	
	return IsClientVoiceMuted(client);
}

public any BaseCommNative_SetClientGag(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	
	if(client < 1 || client > MaxClients)
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d", client);
	
	if(!IsClientInGame(client))
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not in game", client);
	
	bool shouldGag = GetNativeCell(2);
	
	if(shouldGag)
		SQLiteBans_CommPunishClient(client, Penalty_Gag, GetConVarInt(hcv_DefaultGagTime), "No reason specified", 0, false);
		
	else
		SQLiteBans_CommUnpunishClient(client, Penalty_Gag, 0);
		
	static Handle hForward;
	
	if(hForward == null)
	{
		hForward = CreateGlobalForward("BaseComm_OnClientGag", ET_Ignore, Param_Cell, Param_Cell);
	}
	
	Call_StartForward(hForward);
	
	Call_PushCell(client);
	Call_PushCell(shouldGag);
	
	Call_Finish();
	
	return true;
}

public any BaseCommNative_SetClientMute(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if(client < 1 || client > MaxClients)
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d", client);
	
	if(!IsClientInGame(client))
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not in game", client);
	
	bool shouldMute = GetNativeCell(2);
	
	if(shouldMute)
		SQLiteBans_CommPunishClient(client, Penalty_Mute, GetConVarInt(hcv_DefaultMuteTime), "No reason specified", 0, false);
		
	else
		SQLiteBans_CommUnpunishClient(client, Penalty_Mute, 0);
		
 	static Handle hForward;
	
	if(hForward == null)
	{
		hForward = CreateGlobalForward("BaseComm_OnClientMute", ET_Ignore, Param_Cell, Param_Cell);
	}
	
	Call_StartForward(hForward);
	
	Call_PushCell(client);
	Call_PushCell(shouldMute);
	
	Call_Finish();
	
	return true;
}

public void OnPluginStart()
{	
	LoadTranslations("common.phrases");
	
	RegAdminCmd("sm_ban", Command_Ban, ADMFLAG_BAN, "sm_ban <#userid|name> <minutes|0> [reason]");
	RegAdminCmd("sm_banip", Command_BanIP, ADMFLAG_BAN, "sm_banip <#userid|name> <minutes|0> [reason]");
	RegAdminCmd("sm_fban", Command_FullBan, ADMFLAG_BAN, "sm_fban <#userid|name> <minutes|0> [reason]");
	RegAdminCmd("sm_fullban", Command_FullBan, ADMFLAG_BAN, "sm_fban <#userid|name> <minutes|0> [reason]");
	RegAdminCmd("sm_addban", Command_AddBan, ADMFLAG_BAN, "sm_addban <steamid|ip> <minutes|0> [reason]");
	RegAdminCmd("sm_unban", Command_Unban, ADMFLAG_UNBAN, "sm_unban <steamid|ip>");
	
	fw_OnBanIdentity = CreateGlobalForward("SQLiteBans_OnBanIdentity", ET_Ignore, Param_Cell, Param_String, Param_String, Param_String, Param_String);
	fw_OnBanIdentity_Post = CreateGlobalForward("SQLiteBans_OnBanIdentity_Post", ET_Ignore, Param_String, Param_String, Param_String, Param_String, Param_String, Param_Cell);

	
	if(!CommandExists("sm_gag"))
		RegAdminCmd("sm_gag", Command_Null, ADMFLAG_CHAT, "sm_gag <#userid|name> <minutes|0> [reason]");

	if(!CommandExists("sm_mute"))
		RegAdminCmd("sm_mute", Command_Null, ADMFLAG_CHAT, "sm_mute <#userid|name> <minutes|0> [reason]");

	if(!CommandExists("sm_silence"))
		RegAdminCmd("sm_silence", Command_Null, ADMFLAG_CHAT, "sm_silence <#userid|name> <minutes|0> [reason]");		

	if(!CommandExists("sm_ungag"))
		RegAdminCmd("sm_ungag", Command_Null, ADMFLAG_CHAT, "sm_ungag <#userid|name> <minutes|0> [reason]");

	if(!CommandExists("sm_unmute"))
		RegAdminCmd("sm_unmute", Command_Null, ADMFLAG_CHAT, "sm_unmute <#userid|name> <minutes|0> [reason]");

	if(!CommandExists("sm_unsilence"))
		RegAdminCmd("sm_unsilence", Command_Null, ADMFLAG_CHAT, "sm_unsilence <#userid|name> <minutes|0> [reason]");			
		
	AddCommandListener(Listener_Penalty, "sm_gag");
	AddCommandListener(Listener_Penalty, "sm_mute");
	AddCommandListener(Listener_Penalty, "sm_silence");
	
	AddCommandListener(Listener_Unpenalty, "sm_ungag");
	AddCommandListener(Listener_Unpenalty, "sm_unmute");
	AddCommandListener(Listener_Unpenalty, "sm_unsilence");
	
	RegAdminCmd("sm_ogag", Command_OfflinePenalty, ADMFLAG_CHAT, "sm_ogag <steamid> <minutes|0> [reason]");
	RegAdminCmd("sm_omute", Command_OfflinePenalty, ADMFLAG_CHAT, "sm_omute <steamid> <minutes|0> [reason]");
	RegAdminCmd("sm_osilence", Command_OfflinePenalty, ADMFLAG_CHAT, "sm_osilence <steamid> <minutes|0> [reason]");
	
	RegAdminCmd("sm_oungag", Command_OfflineUnpenalty, ADMFLAG_CHAT, "sm_oungag <steamid>");
	RegAdminCmd("sm_ounmute", Command_OfflineUnpenalty, ADMFLAG_CHAT, "sm_ounmute <steamid>");
	RegAdminCmd("sm_ounsilence", Command_OfflineUnpenalty, ADMFLAG_CHAT, "sm_ounsilence <steamid>");
	
	RegAdminCmd("sm_banlist", Command_BanList, ADMFLAG_UNBAN, "List of all past given bans");
	RegAdminCmd("sm_commlist", Command_CommList, ADMFLAG_CHAT, "List of all past given communication punishments");
	RegAdminCmd("sm_breachbans", Command_BreachBans, ADMFLAG_UNBAN, "Allows all banned clients to connect for the next minute");
	RegAdminCmd("sm_kickbreach", Command_KickBreach, ADMFLAG_UNBAN, "Kicks all ban breaching clients inside the server");
	
	//RegAdminCmd("sm_sqlitebans_backup", Command_Backup, ADMFLAG_ROOT, "Backs up the bans database to an external file");
	
	RegConsoleCmd("sm_commstatus", Command_CommStatus, "Gives you information about communication penalties active on you");
	RegConsoleCmd("sm_comms", Command_CommStatus, "Gives you information about communication penalties active on you");
	
	#if defined _autoexecconfig_included
	
	AutoExecConfig_SetFile("SQLiteBans");
	
	#endif
	
	hcv_Website = UC_CreateConVar("sqlite_bans_url", "http://yourwebsite.com", "Url to direct banned players to go to if they wish to appeal their ban");
	hcv_LogMethod = UC_CreateConVar("sqlite_bans_log_method", "1", "0 - Log in the painful to look at \"L20190412.log\" files. 1 - Log in a seperate file, in sourcemod/logs/SQLiteBans.log");
	hcv_LogBannedConnects = UC_CreateConVar("sqlite_bans_log_banned_connects", "0", "0 - Don't. 1 - Log whenever a banned player attempts to join the server");
	hcv_DefaultGagTime = UC_CreateConVar("sqlite_bans_default_gag_time", "7", "If a plugin uses a basecomm native to gag a player, this is how long the gag will last");
	hcv_DefaultMuteTime = UC_CreateConVar("sqlite_bans_default_mute_time", "7", "If a plugin uses a basecomm native to mute a player, this is how long the mute will last");
	
	hcv_Deadtalk = UC_CreateConVar("sm_deadtalk", "0", "Controls how dead communicate. 0 - Off. 1 - Dead players ignore teams. 2 - Dead players talk to living teammates.", 0, true, 0.0, true, 2.0);
	
	#if defined _autoexecconfig_included
	
	AutoExecConfig_ExecuteFile();

	AutoExecConfig_CleanFile();
	
	#endif
	
	hcv_Alltalk = FindConVar("sv_alltalk");
	
	HookConVarChange(hcv_Deadtalk, hcvChange_Deadtalk);
	HookConVarChange(hcv_Alltalk, hcvChange_Alltalk);
	
	char Value[64];
	GetConVarString(hcv_Deadtalk, Value, sizeof(Value));
	
	hcvChange_Deadtalk(hcv_Deadtalk, Value, Value);
	
	GetConVarString(hcv_Alltalk, Value, sizeof(Value));
	
	hcvChange_Alltalk(hcv_Alltalk, Value, Value);
		
	char LogPath[256];
	
	BuildPath(Path_SM, LogPath, sizeof(LogPath), "logs/SQLiteBans");
	CreateDirectory(LogPath, FPERM_ULTIMATE);
	SetFilePermissions(LogPath, FPERM_ULTIMATE); 
	
	ConnectToDatabase();
	
	#if defined _updater_included
	if (LibraryExists("updater"))
	{
		Updater_AddPlugin(UPDATE_URL);
	}
	#endif
}

#if defined _updater_included
public int Updater_OnPluginUpdated()
{
	ServerCommand("sm_reload_translations");
	
	ReloadPlugin(INVALID_HANDLE);
}

#endif
public void OnLibraryAdded(const char[] name)
{
	#if defined _updater_included
	if (StrEqual(name, "updater"))
	{
		Updater_AddPlugin(UPDATE_URL);
	}
	#endif
}

public void ConnectToDatabase()
{		
	char Error[256];
	if((dbLocal = SQLite_UseDatabase("sqlite-bans", Error, sizeof(Error))) == INVALID_HANDLE)
		SetFailState("Could not connect to the database \"sqlite-bans\" at the following error:\n%s", Error);
	
	else
	{ 
		SQL_TQuery(dbLocal, SQLCB_Error, "CREATE TABLE IF NOT EXISTS SQLiteBans_players (AuthId VARCHAR(35), IPAddress VARCHAR(32), PlayerName VARCHAR(64) NOT NULL, AdminAuthID VARCHAR(35) NOT NULL, AdminName VARCHAR(64) NOT NULL, Penalty INT(11) NOT NULL, PenaltyReason VARCHAR(256) NOT NULL, TimestampGiven INT(11) NOT NULL, DurationMinutes INT(11) NOT NULL, UNIQUE(AuthId, Penalty), UNIQUE(IPAddress, Penalty))", 5, DBPrio_High); 

		char sQuery[256];
		
		SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "DELETE FROM SQLiteBans_players WHERE DurationMinutes != 0 AND TimestampGiven + (60 * DurationMinutes) < %i", GetTime());
		SQL_TQuery(dbLocal, SQLCB_Error, sQuery, 6, DBPrio_High);
		
		for(int i=1;i <= MaxClients;i++)
		{
			if(!IsClientInGame(i))
				continue;
			
			else if(!IsClientAuthorized(i))
				continue;
			
			OnClientPostAdminCheck(i);
		}
	}
}

public void SQLCB_Error(Handle db, Handle hndl, const char[] sError, int data)
{
	if(hndl == null)
		ThrowError("SQLite Bans Query error %i: %s", data, sError);
}

public void OnMapStart()
{
	CreateTimer(1.0, Timer_CheckCommStatus, _, TIMER_FLAG_NO_MAPCHANGE|TIMER_REPEAT);
}

public Action Timer_CheckCommStatus(Handle hTimer)
{
	for(int i=1;i <= MaxClients;i++)
	{
		if(!IsClientInGame(i))
			continue;
		
		bool WasGagged = false, WasMuted = false;
		
		if(!IsClientChatGagged(i) && WasGaggedLastCheck[i])
			WasGagged = true;
			
		if(!IsClientVoiceMuted(i) && WasMutedLastCheck[i])
			WasMuted = true;
			
		if(WasGagged && WasMuted)
			PrintToChat(i, "Your silence penalty has expired.");
			
		else if(WasGagged)
			PrintToChat(i, "Your gag penalty has expired.");
			
		else if(WasMuted)
			PrintToChat(i, "Your mute penalty has expired.");
			
		if(WasMuted)
		{
			if(IsPlayerAlive(i))
				SetClientListeningFlags(i, VOICE_NORMAL);
				
			else
			{
				if(GetConVarBool(hcv_Alltalk))
				{
					SetClientListeningFlags(i, VOICE_NORMAL);
				}

				switch(GetConVarInt(hcv_Deadtalk))
				{
					case 1: SetClientListeningFlags(i, VOICE_LISTENALL);
					case 2: SetClientListeningFlags(i, VOICE_TEAM);
				}
			}
		}	
		WasGaggedLastCheck[i] = IsClientChatGagged(i);
		WasMutedLastCheck[i] = IsClientVoiceMuted(i);
			
		
	}
}

public Action OnClientSayCommand(int client, const char[] command, const char[] Args)
{
	int Expire;
	bool permanent;
	if(IsClientChatGagged(client, Expire, permanent))
	{
		if(permanent)
			PrintToChat(client, "You have been gagged. It will never expire");
		
		else
			PrintToChat(client, "You have been gagged. It will expire in %i minutes", RoundToFloor((float((Expire - GetTime())) / 60.0) - 0.1) + 1);
			
		return Plugin_Stop;
	}

	return Plugin_Continue;
}

// Global agreement that if kick_message is not null and flags have no kick, I'll do the kicking?
public Action OnBanClient(int client, int time, int flags, const char[] reason, const char[] kick_message, const char[] command, any source)
{
	if(client == 0)
		return Plugin_Continue;
		
	char sQuery[1024];
	
	char AuthId[35], IPAddress[32], Name[64], AdminAuthId[35], AdminName[64];
	GetClientAuthId(client, AuthId_Steam2, AuthId, sizeof(AuthId));
	GetClientIP(client, IPAddress, sizeof(IPAddress), true);
	GetClientName(client, Name, sizeof(Name));
	
	if(source == 0)
	{
		AdminAuthId = "CONSOLE";
		AdminName = "CONSOLE";
	}
	else
	{
		GetClientAuthId(source, AuthId_Steam2, AdminAuthId, sizeof(AdminAuthId));
		GetClientName(source, AdminName, sizeof(AdminName));
	}
	int UnixTime = GetTime();
	
	if(flags & BANFLAG_AUTO)
		SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "INSERT OR IGNORE INTO SQLiteBans_players (AuthId, IPAddress, PlayerName, AdminAuthID, AdminName, Penalty, PenaltyReason, TimestampGiven, DurationMinutes) VALUES ('%s', '%s', '%s', '%s', '%s',  %i, '%s', %i, %i)", AuthId, IPAddress, Name, AdminAuthId, AdminName, Penalty_Ban, reason, UnixTime, time);
		
	else if(flags & BANFLAG_IP)
		SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "INSERT OR IGNORE INTO SQLiteBans_players (IPAddress, PlayerName, AdminAuthID, AdminName, Penalty, PenaltyReason, TimestampGiven, DurationMinutes) VALUES ('%s', '%s', '%s', '%s',  %i, '%s', %i, %i)", IPAddress, Name, AdminAuthId, AdminName, Penalty_Ban, reason, UnixTime, time);

	else if(flags & BANFLAG_AUTHID)
		SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "INSERT OR IGNORE INTO SQLiteBans_players (AuthId, PlayerName, AdminAuthID, AdminName, Penalty, PenaltyReason, TimestampGiven, DurationMinutes) VALUES ('%s', '%s', '%s', '%s',  %i, '%s', %i, %i)", AuthId, Name, AdminAuthId, AdminName, Penalty_Ban, reason, UnixTime, time);
		
	else
		return Plugin_Continue;	
	
	if(time == 0)
		LogSQLiteBans("Admin %N [AuthId: %s] banned %N permanently ([AuthId: %s],[IP: %s]). Reason: %s", source, AdminAuthId, client, AuthId, IPAddress, reason);

	else
		LogSQLiteBans("Admin %N [AuthId: %s] banned %N for %i minutes ([AuthId: %s],[IP: %s]). Reason: %s", source, AdminAuthId, client, time, AuthId, IPAddress, reason);
	
	Handle DP = CreateDataPack();
	
	WritePackCell(DP, GetEntityUserId(source));
	
	WritePackString(DP, AuthId);
	WritePackString(DP, Name);
	WritePackString(DP, AdminAuthId);
	WritePackString(DP, AdminName);
	WritePackString(DP, reason);
	
	WritePackCell(DP, time);
	
	SQL_TQuery(dbLocal, SQLCB_IdentityBanned, sQuery, DP);
	
	if(kick_message[0] != EOS && flags & BANFLAG_NOKICK)
	{
		KickBannedClient(client, time, AdminName, reason, UnixTime);
	}
	return Plugin_Handled;
}

public Action OnBanIdentity(const char[] identity, int time, int flags, const char[] reason, const char[] command, any source)
{		
	char sQuery[1024];
	
	char AdminAuthId[35], AdminName[64];
	
	if(source == 0)
	{
		AdminAuthId = "CONSOLE";
		AdminName = "CONSOLE";
	}
	else
	{
		GetClientAuthId(source, AuthId_Steam2, AdminAuthId, sizeof(AdminAuthId));
		GetClientName(source, AdminName, sizeof(AdminName));
	}
	
	int UnixTime = GetTime();
	
	char AuthId[35];
	char IPAddress[32];
	char Name[64];
	
	Call_StartForward(fw_OnBanIdentity);
	
	Call_PushCell(flags);
	Call_PushString(identity);
	
	Call_PushStringEx(AuthId, sizeof(AuthId), SM_PARAM_STRING_UTF8|SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
	Call_PushStringEx(IPAddress, sizeof(IPAddress), SM_PARAM_STRING_UTF8|SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
	Call_PushStringEx(Name, sizeof(Name), SM_PARAM_STRING_UTF8|SM_PARAM_STRING_COPY, SM_PARAM_COPYBACK);
	
	Call_Finish();
	
	if(flags & BANFLAG_AUTO && (AuthId[0] == EOS || IPAddress[0] == EOS))
		return Plugin_Continue;
	
	else if(flags & BANFLAG_AUTO)
			SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "INSERT OR IGNORE INTO SQLiteBans_players (AuthId, IPAddress, PlayerName, AdminAuthID, AdminName, Penalty, PenaltyReason, TimestampGiven, DurationMinutes) VALUES ('%s', '%s', '%s', '%s', '%s',  %i, '%s', %i, %i)", AuthId, IPAddress, Name, AdminAuthId, AdminName, Penalty_Ban, reason, UnixTime, time);
			
	else if(flags & BANFLAG_IP)
		SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "INSERT OR IGNORE INTO SQLiteBans_players (IPAddress, PlayerName, AdminAuthID, AdminName, Penalty, PenaltyReason, TimestampGiven, DurationMinutes) VALUES ('%s', '%s', '%s', '%s',  %i, '%s', %i, %i)", identity, Name, AdminAuthId, AdminName, Penalty_Ban, reason, UnixTime, time);
	
	else if(flags & BANFLAG_AUTHID)
		SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "INSERT OR IGNORE INTO SQLiteBans_players (AuthId, PlayerName, AdminAuthID, AdminName, Penalty, PenaltyReason, TimestampGiven, DurationMinutes) VALUES ('%s', '%s', '%s', '%s',  %i, '%s', %i, %i)", identity, Name, AdminAuthId, AdminName, Penalty_Ban, reason, UnixTime, time);
	
	else
		return Plugin_Continue;
		
	Handle DP = CreateDataPack();
	
	WritePackCell(DP, GetEntityUserId(source));
	
	WritePackString(DP, AuthId);
	WritePackString(DP, Name);
	WritePackString(DP, AdminAuthId);
	WritePackString(DP, AdminName);
	WritePackString(DP, reason);
	
	WritePackCell(DP, time);
	
	SQL_TQuery(dbLocal, SQLCB_IdentityBanned, sQuery, DP);

	if(time == 0)
		LogSQLiteBans("Admin %N [AuthId: %s] added a permanent ban on identity %s. Reason: %s", source, AdminAuthId, identity, reason);

	else
		LogSQLiteBans("Admin %N [AuthId: %s] added a %i minute ban on identity %s. Reason: %s", source, AdminAuthId, time, identity, reason);
		
	return Plugin_Handled;
}

public void SQLCB_IdentityBanned(Handle db, Handle hndl, const char[] sError, Handle DP)
{
	
	if(hndl == null)
		ThrowError(sError);
    
	ResetPack(DP);
	
	int source = GetEntityOfUserId(ReadPackCell(DP));
	
	char AuthId[35], Name[64], AdminAuthId[35], AdminName[64], reason[256];
	
	ReadPackString(DP, AuthId, sizeof(AuthId));
	ReadPackString(DP, Name, sizeof(Name));
	ReadPackString(DP, AdminAuthId, sizeof(AdminAuthId));
	ReadPackString(DP, AdminName, sizeof(AdminName));
	ReadPackString(DP, reason, sizeof(reason));
	
	int time = ReadPackCell(DP);
	
	CloseHandle(DP);
	
	if(SQL_GetAffectedRows(hndl) == 0)
	{
		ReplyToCommand(source, "Target %s is already banned!", Name);
		
		return;
	}
	
	Call_StartForward(fw_OnBanIdentity_Post);
	
	Call_PushString(AuthId);

	Call_PushString(Name);
	
	Call_PushString(AdminAuthId);
	Call_PushString(AdminName);
	
	Call_PushString(reason);
	
	Call_PushCell(time);
	
	Call_Finish();
	
}
public Action Event_PlayerSpawn(Handle hEvent, const char[] Name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(hEvent, "userid"));
	
	if(client == 0)
		return;
		
	if(IsClientVoiceMuted(client))
		SetClientListeningFlags(client, VOICE_MUTED);
	
	else
		SetClientListeningFlags(client, VOICE_NORMAL);
}


public Action Event_PlayerDeath(Handle hEvent, const char[] Name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(hEvent, "userid"));
	
	if(client == 0)
		return;
		
	if(IsClientVoiceMuted(client))
	{
		SetClientListeningFlags(client, VOICE_MUTED);
		return;
	}
	
	else if(GetConVarBool(hcv_Alltalk))
	{
		SetClientListeningFlags(client, VOICE_NORMAL);
	}
	
	switch(GetConVarInt(hcv_Deadtalk))
	{
		case 1: SetClientListeningFlags(client, VOICE_LISTENALL);
		case 2: SetClientListeningFlags(client, VOICE_TEAM);
	}
}


public void hcvChange_Deadtalk(Handle convar, const char[] oldValue, const char[] newValue)
{
	if(StringToInt(newValue) == 1)
	{
		HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
		HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
		IsHooked = true;
		return;
	}
	
	else if(IsHooked)
	{
		UnhookEvent("player_spawn", Event_PlayerSpawn);
		UnhookEvent("player_death", Event_PlayerDeath);		
		IsHooked = false;
	}
}


public void hcvChange_Alltalk(Handle convar, const char[] oldValue, const char[] newValue)
{
	int mode = GetConVarInt(hcv_Deadtalk);
	
	for(int i=1;i <= MaxClients;i++)
	{
		if(!IsClientInGame(i))
			continue;
		
		if(IsClientVoiceMuted(i))
		{
			SetClientListeningFlags(i, VOICE_MUTED);
			continue;
		}
		
		else if(GetConVarBool(convar))
		{
			SetClientListeningFlags(i, VOICE_NORMAL);
			continue;
		}
		
		else if(!IsPlayerAlive(i))
		{
			if(mode == 1)
			{
				SetClientListeningFlags(i, VOICE_LISTENALL);
				continue;
			}
			else if (mode == 2)
			{
				SetClientListeningFlags(i, VOICE_TEAM);
				continue;
			}
		}
	}
}

public void OnClientDisconnect(int client)
{
	int count = view_as<int>(enPenaltyType_LENGTH);
	for(int i=0;i < count;i++)
		ExpirePenalty[client][i] = 0;
}

public void OnClientConnected(int client)
{
	WasGaggedLastCheck[client] = false;
	WasMutedLastCheck[client] = false;
}

public void OnClientPostAdminCheck(int client)
{
	int count = view_as<int>(enPenaltyType_LENGTH);
	for(int i=0;i < count;i++)
		ExpirePenalty[client][i] = 0;
		
	if(IsFakeClient(client))
		return;

	char AuthId[35];
	
	if(!GetClientAuthId(client, AuthId_Steam2, AuthId, sizeof(AuthId)))
		CreateTimer(5.0, Timer_Auth, GetClientUserId(client), TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	else
		FindClientPenalties(client);
}

public Action Timer_Auth(Handle timer, int UserId)
{
	int client = GetClientOfUserId(UserId);
	
	char AuthId[35]
	if(!GetClientAuthId(client, AuthId_Steam2, AuthId, sizeof AuthId))
		return Plugin_Continue;
		
	else
	{
		FindClientPenalties(client);
		
		return Plugin_Stop;
	}
}

void FindClientPenalties(int client)
{
	if(ExpireBreach > GetGameTime())
		return;

	int count = view_as<int>(enPenaltyType_LENGTH);
	for(int i=0;i < count;i++)
		ExpirePenalty[client][i] = 0;
		
	bool GotAuthId;
	char AuthId[35], IPAddress[32];
	GotAuthId = GetClientAuthId(client, AuthId_Steam2, AuthId, sizeof(AuthId));
	GetClientIP(client, IPAddress, sizeof(IPAddress), true);
	
	char sQuery[256];
	
	if(GotAuthId)
		SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "SELECT * FROM SQLiteBans_players WHERE AuthId = '%s' OR IPAddress = '%s'", AuthId, IPAddress);
		
	else
		SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "SELECT * FROM SQLiteBans_players WHERE IPAddress = '%s'", IPAddress);
	
	SQL_TQuery(dbLocal, SQLCB_GetClientInfo, sQuery, GetClientUserId(client));
}


public void SQLCB_GetClientInfo(Handle db, Handle hndl, const char[] sError, int data)
{
	if(hndl == null)
		ThrowError(sError);
    
	int client = GetClientOfUserId(data);

	if(client == 0)
		return;
	
	else if(SQL_GetRowCount(hndl) == 0)
		return;
	
	bool Purge = false;
	
	int UnixTime = GetTime();
	
	while(SQL_FetchRow(hndl))
	{
		int TimestampGiven = SQL_FetchInt(hndl, 7);
		int DurationMinutes = SQL_FetchInt(hndl, 8);
		
		if(DurationMinutes != 0 && TimestampGiven + (DurationMinutes * 60) < UnixTime) // if(TimestampGiven + (DurationMinutes * 60) < GetTime())
		{
			Purge = true;
			continue;
		}	
		enPenaltyType Penalty = view_as<enPenaltyType>(SQL_FetchInt(hndl, 5));
		
		switch(Penalty)
		{
			case Penalty_Ban:
			{
				char BanReason[256], AdminName[64];
				
				SQL_FetchString(hndl, 4, AdminName, sizeof(AdminName));
				SQL_FetchString(hndl, 6, BanReason, sizeof(BanReason));
				
				char AuthId[35], IPAddress[32];
				GetClientAuthId(client, AuthId_Steam2, AuthId, sizeof(AuthId));
				GetClientIP(client, IPAddress, sizeof(IPAddress), true);
				
				if(GetConVarBool(hcv_LogBannedConnects))
				{
					if(DurationMinutes == 0)
						LogSQLiteBans_BannedConnect("Kicked banned client %N ([AuthId: %s],[IP: %s]), ban will never expire", client, AuthId, IPAddress)
						
					else
						LogSQLiteBans_BannedConnect("Kicked banned client %N ([AuthId: %s],[IP: %s]), ban expires in %i minutes", client, AuthId, IPAddress, ((TimestampGiven + (DurationMinutes * 60)) - UnixTime) / 60)
				}
				
				KickBannedClient(client, DurationMinutes, AdminName, BanReason, TimestampGiven);
				
				return;
			}
			default:
			{
				if(Penalty >= enPenaltyType_LENGTH)
					continue;

				if(DurationMinutes == 0)
					ExpirePenalty[client][Penalty] = -1;
					
				else
					ExpirePenalty[client][Penalty] = TimestampGiven + DurationMinutes * 60;
			}
		}
	}
	
	if(IsClientChatGagged(client))
		BaseComm_SetClientGag(client, true);
		
	if(IsClientVoiceMuted(client))
		BaseComm_SetClientMute(client, true);
		
	if(Purge)
	{
		char sQuery[256];
			
		SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "DELETE FROM SQLiteBans_players WHERE DurationMinutes != 0 AND TimestampGiven + (60 * DurationMinutes) < %i", UnixTime);
		SQL_TQuery(dbLocal, SQLCB_Error, sQuery, 9);
	}
}

public Action Command_Ban(int client, int args)
{
	if(ExpireBreach != 0.0)
	{	
		ReplyToCommand(client, "You need to disable ban breach by using !kickbreach before banning a client.");
		return Plugin_Handled;
	}	
	if(args < 2)
	{
		ReplyToCommand(client, "[SM] Usage: sm_ban <#userid|name> <time> [reason]");
		return Plugin_Handled;
	}	
	
	char ArgStr[256];
	char TargetArg[64], BanDuration[32];
	char BanReason[170];
	GetCmdArgString(ArgStr, sizeof(ArgStr));
	
	int len = BreakString(ArgStr, TargetArg, sizeof(TargetArg));
	
	int len2 = BreakString(ArgStr[len], BanDuration, sizeof(BanDuration));
	
	if(len2 != -1)
		FormatEx(BanReason, sizeof(BanReason), ArgStr[len+len2]);
	
	int target_list[1];
	int TargetClient, ReplyReason;
	bool tn_is_ml;
	char target_name[MAX_TARGET_LENGTH];
	
	if ((ReplyReason = ProcessTargetString(
		TargetArg,
		client, 
		target_list, 
		1, 
		COMMAND_FILTER_CONNECTED|COMMAND_FILTER_NO_MULTI|COMMAND_FILTER_NO_BOTS,
		target_name,
		sizeof(target_name),
		tn_is_ml)) <= 0)
	{
		ReplyToTargetError(client, ReplyReason);
		return Plugin_Handled;
	}
	
	TargetClient = target_list[0];
	
	bool canTarget = false;
	
	canTarget = CanClientBanTarget(client, TargetClient);
		
	if(!canTarget)
	{
		ReplyToTargetError(client, COMMAND_TARGET_IMMUNE);
		return Plugin_Handled;
	}
	
	int Duration = StringToInt(BanDuration);
	
	// This is the function to ban a client with source being the banning client or 0 for console. If you want my plugin to use its own kicking mechanism, add BANFLAG_NOKICK and set the kick reason to anything apart from ""
	BanClient(TargetClient, Duration, BANFLAG_AUTHID|BANFLAG_NOKICK, BanReason, "KICK!!!", "sm_ban", client);
	
	char AuthId[35], AdminAuthId[35], IPAddress[32];
	GetClientIP(TargetClient, IPAddress, sizeof(IPAddress), true);
	GetClientAuthId(TargetClient, AuthId_Steam2, AuthId, sizeof(AuthId));
	GetClientAuthId(client, AuthId_Steam2, AdminAuthId, sizeof(AdminAuthId));
	
	if(Duration == 0)
		ShowActivity2(client, "[SM] ", "permanently banned %N for the reason \"%s\"", TargetClient, BanReason);

	else
		ShowActivity2(client, "[SM] ", "banned %N for %i minutes for the reason \"%s\"", TargetClient, Duration, BanReason);
		
	return Plugin_Handled;
}

public Action Command_BanIP(int client, int args)
{
	if(ExpireBreach != 0.0)
	{	
		ReplyToCommand(client, "You need to disable ban breach by using !kickbreach before banning a client.");
		return Plugin_Handled;
	}	
	if(args < 2)
	{
		ReplyToCommand(client, "[SM] Usage: sm_banip <#userid|name> <time> [reason]");
		return Plugin_Handled;
	}	
	
	char ArgStr[256];
	char TargetArg[64], BanDuration[32];
	char BanReason[170];
	GetCmdArgString(ArgStr, sizeof(ArgStr));
	
	int len = BreakString(ArgStr, TargetArg, sizeof(TargetArg));
	
	int len2 = BreakString(ArgStr[len], BanDuration, sizeof(BanDuration));
	
	if(len2 != -1)
		FormatEx(BanReason, sizeof(BanReason), ArgStr[len+len2]);
	
	int target_list[1];
	int TargetClient, ReplyReason;
	bool tn_is_ml;
	char target_name[MAX_TARGET_LENGTH];
	
	if ((ReplyReason = ProcessTargetString(
		TargetArg,
		client, 
		target_list, 
		1, 
		COMMAND_FILTER_CONNECTED|COMMAND_FILTER_NO_MULTI|COMMAND_FILTER_NO_BOTS,
		target_name,
		sizeof(target_name),
		tn_is_ml)) <= 0)
	{
		ReplyToTargetError(client, ReplyReason);
		return Plugin_Handled;
	}
	
	TargetClient = target_list[0];
	
	bool canTarget = false;
	
	canTarget = CanClientBanTarget(client, TargetClient);
		
	if(!canTarget)
	{
		ReplyToTargetError(client, COMMAND_TARGET_IMMUNE);
		return Plugin_Handled;
	}
	
	int Duration = StringToInt(BanDuration);
	// This is the function to IP ban a client with source being the banning client or 0 for console. If you want my plugin to use its own kicking mechanism, add BANFLAG_NOKICK and set the kick reason to anything apart from ""
	BanClient(TargetClient, Duration, BANFLAG_IP|BANFLAG_NOKICK, BanReason, "KICK!!!", "sm_banip", client);
	
	char AuthId[35], AdminAuthId[35], IPAddress[32];
	GetClientIP(TargetClient, IPAddress, sizeof(IPAddress), true);
	GetClientAuthId(TargetClient, AuthId_Steam2, AuthId, sizeof(AuthId));
	GetClientAuthId(client, AuthId_Steam2, AdminAuthId, sizeof(AdminAuthId));
	
	if(Duration == 0)
		ShowActivity2(client, "[SM] ", "permanently banned %N for the reason \"%s\"", TargetClient, BanReason);

	else
		ShowActivity2(client, "[SM] ", "banned %N for %i minutes for the reason \"%s\"", TargetClient, Duration, BanReason);

	
	return Plugin_Handled;
}

public Action Command_FullBan(int client, int args)
{
	if(ExpireBreach != 0.0)
	{	
		ReplyToCommand(client, "You need to disable ban breach by using !kickbreach before banning a client.");
		return Plugin_Handled;
	}	
	if(args < 2)
	{
		ReplyToCommand(client, "[SM] Usage: sm_fban <#userid|name> <time> [reason]");
		return Plugin_Handled;
	}	
	
	char ArgStr[256];
	char TargetArg[64], BanDuration[32];
	char BanReason[170];
	GetCmdArgString(ArgStr, sizeof(ArgStr));
	
	int len = BreakString(ArgStr, TargetArg, sizeof(TargetArg));
	
	int len2 = BreakString(ArgStr[len], BanDuration, sizeof(BanDuration));
	
	if(len2 != -1)
		FormatEx(BanReason, sizeof(BanReason), ArgStr[len+len2]);
	
	int target_list[1];
	int TargetClient, ReplyReason;
	bool tn_is_ml;
	char target_name[MAX_TARGET_LENGTH];
	
	if ((ReplyReason = ProcessTargetString(
		TargetArg,
		client, 
		target_list, 
		1, 
		COMMAND_FILTER_CONNECTED|COMMAND_FILTER_NO_MULTI|COMMAND_FILTER_NO_BOTS,
		target_name,
		sizeof(target_name),
		tn_is_ml)) <= 0)
	{
		ReplyToTargetError(client, ReplyReason);
		return Plugin_Handled;
	}
	
	TargetClient = target_list[0];
	
	bool canTarget = false;
	
	canTarget = CanClientBanTarget(client, TargetClient);
		
	if(!canTarget)
	{
		ReplyToTargetError(client, COMMAND_TARGET_IMMUNE);
		return Plugin_Handled;
	}

	GetCmdArg(0, ArgStr, sizeof(ArgStr)); // I already used it.
	
	int Duration = StringToInt(BanDuration);
	// This is the function to full ban a client with source being the banning client or 0 for console. If you want my plugin to use its own kicking mechanism, add BANFLAG_NOKICK and set the kick reason to anything apart from ""
	BanClient(TargetClient, Duration, BANFLAG_AUTO|BANFLAG_NOKICK, BanReason, "KICK!!!", ArgStr, client);
	
	if(Duration == 0)
		ShowActivity2(client, "[SM] ", "permanently banned %N", TargetClient);
		
	else
		ShowActivity2(client, "[SM] ", "banned %N for %i minutes", TargetClient, Duration);
		
	char AuthId[35], AdminAuthId[35], IPAddress[32];
	GetClientIP(TargetClient, IPAddress, sizeof(IPAddress), true);
	GetClientAuthId(TargetClient, AuthId_Steam2, AuthId, sizeof(AuthId));
	GetClientAuthId(client, AuthId_Steam2, AdminAuthId, sizeof(AdminAuthId));

	
	return Plugin_Handled;
}


public Action Command_AddBan(int client, int args)
{
	if(ExpireBreach != 0.0)
	{	
		ReplyToCommand(client, "You need to disable ban breach by using !kickbreach before banning a client.");
		return Plugin_Handled;
	}	
	if(args < 2)
	{
		ReplyToCommand(client, "[SM] Usage: sm_addban <steamid|ip> <minutes|0> [reason]");
		return Plugin_Handled;
	}	
	
	char ArgStr[256];
	char TargetArg[64], BanDuration[32];
	char BanReason[170];
	GetCmdArgString(ArgStr, sizeof(ArgStr));
	
	int len = BreakString(ArgStr, TargetArg, sizeof(TargetArg));
	
	int len2 = BreakString(ArgStr[len], BanDuration, sizeof(BanDuration));
	
	if(len2 != -1)
		FormatEx(BanReason, sizeof(BanReason), ArgStr[len+len2]);
	
	bool isAuthBan = !IsCharNumeric(TargetArg[0]);
	
	int flags;
	if(isAuthBan)
		flags |= BANFLAG_AUTHID
		
	else
		flags |= BANFLAG_IP;
		
	int Duration = StringToInt(BanDuration);
	// This is the function to ban an identity with source being the banning client or 0 for console. If you want my plugin to use its own kicking mechanism, add BANFLAG_NOKICK and set the kick reason to anything apart from ""
	BanIdentity(TargetArg, Duration, flags, BanReason, "sm_addban", client); 
		
	ReplyToCommand(client, "Added %s to the ban list", TargetArg);
	
	char AdminAuthId[35];
	
	if(client == 0)
		AdminAuthId = "CONSOLE";
		
	else
		GetClientAuthId(client, AuthId_Steam2, AdminAuthId, sizeof(AdminAuthId));

	if(Duration == 0)
		ShowActivity2(client, "[SM] ", "added a permanent ban on identity %s. Reason: %s", TargetArg, BanReason);

	else
		ShowActivity2(client, "[SM] ", "added a %i minute ban on identity: %s", Duration, BanReason);

	return Plugin_Handled;
}

public Action Command_Unban(int client, int args)
{
	if(args == 0)
	{
		ReplyToCommand(client, "[SM] Usage: sm_unban <steamid|ip>");
		return Plugin_Handled;
	}	
	
	char TargetArg[64];
	GetCmdArgString(TargetArg, sizeof(TargetArg));
	StripQuotes(TargetArg);
	ReplaceString(TargetArg, sizeof(TargetArg), " ", ""); // Some bug when using rcon...
	
	if(TargetArg[0] == EOS)
	{
		ReplyToCommand(client, "[SM] Usage: sm_unban <steamid|ip>");
		return Plugin_Handled;
	}
	
	Handle DP = CreateDataPack();
	
	WritePackCell(DP, GetEntityUserId(client));
	WritePackCell(DP, GetCmdReplySource());
	
	WritePackString(DP, TargetArg);
	
	if(client == 0)
		WritePackString(DP, "CONSOLE");
		
	else
	{
		char AdminAuthId[35];
		GetClientAuthId(client, AuthId_Steam2, AdminAuthId, sizeof(AdminAuthId));
		
		WritePackString(DP, AdminAuthId);
	}
	
	char sQuery[1024];
	SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "DELETE FROM SQLiteBans_players WHERE Penalty = %i AND (AuthId = '%s' OR IPAddress = '%s')", Penalty_Ban, TargetArg, TargetArg);
	SQL_TQuery(dbLocal, SQLCB_Unban, sQuery, DP);
	
	return Plugin_Handled;
}

public void SQLCB_Unban(Handle db, Handle hndl, const char[] sError, Handle DP)
{
	if(hndl == null)
	{
		CloseHandle(DP);
		ThrowError(sError);
    }
	
	ResetPack(DP);
	
	int UserId = ReadPackCell(DP);
	
	ReplySource CmdReplySource = ReadPackCell(DP);
	
	char TargetArg[64];
	ReadPackString(DP, TargetArg, sizeof(TargetArg));
	
	char AdminAuthId[35];
	ReadPackString(DP, AdminAuthId, sizeof(AdminAuthId)); // Even if the player disconnects we must log him.
	
	CloseHandle(DP);
	int client = GetEntityOfUserId(UserId);
	
	int AffectedRows = SQL_GetAffectedRows(hndl)
	ReplyToCommandBySource(client, CmdReplySource, "Successfully deleted %i bans matching %s", AffectedRows, TargetArg);
	
	LogSQLiteBans("Admin %N [AuthId: %s] deleted %i bans matching \"%s\"", client, AdminAuthId, AffectedRows, TargetArg);
}

public Action Command_Null(int client, int args)
{
	return Plugin_Handled;
}

public Action Listener_Penalty(int client, const char[] command, int args)
{
	if(client && !CheckCommandAccess(client, command, ADMFLAG_CHAT))
		return Plugin_Continue;
		
	if(args < 2)
	{
		ReplyToCommand(client, "[SM] Usage: %s <#userid|name> <minutes|0> [reason]", command);
		return Plugin_Stop;
	}	
	
	char ArgStr[256];
	char TargetArg[64], PenaltyDuration[32];
	char PenaltyReason[170];
	GetCmdArgString(ArgStr, sizeof(ArgStr));
	
	int len = BreakString(ArgStr, TargetArg, sizeof(TargetArg));
	
	int len2 = BreakString(ArgStr[len], PenaltyDuration, sizeof(PenaltyDuration));
	
	if(len2 != -1)
		FormatEx(PenaltyReason, sizeof(PenaltyReason), ArgStr[len+len2]);
	
	int target_list[MAXPLAYERS+1];
	int TargetClient, target_count;
	bool tn_is_ml;
	char target_name[MAX_TARGET_LENGTH];
	
	if ((target_count = ProcessTargetString(
		TargetArg,
		client, 
		target_list, 
		sizeof(target_list), 
		COMMAND_FILTER_CONNECTED|COMMAND_FILTER_NO_MULTI|COMMAND_FILTER_NO_BOTS,
		target_name,
		sizeof(target_name),
		tn_is_ml)) <= 0)
	{
		ReplyToTargetError(client, target_count);
		return Plugin_Stop;
	}
	
	char PenaltyAlias[32];
	enPenaltyType PenaltyType;
	if(StrEqual(command, "sm_gag"))
	{
		PenaltyType = Penalty_Gag;
		PenaltyAlias = "gagged";
	}
	else if(StrEqual(command, "sm_mute"))
	{
		PenaltyType = Penalty_Mute;
		PenaltyAlias = "muted";
	}
	else if(StrEqual(command, "sm_silence"))
	{
		PenaltyType = Penalty_Silence;
		PenaltyAlias = "silenced";
	}
	
	int Duration = StringToInt(PenaltyDuration);
	
	TargetClient = target_list[0];
	
	int Expire;
	bool Extended; // Fix with IsClientChatGagged
	
	if(PenaltyType == Penalty_Mute || PenaltyType == Penalty_Silence)
		Extended = IsClientVoiceMuted(client, Expire);
	
	else if(PenaltyType == Penalty_Gag)
		Extended = IsClientChatGagged(client, Expire);
		

	if(Expire == -1)
	{
		ReplyToCommand(client, "[SM] Cannot extend penalty on a permanently %s client.", PenaltyAlias);
		return Plugin_Stop;
	}
	
	if(!IsClientAuthorized(TargetClient))
	{
		ReplyToCommand(client, "[SM] Error: Could not authenticate %N.", TargetClient);
		return Plugin_Stop;
	}
	if(!SQLiteBans_CommPunishClient(TargetClient, PenaltyType, Duration, PenaltyReason, client, false))
		return Plugin_Stop;

	if(!Extended)
	{
		if(Duration == 0)
		{
			PrintToChat(TargetClient, "You have been permanently %s by %N.", PenaltyAlias, client);
			ShowActivity2(client, "[SM] ", "permanently %s %N", PenaltyAlias, TargetClient);
		}
		else
		{
			PrintToChat(TargetClient, "You have been %s by %N for %i minutes.", PenaltyAlias, client, Duration);
			ShowActivity2(client, "[SM] ", "%s %N for %i minutes", PenaltyAlias, TargetClient, Duration);
		}
	}
	else
	{
		PrintToChat(TargetClient, "You have been %s by %N for %i more minutes ( total: %i )", PenaltyAlias, client, Duration, PositiveOrZero(((ExpirePenalty[TargetClient][PenaltyType] - GetTime()) / 60)));
		ShowActivity2(client, "[SM] ", "%s %N for %i more minutes ( total: %i )", PenaltyAlias, TargetClient, Duration, PositiveOrZero((ExpirePenalty[TargetClient][PenaltyType] - GetTime()) / 60));
	}	
	
	PrintToChat(TargetClient, "Reason: %s", PenaltyReason);
	
	return Plugin_Stop;
}


public Action Listener_Unpenalty(int client, const char[] command, int args)
{
	if(client && !CheckCommandAccess(client, command, ADMFLAG_CHAT))
		return Plugin_Continue;
		
	if(args == 0)
	{
		ReplyToCommand(client, "[SM] Usage: %s <#userid|name>", command);
		return Plugin_Stop;
	}	
	
	char TargetArg[64];
	GetCmdArg(1, TargetArg, sizeof(TargetArg));

	int target_list[MAXPLAYERS+1];
	int TargetClient, target_count;
	bool tn_is_ml;
	char target_name[MAX_TARGET_LENGTH];
	
	if ((target_count = ProcessTargetString(
		TargetArg,
		client, 
		target_list, 
		sizeof(target_list), 
		COMMAND_FILTER_CONNECTED|COMMAND_FILTER_NO_BOTS,
		target_name,
		sizeof(target_name),
		tn_is_ml)) <= 0)
	{
		ReplyToTargetError(client, target_count);
		return Plugin_Stop;
	}
	
	char PenaltyAlias[32];
	enPenaltyType PenaltyType;
	
	if(StrEqual(command, "sm_ungag"))
	{
		PenaltyType = Penalty_Gag;
		PenaltyAlias = "ungagged";
	}
	else if(StrEqual(command, "sm_unmute"))
	{
		PenaltyType = Penalty_Mute;
		PenaltyAlias = "unmuted";
	}
	else if(StrEqual(command, "sm_unsilence"))
	{
		PenaltyType = Penalty_Silence;
		PenaltyAlias = "unsilenced";
	}
	
	for(int i=0;i < target_count;i++)
	{
		TargetClient = target_list[i];
		
		PrintToChat(TargetClient, "You have been %s by %N", PenaltyAlias, client);
		
		SQLiteBans_CommUnpunishClient(TargetClient, PenaltyType, client);
	}

	ShowActivity2(client, "[SM] ", "%s %s", PenaltyAlias, target_name);
		
	return Plugin_Stop;
}


public Action Command_OfflinePenalty(int client, int args)
{
	char command[32];
	GetCmdArg(0, command, sizeof(command));
	
	if(args < 2)
	{
		ReplyToCommand(client, "[SM] Usage: %s <steamid> <minutes|0> [reason]", command);
		return Plugin_Handled;
	}	

	char ArgStr[256];
	char TargetArg[64], PenaltyDuration[32];
	char PenaltyReason[170];
	GetCmdArgString(ArgStr, sizeof(ArgStr));
	
	int len = BreakString(ArgStr, TargetArg, sizeof(TargetArg));
	
	int len2 = BreakString(ArgStr[len], PenaltyDuration, sizeof(PenaltyDuration));
	
	if(len2 != -1)
		FormatEx(PenaltyReason, sizeof(PenaltyReason), ArgStr[len+len2]);
		
	enPenaltyType PenaltyType;
	char PenaltyAlias[32];
	
	if(StrEqual(command, "sm_ogag"))
	{
		PenaltyType = Penalty_Gag;
		PenaltyAlias = "gagged";
	}
	else if(StrEqual(command, "sm_omute"))
	{
		PenaltyType = Penalty_Mute;
		PenaltyAlias = "muted";
	}
	else if(StrEqual(command, "sm_osilence"))
	{
		PenaltyType = Penalty_Silence;
		PenaltyAlias = "silenced";
	}


	int Duration = StringToInt(PenaltyDuration);
	
	if(SQLiteBans_CommPunishIdentity(TargetArg, PenaltyType, "", Duration, PenaltyReason, client, false))
	{
		if(Duration != 0)
		{
			ReplyToCommand(client, "Successfully %s steamid %s for %i minutes.", PenaltyAlias, TargetArg, Duration);
			ReplyToCommand(client, "Note: Using this command on an already %s player will extend the duration", PenaltyAlias);
		}	
		else
			ReplyToCommand(client, "Successfully %s steamid %s permanently", PenaltyAlias, TargetArg);
			
	}
	else
	{
		ReplyToCommand(client, "Could not %s steamid %s", PenaltyAlias, TargetArg);
	}
	return Plugin_Handled;
}


public Action Command_OfflineUnpenalty(int client, int args)
{
	char command[32];
	GetCmdArg(0, command, sizeof(command));
	if(args == 0)
	{
		ReplyToCommand(client, "[SM] Usage: %s <steamid>", command);
		return Plugin_Handled;
	}	
	
	char TargetArg[64];
	GetCmdArgString(TargetArg, sizeof(TargetArg));
	StripQuotes(TargetArg);
	
	if(TargetArg[0] == EOS)
	{
		ReplyToCommand(client, "[SM] Usage: %s <steamid>", command);
		return Plugin_Handled;
	}
	int UserId = (client == 0 ? 0 : GetClientUserId(client));
	
	int PenaltyType = enPenaltyType;
	
	if(StrEqual(command, "sm_oungag"))
		PenaltyType = Penalty_Gag;

	else if(StrEqual(command, "sm_ounmute"))
		PenaltyType = Penalty_Mute;
		
	else if(StrEqual(command, "sm_ounsilence"))
		PenaltyType = Penalty_Silence;
		
	Handle DP = CreateDataPack();
	
	WritePackCell(DP, UserId);
	WritePackCell(DP, GetCmdReplySource());
	WritePackString(DP, TargetArg);
	
	char sQuery[1024];
	SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "DELETE FROM SQLiteBans_players WHERE Penalty = %i AND AuthId = '%s'", PenaltyType, TargetArg);
	SQL_TQuery(dbLocal, SQLCB_Unpenalty, sQuery, DP);
	
	return Plugin_Handled;
}


public void SQLCB_Unpenalty(Handle db, Handle hndl, const char[] sError, Handle DP)
{
	if(hndl == null)
	{
		CloseHandle(DP);
		ThrowError(sError);
    }
	
	ResetPack(DP);
	
	int UserId = ReadPackCell(DP);
	
	ReplySource CmdReplySource = ReadPackCell(DP);
	
	char TargetArg[64];
	ReadPackString(DP, TargetArg, sizeof(TargetArg));
	
	CloseHandle(DP);
	int client = (UserId == 0 ? 0 : GetClientOfUserId(UserId));
	
	if(client == 0)
		CmdReplySource = SM_REPLY_TO_CONSOLE;
	
	ReplySource PrevReplySource = GetCmdReplySource();
	
	SetCmdReplySource(CmdReplySource);
	
	ReplyToCommand(client, "Successfully deleted %i penalties matching %s", SQL_GetAffectedRows(hndl), TargetArg);
	
	SetCmdReplySource(PrevReplySource);
}

public Action Command_CommStatus(int client, int args)
{
	char ExpirationDate[64];
	int Expire, UnixTime = GetTime();
	bool Gagged = IsClientChatGagged(client, Expire);
	FormatTime(ExpirationDate, sizeof(ExpirationDate), "%d/%m/%Y - %H:%M:%S", Expire);
	
	int MinutesLeft = (Expire - UnixTime) / 60;
	if(Expire <= 0) // If you aren't gagged, it won't expire lol.
	{
		FormatEx(ExpirationDate, sizeof(ExpirationDate), "Never");
		MinutesLeft = 0;
	}	
	
	PrintToChat(client, "Gagged: %s, Expiration: %s ( %i minutes )", Gagged ? "Yes" : "No", ExpirationDate, MinutesLeft);
	
	bool Muted = IsClientVoiceMuted(client, Expire);
	
	FormatTime(ExpirationDate, sizeof(ExpirationDate), "%d/%m/%Y - %H:%M:%S", Expire);
	
	MinutesLeft = (Expire - UnixTime) / 60;
	if(Expire <= 0) // If you aren't muted, it won't expire lol.
	{
		FormatEx(ExpirationDate, sizeof(ExpirationDate), "Never");
		MinutesLeft = 0;
	}	
	
	PrintToChat(client, "Muted: %s, Expiration: %s ( %i minutes )", Muted ? "Yes" : "No", ExpirationDate, MinutesLeft);
	
	return Plugin_Handled;
}

public Action Command_BanList(int client, int args)
{
	if(client == 0)
		return Plugin_Handled;
	
	QueryBanList(client, 0);
	
	return Plugin_Handled;
}

public void QueryBanList(int client, int ItemPos)
{
	Handle DP = CreateDataPack();
	
	WritePackCell(DP, GetClientUserId(client));
	WritePackCell(DP, ItemPos);
		
	char sQuery[256];
	
	SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "DELETE FROM SQLiteBans_players WHERE DurationMinutes != 0 AND TimestampGiven + (60 * DurationMinutes) < %i", GetTime());
	SQL_TQuery(dbLocal, SQLCB_Error, sQuery, 10);
		
	SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "SELECT * FROM SQLiteBans_players WHERE Penalty = %i ORDER BY TimestampGiven DESC", Penalty_Ban); 
	SQL_TQuery(dbLocal, SQLCB_BanList, sQuery, DP); 
}

public void SQLCB_BanList(Handle db, Handle hndl, const char[] sError, Handle DP)
{

	ResetPack(DP);
	
	int UserId = ReadPackCell(DP);
	int ItemPos = ReadPackCell(DP);
	
	CloseHandle(DP);
	
	if(hndl == null)
		ThrowError(sError);
    
	int client = GetClientOfUserId(UserId);

	if(client != 0)
	{
		if(SQL_GetRowCount(hndl) == 0)
		{
			PrintToChat(client, "There are no banned clients from the server");
			PrintToConsole(client, "There are no banned clients from the server");
		}
		char TempFormat[512], AuthId[35], IPAddress[32], PlayerName[64], BanReason[256];
		
		Handle hMenu = CreateMenu(BanList_MenuHandler);
	
		while(SQL_FetchRow(hndl))
		{
			SQL_FetchString(hndl, 0, AuthId, sizeof(AuthId));
			SQL_FetchString(hndl, 1, IPAddress, sizeof(IPAddress));
			SQL_FetchString(hndl, 2, PlayerName, sizeof(PlayerName));
			
			if(PlayerName[0] == EOS)
				FormatEx(PlayerName, sizeof(PlayerName), AuthId);
				
			if(PlayerName[0] == EOS)
				FormatEx(PlayerName, sizeof(PlayerName), IPAddress);
			
			SQL_FetchString(hndl, 6, BanReason, sizeof(BanReason));
			StripQuotes(BanReason);
			
			int BanExpiration = SQL_FetchInt(hndl, 8) - ((GetTime() - SQL_FetchInt(hndl, 7)) / 60)
			
			Format(TempFormat, sizeof(TempFormat), "\"%s\" \"%s\" \"%i\" \"%s\"", AuthId, IPAddress, BanExpiration, BanReason);
			AddMenuItem(hMenu, TempFormat, PlayerName);
		}
		
		DisplayMenuAtItem(hMenu, client, ItemPos, MENU_TIME_FOREVER);
	
	}
}


public int BanList_MenuHandler(Handle hMenu, MenuAction action, int client, int item)
{
	if(action == MenuAction_End)
		CloseHandle(hMenu);
	
	else if(action == MenuAction_Select)
	{
		char AuthId[32], IPAddress[32], Name[64], Info[512], sBanExpiration[64], ExpirationDate[64], BanReason[256];
		
		GetMenuItem(hMenu, item, Info, sizeof(Info), _, Name, sizeof(Name));
		
		int len = BreakString(Info, AuthId, sizeof(AuthId));
		int len2 = BreakString(Info[len], IPAddress, sizeof(IPAddress));
		
		int len3 = BreakString(Info[len+len2], sBanExpiration, sizeof(sBanExpiration));
		int BanExpiration = StringToInt(sBanExpiration);
		
		if(len3 != -1)
			BreakString(Info[len+len2+len3], BanReason, sizeof(BanReason));
		
		FormatTime(ExpirationDate, sizeof(ExpirationDate), "%d/%m/%Y - %H:%M:%S", GetTime() + (60 * BanExpiration));
		
		if(BanExpiration <= 0)
		{
			BanExpiration = 0;
			FormatEx(ExpirationDate, sizeof(ExpirationDate), "Never");
		}
		PrintToChat(client, "Name: %s, Steam ID: %s, Ban Reason: %s", Name, AuthId, BanReason);
		PrintToChat(client, "IP Address: %s, Ban Expiration: %s ( %i minutes )", IPAddress, ExpirationDate, BanExpiration);
		PrintToConsole(client, "Name: %s, SteamID: %s, Ban Reason: %s, IP Address: %s, Ban Expiration: %s ( %i minutes )", Name, AuthId, BanReason, IPAddress, ExpirationDate, BanExpiration);
		
		QueryBanList(client, GetMenuSelectionPosition());
	}
}


public Action Command_CommList(int client, int args)
{
	if(client == 0)
		return Plugin_Handled;
	
	QueryCommList(client, 0);
	
	return Plugin_Handled;
}
public void QueryCommList(int client, int ItemPos)
{
	Handle DP = CreateDataPack();
	
	WritePackCell(DP, GetClientUserId(client));
	WritePackCell(DP, ItemPos);
		
	char sQuery[256];
	
	SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "DELETE FROM SQLiteBans_players WHERE DurationMinutes != 0 AND TimestampGiven + (60 * DurationMinutes) < %i", GetTime());
	SQL_TQuery(dbLocal, SQLCB_Error, sQuery, 11);
		
	SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "SELECT * FROM SQLiteBans_players WHERE Penalty > %i AND Penalty < %i ORDER BY TimestampGiven DESC", Penalty_Ban, enPenaltyType_LENGTH); 
	SQL_TQuery(dbLocal, SQLCB_CommList, sQuery, DP); 
}

public void SQLCB_CommList(Handle db, Handle hndl, const char[] sError, Handle DP)
{
	if(hndl == null)
		ThrowError(sError);
    
	ResetPack(DP);
	
	int UserId = ReadPackCell(DP);
	int ItemPos = ReadPackCell(DP);
	
	CloseHandle(DP);
	
	int client = GetClientOfUserId(UserId);

	if(client != 0)
	{
		if(SQL_GetRowCount(hndl) == 0)
		{
			PrintToChat(client, "There are no communication punished clients in the server");
			PrintToConsole(client, "There are no communication punished clients in the server");
		}
		char TempFormat[512], AuthId[35], PlayerName[64], PenaltyReason[256];
		
		Handle hMenu = CreateMenu(CommList_MenuHandler);
	
		while(SQL_FetchRow(hndl))
		{
			SQL_FetchString(hndl, 0, AuthId, sizeof(AuthId));
			SQL_FetchString(hndl, 2, PlayerName, sizeof(PlayerName));
			
			if(PlayerName[0] == EOS)
				FormatEx(PlayerName, sizeof(PlayerName), AuthId);
			
			enPenaltyType Penalty = view_as<enPenaltyType>(SQL_FetchInt(hndl, 5));
			SQL_FetchString(hndl, 6, PenaltyReason, sizeof(PenaltyReason));
			
			int PenaltyExpiration = SQL_FetchInt(hndl, 8) - ((GetTime() - SQL_FetchInt(hndl, 7)) / 60)
			
			StripQuotes(PenaltyReason);
			Format(TempFormat, sizeof(TempFormat), "\"%s\" \"%i\" \"%i\" \"%s\"", AuthId, PenaltyExpiration, Penalty, PenaltyReason);
			AddMenuItem(hMenu, TempFormat, PlayerName);
		}
		
		DisplayMenuAtItem(hMenu, client, ItemPos, MENU_TIME_FOREVER);
	
	}
}


public int CommList_MenuHandler(Handle hMenu, MenuAction action, int client, int item)
{
	if(action == MenuAction_End)
		CloseHandle(hMenu);
	
	else if(action == MenuAction_Select)
	{
		char AuthId[32], Name[64], Info[512], sPenaltyType[11], PenaltyAlias[32], sPenaltyExpiration[64], ExpirationDate[64], PenaltyReason[256];
		
		GetMenuItem(hMenu, item, Info, sizeof(Info), _, Name, sizeof(Name));
		
		int len = BreakString(Info, AuthId, sizeof(AuthId));
		int len2 = BreakString(Info[len], sPenaltyExpiration, sizeof(sPenaltyExpiration));
		int PenaltyExpiration = StringToInt(sPenaltyExpiration);
		
		int len3 = BreakString(Info[len+len2], sPenaltyType, sizeof(sPenaltyType));
		enPenaltyType PenaltyType = view_as<enPenaltyType>(StringToInt(sPenaltyType));
		
		if(len3 != -1)
			BreakString(Info[len+len2+len3], PenaltyReason, sizeof(PenaltyReason));
		
		FormatTime(ExpirationDate, sizeof(ExpirationDate), "%d/%m/%Y - %H:%M:%S", GetTime() + (60 * PenaltyExpiration));
		
		if(PenaltyExpiration <= 0)
		{
			PenaltyExpiration = 0;
			FormatEx(ExpirationDate, sizeof(ExpirationDate), "Never");
		}
		
	
		switch(PenaltyType)
		{
			case Penalty_Gag: PenaltyAlias = "Gag";
			case Penalty_Mute: PenaltyAlias = "Mute";
			case Penalty_Silence: PenaltyAlias = "Silence";
		}
	
		PrintToChat(client, "Name: %s, Steam ID: %s, Penalty Reason: %s", Name, AuthId, PenaltyReason);
		PrintToChat(client, "Penalty Type: %s, Penalty Expiration: %s ( %i minutes )", PenaltyAlias, ExpirationDate, PenaltyExpiration);
		PrintToConsole(client, "Name: %s, SteamID: %s, Penalty Type: %s, Penalty Reason: %s, Penalty Expiration: %s ( %i minutes )", Name, AuthId, PenaltyAlias, PenaltyReason, ExpirationDate, PenaltyExpiration);
		
		Command_CommList(client, 0);
	}
}

public Action Command_BreachBans(int client, int args)
{
	ExpireBreach = GetGameTime() + 60.0;
	
	PrintToChatAll("Admin %N started a ban breach for testing purposes", client);
	PrintToChatAll("All banned players can join for the next 60 seconds");
	
	ReplyToCommand(client, "Don't forget to !kickbreach to kick all banned players inside the server.");
	
	LogSQLiteBans("Admin %N started a 60 second ban breach", client);
	
	return Plugin_Handled;
}

public Action Command_KickBreach(int client, int args)
{
	ExpireBreach = 0.0;
	
	for(int i=1;i <= MaxClients;i++)
	{
		if(!IsClientInGame(i) || !IsClientAuthorized(i))
			continue;
			
		else if(IsFakeClient(i))
			continue;
			
		FindClientPenalties(i);
	}

	PrintToChatAll("Admin %N kicked all breaching clients", client);
	LogAction(client, client, "Kicked all ban breaching clients");
	
	return Plugin_Handled;
}
/*
public Action:Command_Backup(client, args)
{
	new String:sQuery[256];
	SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "SELECT * FROM SQLiteBans_players");
	
	new Handle:DP = CreateDataPack();
	
	WritePackCell(DP, GetEntityUserId(client));
	WritePackCell(DP, GetCmdReplySource());
	
	SQL_TQuery(dbLocal, SQLCB_Backup, "SELECT * FROM SQLiteBans_players", DP);
}


public SQLCB_Backup(Handle:db, Handle:hndl, const String:sError[], Handle:DP)
{
	if(hndl == null)
		ThrowError(sError);
	
	else if(SQL_GetRowCount(hndl) == 0)
	{
		ResetPack(DP);
		
		new client = GetEntityOfUserId(ReadPackCell(DP));
		new ReplySource:CmdReplySource = ReadPackCell(DP);
		
		CloseHandle(DP);
		
		ReplyToCommandBySource(client, CmdReplySource, "There are no bans or comm punishments to backup.");
		
		return;
	}
	
	while(SQL_FetchRow(hndl))
	{
		for(new i=0;i < SQL_GetFieldCount(hndl);i++)
		{
			new Type = 0; // 0 = Int, 1 = Float, 2 = String.
		}
	}
}
*/
stock void KickBannedClient(int client, int BanDuration, const char[] AdminName, const char[] BanReason, int TimestampGiven)
{
	char KickReason[256];
	if(BanReason[0] == EOS)
		KickReason = "No reason specified";
		
	else
		FormatEx(KickReason, sizeof(KickReason), BanReason);
		
	char Website[128];
	GetConVarString(hcv_Website, Website, sizeof(Website));
	
	if(BanDuration == 0)
		KickClient(client, "You have been permanently banned from this server by admin\nReason: %s\nAdmin name: %s\n\nCheck %s for more info", KickReason, AdminName, Website);
		
	else
		KickClient(client, "You have been banned from this server for %i minutes.\nReason: %s\nAdmin name: %s\n\nCheck %s for more info.\nYour ban will expire in %i minutes", BanDuration, BanReason, AdminName, Website, RoundToFloor((float(BanDuration) - (float((GetTime() - TimestampGiven)) / 60.0)) - 0.1) + 1);
}

stock bool IsClientChatGagged(int client, int &Expire = 0, bool &permanent = false, bool &silenced = false)
{
	silenced = false;
	permanent = false;
	Expire = 0;
	
	int UnixTime = GetTime();
	
	if(ExpirePenalty[client][Penalty_Silence] > UnixTime)
	{
		silenced = true;
		Expire = ExpirePenalty[client][Penalty_Silence];
		return true;
	}
	else if(ExpirePenalty[client][Penalty_Silence] == -1)
	{
		silenced = true;
		permanent = true;
		Expire = ExpirePenalty[client][Penalty_Silence];
		return true;
	}
	
	if(ExpirePenalty[client][Penalty_Gag] > UnixTime)
	{
		Expire = ExpirePenalty[client][Penalty_Gag];
		return true;
	}
	else if(ExpirePenalty[client][Penalty_Gag] == -1)
	{
		permanent = true;
		Expire = ExpirePenalty[client][Penalty_Gag];
		return true;
	}
	
	return false;
}
stock bool IsClientVoiceMuted(int client, int &Expire = 0, bool &permanent = false, bool &silenced = false)
{
	silenced = false;
	permanent = false;
	Expire = 0;
	
	int UnixTime = GetTime();
	
	if(ExpirePenalty[client][Penalty_Silence] > UnixTime)
	{
		silenced = true;
		Expire = ExpirePenalty[client][Penalty_Silence];
		return true;
	}
	else if(ExpirePenalty[client][Penalty_Silence] == -1)
	{
		silenced = true;
		permanent = true;
		Expire = ExpirePenalty[client][Penalty_Silence];
		return true;
	}
	
	if(ExpirePenalty[client][Penalty_Mute] > UnixTime)
	{
		Expire = ExpirePenalty[client][Penalty_Mute];
		return true;
	}
	else if(ExpirePenalty[client][Penalty_Mute] == -1)
	{
		permanent = true;
		Expire = ExpirePenalty[client][Penalty_Mute];
		return true;
	}
	
	return false;
}

stock bool CanClientBanTarget(int client, int target)
{
	if(client == 0)
		return true;
		
	else if(CheckCommandAccess(client, "sm_rcon", ADMFLAG_RCON))
		return true;
	
	return CanUserTarget(client, target);
}

// Like GetClientUserId but client index 0 will return 0.
stock int GetEntityUserId(int entity)
{
	if(entity == 0)
		return 0;
		
	return GetClientUserId(entity);
}

stock int GetEntityOfUserId(int UserId)
{
	if(UserId == 0)
		return 0;
		
	return GetClientOfUserId(UserId);
}

stock void ReplyToCommandBySource(int client, ReplySource CmdReplySource, const char[] format, any ...)
{
	if(client == 0)
		CmdReplySource = SM_REPLY_TO_CONSOLE;
		
	char buffer[512];
	
	VFormat(buffer, sizeof(buffer), format, 4);
	
	ReplySource PrevReplySource = GetCmdReplySource();
	
	SetCmdReplySource(CmdReplySource);
	
	ReplyToCommand(client, buffer);
	
	SetCmdReplySource(PrevReplySource);
}

stock void LogSQLiteBans(const char[] format, any ...)
{
	char FilePath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, FilePath, sizeof(FilePath), "logs/SQLiteBans/BannedPlayers.log");

	char buffer[1024];
	VFormat(buffer, sizeof(buffer), format, 2);
	
	if(GetConVarBool(hcv_LogMethod))
		LogToFileEx(FilePath, buffer);
		
	else
		LogMessage(buffer);
}

stock void LogSQLiteBans_BannedConnect(const char[] format, any ...)
{
	char FilePath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, FilePath, sizeof(FilePath), "logs/SQLiteBans/RejectedConnections.log");

	char buffer[1024];
	VFormat(buffer, sizeof(buffer), format, 2);
	
	if(GetConVarBool(hcv_LogMethod))
		LogToFileEx(FilePath, buffer);
		
	else
		LogMessage(buffer);
}


stock void LogSQLiteBans_Comms(const char[] format, any ...)
{
	char FilePath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, FilePath, sizeof(FilePath), "logs/SQLiteBans/CommPlayers.log");

	char buffer[1024];
	VFormat(buffer, sizeof(buffer), format, 2);
	
	if(GetConVarBool(hcv_LogMethod))
		LogToFileEx(FilePath, buffer);
		
	else
		LogMessage(buffer);
}
stock int PositiveOrZero(int value)
{
	if(value < 0)
		return 0;
		
	return value;
}

#if defined _autoexecconfig_included

stock ConVar UC_CreateConVar(const char[] name, const char[] defaultValue, const char[] description = "", int flags = 0, bool hasMin = false, float min = 0.0, bool hasMax = false, float max = 0.0)
{
	return AutoExecConfig_CreateConVar(name, defaultValue, description, flags, hasMin, min, hasMax, max);
}

#else

stock ConVar UC_CreateConVar(const char[] name, const char[] defaultValue, const char[] description = "", int flags = 0, bool hasMin = false, float min = 0.0, bool hasMax = false, float max = 0.0)
{
	return CreateConVar(name, defaultValue, description, flags, hasMin, min, hasMax, max);
}
 
#endif

stock void PenaltyAliasByType(enPenaltyType PenaltyType, char PenaltyAlias[32], bool bPast = true)
{
	if(bPast)
	{
		switch(PenaltyType)
		{
			case Penalty_Gag: PenaltyAlias = "gagged";
			case Penalty_Mute: PenaltyAlias = "muted";
			case Penalty_Silence: PenaltyAlias = "silenced";
		}
	}
	else
	{
		switch(PenaltyType)
		{
			case Penalty_Gag: PenaltyAlias = "gag";
			case Penalty_Mute: PenaltyAlias = "mute";
			case Penalty_Silence: PenaltyAlias = "silence";
		}
	}
}