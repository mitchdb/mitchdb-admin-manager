#pragma semicolon 1
#include <sourcemod>
#include <cURL>

#define MDBAVERSION "1.1.0"

#define ADMINLIST_FILE "configs/admins.cfg"
#define ADMINLIST_TEMP_FILE "configs/admins.cfg.tmp"

#define ADMINGROUP_FILE "configs/admin_groups.cfg"
#define ADMINGROUP_TEMP_FILE "configs/admin_groups.cfg.tmp"

// Define some max string sizes
#define APIKEY_SIZE 33
#define APISECRET_SIZE 33

// API ENDPOINTS
#define MDB_URL_ADMINS        "http://api.mitchdb.net/api/v2/admins"
#define MDB_URL_ADMINGROUPS   "http://api.mitchdb.net/api/v2/admin_groups"

public Plugin:myinfo = 
{
  name = "MitchDB Admin Manager",
  author = "Mitch Dempsey (WebDestroya)",
  description = "MitchDB.com Admin Manager",
  version = MDBAVERSION,
  url = "http://www.mitchdb.com/"
};

new CURL_Default_opt[][2] = {
  {_:CURLOPT_NOSIGNAL,1},
  {_:CURLOPT_NOPROGRESS,1},
  {_:CURLOPT_TIMEOUT,40},
  {_:CURLOPT_CONNECTTIMEOUT,30},
  {_:CURLOPT_VERBOSE,0}
};

#define CURL_DEFAULT_OPT(%1) curl_easy_setopt_int_array(%1, CURL_Default_opt, sizeof(CURL_Default_opt))

// Console variables
new Handle:convar_mdb_apikey = INVALID_HANDLE; // ApiKey Console Variable
new Handle:convar_mdb_apisecret = INVALID_HANDLE; // Api Secret Console Variable
new Handle:convar_mdb_serverid = INVALID_HANDLE; // ServerID Console Variable

// status variables
new bool:is_reload_running = false;
new Handle:reload_form_handle = INVALID_HANDLE;
new Handle:reload_file_handle = INVALID_HANDLE;

new bool:is_group_reload_running = false;
new Handle:group_reload_form_handle = INVALID_HANDLE;
new Handle:group_reload_file_handle = INVALID_HANDLE;

public OnPluginStart() {

  convar_mdb_apikey = CreateConVar("mdb_apikey", "none", "The API key used to communicate with MitchDB", FCVAR_PROTECTED);
  convar_mdb_apisecret = CreateConVar("mdb_apisecret", "none", "The API secret used to communicate with MitchDB", FCVAR_PROTECTED);
  convar_mdb_serverid = CreateConVar("mdb_serverid", "0", "The MitchDB ServerID for this server.", FCVAR_PROTECTED);
  
  // Misc/utility commands
  RegAdminCmd("mdb_reloadadmins", Command_MDB_ReloadAdmins, ADMFLAG_RCON, "This forces the server to download the latest admin list.");
  RegAdminCmd("mdb_reloadadmingroups", Command_MDB_ReloadAdminGroups, ADMFLAG_RCON, "This forces the server to download the latest admin group list.");
}


