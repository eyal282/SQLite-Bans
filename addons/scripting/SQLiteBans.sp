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
#pragma semicolon 1

#define PLUGIN_VERSION "3.4"


public Plugin myinfo = 
{
	name = "SQLite Bans",
	author = "Eyal282",
	description = "Banning system that works on SQLite",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?t=315623"
}

#define FPERM_ULTIMATE (FPERM_U_READ|FPERM_U_WRITE|FPERM_U_EXEC|FPERM_G_READ|FPERM_G_WRITE|FPERM_G_EXEC|FPERM_O_READ|FPERM_O_WRITE|FPERM_O_EXEC)

enum struct enTargets
{
	char Name[64];
	char AuthId[35];
	char IPAddress[32];
	char AdminName[64];
	char AdminAuthId[35];
	char ExpirationDate[64];
	char BanReason[256];
	enPenaltyType PenaltyType;
	
	int LastPos; // Unrelated to the target.
	
	void init(char Name[64], char AuthId[35], char IPAddress[32], char AdminName[64],
	char AdminAuthId[35], char ExpirationDate[64], char BanReason[256], enPenaltyType PenaltyType = Penalty_Ban)
	{
		this.Name = Name;
		this.AuthId = AuthId;
		this.IPAddress = IPAddress;
		
		this.AdminName = AdminName;
		this.AdminAuthId = AdminAuthId;
		
		this.ExpirationDate = ExpirationDate;
		this.BanReason = BanReason;
		
		this.PenaltyType = PenaltyType;
		
		this.LastPos = 0;

	}
}

char Colors[][] = 
{
	"{NORMAL}", "{RED}", "{GREEN}", "{LIGHTGREEN}", "{OLIVE}", "{LIGHTRED}", "{GRAY}", "{YELLOW}", "{ORANGE}", "{BLUE}", "{PINK}"
};

char ColorEquivalents[][] =
{
	"\x01", "\x02", "\x03", "\x04", "\x05", "\x06", "\x07", "\x08", "\x09", "\x10", "\x0C", "\x0E"
};

Handle dbLocal = INVALID_HANDLE;

Handle hcv_Tag = INVALID_HANDLE;
Handle hcv_Website = INVALID_HANDLE;
Handle hcv_LogMethod = INVALID_HANDLE;
Handle hcv_LogBannedConnects = INVALID_HANDLE;
Handle hcv_DefaultGagTime = INVALID_HANDLE;
Handle hcv_DefaultMuteTime = INVALID_HANDLE;
Handle hcv_Deadtalk = INVALID_HANDLE;
Handle hcv_Alltalk = INVALID_HANDLE;

Handle fw_OnBanIdentity = INVALID_HANDLE;
Handle fw_OnBanIdentity_Post = INVALID_HANDLE;
Handle fw_OnCommPunishIdentity_Post = INVALID_HANDLE;

Handle fw_OnUnbanIdentity_Post = INVALID_HANDLE;
Handle fw_OnCommUnpunishIdentity_Post = INVALID_HANDLE;

float ExpireBreach = 0.0;

// Unix, setting to -1 makes it permanent.
int ExpirePenalty[MAXPLAYERS+1][enPenaltyType_LENGTH];

bool WasMutedLastCheck[MAXPLAYERS+1], WasGaggedLastCheck[MAXPLAYERS+1];

bool IsHooked = false;

TopMenu hTopMenu;

bool g_ownReasons[MAXPLAYERS + 1];

Menu ReasonMenuHandle;
Menu TimeMenuHandle;

int g_BanTarget[MAXPLAYERS+1], g_BanTime[MAXPLAYERS+1];

DataPack PlayerDataPack[MAXPLAYERS+1];

char g_BanReasonsPath[PLATFORM_MAX_PATH];

KeyValues g_hKvBanReasons;

char PREFIX[64];

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
		
	return SQLiteBans_CommPunishIdentity(AuthId, PenaltyType, name, time, reason, source, dontExtend);
}


public any Native_CommPunishIdentity(Handle plugin, int numParams)
{
	char AuthId[35];
	GetNativeString(1, AuthId, sizeof(AuthId));
	
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
		SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "INSERT OR REPLACE INTO SQLiteBans_players (AuthId, PlayerName, AdminAuthID, AdminName, Penalty, PenaltyReason, TimestampGiven, DurationMinutes) VALUES ('%s', '%s', '%s', '%s', %i, '%s', %i, %i)", AuthId, name, AdminAuthId, AdminName, PenaltyType, reason, UnixTime, time);
		SQL_TQuery(dbLocal, SQLCB_Error, sQuery, 1);
	}
	else
	{
		if(!dontExtend)
		{
			SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "UPDATE OR IGNORE SQLiteBans_players SET DurationMinutes = DurationMinutes + %i WHERE AuthId = '%s' AND Penalty = %i AND DurationMinutes != '0'", time, AuthId, PenaltyType);
			SQL_TQuery(dbLocal, SQLCB_Error, sQuery, 2);
		}
		SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "INSERT OR IGNORE INTO SQLiteBans_players (AuthId, PlayerName, AdminAuthID, AdminName, Penalty, PenaltyReason, TimestampGiven, DurationMinutes) VALUES ('%s', '%s', '%s', '%s', %i, '%s', %i, %i)", AuthId, name, AdminAuthId, AdminName, PenaltyType, reason, UnixTime, time);	
		SQL_TQuery(dbLocal, SQLCB_Error, sQuery, 3);
	}
	
	
	char PenaltyAlias[32];
	
	PenaltyAliasByType(PenaltyType, PenaltyAlias, false);
	
	if(time == 0)
		LogSQLiteBans("Admin %N [AuthId: %s] added a permanent %s on %s [AuthId: %s]. Reason: %s", source, AdminAuthId, PenaltyAlias, name, AuthId, reason);

	else
		LogSQLiteBans("Admin %N [AuthId: %s] added a %i minute %s on %s [AuthId: %s]. Reason: %s", source, AdminAuthId, time, PenaltyAlias, name, AuthId, reason);
	
	
	Call_StartForward(fw_OnCommPunishIdentity_Post);

	Call_PushCell(PenaltyType);
	
	Call_PushString(AuthId);
	Call_PushString(name);
	
	Call_PushString(AdminAuthId);
	Call_PushString(AdminName);

	Call_PushString(reason);
	
	Call_PushCell(time);
	
	Call_Finish();
	
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
	
	PenaltyAliasByType(PenaltyType, PenaltyAlias, sizeof(PenaltyAlias));
		
	SQLiteBans_CommUnpunishIdentity(AuthId, PenaltyType, source);
	
	return Plugin_Handled;
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
	
	char AdminAuthId[35], AdminName[64];
	
	int source = GetNativeCell(3);
	
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
	int UserId = (source == 0 ? 0 : GetClientUserId(source));
	
	Handle DP = CreateDataPack();
	
	WritePackCell(DP, UserId);
	WritePackCell(DP, GetCmdReplySource());
	WritePackString(DP, identity);
	
	WritePackCell(DP, PenaltyType);
	
	WritePackString(DP, AdminAuthId);
	
	char sQuery[1024];
	SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "SELECT * FROM SQLiteBans_players WHERE Penalty = %i AND AuthId = '%s'", PenaltyType, identity);
	SQL_TQuery(dbLocal, SQLCB_Unpenalty_FindPenalties, sQuery, DP);
	
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
	/*
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
	*/
	return false;
}

public any BaseCommNative_SetClientMute(Handle plugin, int numParams)
{
	/*
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
	*/
	return false;
}


