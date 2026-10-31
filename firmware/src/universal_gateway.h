#pragma once

// Included inside main.cpp's private namespace after the protocol decoders.
// No HTTP, flash, or JSON work is performed from NimBLE callback threads.
constexpr char kFirmwareVersion[] = "1.1.42";
Preferences gIdentityStore;
String gHardwareId, gSetupSsid, gSetupToken;
String gSetupRequestId, gSetupState="waiting", gSetupError;
bool gSetupActive=false, gProvisioning=false, gControllerEnabled=true, gBmsEnabled=false;
// Re-setup of a working gateway: the new configuration reached the cloud but
// is only in RAM until the app's handover; the saved one stays intact.
bool gSetupTrialPending=false;
bool gBleStarted=false, gCloudReady=false,gOperational=false;
uint32_t gWifiAttemptAt=0, gCloudHeartbeatAt=0, gLastQueuePoll=0;
uint32_t gNextCloudHeartbeatAt=0,gControllerNextAt=0,gBmsNextAt=0;
uint32_t gLastReconnectAt=0, gLastCheckpointAt=0, gSetupStartedAt=0;
String gActiveCommand, gActiveCommandType;
String gSelectionPreviousMac,gSelectionPreviousProfile,gSelectionPreviousModel;bool gSelectionPreviousEnabled=false;
uint8_t gSelectionPreviousLink=0;
// The Modbus address and response mode the working controller had taught us.
// Choosing another controller forgets them on purpose; a selection that then
// fails must give them back, or the gateway that was reading a minute ago has
// to walk the whole ladder again.
uint8_t gSelectionPreviousBleAddr=0xff,gSelectionPreviousBleMode=0;
int32_t gSelectionPreviousPin=-1;
// Whether a failed selection may keep the PIN the user just typed: true when
// it is the controller already saved, or when none is saved yet. A selection
// that hands the gateway back to a different controller must not leave this
// one's PIN behind.
bool gSelectionKeepPin=false;
String gControllerModel;
void gatewayDisconnect(bool controller);
JsonDocument gActivePayload;
uint32_t gCommandStartedAt=0;
bool gLoadDesired=false;
uint8_t gLoadModeStage=0;
uint16_t gExpectedSettings[16]={};  // USER block E005..E014 being written
int gActualBatteryType=-1;
uint32_t gSettingsReadAt=0;
// Controller register cache E000..E01F and the charge/discharge switch
// (0xDF00), filled only from replies on the current connection (0 = unread).
uint16_t gCtrlReg[0x20]={};uint32_t gCtrlRegAt[0x20]={};
uint16_t gCtrlSwitch=0;uint32_t gCtrlSwitchAt=0;bool gCtrlSwitchSupported=true;
bool gCtrlSnapshotsDirty=true;
String gLastDailyJson;
String gFinalCommandJson;
uint32_t gControllerLinkedAt=0,gBmsLinkedAt=0;
uint8_t gSrneRx[512]={}; size_t gSrneRxLength=0;
// One CTRL_RX_ADDR and one CTRL_RX_LEN note per link: enough to identify a
// module that answers from an unexpected address, or with a block length no
// decoder claims, without either filling the 40-line ring.
bool gSrneRxOddLogged=false,gSrneRxLenLogged=false;
volatile uint32_t gControllerGeneration=0,gBmsGeneration=0;
// One BLE notification (<= negotiated MTU, at most 252 bytes with NimBLE's
// 255-byte preferred MTU). Small slots allow a deep queue during cloud I/O.
struct GatewayRx { uint32_t receivedAt;uint32_t generation;bool srne; uint16_t size; uint8_t data[256]; };
QueueHandle_t gRxQueue=nullptr;

String gatewayRandom() {
  char out[33]; for(int i=0;i<4;++i) snprintf(out+i*8,9,"%08lx",static_cast<unsigned long>(esp_random()));
  return String(out);
}
bool gatewayIdentifier(const String &s) {
  if(s.length()<6 || s.length()>64) return false;
  for(size_t i=0;i<s.length();++i) if(!isalnum(s[i]) && s[i]!='_' && s[i]!='-') return false;
  return true;
}
bool gatewayMac(const String &s) {
  if(s.length()!=17) return false;
  for(int i=0;i<17;++i) if(i%3==2 ? s[i]!=':' : !isxdigit(s[i])) return false;
  return true;
}
// Only these 12/24V Shiner models are supported; Shiner4820 is excluded.
bool gatewayControllerModel(const String &s) {
  return s=="Shiner2410" || s=="Shiner2420" || s=="Shiner2430" || s=="Shiner2440" || s=="Shiner2460";
}
bool gatewayCloud(const char *method,const String &path,JsonDocument *body,JsonDocument *response=nullptr) {
  if(!gatewayIdentifier(gDeviceId)) { gNetworkError="Gateway has no valid device ID."; return false; }
  if(!firebaseAuthenticate()) return false;  // sets its own reason
  String payload; if(body) serializeJson(*body,payload);
  String raw;
  int status=databaseRequest(method,String(getFirebaseDatabaseUrl())+getDevicePath()+(path.isEmpty()?String(""):"/"+path)+".json"+getFirebaseAuthParam(),payload,&raw);
  if(status==401) gFirebaseIdToken="";
  // A refusal and a silence need different answers: 401/403 is the rules or
  // the account, while a negative status means no reply arrived at all, which
  // points at the Internet rather than at Firebase.
  if(status<=0) { gNetworkError="No reply from the Firebase database. Check that the gateway's Wi-Fi has working Internet."; return false; }
  if(status==401 || status==403) { gNetworkError=String("Firebase refused the gateway (")+status+"). Publish the database rules and check the device account."; return false; }
  if(status<200 || status>=300) { gNetworkError=String("Database request failed (")+status+")."; return false; }
  if(response && deserializeJson(*response,raw)) { gNetworkError="Firebase sent an answer the gateway could not read."; return false; }
  gNetworkError=""; return true;
}
void gatewayJson(int status,JsonDocument &doc) {
  String body; serializeJson(doc,body);
  gWebServer.sendHeader("Cache-Control","no-store"); gWebServer.send(status,"application/json",body);
}
void gatewayError(int status,const String &message) {
  JsonDocument d; d["message"]=message; gatewayJson(status,d);
}
bool gatewayAuthorized() {
  if(!gSetupActive || gSetupToken.isEmpty() || gWebServer.header("X-Setup-Token")!=gSetupToken) {
    gatewayError(403,"Gateway pairing required. Reconnect and verify setup code."); return false;
  }
  return true;
}
// One common setup-hotspot password for every gateway, published with the
// instructions on the web flasher page. Protection comes from when the
// hotspot opens (never-configured gateway, or 3 BOOT presses = physical
// access, 20 minutes) and from the final cloud verification, not from secrecy.
constexpr char kSetupHotspotPassword[]="85208136";
void gatewayPrintSetupInfo() {
  Serial.printf("NOXBRAIN_SETUP ssid=%s (password on the web flasher page)\n",gSetupSsid.c_str());
#if CONFIG_IDF_TARGET_ESP32S3 && ARDUINO_USB_CDC_ON_BOOT
  Serial0.printf("NOXBRAIN_SETUP ssid=%s (password on the web flasher page)\n",gSetupSsid.c_str());
#endif
}
void gatewayStartPortal() {
  if(gSetupActive) return;
  gSetupActive=true; gPortalMode=true; gSetupState="recovery"; gSetupStartedAt=millis();
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP(gSetupSsid.c_str(),kSetupHotspotPassword);
  gatewayPrintSetupInfo();
}
// Pair mode: three BOOT presses within one second open the setup hotspot for
// 20 minutes. Apart from a never-configured gateway, this is the only way the
// hotspot opens. Presses are counted in an interrupt so a blocking cloud
// request in the loop can never miss them.
constexpr uint32_t kPairModeMs=20UL*60UL*1000UL;
uint32_t gPortalUntil=0;
volatile uint32_t gBootPressAt[3]={};
volatile uint8_t gBootPressIndex=0;
volatile bool gPairRequested=false;
// Factory reset: BOOT held down continuously for 10 seconds (releasing cancels).
constexpr uint32_t kFactoryResetHoldMs=10000;
volatile bool gBootDown=false;
volatile uint32_t gBootDownAt=0;
void IRAM_ATTR gatewayBootChanged() {
  const bool down=(REG_READ(GPIO_IN_REG)&BIT0)==0; // GPIO0, IRAM-safe read
  if(down==gBootDown)return;
  gBootDown=down;
  if(!down)return;
  const uint32_t now=millis();gBootDownAt=now;
  const uint32_t last=gBootPressAt[(gBootPressIndex+2)%3];
  if(last && now-last<40)return; // Contact bounce, not a new press.
  gBootPressAt[gBootPressIndex]=now;gBootPressIndex=(gBootPressIndex+1)%3;
  const uint32_t oldest=gBootPressAt[gBootPressIndex];
  if(oldest && now-oldest<=1000){gPairRequested=true;gBootPressAt[0]=gBootPressAt[1]=gBootPressAt[2]=0;}
}
// Erases every setting and recorded value so the gateway starts like new
// (opens the setup hotspot). Firmware stays. Firebase ownership is kept on
// the cloud side so a stolen gateway cannot be claimed in the same project.
void gatewayFactoryReset() {
  Serial.println("FACTORY_RESET_ERASING_ALL_SETTINGS");
  gDailyStore.clear();gIdentityStore.clear();
  LittleFS.end();LittleFS.format();
  WiFi.disconnect(true,true);
  delay(300);ESP.restart();
}
void gatewayStopPortal() {
  WiFi.softAPdisconnect(true); WiFi.mode(WIFI_STA);
  gSetupActive=false; gPortalMode=false; gSetupToken=""; gPortalUntil=0;
}
void gatewaySaveCredentials() {
  gDailyStore.putString("wifi_ssid",gWifiSsid); secretPut("wifi_pass",gWifiPassword);
  gDailyStore.putString("fb_db_url",gFirebaseDatabaseUrl); secretPut("fb_api_key",gFirebaseApiKey);
  secretPut("fb_email",gFirebaseDeviceEmail); secretPut("fb_pass",gFirebaseDevicePassword);
  gDailyStore.putString("device_id",gDeviceId); gDailyStore.putString("setup_request",gSetupRequestId);
  gDailyStore.putInt("tz_offset",gTimezoneOffset);
  gDailyStore.putUInt("setup_schema",1);
  gDailyStore.putBool("configured",true);
}
// A failed trial setup must not leave its trial credentials active. Reload the
// last working configuration from flash (none on a first install) and rejoin.
void gatewayRestoreSavedConfig() {
  diagLog("SETUP_RESTORE_SAVED state=%s error=%s",gSetupState.c_str(),gSetupError.c_str());
  gSetupTrialPending=false;
  const bool saved=gDailyStore.getUInt("setup_schema",0)==1;
  gWifiSsid=saved?gDailyStore.getString("wifi_ssid",""):String("");
  gWifiPassword=saved?secretGet("wifi_pass"):String("");
  gFirebaseDatabaseUrl=saved?gDailyStore.getString("fb_db_url",""):String("");
  gFirebaseApiKey=saved?secretGet("fb_api_key"):String("");
  gFirebaseDeviceEmail=saved?secretGet("fb_email"):String("");
  gFirebaseDevicePassword=saved?secretGet("fb_pass"):String("");
  gDeviceId=saved?gDailyStore.getString("device_id",gHardwareId):gHardwareId;
  gTimezoneOffset=gDailyStore.getInt("tz_offset",0);configTime(gTimezoneOffset,0,"pool.ntp.org","time.nist.gov");
  gFirebaseIdToken="";gLastFirebaseAuthAttempt=0;gCloudReady=false;resetDatabaseConnection();
  WiFi.disconnect(false);gWifiAttemptAt=millis();
  if(gWifiSsid.length())WiFi.begin(gWifiSsid.c_str(),gWifiPassword.c_str());
}
void gatewayRoutes() {
  const char *headers[]={"X-Setup-Token"}; gWebServer.collectHeaders(headers,1);
  gWebServer.on("/api/info",HTTP_GET,[](){
    JsonDocument d; d["product"]="NoxBrain"; d["protocol_version"]=1;
    d["hardware_id"]=gHardwareId; d["device_id"]=gDeviceId; d["setup_ssid"]=gSetupSsid;
    d["firmware_version"]=kFirmwareVersion; d["setup_active"]=gSetupActive; d["configured"]=gOperational;
    // A configured gateway tells which Firebase database it uses (an address,
    // not a secret), so a re-setup in the same project can keep its login.
    if(gOperational)d["database_url"]=gDailyStore.getString("fb_db_url","");
    d["keep_firebase"]=true; // this firmware accepts keep_firebase in /api/setup/config
#if CONFIG_IDF_TARGET_ESP32S3
    d["chip_family"]="ESP32-S3";
#else
    d["chip_family"]="ESP32";
#endif
    gatewayJson(200,d);
  });
  gWebServer.on("/api/pair",HTTP_POST,[](){
    // No code: joining the hotspot is the pairing step. The session token only
    // keeps one phone's setup from mixing with another's.
    if(!gSetupActive) {gatewayError(403,"Setup hotspot is closed. Press BOOT 3 times within one second.");return;}
    gSetupToken=gatewayRandom();JsonDocument d;d["token"]=gSetupToken;d["hardware_id"]=gHardwareId;gatewayJson(200,d);
  });
  gWebServer.on("/api/setup/status",HTTP_GET,[](){
    if(!gatewayAuthorized()) return;
    JsonDocument d;d["state"]=gSetupState;d["message"]=gSetupError;
    d["request_id"]=gSetupRequestId;d["hardware_id"]=gHardwareId;d["device_id"]=gDeviceId;
    d["wifi_connected"]=WiFi.status()==WL_CONNECTED;d["cloud_connected"]=gCloudReady;gatewayJson(200,d);
  });
  gWebServer.on("/api/setup/wifi",HTTP_GET,[](){
    if(!gatewayAuthorized()) return;
    int count=WiFi.scanNetworks(false,false); JsonDocument d;
    if(count<0) {gatewayError(503,"Wi-Fi scan failed. Retry in a moment.");return;}
    JsonArray rows=d["networks"].to<JsonArray>();
    for(int i=0;i<count;++i) {
      if(WiFi.SSID(i).isEmpty()) continue;
      JsonObject row=rows.add<JsonObject>();row["ssid"]=WiFi.SSID(i);row["rssi"]=WiFi.RSSI(i);
      row["secure"]=WiFi.encryptionType(i)!=WIFI_AUTH_OPEN;
    }
    WiFi.scanDelete();gatewayJson(200,d);
  });
  gWebServer.on("/api/setup/config",HTTP_POST,[](){
    if(!gatewayAuthorized())return;
    JsonDocument d;if(gWebServer.arg("plain").length()>6000 || deserializeJson(d,gWebServer.arg("plain"))) {gatewayError(400,"Invalid setup configuration");return;}
    // keep_firebase: a re-setup in the same Firebase project only changes the
    // home Wi-Fi; the gateway keeps its own ID and device login, so the phone
    // needs no Firebase step in the middle of the setup.
    const bool keep=d["keep_firebase"] | false;
    // The saved (working) login is used, never a value from an earlier trial.
    if(keep && (!gOperational || gDailyStore.getUInt("setup_schema",0)!=1 || String(d["device_id"] | "")!=gDailyStore.getString("device_id",""))) {gatewayError(400,"This gateway cannot keep its Firebase login. Run the full setup.");return;}
    const String ssid=d["wifi_ssid"] | "", pass=d["wifi_password"] | "";
    const String db=keep?gDailyStore.getString("fb_db_url",""):String(d["database_url"] | "");
    const String key=keep?secretGet("fb_api_key"):String(d["api_key"] | ""), email=keep?secretGet("fb_email"):String(d["email"] | ""), password=keep?secretGet("fb_pass"):String(d["password"] | "");
    const String id=d["device_id"] | "", request=d["request_id"] | "";
    if(ssid.isEmpty() || ssid.length()>32 || pass.length()>63 || !validCloudUrl(db) || key.isEmpty() || email.isEmpty() || password.isEmpty() || !gatewayIdentifier(id) || !gatewayIdentifier(request)) {
      gatewayError(400,"Complete home Wi-Fi, Firebase login and gateway identification are required.");return;
    }
    // Trial settings stay in RAM until both gateway login and the cloud
    // handshake succeed. Failed setup never erases the last working config.
    gWifiSsid=ssid;gWifiPassword=pass;gFirebaseDatabaseUrl=db;gFirebaseApiKey=key;
    gFirebaseDeviceEmail=email;gFirebaseDevicePassword=password;gDeviceId=id;gSetupRequestId=request;
    int offset=d["timezone_offset_seconds"] | 0;if(offset>= -43200 && offset<=50400)gTimezoneOffset=offset;
    configTime(gTimezoneOffset,0,"pool.ntp.org","time.nist.gov");
    diagLog("SETUP_CONFIG_RECEIVED id=%s operational=%d keep_firebase=%d",id.c_str(),int(gOperational),int(keep));
    gFirebaseIdToken="";gLastFirebaseAuthAttempt=0;gCloudReady=false;gProvisioning=true;gNextCloudHeartbeatAt=0;resetDatabaseConnection();
    gSetupState="connecting_wifi";gSetupError="";gWifiAttemptAt=millis();
    JsonDocument reply;reply["accepted"]=true;reply["request_id"]=request;gatewayJson(202,reply);
    WiFi.begin(gWifiSsid.c_str(),gWifiPassword.c_str());
  });
  gWebServer.on("/",HTTP_GET,[](){
    gWebServer.send(200,"text/html; charset=utf-8","<html><meta name='viewport' content='width=device-width'><h2>NoxBrain Gateway</h2><p>Open the NoxBrain app to securely complete setup. No credentials are displayed here.</p></html>");
  });
  // Obsolete endpoints must fail explicitly, never report fake success.
  gWebServer.on("/save",HTTP_POST,[](){gatewayError(410,"Use the current app setup wizard.");});
  gWebServer.on("/api/cmd",HTTP_POST,[](){gatewayError(410,"Use authenticated cloud commands.");});
  gWebServer.begin();
}