// Reload Admin List
public Action:Command_MDB_ReloadAdmins(client, args) {

  if(is_reload_running) {
    PrintToConsole(client, "[MitchDB] The admin update is already running. Please wait for it to finish.");
    return Plugin_Handled;
  }

  PrintToConsole(client, "[MitchDB] Reloading the admin list");

  is_reload_running = true;

  new Handle:curl = curl_easy_init();
  if(curl == INVALID_HANDLE) {
    CurlError("admin list");
    return Plugin_Handled;
  }

  CURL_DEFAULT_OPT(curl);

  decl String:apikey[APIKEY_SIZE];
  decl String:apisecret[APISECRET_SIZE];
  decl String:serverid[11];
  decl String:servertime[11];
  decl String:sig_request[256];
  decl String:signature[128];
  
  Format(servertime, sizeof(servertime), "%d", GetTime());
  GetConVarString(convar_mdb_apikey, apikey, sizeof(apikey));
  GetConVarString(convar_mdb_apisecret, apisecret, sizeof(apisecret));
  GetConVarString(convar_mdb_serverid, serverid, sizeof(serverid));

  // make the temp file path
  decl String:admin_temp_file[250];
  BuildPath(PathType:Path_SM, admin_temp_file, sizeof(admin_temp_file), ADMINLIST_TEMP_FILE);
  
  // attempt to delete the banfile
  reload_file_handle = curl_OpenFile(admin_temp_file, "w");
  curl_easy_setopt_handle(curl, CURLOPT_WRITEDATA, reload_file_handle);

  reload_form_handle = curl_httppost();
  curl_formadd(reload_form_handle, CURLFORM_COPYNAME, "api_key", CURLFORM_COPYCONTENTS, apikey, CURLFORM_END);
  curl_formadd(reload_form_handle, CURLFORM_COPYNAME, "server_id", CURLFORM_COPYCONTENTS, serverid, CURLFORM_END);
  curl_formadd(reload_form_handle, CURLFORM_COPYNAME, "servertime", CURLFORM_COPYCONTENTS, servertime, CURLFORM_END);

  // Signature
  Format(sig_request, sizeof(sig_request), "%s%s%s%s", apisecret, apikey, servertime, serverid);
  curl_hash_string(sig_request, strlen(sig_request), Openssl_Hash_SHA1, signature, sizeof(signature));

  // add the signature to the request
  curl_formadd(reload_form_handle, CURLFORM_COPYNAME, "signature", CURLFORM_COPYCONTENTS, signature, CURLFORM_END);

  curl_easy_setopt_string(curl, CURLOPT_URL, MDB_URL_ADMINS);
  curl_easy_setopt_handle(curl, CURLOPT_HTTPPOST, reload_form_handle);

  curl_easy_perform_thread(curl, onCompleteMDBAdminList, client);

  return Plugin_Handled;
}

// Request completed, so update the admin cache
public onCompleteMDBAdminList(Handle:hndl, CURLcode: code, any:clientid) {
  is_reload_running = false;

  // close the file that was just downloaded
  CloseHandle(reload_form_handle);
  CloseHandle(reload_file_handle);

  if(code != CURLE_OK) {
    CurlFailure("admin group list", code);
    CloseHandle(hndl);
    return;
  }

  // find out the response code from the server
  new responseCode;
  curl_easy_getinfo_int(hndl, CURLINFO_RESPONSE_CODE, responseCode);
  CloseHandle(hndl);

  if(responseCode != 200) {
    LogToGame("[MitchDB] ERROR: There was a problem downloading the admin list. (Server returned HTTP %d)", responseCode);
    PrintToConsole(clientid, "[MitchDB] ERROR: There was a problem downloading the admin list. (Server returned HTTP %d)", responseCode);
    return;
  }

  // make the file paths
  decl String:admin_temp_file[250];
  decl String:admin_file[250];
  BuildPath(PathType:Path_SM, admin_temp_file, sizeof(admin_temp_file), ADMINLIST_TEMP_FILE);
  BuildPath(PathType:Path_SM, admin_file, sizeof(admin_file), ADMINLIST_FILE);

  // Response was good, so update the file
  DeleteFile(admin_file);

  // rename the old one
  RenameFile(admin_file, admin_temp_file);

  // clear the cache
  DumpAdminCache(AdminCache_Groups, true);
  DumpAdminCache(AdminCache_Overrides, true);

  PrintToConsole(clientid, "[MitchDB] The admin list has been successfully updated!");
}


/////////////// ADMIN GROUPS