public void SQLCB_Unpenalty_FindPenalties(Handle db, Handle hndl, const char[] sError, Handle DP)
{
	if(hndl == null)
	{
		CloseHandle(DP);
		ThrowError(sError);
    }
	
	else if(SQL_GetRowCount(hndl) == 0)
	{
		ResetPack(DP);

		int UserId = ReadPackCell(DP);
	
		ReplySource CmdReplySource = ReadPackCell(DP);
		
		char TargetArg[64];
		
		ReadPackString(DP, TargetArg, sizeof(TargetArg));
		
		enPenaltyType PenaltyType = ReadPackCell(DP);
		
		CloseHandle(DP);
		
		char PenaltyAlias[32];
		PenaltyAliasByType(PenaltyType, PenaltyAlias, sizeof(PenaltyAlias), false);
		
		int client = GetEntityOfUserId(UserId);
		
		ReplyToCommandBySource(client, CmdReplySource, "%s%t", PREFIX, "Unpenalty Not Found", PenaltyAlias, TargetArg);
	}
	
	SQL_FetchRow(hndl);

	char AuthId[35], name[64];
	
	SQL_FetchString(hndl, 0, AuthId, sizeof(AuthId));
	SQL_FetchString(hndl, 2, name, sizeof(name));
	ResetPack(DP);
	
	int UserId = ReadPackCell(DP);
	
	ReplySource CmdReplySource = ReadPackCell(DP);
	
	char TargetArg[64];
	
	ReadPackString(DP, TargetArg, sizeof(TargetArg));
	
	enPenaltyType PenaltyType = ReadPackCell(DP);
	
	char AdminAuthId[35];
	ReadPackString(DP, AdminAuthId, sizeof(AdminAuthId)); // Even if the player disconnects we must log him.
	
	CloseHandle(DP);
	
	int client = GetEntityOfUserId(UserId);
	
	char PenaltyAlias[32];
	PenaltyAliasByType(PenaltyType, PenaltyAlias, sizeof(PenaltyAlias), false);
	
	ReplyToCommandBySource(client, CmdReplySource, "%s%t", PREFIX, "Unpenalty Success", PenaltyAlias, TargetArg);
	
	LogSQLiteBans("Admin %N [AuthId: %s] deleted all %s penalties matching \"%s\"", client, AdminAuthId, PenaltyAlias, TargetArg);
	
	char AdminName[64];
	
	if(client == 0)
		AdminName = "CONSOLE";
		
	else
		GetClientName(client, AdminName, sizeof(AdminName));
		
	char sQuery[1024];
	SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "DELETE FROM SQLiteBans_players WHERE Penalty = %i AND (AuthId = '%s' OR IPAddress = '%s')", PenaltyType, TargetArg, TargetArg);
	SQL_TQuery(dbLocal, SQLCB_Error, sQuery, 50);
	
	Call_StartForward(fw_OnCommUnpunishIdentity_Post);
	
	Call_PushCell(PenaltyType);
	Call_PushString(AuthId);
	Call_PushString(name);
	Call_PushString(AdminAuthId);
	Call_PushString(AdminName);
	
	Call_Finish();
}

