
#pragma semicolon 1

#define PLUGIN_AUTHOR "RumbleFrog, SourceBans++ Dev Team, edit by Eyal282"
#define PLUGIN_VERSION "1.0"

#include <sourcemod>
#include <SteamWorks>
#include <smjansson>
#include <sqlitebans>

#undef REQUIRE_PLUGIN
#undef REQUIRE_EXTENSIONS
#tryinclude <autoexecconfig>

#pragma newdecls required

enum
{
	Ban,
	Comms,
	Type_Count,
	Type_Unknown,
};

int EmbedColors[Type_Count] = {
	0xDA1D87, // Ban
	0x4362FA, // Comms
};

char sHostname[256], sHost[64];

ConVar Convars_WebHook[Type_Count];
ConVar Convars_BotName[Type_Count];
ConVar Convars_BotImage[Type_Count];

public Plugin myinfo =
{
	name = "SQLiteBans Discord Plugin",
	author = PLUGIN_AUTHOR,
	description = "Listens for ban forward and sends it to webhook endpoints",
	version = PLUGIN_VERSION,
	url = "https://sbpp.github.io"
};

public void OnPluginStart()
{
	CreateConVar("sqlite_bans_discord_version", PLUGIN_VERSION, "SBPP Discord Version", FCVAR_REPLICATED | FCVAR_SPONLY | FCVAR_DONTRECORD | FCVAR_NOTIFY);

}

public void OnAllPluginsLoaded()
{
	#if defined _autoexecconfig_included
	
	AutoExecConfig_SetFile("SQLiteBans_Discord");
	
	#endif
	
	Convars_WebHook[Ban] = UC_CreateConVar("sqlite_bans_discord_ban_hook", "https://discord.com/api/webhooks/837021016404262962/IP9ZMDYrCPk7aaoun6MQiPXp9myT7UY3GREK0VEs4Aceuy18iXH9yo6ydN7GqJjC3A96", "Discord web hook endpoint for ban forward", FCVAR_PROTECTED);
	Convars_WebHook[Comms] = UC_CreateConVar("sqlite_bans_discord_comms_hook", "", "Discord web hook endpoint for comms forward. If left empty, the ban endpoint will be used instead", FCVAR_PROTECTED);
	
	Convars_BotName[Ban] = UC_CreateConVar("sqlite_bans_discord_ban_name", "SQLite Bans", "Discord bot name", FCVAR_PROTECTED);
	Convars_BotName[Comms] = UC_CreateConVar("sqlite_bans_discord_comms_name", "", "Discord bot name, if empty, the ban name will be used instead.", FCVAR_PROTECTED);

	Convars_BotImage[Ban] = UC_CreateConVar("sqlite_bans_discord_ban_image", "https://wallpapercave.com/wp/AKsyaeQ.jpg", "Discord bot image URL", FCVAR_PROTECTED);
	Convars_BotImage[Comms] = UC_CreateConVar("sqlite_bans_discord_comms_image", "", "Discord bot image URL. if left empty, the ban image will be used instead.", FCVAR_PROTECTED);
	
	#if defined _autoexecconfig_included
	
	AutoExecConfig_ExecuteFile();

	AutoExecConfig_CleanFile();
	
	#endif
}
public void OnConfigsExecuted()
{
	FindConVar("hostname").GetString(sHostname, sizeof sHostname);
	
	int ip[4];
	
	SteamWorks_GetPublicIP(ip);
	
	if (SteamWorks_GetPublicIP(ip))
	{
		Format(sHost, sizeof sHost, "%d.%d.%d.%d:%d", ip[0], ip[1], ip[2], ip[3], FindConVar("hostport").IntValue);
	} else
	{
		int iIPB = FindConVar("hostip").IntValue;
		Format(sHost, sizeof sHost, "%d.%d.%d.%d:%d", iIPB >> 24 & 0x000000FF, iIPB >> 16 & 0x000000FF, iIPB >> 8 & 0x000000FF, iIPB & 0x000000FF, FindConVar("hostport").IntValue);
	}
}