#ifdef NOXBRAIN_BENCH
// JK notification counters (BLE task), printed by the bench tick.
volatile uint32_t gBenchJkNotes=0,gBenchJkTooBig=0,gBenchJkQueueFull=0,gBenchJkMaxSize=0,gBenchJkMinSize=0;
#endif
void gatewayNotify(NimBLERemoteCharacteristic *c,uint8_t *data,size_t length,bool) {
  ++gDiagNotes;
#ifdef NOXBRAIN_BENCH
  if(c && c==gJkChar && length) {
    ++gBenchJkNotes;if(length>gBenchJkMaxSize)gBenchJkMaxSize=length;if(!gBenchJkMinSize || length<gBenchJkMinSize)gBenchJkMinSize=length;
    if(length>sizeof(GatewayRx::data))++gBenchJkTooBig;
  }
#endif
  if(!gRxQueue || !length || length>sizeof(GatewayRx::data) || (c!=gSrneNotifier && c!=gJkChar)) return;
  GatewayRx packet;packet.receivedAt=millis();packet.srne=c==gSrneNotifier;packet.generation=packet.srne?gControllerGeneration:gBmsGeneration;packet.size=length;memcpy(packet.data,data,length);
  if(xQueueSend(gRxQueue,&packet,0)!=pdTRUE) {
    ++gRxDropped;
#ifdef NOXBRAIN_BENCH
    if(!packet.srne)++gBenchJkQueueFull;
#endif
  }
}
bool gatewayFlushResult() {
  if(gFinalCommandJson.isEmpty())return true;
  JsonDocument result;if(deserializeJson(result,gFinalCommandJson))return false;
  String id=result["id"].as<String>();
  if(!gatewayCloud("PUT","command_results/"+id,&result))return false;
  JsonDocument empty;empty.set(nullptr);
  if(!gatewayCloud("PUT","commands/queue/"+id,&empty))return false;
  gDailyStore.remove("pending_result");gFinalCommandJson="";
  gActiveCommand="";gActiveCommandType="";gActivePayload.clear();return true;
}
void gatewayResult(const String &status,const String &message,JsonDocument *extra=nullptr) {
#ifdef NOXBRAIN_BENCH
  // Bench: print the result instead of writing it to Firebase.
  if(gActiveCommand.startsWith("bench")) {
    String data;if(extra)serializeJson(*extra,data);
    BENCH_PORT.println("BENCH_RESULT "+gActiveCommandType+" "+status+": "+message+(data.length()?" data="+data:String("")));
    if(status!="accepted"){gActiveCommand="";gActiveCommandType="";gActivePayload.clear();gLoadModeStage=0;}
    return;
  }
#endif
  if(gActiveCommand.isEmpty() || !gFinalCommandJson.isEmpty())return;
  diagLog("CMD %s %s: %s",gActiveCommandType.c_str(),status.c_str(),message.c_str());
  JsonDocument result;result["status"]=status;result["message"]=message;result["id"]=gActiveCommand;
  result["updated_at"][".sv"]="timestamp";
  if(extra)result["data"].set(*extra);
  if(status=="confirmed" || status=="failed" || status=="expired") {
    if(gActiveCommandType=="select_device" && !gSelectionPreviousProfile.isEmpty()) {
      const bool controller=gActivePayload["target"].as<String>()=="controller";
      if(status=="confirmed") {
        gDailyStore.putString(controller?"ctrl_mac":"bms_mac",controller?gConfigControllerMac:gConfigBmsMac);
        gDailyStore.putBool(controller?"ctrl_enabled":"bms_enabled",true);
        if(controller){gDailyStore.putString("ctrl_model",gControllerModel);gDailyStore.putUChar("ctrl_link",gCtrlLink);gDailyStore.putInt("ctrl_pin",gCtrlPin);
          if(gCtrlLink==1){gDailyStore.putUInt("rs485_baud",gRs485Baud);gDailyStore.putUChar("rs485_addr",gRs485Addr);}}
        else gDailyStore.putString("bms_profile",gJkProfile);
      } else {
        gatewayDisconnect(controller);
        if(controller){gConfigControllerMac=gSelectionPreviousMac;gControllerEnabled=gSelectionPreviousEnabled;gControllerModel=gSelectionPreviousModel;gCtrlLink=gSelectionPreviousLink;
          gRs485Baud=gDailyStore.getUInt("rs485_baud",9600);gRs485Addr=gDailyStore.getUChar("rs485_addr",1);
          // Give the old controller its learned address and mode back.
          gSrneBleAddr=gSelectionPreviousBleAddr;gSrneRespMode=gSelectionPreviousBleMode;
          // The PIN typed for this controller stays, so the next attempt and
          // the automatic reconnects can pair with it (see the select handler).
          if(!gSelectionKeepPin)gCtrlPin=gSelectionPreviousPin;
          gDailyStore.putInt("ctrl_pin",gCtrlPin);
          gDailyStore.putUChar("srne_ble_addr",gSelectionPreviousBleAddr);gDailyStore.putUChar("srne_ble_mode",gSelectionPreviousBleMode);}
        else {gConfigBmsMac=gSelectionPreviousMac;gBmsEnabled=gSelectionPreviousEnabled;gJkProfile=gSelectionPreviousProfile;}
      }
      gSelectionPreviousProfile="";
    }
    serializeJson(result,gFinalCommandJson);
    gDailyStore.putString("pending_result",gFinalCommandJson);
    gatewayFlushResult();
  } else gatewayCloud("PUT","command_results/"+gActiveCommand,&result);
}
void gatewayOnLive(const uint8_t *data,size_t length) {
  if(gActiveCommandType!="load" || gLoadModeStage!=2 || length<73) return;
  // 0x0120 high byte bit7 is the Shiner load-output switch state.
  // Confirm the output readback, not only a successful BLE write call.
  const uint16_t status=(uint16_t(data[67])<<8)|data[68];
  const bool on=(status & 0x8000)!=0;
  if(on==gLoadDesired) gatewayResult("confirmed","Controller load state read back successfully.");
}
// ---------------------------------------------------------------------------
// Controller parameters (SRNE "Parameter set"), read and written on a
// Shiner2420: E001 max charge current (0.01 A), E002 capacity (Ah), E003
// system voltage (high byte = setting 0x0C/0x18, 0xFF = automatic
// recognition (unverified); low byte = recognised voltage, read-only), E004
// battery type, E005..E014 USER block, E015..E018 charging/discharging upper
// and lower temperature limits (low byte, bit7 = minus), E01D load working
// mode, E01E light control delay (min), E01F light control voltage (V), DF00
// charge/discharge switch (1 = on). Every write is confirmed by a readback.
//
// Requests run one at a time from a small queue, each waiting for its own
// reply: the controller's BLE module drops a frame that follows another
// too closely. A command job reads everything first, then validates and
// builds its writes from those fresh values, writes, reads back, verifies.
enum CtrlOpKind:uint8_t{kOpReadSettings,kOpReadE001,kOpReadE015,kOpReadSwitch,kOpWrite,kOpWriteBlock,kOpMark,kOpBuild,kOpVerify};
struct CtrlOp{uint8_t kind;uint16_t addr;uint16_t value;};
struct CtrlExpect{uint16_t addr;uint16_t value;uint16_t mask;};
std::vector<CtrlOp> gCtrlOps;std::vector<CtrlExpect> gCtrlExpect;
size_t gCtrlOpAt=0;bool gCtrlWaiting=false;uint8_t gCtrlTries=0;
uint32_t gCtrlSentAt=0,gCtrlMarkAt=0,gCtrlJobDeadline=0;bool gCtrlJob=false;
const char *const kUserKeys[16]={"over_voltage_v","charge_limit_v","equalization_v","boost_absorption_v","float_v","boost_return_v","over_discharge_recovery_v","low_voltage_warning_v","discharge_cutoff_v","discharge_limit_v",nullptr,"over_discharge_delay_s","equalization_time_min","boost_time_min","equalization_interval_days","temperature_compensation_mv"};

bool gatewayCtrlBusy(){return gCtrlOpAt<gCtrlOps.size();}
void gatewayCtrlReset(){gCtrlOps.clear();gCtrlExpect.clear();gCtrlOpAt=0;gCtrlWaiting=false;gCtrlTries=0;gCtrlJob=false;}
void gatewayCtrlAdvance(uint8_t kind){
  if(!gatewayCtrlBusy() || !gCtrlWaiting || gCtrlOps[gCtrlOpAt].kind!=kind)return;
  // Only a reply that arrived after this op was sent can be its reply. A late
  // one from a cancelled refresh, or from an attempt already given up on,
  // reads as the same kind and used to advance the step it never answered.
  if(int32_t(gDecodedReceivedAt-gCtrlSentAt)<0)return;
  ++gCtrlOpAt;gCtrlWaiting=false;gCtrlTries=0;
}
void gatewayCtrlStore(uint16_t first,const uint8_t *data,uint8_t count){
  const uint32_t now=millis()|1;
  for(uint8_t i=0;i<count;++i){
    const uint16_t index=first-0xe000+i;if(index>=0x20)continue;
    gCtrlReg[index]=(uint16_t(data[3+i*2])<<8)|data[4+i*2];gCtrlRegAt[index]=now;
  }
}
bool gatewayCtrlKnown(uint16_t address){return gCtrlRegAt[address-0xe000]!=0;}
// Read after the last mark (job start, or after its writes).
bool gatewayCtrlFresh(uint16_t address){const uint32_t at=gCtrlRegAt[address-0xe000];return at && int32_t(at-gCtrlMarkAt)>=0;}
bool gatewayCtrlFreshRange(uint16_t from,uint16_t to){for(uint16_t a=from;a<=to;++a)if(!gatewayCtrlFresh(a))return false;return true;}
bool gatewayCtrlKnownRange(uint16_t from,uint16_t to){for(uint16_t a=from;a<=to;++a)if(!gatewayCtrlKnown(a))return false;return true;}
bool gatewayCtrlSwitchFresh(){return gCtrlSwitchAt && int32_t(gCtrlSwitchAt-gCtrlMarkAt)>=0;}
const char *gatewayCtrlProfileName(uint16_t type){return type==0?"USER":type==1?"OPEN":type==2?"SEALED":type==3?"GEL":type==4?"LITHIUM":"UNKNOWN";}
int gatewayCtrlTemp(uint16_t raw){const int magnitude=raw&0x7f;return (raw&0x80)?-magnitude:magnitude;}
uint16_t gatewayCtrlTempRaw(int celsius){return celsius<0?uint16_t(0x80|(-celsius)):uint16_t(celsius);}
// Rated charge current from the selected Shiner model (e.g. Shiner2420 = 20 A).
int gatewayCtrlRatedA(){return gatewayControllerModel(gControllerModel)?gControllerModel.substring(8).toInt():0;}
String gatewayCtrlHex(uint16_t address){String text=String(address,HEX);text.toUpperCase();return text;}

// r = E005..E014. Temperature compensation is stored without its minus
// sign (1 = -1 mV/°C/2V, confirmed with the SRNE app).
void gatewayCtrlDecodeBlock(JsonObject o,const uint16_t *r){
  for(int i=0;i<16;++i) {
    if(i==10){o["charge_end_soc_pct"]=r[10]>>8;o["discharge_end_soc_pct"]=r[10]&0xff;}
    else if(i<10)o[kUserKeys[i]]=r[i]/10.0;
    else o[kUserKeys[i]]=r[i];
  }
}
void gatewayCtrlSettingsJson(JsonObject o){
  const bool type=gatewayCtrlKnown(0xe004);
  if(type)o["battery_type_code"]=gCtrlReg[4];else o["battery_type_code"]=nullptr;
  o["battery_profile"]=type?gatewayCtrlProfileName(gCtrlReg[4]):"UNKNOWN";
  o["controller_battery_profile"]=o["battery_profile"];
  if(gatewayCtrlKnownRange(0xe005,0xe014))gatewayCtrlDecodeBlock(o,&gCtrlReg[5]);
  if(gatewayCtrlKnownRange(0xe001,0xe003)) {
    o["max_charge_current_a"]=gCtrlReg[1]/100.0;o["battery_capacity_ah"]=gCtrlReg[2];
    const uint8_t setting=gCtrlReg[3]>>8;
    o["system_voltage_setting"]=setting==0x0c?"12":setting==0x18?"24":setting==0xff?"auto":"other";
    o["system_voltage_recognized_v"]=gCtrlReg[3]&0xff;
  }
  if(gatewayCtrlKnownRange(0xe015,0xe01f)) {
    o["charge_temp_upper_c"]=gatewayCtrlTemp(gCtrlReg[0x15]);o["charge_temp_lower_c"]=gatewayCtrlTemp(gCtrlReg[0x16]);
    o["discharge_temp_upper_c"]=gatewayCtrlTemp(gCtrlReg[0x17]);o["discharge_temp_lower_c"]=gatewayCtrlTemp(gCtrlReg[0x18]);
    o["load_mode"]=gCtrlReg[0x1d];o["light_control_delay_min"]=gCtrlReg[0x1e];o["light_control_voltage_v"]=gCtrlReg[0x1f];
  }
  const int rated=gatewayCtrlRatedA();if(rated)o["rated_charge_current_a"]=rated;else o["rated_charge_current_a"]=nullptr;
  o["charge_discharge_switch_supported"]=gCtrlSwitchSupported;
  if(gCtrlSwitchAt)o["charge_discharge_switch"]=gCtrlSwitch!=0;else o["charge_discharge_switch"]=nullptr;
}

// Last two copies of the battery profile (type, USER block, max charge
// current), saved before every change to them. Copy 1 is the newest.
bool gatewayCtrlSnapshotJson(JsonObject o,const String &raw) {
  JsonDocument saved;
  if(raw.isEmpty() || deserializeJson(saved,raw) || !saved["r"].is<JsonArrayConst>() || saved["r"].size()!=16)return false;
  uint16_t r[16];for(int i=0;i<16;++i)r[i]=saved["r"][i] | 0;
  const uint64_t at=saved["t"] | uint64_t(0);if(at)o["saved_at"]=at;else o["saved_at"]=nullptr;
  const uint16_t type=saved["type"] | 99;
  o["battery_type_code"]=type;o["battery_profile"]=gatewayCtrlProfileName(type);
  o["max_charge_current_a"]=(saved["e001"] | 0)/100.0;
  gatewayCtrlDecodeBlock(o,r);return true;
}
void gatewayCtrlSnapshotsJson(JsonObject o) {
  const char *keys[2]={"ctrl_snap1","ctrl_snap2"},*slots[2]={"slot1","slot2"};
  for(int i=0;i<2;++i)if(!gatewayCtrlSnapshotJson(o[slots[i]].to<JsonObject>(),gDailyStore.getString(keys[i],"")))o[slots[i]]=nullptr;
}
void gatewayCtrlTakeSnapshot() {
  JsonDocument saved;const time_t now=time(nullptr);
  saved["t"]=now>1700000000?uint64_t(now)*1000:uint64_t(0);saved["type"]=gCtrlReg[4];saved["e001"]=gCtrlReg[1];
  JsonArray r=saved["r"].to<JsonArray>();for(int i=0;i<16;++i)r.add(gCtrlReg[5+i]);
  String raw;serializeJson(saved,raw);
  gDailyStore.putString("ctrl_snap2",gDailyStore.getString("ctrl_snap1",""));gDailyStore.putString("ctrl_snap1",raw);
  gCtrlSnapshotsDirty=true;
}
void gatewayPublishControllerSettings() {
  JsonDocument d;gatewayCtrlSettingsJson(d["controller_settings"].to<JsonObject>());
  if(gCtrlSnapshotsDirty){gatewayCtrlSnapshotsJson(d["controller_profile_snapshots"].to<JsonObject>());gCtrlSnapshotsDirty=false;}
  String json;serializeJson(d,json);firebasePatchLive(json,true);
}

void gatewayCtrlFinish(bool ok,const String &message,bool withData=false) {
  const bool job=gCtrlJob;gatewayCtrlReset();
  if(!job)return;
  if(!withData){gatewayResult(ok?"confirmed":"failed",message);return;}
  JsonDocument data;gatewayCtrlSettingsJson(data.to<JsonObject>());
  gatewayCtrlSnapshotsJson(data["controller_profile_snapshots"].to<JsonObject>());
  gatewayResult(ok?"confirmed":"failed",message,&data);
}
void gatewayCtrlQueueReads(){for(uint8_t kind:{kOpReadSettings,kOpReadE001,kOpReadE015,kOpReadSwitch})gCtrlOps.push_back({kind,0,0});}
// Periodic refresh; never interrupts a running job or refresh. Once every
// parameter is known only the main E004 block (one request) is read, like the
// earlier smooth-running project, so live readings are barely interrupted.
void gatewayCtrlStartRefresh(){
  if(gatewayCtrlBusy())return;gatewayCtrlReset();
  if(gatewayCtrlKnownRange(0xe001,0xe003) && gatewayCtrlKnownRange(0xe015,0xe01f) && gCtrlSwitchAt)gCtrlOps.push_back({kOpReadSettings,0,0});
  else gatewayCtrlQueueReads();
  diagLog("CTRL_REFRESH_START ops=%u",unsigned(gCtrlOps.size()));
}
void gatewayCtrlStartJob() {
  gatewayCtrlReset();gCtrlJob=true;gCtrlJobDeadline=millis()+50000;
  gCtrlOps.push_back({kOpMark,0,0});gatewayCtrlQueueReads();gCtrlOps.push_back({kOpBuild,0,0});
}
void gatewayCtrlWrite(uint16_t address,uint16_t value,uint16_t mask=0xffff){gCtrlOps.push_back({kOpWrite,address,value});gCtrlExpect.push_back({address,value,mask});}
void gatewayCtrlWriteBlock(const uint16_t *block) {
  memcpy(gExpectedSettings,block,sizeof(gExpectedSettings));gCtrlOps.push_back({kOpWriteBlock,0xe005,0});
  for(int i=0;i<16;++i)gCtrlExpect.push_back({uint16_t(0xe005+i),block[i],0xffff});
}
void gatewayCtrlEndWrites(){gCtrlOps.push_back({kOpMark,0,0});gatewayCtrlQueueReads();gCtrlOps.push_back({kOpVerify,0,0});}

// USER block safety rules (raw register values, E005..E014).
String gatewayCtrlCheckUserBlock(const uint16_t *v) {
  for(int i=0;i<10;++i)if(v[i]<70 || v[i]>170)return String(kUserKeys[i])+" must be 7.0-17.0 V (12V scale).";
  // Upper limits for the integer fields (seconds, minutes, minutes, days, mV/°C/2V).
  const uint16_t integerMax[]={255,720,720,255,5};
  for(int i=11;i<16;++i)if(v[i]>integerMax[i-11])return String(kUserKeys[i])+" must be 0-"+String(integerMax[i-11])+".";
  const int upper=v[10]>>8,lower=v[10]&0xff;
  if(upper>100 || upper<=lower)return "Charge-end SOC must be above discharge-end SOC (0-100%).";
  // No strict voltage-order rule: like the SRNE app, each value only has to
  // be in range (7.0-17.0 V above); the controller enforces its own limits
  // and refuses a value it will not accept (reported from the write readback).
  return "";
}
String gatewayCtrlParseUserBlock(JsonVariantConst params,uint16_t *out) {
  const String generic="Only a complete validated USER parameter block is writable. Read controller settings before editing.";
  for(int i=0;i<16;++i) {
    if(i==10)continue;
    if(!params[kUserKeys[i]].is<double>())return generic;
    const double value=params[kUserKeys[i]].as<double>(),scaled=value*(i<10?10:1);
    if(!isfinite(value) || value<0 || scaled>65535)return generic;
    if(fabs(scaled-round(scaled))>0.001)return String(kUserKeys[i])+(i<10?" allows one decimal place.":" must be a whole number.");
    out[i]=uint16_t(round(scaled));
  }
  if(!params["charge_end_soc_pct"].is<double>() || !params["discharge_end_soc_pct"].is<double>())return generic;
  const double upper=params["charge_end_soc_pct"].as<double>(),lower=params["discharge_end_soc_pct"].as<double>();
  if(!isfinite(upper) || !isfinite(lower) || upper!=floor(upper) || lower!=floor(lower) || lower<0 || upper>100)
    return "Charge-end SOC must be above discharge-end SOC (0-100%).";
  out[10]=(uint16_t(upper)<<8)|uint16_t(lower);
  return gatewayCtrlCheckUserBlock(out);
}
bool gatewayCtrlWhole(JsonVariantConst value,double low,double high,int &out) {
  if(!value.is<double>())return false;
  const double number=value.as<double>();
  if(!isfinite(number) || number!=floor(number) || number<low || number>high)return false;
  out=int(number);return true;
}