public void OnPluginStart()
{	
	LoadTranslations("sqlitebans.phrases");
	LoadTranslations("common.phrases");
	LoadTranslations("basebans.phrases");
	LoadTranslations("core.phrases");
	
	
	BuildPath(Path_SM, g_BanReasonsPath, sizeof(g_BanReasonsPath), "configs/banreasons.txt");
	
	if ((TimeMenuHandle = CreateMenu(MenuHandler_BanTimeList, MenuAction_Select|MenuAction_Cancel|MenuAction_DrawItem)) != INVALID_HANDLE)
	{
		TimeMenuHandle.Pagination = 8;
		TimeMenuHandle.ExitBackButton = true;
		
		TimeMenuHandle.AddItem("0", "Permanent");
		TimeMenuHandle.AddItem("10", "10 Minutes");
		TimeMenuHandle.AddItem("30", "30 Minutes");
		TimeMenuHandle.AddItem("60", "1 Hour");
		TimeMenuHandle.AddItem("240", "4 Hours");
		TimeMenuHandle.AddItem("1440", "1 Day");
		TimeMenuHandle.AddItem("10080", "1 Week");
	}

	if ((ReasonMenuHandle = new Menu(ReasonSelected)) != INVALID_HANDLE)
	{
		ReasonMenuHandle.Pagination = 8;
		ReasonMenuHandle.ExitBackButton = true;
		
		ReasonMenuHandle.AddItem("Own Reason", "Custom Reason");
	}

	LoadBanReasons();
	
	RegAdminCmd("sm_ban", Command_Ban, ADMFLAG_BAN, "sm_ban <#userid|name> <minutes|0> [reason]");
	RegAdminCmd("sm_banip", Command_BanIP, ADMFLAG_BAN, "sm_banip <#userid|name> <minutes|0> [reason]");
	RegAdminCmd("sm_fban", Command_FullBan, ADMFLAG_BAN, "sm_fban <#userid|name> <minutes|0> [reason]");
	RegAdminCmd("sm_fullban", Command_FullBan, ADMFLAG_BAN, "sm_fban <#userid|name> <minutes|0> [reason]");
	RegAdminCmd("sm_addban", Command_AddBan, ADMFLAG_BAN, "sm_addban <steamid|ip> <minutes|0> [reason]");
	RegAdminCmd("sm_unban", Command_Unban, ADMFLAG_UNBAN, "sm_unban <steamid|ip>");
	
	fw_OnBanIdentity = CreateGlobalForward("SQLiteBans_OnBanIdentity", ET_Ignore, Param_Cell, Param_String, Param_String, Param_String, Param_String);
	fw_OnBanIdentity_Post = CreateGlobalForward("SQLiteBans_OnBanIdentity_Post", ET_Ignore, Param_String, Param_String, Param_String, Param_String, Param_String, Param_Cell);
	fw_OnCommPunishIdentity_Post = CreateGlobalForward("SQLiteBans_OnCommPunishIdentity_Post", ET_Ignore, Param_Cell, Param_String, Param_String, Param_String, Param_String, Param_String, Param_Cell);
	
	fw_OnUnbanIdentity_Post = CreateGlobalForward("SQLiteBans_OnUnbanIdentity_Post", ET_Ignore, Param_String, Param_String, Param_String, Param_String);
	fw_OnCommUnpunishIdentity_Post = CreateGlobalForward("SQLiteBans_OnCommUnpunishIdentity_Post", ET_Ignore, Param_Cell, Param_String, Param_String, Param_String, Param_String);

	
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
	
	RegConsoleCmd("sm_abortban", Command_AbortBan, "sm_abortban");
	//RegAdminCmd("sm_sqlitebans_backup", Command_Backup, ADMFLAG_ROOT, "Backs up the bans database to an external file");
	
	//RegConsoleCmd("sm_commstatus", Command_CommStatus, "Gives you information about communication penalties active on you");
	//RegConsoleCmd("sm_comms", Command_CommStatus, "Gives you information about communication penalties active on you");
	
	#if defined _autoexecconfig_included
	
	AutoExecConfig_SetFile("SQLiteBans");
	
	#endif

	#if defined _autoexecconfig_included
	
	AutoExecConfig_ExecuteFile();

	AutoExecConfig_CleanFile();
	
	#endif
		
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


public void OnConfigsExecuted()
{
	//(Re-)Load BanReasons
	LoadBanReasons();
}


public void OnAllPluginsLoaded()
{
	hcv_Tag = UC_CreateConVar("sqlite_bans_tag", "[{RED}SQLiteBans{NORMAL}] {NORMAL}", _, FCVAR_PROTECTED);
	hcv_Website = UC_CreateConVar("sqlite_bans_url", "http://yourwebsite.com", "Url to direct banned players to go to if they wish to appeal their ban", FCVAR_PROTECTED);
	hcv_LogMethod = UC_CreateConVar("sqlite_bans_log_method", "1", "0 - Log in the painful to look at \"L20190412.log\" files. 1 - Log in a seperate file, in sourcemod/logs/SQLiteBans.log", FCVAR_PROTECTED);
	hcv_LogBannedConnects = UC_CreateConVar("sqlite_bans_log_banned_connects", "0", "0 - Don't. 1 - Log whenever a banned player attempts to join the server", FCVAR_PROTECTED);
	hcv_DefaultGagTime = UC_CreateConVar("sqlite_bans_default_gag_time", "7", "If a plugin uses a basecomm native to gag a player, this is how long the gag will last", FCVAR_PROTECTED);
	hcv_DefaultMuteTime = UC_CreateConVar("sqlite_bans_default_mute_time", "7", "If a plugin uses a basecomm native to mute a player, this is how long the mute will last", FCVAR_PROTECTED);
	
	hcv_Deadtalk = UC_CreateConVar("sm_deadtalk", "0", "Controls how dead communicate. 0 - Off. 1 - Dead players ignore teams. 2 - Dead players talk to living teammates.", 0, true, 0.0, true, 2.0);

	hcv_Alltalk = FindConVar("sv_alltalk");
	
	GetConVarString(hcv_Tag, PREFIX, sizeof(PREFIX));
	HookConVarChange(hcv_Tag, hcvChange_Tag);
	
	HookConVarChange(hcv_Deadtalk, hcvChange_Deadtalk);
	HookConVarChange(hcv_Alltalk, hcvChange_Alltalk);
	
	char Value[64];
	GetConVarString(hcv_Deadtalk, Value, sizeof(Value));
	
	hcvChange_Deadtalk(hcv_Deadtalk, Value, Value);
	
	GetConVarString(hcv_Alltalk, Value, sizeof(Value));
	
	hcvChange_Alltalk(hcv_Alltalk, Value, Value);
	TopMenu topmenu;

	if (LibraryExists("adminmenu") && ((topmenu = GetAdminTopMenu()) != INVALID_HANDLE))
	{
		OnAdminMenuReady(topmenu);
	}
}


public void hcvChange_Tag(Handle convar, const char[] oldValue, const char[] newValue)
{
	FormatEx(PREFIX, sizeof(PREFIX), newValue);
}

void LoadBanReasons()
{
	delete g_hKvBanReasons;

	g_hKvBanReasons = new KeyValues("banreasons");

	if (g_hKvBanReasons.ImportFromFile(g_BanReasonsPath))
	{
		char sectionName[255];
		if (!g_hKvBanReasons.GetSectionName(sectionName, sizeof(sectionName)))
		{
			SetFailState("Error in %s: File corrupt or in the wrong format", g_BanReasonsPath);
			return;
		}

		if (strcmp(sectionName, "banreasons") != 0)
		{
			SetFailState("Error in %s: Couldn't find 'banreasons'", g_BanReasonsPath);
			return;
		}
		
		//Reset kvHandle
		g_hKvBanReasons.Rewind();
		
		g_hKvBanReasons.GotoFirstSubKey(false);
		
		char reasonName[100];
		char reasonFull[256];
		
		do
		{
			g_hKvBanReasons.GetSectionName(reasonName, sizeof(reasonName));
			g_hKvBanReasons.GetString(NULL_STRING, reasonFull, sizeof(reasonFull));
			
			//Add entry
			ReasonMenuHandle.AddItem(reasonFull, reasonName);
			
		} while (g_hKvBanReasons.GotoNextKey(false));
		
	} else {
		SetFailState("Error in %s: File not found, corrupt or in the wrong format", g_BanReasonsPath);
		return;
	}
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
			UC_PrintToChat(i, "%s%t", PREFIX, "Silence Expired");
			
		else if(WasGagged)
			UC_PrintToChat(i, "%s%t", PREFIX, "Gag Expired");
			
		else if(WasMuted)
			UC_PrintToChat(i, "%s%t", PREFIX, "Mute Expired");
			
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

public void OnClientSayCommand_Post(int client, const char[] command, const char[] sArgs)
{
	if(g_ownReasons[client])
	{
		g_ownReasons[client] = false;
		BanClient(g_BanTarget[client], g_BanTime[client], BANFLAG_AUTO|BANFLAG_NOKICK, sArgs, "KICK!!!", "sm_ban", client);
	}
}
public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
	int Expire;
	bool permanent;
	
	// Do the banning in the post, to allow sm_abortban to have time.
	if(g_ownReasons[client])
		return Plugin_Handled;
	
	if(IsClientChatGagged(client, Expire, permanent))
	{
		if(permanent)
			UC_PrintToChat(client, "%s%t", PREFIX, "Gag Indicator - Permanent");
		
		else
			UC_PrintToChat(client, "%s%t", PREFIX, "Gag Indicator - Permanent", RoundToFloor((float((Expire - GetTime())) / 60.0) - 0.1) + 1);
			
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
		UC_ReplyToCommand(source, "%s%t", PREFIX, "Target Already Banned", Name);
		
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
		
	g_ownReasons[client] = false;
}

public void OnClientConnected(int client)
{
	WasGaggedLastCheck[client] = false;
	WasMutedLastCheck[client] = false;
	
	g_ownReasons[client] = false;
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
	
	char AuthId[35];
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
						LogSQLiteBans_BannedConnect("Kicked banned client %N ([AuthId: %s],[IP: %s]), ban will never expire", client, AuthId, IPAddress);
						
					else
						LogSQLiteBans_BannedConnect("Kicked banned client %N ([AuthId: %s],[IP: %s]), ban expires in %i minutes", client, AuthId, IPAddress, ((TimestampGiven + (DurationMinutes * 60)) - UnixTime) / 60);
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


public Action Command_AbortBan(int client, int args)
{
	if(!CheckCommandAccess(client, "sm_ban", ADMFLAG_BAN))
	{
		UC_ReplyToCommand(client, "%s%t", PREFIX, "No Access");
		return Plugin_Handled;
	}
	
	if(g_ownReasons[client])
	{
		g_ownReasons[client] = false;
		UC_ReplyToCommand(client, "%s%t", PREFIX, "AbortBan applied successfully");
	}
	else
	{
		UC_ReplyToCommand(client, "%s%t", PREFIX, "AbortBan not waiting for custom reason");
	}
	
	return Plugin_Handled;
}

public Action Command_Ban(int client, int args)
{
	if(ExpireBreach != 0.0)
	{	
		UC_ReplyToCommand(client, "%s%t", PREFIX, "Cannot Ban - Ban Breach");
		return Plugin_Handled;
	}	
	else if(args == 0)
	{
		UC_ReplyToCommand(client, "%s%t", PREFIX, "Ban Menu - Full Ban Note");
		
		DisplayBanTargetMenu(client);
		
		return Plugin_Handled;
	}
	else if(args < 2)
	{
		char arg0[65];
		GetCmdArg(0, arg0, sizeof(arg0));
		
		UC_ReplyToCommand(client, "%s%t", PREFIX, "Command Usage Ban", arg0);
		
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
		UC_ShowActivity2(client, PREFIX, "permanently banned %N for the reason \"%s\"", TargetClient, BanReason);

	else
		UC_ShowActivity2(client, PREFIX, "banned %N for %i minutes for the reason \"%s\"", TargetClient, Duration, BanReason);
		
	return Plugin_Handled;
}

public Action Command_BanIP(int client, int args)
{
	if(ExpireBreach != 0.0)
	{	
		UC_ReplyToCommand(client, "%s%t", PREFIX, "Cannot Ban - Ban Breach");
		return Plugin_Handled;
	}	
	else if(args == 0)
	{
		UC_ReplyToCommand(client, "%s%t", PREFIX, "Ban Menu - Full Ban Note");
		
		DisplayBanTargetMenu(client);
		
		return Plugin_Handled;
	}
	else if(args < 2)
	{
		char arg0[65];
		GetCmdArg(0, arg0, sizeof(arg0));
		
		UC_ReplyToCommand(client, "%s%t", PREFIX, "Command Usage Ban", arg0);
		
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
		UC_ShowActivity2(client, PREFIX, "permanently banned %N for the reason \"%s\"", TargetClient, BanReason);

	else
		UC_ShowActivity2(client, PREFIX, "banned %N for %i minutes for the reason \"%s\"", TargetClient, Duration, BanReason);

	
	return Plugin_Handled;
}

public Action Command_FullBan(int client, int args)
{
	if(ExpireBreach != 0.0)
	{	
		UC_ReplyToCommand(client, "%s%t", PREFIX, "Cannot Ban - Ban Breach");
		return Plugin_Handled;
	}
	else if(args == 0)
	{	
		DisplayBanTargetMenu(client);
		
		return Plugin_Handled;
	}
	else if(args < 2)
	{
		char arg0[65];
		GetCmdArg(0, arg0, sizeof(arg0));
		
		UC_ReplyToCommand(client, "%s%t", PREFIX, "Command Usage Ban", arg0);
		
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
		UC_ShowActivity2(client, PREFIX, "permanently banned %N", TargetClient);
		
	else
		UC_ShowActivity2(client, PREFIX, "banned %N for %i minutes", TargetClient, Duration);
		
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
		UC_ReplyToCommand(client, "%s%t", PREFIX, "Cannot Ban - Ban Breach");
		return Plugin_Handled;
	}	
	if(args < 2)
	{
		char arg0[65];
		GetCmdArg(0, arg0, sizeof(arg0));
		
		UC_ReplyToCommand(client, "%s%t", PREFIX, "Command Usage Add Ban", arg0);
		
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
		flags |= BANFLAG_AUTHID;
		
	else
		flags |= BANFLAG_IP;
		
	int Duration = StringToInt(BanDuration);
	// This is the function to ban an identity with source being the banning client or 0 for console. If you want my plugin to use its own kicking mechanism, add BANFLAG_NOKICK and set the kick reason to anything apart from ""
	BanIdentity(TargetArg, Duration, flags, BanReason, "sm_addban", client); 
	
	char AdminAuthId[35];
	
	if(client == 0)
		AdminAuthId = "CONSOLE";
		
	else
		GetClientAuthId(client, AuthId_Steam2, AdminAuthId, sizeof(AdminAuthId));

	if(Duration == 0)
		UC_ShowActivity2(client, PREFIX, "added a permanent ban on identity %s. Reason: %s", TargetArg, BanReason);

	else
		UC_ShowActivity2(client, PREFIX, "added a %i minute ban on identity: %s", Duration, BanReason);

	return Plugin_Handled;
}

public Action Command_Unban(int client, int args)
{
	if(args == 0)
	{
		char arg0[65];
		GetCmdArg(0, arg0, sizeof(arg0));
		
		UC_ReplyToCommand(client, "%s%t", PREFIX, "Command Usage Unban", arg0);
		
		return Plugin_Handled;
	}	
	
	char TargetArg[64];
	GetCmdArgString(TargetArg, sizeof(TargetArg));
	StripQuotes(TargetArg);
	ReplaceString(TargetArg, sizeof(TargetArg), " ", ""); // Some bug when using rcon...
	
	if(TargetArg[0] == EOS)
	{
		char arg0[65];
		GetCmdArg(0, arg0, sizeof(arg0));
		
		UC_ReplyToCommand(client, "%s%t", PREFIX, "Command Usage Unban", arg0);
		
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
	SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "SELECT * FROM SQLiteBans_players WHERE Penalty = %i AND (AuthId = '%s' OR IPAddress = '%s')", Penalty_Ban, TargetArg, TargetArg);
	SQL_TQuery(dbLocal, SQLCB_Unban_FindBans, sQuery, DP);
	
	return Plugin_Handled;
}

public void SQLCB_Unban_FindBans(Handle db, Handle hndl, const char[] sError, Handle DP)
{
	if(hndl == null)
	{
		CloseHandle(DP);
		ThrowError(sError);
    }
	
	else if(SQL_GetRowCount(hndl) == 0)
	{
		ResetPack(DP);
	
		int UserId = ReadPackCell(DP);
	
		ReplySource CmdReplySource = ReadPackCell(DP);
		
		char TargetArg[64];
		
		ReadPackString(DP, TargetArg, sizeof(TargetArg));
		
		CloseHandle(DP);
		int client = GetEntityOfUserId(UserId);
		
		ReplyToCommandBySource(client, CmdReplySource, "%s%t", PREFIX, "No bans found", TargetArg);
	}
	
	SQL_FetchRow(hndl);

	char AuthId[35], name[64];
	
	SQL_FetchString(hndl, 0, AuthId, sizeof(AuthId));
	SQL_FetchString(hndl, 2, name, sizeof(name));
	ResetPack(DP);
	
	int UserId = ReadPackCell(DP);
	
	ReplySource CmdReplySource = ReadPackCell(DP);
	
	char TargetArg[64];
	
	ReadPackString(DP, TargetArg, sizeof(TargetArg));
	char AdminAuthId[35];
	ReadPackString(DP, AdminAuthId, sizeof(AdminAuthId)); // Even if the player disconnects we must log him.
	
	CloseHandle(DP);
	
	int client = GetEntityOfUserId(UserId);
	
	ReplyToCommandBySource(client, CmdReplySource, "%s%t", PREFIX, "Ban Deleted", TargetArg);
	
	LogSQLiteBans("Admin %N [AuthId: %s] deleted all bans matching \"%s\"", client, AdminAuthId, TargetArg);
	
	char AdminName[64];
	
	if(client == 0)
		AdminName = "CONSOLE";
		
	else
		GetClientName(client, AdminName, sizeof(AdminName));
		
	char sQuery[1024];
	SQL_FormatQuery(dbLocal, sQuery, sizeof(sQuery), "DELETE FROM SQLiteBans_players WHERE Penalty = %i AND (AuthId = '%s' OR IPAddress = '%s')", Penalty_Ban, TargetArg, TargetArg);
	SQL_TQuery(dbLocal, SQLCB_Error, sQuery, 50);
	
	Call_StartForward(fw_OnUnbanIdentity_Post);
	
	Call_PushString(AuthId);
	Call_PushString(name);
	Call_PushString(AdminAuthId);
	Call_PushString(AdminName);
	
	Call_Finish();
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
		UC_ReplyToCommand(client, "%s%t", PREFIX, "Command Usage Ban", command);
		
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
		
		UC_ReplyToCommand(client, "%s%t", PREFIX, "Cannot Extend Permanent Penalty", PenaltyAlias);
		return Plugin_Stop;
	}
	
	if(!IsClientAuthorized(TargetClient))
	{
		UC_ReplyToCommand(client, "%s%t", PREFIX, "Cannot Authenticate Error", TargetClient);
		return Plugin_Stop;
	}
	
	if(!SQLiteBans_CommPunishClient(TargetClient, PenaltyType, Duration, PenaltyReason, client, false))
		return Plugin_Stop;

	if(!Extended || Duration == 0)
	{
		if(Duration == 0)
		{
			
			UC_PrintToChat(TargetClient, "%s%t", PREFIX, "You Are Permanently Penalized", PenaltyAlias, client);
			UC_ShowActivity2(client, PREFIX, "permanently %s %N | Reason: %s", PenaltyAlias, TargetClient, PenaltyReason);
		}
		else
		{
			UC_PrintToChat(TargetClient, "%s%t", PREFIX, "You Are Temporarily Penalized", PenaltyAlias, client, Duration);
			UC_ShowActivity2(client, PREFIX, "%s %N for %i minutes | Reason: %s", PenaltyAlias, TargetClient, Duration, PenaltyReason);
		}
	}
	else
	{
		UC_PrintToChat(TargetClient, "%s%t", "You Are Extended Penalized", PREFIX, PenaltyAlias, client, Duration, PositiveOrZero(((ExpirePenalty[TargetClient][PenaltyType] - GetTime()) / 60)));
		UC_ShowActivity2(client, PREFIX, "%s %N for %i more minutes ( total: %i ) | Reason: %s", PenaltyAlias, TargetClient, Duration, PositiveOrZero((ExpirePenalty[TargetClient][PenaltyType] - GetTime()) / 60), PenaltyReason);
	}	
	
	UC_PrintToChat(TargetClient, "%s%t", PREFIX, "Reason New Line", PenaltyReason);
	
	return Plugin_Stop;
}


public Action Listener_Unpenalty(int client, const char[] command, int args)
{
	if(client && !CheckCommandAccess(client, command, ADMFLAG_CHAT))
		return Plugin_Continue;
		
	if(args == 0)
	{
		char arg0[65];
		GetCmdArg(0, arg0, sizeof(arg0));
		
		UC_ReplyToCommand(client, "%s%t", PREFIX, "Command Usage Unban", arg0);

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
		
		UC_PrintToChat(TargetClient, "%s%t", PREFIX, "You Are Unpenalized", PenaltyAlias, client);
		
		SQLiteBans_CommUnpunishClient(TargetClient, PenaltyType, client);
	}

	UC_ShowActivity2(client, PREFIX, "%s %s", PenaltyAlias, target_name);
		
	return Plugin_Stop;
}


public Action Command_OfflinePenalty(int client, int args)
{
	char command[32];
	GetCmdArg(0, command, sizeof(command));
	
	if(args < 2)
	{
		char arg0[65];
		GetCmdArg(0, arg0, sizeof(arg0));
		
		UC_ReplyToCommand(client, "%s%t", PREFIX, "Command Usage Offline Penalty", command);
		
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
			
			UC_ReplyToCommand(client, "%s%t", PREFIX, "Temporary Offline Penalty Success", PenaltyAlias, TargetArg, Duration);
			UC_ReplyToCommand(client, "%s%t", PREFIX, "Temporary Offline Penalty Note", PenaltyAlias);
		}	
		else
			UC_ReplyToCommand(client, "%s%t", PREFIX, "Permanently Offline Penalty Success", PenaltyAlias, TargetArg);
			
	}
	
	return Plugin_Handled;
}


public Action Command_OfflineUnpenalty(int client, int args)
{
	char command[32];
	GetCmdArg(0, command, sizeof(command));
	if(args == 0)
	{
		char arg0[65];
		GetCmdArg(0, arg0, sizeof(arg0));
		
		UC_ReplyToCommand(client, "%s%t", PREFIX, "Command Usage Offline Unpenalty", command);
		
		return Plugin_Handled;
	}	
	
	char TargetArg[64];
	GetCmdArgString(TargetArg, sizeof(TargetArg));
	StripQuotes(TargetArg);
	
	if(TargetArg[0] == EOS)
	{
		char arg0[65];
		GetCmdArg(0, arg0, sizeof(arg0));
		
		UC_ReplyToCommand(client, "%s%t", PREFIX, "Command Usage Offline Unpenalty", command);
		
		return Plugin_Handled;
	}
	
	enPenaltyType PenaltyType;
	
	if(StrEqual(command, "sm_oungag"))
		PenaltyType = Penalty_Gag;

	else if(StrEqual(command, "sm_ounmute"))
		PenaltyType = Penalty_Mute;
		
	else if(StrEqual(command, "sm_ounsilence"))
		PenaltyType = Penalty_Silence;
	
	SQLiteBans_CommUnpunishIdentity(TargetArg, PenaltyType, client);
	
	return Plugin_Handled;
}
/*
public Action Command_CommStatus(int client, int args)
{
	char ExpirationDate[64];
	int Expire, UnixTime = GetTime();
	bool Gagged = IsClientChatGagged(client, Expire);
	FormatTime(ExpirationDate, sizeof(ExpirationDate), "%Y/%m/%d - %H:%M:%S", Expire);
	
	int MinutesLeft = (Expire - UnixTime) / 60;
	if(Expire <= 0) // If you aren't gagged, it won't expire lol.
	{
		FormatEx(ExpirationDate, sizeof(ExpirationDate), "Never");
		MinutesLeft = 0;
	}	
	
	UC_PrintToChat(client, "%sGagged: %s, Expiration: %s ( %i minutes )", PREFIX, Gagged ? "Yes" : "No", ExpirationDate, MinutesLeft);
	
	bool Muted = IsClientVoiceMuted(client, Expire);
	
	FormatTime(ExpirationDate, sizeof(ExpirationDate), "%Y/%m/%d - %H:%M:%S", Expire);
	
	MinutesLeft = (Expire - UnixTime) / 60;
	if(Expire <= 0) // If you aren't muted, it won't expire lol.
	{
		FormatEx(ExpirationDate, sizeof(ExpirationDate), "Never");
		MinutesLeft = 0;
	}	
	
	UC_PrintToChat(client, "%sMuted: %s, Expiration: %s ( %i minutes )", PREFIX, Muted ? "Yes" : "No", ExpirationDate, MinutesLeft);
	
	return Plugin_Handled;
}
*/
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
			UC_PrintToChat(client, "%s%t", PREFIX, "No Bans At All");
			UC_PrintToConsole(client, "%s%t", PREFIX, "No Bans At All");
		}
		
		char TempFormat[64], AuthId[35], IPAddress[32], PlayerName[64], AdminAuthId[35], AdminName[64], BanReason[256], ExpirationDate[64];
		
		Handle hMenu = CreateMenu(BanList_MenuHandler);
	
		Handle Array_Targets = CreateArray(sizeof(enTargets));
		
		enTargets target;
		
		while(SQL_FetchRow(hndl))
		{
			SQL_FetchString(hndl, 0, AuthId, sizeof(AuthId));
			SQL_FetchString(hndl, 1, IPAddress, sizeof(IPAddress));
			SQL_FetchString(hndl, 2, PlayerName, sizeof(PlayerName));
			SQL_FetchString(hndl, 3, AdminAuthId, sizeof(AdminAuthId));
			SQL_FetchString(hndl, 4, AdminName, sizeof(AdminName));
			SQL_FetchString(hndl, 6, BanReason, sizeof(BanReason));
			StripQuotes(BanReason);
			
			int BanExpiration = SQL_FetchInt(hndl, 8) - ((GetTime() - SQL_FetchInt(hndl, 7)) / 60);
			
			FormatTime(ExpirationDate, sizeof(ExpirationDate), "%Y/%m/%d - %H:%M:%S", GetTime() + (60 * BanExpiration));

			if(BanExpiration <= 0)
			{
				BanExpiration = 0;
				FormatEx(ExpirationDate, sizeof(ExpirationDate), "∞");
			}
			
			target.init(PlayerName, AuthId, IPAddress, AdminName, AdminAuthId, ExpirationDate, BanReason);
			
			// Any edit to PlayerName after target.init will not be reflected in the array.
			if(PlayerName[0] == EOS)
			{
				if(AuthId[0] != EOS)
					FormatEx(PlayerName, sizeof(PlayerName), AuthId);
					
				else if(IPAddress[0] != EOS)
					FormatEx(PlayerName, sizeof(PlayerName), IPAddress);
					
			}
			
			PushArrayArray(Array_Targets, target, sizeof(enTargets));
			
			IntToString(view_as<int>(Array_Targets), TempFormat, sizeof(TempFormat));
			AddMenuItem(hMenu, TempFormat, PlayerName);
		}
		
		SetMenuTitle(hMenu, "Bans sorted by date:");
		DisplayMenuAtItem(hMenu, client, ItemPos, MENU_TIME_FOREVER);
	
	}
}


public int BanList_MenuHandler(Handle hMenu, MenuAction action, int client, int item)
{
	if(action == MenuAction_End)
	{
		char Info[64];
		
		Handle Array_Targets;
		
		GetMenuItem(hMenu, 0, Info, sizeof(Info));
		
		Array_Targets = view_as<Handle>(StringToInt(Info));
		
		CloseHandle(Array_Targets);
		CloseHandle(hMenu);
	}
	else if(action == MenuAction_Select)
	{
		char Info[64];
		
		Handle Array_Targets;
		
		GetMenuItem(hMenu, item, Info, sizeof(Info));
		
		Array_Targets = view_as<Handle>(StringToInt(Info));
				
		enTargets target;
		
		GetArrayArray(Array_Targets, item, target);
		
		BanListMenu_ShowTargetInfo(client, target.AuthId, target.IPAddress, target.Name, target.AdminAuthId, target.AdminName, target.ExpirationDate, target.BanReason, GetMenuSelectionPosition());
	}
}

void BanListMenu_ShowTargetInfo(int client, char AuthId[35], char IPAddress[32], char Name[64], char AdminAuthId[35], char AdminName[64], char ExpirationDate[64], char BanReason[256], int LastPos)
{
		Handle hMenu = CreateMenu(BanListTargetInfo_MenuHandler);
		
		SetMenuTitle(hMenu, "Ban Info of %s\n AuthId: %s | IP: %s\n Admin Info [%s]:\n Admin AuthId: %s\n Expiration Date: %s", Name, AuthId, IPAddress, AdminName, AdminAuthId, ExpirationDate);
		
		Handle Array_Target = CreateArray(sizeof(enTargets));
		
		enTargets target;
		
		target.init(Name, AuthId, IPAddress, AdminName, AdminAuthId, ExpirationDate, BanReason);
		
		target.LastPos = LastPos;
		
		PushArrayArray(Array_Target, target);
		
		char TempFormat[64];
		
		IntToString(view_as<int>(Array_Target), TempFormat, sizeof(TempFormat));
		AddMenuItem(hMenu, TempFormat, "Unban Player");
		
		SetMenuExitBackButton(hMenu, true);
		
		DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
}


public int BanListTargetInfo_MenuHandler(Handle hMenu, MenuAction action, int client, int item)
{
	if(action == MenuAction_End)
	{
		char Info[64];
		
		Handle Array_Target;
		
		GetMenuItem(hMenu, 0, Info, sizeof(Info));
		
		Array_Target = view_as<Handle>(StringToInt(Info));
		
		CloseHandle(Array_Target);
		
		CloseHandle(hMenu);
	}
	else if(action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		Handle Array_Target;
		
		char Info[64];
		
		GetMenuItem(hMenu, 0, Info, sizeof(Info));
		
		Array_Target = view_as<Handle>(StringToInt(Info));
		
		enTargets target;
		
		GetArrayArray(Array_Target, 0, target, sizeof(enTargets));
		
		QueryBanList(client, target.LastPos);
	}
	else if(action == MenuAction_Select)
	{
		switch(item)
		{
			case 0:
			{
				Handle Array_Target;
				
				char Info[64];
				
				GetMenuItem(hMenu, 0, Info, sizeof(Info));
				
				Array_Target = view_as<Handle>(StringToInt(Info));
				
				enTargets target;
				
				GetArrayArray(Array_Target, 0, target, sizeof(enTargets));
				
				if(target.AuthId[0] != EOS)
					FakeClientCommand(client, "sm_unban %s", target.AuthId);
					
				else if(target.IPAddress[0] != EOS)
					FakeClientCommand(client, "sm_unban %s", target.IPAddress);
				
			}
		}
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
			UC_PrintToChat(client, "%s%t", PREFIX, "No Penalties At All");
			UC_PrintToConsole(client, "%s%t", PREFIX, "No Penalties At All");
		}
		char TempFormat[512], AuthId[35], PlayerName[64], AdminAuthId[35], AdminName[64], PenaltyReason[256], ExpirationDate[64];
		
		Handle hMenu = CreateMenu(CommList_MenuHandler);
	
		Handle Array_Targets = CreateArray(sizeof(enTargets));
		enTargets target;
		
		while(SQL_FetchRow(hndl))
		{
			SQL_FetchString(hndl, 0, AuthId, sizeof(AuthId));
			SQL_FetchString(hndl, 2, PlayerName, sizeof(PlayerName));
			SQL_FetchString(hndl, 3, AdminAuthId, sizeof(AdminAuthId));
			SQL_FetchString(hndl, 4, AdminName, sizeof(AdminName));
			
			if(PlayerName[0] == EOS)
				FormatEx(PlayerName, sizeof(PlayerName), AuthId);
			
			enPenaltyType Penalty = view_as<enPenaltyType>(SQL_FetchInt(hndl, 5));
			SQL_FetchString(hndl, 6, PenaltyReason, sizeof(PenaltyReason));
			
			StripQuotes(PenaltyReason);
			
			int PenaltyExpiration = SQL_FetchInt(hndl, 8) - ((GetTime() - SQL_FetchInt(hndl, 7)) / 60);
			
			FormatTime(ExpirationDate, sizeof(ExpirationDate), "%Y/%m/%d - %H:%M:%S", GetTime() + (60 * PenaltyExpiration));

			if(PenaltyExpiration <= 0)
			{
				PenaltyExpiration = 0;
				FormatEx(ExpirationDate, sizeof(ExpirationDate), "∞");
			}
			
			target.init(PlayerName, AuthId, "", AdminName, AdminAuthId, ExpirationDate, PenaltyReason, Penalty);
			
			// Any edit to PlayerName after target.init will not be reflected in the array.
			if(PlayerName[0] == EOS)
				FormatEx(PlayerName, sizeof(PlayerName), AuthId);
			
			PushArrayArray(Array_Targets, target, sizeof(enTargets));
			
			IntToString(view_as<int>(Array_Targets), TempFormat, sizeof(TempFormat));
			AddMenuItem(hMenu, TempFormat, PlayerName);
		}
		
		SetMenuTitle(hMenu, "Communication punishments sorted by date:");
		
		DisplayMenuAtItem(hMenu, client, ItemPos, MENU_TIME_FOREVER);
	
	}
}