public void SQLiteBans_OnBanIdentity_Post(const char AuthId[35], const char Name[64], const char AdminAuthId[35], const char AdminName[64], const char reason[256], int time)
{
	SendReport(AdminAuthId, AdminName, AuthId, Name, reason, Ban, time);
}

public void SQLiteBans_OnCommPunishIdentity_Post(enPenaltyType PenaltyType, const char AuthId[35], const char Name[64], const char AdminAuthId[35], const char AdminName[64], const char reason[256], int time)
{
	SendReport(AdminAuthId, AdminName, AuthId, Name, reason, Comms, time, PenaltyType);
}

void SendReport(const char AdminAuthId[35], const char AdminName[64], const char AuthId[35], const char Name[64], const char[] sReason, int iType = Ban, int iTime = -1, any extra = 0)
{
	char sBotWebHook[512], sBotName[64], sBotImage[256];
	
	Convars_WebHook[iType].GetString(sBotWebHook, sizeof(sBotWebHook));
	Convars_BotImage[iType].GetString(sBotImage, sizeof(sBotImage));
	Convars_BotName[iType].GetString(sBotName, sizeof(sBotName));
	
	if(sBotWebHook[0] == EOS)
		Convars_WebHook[Ban].GetString(sBotWebHook, sizeof(sBotWebHook));
		
	if(sBotImage[0] == EOS)
		Convars_BotImage[Ban].GetString(sBotImage, sizeof(sBotImage));
		
	if(sBotName[0] == EOS)
		Convars_BotName[Ban].GetString(sBotName, sizeof(sBotName));
		
	if(sBotWebHook[0] == EOS)
	{
		LogError("Missing ban hook endpoint");
		return;
	}
	
	else if(sBotName[0] == EOS)
	{
		LogError("Missing ban bot name");
		return;
	}
	
	else if(sBotImage[0] == EOS)
	{
		LogError("Missing ban bot image");
		return;
	}

	char sJson[2048], sBuffer[256];

	Handle jRequest = json_object();

	Handle jEmbeds = json_array();


	Handle jContent = json_object();
	
	json_object_set(jContent, "color", json_integer(GetEmbedColor(iType)));

	Handle jContentAuthor = json_object();

	json_object_set_new(jContentAuthor, "name", json_string(Name));
	
	char steam3[64];
	SteamIDToSteamID3(AuthId, steam3, sizeof(steam3));
	
	Format(sBuffer, sizeof sBuffer, "https://steamcommunity.com/profiles/%s", steam3);
	json_object_set_new(jContentAuthor, "url", json_string(sBuffer));
	json_object_set_new(jContentAuthor, "icon_url", json_string(sBotImage));
	json_object_set_new(jContent, "author", jContentAuthor);

	Handle jContentFooter = json_object();

	Format(sBuffer, sizeof sBuffer, "%s (%s)", sHostname, sHost);
	json_object_set_new(jContentFooter, "text", json_string(sBuffer));
	json_object_set_new(jContentFooter, "icon_url", json_string(sBotImage));
	json_object_set_new(jContent, "footer", jContentFooter);


	Handle jFields = json_array();


	Handle jFieldAuthor = json_object();
	json_object_set_new(jFieldAuthor, "name", json_string("Author"));
	Format(sBuffer, sizeof sBuffer, "%s (%s)", AdminName, AdminAuthId);
	json_object_set_new(jFieldAuthor, "value", json_string(sBuffer));
	json_object_set_new(jFieldAuthor, "inline", json_boolean(true));

	Handle jFieldTarget = json_object();
	json_object_set_new(jFieldTarget, "name", json_string("Target"));
	Format(sBuffer, sizeof sBuffer, "%s (%s)", Name, AuthId);
	json_object_set_new(jFieldTarget, "value", json_string(sBuffer));
	json_object_set_new(jFieldTarget, "inline", json_boolean(true));

	Handle jFieldReason = json_object();
	json_object_set_new(jFieldReason, "name", json_string("Reason"));
	json_object_set_new(jFieldReason, "value", json_string(sReason));

	json_array_append_new(jFields, jFieldAuthor);
	json_array_append_new(jFields, jFieldTarget);

	if (iType == Ban || iType == Comms)
	{
		Handle jFieldDuration = json_object();

		json_object_set_new(jFieldDuration, "name", json_string("Duration"));

		if (iTime > 0)
			Format(sBuffer, sizeof sBuffer, "%d Minutes", iTime);

		else
			Format(sBuffer, sizeof sBuffer, "Permanent");

		json_object_set_new(jFieldDuration, "value", json_string(sBuffer));

		json_array_append_new(jFields, jFieldDuration);
	}
	
	if (iType == Comms)
	{
		Handle jFieldCommType = json_object();
		
		json_object_set_new(jFieldCommType, "name", json_string("Comm Type"));
		
		char cType[32];
		
		GetCommType(cType, sizeof cType, extra);
		
		json_object_set_new(jFieldCommType, "value", json_string(cType));
		
		json_array_append_new(jFields, jFieldCommType);
	}

	json_array_append_new(jFields, jFieldReason);


	json_object_set_new(jContent, "fields", jFields);



	json_array_append_new(jEmbeds, jContent);

	json_object_set_new(jRequest, "username", json_string(sBotName));
	json_object_set_new(jRequest, "avatar_url", json_string(sBotImage));
	json_object_set_new(jRequest, "embeds", jEmbeds);



	json_dump(jRequest, sJson, sizeof sJson, 0, false, false, true);

	#if defined DEBUG
		PrintToServer(sJson);
	#endif

	CloseHandle(jRequest);

	Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodPOST, sBotWebHook);

	SteamWorks_SetHTTPRequestContextValue(hRequest, 0, 0);
	SteamWorks_SetHTTPRequestGetOrPostParameter(hRequest, "payload_json", sJson);
	SteamWorks_SetHTTPCallbacks(hRequest, OnHTTPRequestComplete);

	if (!SteamWorks_SendHTTPRequest(hRequest))
		LogError("HTTP request failed for %s against %s", AdminName, Name);
}