// Builds the writes of the active command from the values just read.
// Returns why it was refused, or "" (writes queued, or job already finished).
String gatewayCtrlBuild() {
  const String &type=gActiveCommandType;JsonVariantConst p=gActivePayload.as<JsonVariantConst>();
  if(!gatewayCtrlFreshRange(0xe001,0xe014))return "Controller parameters could not be read. Check the controller connection and retry.";
  if(type=="read_settings"){gCtrlOps.push_back({kOpVerify,0,0});return "";}
  const String noChange="No change: the controller already has these values.";
  if(type=="controller_settings") {
    if(p["profile"].as<String>()!="USER" || gCtrlReg[4]!=0)return "Battery parameters can be changed only when the controller battery type is User defined (USER).";
    uint16_t block[16];const String error=gatewayCtrlParseUserBlock(p["parameters"],block);if(error.length())return error;
    if(!memcmp(block,&gCtrlReg[5],sizeof(block))){gatewayCtrlFinish(true,noChange,true);return "";}
    gatewayCtrlTakeSnapshot();gatewayCtrlWriteBlock(block);gatewayCtrlEndWrites();return "";
  }
  if(type=="restore_profile_snapshot") {
    const int slot=p["slot"] | 0;if(slot!=1 && slot!=2)return "Select saved copy 1 or 2.";
    JsonDocument saved;const String raw=gDailyStore.getString(slot==1?"ctrl_snap1":"ctrl_snap2","");
    if(raw.isEmpty() || deserializeJson(saved,raw) || !saved["r"].is<JsonArrayConst>() || saved["r"].size()!=16)return "This saved copy does not exist yet.";
    const int savedType=saved["type"] | -1,current=saved["e001"] | -1,rated=gatewayCtrlRatedA();
    if(savedType<0 || savedType>4)return "The saved copy has an unknown battery type.";
    if(current<100 || (rated && current>rated*100))return "The saved max charge current is outside this controller's range.";
    uint16_t block[16];for(int i=0;i<16;++i)block[i]=saved["r"][i] | 0;
    if(savedType==0){const String error=gatewayCtrlCheckUserBlock(block);if(error.length())return "The saved copy fails the safety checks: "+error;}
    const bool changed=savedType!=gCtrlReg[4] || current!=gCtrlReg[1] || (savedType==0 && memcmp(block,&gCtrlReg[5],sizeof(block)));
    if(!changed){gatewayCtrlFinish(true,noChange,true);return "";}
    // The chosen copy is already in memory, so rolling the copies is safe.
    gatewayCtrlTakeSnapshot();
    if(savedType!=gCtrlReg[4])gatewayCtrlWrite(0xe004,savedType);
    // A fixed type uses its own built-in values; only USER gets the block.
    if(savedType==0)gatewayCtrlWriteBlock(block);
    if(current!=gCtrlReg[1])gatewayCtrlWrite(0xe001,current);
    gatewayCtrlEndWrites();return "";
  }
  if(type!="controller_parameters")return "Unsupported controller parameter command.";
  uint16_t next[0x20];memcpy(next,gCtrlReg,sizeof(next));bool given=false;int number=0;
  auto has=[&](const char *key){const bool present=!p[key].isNull();given=given || present;return present;};
  if(has("system_voltage")) {
    const String value=p["system_voltage"].as<String>();
    const uint8_t setting=value=="12"?0x0c:value=="24"?0x18:value=="auto"?0xff:0;
    if(!setting)return "System voltage must be 12V, 24V or Automatic recognition.";
    next[3]=(uint16_t(setting)<<8)|(gCtrlReg[3]&0xff);
  }
  if(has("battery_type")) {
    const String value=p["battery_type"].as<String>();
    const int code=value=="USER"?0:value=="OPEN"?1:value=="SEALED"?2:value=="GEL"?3:value=="LITHIUM"?4:-1;
    if(code<0)return "Select a battery type: User defined, FLD, SLD/AGM, GEL or LI.";
    next[4]=code;
  }
  if(has("battery_capacity_ah")) {
    if(!gatewayCtrlWhole(p["battery_capacity_ah"],1,10000,number))return "Battery capacity must be a whole number, 1-10000 Ah.";
    next[2]=number;
  }
  if(has("max_charge_current_a")) {
    const int rated=gatewayCtrlRatedA();
    if(!rated)return "Select the controller model first; its rated current limits the charge current.";
    if(!p["max_charge_current_a"].is<double>())return "Max charge current must be a number.";
    const double amps=p["max_charge_current_a"].as<double>(),scaled=amps*100;
    if(!isfinite(amps) || amps<1 || amps>rated)return "Max charge current must be 1-"+String(rated)+" A.";
    if(fabs(scaled-round(scaled))>0.001)return "Max charge current allows two decimal places.";
    next[1]=uint16_t(round(scaled));
  }
  const char *temperatures[4]={"charge_temp_upper_c","charge_temp_lower_c","discharge_temp_upper_c","discharge_temp_lower_c"};
  bool anyTemperature=false;
  for(int i=0;i<4;++i) {
    if(!has(temperatures[i]))continue;
    if(!gatewayCtrlFreshRange(0xe015,0xe018))return "Temperature limits could not be read from this controller.";
    if(!gatewayCtrlWhole(p[temperatures[i]],-40,90,number))return String(temperatures[i])+" must be a whole number, -40 to 90 °C.";
    // Only the low byte holds the value; the high byte is kept as read.
    next[0x15+i]=(gCtrlReg[0x15+i]&0xff00)|gatewayCtrlTempRaw(number);anyTemperature=true;
  }
  if(anyTemperature) {
    if(gatewayCtrlTemp(next[0x15])<=gatewayCtrlTemp(next[0x16]))return "Charging upper limit temperature must be above the lower limit.";
    if(gatewayCtrlTemp(next[0x17])<=gatewayCtrlTemp(next[0x18]))return "Discharge upper limit temperature must be above the lower limit.";
  }
  const bool anyLoad=has("load_mode") | has("light_control_delay_min") | has("light_control_voltage_v");
  if(anyLoad && !gatewayCtrlFreshRange(0xe01d,0xe01f))return "Load settings could not be read from this controller.";
  if(!p["load_mode"].isNull()) {
    // 0 light control, 1-14 light control + N hours, 15 manual, 17 normally on.
    // 16 (Debugging mode) is deliberately not offered.
    if(!gatewayCtrlWhole(p["load_mode"],0,17,number) || number==16)return "Select a load working mode (Debugging mode is not offered).";
    next[0x1d]=number;
  }
  if(!p["light_control_delay_min"].isNull()) {
    if(!gatewayCtrlWhole(p["light_control_delay_min"],0,60,number))return "Light controlled delay must be a whole number, 0-60 min.";
    next[0x1e]=number;
  }
  if(!p["light_control_voltage_v"].isNull()) {
    if(!gatewayCtrlWhole(p["light_control_voltage_v"],1,40,number))return "Light controlled voltage must be a whole number, 1-40 V.";
    next[0x1f]=number;
  }
  const bool anySwitch=has("charge_discharge_switch");
  if(anySwitch && !p["charge_discharge_switch"].is<bool>())return "Charge/discharge switch must be on or off.";
  if(anySwitch && (!gCtrlSwitchSupported || !gatewayCtrlSwitchFresh()))return "Charge/discharge switch could not be read from this controller.";
  if(!given)return "No controller parameter was given.";
  // Battery type and max charge current belong to the saved profile copies.
  if(next[4]!=gCtrlReg[4] || next[1]!=gCtrlReg[1])gatewayCtrlTakeSnapshot();
  // The app's load ON/OFF needs manual mode; remember the mode it replaces.
  if(next[0x1d]==15 && gCtrlReg[0x1d]!=15)gDailyStore.putInt("prev_load_mode",gCtrlReg[0x1d]);
  const uint8_t order[]={3,4,2,1,0x15,0x16,0x17,0x18,0x1d,0x1e,0x1f};
  for(uint8_t index:order)
    if(next[index]!=gCtrlReg[index])gatewayCtrlWrite(0xe000+index,next[index],index==3?0xff00:(index>=0x15 && index<=0x18)?0x00ff:0xffff);
  if(anySwitch) {
    const bool on=p["charge_discharge_switch"].as<bool>();
    if(on!=(gCtrlSwitch!=0)){gCtrlOps.push_back({kOpWrite,0xdf00,uint16_t(on?1:0)});gCtrlExpect.push_back({0xdf00,uint16_t(on?1:0),0xffff});}
  }
  if(gCtrlExpect.empty()){gatewayCtrlFinish(true,noChange,true);return "";}
  gatewayCtrlEndWrites();return "";
}
void gatewayCtrlVerify() {
  for(const CtrlExpect &expect:gCtrlExpect) {
    const bool sw=expect.addr==0xdf00;
    const bool fresh=sw?gatewayCtrlSwitchFresh():gatewayCtrlFresh(expect.addr);
    const uint16_t actual=sw?gCtrlSwitch:gCtrlReg[expect.addr-0xe000];
    if(!fresh){gatewayCtrlFinish(false,"Values were sent but the controller readback did not arrive. Read the parameters again to check them.",true);return;}
    if((actual&expect.mask)!=(expect.value&expect.mask)){gatewayCtrlFinish(false,"Controller did not keep the new value (register "+gatewayCtrlHex(expect.addr)+"). Read the parameters and check the controller.",true);return;}
  }
  gatewayCtrlFinish(true,gCtrlExpect.empty()?"Actual controller parameters received.":"Controller parameters written and confirmed by readback.",true);
}
void gatewayCtrlTick() {
  if(!gatewayCtrlBusy()){if(!gCtrlOps.empty())gatewayCtrlReset();return;}
  if(!srneWriterReady() || !srneLinkUp()){gatewayCtrlFinish(false,"Controller disconnected during the parameter command. Read the parameters again before retrying.");return;}
  if(gCtrlJob && int32_t(millis()-gCtrlJobDeadline)>=0){gatewayCtrlFinish(false,"Controller did not answer in time. Read the parameters again before retrying.");return;}
  const CtrlOp op=gCtrlOps[gCtrlOpAt];
  if(op.kind==kOpMark){gCtrlMarkAt=millis();++gCtrlOpAt;return;}
  if(op.kind==kOpBuild){++gCtrlOpAt;const String error=gatewayCtrlBuild();if(error.length())gatewayCtrlFinish(false,error);return;}
  if(op.kind==kOpVerify){gatewayCtrlVerify();return;}
  if(gCtrlWaiting) {
    if(millis()-gCtrlSentAt<2000)return;
    gCtrlWaiting=false;
    if(gCtrlTries>=3) {
      if(op.kind==kOpWrite || op.kind==kOpWriteBlock){gatewayCtrlFinish(false,"The controller did not acknowledge the write. Read the parameters again to check what changed.");return;}
      // A missing read is caught later by the build or verify step.
      ++gCtrlOpAt;gCtrlTries=0;return;
    }
  }
  if(millis()-gSrneLastTxAt<400)return;
  switch(op.kind) {
    case kOpReadSettings:sendSrneSettingsRead();break;
    case kOpReadE001:sendSrneRead(0xe001,3);break;
    case kOpReadE015:sendSrneRead(0xe015,11);break;
    case kOpReadSwitch:sendSrneRead(0xdf00,1);break;
    case kOpWrite:sendSrneRegisterWrite(op.addr,op.value,"controller_parameter");break;
    case kOpWriteBlock:sendSrneSettingsWrite(gExpectedSettings);break;
  }
  gCtrlWaiting=true;++gCtrlTries;gCtrlSentAt=millis();
}

// Replies from the controller (called from gatewayDrainRx).
void gatewayOnSettings(const uint8_t *data,size_t length) {
  if(length<5+size_t(data[2]))return;
  if(data[2]==34) {
    gatewayCtrlStore(0xe004,data,17);gActualBatteryType=gCtrlReg[4];gSettingsReadAt=millis();
    gatewayCtrlAdvance(kOpReadSettings);
  } else if(data[2]==32)gatewayCtrlStore(0xe005,data,16);
}
void gatewayCtrlOnBlock(const uint8_t *data,size_t length) {
  if(length<5+size_t(data[2]))return;
  if(data[2]==6){gatewayCtrlStore(0xe001,data,3);gatewayCtrlAdvance(kOpReadE001);}
  else {gatewayCtrlStore(0xe015,data,11);gatewayCtrlAdvance(kOpReadE015);}
  gatewayPublishControllerSettings();
}
// A 2-byte reply belongs to the switch only while its read is pending.
void gatewayCtrlOnSwitch(const uint8_t *data) {
  if(!gatewayCtrlBusy() || !gCtrlWaiting || gCtrlOps[gCtrlOpAt].kind!=kOpReadSwitch)return;
  gCtrlSwitch=(uint16_t(data[3])<<8)|data[4];gCtrlSwitchAt=millis()|1;gCtrlSwitchSupported=true;
  gatewayCtrlAdvance(kOpReadSwitch);gatewayPublishControllerSettings();
}
void gatewayCtrlOnWriteEcho(uint8_t function,const uint8_t *frame) {
  if(!gatewayCtrlBusy() || !gCtrlWaiting)return;
  const CtrlOp &op=gCtrlOps[gCtrlOpAt];const uint16_t address=(uint16_t(frame[2])<<8)|frame[3];
  if(function==6 && op.kind==kOpWrite && address==op.addr)gatewayCtrlAdvance(kOpWrite);
  else if(function==16 && op.kind==kOpWriteBlock && address==0xe005)gatewayCtrlAdvance(kOpWriteBlock);
}
// Modbus exception for the pending request. Returns false if none is pending.
bool gatewayCtrlOnException() {
  if(!gatewayCtrlBusy() || !gCtrlWaiting)return false;
  const CtrlOp op=gCtrlOps[gCtrlOpAt];
  if(op.kind==kOpWrite || op.kind==kOpWriteBlock) {
    gatewayCtrlFinish(false,"Controller refused the new value (register "+gatewayCtrlHex(op.addr)+"). Values before it in this save may already be written; read the parameters again.",true);
    return true;
  }
  if(op.kind==kOpReadSwitch){gCtrlSwitchSupported=false;gCtrlSwitchAt=0;}
  ++gCtrlOpAt;gCtrlWaiting=false;gCtrlTries=0;return true;
}

// Product model text the controller reports (0x000C..0x0013, 16 ASCII bytes).
// Compared with the model chosen in the app by its number (e.g. "2440");
// the exact Shiner text format is unverified, so a mismatch only warns.
String gControllerModelReported;
void gatewayOnModel(const uint8_t *data,size_t length) {
  if(length<21)return;
  String text;
  for(size_t i=3;i<19;++i){const char ch=char(data[i]);if(ch>=0x20 && ch<0x7f)text+=ch;}
  text.trim();gControllerModelReported=text;
}
// 1/0 when the reported text contains a 4-digit model number to compare,
// -1 when it does not (unknown format is never reported as a mismatch).
int gatewayModelMatch() {
  if(!gatewayControllerModel(gControllerModel))return -1;
  const String &text=gControllerModelReported;
  for(size_t i=0;i+4<=text.length();++i) {
    bool digits=true;for(size_t k=0;k<4;++k)digits=digits && isdigit(text[i+k]);
    const bool bounded=(i==0 || !isdigit(text[i-1])) && (i+4==text.length() || !isdigit(text[i+4]));
    if(digits && bounded)return text.substring(i,i+4)==gControllerModel.substring(6) ? 1 : 0;
  }
  return -1;
}