public int CommList_MenuHandler(Handle hMenu, MenuAction action, int client, int item)
{
	if(action == MenuAction_End)
	{
		char Info[64];
		
		Handle Array_Targets;
		
		GetMenuItem(hMenu, 0, Info, sizeof(Info));
		
		Array_Targets = view_as<Handle>(StringToInt(Info));
		
		CloseHandle(Array_Targets);
		CloseHandle(hMenu);
	}
	else if(action == MenuAction_Select)
	{
		char Info[64];
		
		Handle Array_Targets;
		
		GetMenuItem(hMenu, item, Info, sizeof(Info));
		
		Array_Targets = view_as<Handle>(StringToInt(Info));
				
		enTargets target;
		
		GetArrayArray(Array_Targets, item, target);
		
		CommListMenu_ShowTargetInfo(client, target.AuthId, target.IPAddress, target.Name, target.AdminAuthId, target.AdminName, target.ExpirationDate, target.BanReason, GetMenuSelectionPosition(), target.PenaltyType);
	}
}

void CommListMenu_ShowTargetInfo(int client, char AuthId[35], char IPAddress[32], char Name[64], char AdminAuthId[35], char AdminName[64], char ExpirationDate[64], char BanReason[256], int LastPos, enPenaltyType PenaltyType)
{
		Handle hMenu = CreateMenu(CommListTargetInfo_MenuHandler);
		
		char PenaltyAlias[32];
		PenaltyAliasByType(PenaltyType, PenaltyAlias, sizeof(PenaltyAlias), false);
		
		PenaltyAlias[0] = CharToUpper(PenaltyAlias[0]);
		
		SetMenuTitle(hMenu, "%s Info of %s\n AuthId: %s | IP: %s\n Admin Info [%s]:\n Admin AuthId: %s\n Expiration Date: %s", PenaltyAlias, Name, AuthId, IPAddress, AdminName, AdminAuthId, ExpirationDate);
		
		Handle Array_Target = CreateArray(sizeof(enTargets));
		
		enTargets target;
		
		target.init(Name, AuthId, IPAddress, AdminName, AdminAuthId, ExpirationDate, BanReason, PenaltyType);
		
		target.LastPos = LastPos;
		
		PushArrayArray(Array_Target, target);
		
		char TempFormat[64];
		
		IntToString(view_as<int>(Array_Target), TempFormat, sizeof(TempFormat));
		AddMenuItem(hMenu, TempFormat, "Unpunish Player");
		
		SetMenuExitBackButton(hMenu, true);
		
		DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
}