// Reload the admin group list
public Action:Command_MDB_ReloadAdminGroups(client, args) {

  if(is_group_reload_running) {
    PrintToConsole(client, "[MitchDB] The admin group update is already running. Please wait for it to finish.");
    return Plugin_Handled;
  }

  PrintToConsole(client, "[MitchDB] Reloading the admin group list");

  is_group_reload_running = true;

  new Handle:curl = curl_easy_init();
  if(curl == INVALID_HANDLE) {
    CurlError("admin group list");
    return Plugin_Handled;
  }

  CURL_DEFAULT_OPT(curl);

  decl String:apikey[APIKEY_SIZE];
  decl String:apisecret[APISECRET_SIZE];
  decl String:serverid[11];
  decl String:servertime[11];
  decl String:sig_request[256];
  decl String:signature[128];
  
  Format(servertime, sizeof(servertime), "%d", GetTime());
  GetConVarString(convar_mdb_apikey, apikey, sizeof(apikey));
  GetConVarString(convar_mdb_apisecret, apisecret, sizeof(apisecret));
  GetConVarString(convar_mdb_serverid, serverid, sizeof(serverid));

  // make the temp file path
  decl String:admin_groups_temp_file[250];
  BuildPath(PathType:Path_SM, admin_groups_temp_file, sizeof(admin_groups_temp_file), ADMINGROUP_TEMP_FILE);
  
  // attempt to delete the banfile
  group_reload_form_handle = curl_OpenFile(admin_groups_temp_file, "w");
  curl_easy_setopt_handle(curl, CURLOPT_WRITEDATA, group_reload_form_handle);

  group_reload_form_handle = curl_httppost();
  curl_formadd(group_reload_form_handle, CURLFORM_COPYNAME, "api_key", CURLFORM_COPYCONTENTS, apikey, CURLFORM_END);
  curl_formadd(group_reload_form_handle, CURLFORM_COPYNAME, "server_id", CURLFORM_COPYCONTENTS, serverid, CURLFORM_END);
  curl_formadd(group_reload_form_handle, CURLFORM_COPYNAME, "servertime", CURLFORM_COPYCONTENTS, servertime, CURLFORM_END);

  // Signature
  Format(sig_request, sizeof(sig_request), "%s%s%s%s", apisecret, apikey, servertime, serverid);
  curl_hash_string(sig_request, strlen(sig_request), Openssl_Hash_SHA1, signature, sizeof(signature));

  // add the signature to the request
  curl_formadd(group_reload_form_handle, CURLFORM_COPYNAME, "signature", CURLFORM_COPYCONTENTS, signature, CURLFORM_END);

  curl_easy_setopt_string(curl, CURLOPT_URL, MDB_URL_ADMINGROUPS);
  curl_easy_setopt_handle(curl, CURLOPT_HTTPPOST, group_reload_form_handle);

  curl_easy_perform_thread(curl, onCompleteMDBAdminGroupList, client);

  return Plugin_Handled;
}

// Request completed, so update the admin cache
public onCompleteMDBAdminGroupList(Handle:hndl, CURLcode: code, any:clientid) {
  is_group_reload_running = false;

  // close the file that was just downloaded
  CloseHandle(group_reload_form_handle);
  CloseHandle(group_reload_file_handle);

  if(code != CURLE_OK) {
    CurlFailure("admin group list", code);
    CloseHandle(hndl);
    return;
  }

  // find out the response code from the server
  new responseCode;
  curl_easy_getinfo_int(hndl, CURLINFO_RESPONSE_CODE, responseCode);
  CloseHandle(hndl);

  if(responseCode != 200) {
    LogToGame("[MitchDB] ERROR: There was a problem downloading the admin group list. (Server returned HTTP %d)", responseCode);
    PrintToConsole(clientid, "[MitchDB] ERROR: There was a problem downloading the admin group list. (Server returned HTTP %d)", responseCode);
    return;
  }

  // make the file paths
  decl String:admin_groups_temp_file[250];
  decl String:admin_groups_file[250];
  BuildPath(PathType:Path_SM, admin_groups_temp_file, sizeof(admin_groups_temp_file), ADMINGROUP_TEMP_FILE);
  BuildPath(PathType:Path_SM, admin_groups_file, sizeof(admin_groups_file), ADMINGROUP_FILE);

  // Response was good, so update the file
  DeleteFile(admin_groups_file);

  // rename the old one
  RenameFile(admin_groups_file, admin_groups_temp_file);

  // clear the cache
  DumpAdminCache(AdminCache_Groups, true);
  DumpAdminCache(AdminCache_Overrides, true);

  PrintToConsole(clientid, "[MitchDB] The admin group list has been successfully updated!");
}



/////// UTILS

stock CurlError(const String:info[]) {
  LogToGame("[MitchDB] ERROR: Unable to create cURL resource. (%s)", info);
}

stock CurlFailure(const String:info[], CURLcode:code) {
  if(code == CURLE_COULDNT_RESOLVE_HOST) {
    LogToGame("[MitchDB] ERROR: Network error contacting API. [unable to resolve host] (%s)", info);
  } else if(code==CURLE_OPERATION_TIMEDOUT) {
    LogToGame("[MitchDB] ERROR: Network error contacting API. [timed out] (%s)", info);
  } else {
    LogToGame("[MitchDB] ERROR: Network error contacting API. [curlcode=%d] (%s)", code, info);
  }
}