// Firmware OTA files base URL (can be customized via -DOTA_BASE_URL in platformio.ini)
#ifndef OTA_BASE_URL
#define OTA_BASE_URL "https://mehedycse.github.io/noxbrain_espupdate/"
#endif
constexpr char kOtaBaseUrl[] = OTA_BASE_URL;
extern const uint8_t kPublicCaBundle[] asm("_binary_x509_crt_bundle_start");
// After an OTA update the new firmware is kept only if it reaches Wi-Fi and
// Firebase within 10 minutes; otherwise the bootloader returns to the
// previous firmware. Web-flashed firmware is never in this pending state.
void gatewayRollbackTick() {
  static int8_t pending=-1;
  if(pending==0)return;
  if(pending<0) {
    esp_ota_img_states_t state;const esp_partition_t *running=esp_ota_get_running_partition();
    pending=(running && esp_ota_get_state_partition(running,&state)==ESP_OK && state==ESP_OTA_IMG_PENDING_VERIFY)?1:0;
    if(!pending)return;
    Serial.println("OTA_IMAGE_PENDING_VERIFY");
  }
  if(gCloudReady){esp_ota_mark_app_valid_cancel_rollback();pending=0;Serial.println("OTA_IMAGE_CONFIRMED");return;}
  if(millis()>10UL*60UL*1000UL){Serial.println("OTA_IMAGE_NOT_CONFIRMED_ROLLING_BACK");esp_ota_mark_app_invalid_rollback_and_reboot();}
}
void gatewayOta(JsonVariantConst payload) {
  String url=payload["firmware_url"] | "", expected=payload["sha256"] | "", family=payload["chip_family"] | "";
  size_t size=payload["image_size"] | size_t(0);
#if CONFIG_IDF_TARGET_ESP32S3
  const char *target="ESP32-S3";const uint16_t chip=9;
#else
  const char *target="ESP32";const uint16_t chip=0;
#endif
  bool validHash=expected.length()==64;for(size_t i=0;i<expected.length();++i)validHash=validHash && isxdigit(expected[i]);expected.toLowerCase();
  if(!url.startsWith(kOtaBaseUrl) || url.indexOf('@')>=0 || url.indexOf("..")>=0 || family!=target || !validHash || size<24 || size>ESP.getFreeSketchSpace()) {
    gatewayResult("failed","OTA requires the official update site, matching chip family, image size and SHA-256.");return;
  }
  // Status LED blinks white (0.5 s on/off) while the update downloads and is
  // written; the normal status colour returns if it fails, a restart follows
  // if it succeeds. LED only: the download and checks are unchanged.
  auto otaLed=[]{static uint32_t at=0;if(millis()-at<250)return;at=millis();if((millis()/500)%2==0)setStatusLed(24,24,24);else setStatusLed(0,0,0);};
  setStatusLed(24,24,24);
  // Archive the day before the download: that is a database request, and its
  // TLS link must not be open next to the download's (memory).
  saveDailySummaryToFlash();gatewayArchiveDay(gSummaryDay);
  // GitHub Pages is not a Google host: trust the public CA bundle here only.
  // Free the kept-alive database link first: two TLS sessions may not fit.
  resetDatabaseConnection();
  WiFiClientSecure client;client.setCACertBundle(kPublicCaBundle);HTTPClient http;http.setTimeout(10000);
  if(!http.begin(client,url) || http.GET()!=200 || http.getSize()!=int(size)) {http.end();gatewayResult("failed","OTA download or image length verification failed.");return;}
  auto *stream=http.getStreamPtr();uint8_t buffer[1024];
  // The 24-byte header gets the same patience as the body below, and for the
  // same reason: a secure client's Stream timeout stays at 1 s, so one
  // readBytes() call comes back short whenever the link pauses, and a short
  // read was then reported as the wrong chip. Measured on a gateway with a
  // struggling uplink: the update failed with "belongs to a different chip"
  // and the very next attempt, same file, same chip, downloaded and installed.
  size_t initial=0;uint32_t headerData=millis();
  while(initial<24) {
    gLoopAliveAt=millis();otaLed();
    const size_t count=stream->readBytes(buffer+initial,24-initial);
    if(count){initial+=count;headerData=millis();continue;}
    if(!client.connected() && !client.available())break;
    if(millis()-headerData>=20000)break;
  }
  // Three different faults used to share one sentence, and only the last of
  // them was about the chip at all.
  if(initial!=24) {http.end();gatewayResult("failed","The update stopped while the gateway was still reading the start of the image. The download did not get through; check the gateway's Internet connection and try again.");return;}
  if(buffer[0]!=0xe9) {http.end();gatewayResult("failed","What arrived is not an ESP firmware image. The download was most likely cut short on the way; try again.");return;}
  if((uint16_t(buffer[12])|(uint16_t(buffer[13])<<8))!=chip) {http.end();gatewayResult("failed","Firmware image header belongs to a different chip.");return;}
  if(!Update.begin(size)) {http.end();gatewayResult("failed","No valid OTA partition. Flash the correct partition layout using the website first.");return;}
  mbedtls_sha256_context hash;mbedtls_sha256_init(&hash);mbedtls_sha256_starts_ret(&hash,0);
  mbedtls_sha256_update_ret(&hash,buffer,initial);size_t written=Update.write(buffer,initial);
  // readBytes() gives up after the Stream timeout, which stays at 1 s for a
  // secure client (HTTPClient's setTimeout only sets the TLS one). A pause of
  // more than 1 s in the download used to end it ("integrity failed" after
  // 6-9 s, measured twice). Only 20 s without any data counts as a stall.
  const uint32_t started=millis();uint32_t lastData=started;const char *stop="";
  while(written<size) {
    gLoopAliveAt=millis();
    otaLed();
    if(millis()-started>=180000){stop="total time";break;}
    size_t want=min(size-written,sizeof(buffer));size_t count=stream->readBytes(buffer,want);
    if(!count) {
      if(!client.connected() && !client.available()){stop="connection closed";break;}
      if(millis()-lastData>=20000){stop="no data for 20 s";break;}
      continue;
    }
    lastData=millis();mbedtls_sha256_update_ret(&hash,buffer,count);
    size_t actual=Update.write(buffer,count);written+=actual;if(actual!=count){stop="flash write";break;}
  }
  uint8_t digest[32];mbedtls_sha256_finish_ret(&hash,digest);mbedtls_sha256_free(&hash);http.end();
  char hex[65];for(int i=0;i<32;++i)snprintf(hex+i*2,3,"%02x",digest[i]);
  diagLog("OTA_DOWNLOAD written=%u size=%u ms=%u stop=%s update_error=%u hash_ok=%d",unsigned(written),unsigned(size),unsigned(millis()-started),stop,unsigned(Update.getError()),int(expected==hex));
  if(written!=size || expected!=hex) {Update.abort();gatewayResult("failed",String("OTA download incomplete or changed (")+(*stop?stop:"SHA-256 mismatch")+"). Existing firmware remains active.");return;}
  if(!Update.end(false)) {gatewayResult("failed","OTA activation failed.");return;}
  gatewayResult("confirmed","Firmware image and chip verified. Restarting; verify the running version after reconnect.");
  delay(250);ESP.restart();
}
// --- RS485 controller link -------------------------------------------------
void gatewayRs485Open(uint32_t baud) {
  if(gRs485Open)Serial1.end();
  Serial1.setRxBufferSize(1024);
  Serial1.begin(baud,SERIAL_8N1,kRs485RxPin,kRs485TxPin);
  while(Serial1.available())Serial1.read();
  gRs485Open=true;
}
void gatewayRs485Close() {
  if(gRs485Open){Serial1.end();gRs485Open=false;}
}
// Complete Modbus reply at the start of buf for address addr: its size, 0 if
// more bytes are needed, -1 if buf[0] cannot start a reply.
int gatewayRs485FrameSize(const uint8_t *buf,size_t length,uint8_t addr) {
  if(length<1)return 0;
  if(buf[0]!=addr)return -1;
  if(length<3)return 0;
  const uint8_t function=buf[1];
  const size_t size=function==3 ? size_t(buf[2])+5 : (function==6 || function==16 ? 8 : (function&0x80 ? 5 : 0));
  if(size<5)return -1;
  if(length<size)return 0;
  const uint16_t expected=buf[size-2]|(uint16_t(buf[size-1])<<8);
  return modbusCrc(buf,size-2)==expected ? int(size) : -1;
}
// Wire replies enter the same queue and decoder as Bluetooth notifications.
// The decoder expects address 0xFF, so a reply from the controller's own
// address is given 0xFF and a new CRC; nothing else in the frame changes.
void gatewayRs485Pump() {
  static uint8_t buf[512];static size_t length=0;
  if(!gRs485Open){length=0;return;}
  while(Serial1.available() && length<sizeof(buf))buf[length++]=uint8_t(Serial1.read());
  while(length>0) {
    const int size=gatewayRs485FrameSize(buf,length,gRs485Addr);
    if(size==0){if(length==sizeof(buf))length=0;break;}
    if(size<0){memmove(buf,buf+1,--length);continue;}
    if(gRs485Addr!=0xff){buf[0]=0xff;const uint16_t crc=modbusCrc(buf,size-2);buf[size-2]=crc&0xff;buf[size-1]=crc>>8;}
    for(int offset=0;offset<size && gRxQueue;offset+=sizeof(GatewayRx::data)) {
      GatewayRx packet;packet.receivedAt=millis();packet.srne=true;packet.generation=gControllerGeneration;
      packet.size=uint16_t(min(int(sizeof(GatewayRx::data)),size-offset));memcpy(packet.data,buf+offset,packet.size);
      xQueueSend(gRxQueue,&packet,0);
    }
    ++gDiagNotes;
    length-=size;memmove(buf,buf+size,length);
  }
}
// Finds the controller on the wire: reads the live block (0x0100, 10
// registers) at each common speed and address until a valid reply arrives.
bool gatewayRs485Search(uint32_t &foundBaud,uint8_t &foundAddr) {
  static const uint32_t kBauds[]={9600,115200,19200,4800,38400};
  static const uint8_t kAddrs[]={1,0xff};
  for(uint32_t baud:kBauds) {
    gatewayRs485Open(baud);
    for(uint8_t addr:kAddrs) {
      uint8_t request[]={addr,0x03,0x01,0x00,0x00,0x0a,0x00,0x00};
      const uint16_t crc=modbusCrc(request,6);request[6]=crc&0xff;request[7]=crc>>8;
      while(Serial1.available())Serial1.read();
      Serial1.write(request,sizeof(request));Serial1.flush();
      uint8_t reply[64];size_t length=0;const uint32_t started=millis();
      while(millis()-started<400) {
        while(Serial1.available() && length<sizeof(reply))reply[length++]=uint8_t(Serial1.read());
        // Skip any noise in front of the reply.
        while(length>0 && reply[0]!=addr){memmove(reply,reply+1,--length);}
        const int size=gatewayRs485FrameSize(reply,length,addr);
        if(size>0 && reply[1]==0x03 && reply[2]==20) {
          diagLog("RS485_FOUND baud=%u addr=%u",unsigned(baud),unsigned(addr));
          foundBaud=baud;foundAddr=addr;return true;
        }
        if(size<0 && length)memmove(reply,reply+1,--length);
        delay(5);
      }
    }
  }
  gatewayRs485Close();
  diagLog("RS485_NOT_FOUND");
  return false;
}
void gatewayDrainRx() {
  gatewayRs485Pump();
  GatewayRx packet;
  while(xQueueReceive(gRxQueue,&packet,0)==pdTRUE) {
    if(millis()-packet.receivedAt>5000){if(packet.srne)gSrneRxLength=0;else gJkFrameLength=0;continue;} // Never relabel an old queued packet as a fresh measurement.
    if(packet.generation!=(packet.srne?gControllerGeneration:gBmsGeneration) || !(packet.srne?gControllerEnabled:gBmsEnabled))continue;
    gDecodedReceivedAt=packet.receivedAt;
    if(packet.srne) {
      if(gSrneRxLength+packet.size>sizeof(gSrneRx))gSrneRxLength=0;
      if(packet.size>sizeof(gSrneRx))continue;
      memcpy(gSrneRx+gSrneRxLength,packet.data,packet.size);gSrneRxLength+=packet.size;
      while(gSrneRxLength>=5) {
        // A Modbus slave answers from the address the request was sent to, so
        // a Bluetooth reply carries whatever the address ladder is currently
        // trying; RS485 replies were already given 0xFF by the pump. Matching
        // only 0xFF here threw away every reply from 0x01 or 0x60, which made
        // the ladder unable to settle on any address but the one it starts on.
        // The BT-TH module's own status frame, sent once per connect:
        // 01 01 08 S and two check bytes, the first of which is the Modbus CRC
        // low byte of those four. S=01 while the module is locked for want of
        // its Bluetooth PIN, 00 once paired (seen on the Shiner2430B's module).
        // It is no Modbus reply, so it is taken here rather than mis-read.
        if(!srneRs485() && gSrneRx[0]==0x01 && gSrneRx[1]==0x01 && gSrneRx[2]==0x08) {
          if(gSrneRxLength<6)break;
          if(gSrneRx[3]<=1 && uint8_t(modbusCrc(gSrneRx,4)&0xff)==gSrneRx[4]) {
            gSrneLocked=gSrneRx[3]==1;
            if(!gSrneLockLogged){gSrneLockLogged=true;diagLog("CTRL_MODULE_%s pin_saved=%d",gSrneLocked?"LOCKED":"UNLOCKED",gCtrlPin>=0);}
            if(gSrneLocked) {
              gLinkError=gCtrlPin>=0
                ? "The controller's Bluetooth module is still locked after pairing, so the saved PIN is probably wrong. Enter the right PIN and select the controller again."
                : "This controller's Bluetooth module is locked until it is paired with its PIN. Enter the PIN in the app and select the controller again.";
              gCtrlVerdict=gLinkError;
            }
            gSrneRxLength-=6;memmove(gSrneRx,gSrneRx+6,gSrneRxLength);continue;
          }
        }
        const uint8_t wantAddress=srneRs485()?uint8_t(0xff):gSrneBleAddr;
        if(gSrneRx[0]!=wantAddress) {
          // Bytes arrive but never parse when the module answers from an
          // address that was never requested: say so once per link, or the
          // only evidence is a silent ladder and a generic timeout.
          if(!gSrneRxOddLogged){gSrneRxOddLogged=true;
            // The bytes themselves, so a report shows whether this is a reply,
            // an exception or the module's own greeting -- not just byte one.
            char hex[49];size_t n=0;for(size_t i=0;i<gSrneRxLength && i<24 && n<sizeof(hex)-2;++i)n+=snprintf(hex+n,sizeof(hex)-n,"%02x",gSrneRx[i]);hex[n]=0;
            diagLog("CTRL_RX_ADDR got=0x%02x want=0x%02x len=%u hex=%s",unsigned(gSrneRx[0]),unsigned(wantAddress),unsigned(gSrneRxLength),hex);}
          memmove(gSrneRx,gSrneRx+1,--gSrneRxLength);continue;}
        uint8_t function=gSrneRx[1];
        size_t size=function==3 ? size_t(gSrneRx[2])+5 : (function==6 || function==16 ? 8 : (function&0x80 ? 5 : 0));
        if(size<5 || size>sizeof(gSrneRx)) {memmove(gSrneRx,gSrneRx+1,--gSrneRxLength);continue;}
        if(gSrneRxLength<size)break;
        uint16_t expected=gSrneRx[size-2]|(uint16_t(gSrneRx[size-1])<<8);
        if(modbusCrc(gSrneRx,size-2)!=expected) {memmove(gSrneRx,gSrneRx+1,--gSrneRxLength);continue;}
        // Every decoder below reads the 0xFF frame this firmware has always
        // handed them, so a verified reply from another address is relabelled
        // exactly as the RS485 pump relabels one: new address byte, new CRC.
        if(wantAddress!=0xff){gSrneRx[0]=0xff;const uint16_t fixed=modbusCrc(gSrneRx,size-2);gSrneRx[size-2]=fixed&0xff;gSrneRx[size-1]=fixed>>8;}
        // Address and CRC both check out, so the controller is answering here
        // whatever the frame turns out to say. That, not a decoded live
        // sample, is what settles the address ladder.
        gSrneAnsweredAt=gDecodedReceivedAt;
#ifdef NOXBRAIN_BENCH
        if(!(function==3 && (gSrneRx[2]==68 || gSrneRx[2]==70))) {
          String hex;for(size_t i=0;i<size && i<24;++i){char h[3];snprintf(h,3,"%02x",gSrneRx[i]);hex+=h;}
          BENCH_PORT.printf("BENCH_RX fn=%02x stage=%u cmd=%s %s\n",function,gLoadModeStage,gActiveCommandType.c_str(),hex.c_str());
        }
#endif
        // A parameter job owns its own exception, and so does a load sequence
        // still in flight -- its register reads and the one-second live read
        // interleave, so the last frame sent is no proof of whose refusal
        // this is. Only when neither is running may the live read claim it
        // and retry shorter; an exception belonging to none of them fails the
        // command that is running, as it always did.
        if(function&0x80) {if(!gatewayCtrlOnException() && !(gLoadModeStage==0 && srneLiveReadStepDown()))gatewayResult("failed","Controller rejected the Modbus command.");}
        else if(function==6 || function==16) gatewayCtrlOnWriteEcho(function,gSrneRx);
        else if(function==3) {
          const bool loadModeReply=gSrneRx[2]==2 && (gActiveCommandType=="load" || gActiveCommandType=="enable_manual_load" || gActiveCommandType=="restore_load_mode");
          if(loadModeReply && gLoadModeStage==3) {
            // Mode before manual: saved so the app can restore it later.
            uint16_t mode=(uint16_t(gSrneRx[3])<<8)|gSrneRx[4];
            if(mode==15)gatewayResult("confirmed","Controller manual load mode read back successfully.");
            else {gDailyStore.putInt("prev_load_mode",mode);sendSrneRegisterWrite(0xe01d,15,"manual_load_mode");gLoadModeStage=1;srneSendAfter(kSrneSendLoadMode,200);}
          }
          else if(loadModeReply && gLoadModeStage==4) {
            uint16_t mode=(uint16_t(gSrneRx[3])<<8)|gSrneRx[4];
            if(mode==uint16_t(gDailyStore.getInt("prev_load_mode",-1)))gatewayResult("confirmed","Controller load mode restored and read back successfully.");
            else gatewayResult("failed","Controller did not keep the restored load mode. Check it with the SRNE app.");
          }
          else if(loadModeReply && gLoadModeStage==1) {
            uint16_t mode=(uint16_t(gSrneRx[3])<<8)|gSrneRx[4];
            if(mode!=15)gatewayResult("failed","Controller DC load is not in manual mode. Explicitly enable manual load mode first.");
            else if(gActiveCommandType=="enable_manual_load")gatewayResult("confirmed","Controller manual load mode read back successfully.");
            // The controller's BLE module drops a frame that arrives right
            // after another one: pause, send only the load write, and let the
            // regular 1 s live read confirm the new output state.
            else {gLoadModeStage=2;srneSendAfter(kSrneSendLoadCommand,250);}
          }
          // Routing must never be stricter than the decoder it routes to.
          // publishSrneLive reads any block of 68 bytes or more, but an exact
          // 68-or-70 test sent anything longer to the settings branch, which
          // refuses it and returns without a word. No settings read asks for
          // more than 34 bytes, so 68 and above cannot belong to one.
          else if(gSrneRx[2]>=68)publishSrneLive(gSrneRx,size);
          else if(gSrneRx[2]==16)gatewayOnModel(gSrneRx,size);
          else if(gSrneRx[2]==6 || gSrneRx[2]==22)gatewayCtrlOnBlock(gSrneRx,size);
          else if(gSrneRx[2]==2)gatewayCtrlOnSwitch(gSrneRx);
          else if(gSrneRx[2]==32 || gSrneRx[2]==34)publishSrneSettings(gSrneRx,size);
          // A length no decoder claims used to disappear inside the settings
          // branch, which simply returns: name it once instead.
          else if(!gSrneRxLenLogged){gSrneRxLenLogged=true;diagLog("CTRL_RX_LEN bytes=%u",unsigned(gSrneRx[2]));}
        }
        gSrneRxLength-=size;memmove(gSrneRx,gSrneRx+size,gSrneRxLength);
      }
    } else if(gBmsJbd) {
      // JBD replies arrive in 20-byte pieces: join them, then take each
      // "DD cmd status len data sum 77" frame whose checksum matches.
      if(gJkFrameLength+packet.size>sizeof(gJkFrameBuffer))gJkFrameLength=0;
      memcpy(gJkFrameBuffer+gJkFrameLength,packet.data,packet.size);gJkFrameLength+=packet.size;
      while(gJkFrameLength>=7) {
        if(gJkFrameBuffer[0]!=0xdd) {memmove(gJkFrameBuffer,gJkFrameBuffer+1,--gJkFrameLength);continue;}
        const size_t size=size_t(gJkFrameBuffer[3])+7;
        if(gJkFrameLength<size)break;
        uint16_t sum=0;for(size_t i=2;i<size-3;++i)sum+=gJkFrameBuffer[i];
        const uint16_t expected=(uint16_t(gJkFrameBuffer[size-3])<<8)|gJkFrameBuffer[size-2];
        if(gJkFrameBuffer[size-1]!=0x77 || uint16_t(0x10000-sum)!=expected) {memmove(gJkFrameBuffer,gJkFrameBuffer+1,--gJkFrameLength);continue;}
        // Checksum and tail both check out, so this BMS is answering whatever
        // the frame turns out to say -- the counterpart of gSrneAnsweredAt.
        gBmsAnsweredAt=gDecodedReceivedAt;
        // Status 0 = OK; anything else (e.g. 0x81 for a locked register) is ignored.
        if(gJkFrameBuffer[2]==0)publishJbdFrame(gJkFrameBuffer,size);
        else if(!gBmsRejectLogged){gBmsRejectLogged=true;diagLog("BMS_JBD_STATUS cmd=0x%02x status=0x%02x",unsigned(gJkFrameBuffer[1]),unsigned(gJkFrameBuffer[2]));}
        gJkFrameLength-=size;memmove(gJkFrameBuffer,gJkFrameBuffer+size,gJkFrameLength);
      }
    } else {
      if(gJkFrameLength+packet.size>sizeof(gJkFrameBuffer))gJkFrameLength=0;
      memcpy(gJkFrameBuffer+gJkFrameLength,packet.data,packet.size);gJkFrameLength+=packet.size;
      while(gJkFrameLength>=300) {
        bool header=gJkFrameBuffer[0]==0x55 && gJkFrameBuffer[1]==0xaa && gJkFrameBuffer[2]==0xeb && gJkFrameBuffer[3]==0x90;
        size_t size=0;
        if(header) {
          for(size_t candidate: {size_t(300),size_t(320)}) {
            if(gJkFrameLength<candidate)continue;
            uint8_t sum=0;for(size_t i=0;i<candidate-1;++i)sum+=gJkFrameBuffer[i];
            if(sum==gJkFrameBuffer[candidate-1]) {size=candidate;break;}
          }
          if(!size && gJkFrameLength<320)break;
        }
#ifdef NOXBRAIN_BENCH
        if(header && !size)BENCH_PORT.printf("BENCH_JK header but checksum fails at 300/320 (buffered=%u)\n",unsigned(gJkFrameLength));
        if(size)BENCH_PORT.printf("BENCH_JK frame type=0x%02x size=%u profile=%s\n",gJkFrameBuffer[4],unsigned(size),gJkProfile.c_str());
#endif
        if(!size) {
          if(header && !gBmsRejectLogged){gBmsRejectLogged=true;diagLog("BMS_JK_CHECKSUM buffered=%u",unsigned(gJkFrameLength));}
          memmove(gJkFrameBuffer,gJkFrameBuffer+1,--gJkFrameLength);continue;}
        // A whole frame with a good checksum: the BMS is answering, whether or
        // not a layout can read it.
        gBmsAnsweredAt=gDecodedReceivedAt;
        bool decoded;
        if(gJkProfile=="auto") {
          // Auto-detect: only the layout whose cells sum to the pack voltage
          // and whose fields pass validation is accepted and kept.
          gJkProfile="jk02_32";
          decoded=publishJkLive(gJkFrameBuffer,size);
          if(!decoded) {gJkProfile="jk02_24";decoded=publishJkLive(gJkFrameBuffer,size);if(!decoded)gJkProfile="auto";}
        } else decoded=publishJkLive(gJkFrameBuffer,size);
        // Only the 0x02 cell/live frame is meant to decode. Type 0x01
        // (settings) and 0x03 (device info, which sendJkDeviceInfo asks for on
        // every connect) are ignored on purpose, so counting their refusal as
        // a fault put a false link error on every healthy JK BMS.
        if(!decoded && gJkFrameBuffer[4]==0x02 && !gBmsRejectLogged) {
          gBmsRejectLogged=true;
          diagLog("BMS_JK_UNDECODED type=0x%02x size=%u profile=%s",unsigned(gJkFrameBuffer[4]),unsigned(size),gJkProfile.c_str());
          gLinkError="The BMS answers on Bluetooth, but its data frames do not match any layout this firmware knows. Pick the BMS type by hand instead of Auto-detect.";
        }
        gJkFrameLength-=size;memmove(gJkFrameBuffer,gJkFrameBuffer+size,gJkFrameLength);
      }
    }
  }
}