public int CommListTargetInfo_MenuHandler(Handle hMenu, MenuAction action, int client, int item)
{
	if(action == MenuAction_End)
	{
		char Info[64];
		
		Handle Array_Target;
		
		GetMenuItem(hMenu, 0, Info, sizeof(Info));
		
		Array_Target = view_as<Handle>(StringToInt(Info));
		
		CloseHandle(Array_Target);
		
		CloseHandle(hMenu);
	}
	else if(action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		Handle Array_Target;
		
		char Info[64];
		
		GetMenuItem(hMenu, 0, Info, sizeof(Info));
		
		Array_Target = view_as<Handle>(StringToInt(Info));
		
		enTargets target;
		
		GetArrayArray(Array_Target, 0, target, sizeof(enTargets));
		
		QueryCommList(client, target.LastPos);
	}
	else if(action == MenuAction_Select)
	{
		switch(item)
		{
			case 0:
			{
				Handle Array_Target;
				
				char Info[64];
				
				GetMenuItem(hMenu, 0, Info, sizeof(Info));
				
				Array_Target = view_as<Handle>(StringToInt(Info));
				
				enTargets target;
				
				GetArrayArray(Array_Target, 0, target, sizeof(enTargets));
				
				char CommandName[32];
				PenaltyAliasByType(target.PenaltyType, CommandName, sizeof(CommandName), false);
				
				Format(CommandName, sizeof(CommandName), "sm_oun%s", CommandName);
				
				FakeClientCommand(client, "%s %s", CommandName, target.AuthId);
				
			}
		}
	}
	
}