public int OnHTTPRequestComplete(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode)
{
	if (!bRequestSuccessful || eStatusCode != k_EHTTPStatusCode204NoContent)
	{
		LogError("HTTP request failed");

		#if defined DEBUG
			int iSize;

			SteamWorks_GetHTTPResponseBodySize(hRequest, iSize);

			char[] sBody = new char[iSize];

			SteamWorks_GetHTTPResponseBodyData(hRequest, sBody, iSize);

			PrintToServer(sBody);
			PrintToServer("Status Code: %d", eStatusCode);
			PrintToServer("SteamWorks_IsLoaded: %d", SteamWorks_IsLoaded());
		#endif
	}

	CloseHandle(hRequest);
}

int GetEmbedColor(int iType)
{
	if (iType != Type_Unknown)
		return EmbedColors[iType];
	
	return EmbedColors[Ban];
}

void GetCommType(char[] sBuffer, int iBufferSize, int iType)
{
	switch (iType)
	{
		case Penalty_Mute:
			strcopy(sBuffer, iBufferSize, "Mute");
		case Penalty_Gag:
			strcopy(sBuffer, iBufferSize, "Gag");
		case Penalty_Silence:
			strcopy(sBuffer, iBufferSize, "Silence");
	}
}

stock bool IsValidClient(int iClient, bool bAlive = false)
{
	if (iClient >= 1 &&
	iClient <= MaxClients &&
	IsClientConnected(iClient) &&
	IsClientInGame(iClient) &&
	!IsFakeClient(iClient) &&
	(bAlive == false || IsPlayerAlive(iClient)))
	{
		return true;
	}

	return false;
}

void SteamIDToSteamID3(const char[] authid, char[] steamid3, int len) {
    // STEAM_X:Y:Z
    // W = Z * 2 + Y
    // [U:1:W]
    char buffer[3][32];
    ExplodeString(authid, ":", buffer, sizeof buffer, sizeof buffer[]);
    int w = StringToInt(buffer[2]) * 2 + StringToInt(buffer[1]);
    FormatEx(steamid3, len, "[U:1:%i]", w);
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