// Sends the frame srneSendAfter() queued, once its gap has passed. A link
// that dropped in the meantime cancels it: the reply it waits for can no
// longer arrive, and the parameter machinery retries the whole step anyway.
void srneSendPendingTick() {
  if(!gSrneSendPending || int32_t(millis()-gSrneSendAt)<0)return;
  const uint8_t what=gSrneSendPending;gSrneSendPending=kSrneSendNone;
  if(!srneLinkUp() || !srneWriterReady())return;
  if(what==kSrneSendSettingsBlock)sendSrneSettingsBlockRead();
  else if(what==kSrneSendLoadMode)sendSrneRegisterRead(0xe01d,"load_mode");
  else if(what==kSrneSendLoadCommand)sendSrneLoadCommand(gLoadDesired);
  else if(what==kSrneSendRestoreMode) {
    const int previous=gDailyStore.getInt("prev_load_mode",-1);
    if(previous<0 || previous>17 || previous==15){gatewayResult("failed","No saved previous load mode. Set the load mode with the SRNE app or controller buttons.");return;}
    sendSrneRegisterWrite(0xe01d,uint16_t(previous),"restore_load_mode");
    srneSendAfter(kSrneSendLoadMode,200);
  }
}
// Answers a controller module's pairing request with the PIN the user saved.
// Runs on the NimBLE host task, so it only reads gCtrlPin and sets a flag.
class SrneSecurityCallbacks : public NimBLEClientCallbacks {
  uint32_t onPassKeyRequest() override { gCtrlPinAsked=true; return gCtrlPin>=0?uint32_t(gCtrlPin):0; }
  bool onConfirmPIN(uint32_t) override { return gCtrlPin>=0; }
};
SrneSecurityCallbacks gSrneSecurity;
void gatewayDisconnect(bool controller) {
  NimBLEClient *&client=controller ? gSrneClient : gJkClient;
  // A disconnected or replaced controller must never inherit the previous
  // controller's verified USER profile: settings must be read again first.
  if(controller) {++gControllerGeneration;gSrneWriter=nullptr;gSrneNotifier=nullptr;gLatestSrneSampleAt=0;gSrneAnsweredAt=0;gSrneLiveCount=0x23;gSrneLastTxLive=false;gSrneRxLength=0;gSrneRxOddLogged=false;gSrneRxLenLogged=false;gSrneLiveRejectLogged=false;gSrneWriteFailLogged=false;gSrneLocked=false;gSrneLockLogged=false;gSrneSendPending=kSrneSendNone;gLastEnergySample=0;gActualBatteryType=-1;gSettingsReadAt=0;gControllerModelReported="";gCalcLastAt=0;
    memset(gCtrlRegAt,0,sizeof(gCtrlRegAt));gCtrlSwitchAt=0;gCtrlSwitchSupported=true;gatewayRs485Close();}
  else {++gBmsGeneration;gJkChar=nullptr;gJbdWriter=nullptr;gBmsJbd=false;gJbdCellsAt=0;gJbdCellCount=0;gJkInitialized=false;gLatestBmsSampleAt=0;gBmsAnsweredAt=0;gBmsRejectLogged=false;gLastBmsEnergyAt=0;gJkFrameLength=0;}
  if(client) {if(client->isConnected())client->disconnect();NimBLEDevice::deleteClient(client);client=nullptr;}
}
bool gatewayConnect(bool controller) {
  const String mac=controller ? gConfigControllerMac : gConfigBmsMac;
  if(!gatewayMac(mac))return false;
  gatewayDisconnect(controller);
  // A weak signal can need several seconds to form the link. If a link forms
  // after a timeout it must be dropped, or the device stays connected to this
  // gateway and stops advertising until the gateway restarts.
  NimBLEClient *client=NimBLEDevice::createClient();client->setConnectTimeout(6);
  if(controller) {
    client->setClientCallbacks(&gSrneSecurity,false);gCtrlSecureFailed=false;
    // Pairing with a passkey only for a controller the user gave a PIN for;
    // every other link keeps NimBLE's defaults exactly as before.
    // No bonding: the BT-TH module keeps no bond (the phone showed none
    // after pairing either), so a stored key only made every reconnect try
    // a re-encryption the module could not complete. Pair afresh each time.
    if(gCtrlPin>=0){NimBLEDevice::setSecurityAuth(false,true,true);NimBLEDevice::setSecurityIOCap(BLE_HS_IO_KEYBOARD_ONLY);
      // Clear a stale key from 1.1.34/1.1.35 while there is no link to lose.
      // deleteBond is ble_gap_unpair, which terminates any open connection to
      // that address first. 1.1.36 to 1.1.38 called it just after connecting,
      // so it cut the link it had only just made and every pairing attempt
      // ended "link dropped" before the module could ask for the PIN. The
      // bonded address type is unknown here, so clear both.
      NimBLEDevice::deleteBond(NimBLEAddress(std::string(mac.c_str()),BLE_ADDR_PUBLIC));
      NimBLEDevice::deleteBond(NimBLEAddress(std::string(mac.c_str()),BLE_ADDR_RANDOM));}
  }
  int8_t &kind=controller?gCtrlAddrKind:gBmsAddrKind;
  auto tryKind=[&](uint8_t type){bool r=client->connect(NimBLEAddress(std::string(mac.c_str()),type));if(!r && client->isConnected())client->disconnect();return r;};
  // A known device uses only the address type that worked before: one attempt,
  // not two 6 s blocks that froze the loop (and so the cloud link) while
  // connecting. The first connect (kind unknown) still probes both types.
  bool ok=false;uint8_t used=BLE_ADDR_PUBLIC;
  if(kind==1){used=BLE_ADDR_RANDOM;ok=tryKind(BLE_ADDR_RANDOM);}
  else if(kind==0){ok=tryKind(BLE_ADDR_PUBLIC);}
  else {ok=tryKind(BLE_ADDR_PUBLIC);if(!ok){used=BLE_ADDR_RANDOM;ok=tryKind(BLE_ADDR_RANDOM);}}
#ifdef NOXBRAIN_BENCH
  BENCH_PORT.printf("BENCH_CONNECT %s %s link=%d\n",controller?"controller":"bms",mac.c_str(),ok);
#endif
  diagLog("%s_CONNECT %s link=%d interval=%u",controller?"CTRL":"BMS",mac.c_str(),ok,ok?unsigned(client->getConnInfo().getConnInterval()):0u);
  if(!ok) {
    gLinkError=String(controller?"Controller":"BMS")+" did not accept a Bluetooth link. It is usually still connected to a phone app (close it fully), switched off, or too far away.";
    kind=-1;gDailyStore.putChar(controller?"ctrl_addr":"bms_addr",-1);NimBLEDevice::deleteClient(client);return false;}
  const int8_t newKind=(used==BLE_ADDR_RANDOM)?1:0;
  if(kind!=newKind){kind=newKind;gDailyStore.putChar(controller?"ctrl_addr":"bms_addr",newKind);}
  if(controller) {
    gSrneClient=client;gControllerLinkedAt=millis();
    if(gCtrlPin>=0) {
      // This module passes data only over a paired link: pair with the saved
      // PIN before using its services. Never through secureConnection(): it
      // waits with portMAX_DELAY, and a module that did not answer froze the
      // whole loop -- no cloud, no commands, no OTA -- on every boot. Start
      // pairing and wait at most 12 s for the link to become encrypted. The
      // stale bond was already cleared before the link was opened: clearing it
      // here would terminate this connection (see gatewayConnect above).
      bool secured=false;const char *why="no reply";
      const int rc=NimBLEDevice::startSecurity(client->getConnId());
      if(rc!=0 && rc!=BLE_HS_EALREADY) why="could not start";
      else {
        const uint32_t pairStart=millis();
        while(millis()-pairStart<12000) {
          if(!client->isConnected()){why="link dropped";break;}
          if(client->getConnInfo().isEncrypted()){secured=true;break;}
          delay(50);
        }
      }
      if(secured)diagLog("CTRL_SECURE ok=1");else diagLog("CTRL_SECURE ok=0 why=%s",why);
      if(!secured) {
        gCtrlSecureFailed=true;
        gLinkError="The controller asks for a Bluetooth PIN and pairing with the saved PIN failed. Check the PIN and select the controller again.";
        gCtrlVerdict=gLinkError;
        NimBLEDevice::deleteBond(client->getPeerAddress());
        gatewayDisconnect(true);return false;
      }
    }
    auto *writeService=client->getService(NimBLEUUID("ffd0"));auto *notifyService=client->getService(NimBLEUUID("fff0"));
    gSrneWriter=writeService ? writeService->getCharacteristic(NimBLEUUID("ffd1")) : nullptr;
    gSrneNotifier=notifyService ? notifyService->getCharacteristic(NimBLEUUID("fff1")) : nullptr;
#ifdef NOXBRAIN_BENCH
    BENCH_PORT.printf("BENCH_SERVICES controller writer=%d notifier=%d\n",gSrneWriter!=nullptr,gSrneNotifier!=nullptr);
#endif
    if(!gSrneWriter || !gSrneNotifier || !gSrneNotifier->canNotify() || !gSrneNotifier->subscribe(true,onNotify,gSrneRespMode==1)) {
      // Missing services mean the Bluetooth module is a different generation
      // from the one this firmware speaks to, which no amount of retrying or
      // moving closer will change -- say so instead of blaming the range.
      gLinkError=(!gSrneWriter || !gSrneNotifier)
        ? "Bluetooth link opened, but this module does not offer the SRNE data service (ffd0/fff0). It is a different Bluetooth module than this firmware supports."
        : "Bluetooth link opened and the SRNE service was found, but the module refused to start sending data.";
      diagLog("CTRL_SERVICES_FAIL writer=%d notifier=%d",gSrneWriter!=nullptr,gSrneNotifier!=nullptr);gatewayDisconnect(true);return false;}
    srneAddressProbeReset();
    sendSrneLiveRead();
  } else {
    gJkClient=client;gBmsLinkedAt=millis();auto *service=client->getService(NimBLEUUID("ffe0"));
    // JBD / Xiaoxiang: chosen as "jbd", or found by "auto" (FF00 service, no JK FFE0).
    // A JBD clone that also advertises the JK service (ffe0) without its data
    // characteristic (ffe1) used to be taken for a JK and then sat silent, so
    // auto-detect looks for ff00 whenever ffe1 is not there to talk to.
    auto *jbdService=(gJkProfile=="jbd" || (gJkProfile=="auto" && (!service || !service->getCharacteristic(NimBLEUUID("ffe1")))))
      ? client->getService(NimBLEUUID("ff00")) : nullptr;
    if(jbdService) {
      gBmsJbd=true;gJkProfile="jbd";gJbdNextRequest=0x04;
      gJkChar=jbdService->getCharacteristic(NimBLEUUID("ff01"));
      gJbdWriter=jbdService->getCharacteristic(NimBLEUUID("ff02"));
      const bool subscribed=gJkChar && gJbdWriter && gJkChar->canNotify() && gJkChar->subscribe(true,onNotify,true);
      diagLog("BMS_JBD subscribed=%d",subscribed);
      if(!subscribed) {gLinkError="Bluetooth link opened to the JBD BMS, but it refused to start sending data.";gatewayDisconnect(false);return false;}
      sendJbdRead();gJkInitialized=true;
      gLinkError="";
      return true;
    }
    if(gJkProfile=="jbd") {gLinkError="Bluetooth link opened, but this BMS does not offer the JBD service (ff00). Pick a different BMS type.";diagLog("BMS_JBD_SERVICE_MISSING");gatewayDisconnect(false);return false;}
    gJkChar=service ? service->getCharacteristic(NimBLEUUID("ffe1")) : nullptr;
#ifdef NOXBRAIN_BENCH
    BENCH_PORT.printf("BENCH_SERVICES bms char=%d\n",gJkChar!=nullptr);
    if(gJkChar)BENCH_PORT.printf("BENCH_JK props read=%d write=%d write_nr=%d notify=%d indicate=%d handle=%u mtu=%u\n",
      gJkChar->canRead(),gJkChar->canWrite(),gJkChar->canWriteNoResponse(),gJkChar->canNotify(),gJkChar->canIndicate(),gJkChar->getHandle(),client->getMTU());
#endif
    // JK ignores a CCCD write without response (NimBLE's default), so the
    // link stays up but no notification ever arrives: write it with response.
    const bool subscribed=gJkChar && gJkChar->canNotify() && gJkChar->subscribe(true,onNotify,true);
#ifdef NOXBRAIN_BENCH
    BENCH_PORT.printf("BENCH_JK subscribe=%d\n",subscribed);
#endif
    if(!subscribed) {gLinkError=gJkChar?String("Bluetooth link opened to the BMS, but it refused to start sending data."):String("Bluetooth link opened, but this BMS does not offer the JK service (ffe0). Pick a different BMS type.");diagLog("BMS_SUBSCRIBE_FAIL char=%d",gJkChar!=nullptr);gatewayDisconnect(false);return false;}
    sendJkDeviceInfo();sendJkRead();gJkInitialized=true;
  }
  gLinkError="";
  return true;
}
// Remote Wi-Fi change. The new network is only committed to flash after the
// gateway reaches Firebase through it; otherwise the previous one is restored.
uint8_t gWifiTrial=0;            // 0 = none, 1 = trying new, 2 = restoring previous
uint32_t gWifiTrialAt=0;
String gWifiPrevSsid,gWifiPrevPass,gWifiTrialError;
void gatewayWifiTrialStart(const String &ssid,const String &pass) {
  gWifiPrevSsid=gWifiSsid;gWifiPrevPass=gWifiPassword;gWifiSsid=ssid;gWifiPassword=pass;
  gWifiTrial=1;gWifiTrialAt=millis();gWifiAttemptAt=millis();
  gCloudReady=false;gNextCloudHeartbeatAt=0;resetDatabaseConnection();
  WiFi.disconnect(false);WiFi.begin(gWifiSsid.c_str(),gWifiPassword.c_str());
}
void gatewayWifiTrialTick() {
  if(!gWifiTrial)return;
  const bool online=WiFi.status()==WL_CONNECTED && WiFi.SSID()==gWifiSsid && gCloudReady && millis()-gWifiTrialAt>3000;
  if(gWifiTrial==1) {
    if(online) {
      gDailyStore.putString("wifi_ssid",gWifiSsid);secretPut("wifi_pass",gWifiPassword);
      gWifiTrial=0;gatewayResult("confirmed","Gateway joined the new Wi-Fi and reached Firebase.");return;
    }
    if(millis()-gWifiTrialAt>45000) {
      gWifiTrialError=WiFi.status()==WL_CONNECTED?"joined the network but could not reach Firebase":"could not join (check the password and 2.4 GHz signal)";
      gWifiSsid=gWifiPrevSsid;gWifiPassword=gWifiPrevPass;
      gWifiTrial=2;gWifiTrialAt=millis();gWifiAttemptAt=millis();
      gCloudReady=false;gNextCloudHeartbeatAt=0;resetDatabaseConnection();
      WiFi.disconnect(false);WiFi.begin(gWifiSsid.c_str(),gWifiPassword.c_str());
    }
  } else if(online) {
    gWifiTrial=0;gatewayResult("failed","The new Wi-Fi "+gWifiTrialError+". The previous Wi-Fi was restored.");
  }
}

// Remote Firebase change, sent through the current Firebase. The new project
// is committed only after the gateway reaches it with its device account;
// otherwise the previous Firebase is restored and the failure reported there.
uint8_t gCloudTrial=0;           // 0 = none, 1 = trying new, 2 = restoring previous
uint32_t gCloudTrialAt=0;
String gCloudPrevUrl,gCloudPrevKey,gCloudPrevEmail,gCloudPrevPass,gCloudTrialError;
void gatewayCloudSwitch(const String &url,const String &key,const String &email,const String &pass) {
  gFirebaseDatabaseUrl=url;gFirebaseApiKey=key;gFirebaseDeviceEmail=email;gFirebaseDevicePassword=pass;
  gFirebaseIdToken="";gLastFirebaseAuthAttempt=0;gCloudReady=false;gNextCloudHeartbeatAt=0;resetDatabaseConnection();
}
void gatewayCloudTrialTick() {
  if(!gCloudTrial)return;
  const bool online=gCloudReady && millis()-gCloudTrialAt>3000;
  if(gCloudTrial==1) {
    if(online) {
      gatewaySaveCredentials();gCloudTrial=0;
      gatewayResult("confirmed","Gateway moved to the new Firebase.");return;
    }
    if(millis()-gCloudTrialAt>60000) {
      gCloudTrialError=gNetworkError.length()?gNetworkError:String("new Firebase was unreachable");
      gCloudTrial=2;gCloudTrialAt=millis();
      gatewayCloudSwitch(gCloudPrevUrl,gCloudPrevKey,gCloudPrevEmail,gCloudPrevPass);
    }
  } else if(online) {
    gCloudTrial=0;gatewayResult("failed","New Firebase failed ("+gCloudTrialError+"). The previous Firebase was restored.");
  }
}

// Wi-Fi networks added manually from the app (e.g. before a router change).
// When the current network is unavailable the gateway scans and joins the
// next saved network that is actually visible. Passwords stay on the gateway.
struct SavedWifi { String ssid, pass; };
std::vector<SavedWifi> gSavedWifi;
constexpr size_t kMaxSavedWifi=3;
int8_t gWifiCandidate=-1; // -1 = current network, otherwise index into gSavedWifi
void gatewayLoadSavedWifi() {
  gSavedWifi.clear();JsonDocument d;
  if(deserializeJson(d,secretGet("wifi_saved")))return;
  for(JsonObject o:d.as<JsonArray>()) {
    const String ssid=o["ssid"] | "", pass=o["pass"] | "";
    if(ssid.length() && gSavedWifi.size()<kMaxSavedWifi)gSavedWifi.push_back({ssid,pass});
  }
}
void gatewayStoreSavedWifi() {
  JsonDocument d;JsonArray rows=d.to<JsonArray>();
  for(const SavedWifi &w:gSavedWifi){JsonObject o=rows.add<JsonObject>();o["ssid"]=w.ssid;o["pass"]=w.pass;}
  String raw;serializeJson(d,raw);secretPut("wifi_saved",raw);
}
void gatewayWifiReconnect() {
  if(gWifiTrial || gSavedWifi.empty()){gWifiCandidate=-1;WiFi.begin(getWifiSsid(),getWifiPassword());return;}
  WiFi.disconnect(false);
  const int count=WiFi.scanNetworks(false,false);
  auto visible=[&](const String &s){for(int i=0;i<count;++i)if(WiFi.SSID(i)==s)return true;return false;};
  // Try the next visible network after the one tried last: current, then saved.
  const int total=int(gSavedWifi.size())+1;
  for(int step=1;step<=total;++step) {
    const int idx=((gWifiCandidate+1+step)%total)-1;
    const String &ssid=idx<0?gWifiSsid:gSavedWifi[idx].ssid;
    if(count>0 && ssid.length() && visible(ssid)) {
      const String &pass=idx<0?gWifiPassword:gSavedWifi[idx].pass;
      gWifiCandidate=idx;WiFi.scanDelete();WiFi.begin(ssid.c_str(),pass.c_str());
      Serial.printf("WIFI_TRY %s\n",idx<0?"current":"saved");return;
    }
  }
  // Nothing known is visible (router still booting): keep trying the current one.
  WiFi.scanDelete();gWifiCandidate=-1;WiFi.begin(getWifiSsid(),getWifiPassword());
}
// A saved network becomes the current one only after Firebase is reached
// through it; the previous network is kept as a saved fallback.
void gatewayWifiPromote() {
  if(gWifiCandidate<0 || gWifiCandidate>=int(gSavedWifi.size()) || !gCloudReady)return;
  const SavedWifi next=gSavedWifi[gWifiCandidate];
  if(gWifiSsid.isEmpty() || gWifiSsid==next.ssid)gSavedWifi.erase(gSavedWifi.begin()+gWifiCandidate);
  else gSavedWifi[gWifiCandidate]={gWifiSsid,gWifiPassword};
  gWifiSsid=next.ssid;gWifiPassword=next.pass;gWifiCandidate=-1;
  gDailyStore.putString("wifi_ssid",gWifiSsid);secretPut("wifi_pass",gWifiPassword);
  gatewayStoreSavedWifi();Serial.println("WIFI_SAVED_NETWORK_PROMOTED");
}

// Remote Bluetooth discovery by the gateway itself (phone can be anywhere).
void gatewayBleScanDone(NimBLEScanResults) {}
bool gBleScanRunning=false;
void gatewayBleScanFinish() {
  NimBLEScanResults found=NimBLEDevice::getScan()->getResults();
  JsonDocument data;JsonArray rows=data["devices"].to<JsonArray>();
  // Strongest signals first, at most 30 rows.
  std::vector<int> order;for(int i=0;i<found.getCount();++i)order.push_back(i);
  std::sort(order.begin(),order.end(),[&](int a,int b){return found.getDevice(a).getRSSI()>found.getDevice(b).getRSSI();});
  for(size_t n=0;n<order.size() && n<30;++n) {
    NimBLEAdvertisedDevice device=found.getDevice(order[n]);
    JsonObject row=rows.add<JsonObject>();
    row["mac"]=String(device.getAddress().toString().c_str());
    row["name"]=device.haveName()?String(device.getName().c_str()):String("");
    row["rssi"]=device.getRSSI();
  }
  NimBLEDevice::getScan()->clearResults();gBleScanRunning=false;
  gatewayResult("confirmed","Gateway Bluetooth scan complete.",&data);
}