public Action Command_BreachBans(int client, int args)
{
	ExpireBreach = GetGameTime() + 60.0;

	UC_PrintToChatAdmins("%s%t", PREFIX, "Announce Ban Breach", client);
	UC_PrintToChatAdmins("%s%t", PREFIX, "Announce Ban Breach Part 2");
	
	UC_ReplyToCommand(client, "%s%t", PREFIX, "Ban Breach Reminder");
	
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

	
	UC_PrintToChatAdmins("%s%t", PREFIX, "Anounce Kick Breach", client);
	LogSQLiteBans("Admin %N kicked all ban breaching clients", client);
	
	return Plugin_Handled;
}


// MENU CODE //

public void OnAdminMenuReady(Handle hTemp)
{
	TopMenu topmenu = view_as<TopMenu>(hTemp);
	#if defined DEBUG
	LogToFile(logFile, "OnAdminMenuReady()");
	#endif

	/* Block us from being called twice */
	if (topmenu == hTopMenu)
	{
		return;
	}

	/* Save the Handle */
	hTopMenu = topmenu;

	/* Find the "Player Commands" category */
	TopMenuObject player_commands = hTopMenu.FindCategory(ADMINMENU_PLAYERCOMMANDS);

	if (player_commands != INVALID_TOPMENUOBJECT)
	{
		// just to avoid "unused variable 'res'" warning
		#if defined DEBUG
		TopMenuObject res = hTopMenu.AddItem(
			"sm_ban",  // Name
			AdminMenu_Ban,  // Handler function
			player_commands,  // We are a submenu of Player Commands
			"sm_ban",  // The command to be finally called (Override checks)
			ADMFLAG_BAN); // What flag do we need to see the menu option
		char temp[125];
		Format(temp, 125, "Result of AddToTopMenu: %d", res);
		LogToFile(logFile, temp);
		LogToFile(logFile, "Added Ban option to admin menu");
		#else
		hTopMenu.AddItem(
			"sm_ban",  // Name
			AdminMenu_Ban,  // Handler function
			player_commands,  // We are a submenu of Player Commands
			"sm_ban",  // The command to be finally called (Override checks)
			ADMFLAG_BAN); // What flag do we need to see the menu option
		#endif
	}
}