// Runs the active command (cloud queue or bench). Results go through gatewayResult().
// A failed controller selection says why in a form the app can act on: it
// pops up the PIN dialog on pin_required / pin_wrong instead of parsing text.
const char *gatewayCtrlPinReason() {
  if(gCtrlSecureFailed) return "pin_wrong";
  if(gSrneLocked) return gCtrlPin>=0?"pin_wrong":"pin_required";
  if(gCtrlPinAsked && gCtrlPin<0) return "pin_required";
  return nullptr;
}
void gatewayCtrlFail(const String &message) {
  const char *reason=gatewayCtrlPinReason();
  if(!reason){gatewayResult("failed",message);return;}
  JsonDocument extra;extra["reason"]=reason;gatewayResult("failed",message,&extra);
}
void gatewayDispatch() {
  // A periodic parameter refresh must not share the controller link with a command.
  if(!gCtrlJob)gatewayCtrlReset();
  if(gActiveCommandType=="handover") {
    if(gActivePayload["request_id"].as<String>()!=gSetupRequestId) {gatewayResult("failed","Setup session did not match.");return;}
    gatewaySaveCredentials();gDailyStore.putBool("setup_complete",true);gOperational=true;gSetupTrialPending=false;gatewayResult("confirmed","Cloud handover complete.");gatewayStopPortal();gSetupState="complete";
  } else if(gActiveCommandType=="connection") {
    if(!gActivePayload["controller_enabled"].is<bool>() || !gActivePayload["bms_enabled"].is<bool>()) {gatewayResult("failed","Invalid connection options.");return;}
    if(gControllerOnlyMode && gActivePayload["bms_enabled"].as<bool>()) {gatewayResult("failed","Only Controller Mode uses no BMS. Switch to Controller + BMS Mode first.");return;}
    gControllerEnabled=gActivePayload["controller_enabled"];gBmsEnabled=gActivePayload["bms_enabled"];gControllerNextAt=gBmsNextAt=0;
    gDailyStore.putBool("ctrl_enabled",gControllerEnabled);gDailyStore.putBool("bms_enabled",gBmsEnabled);
    if(!gControllerEnabled)gatewayDisconnect(true);if(!gBmsEnabled)gatewayDisconnect(false);
    gatewayResult("confirmed","Connection preference saved. Enabled devices reconnect independently.");
  } else if(gActiveCommandType=="select_device") {
    String target=gActivePayload["target"] | "", mac=gActivePayload["mac"] | "";
    const String link=gActivePayload["link"] | "";
    // RS485: the gateway searches the wire for the controller; no MAC is used.
    if(target=="controller" && link=="rs485") {
      const String model=gActivePayload["model"] | "";
      if(!gatewayControllerModel(model)) {gatewayResult("failed","Unsupported controller model. Select Shiner2410, 2420, 2430, 2440 or 2460.");return;}
      gSelectionPreviousMac=gConfigControllerMac;gSelectionPreviousProfile=gJkProfile;gSelectionPreviousEnabled=gControllerEnabled;gSelectionPreviousModel=gControllerModel;gSelectionPreviousLink=gCtrlLink;
      gatewayDisconnect(true);
      uint32_t baud=0;uint8_t addr=0;
      if(!gatewayRs485Search(baud,addr)) {gatewayResult("failed","No controller answered on RS485. Check the wiring (D+/A, D-/B, GND) and that the controller is on.");return;}
      gCtrlLink=1;gRs485Baud=baud;gRs485Addr=addr;gControllerEnabled=true;gControllerModel=model;
      gControllerLinkedAt=millis();gControllerNextAt=millis()+10000;
      sendSrneLiveRead();
      return;
    }
    if((target!="controller" && target!="bms") || !gatewayMac(mac)) {gatewayResult("failed","Invalid device selection.");return;}
    bool controller=target=="controller";
    if(!controller && gControllerOnlyMode) {gatewayResult("failed","Only Controller Mode uses no BMS. Switch to Controller + BMS Mode first.");return;}
    const String model=gActivePayload["model"] | "";
    if(controller && !gatewayControllerModel(model)) {gatewayResult("failed","Unsupported controller model. Select Shiner2410, 2420, 2430, 2440 or 2460.");return;}
    if(!controller && (gActivePayload["profile"].as<String>()!="auto" && gActivePayload["profile"].as<String>()!="jk02_24" && gActivePayload["profile"].as<String>()!="jk02_32" && gActivePayload["profile"].as<String>()!="jbd")) {gatewayResult("failed","BMS type is not supported. Select Auto-detect, a JK02 layout or JBD.");return;}
    gSelectionPreviousMac=controller?gConfigControllerMac:gConfigBmsMac;gSelectionPreviousProfile=gJkProfile;gSelectionPreviousEnabled=controller?gControllerEnabled:gBmsEnabled;gSelectionPreviousModel=gControllerModel;gSelectionPreviousLink=gCtrlLink;
    gatewayDisconnect(controller);
    // A newly chosen device must probe both address types again.
    if(controller){gConfigControllerMac=mac;gControllerEnabled=true;gControllerModel=model;gCtrlAddrKind=-1;gCtrlLink=0;
      // Another controller may want a different address and response mode:
      // forget what the previous one taught us rather than ruling them out.
      // Kept here so a failed selection can hand them back.
      gSelectionPreviousBleAddr=gDailyStore.getUChar("srne_ble_addr",0xff);gSelectionPreviousBleMode=gDailyStore.getUChar("srne_ble_mode",0);
      // A PIN travels with the controller it belongs to: 1 to 6 digits, or
      // none. A failed selection used to throw it away again, so the PIN was
      // only ever kept by a selection that already worked -- and the automatic
      // reconnects between attempts, which carry no command, paired without one
      // and left the module locked. The user retyped it every time. Keep it for
      // the controller it was typed for, saved or not yet saved.
      gSelectionPreviousPin=gCtrlPin;  // before any early failure restores it
      gSelectionKeepPin=gSelectionPreviousMac.isEmpty() || gSelectionPreviousMac==mac;
      const String pin=gActivePayload["pin"] | "";
      bool pinOk=pin.length()<=6;for(size_t i=0;i<pin.length();++i)if(!isDigit(pin[i]))pinOk=false;
      if(!pinOk){gatewayResult("failed","The Bluetooth PIN must be 1 to 6 digits.");return;}
      gCtrlPin=pin.length()?int32_t(pin.toInt()):-1;gCtrlPinAsked=false;
      if(gSelectionKeepPin)gDailyStore.putInt("ctrl_pin",gCtrlPin);
      gCtrlVerdict="";gSrneRespMode=0;gDailyStore.remove("srne_ble_addr");gDailyStore.remove("srne_ble_mode");}
    else {gJkProfile=gActivePayload["profile"].as<String>();gConfigBmsMac=mac;gBmsEnabled=true;gBmsAddrKind=-1;}
    // gatewayConnect names what failed (no link, no SRNE service, no data):
    // report that, not one sentence that fits every case.
    if(!gatewayConnect(controller)) {
      const String why=gLinkError.length()?gLinkError:String("Device connection failed. Close its other Bluetooth apps and verify range.");
      if(controller)gatewayCtrlFail(why);else gatewayResult("failed",why);
    }
  } else if(gActiveCommandType=="load") {
    if(!gControllerEnabled || !srneLinkUp() || !srneWriterReady() || !gActivePayload["enabled"].is<bool>()) {gatewayResult("failed","Controller is not connected.");return;}
    // Through the pending slot, never straight out: the cloud can hand this
    // over milliseconds after the one-second live read, and the module drops
    // a frame that arrives right behind another.
    gLoadDesired=gActivePayload["enabled"];gLoadModeStage=1;srneSendAfter(kSrneSendLoadMode,srneSendGap());
  } else if(gActiveCommandType=="enable_manual_load") {
    if(!srneLinkUp() || !srneWriterReady()) {gatewayResult("failed","Controller is not connected.");return;}
    // Read the current mode first; it is saved before manual is written.
    gLoadModeStage=3;srneSendAfter(kSrneSendLoadMode,srneSendGap());
  } else if(gActiveCommandType=="restore_load_mode") {
    if(!srneLinkUp() || !srneWriterReady()) {gatewayResult("failed","Controller is not connected.");return;}
    const int previous=gDailyStore.getInt("prev_load_mode",-1);
    if(previous<0 || previous>17 || previous==15) {gatewayResult("failed","No saved previous load mode. Set the load mode with the SRNE app or controller buttons.");return;}
    gLoadModeStage=4;srneSendAfter(kSrneSendRestoreMode,srneSendGap());
  } else if(gActiveCommandType=="read_settings" || gActiveCommandType=="controller_settings" || gActiveCommandType=="controller_parameters" ||
            gActiveCommandType=="restore_profile_snapshot" || gActiveCommandType=="set_battery_type_user") {
    // Controller parameter jobs: read, validate, save a copy, write, read back.
    if(!srneLinkUp() || !srneWriterReady() || !gLatestSrneSampleAt || millis()-gLatestSrneSampleAt>10000) {gatewayResult("failed","Controller is not connected.");return;}
    // Older apps: "change to USER" is the battery type parameter.
    if(gActiveCommandType=="set_battery_type_user"){gActiveCommandType="controller_parameters";gActivePayload.clear();gActivePayload["battery_type"]="USER";}
    gatewayCtrlStartJob();
  } else if(gActiveCommandType=="get_logs") {
    JsonDocument data;
    data["firmware_version"]=kFirmwareVersion;
    data["uptime_seconds"]=millis()/1000;
    data["free_heap"]=ESP.getFreeHeap();
    data["wifi_ssid"]=WiFi.SSID();data["wifi_rssi"]=WiFi.RSSI();
    data["controller_mac"]=gConfigControllerMac;data["controller_model"]=gControllerModel;
    data["controller_link"]=srneLinkUp();data["controller_reading"]=gLatestSrneSampleAt!=0;
    data["srne_ble_address"]=gSrneBleAddr;data["srne_ble_mode"]=gSrneRespMode;
    // Answered-but-no-reading and a shortened live block are the two states a
    // remote report could not otherwise distinguish from plain silence.
    data["controller_verdict"]=gCtrlVerdict;
    // Whether a PIN is saved and whether the module asked for one -- never the PIN.
    data["controller_locked"]=gSrneLocked;data["controller_pin_saved"]=gCtrlPin>=0;data["controller_pin_asked"]=bool(gCtrlPinAsked);
    data["controller_answered"]=gSrneAnsweredAt!=0;data["srne_live_count"]=gSrneLiveCount;
    data["bms_mac"]=gConfigBmsMac;data["bms_profile"]=gJkProfile;
    // The BMS half of the same question: answering but undecodable reads very
    // differently from never answering, and both looked alike before.
    data["bms_link"]=gJkClient && gJkClient->isConnected();
    data["bms_answered"]=gBmsAnsweredAt!=0;data["bms_reading"]=gLatestBmsSampleAt!=0;
    data["rx_dropped"]=gRxDropped;
    data["last_link_error"]=gLinkError;data["last_network_error"]=gNetworkError;
    JsonArray lines=data["lines"].to<JsonArray>();
    for(uint8_t i=0;i<kDiagRingSize;++i) {
      const String &line=gDiagRing[(gDiagRingNext+i)%kDiagRingSize];
      if(line.length())lines.add(line);
    }
    gatewayResult("confirmed","Gateway diagnostics collected.",&data);
  } else if(gActiveCommandType=="reporting_options") {
    int reset=gActivePayload["reset_minute"] | -1,start=gActivePayload["pv_start"] | -1,end=gActivePayload["pv_end"] | -1;
    int offset=gActivePayload["timezone_offset_seconds"] | 999999;
    if(reset<0 || reset>1439 || start<0 || start>1439 || end<0 || end>1439 || offset< -43200 || offset>50400){gatewayResult("failed","Invalid reporting time options.");return;}
    // Archive the old boundary before changing its reporting calendar.
    gatewayArchiveDay(gSummaryDay);gResetHour=reset/60;gResetMinute=reset%60;gPvAverageStartMinute=start;gPvAverageEndMinute=end;gTimezoneOffset=offset;
    gDailyStore.putInt("reset_minute",reset);gDailyStore.putInt("pv_start",start);gDailyStore.putInt("pv_end",end);gDailyStore.putInt("tz_offset",offset);
    configTime(offset,0,"pool.ntp.org","time.nist.gov");gLastEnergySample=0;gLastBmsEnergyAt=0;
    gatewayResult("confirmed","Reporting times saved by gateway.");
  } else if(gActiveCommandType=="system_options") {
    // Battery mode, panel rating and (Only Controller Mode) battery type and
    // capacity. Saved on the gateway; the calculation runs here, not on a phone.
    const String mode=gActivePayload["mode"] | "";
    diagLog("SYSTEM_OPTIONS requested mode=%s",mode.c_str());
    if(mode!="controller" && mode!="controller_bms"){gatewayResult("failed","Select Only Controller Mode or Controller + BMS Mode.");return;}
    if(!gActivePayload["panel_w"].is<double>()){gatewayResult("failed","Panel power is required (0 if unknown).");return;}
    const double panel=gActivePayload["panel_w"].as<double>();
    if(!isfinite(panel) || panel<0 || panel>100000){gatewayResult("failed","Panel power must be 0-100000 W.");return;}
    const bool controllerOnly=mode=="controller";
    uint8_t type=gBatteryType;double capacity=gBatteryCapacityAh;
    if(controllerOnly) {
      const String name=gActivePayload["battery_type"] | "";
      type=name=="flooded"?1:name=="sealed"?2:name=="gel"?3:name=="lithium"?4:0;
      if(!type){gatewayResult("failed","Select the battery type (Flooded, Sealed, Gel or Lithium).");return;}
      capacity=gActivePayload["capacity_ah"].is<double>()?gActivePayload["capacity_ah"].as<double>():-1;
      if(!isfinite(capacity) || capacity<1 || capacity>10000){gatewayResult("failed","Battery capacity must be 1-10000 Ah.");return;}
    }
    // Entering Only Controller Mode restarts the calculation from the
    // controller's SOC; a new capacity keeps the calculated SOC.
    if(controllerOnly && !gControllerOnlyMode)gCalcRemainingAh=-1;
    else if(controllerOnly && gCalcRemainingAh>=0 && gBatteryCapacityAh>0)gCalcRemainingAh=gCalcRemainingAh/gBatteryCapacityAh*capacity;
    gControllerOnlyMode=controllerOnly;gBatteryType=type;gBatteryCapacityAh=capacity;gPanelRatedW=panel;gCalcLastAt=0;
    if(controllerOnly){gBmsEnabled=false;gatewayDisconnect(false);}
    else gBmsEnabled=gatewayMac(gConfigBmsMac);
    gBmsNextAt=0;
    gDailyStore.putInt("bat_mode",controllerOnly?0:1);gDailyStore.putUChar("bat_type",type);gDailyStore.putFloat("bat_cap",capacity);
    gDailyStore.putFloat("panel_w",panel);gDailyStore.putBool("bms_enabled",gBmsEnabled);gDailyStore.putDouble("calc_ah",gCalcRemainingAh);
    publishLifetimeState();
    gatewayResult("confirmed","Battery mode and system details saved by gateway.");
  } else if(gActiveCommandType=="clear_history") {
    // One atomic database patch removes measurements, never credentials.
    JsonDocument cleared;cleared["history"]=nullptr;cleared["summary"]=nullptr;cleared["lifetime"]=nullptr;
    if(!gatewayCloud("PATCH","",&cleared)){gatewayResult("failed","Cloud history could not be cleared; local data retained.");return;}
    clearAllStoredData(uint64_t(time(nullptr))*1000);gLastDailyJson="";
    if(LittleFS.begin(false)) {File dir=LittleFS.open("/");File file=dir.openNextFile();while(file){String name=file.name();file.close();if(name.startsWith("/day-") || name.startsWith("day-"))LittleFS.remove(name.startsWith("/")?name:"/"+name);file=dir.openNextFile();}}
    gatewayResult("confirmed","Recorded cloud and local history cleared; credentials preserved.");
  } else if(gActiveCommandType=="wifi_scan") {
    int count=WiFi.scanNetworks(false,false);
    if(count<0){gatewayResult("failed","Gateway Wi-Fi scan failed. Retry in a moment.");return;}
    JsonDocument data;JsonArray rows=data["networks"].to<JsonArray>();
    for(int i=0;i<count && rows.size()<30;++i) {
      if(WiFi.SSID(i).isEmpty() || WiFi.SSID(i).startsWith("NoxBrain-"))continue;
      JsonObject row=rows.add<JsonObject>();row["ssid"]=WiFi.SSID(i);row["rssi"]=WiFi.RSSI(i);
      row["secure"]=WiFi.encryptionType(i)!=WIFI_AUTH_OPEN;row["current"]=WiFi.SSID(i)==gWifiSsid;
    }
    WiFi.scanDelete();gatewayResult("confirmed","Gateway Wi-Fi scan complete.",&data);
  } else if(gActiveCommandType=="wifi_change") {
    const String ssid=gActivePayload["ssid"] | "", pass=gActivePayload["password"] | "";
    if(ssid.isEmpty() || ssid.length()>32 || pass.length()>63 || (pass.length()>0 && pass.length()<8)) {gatewayResult("failed","Invalid Wi-Fi name or password.");return;}
    gatewayWifiTrialStart(ssid,pass);
  } else if(gActiveCommandType=="cloud_change") {
    const String url=gActivePayload["database_url"] | "", key=gActivePayload["api_key"] | "";
    const String email=gActivePayload["email"] | "", pass=gActivePayload["password"] | "";
    if(!validCloudUrl(url) || key.isEmpty() || email.isEmpty() || pass.isEmpty()) {gatewayResult("failed","Incomplete new Firebase configuration.");return;}
    gCloudPrevUrl=gFirebaseDatabaseUrl;gCloudPrevKey=gFirebaseApiKey;gCloudPrevEmail=gFirebaseDeviceEmail;gCloudPrevPass=gFirebaseDevicePassword;
    gCloudTrial=1;gCloudTrialAt=millis();gatewayCloudSwitch(url,key,email,pass);
  } else if(gActiveCommandType=="wifi_add") {
    const String ssid=gActivePayload["ssid"] | "", pass=gActivePayload["password"] | "";
    if(ssid.isEmpty() || ssid.length()>32 || pass.length()>63 || (pass.length()>0 && pass.length()<8)) {gatewayResult("failed","Invalid Wi-Fi name or password.");return;}
    if(ssid==gWifiSsid && pass==gWifiPassword) {gatewayResult("failed","This is already the current Wi-Fi.");return;}
    for(size_t i=0;i<gSavedWifi.size();++i)if(gSavedWifi[i].ssid==ssid){gSavedWifi.erase(gSavedWifi.begin()+i);break;}
    if(gSavedWifi.size()>=kMaxSavedWifi) {gatewayStoreSavedWifi();gatewayResult("failed","Up to 3 Wi-Fi networks can be saved. Remove one first.");return;}
    gSavedWifi.push_back({ssid,pass});gWifiCandidate=-1;gatewayStoreSavedWifi();
    gatewayResult("confirmed","Wi-Fi saved. The gateway joins it when the current Wi-Fi is unavailable and this one is in range.");
  } else if(gActiveCommandType=="wifi_remove") {
    const String ssid=gActivePayload["ssid"] | "";bool removed=false;
    for(size_t i=0;i<gSavedWifi.size();++i)if(gSavedWifi[i].ssid==ssid){gSavedWifi.erase(gSavedWifi.begin()+i);removed=true;break;}
    gWifiCandidate=-1;gatewayStoreSavedWifi();
    if(removed)gatewayResult("confirmed","Saved Wi-Fi removed.");else gatewayResult("failed","This Wi-Fi is not saved on the gateway.");
  } else if(gActiveCommandType=="ble_scan") {
    NimBLEScan *scan=NimBLEDevice::getScan();
    if(scan->isScanning()){gatewayResult("failed","A Bluetooth scan is already running.");return;}
    scan->clearResults();scan->setActiveScan(true);scan->setInterval(97);scan->setWindow(37);
    if(!scan->start(6,gatewayBleScanDone,false)){gatewayResult("failed","Gateway Bluetooth scan could not start.");return;}
    gBleScanRunning=true;
  } else if(gActiveCommandType=="factory_reset") {
    gatewayResult("confirmed","Gateway is erasing everything and restarting as new.");
    gatewayFactoryReset();
  } else if(gActiveCommandType=="ota")gatewayOta(gActivePayload.as<JsonVariantConst>());
  else gatewayResult("failed","Command unsupported by this firmware. No device state was changed.");
}