public void AdminMenu_Ban(TopMenu topmenu,
	TopMenuAction action,  // Action being performed
	TopMenuObject object_id,  // The object ID (if used)
	int param,  // client idx of admin who chose the option (if used)
	char[] buffer,  // Output buffer (if used)
	int maxlength) // Output buffer (if used)
{
	/* Clear the Ownreason bool, so he is able to chat again;) */
	g_ownReasons[param] = false;

	#if defined DEBUG
	LogToFile(logFile, "AdminMenu_Ban()");
	#endif

	switch (action)
	{
		// We are only being displayed, We only need to show the option name
		case TopMenuAction_DisplayOption:
		{
			FormatEx(buffer, maxlength, "%T", "Ban player", param);

			#if defined DEBUG
			LogToFile(logFile, "AdminMenu_Ban() -> Formatted the Ban option text");
			#endif
		}

		case TopMenuAction_SelectOption:
		{
			DisplayBanTargetMenu(param); // Someone chose to ban someone, show the list of users menu

			#if defined DEBUG
			LogToFile(logFile, "AdminMenu_Ban() -> DisplayBanTargetMenu()");
			#endif
		}
	}
}

public int ReasonSelected(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[128], key[128];

			menu.GetItem(param2, key, sizeof(key), _, info, sizeof(info));

			if (StrEqual("Own Reason", key)) // admin wants to use his own reason
			{
				g_ownReasons[param1] = true;
				UC_PrintToChat(param1, "%s%t", PREFIX, "Custom ban reason explanation", "sm_abortban");
				return;
			}

			else if (g_BanTarget[param1] != -1 && g_BanTime[param1] != -1)
				BanClient(g_BanTarget[param1], g_BanTime[param1], BANFLAG_AUTO|BANFLAG_NOKICK, info, "KICK!!!", "sm_ban", param1);
		}

		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_Disconnected)
			{
				if (PlayerDataPack[param1] != null)
				{
					delete PlayerDataPack[param1];
				}
			}

			else if(param2 == MenuCancel_ExitBack)
			{
				DisplayBanTimeMenu(param1);
			}
		}
	}
}


public int MenuHandler_BanPlayerList(Menu menu, MenuAction action, int param1, int param2)
{
	#if defined DEBUG
	LogToFile(logFile, "MenuHandler_BanPlayerList()");
	#endif

	switch (action)
	{
		case MenuAction_End:
		{
			delete menu;
		}

		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack && hTopMenu != INVALID_HANDLE)
			{
				hTopMenu.Display(param1, TopMenuPosition_LastCategory);
			}
		}

		case MenuAction_Select:
		{
			char info[32], name[32];
			int userid, target;

			menu.GetItem(param2, info, sizeof(info), _, name, sizeof(name));
			userid = StringToInt(info);

			if ((target = GetClientOfUserId(userid)) == 0)
			{
				UC_PrintToChat(param1, "%s%t", PREFIX, "Player no longer available");
			}
			else if (!CanUserTarget(param1, target))
			{
				UC_PrintToChat(param1, "%s%t", PREFIX, "Unable to target");
			}
			else
			{
				g_BanTarget[param1] = target;
				DisplayBanTimeMenu(param1);
			}
		}
	}
}