void gatewayPollCommands() {
  if(!gCloudReady || millis()-gLastQueuePoll<2000)return;
  gLastQueuePoll=millis();
  if(!gFinalCommandJson.isEmpty()){gatewayFlushResult();return;}
  if(gActiveCommand.length()) {
    if(gActiveCommandType=="wifi_change")return; // Finished by gatewayWifiTrialTick().
    if(gActiveCommandType=="cloud_change")return; // Finished by gatewayCloudTrialTick().
    if(gActiveCommandType=="ble_scan") {
      if(gBleScanRunning && !NimBLEDevice::getScan()->isScanning())gatewayBleScanFinish();
      else if(millis()-gCommandStartedAt>25000){NimBLEDevice::getScan()->stop();NimBLEDevice::getScan()->clearResults();gBleScanRunning=false;gatewayResult("failed","Gateway Bluetooth scan did not finish.");}
      return;
    }
    if(gActiveCommandType=="select_device") {
      bool controller=gActivePayload["target"].as<String>()=="controller";
      uint32_t sampled=controller ? gLatestSrneSampleAt : gLatestBmsSampleAt;
      if(sampled && millis()-sampled<5000) {gatewayResult("confirmed","Device connected and valid telemetry received.");return;}
      // A module that says it is locked will not answer however long we wait:
      // report that now instead of after 55 s.
      if(controller && gSrneLocked && gLinkError.length()) {gatewayCtrlFail(gLinkError);return;}
    }
    if(gCtrlJob)return; // Parameter jobs end themselves (50 s limit).
    // A newly selected device gets 55 s for its first valid reading. A silent
    // module spends about 35 s of that in the address ladder -- three
    // addresses at 5 s, a reconnect, then the same three with replies
    // requested -- and only then is the specific reason known. At 45 s a
    // slow cloud round trip could end the command first, and the reason
    // reported was the generic one below, which fits any fault at all.
    // The ceiling is the app: it waits 70 s, and expires_at (60 s) is
    // checked only when a command is picked up, never once it is running.
    // Report what the link attempt actually hit; the old wording listed every
    // possible cause at once, so a module this firmware cannot talk to looked
    // like a range problem and was chased for hours.
    if(millis()-gCommandStartedAt>(gActiveCommandType=="select_device"?55000UL:25000UL))
    {
      // gLinkError is cleared by every successful reconnect, the ladder's own
      // included, so for a controller fall back to the last verdict it reached.
      const bool ctrlTarget=gActiveCommandType=="select_device" && gActivePayload["target"].as<String>()=="controller";
      const String why=gLinkError.length()?gLinkError:(ctrlTarget && gCtrlVerdict.length())?gCtrlVerdict:String("The device never answered. It may be switched off, out of range, or connected to another app.");
      if(ctrlTarget)gatewayCtrlFail(why);else gatewayResult("failed",why);
    }
    return;
  }
  JsonDocument queue;if(!gatewayCloud("GET","commands/queue",nullptr,&queue))return;
  for(JsonPair item:queue.as<JsonObject>()) {
    String id=item.key().c_str();if(!gatewayIdentifier(id))continue;
    JsonVariant command=item.value();gActiveCommand=id;gActiveCommandType=command["type"].as<String>();gActivePayload.set(command["payload"]);
    gCommandStartedAt=millis();
    uint64_t now=uint64_t(time(nullptr))*1000;
    uint64_t expires=command["expires_at"] | uint64_t(0);
    JsonDocument previous;
    if(!gatewayCloud("GET","command_results/"+id,nullptr,&previous)){gActiveCommand="";gActiveCommandType="";gActivePayload.clear();return;}
    String priorStatus=previous["status"] | "";
    if(priorStatus=="confirmed" || priorStatus=="failed" || priorStatus=="expired") {
      serializeJson(previous,gFinalCommandJson);gDailyStore.putString("pending_result",gFinalCommandJson);gatewayFlushResult();return;
    }
    if(!expires || expires<now || expires>now+120000) {gatewayResult("expired","Command expired; it was not executed.");return;}
    if(gDailyStore.getString("last_command","")==id || !priorStatus.isEmpty()){gatewayResult("failed","Previous execution was interrupted. Read actual device state before retrying.");return;}
    gDailyStore.putString("last_command",id); // Persist before physical action; never replay after a reset.
    // This command is about to send frames. The periodic refresh runs with no
    // active command and gCtrlJob false, so the guard above never covered it:
    // its frames would interleave with this one's. Drop the refresh rather
    // than queue behind it -- it repeats every two minutes -- and clear
    // whatever it left waiting in the one pending-send slot.
    if(gatewayCtrlBusy() && !gCtrlJob){diagLog("CTRL_REFRESH_CANCELLED for %s",gActiveCommandType.c_str());gatewayCtrlReset();gSrneSendPending=kSrneSendNone;}
    gatewayResult("accepted","Gateway accepted command.");
    gatewayDispatch();
    return;
  }
}