public int MenuHandler_BanTimeList(Menu menu, MenuAction action, int param1, int param2)
{
	#if defined DEBUG
	LogToFile(logFile, "MenuHandler_BanTimeList()");
	#endif

	switch (action)
	{
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack && hTopMenu != INVALID_HANDLE)
			{
				DisplayBanTargetMenu(param1);
			}
		}

		case MenuAction_Select:
		{
			char info[32];

			menu.GetItem(param2, info, sizeof(info));
			g_BanTime[param1] = StringToInt(info);

			//DisplayBanReasonMenu(param1);
			ReasonMenuHandle.Display(param1, MENU_TIME_FOREVER);
		}

		case MenuAction_DrawItem:
		{
			char time[16];

			menu.GetItem(param2, time, sizeof(time));

			return (StringToInt(time) > 0 || CheckCommandAccess(param1, "sm_unban", ADMFLAG_UNBAN | ADMFLAG_ROOT)) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED;
		}
	}

	return 0;
}

stock void DisplayBanTargetMenu(int client)
{
	#if defined DEBUG
	LogToFile(logFile, "DisplayBanTargetMenu()");
	#endif

	Menu menu = new Menu(MenuHandler_BanPlayerList); // Create a new menu, pass it the handler.

	char title[100];

	FormatEx(title, sizeof(title), "%T:", "Ban player", client);

	menu.SetTitle(title); // Set the title
	menu.ExitBackButton = true; // Yes we want back/exit

	AddTargetsToMenu(menu,  // Add clients to our menu
		client,  // The client that called the display
		false,  // We want to see people connecting
		false); // And dead people

	menu.Display(client, MENU_TIME_FOREVER); // Show the menu to the client FOREVER!
}

stock void DisplayBanTimeMenu(int client)
{
	#if defined DEBUG
	LogToFile(logFile, "DisplayBanTimeMenu()");
	#endif

	char title[100];
	FormatEx(title, sizeof(title), "%T:", "Ban player", client);
	SetMenuTitle(TimeMenuHandle, title);

	DisplayMenu(TimeMenuHandle, client, MENU_TIME_FOREVER);
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
	
	UC_ReplyToCommand(client, buffer);
	
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
	ConVar hndl = AutoExecConfig_CreateConVar(name, defaultValue, description, flags, hasMin, min, hasMax, max);
	
	if(flags & FCVAR_PROTECTED)
		ServerCommand("sm_cvar protect %s", name);
		
	return hndl;
}

#else

stock ConVar UC_CreateConVar(const char[] name, const char[] defaultValue, const char[] description = "", int flags = 0, bool hasMin = false, float min = 0.0, bool hasMax = false, float max = 0.0)
{
	ConVar hndl = CreateConVar(name, defaultValue, description, flags, hasMin, min, hasMax, max);
	
	if(flags & FCVAR_PROTECTED)
		ServerCommand("sm_cvar protect %s", name);
		
	return hndl;
}
 
#endif


// https://forums.alliedmods.net/showpost.php?p=2325048&postcount=8
// Print a Valve translation phrase to a group of players 
// Adapted from util.h's UTIL_PrintToClientFilter 
stock void UC_PrintCenterTextAll(const char[] msg_name, const char[] param1 = "", const char[] param2 = "", const char[] param3 = "", const char[] param4 = "")
{ 
	UserMessageType MessageType = GetUserMessageType();
	for(int i=1;i <= MaxClients;i++)
	{
		if(!IsClientInGame(i))
			continue;
		
		SetGlobalTransTarget(i);
		
		Handle bf = StartMessageOne("TextMsg", i, USERMSG_RELIABLE); 
		 
		if (MessageType == UM_Protobuf) 
		{ 
			PbSetInt(bf, "msg_dst", HUD_PRINTCENTER); 
			PbAddString(bf, "params", msg_name); 
				
			PbAddString(bf, "params", param1); 
			PbAddString(bf, "params", param2); 
			PbAddString(bf, "params", param3); 
			PbAddString(bf, "params", param4); 
		} 
		else 
		{ 
			BfWriteByte(bf, HUD_PRINTCENTER); 
			BfWriteString(bf, msg_name); 
			
			BfWriteString(bf, param1); 
			BfWriteString(bf, param2); 
			BfWriteString(bf, param3); 
			BfWriteString(bf, param4); 
		}
		 
		EndMessage(); 
	}
}  

// Registers a command and saves it for later when we wanna iterate all commands.
stock void UC_RegAdminCmd(const char[] cmd, ConCmd callback, int adminflags, const char[] description = "", const char[] group = "", int flags = 0)
{
	RegAdminCmd(cmd, callback, adminflags, description, group, flags);
	
	char Info[300];
	FormatEx(Info, sizeof(Info), "\"%i\" \"%s\"", adminflags, description);
	
	SetTrieString(Trie_UCCommands, cmd, Info);
}

stock void UC_RegConsoleCmd(const char[] cmd, ConCmd callback, const char[] description = "", int flags = 0)
{
	RegConsoleCmd(cmd, callback, description, flags);

	char Info[300];
	FormatEx(Info, sizeof(Info), "\"%i\" \"%s\"", 0, description);
	
	SetTrieString(Trie_UCCommands, cmd, Info);
}


stock void UC_ReplyToCommand(int client, const char[] format, any ...)
{
	SetGlobalTransTarget(client);
	char buffer[256];

	VFormat(buffer, sizeof(buffer), format, 3);
	for(int i=0;i < sizeof(Colors);i++)
	{
		ReplaceString(buffer, sizeof(buffer), Colors[i], ColorEquivalents[i]);
	}
	
	ReplyToCommand(client, buffer);
}

stock void UC_PrintToChat(int client, const char[] format, any ...)
{
	SetGlobalTransTarget(client);
	
	char buffer[256];
	
	VFormat(buffer, sizeof(buffer), format, 3);
	for(int i=0;i < sizeof(Colors);i++)
	{
		ReplaceString(buffer, sizeof(buffer), Colors[i], ColorEquivalents[i]);
	}
	
	PrintToChat(client, buffer);
}

stock void UC_PrintToChatAll(const char[] format, any ...)
{	
	char buffer[256];
	for(int i=1;i <= MaxClients;i++)
	{
		if(!IsClientInGame(i))
			continue;
		
		SetGlobalTransTarget(i);
		VFormat(buffer, sizeof(buffer), format, 2);
		
		UC_PrintToChat(i, buffer);
	}
}

stock void UC_PrintToChatAdmins(const char[] format, any ...)
{	
	char buffer[256];
	
	for(int i=1;i <= MaxClients;i++)
	{
		if(!IsClientInGame(i))
			continue;
		
		else if (!CheckCommandAccess(i, "sm_admin", ADMFLAG_GENERIC))
			continue;
			
		SetGlobalTransTarget(i);
		
		VFormat(buffer, sizeof(buffer), format, 2);
		
		UC_PrintToChat(i, buffer);
	}
}


stock void UC_PrintToConsole(int client, const char[] format, any ...)
{
	SetGlobalTransTarget(client);
	
	char buffer[256];
	
	VFormat(buffer, sizeof(buffer), format, 3);
	for(int i=0;i < sizeof(Colors);i++)
	{
		ReplaceString(buffer, sizeof(buffer), Colors[i], "");
	}
	
	PrintToConsole(client, buffer);
}
stock void UC_ShowActivity2(int client, const char[] Tag, const char[] format, any ...)
{
	char buffer[256], TagBuffer[256];
	VFormat(buffer, sizeof(buffer), format, 4);
	
	Format(TagBuffer, sizeof(TagBuffer), Tag);
	
	for(int i=0;i < sizeof(Colors);i++)
	{
		ReplaceString(buffer, sizeof(buffer), Colors[i], ColorEquivalents[i]);
	}
	
	for(int i=0;i < sizeof(Colors);i++)
	{
		ReplaceString(TagBuffer, sizeof(TagBuffer), Colors[i], ColorEquivalents[i]);
	}
	
	UC_ShowActivity2(client, TagBuffer, buffer);
}