void gatewayInitializeSummary(JsonDocument &d) {
  // Persist sums and counts so averages can actually be recovered.
  d["panel_ah"]=gPanelAh;d["load_ah"]=gLoadAh;d["bms_coverage_seconds"]=gBatteryCoverageSeconds;
  d["battery_energy_complete"]=false; // Coverage is published; gaps are never silently filled.
  d["pv_w_sum"]=gPvWSum;d["pv_v_sum"]=gPvVSum;d["pv_a_sum"]=gPvASum;
  d["pv_on_w_sum"]=gPvOnWSum;d["pv_on_v_sum"]=gPvOnVSum;d["pv_on_a_sum"]=gPvOnASum;d["charge_a_sum"]=gChargeASum;
  d["discharge_w_sum"]=gDischargeWSum;d["discharge_a_sum"]=gDischargeASum;
  d["samples"]=gAggregateSamples;d["pv_on_samples"]=gPvOnSamples;d["charge_samples"]=gChargeSamples;
  d["discharge_w_samples"]=gDischargeWSamples;d["discharge_a_samples"]=gDischargeASamples;
  d["load_source_method"]=gControllerOnlyMode?"controller_calculated_net":"bms_net_estimate";
  // "calculated" = Only Controller Mode values from controller registers.
  d["battery_data_source"]=gControllerOnlyMode?"calculated":"bms";
  d["load_source_note"]="Only valid for controller DC load with no other battery loads or charging sources; gaps are unallocated.";
  d["load_source_unallocated_wh"]=max(0.0,gLoadWh-gLoadFromPanelWh-gLoadFromBatteryWh);
  // Energy is counted for the whole reporting day, from one daily reset to
  // the next -- the same period the history and Statistics show. PV ON and
  // PV OFF are event times only; they never bound an energy total.
  d["load_window"]="reset_to_reset";
  // Full charge of this reporting day only (null after the reset); the lifetime record stays in /lifetime.
  d["full_charge_scope"]="day";
  if(gDayFullChargeAt){d["day_full_charge_at"]=static_cast<unsigned long long>(gDayFullChargeAt);if(gDayFullSoc>=0)d["day_full_charge_soc"]=gDayFullSoc;else d["day_full_charge_soc"]=nullptr;if(gDayFullAh>=0)d["day_full_charge_ah"]=gDayFullAh;else d["day_full_charge_ah"]=nullptr;}
  else{d["day_full_charge_at"]=nullptr;d["day_full_charge_soc"]=nullptr;d["day_full_charge_ah"]=nullptr;}
  // Sent as null so a gateway that once published the PV ON window clears
  // those keys in Firebase instead of leaving them next to the day totals.
  d["window_load_wh"]=nullptr;d["window_load_from_panel_wh"]=nullptr;
  d["window_load_from_battery_wh"]=nullptr;d["window_load_unallocated_wh"]=nullptr;
  if(gBatteryCoverageSeconds<=0){
    d["battery_charge_wh"]=nullptr;d["battery_charge_ah"]=nullptr;d["battery_discharge_wh"]=nullptr;d["energy_balance_wh"]=nullptr;
    // Without any BMS interval the panel/battery split of load is unknown, not zero.
    for(const char *k:{"load_from_panel_wh","load_from_battery_wh","load_from_panel_bms_wh","load_from_battery_bms_wh","load_panel_wh","load_battery_wh"})d[k]=nullptr;
  }
  if(!gAggregateSamples){d["panel_wh"]=nullptr;d["load_wh"]=nullptr;}
  d["battery_energy_method"]=gControllerOnlyMode?"controller_calculated":"independent_bms_trapezoid";
}
void gatewayPersistHistory(const String &json) {
  gLastDailyJson=json;
  if(millis()-gLastCheckpointAt<60000)return;
  gLastCheckpointAt=millis();gatewayArchiveDay(gSummaryDay);
}
void gatewayArchiveDay(const String &day) {
  if(day.isEmpty() || gLastDailyJson.isEmpty())return;
  JsonDocument saved;if(deserializeJson(saved,gLastDailyJson) || saved["day"].as<String>()!=day)return;
  String path="/day-"+day+".json";File file=LittleFS.open(path+".tmp","w");
  if(!file){Serial.println("HISTORY_STORAGE_FULL_OR_UNAVAILABLE");return;}
  size_t written=file.print(gLastDailyJson);file.close();
  if(written!=gLastDailyJson.length()){LittleFS.remove(path+".tmp");return;}
  // LittleFS renames atomically over an existing file, so the old archive
  // stays until the new one replaces it. Only if that fails is the old one
  // removed first; a power cut then leaves the .tmp, recovered at startup.
  if(!LittleFS.rename(path+".tmp",path) && !(LittleFS.remove(path) && LittleFS.rename(path+".tmp",path)))
    Serial.println("HISTORY_ARCHIVE_RENAME_FAILED");
}
// Startup: a day archive left only as .tmp (power cut between remove and
// rename) is restored if it is complete; a .tmp next to its archive is stale.
void gatewayRecoverArchive() {
  std::vector<String> pending;
  File root=LittleFS.open("/");if(!root)return;
  for(File file=root.openNextFile();file;file=root.openNextFile()) {
    String name=file.name();file.close();if(!name.startsWith("/"))name="/"+name;
    if(name.startsWith("/day-") && name.endsWith(".json.tmp"))pending.push_back(name);
  }
  root.close();
  for(const String &tmp: pending) {
    const String path=tmp.substring(0,tmp.length()-4),day=path.substring(5,15);
    bool complete=false;
    if(!LittleFS.exists(path)) {File file=LittleFS.open(tmp,"r");JsonDocument saved;complete=file && !deserializeJson(saved,file) && saved["day"].as<String>()==day;if(file)file.close();}
    // A complete copy is never deleted: if the rename fails it stays for the
    // next start. Only a stale (archive exists) or partial .tmp is removed.
    if(complete) {
      if(LittleFS.rename(tmp,path))Serial.println("HISTORY_ARCHIVE_RECOVERED "+day);
      else Serial.println("HISTORY_ARCHIVE_RECOVERY_RETRY "+day);
    } else LittleFS.remove(tmp);
  }
}
// Returns true when it made a network request (see gatewayCloudStep).
bool gatewayFlushArchive() {
  static uint32_t last=0;if(millis()-last<30000 || !gCloudReady)return false;last=millis();
  // During an unfinished re-setup the cloud is a trial: upload (and delete)
  // nothing there, or a reverted gateway would lose those days.
  if(gSetupTrialPending)return false;
  File root=LittleFS.open("/");if(!root)return false;
  File file=root.openNextFile();String chosen,chosenDay;
  while(file) {
    String name=file.name();file.close();if(!name.startsWith("/"))name="/"+name;
    if(name.startsWith("/day-") && name.endsWith(".json")) {
      String day=name.substring(5,15);
      // Oldest unsent day first; today's checkpoint never starves a backlog.
      if(chosen.isEmpty() || day<chosenDay){chosen=name;chosenDay=day;}
    }
    file=root.openNextFile();
  }
  if(chosen.isEmpty())return false;
  file=LittleFS.open(chosen,"r");if(!file)return false;
  JsonDocument day;auto error=deserializeJson(day,file);file.close();
  String key=day["day"] | "";
  if(error || key!=chosenDay) {
    // A damaged archive is kept for inspection under a name the upload
    // ignores, so it no longer blocks the following days.
    const bool moved=LittleFS.rename(chosen,chosen+".bad");
    Serial.println(String(moved?"HISTORY_ARCHIVE_SET_ASIDE ":"HISTORY_ARCHIVE_SET_ASIDE_FAILED ")+chosen);
    return false;
  }
  if(gatewayCloud("PUT","history/"+key,&day) && key!=gSummaryDay)LittleFS.remove(chosen);
  return true;
}
bool gatewayMountHistory() {
  if(LittleFS.begin(false)){gDailyStore.putBool("fs_owned",true);return true;}
  auto *part=esp_partition_find_first(ESP_PARTITION_TYPE_DATA,ESP_PARTITION_SUBTYPE_DATA_SPIFFS,"spiffs");
  if(!part)return false;
  // A partition that already holds a LittleFS (its superblock names
  // "littlefs") is never formatted: a failing mount may be temporary and the
  // history in it must survive. Only a partition this firmware has never
  // owned and that is not LittleFS (older SPIFFS data) may be initialized once.
  bool wasLittleFs=false;
  for(size_t offset=0;offset<8192 && offset<part->size && !wasLittleFs;offset+=4096) {
    char head[64]={};
    if(esp_partition_read(part,offset,head,sizeof(head))!=ESP_OK)return false;
    for(size_t i=0;i+8<=sizeof(head);++i)if(!memcmp(head+i,"littlefs",8)){wasLittleFs=true;break;}
  }
  if(wasLittleFs){Serial.println("HISTORY_STORAGE_MOUNT_FAILED_NOT_FORMATTED");return false;}
  if(!gDailyStore.getBool("fs_owned",false)) {
    Serial.println("HISTORY_STORAGE_LEGACY_PARTITION_INITIALIZED");
    if(LittleFS.format() && LittleFS.begin(false)){gDailyStore.putBool("fs_owned",true);return true;}
    return false;
  }
  uint8_t block[512];
  for(size_t offset=0;offset<part->size;offset+=sizeof(block)) {
    size_t count=min(sizeof(block),size_t(part->size-offset));
    if(esp_partition_read(part,offset,block,count)!=ESP_OK)return false;
    for(size_t i=0;i<count;++i)if(block[i]!=0xff)return false;
  }
  return LittleFS.format() && LittleFS.begin(false);
}
void gatewayPublishStatus() {
  // firebaseAuthenticate checks Wi-Fi itself and records the reason; testing
  // it here as well would short-circuit before anything was written down.
  if(!firebaseAuthenticate()) {gCloudReady=false;return;}
  JsonDocument status;status["device_id"]=gDeviceId;status["hardware_id"]=gHardwareId;
  status["request_id"]=gSetupRequestId;status["state"]="online";status["firmware_version"]=kFirmwareVersion;
  status["updated_at"][".sv"]="timestamp";
  if(!gatewayCloud("PUT","setup/status",&status)) {gCloudReady=false;return;}
  gCloudReady=true;
  if(gProvisioning) {
    // A new gateway has nothing to lose and keeps its progress across a
    // restart. A working one keeps its saved configuration until handover.
    if(gOperational)gSetupTrialPending=true;
    else {gDailyStore.putBool("setup_complete",false);gatewaySaveCredentials();}
    gProvisioning=false;gSetupState="cloud_ready";gSetupError="";
  }
  JsonDocument live;
  const bool ctrl=srneLinkUp() && gLatestSrneSampleAt && millis()-gLatestSrneSampleAt<10000;
  const bool bms=gJkClient && gJkClient->isConnected() && gLatestBmsSampleAt && millis()-gLatestBmsSampleAt<10000;
  live["connected"]=ctrl || bms;live["controller_connected"]=ctrl;live["bms_connected"]=bms;
  live["controller_enabled"]=gControllerEnabled;live["controller_link"]=srneRs485()?"rs485":"ble";live["bms_enabled"]=gBmsEnabled;live["controller_model"]=gControllerModel;
  // Why a controller is not connected, on the heartbeat rather than only in
  // a command result or the diagnostics report. A reconnect that fails on its
  // own carries no command to answer, so a user whose PIN stopped working saw
  // nothing but a disconnected controller and no way to learn it was the PIN.
  // Published while the controller is wanted but not reading; cleared once it
  // reads, so a stale reason never sits under a working controller.
  if(gControllerEnabled && !gLatestSrneSampleAt) {
    const String why=gLinkError.length()?gLinkError:gCtrlVerdict;
    if(why.length())live["controller_verdict"]=why;
    live["controller_locked"]=gSrneLocked;
  }
  // The gateway's saved battery mode and system details (what it calculates with).
  static const char *const kBatteryTypes[]={"","flooded","sealed","gel","lithium"};
  live["battery_mode"]=gControllerOnlyMode?"controller":"controller_bms";
  live["battery_type"]=kBatteryTypes[gBatteryType<=4?gBatteryType:0];
  live["battery_capacity_ah"]=gBatteryCapacityAh;live["panel_rated_w"]=gPanelRatedW;
  if(gControllerModelReported.length())live["controller_model_reported"]=gControllerModelReported;
  const int match=gatewayModelMatch();
  if(match<0)live["controller_model_match"]=nullptr;else live["controller_model_match"]=match==1;
  // Network names only; saved passwords are never published.
  live["wifi_ssid"]=WiFi.SSID();JsonArray saved=live["wifi_saved"].to<JsonArray>();
  for(const SavedWifi &w:gSavedWifi)saved.add(w.ssid);
  live["gateway_updated_at"][".sv"]="timestamp";live["esp32_firmware_version"]=kFirmwareVersion;
#if CONFIG_IDF_TARGET_ESP32S3
  live["chip_family"]="ESP32-S3";
#else
  live["chip_family"]="ESP32";
#endif
  gatewayCloud("PATCH","live",&live);
}
// Logs every Wi-Fi, cloud and Bluetooth link change, and the heap once a minute.
void gatewayDiagTick() {
  static int wifi=-1,cloud=-1,ctrl=-1,bms=-1;static uint32_t heapAt=0;
  const int w=WiFi.status()==WL_CONNECTED,c=gCloudReady;
  const int s=srneRs485()?srneRs485Alive():(gSrneClient && gSrneClient->isConnected()),b=gJkClient && gJkClient->isConnected();
  if(w!=wifi){wifi=w;if(w)diagLog("WIFI_UP rssi=%d ch=%d",WiFi.RSSI(),WiFi.channel());else diagLog("WIFI_DOWN status=%d",int(WiFi.status()));}
  if(c!=cloud){cloud=c;if(c)diagLog("CLOUD_READY");else diagLog("CLOUD_LOST %s",gNetworkError.c_str());}
  if(s!=ctrl){ctrl=s;diagLog(s?"CTRL_LINK_UP":"CTRL_LINK_DOWN");}
  if(b!=bms){bms=b;diagLog(b?"BMS_LINK_UP":"BMS_LINK_DOWN");}
  if(millis()-heapAt>=60000){heapAt=millis();
    diagLog("STATS req=%u reused=%u fail=%u avg_ms=%u max_ms=%u loop_max_ms=%u ble_notes=%u drops_total=%u ctrl=%d bms=%d mode=%s bms_enabled=%d",unsigned(gDiagReqCount),unsigned(gDiagReqReused),unsigned(gDiagReqFail),
      unsigned(gDiagReqCount?gDiagReqMsTotal/gDiagReqCount:0),unsigned(gDiagReqMsMax),unsigned(gDiagLoopMax),unsigned(gDiagNotes),unsigned(gRxDropped),s,b,gControllerOnlyMode?"controller":"controller_bms",gBmsEnabled);
    gDiagReqCount=gDiagReqReused=gDiagReqFail=gDiagReqMsTotal=gDiagReqMsMax=gDiagLoopMax=0;gDiagNotes=0;}
}
// S3 status LED: purple blink = setup mode, red = no Wi-Fi, blue = Wi-Fi
// without cloud, yellow blink = devices up but no cloud, yellow = cloud but a
// device the mode needs is off or not connected (controller always; BMS in
// Controller + BMS Mode), green = Wi-Fi, cloud and every needed device up.
// Blinks are 0.5 s on / 0.5 s off. Tuned by eye on the board: yellow 40,24
// (32,24 looked green, 40,18 and 40,12 orange); green 4,56 (pure 0,32 looked
// teal, 8,32 pale).
void gatewayUpdateLed() {
  static uint32_t at=0;if(millis()-at<250)return;at=millis();
  const bool blinkOn=(millis()/500)%2==0;
  if(gSetupActive){if(blinkOn)setStatusLed(24,0,32);else setStatusLed(0,0,0);return;}
  if(WiFi.status()!=WL_CONNECTED){setStatusLed(32,0,0);return;}
  const bool ctrlOk=gControllerEnabled && (srneRs485()?srneRs485Alive():(gSrneClient && gSrneClient->isConnected()));
  const bool bmsOk=gControllerOnlyMode || (gBmsEnabled && gJkClient && gJkClient->isConnected());
  const bool devicesOk=ctrlOk && bmsOk;
  if(!gCloudReady){if(!devicesOk)setStatusLed(0,0,32);else if(blinkOn)setStatusLed(40,24,0);else setStatusLed(0,0,0);return;}
  if(devicesOk)setStatusLed(4,56,0);else setStatusLed(40,24,0);
}
// Restarts the gateway when the main loop has not run for two minutes.
// Sleeps between checks; does nothing until the loop has run once.
void gatewayStallGuard(void *) {
  for(;;) {
    vTaskDelay(pdMS_TO_TICKS(5000));
    const uint32_t alive=gLoopAliveAt;
    if(alive && millis()-alive>120000UL){gStallRestartMark=kStallRestartMark;esp_restart();}
  }
}
void gatewaySetup() {
  Serial.begin(115200);
#if CONFIG_IDF_TARGET_ESP32S3 && ARDUINO_USB_CDC_ON_BOOT
  Serial0.begin(115200);
#endif
  loadDailySummaryFromFlash();repairInvalidChargeSummary();loadCredentialsFromFlash();
  uint8_t mac[6];esp_read_mac(mac,ESP_MAC_WIFI_STA);char identity[32];
  snprintf(identity,sizeof(identity),"NOX-%02X%02X%02X%02X%02X%02X",mac[0],mac[1],mac[2],mac[3],mac[4],mac[5]);gHardwareId=identity;
  gIdentityStore.begin("gateway",false);
  gIdentityStore.remove("setup_code"); // Per-device setup codes are no longer used.
  gSetupSsid="NoxBrain-"+gHardwareId.substring(4);gDeviceId=gDailyStore.getString("device_id",gHardwareId);
  const bool schemaValid=gDailyStore.getUInt("setup_schema",0)==1;
  gOperational=schemaValid && gDailyStore.getBool("setup_complete",false);
  if(!schemaValid) {
    // Legacy releases could contain a shared project/device ID. Never send
    // anything there after migration; require new app ownership verification.
    gDeviceId=gHardwareId;gWifiSsid="";gWifiPassword="";gFirebaseApiKey="";gFirebaseDatabaseUrl="";gFirebaseDeviceEmail="";gFirebaseDevicePassword="";
  }
  gSetupRequestId=gDailyStore.getString("setup_request","");
  gFinalCommandJson=gDailyStore.getString("pending_result","");
  gJkProfile=gDailyStore.getString("bms_profile","auto");
  gControllerModel=gDailyStore.getString("ctrl_model","");if(!gatewayControllerModel(gControllerModel))gControllerModel="";
  gCtrlPin=gDailyStore.getInt("ctrl_pin",-1);
  if(schemaValid)gatewayLoadSavedWifi();
  gControllerEnabled=gDailyStore.getBool("ctrl_enabled",true);gBmsEnabled=gDailyStore.getBool("bms_enabled",false);
  gCtrlAddrKind=gDailyStore.getChar("ctrl_addr",-1);gBmsAddrKind=gDailyStore.getChar("bms_addr",-1);
  // Gateways set up before battery modes existed: no BMS in use = Only Controller.
  const int savedMode=gDailyStore.getInt("bat_mode",-1);
  gControllerOnlyMode=savedMode<0 ? !gBmsEnabled : savedMode==0;
  if(gControllerOnlyMode)gBmsEnabled=false;
  gRxQueue=xQueueCreate(96,sizeof(GatewayRx));
  if(!gRxQueue) {Serial.println("RX_QUEUE_ALLOCATION_FAILED");return;}
  if(!gatewayMountHistory())Serial.println("History storage unavailable; existing filesystem was not erased.");
  else {
    gatewayRecoverArchive();
    if(!gSummaryDay.isEmpty()){File file=LittleFS.open("/day-"+gSummaryDay+".json","r");if(file){gLastDailyJson=file.readString();file.close();}}
  }
  #if CONFIG_IDF_TARGET_ESP32S3
  gStatusLed.begin();gStatusLed.setBrightness(32);
#endif
  pinMode(0,INPUT_PULLUP);attachInterrupt(digitalPinToInterrupt(0),gatewayBootChanged,CHANGE);
  configTime(gTimezoneOffset,0,"pool.ntp.org","time.nist.gov");
  WiFi.setAutoReconnect(true);WiFi.persistent(false);
  WiFi.mode(WIFI_STA);
  if(!gOperational)gatewayStartPortal();
  else gSetupState="complete";
  gatewayRoutes();
  if(strlen(getWifiSsid()) && validCloudUrl(getFirebaseDatabaseUrl())) {WiFi.begin(getWifiSsid(),getWifiPassword());gWifiAttemptAt=millis();gSetupState="connecting_wifi";}
  NimBLEDevice::init("NoxBrain Gateway");gBleStarted=true;
  // A restart by the stall guard says so once, then the guard starts.
  if(esp_reset_reason()==ESP_RST_SW && gStallRestartMark==kStallRestartMark)diagLog("BOOT_AFTER_LOOP_STALL");
  gStallRestartMark=0;
  xTaskCreate(gatewayStallGuard,"stall_guard",2048,nullptr,2,nullptr);
}
#ifdef NOXBRAIN_BENCH
// Bench commands (one per line, RAM only, nothing saved):
//   ctrl <MAC> <Shiner model> | bms <MAC> | mode controller|controller_bms
//   bat <flooded|sealed|gel|lithium> <capacity Ah> | panel <W> | read | status
//   cmd <type> <json payload>: runs a cloud command exactly as from Firebase,
//   e.g. cmd read_settings | cmd controller_parameters {"load_mode":15}
void gatewayBenchCommand(String line) {
  line.trim();
  const int a=line.indexOf(' '),b=line.indexOf(' ',a+1);
  const String cmd=a<0?line:line.substring(0,a);
  const String p1=a<0?"":line.substring(a+1,b<0?line.length():b),p2=b<0?"":line.substring(b+1);
  if(cmd=="ctrl" && gatewayMac(p1) && gatewayControllerModel(p2)) {gatewayDisconnect(true);gConfigControllerMac=p1;gControllerModel=p2;gControllerEnabled=true;gControllerNextAt=0;gLastReconnectAt=0;}
  else if(cmd=="bms" && gatewayMac(p1)) {gatewayDisconnect(false);gConfigBmsMac=p1;gJkProfile="auto";gBmsEnabled=!gControllerOnlyMode;gBmsNextAt=0;gLastReconnectAt=0;}
  else if(cmd=="mode" && (p1=="controller" || p1=="controller_bms")) {
    gControllerOnlyMode=p1=="controller";gCalcRemainingAh=-1;gCalcLastAt=0;
    if(gControllerOnlyMode){gBmsEnabled=false;gatewayDisconnect(false);}else{gBmsEnabled=gatewayMac(gConfigBmsMac);gBmsNextAt=0;gLastReconnectAt=0;}
  }
  else if(cmd=="bat") {gBatteryType=p1=="flooded"?1:p1=="sealed"?2:p1=="gel"?3:p1=="lithium"?4:0;gBatteryCapacityAh=p2.toFloat();gCalcRemainingAh=-1;gCalcLastAt=0;}
  else if(cmd=="panel") gPanelRatedW=p1.toFloat();
  else if(cmd=="read" && srneWriterReady()) gatewayCtrlStartRefresh();  else if(cmd=="raw" && srneWriterReady()) {
    // raw <hex frame without CRC>, e.g. "raw ff06e01d000f"; CRC is appended.
    const String hex=p1+p2;uint8_t frame[64];size_t n=0;
    for(size_t i=0;i+1<hex.length() && n<62;i+=2)frame[n++]=strtoul(hex.substring(i,i+2).c_str(),nullptr,16);
    const uint16_t crc=modbusCrc(frame,n);frame[n++]=crc&0xff;frame[n++]=crc>>8;
    srneSend(frame,n);gSrneLastTxAt=millis();
  }
  else if(cmd=="cmd" && p1.length()) {
    gActiveCommand="bench";gActiveCommandType=p1;gCommandStartedAt=millis();
    if(deserializeJson(gActivePayload,p2.length()?p2:String("{}"))){gActiveCommand="";BENCH_PORT.println("BENCH_ERR invalid JSON payload");return;}
    gatewayDispatch();return;
  }
  // Controller command paths, exactly as the cloud commands run them.
  else if(cmd=="load" || cmd=="manual" || cmd=="restore") {
    if(!srneWriterReady()){BENCH_PORT.println("BENCH_ERR controller not connected");return;}
    gActiveCommand="bench";gCommandStartedAt=millis();
    if(cmd=="load"){gActiveCommandType="load";gLoadDesired=p1=="on";gLoadModeStage=1;sendSrneRegisterRead(0xe01d,"load_mode");}
    else if(cmd=="manual"){gActiveCommandType="enable_manual_load";gLoadModeStage=3;sendSrneRegisterRead(0xe01d,"load_mode_before_manual");}
    else if(cmd=="restore") {
      gActiveCommandType="restore_load_mode";const int previous=gDailyStore.getInt("prev_load_mode",-1);
      if(previous<0 || previous>17 || previous==15){gatewayResult("failed","No saved previous load mode.");return;}
      gLoadModeStage=4;srneSendAfter(kSrneSendRestoreMode,srneSendGap());
    }
    return;
  }
  else if(cmd!="status") {BENCH_PORT.println("BENCH_ERR unknown or invalid: "+line);return;}
  BENCH_PORT.printf("BENCH_STATE mode=%s ctrl=%s(%s) linked=%d bms=%s enabled=%d linked=%d bat_type=%u cap=%.1f panel=%.0f calc_ah=%.2f model_reported='%s' match=%d fw=%s\n",
    gControllerOnlyMode?"controller":"controller_bms",gConfigControllerMac.c_str(),gControllerModel.c_str(),gSrneClient && gSrneClient->isConnected(),
    gConfigBmsMac.c_str(),gBmsEnabled,gJkClient && gJkClient->isConnected(),gBatteryType,gBatteryCapacityAh,gPanelRatedW,gCalcRemainingAh,
    gControllerModelReported.c_str(),gatewayModelMatch(),kFirmwareVersion);
}
void gatewayBenchTick() {
  static String line;
  while(BENCH_PORT.available()) {
    const char ch=char(BENCH_PORT.read());
    if(ch=='\n' || ch=='\r'){if(line.length())gatewayBenchCommand(line);line="";}
    else if(line.length()<1024)line+=ch;
  }
  static uint32_t at=0;
  if(millis()-at>=15000){at=millis();gatewayBenchCommand("status");}
  static uint32_t jkAt=0;
  if(gBmsEnabled && millis()-jkAt>=5000) {
    jkAt=millis();
    BENCH_PORT.printf("BENCH_JK notes=%lu min=%lu max=%lu too_big=%lu queue_full=%lu buffered=%u linked=%d\n",
      (unsigned long)gBenchJkNotes,(unsigned long)gBenchJkMinSize,(unsigned long)gBenchJkMaxSize,(unsigned long)gBenchJkTooBig,(unsigned long)gBenchJkQueueFull,
      unsigned(gJkFrameLength),gJkClient && gJkClient->isConnected());
  }
}
#endif
// One Firebase task per loop pass. Each request takes about 0.5-2 s (measured);
// running them back to back blocked controller/BMS polling for 10-15 s, so the
// devices are now read between every request. Tasks take turns.
void gatewayCloudStep() {
  static uint8_t turn=0;static uint32_t flushedAt=0;
  // Live readings go first: the app shows a device as connected only while its
  // data in Firebase is recent, so they must not wait behind the other tasks.
  if(gCloudReady && millis()-flushedAt>=2500) {
    flushedAt=millis();flushFirebaseLive();
    // Three failed uploads in a row is a lost cloud, whatever the heartbeat
    // says: say so, so the light blinks yellow, the app sees it, and the next
    // heartbeat has to prove the connection again.
    if(gFlushFailStreak>=3){gFlushFailStreak=0;gCloudReady=false;gNextCloudHeartbeatAt=0;}
    return;
  }
  for(uint8_t i=0;i<3;++i) {
    const uint8_t task=(turn+i)%3;bool ran=false;
    if(task==0 && (!gNextCloudHeartbeatAt || int32_t(millis()-gNextCloudHeartbeatAt)>=0)) {
      // After a failed request try again in 5 s: one slow answer must not
      // stop all uploads and commands for 30 s.
      gCloudHeartbeatAt=millis();gatewayPublishStatus();gNextCloudHeartbeatAt=millis()+5000;ran=true;
    } else if(task==1 && gCloudReady && millis()-gLastQueuePoll>=2000) {gatewayPollCommands();ran=true;}
    else if(task==2 && gCloudReady) ran=gatewayFlushArchive();
    if(ran){turn=(task+1)%3;return;}
  }
}
// Names the part of a loop pass that held it up. loop_max_ms only says that a
// pass was slow: on a live gateway one reached 31 s inside a minute where no
// database request failed at all, so the request timeout was not the cause and
// nothing recorded what was. A pass that stops for half a minute loses BLE
// notifications (468 of them, measured) and breaks the 30 s freshness window
// the app uses to call a gateway online, so the step responsible has to say so
// itself. Only a step of 3 s or more is logged; the quick ones stay silent.
template<class F> inline void loopTimed(const char *name, F step) {
  const uint32_t at=millis();
  step();
  const uint32_t ms=millis()-at;
  if(ms>=3000)diagLog("LOOP_SLOW %s ms=%u",name,unsigned(ms));
}
void gatewayLoop() {
  gLoopAliveAt=millis();
  {static uint32_t loopAt=0;const uint32_t now=millis();if(loopAt && now-loopAt>gDiagLoopMax)gDiagLoopMax=now-loopAt;loopAt=now;}
#ifdef NOXBRAIN_BENCH
  gOperational=true;gatewayBenchTick();
#endif
  // Pair mode never erases credentials; monitoring continues meanwhile.
  if(gPairRequested) {
    gPairRequested=false;gatewayStartPortal();
    if(gOperational)gPortalUntil=millis()+kPairModeMs;
    Serial.println("PAIR_MODE_HOTSPOT_OPEN_20_MIN");
  }
  if(gSetupActive && gOperational && gPortalUntil && !gProvisioning && int32_t(millis()-gPortalUntil)>=0) {
    gatewayStopPortal();gSetupState="complete";Serial.println("PAIR_MODE_HOTSPOT_CLOSED");
    // Re-setup abandoned before handover: go back to the saved configuration.
    if(gSetupTrialPending) {
      gSetupTrialPending=false;gSetupRequestId=gDailyStore.getString("setup_request","");gatewayRestoreSavedConfig();
      Serial.println("PAIR_MODE_TRIAL_REVERTED");
    }
  }
  static uint32_t setupLogAt=0;
  if(gSetupActive && gSetupToken.isEmpty() && millis()-setupLogAt>=10000){setupLogAt=millis();gatewayPrintSetupInfo();}
  loopTimed("web",[]{gWebServer.handleClient();});if(!gRxQueue){delay(20);return;}gatewayDrainRx();
  if(gProvisioning && WiFi.status()!=WL_CONNECTED && millis()-gWifiAttemptAt>30000) {
    gProvisioning=false;gSetupState="failed";gSetupError="Home Wi-Fi connection failed. Check password and 2.4 GHz coverage.";
    gatewayRestoreSavedConfig();
  }
  if(WiFi.status()==WL_CONNECTED) {
    if(gProvisioning)gSetupState="connecting_firebase";
    loopTimed("cloud",[]{gatewayCloudStep();});gatewayDrainRx();
    // Every step that can fail now records why, so this last-resort wording is
    // only reached when nothing was even attempted in 90 s.
    if(gProvisioning && millis()-gWifiAttemptAt>90000) {gProvisioning=false;gSetupState="failed";gSetupError=gNetworkError.length()?gNetworkError:"The gateway joined Wi-Fi but never reached Firebase in 90 seconds.";gatewayRestoreSavedConfig();}
    if(gCloudReady && !gWifiTrial)gatewayWifiPromote();
  } else {
    gCloudReady=false;
    // Losing Wi-Fi (power cut, router reboot, ISP outage) only retries; it
    // never opens the hotspot. Re-setup needs pair mode (3 BOOT presses).
    if(strlen(getWifiSsid()) && millis()-gWifiAttemptAt>15000 && !gProvisioning) {loopTimed("wifi_reconnect",[]{gatewayWifiReconnect();});gWifiAttemptAt=millis();gatewayDrainRx();}
  }
  loopTimed("wifi_trial",[]{gatewayWifiTrialTick();gatewayCloudTrialTick();});
  // Each peripheral has its own lifecycle. A failed JK link never drops SRNE.
  // No connection attempts while the gateway's own Bluetooth scan runs.
  if(gOperational && millis()-gLastReconnectAt>=10000 && !gBleScanRunning) {
    gLastReconnectAt=millis();
    // Like the earlier smooth-running project, slow data never drops a link;
    // only a link silent for 5 minutes is rebuilt (never during parameter work).
    if(srneLinkUp() && !gatewayCtrlBusy() && millis()-(gLatestSrneSampleAt?gLatestSrneSampleAt:gControllerLinkedAt)>300000){diagLog("CTRL_STALE_RECONNECT had_sample=%d",gLatestSrneSampleAt!=0);gatewayDisconnect(true);}
    if(gJkClient && gJkClient->isConnected() && millis()-(gLatestBmsSampleAt?gLatestBmsSampleAt:gBmsLinkedAt)>300000){diagLog("BMS_STALE_RECONNECT had_sample=%d",gLatestBmsSampleAt!=0);gatewayDisconnect(false);}
    if(!srneRs485() && gControllerEnabled && gatewayMac(gConfigControllerMac) && (!gSrneClient || !gSrneClient->isConnected()) && (!gControllerNextAt || int32_t(millis()-gControllerNextAt)>=0)){bool ok=false;loopTimed("ctrl_connect",[&]{ok=gatewayConnect(true);});gControllerNextAt=millis()+(ok?10000:60000);}
    // RS485: reopen the port at the speed found by the last search.
    if(srneRs485() && gControllerEnabled && !gRs485Open && (!gControllerNextAt || int32_t(millis()-gControllerNextAt)>=0)){gatewayRs485Open(gRs485Baud);gControllerLinkedAt=millis();gControllerNextAt=millis()+10000;diagLog("RS485_OPEN baud=%u addr=%u",unsigned(gRs485Baud),unsigned(gRs485Addr));sendSrneLiveRead();}
    if(gBmsEnabled && gatewayMac(gConfigBmsMac) && (!gJkClient || !gJkClient->isConnected()) && (!gBmsNextAt || int32_t(millis()-gBmsNextAt)>=0)){bool ok=false;loopTimed("bms_connect",[&]{ok=gatewayConnect(false);});gBmsNextAt=millis()+(ok?10000:60000);}
  }
  static uint32_t readAt=0,settingsAt=0;
  // Before the senders below, never after: both skip a frame within 400 ms of
  // the last one, and a loop held up long enough for a queued frame and a
  // live read to come due together would otherwise send them back to back --
  // the very thing the gap exists to prevent.
  srneSendPendingTick();
  loopTimed("ctrl_params",[]{gatewayCtrlTick();});
  if(gOperational && millis()-readAt>=1000) {
    readAt=millis();
    // Parameter requests have priority; live data pauses at most 8 s for them.
    const bool liveAllowed=millis()-gSrneLastTxAt>=400 && (!gatewayCtrlBusy() || millis()-gLatestSrneSampleAt>8000);
    if(gControllerEnabled && srneLinkUp() && srneWriterReady() && !srneAddressProbeTick()) {
      if(gSrneLadderDone) {
        gLinkError=(gCtrlPinAsked && gCtrlPin<0)
          ? "This controller's Bluetooth module asks for a PIN before it sends data. Enter its PIN in the app and select the controller again."
          : "Bluetooth and the SRNE data service both work, but the controller answered nothing. Tried Modbus addresses FF, 01 and 60, with replies both requested and not. If its Bluetooth module needs a PIN (the phone asks for one when pairing), enter it in the app and select the controller again.";
        gCtrlVerdict=gLinkError;
      }
      else diagLog("CTRL_RECONNECT_FOR_MODE");
      gatewayDisconnect(true);
      // The ladder asked for this reconnect, so do not spend another ten
      // seconds of the command's budget waiting for the ordinary retry tick:
      // the whole walk has to finish inside select_device's 55 s.
      if(!gSrneLadderDone){gControllerNextAt=millis();gLastReconnectAt=millis()-10000;}
    }
    else if(gControllerEnabled && srneLinkUp() && srneWriterReady() && liveAllowed)sendSrneLiveRead();
    if(gBmsEnabled && gJkClient && gJkClient->isConnected() && gJkChar){if(gBmsJbd)sendJbdRead();else sendJkRead();}
  }
  if(gOperational && srneLinkUp() && srneWriterReady() && millis()-settingsAt>=120000 && gActiveCommand.isEmpty() && !gatewayCtrlBusy()){settingsAt=millis();gatewayCtrlStartRefresh();}
  gatewayRollbackTick();
  gatewayDiagTick();
  if(gBootDown && millis()-gBootDownAt>=kFactoryResetHoldMs && digitalRead(0)==LOW)gatewayFactoryReset();
  // While BOOT is held, blink red so the user sees the factory-reset countdown.
  if(gBootDown && millis()-gBootDownAt>=1000)setStatusLed((millis()/250)%2?48:0,0,0);
  else gatewayUpdateLed();
  delay(10);
}
