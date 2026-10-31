#include <Arduino.h>
#include <NimBLEDevice.h>
#include <NimBLEScan.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <Update.h>
#include <mbedtls/sha256.h>
#include <mbedtls/aes.h>
#include <mbedtls/base64.h>
#include <esp_ota_ops.h>
#include <soc/gpio_reg.h>
#include <time.h>
#include <sys/time.h>
#include <Preferences.h>
#include <Adafruit_NeoPixel.h>
#include <WebServer.h>
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <esp_partition.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <algorithm>
#include <vector>
#include "firebase_roots.h"

// Bench test build only (env "bench-s3"): devices are chosen over the serial
// port and published data is printed there instead of sent to Firebase.
#ifdef NOXBRAIN_BENCH
#if CONFIG_IDF_TARGET_ESP32S3 && ARDUINO_USB_CDC_ON_BOOT
#define BENCH_PORT Serial0
#else
#define BENCH_PORT Serial
#endif
#endif


namespace {
void sendSrneLiveRead();
void sendSrneSettingsRead();
void sendSrneLoadCommand(bool on);
void sendSrneRegisterWrite(uint16_t address, uint16_t value, const char *label);
void sendSrneSettingsWrite(const uint16_t *values);
void sendSrneRead(uint16_t address, uint16_t count);
// Last frame sent to the controller: its BLE module drops a frame that
// arrives right after another one, so every sender keeps a gap.
uint32_t gSrneLastTxAt = 0;
void publishLifetimeState();
void gatewayNotify(NimBLERemoteCharacteristic *, uint8_t *, size_t, bool);
void gatewayOnSettings(const uint8_t *, size_t);
void gatewayPublishControllerSettings();
void gatewayOnLive(const uint8_t *, size_t);
void gatewayArchiveDay(const String &);
void gatewayInitializeSummary(JsonDocument &);
void gatewayPersistHistory(const String &);
void updateLifetimeBatteryCounts(uint8_t soc, float batteryCurrent);
String gConfigControllerMac;
String gConfigBmsMac;
// Which BLE address type last connected each device (-1 unknown, 0 public,
// 1 random). A known device then uses only that type, so a reconnect makes
// one attempt (like the earlier smooth project), not two 6 s attempts.
int8_t gCtrlAddrKind = -1, gBmsAddrKind = -1;
String gDiscoveredControllerMac = "";
String gDiscoveredBmsMac = "";
uint8_t gFailedConnectAttempts = 0;

String getEffectiveControllerMac() {
  if (gConfigControllerMac.length() >= 17) return gConfigControllerMac;
  if (gDiscoveredControllerMac.length() >= 17) return gDiscoveredControllerMac;
  return "";
}

String getEffectiveBmsMac() {
  if (gConfigBmsMac.length() >= 17) return gConfigBmsMac;
  if (gDiscoveredBmsMac.length() >= 17) return gDiscoveredBmsMac;
  return "";
}
String gWifiSsid = "";
String gWifiPassword = "";
String gFirebaseApiKey = "";
String gFirebaseDatabaseUrl = "";
String gFirebaseDeviceEmail = "";
String gFirebaseDevicePassword = "";
String gDeviceId = "";
String gJkProfile = "jk02_32";

WebServer gWebServer(80);
bool gPortalMode = false;

const char* getWifiSsid() { return gWifiSsid.c_str(); }
const char* getWifiPassword() { return gWifiPassword.c_str(); }
const char* getFirebaseApiKey() { return gFirebaseApiKey.c_str(); }
const char* getFirebaseDatabaseUrl() { return gFirebaseDatabaseUrl.c_str(); }
const char* getFirebaseDeviceEmail() { return gFirebaseDeviceEmail.c_str(); }
const char* getFirebaseDevicePassword() { return gFirebaseDevicePassword.c_str(); }
String getDevicePath() {
  if (gDeviceId.length() > 0) return "/devices/" + gDeviceId;
  return "";
}
constexpr uint8_t kStatusLedPin = 48;
Adafruit_NeoPixel gStatusLed(1, kStatusLedPin, NEO_GRB + NEO_KHZ800);
void setStatusLed(uint8_t red, uint8_t green, uint8_t blue);
void resetDatabaseConnection();
Preferences gDailyStore;
NimBLEClient *gJkClient = nullptr;
NimBLEClient *gSrneClient = nullptr;
// BMS notify characteristic: JK FFE1 (also its write channel) or JBD FF01.
NimBLERemoteCharacteristic * volatile gJkChar = nullptr;
// JBD / Xiaoxiang BMS (bms_profile "jbd"): requests go to FF02, replies come
// on FF01. Read-only: the gateway never writes JBD settings.
NimBLERemoteCharacteristic *gJbdWriter = nullptr;
bool gBmsJbd = false;
uint16_t gJbdCells[32] = {};
uint8_t gJbdCellCount = 0;
uint32_t gJbdCellsAt = 0;
uint8_t gJbdNextRequest = 0x04;
NimBLERemoteCharacteristic *gSrneWriter = nullptr;
NimBLERemoteCharacteristic * volatile gSrneNotifier = nullptr;
// Controller link: 0 = Bluetooth (unchanged default), 1 = RS485 on Serial1
// through an auto-direction TTL-RS485 module (TX GPIO18, RX GPIO17). The same
// Modbus frames go over both links; only the transport differs.
constexpr int kRs485RxPin = 17;
constexpr int kRs485TxPin = 18;
uint8_t gCtrlLink = 0;
bool gRs485Open = false;
uint32_t gRs485Baud = 9600;
uint8_t gRs485Addr = 1;
uint8_t gJkFrameBuffer[600] = {};
size_t gJkFrameLength = 0;
bool gConnectionsReady = false;
bool gConnectionEnabled = true;
bool gJkInitialized = false;
String gFirebaseIdToken;
uint32_t gFirebaseAuthAt = 0;
uint32_t gLastFirebaseAuthAttempt = 0;
uint32_t gLastConnectionPoll = 0;
uint32_t gLastLoadPoll = 0;
uint32_t gLastConfigPoll = 0;
uint32_t gLastControllerSettingsPoll = 0;
uint32_t gLastClearPoll = 0;
String gLastControllerSettingsJson;
int32_t gTimezoneOffset=0;
uint8_t gResetHour = 7;
uint8_t gResetMinute = 0;
uint16_t gPvAverageStartMinute = 7 * 60;
uint16_t gPvAverageEndMinute = 17 * 60;
String gPendingControllerJson;
String gPendingBmsJson;
bool gPendingController = false;
bool gPendingBms = false;
String gPendingConfigJson;
bool gPendingConfig = false;
// Consecutive failures of the multi-location PATCH. Only the heartbeat used to
// decide whether the gateway was "on the cloud", so a gateway whose every
// upload timed out still showed a green light and cloud_connected true, and
// the diagnostics log recorded no CLOUD_LOST at all (seen on a live gateway,
// 1.1.38). gatewayCloudStep turns a run of these into an honest loss.
uint8_t gFlushFailStreak = 0;
String gPendingSummaryJson;
bool gPendingSummary = false;
String gPendingHistoryJson;
bool gPendingHistory = false;
String gPendingLifetimeJson;
bool gPendingLifetime = false;
double gPanelWh = 0;
double gPanelAh=0,gLoadAh=0,gBatteryCoverageSeconds=0;
double gBatteryChargeWh = 0;
double gBatteryChargeAh = 0;
double gBatteryDischargeWh = 0;
double gLoadWh = 0;
double gLoadFromPanelWh = 0;
double gLoadFromBatteryWh = 0;
double gLoadFromPanelAh = 0, gLoadFromBatteryAh = 0;
// Controller-derived battery share minus what the BMS shunt reports, in watts.
// Only Controller + BMS Mode has a second meter to disagree with, so this is
// zero in Only Controller Mode and whenever the BMS sample is stale. A steady
// wide gap means something is wired straight to the pack, or one of the two
// meters is wrong; either is worth seeing rather than hiding in the split.
float gBatteryMeterGapW = 0;
float gPvWMax = -1, gPvWMin = -1, gPvVMax = -1, gPvVMin = -1, gPvAMax = -1, gPvAMin = -1;
float gChargeAMax = -1, gChargeAMin = -1, gDischargeWMax = -1, gDischargeWMin = -1, gDischargeAMax = -1, gDischargeAMin = -1;
double gPvWSum = 0, gPvVSum = 0, gPvASum = 0, gChargeASum = 0, gDischargeWSum = 0, gDischargeASum = 0;
double gPvOnWSum = 0, gPvOnVSum = 0, gPvOnASum = 0;
uint32_t gAggregateSamples = 0;
uint32_t gDischargeWSamples = 0, gDischargeASamples = 0;
uint32_t gChargeSamples = 0;
uint32_t gPvOnSamples = 0;
uint32_t gLastEnergySample = 0;
float gLatestBmsVoltage = 0;
float gLatestBmsCurrent = 0;
uint32_t gLatestBmsSampleAt = 0;
uint32_t gDecodedReceivedAt=0;
uint32_t gLastBmsEnergyAt=0;
float gPreviousBmsPower=0,gPreviousBmsCurrent=0;
float gLatestSrnePanelPower = 0;
float gLatestSrneLoadPower = 0;
uint32_t gLatestSrneSampleAt = 0;
// Controller + BMS Mode: learned BMS / controller load-current ratio (see
// learnLoadCalibration), saved with the controller|BMS pair it belongs to.
float gLoadCalRatio = 1.0f;
bool gLoadCalLearned = false;
String gLoadCalId = "";
// Modbus address for Bluetooth frames. Older SRNE modules answer 0xFF, which
// SRNE's own protocol does not actually allow (it documents 1..247), and a
// stricter module drops such a frame without a word -- the link and the data
// service look perfectly healthy while nothing ever arrives. So the known
// candidates are tried in turn, starting with the one that has always worked.
constexpr uint8_t kSrneBleAddresses[] = {0xff, 0x01, 0x60};
// 0 = writes and CCCD without a response, which is what has always been
// sent; 1 = both with a response, the mode that fixed the JK BMS.
uint8_t gSrneRespMode = 0;
bool gSrneLadderDone = false;
uint8_t gSrneBleAddr = 0xff;
uint8_t gSrneAddrIndex = 0;
uint8_t gSrneAddrTries = 0;
uint32_t gSrneAddrTriedAt = 0;
bool gSrneAddrSettled = false;
// "The controller answered at this address" and "a live sample arrived" are
// not the same thing. A settings block, the model text, even a Modbus
// exception all prove the address and the module; only a live frame used to
// count, so a controller that answers everything except the live block was
// walked past by the ladder and finally called not an SRNE Shiner at all.
uint32_t gSrneAnsweredAt = 0;
// Registers in one live read. 0x23 covers 0x0100..0x0122 including both fault
// words; a controller that does not carry the whole block answers with an
// exception instead, so the read steps down to the shortest publishSrneLive
// can still decode (0x22 = 34 registers = 68 bytes, fault words dropped).
uint16_t gSrneLiveCount = 0x23;
bool gSrneLastTxLive = false;
// Why a live block was thrown away, once per link. A frame of the right
// length whose values this firmware cannot believe used to vanish without a
// word, so the report said "answered but not reading" and gave no reason.
bool gSrneLiveRejectLogged = false;
// The BMS equivalents of gSrneAnsweredAt and that note: a BMS answering
// frames no layout can decode looked exactly like a BMS that never answered.
uint32_t gBmsAnsweredAt = 0;
bool gBmsRejectLogged = false;
// Notifications dropped because the RX queue was full. Counted in production
// too, not only on the bench: a cloud pass long enough to fill the queue
// loses frames, and nothing in the collectable log used to say so.
volatile uint32_t gRxDropped = 0;
// One CTRL_WRITE_FAIL per link: a write the module refused went unnoticed.
bool gSrneWriteFailLogged = false;
// The last specific reason the controller could not be read (ladder spent,
// live block unreadable or refused). The ladder's own reconnects clear
// gLinkError, which is how select_device ended up reporting the generic
// text; this survives them and is cleared only by a good live sample or a
// newly selected controller.
String gCtrlVerdict;
// Bluetooth PIN (passkey) for a controller whose module passes no data over
// an unpaired link: the Shiner2430B's BT-TH module answers one frame and then
// nothing until it is paired. The user enters it -- modules let owners change
// it, so there is no default to guess. -1 = none saved. Never logged.
int32_t gCtrlPin = -1;
// Set from the NimBLE host task when the module itself asks for a passkey, so
// the gateway can say a PIN is needed even when none was entered.
volatile bool gCtrlPinAsked = false;
// The BT-TH module's own lock state, from the status frame it sends once per
// connect (see gatewayDrainRx): true while it withholds data for want of its
// PIN. Lets the gateway say so within seconds instead of after the ladder.
bool gSrneLocked = false, gSrneLockLogged = false;
// Pairing with the saved PIN failed on the last controller connect.
bool gCtrlSecureFailed = false;
// Loop heartbeat for the stall guard task: if the main loop stops for two
// minutes (a library call that never returns), the gateway restarts itself
// instead of staying offline until someone cuts its power.
volatile uint32_t gLoopAliveAt = 0;
// Survives a software reset, so the next boot can say why it happened.
RTC_NOINIT_ATTR uint32_t gStallRestartMark;
constexpr uint32_t kStallRestartMark = 0x5741114Cu;
// The controller's BLE module drops a frame that arrives right behind
// another, so a few steps must leave a gap before the next one. Holding the
// whole loop for it stopped the cloud link, the web server and the BLE drain
// as well, so the next frame waits here and the loop sends it. Nothing can
// slip into the gap: the live read and the parameter sender both refuse to
// transmit within 400 ms of the last frame.
enum : uint8_t { kSrneSendNone = 0, kSrneSendSettingsBlock, kSrneSendLoadMode, kSrneSendLoadCommand, kSrneSendRestoreMode };
uint8_t gSrneSendPending = kSrneSendNone;
uint32_t gSrneSendAt = 0;
void srneSendAfter(uint8_t what, uint32_t gapMs) { gSrneSendPending = what; gSrneSendAt = millis() + gapMs; }
// What a sender outside those two must wait before its own frame may go out.
// The load commands used to transmit the moment the cloud handed them over,
// which could be milliseconds after the one-second live read -- exactly the
// back-to-back pair the module drops.
uint32_t srneSendGap() { const uint32_t since = millis() - gSrneLastTxAt; return since >= 400 ? 0 : 400 - since; }
String gSummaryDay;
String gPvOnTime;
String gPvOffTime;
int8_t gPvOutputState = -1;
time_t gPvZeroSince = 0;
// Battery state at the PV ON/OFF events (BMS only; -1 = not measured) and
// the time of the last counted full charge (epoch ms, 0 = none).
float gPvOnSoc = -1, gPvOnAh = -1, gPvOffSoc = -1, gPvOffAh = -1;
float gLatestBmsSoc = -1, gLatestBmsRemainingAh = -1;
uint64_t gLastFullChargeAt = 0;
// Battery state at that last full charge (-1 = not recorded yet).
float gLastFullSoc = -1, gLastFullAh = -1;
// Full charge inside the current reporting day only (Today's Energy card); cleared at the daily reset, unlike the lifetime record above.
uint64_t gDayFullChargeAt = 0;
float gDayFullSoc = -1, gDayFullAh = -1;
time_t gPvRiseSince = 0;
bool gPvNightQualified = false;
uint32_t gFullChargeCount = 0;
uint32_t gFullDischargeCount = 0;
float gAllTimePvPowerMax = -1;
float gAllTimePvCurrentMax = -1;
bool gAllTimeHighEnabled = false;
int8_t gSocMilestoneState = -1;  // 0=empty, 1=between, 2=full
bool gLifetimePublished = false;
uint8_t gFullChargeStreak = 0;
uint8_t gFullDischargeStreak = 0;
// Battery mode and system details set from the app ("system_options").
// Only Controller Mode calculates battery values from controller registers;
// Controller + BMS Mode takes every battery value from the BMS.
bool gControllerOnlyMode = false;
uint8_t gBatteryType = 0;         // 0 = not set, 1 flooded, 2 sealed, 3 gel, 4 lithium
float gBatteryCapacityAh = 0;     // user-entered nominal capacity
float gPanelRatedW = 0;           // user-entered panel rating, 0 = unknown
double gCalcRemainingAh = -1;     // calculated remaining Ah, <0 = not started
uint32_t gCalcLastAt = 0;
// Only Controller Mode: the controller's own SOC (0x0100), as on its display.
uint8_t gCtrlSoc = 0;
float gCalcCurrent = 0;

void loadDailySummaryFromFlash() {
  gDailyStore.begin("daily", false);
  gSummaryDay = gDailyStore.getString("day", "");
  int reset=gDailyStore.getInt("reset_minute",420);gResetHour=reset/60;gResetMinute=reset%60;
  gPvAverageStartMinute=gDailyStore.getInt("pv_start",420);gPvAverageEndMinute=gDailyStore.getInt("pv_end",1020);
  gTimezoneOffset=gDailyStore.getInt("tz_offset",0);
  gPanelWh = gDailyStore.getDouble("panel_wh", 0);
  gPanelAh=gDailyStore.getDouble("panel_ah",0);gLoadAh=gDailyStore.getDouble("load_ah",0);gBatteryCoverageSeconds=gDailyStore.getDouble("bms_seconds",0);
  gBatteryChargeWh = gDailyStore.getDouble("charge_wh", 0);
  gBatteryChargeAh = gDailyStore.getDouble("charge_ah", 0);
  gBatteryDischargeWh = gDailyStore.getDouble("discharge_wh", 0);
  gLoadWh = gDailyStore.getDouble("load_wh", 0);
  gLoadFromPanelWh = gDailyStore.getDouble("load_pv_wh", 0);
  gLoadFromBatteryWh = gDailyStore.getDouble("load_bat_wh", 0);
  gLoadFromPanelAh = gDailyStore.getDouble("load_pv_ah", 0); gLoadFromBatteryAh = gDailyStore.getDouble("load_bat_ah", 0);
  gPvWMax = gDailyStore.getFloat("pv_w_max", -1); gPvWMin = gDailyStore.getFloat("pv_w_min", -1);
  gPvVMax = gDailyStore.getFloat("pv_v_max", -1); gPvVMin = gDailyStore.getFloat("pv_v_min", -1);
  gPvAMax = gDailyStore.getFloat("pv_a_max", -1); gPvAMin = gDailyStore.getFloat("pv_a_min", -1);
  gChargeAMax = gDailyStore.getFloat("chg_a_max", -1); gChargeAMin = gDailyStore.getFloat("chg_a_min", -1);
  gDischargeWMax = gDailyStore.getFloat("dis_w_max", -1); gDischargeWMin = gDailyStore.getFloat("dis_w_min", -1);
  gDischargeAMax = gDailyStore.getFloat("dis_a_max", -1); gDischargeAMin = gDailyStore.getFloat("dis_a_min", -1);
  gPvWSum = gDailyStore.getDouble("pv_w_sum", 0); gPvVSum = gDailyStore.getDouble("pv_v_sum", 0); gPvASum = gDailyStore.getDouble("pv_a_sum", 0);
  gPvOnWSum = gDailyStore.getDouble("pv_on_w_sum", 0);
  gPvOnVSum = gDailyStore.getDouble("pv_on_v_sum", 0); gPvOnASum = gDailyStore.getDouble("pv_on_a_sum", 0);
  gChargeASum = gDailyStore.getDouble("chg_a_sum", 0); gDischargeWSum = gDailyStore.getDouble("dis_w_sum", 0); gDischargeASum = gDailyStore.getDouble("dis_a_sum", 0);
  gAggregateSamples = gDailyStore.getUInt("samples", 0);
  gDischargeWSamples = gDailyStore.getUInt("dis_w_samples", 0); gDischargeASamples = gDailyStore.getUInt("dis_a_samples", 0);
  gChargeSamples = gDailyStore.getUInt("chg_samples", 0);
  gPvOnSamples = gDailyStore.getUInt("pv_on_samples", 0);
  gPvOnTime = gDailyStore.getString("pv_on_time", "");
  gPvOffTime = gDailyStore.getString("pv_off_time", "");
  gPvOutputState = static_cast<int8_t>(gDailyStore.getInt("pv_state", -1));
  gPvZeroSince = static_cast<time_t>(gDailyStore.getULong64("pv_zero_since", 0));
  gPvOnSoc = gDailyStore.getFloat("pv_on_soc", -1); gPvOnAh = gDailyStore.getFloat("pv_on_ah", -1);
  gPvOffSoc = gDailyStore.getFloat("pv_off_soc", -1); gPvOffAh = gDailyStore.getFloat("pv_off_ah", -1);
  gLastFullChargeAt = gDailyStore.getULong64("last_full_at", 0);
  gLastFullSoc = gDailyStore.getFloat("last_full_soc", -1); gLastFullAh = gDailyStore.getFloat("last_full_ah", -1);
  gDayFullChargeAt = gDailyStore.getULong64("day_full_at", 0);
  gDayFullSoc = gDailyStore.getFloat("day_full_soc", -1); gDayFullAh = gDailyStore.getFloat("day_full_ah", -1);
  gPvRiseSince = static_cast<time_t>(gDailyStore.getULong64("pv_rise_since", 0));
  gPvNightQualified = gDailyStore.getBool("pv_night_ok", false);
  gFullChargeCount = gDailyStore.getUInt("full_chg_count", 0);
  gFullDischargeCount = gDailyStore.getUInt("full_dis_count", 0);
  gAllTimePvPowerMax = gDailyStore.getFloat("all_pv_w_max", -1);
  gAllTimePvCurrentMax = gDailyStore.getFloat("all_pv_a_max", -1);
  gSocMilestoneState = static_cast<int8_t>(gDailyStore.getInt("soc_milestone", -1));
  gBatteryType = gDailyStore.getUChar("bat_type", 0); if (gBatteryType > 4) gBatteryType = 0;
  gBatteryCapacityAh = gDailyStore.getFloat("bat_cap", 0);
  gPanelRatedW = gDailyStore.getFloat("panel_w", 0);
  gCalcRemainingAh = gDailyStore.getDouble("calc_ah", -1);
  // Version 1 used a single raw notification, which can be fragmented by BLE.
  // Discard that untrustworthy initial counter and start with verified samples.
  if (gDailyStore.getUInt("lifetime_v", 0) < 4) {
    gFullChargeCount = 0;
    gFullDischargeCount = 0;
    gSocMilestoneState = -1;
    gDailyStore.putUInt("lifetime_v", 4);
  }
  if (gDailyStore.getUInt("all_time_high_v", 0) < 2) {
    gAllTimePvPowerMax = 0;
    gAllTimePvCurrentMax = 0;
    gAllTimeHighEnabled = true;
    gDailyStore.putUInt("all_time_high_v", 2);
  } else {
    // NVS keys are limited to 15 characters ("all_time_high_enabled" never saved).
    gAllTimeHighEnabled = gDailyStore.getBool("ath_enabled", true);
  }
  // Do not treat a firmware start as a real PV ON/OFF event. Clear the first
  // boot-time value created by the initial rollout; later transitions are real.
  if (gDailyStore.getUInt("pv_event_v", 0) < 6) {
    gPvOnTime = "";
    gPvOffTime = "";
    gDailyStore.putUInt("pv_event_v", 6);
  }
  // Older firmware stored battery-discharge values in these load-stat fields.
  // Clear only those stale statistics once; energy totals and source shares stay intact.
  if (gDailyStore.getUInt("dis_stats_v", 0) < 2) {
    gDischargeWMax = gDischargeWMin = gDischargeAMax = gDischargeAMin = -1;
    gDischargeWSum = gDischargeASum = 0;
    gDischargeWSamples = gDischargeASamples = 0;
    gDailyStore.putUInt("dis_stats_v", 2);
  }
  const String savedCtrlMac = gDailyStore.getString("ctrl_mac", "");
  if (savedCtrlMac.length() >= 17) gConfigControllerMac = savedCtrlMac;
  gCtrlLink = gDailyStore.getUChar("ctrl_link", 0) == 1 ? 1 : 0;
  gRs485Baud = gDailyStore.getUInt("rs485_baud", 9600);
  gRs485Addr = gDailyStore.getUChar("rs485_addr", 1);
  gSrneRespMode = gDailyStore.getUChar("srne_ble_mode", 0);
  const String savedBmsMac = gDailyStore.getString("bms_mac", "");
  if (savedBmsMac.length() >= 17) gConfigBmsMac = savedBmsMac;
  gDiscoveredControllerMac = gDailyStore.getString("disc_ctrl_mac", "");
  gDiscoveredBmsMac = gDailyStore.getString("disc_bms_mac", "");
  gLoadCalId = gDailyStore.getString("lcal_id", "");
  gLoadCalRatio = gDailyStore.getFloat("lcal_ratio", 1.0f);
  gLoadCalLearned = gLoadCalId.length() > 0 && gLoadCalRatio >= 0.85f && gLoadCalRatio <= 1.15f;
  if (!gLoadCalLearned) { gLoadCalId = ""; gLoadCalRatio = 1.0f; }
  Serial.printf("MAC_LOADED config_ctrl=%s config_bms=%s disc_ctrl=%s disc_bms=%s\n",
                gConfigControllerMac.c_str(), gConfigBmsMac.c_str(),
                gDiscoveredControllerMac.c_str(), gDiscoveredBmsMac.c_str());
}

// Stored secrets (Wi-Fi and device-account passwords, saved networks) are
// AES-256-CTR encrypted with a key derived from this chip's factory MAC, so a
// plain flash dump does not reveal them. This is deliberately not flash
// encryption: any ESP32 must stay re-flashable with the web flasher.
void secretKey(uint8_t key[32]) {
  uint8_t mac[6];esp_efuse_mac_get_default(mac);
  static const char kSalt[]="NoxBrain-NVS-v1";
  mbedtls_sha256_context hash;mbedtls_sha256_init(&hash);mbedtls_sha256_starts_ret(&hash,0);
  mbedtls_sha256_update_ret(&hash,reinterpret_cast<const uint8_t *>(kSalt),sizeof(kSalt)-1);
  mbedtls_sha256_update_ret(&hash,mac,sizeof(mac));mbedtls_sha256_finish_ret(&hash,key);mbedtls_sha256_free(&hash);
}
void secretCtr(const uint8_t iv[16], const uint8_t *in, uint8_t *out, size_t length) {
  uint8_t key[32];secretKey(key);
  mbedtls_aes_context aes;mbedtls_aes_init(&aes);mbedtls_aes_setkey_enc(&aes,key,256);
  uint8_t nonce[16],block[16]={};size_t offset=0;memcpy(nonce,iv,16);
  mbedtls_aes_crypt_ctr(&aes,length,&offset,nonce,block,in,out);
  mbedtls_aes_free(&aes);memset(key,0,sizeof(key));
}
String secretEncrypt(const String &plain) {
  if(plain.isEmpty())return "";
  std::vector<uint8_t> raw(16+plain.length());esp_fill_random(raw.data(),16);
  secretCtr(raw.data(),reinterpret_cast<const uint8_t *>(plain.c_str()),raw.data()+16,plain.length());
  size_t needed=0;mbedtls_base64_encode(nullptr,0,&needed,raw.data(),raw.size());
  std::vector<uint8_t> text(needed+1,0);size_t written=0;
  if(mbedtls_base64_encode(text.data(),text.size(),&written,raw.data(),raw.size()))return "";
  return String("enc1:")+String(reinterpret_cast<const char *>(text.data()));
}
String secretDecrypt(const String &stored) {
  if(!stored.startsWith("enc1:"))return stored;
  const String body=stored.substring(5);size_t needed=0;
  mbedtls_base64_decode(nullptr,0,&needed,reinterpret_cast<const uint8_t *>(body.c_str()),body.length());
  std::vector<uint8_t> raw(needed+1,0);size_t length=0;
  if(mbedtls_base64_decode(raw.data(),raw.size(),&length,reinterpret_cast<const uint8_t *>(body.c_str()),body.length()) || length<16)return "";
  std::vector<uint8_t> plain(length-16+1,0);secretCtr(raw.data(),raw.data()+16,plain.data(),length-16);
  return String(reinterpret_cast<const char *>(plain.data()));
}
// Reads a secret; values written by older firmware in plain text are
// encrypted in place on first read.
String secretGet(const char *key) {
  const String stored=gDailyStore.getString(key,"");
  if(stored.length() && !stored.startsWith("enc1:")){gDailyStore.putString(key,secretEncrypt(stored));return stored;}
  return secretDecrypt(stored);
}
void secretPut(const char *key, const String &value) { gDailyStore.putString(key,secretEncrypt(value)); }

void loadCredentialsFromFlash() {
  uint8_t baseMac[6];
  esp_read_mac(baseMac, ESP_MAC_WIFI_STA);
  char defaultChipId[16];
  snprintf(defaultChipId, sizeof(defaultChipId), "NOX-%02X%02X%02X", baseMac[3], baseMac[4], baseMac[5]);

  const String savedDevId = gDailyStore.getString("device_id", "");
  if (savedDevId.length()) gDeviceId = savedDevId;
  else gDeviceId = String(defaultChipId);

  const String ssid = gDailyStore.getString("wifi_ssid", "");
  if (ssid.length()) gWifiSsid = ssid;
  const String pass = secretGet("wifi_pass");
  if (pass.length()) gWifiPassword = pass;
  const String apiKey = secretGet("fb_api_key");
  if (apiKey.length()) gFirebaseApiKey = apiKey;
  const String dbUrl = gDailyStore.getString("fb_db_url", "");
  if (dbUrl.length()) gFirebaseDatabaseUrl = dbUrl;
  const String email = secretGet("fb_email");
  if (email.length()) gFirebaseDeviceEmail = email;
  const String devPass = secretGet("fb_pass");
  if (devPass.length()) gFirebaseDevicePassword = devPass;
  // Never print Wi-Fi, account or database details to the serial console.
  Serial.printf("CREDENTIALS_LOADED device_id=%s wifi=%s cloud=%s\n", gDeviceId.c_str(),
                gWifiSsid.length() ? "saved" : "none", gFirebaseDatabaseUrl.length() ? "saved" : "none");
}

void saveDailySummaryToFlash() {
  gDailyStore.putString("day", gSummaryDay);
  gDailyStore.putDouble("panel_wh", gPanelWh);
  gDailyStore.putDouble("panel_ah",gPanelAh);gDailyStore.putDouble("load_ah",gLoadAh);gDailyStore.putDouble("bms_seconds",gBatteryCoverageSeconds);
  gDailyStore.putDouble("charge_wh", gBatteryChargeWh);
  gDailyStore.putDouble("charge_ah", gBatteryChargeAh);
  gDailyStore.putDouble("discharge_wh", gBatteryDischargeWh);
  gDailyStore.putDouble("load_wh", gLoadWh);
  gDailyStore.putDouble("load_pv_wh", gLoadFromPanelWh);
  gDailyStore.putDouble("load_bat_wh", gLoadFromBatteryWh);
  gDailyStore.putDouble("load_pv_ah", gLoadFromPanelAh); gDailyStore.putDouble("load_bat_ah", gLoadFromBatteryAh);
  gDailyStore.putFloat("pv_w_max", gPvWMax); gDailyStore.putFloat("pv_w_min", gPvWMin);
  gDailyStore.putFloat("pv_v_max", gPvVMax); gDailyStore.putFloat("pv_v_min", gPvVMin);
  gDailyStore.putFloat("pv_a_max", gPvAMax); gDailyStore.putFloat("pv_a_min", gPvAMin);
  gDailyStore.putFloat("chg_a_max", gChargeAMax); gDailyStore.putFloat("chg_a_min", gChargeAMin);
  gDailyStore.putFloat("dis_w_max", gDischargeWMax); gDailyStore.putFloat("dis_w_min", gDischargeWMin);
  gDailyStore.putFloat("dis_a_max", gDischargeAMax); gDailyStore.putFloat("dis_a_min", gDischargeAMin);
  gDailyStore.putDouble("pv_w_sum", gPvWSum); gDailyStore.putDouble("pv_v_sum", gPvVSum); gDailyStore.putDouble("pv_a_sum", gPvASum);
  gDailyStore.putDouble("pv_on_w_sum", gPvOnWSum);
  gDailyStore.putDouble("pv_on_v_sum", gPvOnVSum); gDailyStore.putDouble("pv_on_a_sum", gPvOnASum);
  gDailyStore.putDouble("chg_a_sum", gChargeASum); gDailyStore.putDouble("dis_w_sum", gDischargeWSum); gDailyStore.putDouble("dis_a_sum", gDischargeASum);
  gDailyStore.putUInt("samples", gAggregateSamples);
  gDailyStore.putUInt("dis_w_samples", gDischargeWSamples); gDailyStore.putUInt("dis_a_samples", gDischargeASamples);
  gDailyStore.putUInt("chg_samples", gChargeSamples);
  gDailyStore.putUInt("pv_on_samples", gPvOnSamples);
  gDailyStore.putUInt("dis_stats_v", 2);
  gDailyStore.putString("pv_on_time", gPvOnTime);
  gDailyStore.putString("pv_off_time", gPvOffTime);
  gDailyStore.putInt("pv_state", gPvOutputState);
  gDailyStore.putULong64("pv_zero_since", static_cast<uint64_t>(gPvZeroSince));
  gDailyStore.putFloat("pv_on_soc", gPvOnSoc); gDailyStore.putFloat("pv_on_ah", gPvOnAh);
  gDailyStore.putFloat("pv_off_soc", gPvOffSoc); gDailyStore.putFloat("pv_off_ah", gPvOffAh);
  gDailyStore.putULong64("last_full_at", gLastFullChargeAt);
  gDailyStore.putFloat("last_full_soc", gLastFullSoc); gDailyStore.putFloat("last_full_ah", gLastFullAh);
  gDailyStore.putULong64("day_full_at", gDayFullChargeAt);
  gDailyStore.putFloat("day_full_soc", gDayFullSoc); gDailyStore.putFloat("day_full_ah", gDayFullAh);
  gDailyStore.putULong64("pv_rise_since", static_cast<uint64_t>(gPvRiseSince));
  gDailyStore.putBool("pv_night_ok", gPvNightQualified);
  gDailyStore.putUInt("pv_event_v", 6);
  gDailyStore.putUInt("full_chg_count", gFullChargeCount);
  gDailyStore.putUInt("full_dis_count", gFullDischargeCount);
  gDailyStore.putFloat("all_pv_w_max", gAllTimePvPowerMax);
  gDailyStore.putFloat("all_pv_a_max", gAllTimePvCurrentMax);
  gDailyStore.putBool("ath_enabled", gAllTimeHighEnabled);
  gDailyStore.putUInt("all_time_high_v", 2);
  gDailyStore.putInt("soc_milestone", gSocMilestoneState);
  gDailyStore.putUInt("lifetime_v", 4);
}

void repairInvalidChargeSummary() {
  if(!isfinite(gBatteryChargeWh) || !isfinite(gBatteryChargeAh)) Serial.println("SUMMARY_INVALID_REQUIRES_REVIEW");
}

String summaryMetric(float value) { return value < 0 ? String("null") : String(value, 2); }
// Panel output as a percentage of the user's panel rating; null while the
// rating or the power value is unknown.
String panelOutputPct(float watts) {
  return (gPanelRatedW > 0 && watts >= 0) ? String(watts / gPanelRatedW * 100.0f, 1) : String("null");
}

String chargingModeName(uint8_t code) {
  switch (code) {
    case 0: return "Off";
    case 1: return "Charging";
    case 2: return "MPPT";
    case 3: return "Equalizing";
    case 4: return "Absorption";  // SRNE protocol calls it "boost"; the SRNE app shows Absorption.
    case 5: return "Float";
    case 6: return "Current Limiting";
    default: return "";
  }
}

String localEventTime(time_t epoch) {
  struct tm localNow;
  localtime_r(&epoch, &localNow);
  char value[16];
  strftime(value, sizeof(value), "%I:%M %p", &localNow);
  return String(value);
}

String currentTimestampMillis(uint32_t sampledAt=0) {
  struct timeval now;gettimeofday(&now,nullptr);
  if(now.tv_sec<1700000000)return "0";
  char buffer[24];snprintf(buffer,sizeof(buffer),"%llu",static_cast<unsigned long long>(now.tv_sec)*1000ULL+now.tv_usec/1000-(sampledAt?millis()-sampledAt:0));
  return String(buffer);
}


String gFirebaseRefreshToken, gNetworkError;
// Why the last Bluetooth link attempt failed. The gateway always knew this,
// but it only ever went to the serial port, so a phone saw the same vague
// timeout whether the device was out of reach or simply spoke another
// protocol. Cleared once data actually arrives, not merely on a link.
String gLinkError;
uint32_t gFirebaseTokenLifetime = 3300000;
bool validCloudUrl(const String &url) {
  if (!url.startsWith("https://") || url.indexOf('?', 8) >= 0 || url.indexOf('#', 8) >= 0 || url.indexOf('@', 8) >= 0) return false;
  String host = url.substring(8);
  return host.indexOf('/') < 0 && (host.endsWith(".firebaseio.com") || host.endsWith(".firebasedatabase.app"));
}
String getFirebaseAuthParam() { return gFirebaseIdToken.length() ? "?auth=" + gFirebaseIdToken : ""; }
// Field diagnostics on the serial port: one line per state change or failure,
// with free heap. Never prints tokens, passwords or full database URLs.
// The last diagnostic lines, kept in RAM so the app can collect them
// without a PC on the serial port. Roughly 6 KB, and never any secret:
// diagLog already logs paths without hosts and without the auth token.
constexpr uint8_t kDiagRingSize = 40;
String gDiagRing[kDiagRingSize];
uint8_t gDiagRingNext = 0;
void diagLog(const char *fmt, ...) {
  char text[200];
  va_list args; va_start(args, fmt); vsnprintf(text, sizeof(text), fmt, args); va_end(args);
  char line[280];
  snprintf(line, sizeof(line), "DIAG t=%lus heap=%u maxblk=%u %s\n", static_cast<unsigned long>(millis() / 1000),
           static_cast<unsigned>(ESP.getFreeHeap()), static_cast<unsigned>(heap_caps_get_largest_free_block(MALLOC_CAP_8BIT)), text);
  Serial.print(line);
#if CONFIG_IDF_TARGET_ESP32S3 && ARDUINO_USB_CDC_ON_BOOT
  Serial0.print(line);  // The USB-UART (COM) port; Serial is the native USB port here.
#endif
  String kept(line);
  kept.trim();
  gDiagRing[gDiagRingNext] = kept;
  gDiagRingNext = uint8_t((gDiagRingNext + 1) % kDiagRingSize);
}
bool firebaseAuthenticate() {
  // Each of these used to return quietly, so a setup that stopped here ended
  // with the generic "check Internet, account and rules" and sent the user
  // looking in the wrong place. Say what actually stopped it.
  if (WiFi.status() != WL_CONNECTED) { gNetworkError="Gateway is not connected to Wi-Fi."; return false; }
  // There is no battery-backed clock: until NTP answers, the login token and
  // the TLS certificate dates cannot be judged, so there is nothing to try.
  if (time(nullptr) < 1700000000) { gNetworkError="Gateway clock is not set. Its Wi-Fi must reach the Internet and allow time sync (NTP, UDP port 123)."; return false; }
  if (!validCloudUrl(getFirebaseDatabaseUrl())) { gNetworkError="Saved database address is not a Firebase URL."; return false; }
  if (gFirebaseIdToken.length() && millis() - gFirebaseAuthAt < gFirebaseTokenLifetime) return true;
  if (!strlen(getFirebaseApiKey()) || !strlen(getFirebaseDeviceEmail()) || !strlen(getFirebaseDevicePassword())) { gNetworkError="Firebase credentials are incomplete"; return false; }
  if (gLastFirebaseAuthAttempt && millis()-gLastFirebaseAuthAttempt < 10000) return false;
  gLastFirebaseAuthAttempt=millis();
  // Token renewal is a second HTTPS request with its own handshake, inside the
  // same loop pass as whatever asked for it, so its cost has to be visible
  // separately from the database request it precedes.
  const uint32_t authStartedAt=millis();
  // The kept-alive database TLS link holds the memory a second handshake
  // needs (measured: -32512 allocation failure at maxblk 28 KB, then every
  // token renewal failed and the gateway stayed off the cloud). Close it first.
  resetDatabaseConnection();
  WiFiClientSecure client; client.setCACert(kGoogleTrustRoots); HTTPClient http; http.setTimeout(7000);
  JsonDocument request, response;
  request["email"]=getFirebaseDeviceEmail(); request["password"]=getFirebaseDevicePassword(); request["returnSecureToken"]=true;
  String body; serializeJson(request,body);
  if (!http.begin(client,String("https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=")+getFirebaseApiKey())) { gNetworkError="Could not open a connection to the Firebase login service."; diagLog("AUTH_BEGIN_FAIL"); return false; }
  http.addHeader("Content-Type","application/json"); int code=http.POST(body); String raw=http.getString(); http.end();
  if (deserializeJson(response,raw) || code!=200 || !response["idToken"].is<String>()) {
    gFirebaseIdToken=""; gNetworkError=String("Firebase login failed: ")+(response["error"]["message"] | "check Internet and account");
    diagLog("AUTH_FAIL code=%d ms=%u %s", code, static_cast<unsigned>(millis()-authStartedAt), gNetworkError.c_str()); return false;
  }
  gFirebaseIdToken=response["idToken"].as<String>(); gFirebaseAuthAt=millis(); gNetworkError="";
  // First 8 characters of the account UID: shows which device account the
  // gateway uses (matches gateway_devices in Firebase), without secrets.
  diagLog("AUTH_OK uid=%.8s ms=%u", (response["localId"] | ""), static_cast<unsigned>(millis()-authStartedAt));
  return true;
}


// One kept-alive TLS connection to the user's database. A full TLS handshake
// per request blocked the loop for seconds and let BLE packets overflow.
WiFiClientSecure gDbClient;
bool gDbClientReady = false;
void resetDatabaseConnection() { gDbClient.stop(); }
// Per-minute request statistics for diagnostics (see gatewayDiagTick).
uint32_t gDiagReqCount = 0, gDiagReqFail = 0, gDiagReqMsTotal = 0, gDiagReqMsMax = 0, gDiagLoopMax = 0, gDiagReqReused = 0;
volatile uint32_t gDiagNotes = 0;
// A handshake that fails for memory must not be retried at once. Measured on
// a live gateway (serial capture, 1.1.38): once start_ssl_client returned
// -32512 "SSL - Memory allocation failed", the failure closed the link, so
// every following request needed a handshake of its own, each one fragmenting
// the heap further -- the gateway never reached Firebase again until its power
// was cut. Waiting, doubling, gives the heap time to give a block back.
uint32_t gDbBackoffUntil = 0, gDbBackoffMs = 0;
constexpr uint32_t kDbBackoffMinMs = 2000, kDbBackoffMaxMs = 30000;
int databaseRequest(const char *method, const String &url, const String &payload, String *response = nullptr) {
  const uint32_t startedAt = millis();
  if (!gDbClientReady) { gDbClient.setCACert(kGoogleTrustRoots); gDbClientReady = true; }
  const bool reused = gDbClient.connected();
  if (reused) ++gDiagReqReused;  // Kept-alive TLS link reused (no new handshake).
  // Only a new handshake waits: an open link costs no large allocation, so a
  // request that can reuse one still goes out during the backoff.
  if (!reused && gDbBackoffUntil && int32_t(millis() - gDbBackoffUntil) < 0) { ++gDiagReqCount; ++gDiagReqFail; return -1; }
  // Must outlive the call: HTTPClient's destructor stops its client, which
  // closed the kept-alive link after every request (measured: 0 reused, ~2 s
  // TLS handshake per request).
  // 4 s cut off requests that were about to succeed: the same capture timed
  // successful replies at 7.5 s and 9 s on a slow uplink, while every failure
  // sat at exactly 4 005-4 018 ms, the read timeout. Each one then closed the
  // kept-alive link and forced the handshake above. The connect phase keeps
  // its own 4 s: a link that cannot be opened is not worth a longer wait.
  static HTTPClient http; http.setReuse(true); http.setConnectTimeout(4000); http.setTimeout(10000);
  if (!http.begin(gDbClient, url)) { gDbClient.stop(); return -1; }
  http.addHeader("Content-Type", "application/json");
  const int status = http.sendRequest(method, payload);
  String body = status > 0 ? http.getString() : String();
  http.end();
  if (status <= 0) gDbClient.stop();  // Stale keep-alive; reconnect next time.
  if (status > 0) { gDbBackoffMs = 0; gDbBackoffUntil = 0; }
  else if (!reused) {
    gDbBackoffMs = gDbBackoffMs ? (gDbBackoffMs * 2 > kDbBackoffMaxMs ? kDbBackoffMaxMs : gDbBackoffMs * 2) : kDbBackoffMinMs;
    gDbBackoffUntil = millis() + gDbBackoffMs;
    diagLog("DB_BACKOFF ms=%u", static_cast<unsigned>(gDbBackoffMs));
  }
  const uint32_t tookMs = millis() - startedAt;
  ++gDiagReqCount; gDiagReqMsTotal += tookMs; if (tookMs > gDiagReqMsMax) gDiagReqMsMax = tookMs;
  if (status < 200 || status >= 300) ++gDiagReqFail;
  if (status < 200 || status >= 300) {
    // Path only: the host and the ?auth= token are never logged.
    const int from = url.indexOf("/devices/"), query = url.indexOf('?');
    diagLog("DB_FAIL %s %s status=%d bytes=%u ms=%u", method, url.substring(from < 0 ? 0 : from, query < 0 ? url.length() : query).c_str(), status, static_cast<unsigned>(payload.length()), static_cast<unsigned>(tookMs));
  }
  if (response) *response = body;
  return status;
}

int jsonNumber(const String &json, const char *key, int fallback = -1) {
  const String marker = String("\"") + key + "\"";
  const int keyAt = json.indexOf(marker);
  if (keyAt < 0) return fallback;
  const int colon = json.indexOf(':', keyAt + marker.length());
  if (colon < 0) return fallback;
  int start = colon + 1;
  while (start < json.length() && (json[start] == ' ' || json[start] == '"')) ++start;
  int end = start;
  while (end < json.length() && (isDigit(json[end]) || json[end] == '-')) ++end;
  return end > start ? json.substring(start, end).toInt() : fallback;
}

uint64_t jsonUint64(const String &json, const char *key, uint64_t fallback = 0) {
  const String marker = String("\"") + key + "\"";
  const int keyAt = json.indexOf(marker);
  if (keyAt < 0) return fallback;
  const int colon = json.indexOf(':', keyAt + marker.length());
  if (colon < 0) return fallback;
  int start = colon + 1;
  while (start < json.length() && (json[start] == ' ' || json[start] == '"')) ++start;
  int end = start;
  while (end < json.length() && isDigit(json[end])) ++end;
  return end > start ? static_cast<uint64_t>(json.substring(start, end).toDouble()) : fallback;
}

void clearAllStoredData(uint64_t requestedAt) {
  gSummaryDay = "";gPanelAh=gLoadAh=gBatteryCoverageSeconds=0;
  gPanelWh = gBatteryChargeWh = gBatteryChargeAh = gBatteryDischargeWh = gLoadWh = gLoadFromPanelWh = gLoadFromBatteryWh = 0;
  gPvWMax = gPvWMin = gPvVMax = gPvVMin = gPvAMax = gPvAMin = gChargeAMax = gChargeAMin = gDischargeWMax = gDischargeWMin = gDischargeAMax = gDischargeAMin = -1;
  gPvWSum = gPvVSum = gPvASum = gChargeASum = gDischargeWSum = gDischargeASum = 0;
  gAggregateSamples = gDischargeWSamples = gDischargeASamples = gChargeSamples = 0;
  gLastEnergySample = 0;gLastBmsEnergyAt=0;gPvOnWSum=gPvOnVSum=gPvOnASum=0;gPvOnSamples=0;gLoadFromPanelAh=gLoadFromBatteryAh=0;
  gPvOnTime = gPvOffTime = ""; gPvOutputState = -1; gPvZeroSince = 0; gPvRiseSince = 0; gPvNightQualified = false;
  gPvOnSoc = gPvOnAh = gPvOffSoc = gPvOffAh = -1; gLastFullChargeAt = 0; gLastFullSoc = gLastFullAh = -1; gDayFullChargeAt = 0; gDayFullSoc = gDayFullAh = -1;
  gFullChargeCount = gFullDischargeCount = 0; gSocMilestoneState = -1; gFullChargeStreak = gFullDischargeStreak = 0;
  gAllTimePvPowerMax = gAllTimePvCurrentMax = 0; gAllTimeHighEnabled = true;
  gLifetimePublished = false;
  gPendingSummary = gPendingHistory = false;
  // Clear daily and lifetime statistical keys, but preserve WiFi, Firebase & Device credentials
  const char* statsKeys[] = {
    "day", "panel_wh", "panel_ah", "load_ah", "bms_seconds", "charge_wh", "charge_ah", "discharge_wh", "load_wh",
    "load_pv_wh", "load_bat_wh", "pv_w_max", "pv_w_min", "pv_v_max", "pv_v_min",
    "pv_a_max", "pv_a_min", "chg_a_max", "chg_a_min", "dis_w_max", "dis_w_min",
    "dis_a_max", "dis_a_min", "pv_w_sum", "pv_v_sum", "pv_a_sum", "pv_on_w_sum", "pv_on_v_sum", "pv_on_a_sum", "load_pv_ah", "load_bat_ah",
    "chg_a_sum", "dis_w_sum", "dis_a_sum", "samples", "dis_w_samples", "dis_a_samples",
    "chg_samples", "pv_on_samples", "pv_on_time", "pv_off_time", "pv_state",
    "pv_zero_since", "pv_rise_since", "pv_night_ok", "full_chg_count", "full_dis_count",
    "pv_on_soc", "pv_on_ah", "pv_off_soc", "pv_off_ah", "last_full_at", "last_full_soc", "last_full_ah", "day_full_at", "day_full_soc", "day_full_ah",
    "all_pv_w_max", "all_pv_a_max", "ath_enabled", "soc_milestone"
  };
  for (const char* key : statsKeys) {
    gDailyStore.remove(key);
  }
  gDailyStore.putULong64("clear_data_at", requestedAt);
  saveDailySummaryToFlash();
  publishLifetimeState();
  Serial.println("ALL_STORED_STATISTICS_CLEARED_CREDENTIALS_PRESERVED");
}


float jsonFloat(const String &json, const char *key, float fallback = -1.0f) {
  const String marker = String("\"") + key + "\"";
  const int keyAt = json.indexOf(marker);
  if (keyAt < 0) return fallback;
  const int colon = json.indexOf(':', keyAt + marker.length());
  if (colon < 0) return fallback;
  int start = colon + 1;
  while (start < json.length() && (json[start] == ' ' || json[start] == '"')) ++start;
  int end = start;
  while (end < json.length() && (isDigit(json[end]) || json[end] == '-' || json[end] == '.')) ++end;
  return end > start ? json.substring(start, end).toFloat() : fallback;
}


void firebasePatchLive(const String &json, bool controller) {
#ifdef NOXBRAIN_BENCH
  static uint32_t printedAt[2] = {};
  if (millis() - printedAt[controller] >= 3000 || json.indexOf("controller_settings") >= 0) {
    printedAt[controller] = millis();
    BENCH_PORT.println(String(controller ? "BENCH_CTRL " : "BENCH_BMS ") + json);
  }
#endif
  // Merge into a still-unsent patch: a 1 s live sample must not erase
  // other pending fields (controller settings, snapshots) before the flush.
  // While the cloud answers, a patch waits about a second, so the merge is
  // cheap and does its job. While the cloud is unreachable nothing is ever
  // flushed, and merging every second then costs two documents and a full
  // reserialize of a buffer no one is waiting for -- heap churn at exactly
  // the moment a handshake needs a large block. Past that age the newest
  // sample simply replaces the old one, at a fixed cost.
  constexpr uint32_t kMergeWhileFreshMs = 10000;
  static uint32_t pendingSince[2] = {};
  const uint8_t slot = controller ? 1 : 0;
  String &pending = controller ? gPendingControllerJson : gPendingBmsJson;
  bool &isPending = controller ? gPendingController : gPendingBms;
  const bool mergeable = isPending && millis() - pendingSince[slot] < kMergeWhileFreshMs;
  if (mergeable) {
    JsonDocument merged, update;
    if (!deserializeJson(merged, pending) && !deserializeJson(update, json)) {
      for (JsonPair field : update.as<JsonObject>()) merged[field.key()].set(field.value());
      pending = "";
      serializeJson(merged, pending);
    } else pending = json;
  } else { pending = json; pendingSince[slot] = millis(); }
  isPending = true;
  Serial.println("FIREBASE_LIVE_QUEUED");
}

void firebasePatchSummary(const String &json) {
#ifdef NOXBRAIN_BENCH
  static uint32_t printedAt = 0;
  if (millis() - printedAt >= 20000) { printedAt = millis(); BENCH_PORT.println("BENCH_SUMMARY " + json); }
#endif
  gPendingSummaryJson = json;
  gPendingSummary = true;
  Serial.println("FIREBASE_SUMMARY_QUEUED");
}

void firebasePatchHistory(const String &json) {
  gPendingHistoryJson = json;
  gPendingHistory = true;
  Serial.println("FIREBASE_HISTORY_QUEUED");
}

void firebasePatchLifetime(const String &json) {
#ifdef NOXBRAIN_BENCH
  BENCH_PORT.println("BENCH_LIFETIME " + json);
#endif
  gPendingLifetimeJson = json;
  gPendingLifetime = true;
  Serial.println("FIREBASE_LIFETIME_QUEUED");
}

void publishLifetimeState() {
  firebasePatchLifetime(String("{\"full_charge_count\":") + String(gFullChargeCount) +
    ",\"full_discharge_count\":" + String(gFullDischargeCount) +
    ",\"pv_power_max\":" + summaryMetric(gAllTimePvPowerMax) +
    ",\"pv_current_max\":" + summaryMetric(gAllTimePvCurrentMax) +
    ",\"pv_output_max_pct\":" + panelOutputPct(gAllTimePvPowerMax) +
    ",\"last_full_charge_at\":" + (gLastFullChargeAt ? String(static_cast<unsigned long long>(gLastFullChargeAt)) : String("null")) +
    ",\"last_full_charge_soc\":" + summaryMetric(gLastFullSoc) + ",\"last_full_charge_ah\":" + summaryMetric(gLastFullAh) + "}");
}

void firebasePatchConfig(const String &json) {
  gPendingConfigJson = json;
  gPendingConfig = true;
}

void flushFirebaseLive() {
  if((!gPendingController && !gPendingBms && !gPendingConfig && !gPendingSummary && !gPendingHistory && !gPendingLifetime) || WiFi.status()!=WL_CONNECTED || !validCloudUrl(getFirebaseDatabaseUrl()) || !firebaseAuthenticate())return;
  // One atomic multi-location PATCH avoids six blocking TLS requests per tick.
  JsonDocument patch;
  auto addLive=[&](const String &raw,bool pending){
    if(!pending)return;JsonDocument d;if(deserializeJson(d,raw))return;
    for(JsonPair field:d.as<JsonObject>())patch["live/"+String(field.key().c_str())].set(field.value());
  };
  auto addNode=[&](const char *path,const String &raw,bool pending){
    if(!pending)return;JsonDocument d;if(!deserializeJson(d,raw))patch[path].set(d);
  };
  addLive(gPendingControllerJson,gPendingController);addLive(gPendingBmsJson,gPendingBms);
  addNode("config",gPendingConfigJson,gPendingConfig);addNode("summary",gPendingSummaryJson,gPendingSummary);addNode("lifetime",gPendingLifetimeJson,gPendingLifetime);
  if(gPendingHistory){JsonDocument d;if(!deserializeJson(d,gPendingHistoryJson)){String day=d["day"] | "";if(day.length()==10)patch["history/"+day].set(d);}}
  String raw;serializeJson(patch,raw);
  int status=databaseRequest("PATCH",String(getFirebaseDatabaseUrl())+getDevicePath()+".json"+getFirebaseAuthParam(),raw);
  if(status==401)gFirebaseIdToken="";
  if(status>=200 && status<300){gPendingController=gPendingBms=gPendingConfig=gPendingSummary=gPendingHistory=gPendingLifetime=false;gFlushFailStreak=0;}
  else if(gFlushFailStreak<255)++gFlushFailStreak;
}

void publishDailySummary(bool pvEventChanged=false) {
  const uint32_t nowMs=millis();
  static uint32_t lastSummaryWrite = 0;
  if (pvEventChanged || nowMs - lastSummaryWrite >= 2000) {
    lastSummaryWrite = nowMs;
    const double loadFromBatteryWh = gLoadFromBatteryWh;
    const double loadFromPanelWh = gLoadFromPanelWh;
    String json = String("{\"day\":\"") + gSummaryDay + "\",\"panel_wh\":" + String(gPanelWh, 3) +
      ",\"battery_charge_wh\":" + (gBatteryCoverageSeconds>0 ? String(gBatteryChargeWh, 3) : String("null")) +
      ",\"battery_charge_ah\":" + (gBatteryCoverageSeconds>0 ? String(gBatteryChargeAh, 3) : String("null")) +
      ",\"battery_discharge_wh\":" + String(gBatteryDischargeWh, 3) +
      ",\"load_from_battery_bms_wh\":" + String(loadFromBatteryWh, 3) +
      ",\"load_from_panel_bms_wh\":" + String(loadFromPanelWh, 3) +
      ",\"energy_balance_wh\":" + String(gPanelWh + gBatteryDischargeWh - gBatteryChargeWh - gLoadWh, 3) +
      ",\"load_wh\":" + String(gLoadWh, 3) +
      ",\"load_from_panel_wh\":" + String(gLoadFromPanelWh, 3) +
      ",\"load_from_battery_wh\":" + String(gLoadFromBatteryWh, 3) +
      ",\"load_from_panel_ah\":" + String(gLoadFromPanelAh, 3) + ",\"load_from_battery_ah\":" + String(gLoadFromBatteryAh, 3) +
      ",\"load_panel_wh\":" + String(gLoadFromPanelWh, 3) +
      ",\"load_battery_wh\":" + String(gLoadFromBatteryWh, 3) +
      ",\"pv_on_time\":\"" + gPvOnTime + "\",\"pv_off_time\":\"" + gPvOffTime + "\"" +
      ",\"pv_on_battery_soc\":" + summaryMetric(gPvOnSoc) + ",\"pv_on_battery_remaining_ah\":" + summaryMetric(gPvOnAh) +
      ",\"pv_off_battery_soc\":" + summaryMetric(gPvOffSoc) + ",\"pv_off_battery_remaining_ah\":" + summaryMetric(gPvOffAh) +
      ",\"pv_w_max\":" + (gPvOnSamples ? String(gPvWMax, 2) : String("null")) + ",\"pv_w_min\":" + (gPvOnSamples ? String(gPvWMin, 2) : String("null")) + ",\"pv_w_avg\":" + (gPvOnSamples ? String(gPvWSum / max(1u, gAggregateSamples), 2) : String("null")) + ",\"pv_w_on_avg\":" + (gPvOnSamples ? String(gPvOnWSum / gPvOnSamples, 2) : String("null")) +
      ",\"pv_output_max_pct\":" + (gPvOnSamples ? panelOutputPct(gPvWMax) : String("null")) + ",\"pv_output_avg_pct\":" + (gPvOnSamples ? panelOutputPct(gPvOnWSum / gPvOnSamples) : String("null")) +
      ",\"pv_v_max\":" + (gPvOnSamples ? String(gPvVMax, 2) : String("null")) + ",\"pv_v_min\":" + (gPvOnSamples ? String(gPvVMin, 2) : String("null")) + ",\"pv_v_avg\":" + (gPvOnSamples ? String(gPvOnVSum / gPvOnSamples, 2) : String("null")) +
      ",\"pv_a_max\":" + (gPvOnSamples ? String(gPvAMax, 2) : String("null")) + ",\"pv_a_min\":" + (gPvOnSamples ? String(gPvAMin, 2) : String("null")) + ",\"pv_a_avg\":" + (gPvOnSamples ? String(gPvOnASum / gPvOnSamples, 2) : String("null")) +
      ",\"charge_a_max\":" + (gChargeSamples ? summaryMetric(gChargeAMax) : String("null")) + ",\"charge_a_min\":" + (gChargeSamples ? summaryMetric(gChargeAMin) : String("null")) + ",\"charge_a_avg\":" + (gChargeSamples ? String(gChargeASum / gChargeSamples, 2) : String("null")) +
      ",\"discharge_w_max\":" + summaryMetric(gDischargeWMax) + ",\"discharge_w_min\":" + summaryMetric(gDischargeWMin) + ",\"discharge_wh\":" + String(gLoadWh, 3) +
      ",\"discharge_a_max\":" + summaryMetric(gDischargeAMax) + ",\"discharge_a_min\":" + summaryMetric(gDischargeAMin) + ",\"discharge_a_avg\":" + (gDischargeASamples ? String(gDischargeASum / gDischargeASamples, 2) : String("null")) + "}";
    JsonDocument daily; deserializeJson(daily,json); gatewayInitializeSummary(daily); json="";serializeJson(daily,json);
    firebasePatchSummary(json);
    gatewayPersistHistory(json);
    static uint32_t lastCheckpoint=0; if(nowMs-lastCheckpoint>=60000){saveDailySummaryToFlash();lastCheckpoint=nowMs;}
  }
}

// Energy measured before NTP has set the clock (e.g. power returned while the
// Internet is down). It is merged only when the clock proves every sample
// belongs to the current reporting day; otherwise it is discarded, never guessed.
double gPreSyncPanelWh=0,gPreSyncPanelAh=0,gPreSyncLoadWh=0,gPreSyncLoadAh=0;
double gPreSyncChargeWh=0,gPreSyncChargeAh=0,gPreSyncDischargeWh=0,gPreSyncCoverage=0;
uint32_t gPreSyncLastSample=0,gPreSyncLastBms=0;
float gPreSyncPrevBmsPower=0,gPreSyncPrevBmsCurrent=0;

String summaryDayKey(time_t epoch) {
  struct tm local;localtime_r(&epoch,&local);
  if(local.tm_hour*60+local.tm_min<gResetHour*60+gResetMinute){time_t previous=mktime(&local)-86400;localtime_r(&previous,&local);}
  char key[16];snprintf(key,sizeof(key),"%04d-%02d-%02d",local.tm_year+1900,local.tm_mon+1,local.tm_mday);
  return String(key);
}

void mergePreSyncEnergy(time_t epochNow, const String &today) {
  if(!gPreSyncPanelWh && !gPreSyncLoadWh && !gPreSyncCoverage && !gPreSyncPanelAh && !gPreSyncLoadAh) return;
  const time_t bootEpoch=epochNow-static_cast<time_t>(millis()/1000);
  if(summaryDayKey(bootEpoch)==today) {
    gPanelWh+=gPreSyncPanelWh;gPanelAh+=gPreSyncPanelAh;gLoadWh+=gPreSyncLoadWh;gLoadAh+=gPreSyncLoadAh;
    gBatteryChargeWh+=gPreSyncChargeWh;gBatteryChargeAh+=gPreSyncChargeAh;gBatteryDischargeWh+=gPreSyncDischargeWh;gBatteryCoverageSeconds+=gPreSyncCoverage;
    Serial.printf("PRESYNC_ENERGY_MERGED panel_wh=%.3f load_wh=%.3f\n",gPreSyncPanelWh,gPreSyncLoadWh);
  } else {
    Serial.printf("PRESYNC_ENERGY_DISCARDED_DAY_UNKNOWN panel_wh=%.3f load_wh=%.3f\n",gPreSyncPanelWh,gPreSyncLoadWh);
  }
  gPreSyncPanelWh=gPreSyncPanelAh=gPreSyncLoadWh=gPreSyncLoadAh=gPreSyncChargeWh=gPreSyncChargeAh=gPreSyncDischargeWh=gPreSyncCoverage=0;
  gPreSyncLastSample=gPreSyncLastBms=0;
}

bool ensureSummaryDay() {
  const time_t epochNow=time(nullptr);if(epochNow<1700000000)return false;
  const String dayKey=summaryDayKey(epochNow);const char *key=dayKey.c_str();
  // The reporting day only moves forward. A later reset time (or a clock
  // set back) must never reopen an earlier, already archived day and
  // overwrite it; the new reset time then applies from the next day.
  if (gSummaryDay.isEmpty() || dayKey > gSummaryDay) { gatewayArchiveDay(gSummaryDay); const bool hadPreviousDay = gSummaryDay.length() > 0; gSummaryDay = key;gLastBmsEnergyAt=0;gLastEnergySample=0; if (hadPreviousDay && !gAllTimeHighEnabled) gAllTimeHighEnabled = true; gPanelAh=gLoadAh=gBatteryCoverageSeconds=0;gPanelWh = gBatteryChargeWh = gBatteryChargeAh = gBatteryDischargeWh = gLoadWh = gLoadFromPanelWh = gLoadFromBatteryWh = 0; gPvWMax=gPvWMin=gPvVMax=gPvVMin=gPvAMax=gPvAMin=gChargeAMax=gChargeAMin=gDischargeWMax=gDischargeWMin=gDischargeAMax=gDischargeAMin=-1; gPvWSum=gPvVSum=gPvASum=gChargeASum=gDischargeWSum=gDischargeASum=0; gPvOnWSum=gPvOnVSum=gPvOnASum=0; gLoadFromPanelAh=gLoadFromBatteryAh=0; gAggregateSamples=0; gChargeSamples=gDischargeWSamples=gDischargeASamples=gPvOnSamples=0; gPvOffTime=""; gPvOffSoc=gPvOffAh=-1; gDayFullChargeAt=0; gDayFullSoc=gDayFullAh=-1;
    // A sunrise before the reset time belongs to the new day: while the panel
    // is still on, keep its PV ON time, SOC and Ah instead of clearing them.
    if (gPvOutputState != 1) { gPvOnTime=""; gPvOnSoc=gPvOnAh=-1; } }
  mergePreSyncEnergy(epochNow,gSummaryDay);
  return true;
}
bool calculatedBatteryReady() {
  return gControllerOnlyMode && gBatteryType >= 1 && gBatteryType <= 4 && gBatteryCapacityAh > 0;
}
// Battery SOC/Ah at this moment: BMS in Controller + BMS Mode, the calculated
// value in Only Controller Mode. False (-1 values) when neither is available.
bool batterySnapshot(float &soc, float &ah) {
  if (gControllerOnlyMode) {
    const bool valid = gLatestSrneSampleAt && millis() - gLatestSrneSampleAt <= 10000;
    if (!valid) { soc = -1; ah = -1; return false; }
    // The gateway's own count where there is one: remaining Ah integrated from
    // the load terminal, the same figure the app shows beside the net current
    // it is integrated from. The controller's SOC register is a coarse,
    // voltage-led estimate that steps as soon as a load switches on.
    if (calculatedBatteryReady() && gCalcRemainingAh >= 0) {
      ah = float(gCalcRemainingAh);
      soc = float(gCalcRemainingAh / gBatteryCapacityAh * 100.0);
      return true;
    }
    // No battery type or capacity saved, so there is nothing to count against.
    // The controller's own SOC stands in rather than leaving the user with no
    // battery reading at all; the Ah stays unknown without a capacity.
    soc = gCtrlSoc;
    ah = gBatteryCapacityAh > 0 ? gBatteryCapacityAh * gCtrlSoc / 100.0f : -1;
    return true;
  }
  const bool bmsFresh = gLatestBmsSampleAt && millis() - gLatestBmsSampleAt <= 10000;
  soc = bmsFresh ? gLatestBmsSoc : -1; ah = bmsFresh ? gLatestBmsRemainingAh : -1;
  return bmsFresh;
}

// Longest gap between two samples that still counts as continuous data (energy
// integration, PV ON/OFF timers, BMS freshness). 5 s was shorter than the
// gateway's slowest cloud passes, so PV ON was delayed by hours and energy was
// dropped; a real outage (device or gateway off, restart) is far longer.
constexpr uint32_t kMaxSampleGapMs = 30000;
void updateDailySummary(float panelPower, float panelVoltage, float panelCurrent, float bmsPower, float bmsCurrent, bool bmsSampleFresh, float loadPower, float loadCurrent, float batteryCurrent) {
  if(!ensureSummaryDay()) {
    const uint32_t at=gDecodedReceivedAt;
    if(gPreSyncLastSample && at-gPreSyncLastSample<=kMaxSampleGapMs) {
      const double h=(at-gPreSyncLastSample)/3600000.0;
      gPreSyncPanelWh+=panelPower*h;gPreSyncPanelAh+=panelCurrent*h;gPreSyncLoadWh+=loadPower*h;gPreSyncLoadAh+=loadCurrent*h;
    }
    gPreSyncLastSample=at;return;
  }
  const uint32_t nowMs = gDecodedReceivedAt;
  // "Five continuous minutes" must be observed: after a reconnect, restart or
  // any gap longer than kMaxSampleGapMs the PV ON/OFF timers start again.
  if (gLastEnergySample == 0) { gLastEnergySample = nowMs; gPvZeroSince = 0; gPvRiseSince = 0; Serial.printf("SUMMARY_FIRST_SAMPLE ms=%u\n", static_cast<unsigned>(nowMs)); return; }
  const uint32_t intervalMs=nowMs-gLastEnergySample;
  if (intervalMs > kMaxSampleGapMs) { gPvZeroSince = 0; gPvRiseSince = 0; }
  const float hours = intervalMs<=kMaxSampleGapMs ? intervalMs/3600000.0f : 0.0f;
  gLastEnergySample = nowMs;
  struct tm localNow;
  char key[16];
  // Never invent a day before NTP has synchronized. Use the same epoch clock
  // as the live timestamp so energy accumulation is not blocked by a failed
  // getLocalTime() refresh.
  const time_t epochNow = time(nullptr);
  if (epochNow < 1700000000) { Serial.printf("SUMMARY_WAIT_NTP epoch=%ld\n", static_cast<long>(epochNow)); return; }
  localtime_r(&epochNow, &localNow);
  if (localNow.tm_hour * 60 + localNow.tm_min < gResetHour * 60 + gResetMinute) {
    time_t previous = mktime(&localNow) - 86400;
    localtime_r(&previous, &localNow);
  }
  int year = localNow.tm_year + 1900, month = localNow.tm_mon + 1, day = localNow.tm_mday;
  snprintf(key, sizeof(key), "%04d-%02d-%02d", year, month, day);
  const uint16_t localMinute = static_cast<uint16_t>(localNow.tm_hour * 60 + localNow.tm_min);
  const bool inPvAverageWindow = gPvAverageStartMinute <= gPvAverageEndMinute
    ? localMinute >= gPvAverageStartMinute && localMinute <= gPvAverageEndMinute
    : localMinute >= gPvAverageStartMinute || localMinute <= gPvAverageEndMinute;
  const int8_t pvOutputNow = panelPower >= 1.0f ? 1 : 0;
  bool pvEventChanged = false;
  if (gPvOutputState < 0) {
    gPvOutputState = pvOutputNow;
  }
  if (!pvOutputNow) {
    gPvRiseSince = 0;
    if (gPvZeroSince == 0) gPvZeroSince = epochNow;
    // OFF is valid only after five continuous minutes at 0W.
    if (epochNow - gPvZeroSince >= 300) {
      if (gPvOutputState != 0) {
        gPvOutputState = 0;
        gPvOffTime = localEventTime(gPvZeroSince);
        batterySnapshot(gPvOffSoc, gPvOffAh);
        pvEventChanged = true;
      }
      gPvNightQualified = true;
    }
  } else {
    gPvZeroSince = 0;
    // A morning ON requires both a verified 0W night and five continuous
    // minutes at 1W+. A brief dusk/noise value can never create an ON event.
    if (gPvOutputState == 0 && gPvNightQualified && gPvRiseSince == 0) {
      gPvRiseSince = epochNow;
    }
    if (gPvOutputState == 0 && gPvNightQualified && gPvRiseSince > 0 && epochNow - gPvRiseSince >= 300) {
      gPvOutputState = 1;
      gPvNightQualified = false;
      gPvOnTime = localEventTime(gPvRiseSince);
      batterySnapshot(gPvOnSoc, gPvOnAh);
      gPvRiseSince = 0;
      pvEventChanged = true;
    }
  }
  // What runs the load has to add up to the load. The panel covers as much
  // of it as its own output allows (nothing below 1 W) and the battery covers
  // the rest, both read from the controller in the same sample. Taking the
  // battery's share from the BMS instead made the two shares fall short of
  // the load whenever the meters disagreed -- which they do, by far more than
  // the few percent assumed here: the shortfall was clamped away without a
  // word, and the app showed a load larger than everything feeding it.
  const double loadNow = max(0.0, double(loadPower));
  const double panelAvailable = panelPower >= 1.0f ? double(panelPower) : 0.0;
  const double panelToLoad = min(panelAvailable, loadNow);
  const double batteryToLoad = loadNow - panelToLoad;
  // The same reading from the other meter, and only where there is one. The
  // controller cannot see anything wired straight to the pack, so a wide gap
  // against a real shunt is not noise: it is either such a load or a meter at
  // fault, and worth publishing rather than discarding. In Only Controller
  // Mode bmsPower is the controller's own net power, so comparing the two
  // would measure the controller against itself; the gap stays zero there.
  const bool shuntPresent = !gControllerOnlyMode && bmsSampleFresh;
  gBatteryMeterGapW = shuntPresent ? float(batteryToLoad - max(0.0, double(-bmsPower))) : 0.0f;
  gPanelWh += panelPower * hours;gPanelAh+=panelCurrent*hours;gLoadAh+=loadCurrent*hours;
  gLoadWh += loadPower * hours;
  gLoadFromPanelWh += panelToLoad * hours;
  gLoadFromBatteryWh += batteryToLoad * hours;
  // The load current split in the same proportion as its power.
  if (loadPower > 0.01f) { gLoadFromPanelAh += loadCurrent * (panelToLoad / loadPower) * hours; gLoadFromBatteryAh += loadCurrent * (batteryToLoad / loadPower) * hours; }
  // Discharge rows are controller load-output statistics. They include the
  // complete load regardless of whether the source is panel, battery, or both.
  const float dischargeW = max(0.0f, loadPower);
  const float dischargeA = max(0.0f, loadCurrent);
  gPvWMax = gPvWMax < 0 ? panelPower : max(gPvWMax, panelPower); gPvWMin = gPvWMin < 0 ? panelPower : min(gPvWMin, panelPower);
  gPvVMax = gPvVMax < 0 ? panelVoltage : max(gPvVMax, panelVoltage); gPvVMin = gPvVMin < 0 ? panelVoltage : min(gPvVMin, panelVoltage);
  gPvAMax = gPvAMax < 0 ? panelCurrent : max(gPvAMax, panelCurrent); gPvAMin = gPvAMin < 0 ? panelCurrent : min(gPvAMin, panelCurrent);
  if (dischargeW > 0.01f) { gDischargeWMax = gDischargeWMax < 0 ? dischargeW : max(gDischargeWMax, dischargeW); gDischargeWMin = gDischargeWMin < 0 ? dischargeW : min(gDischargeWMin, dischargeW); gDischargeWSum += dischargeW; ++gDischargeWSamples; }
  if (dischargeA > 0.01f) { gDischargeAMax = gDischargeAMax < 0 ? dischargeA : max(gDischargeAMax, dischargeA); gDischargeAMin = gDischargeAMin < 0 ? dischargeA : min(gDischargeAMin, dischargeA); gDischargeASum += dischargeA; ++gDischargeASamples; }
  gPvWSum += panelPower; gPvVSum += panelVoltage; gPvASum += panelCurrent; ++gAggregateSamples;
  if (inPvAverageWindow && panelPower >= 1.0f) { gPvOnWSum += panelPower; gPvOnVSum += panelVoltage; gPvOnASum += panelCurrent; ++gPvOnSamples; }
  static uint32_t lastSummaryDebug = 0;
  if (nowMs - lastSummaryDebug >= 2000) {
    lastSummaryDebug = nowMs;
    Serial.printf("SUMMARY_SAMPLE load=%.2f total=%.3f samples=%u day=%s\n", loadPower, gLoadWh, static_cast<unsigned>(gAggregateSamples), gSummaryDay.c_str());
  }
  publishDailySummary(pvEventChanged);
}

// Only Controller Mode: every load is on the controller's Load terminal, so
// net battery current = charge current (0x0102) - load current (0x0105).
// Remaining Ah is counted from it (charge at the chemistry's efficiency) and
// started from the controller's own SOC (0x0100). Values are published as
// calculated, never as BMS.
void updateCalculatedBattery(float batteryVoltage, float netCurrent, uint8_t controllerSoc) {
  gCalcCurrent = netCurrent;
  gCtrlSoc = controllerSoc > 100 ? 100 : controllerSoc;
  if (!calculatedBatteryReady()) { gCalcLastAt = 0; return; }
  const uint32_t at = gDecodedReceivedAt;
  const bool contiguous = gCalcLastAt && at - gCalcLastAt <= kMaxSampleGapMs;
  const double hours = contiguous ? (at - gCalcLastAt) / 3600000.0 : 0;
  gCalcLastAt = at;
  if (gCalcRemainingAh < 0) gCalcRemainingAh = gBatteryCapacityAh * (controllerSoc > 100 ? 100 : controllerSoc) / 100.0;
  else if (contiguous) gCalcRemainingAh += netCurrent * hours * (netCurrent > 0 ? (gBatteryType == 4 ? 0.99 : 0.85) : 1.0);
  gCalcRemainingAh = constrain(gCalcRemainingAh, 0.0, static_cast<double>(gBatteryCapacityAh));
  // A full charge is counted, never inferred. Holding Float used to be taken
  // as proof of a full battery: the charge was set straight to capacity, the
  // counter was shown the controller's own voltage-based SOC -- which a
  // flooded bank reads as 100% the moment it reaches float voltage, long
  // before it is full -- and the current was forced positive so the test could
  // not fail. On a real system that recorded a full charge at 07:32 on a day
  // whose panel had produced less energy in total than the jump it claimed,
  // and the Ah written down was simply the capacity, because the clamp had
  // just put it there. The counted charge is the only thing that knows.
  if (gControllerOnlyMode) {
    const double percent = gCalcRemainingAh / gBatteryCapacityAh * 100.0;
    updateLifetimeBatteryCounts(uint8_t(constrain(percent, 0.0, 100.0)), netCurrent);
  }
  if (contiguous && ensureSummaryDay()) {
    const float power = batteryVoltage * netCurrent;
    gBatteryChargeWh += max(0.0f, power) * hours; gBatteryChargeAh += max(0.0f, netCurrent) * hours;
    gBatteryDischargeWh += max(0.0f, -power) * hours; gBatteryCoverageSeconds += hours * 3600;
    if (netCurrent > 0) { gChargeAMax = gChargeAMax < 0 ? netCurrent : max(gChargeAMax, netCurrent); gChargeAMin = gChargeAMin < 0 ? netCurrent : min(gChargeAMin, netCurrent); gChargeASum += netCurrent; ++gChargeSamples; }
  }
  static uint32_t savedAt = 0;
  if (millis() - savedAt >= 60000) { savedAt = millis(); gDailyStore.putDouble("calc_ah", gCalcRemainingAh); }
}

// SRNE fault and warning bits (0x0121 high word = B16..B31, 0x0122 = B0..B15).
// Names follow the SRNE Modbus protocol; confirm on hardware.
String controllerFaultNames(uint32_t code) {
  static const char *const kNames[] = {
    "Battery over-discharge", "Battery over-voltage", "Battery under-voltage warning", "Load short circuit",
    "Load over-power or over-current", "Controller temperature too high", "Ambient temperature too high",
    "PV input over-power", "PV input short circuit", "PV input over-voltage", "PV counter-current",
    "PV working point over-voltage", "PV reversely connected", "Anti-reverse MOS short", "Charge MOS short circuit"};
  String list = "[";
  for (uint8_t bit = 16; bit <= 30; ++bit) {
    if (!(code & (1UL << bit))) continue;
    if (list.length() > 1) list += ',';
    list += String("\"") + kNames[bit - 16] + "\"";
  }
  return list + "]";
}

// Controller + BMS Mode: the controller's load sensor (0x0105/0x0106) reads a
// few percent away from the BMS shunt, so at night the load showed more than
// the battery gave it (35.6 W from a 34 W discharge). With no panel and no
// charge the whole load runs from the battery, and both meters see the same
// current: learn their ratio there, from steady paired samples only, and
// scale the controller's load by it. Until it is learned the raw load stands.
constexpr float kLoadCalMin = 0.85f, kLoadCalMax = 1.15f;
constexpr uint32_t kLoadCalPairMs = 3000;   // BMS sample this close to the controller's
constexpr uint16_t kLoadCalWindow = 60;     // steady samples per window
constexpr uint8_t kLoadCalWindowsToLearn = 3;
double gLoadCalSumBms = 0, gLoadCalSumLoad = 0, gLoadCalPendingSum = 0;
uint16_t gLoadCalCount = 0;
uint8_t gLoadCalPendingWindows = 0;
float gLoadCalPrevLoadA = -1, gLoadCalPrevBmsA = 0;
uint32_t gLoadCalLastAt = 0;

bool loadCalPaired() {
  return !gControllerOnlyMode && gLatestBmsSampleAt != 0 && gDecodedReceivedAt - gLatestBmsSampleAt <= kLoadCalPairMs;
}

void learnLoadCalibration(float panelPower, float panelCurrent, float chargeCurrent, float loadA) {
  const String id = getEffectiveControllerMac() + "|" + getEffectiveBmsMac();
  // Another controller or BMS: the saved ratio belongs to the old pair.
  if (gLoadCalId.length() && gLoadCalId != id) {
    diagLog("LOAD_CAL_FORGET pair_changed");
    gLoadCalId = ""; gLoadCalRatio = 1.0f; gLoadCalLearned = false; gLoadCalPendingWindows = 0; gLoadCalPendingSum = 0;
    gDailyStore.remove("lcal_id"); gDailyStore.remove("lcal_ratio");
  }
  const uint32_t at = gDecodedReceivedAt;
  const float bmsA = gLatestBmsCurrent;
  const bool night = panelPower < 1.0f && panelCurrent < 0.05f && chargeCurrent < 0.05f;
  const bool usable = !gControllerOnlyMode && id.length() >= 35 && night && loadA >= 0.5f && bmsA <= -0.3f;
  if (!usable || at - gLoadCalLastAt > kMaxSampleGapMs) { gLoadCalSumBms = gLoadCalSumLoad = 0; gLoadCalCount = 0; gLoadCalPrevLoadA = -1; }
  if (!usable || !loadCalPaired()) return;
  gLoadCalLastAt = at;
  // A load switching, a motor starting or one meter a sample behind the
  // other: skip it rather than average it in.
  const bool steady = gLoadCalPrevLoadA >= 0 &&
    fabsf(loadA - gLoadCalPrevLoadA) <= max(0.05f, 0.03f * loadA) &&
    fabsf(bmsA - gLoadCalPrevBmsA) <= max(0.05f, 0.03f * fabsf(bmsA));
  gLoadCalPrevLoadA = loadA; gLoadCalPrevBmsA = bmsA;
  const float sample = -bmsA / loadA;
  if (!steady || sample < 0.7f || sample > 1.3f) return;
  gLoadCalSumBms += -bmsA; gLoadCalSumLoad += loadA;
  if (++gLoadCalCount < kLoadCalWindow) return;
  const float window = float(gLoadCalSumBms / gLoadCalSumLoad);
  gLoadCalSumBms = gLoadCalSumLoad = 0; gLoadCalCount = 0;
  // Far outside a sensor tolerance is not a calibration: a load wired straight
  // to the pack, or a meter at fault. Leave the load as it is.
  if (window < kLoadCalMin || window > kLoadCalMax) { diagLog("LOAD_CAL_REJECT window=%.3f", window); return; }
  float next;
  if (!gLoadCalLearned) {
    gLoadCalPendingSum += window;
    if (++gLoadCalPendingWindows < kLoadCalWindowsToLearn) return;
    next = float(gLoadCalPendingSum / gLoadCalPendingWindows);
    gLoadCalPendingSum = 0; gLoadCalPendingWindows = 0;
  } else {
    next = 0.9f * gLoadCalRatio + 0.1f * window;
  }
  const bool save = !gLoadCalLearned || fabsf(next - gDailyStore.getFloat("lcal_ratio", 0)) > 0.003f;
  gLoadCalRatio = next; gLoadCalLearned = true; gLoadCalId = id;
  if (save) { gDailyStore.putFloat("lcal_ratio", gLoadCalRatio); gDailyStore.putString("lcal_id", gLoadCalId); diagLog("LOAD_CAL_SAVED ratio=%.4f", gLoadCalRatio); }
}

void publishSrneLive(const uint8_t *data, size_t length) {
  if (length < 23 || data[0] != 0xff || data[1] != 0x03) return;
  const uint8_t byteCount = data[2];
  // Live telemetry is the 0x0100..0x0122 response (70 bytes; 68 from older
  // reads without 0x0122). Shorter SRNE responses are settings/register
  // replies and must not be decoded as live panel or load measurements.
  if (byteCount < 68 || length < static_cast<size_t>(3 + byteCount)) {
    if (!gSrneLiveRejectLogged) { gSrneLiveRejectLogged = true; diagLog("CTRL_LIVE_SHORT bytes=%u frame=%u", unsigned(byteCount), unsigned(length)); }
    return;
  }
  auto reg = [&](size_t index) -> uint16_t { return (static_cast<uint16_t>(data[3 + index * 2]) << 8) | data[4 + index * 2]; };
  const float batteryVoltage = reg(1) * 0.1f;
  // A block of believable length but unbelievable values is not this
  // firmware's live block: the module is answering, in a dialect it does not
  // read. Name the values once per link and say so in the link error, or the
  // only report left is the generic "the device never answered".
  if((reg(0)&0xff)>100 || batteryVoltage<5 || batteryVoltage>120 || reg(7)*0.1f>600) {
    if (!gSrneLiveRejectLogged) {
      gSrneLiveRejectLogged = true;
      diagLog("CTRL_LIVE_REJECT soc=%u bat=%.1f pv=%.1f bytes=%u", unsigned(reg(0)&0xff), batteryVoltage, reg(7)*0.1f, unsigned(byteCount));
      gLinkError = "The controller answers on Bluetooth, but its live block holds values this firmware cannot read (battery " +
        String(batteryVoltage, 1) + " V, panel " + String(reg(7)*0.1f, 1) + " V, SOC " + String(reg(0)&0xff) +
        "). Its register map or scaling is not the one this firmware reads.";
      gCtrlVerdict = gLinkError;
    }
    return;
  }
  const float chargeCurrent = reg(2) * 0.01f;
  const float rawLoadCurrent = reg(5) * 0.01f;
  const float rawLoadPower = reg(6);
  const float panelPower = reg(9);
  const float panelCurrent = reg(8) * 0.01f;
  // Controller + BMS Mode: the load scaled by the learned meter ratio, and
  // never more than what the panel and the battery give it: panel + battery
  // discharge, or panel - battery charge when the panel has a surplus (a load
  // cannot take more than its sources; less is losses). Only Controller Mode keeps
  // the controller's own reading: there the battery is derived from it.
  learnLoadCalibration(panelPower, panelCurrent, chargeCurrent, rawLoadCurrent);
  float loadFactor = !gControllerOnlyMode && gLoadCalLearned ? gLoadCalRatio : 1.0f;
  bool loadCapped = false;
  if (loadCalPaired() && rawLoadPower > 0.5f) {
    const float supply = max(0.0f, (panelPower >= 1.0f ? panelPower : 0.0f) - gLatestBmsVoltage * gLatestBmsCurrent);
    if (rawLoadPower * loadFactor > supply) { loadFactor = supply / rawLoadPower; loadCapped = true; }
  }
  const float loadCurrent = rawLoadCurrent * loadFactor;
  const float loadPower = rawLoadPower * loadFactor;
  const bool newAllTimeHigh = (panelPower > gAllTimePvPowerMax || panelCurrent > gAllTimePvCurrentMax);
  if (panelPower > gAllTimePvPowerMax) gAllTimePvPowerMax = panelPower;
  if (panelCurrent > gAllTimePvCurrentMax) gAllTimePvCurrentMax = panelCurrent;
  if (newAllTimeHigh) { publishLifetimeState(); saveDailySummaryToFlash(); }
  gLatestSrnePanelPower = panelPower;
  gLatestSrneLoadPower = loadPower;
  if (!gLatestSrneSampleAt) diagLog("CTRL_FIRST_SAMPLE battery=%.1fV", batteryVoltage);
  gLatestSrneSampleAt = gDecodedReceivedAt;
  gCtrlVerdict = "";
  const float batteryCurrent = chargeCurrent; // Controller charge output only; never fabricate net discharge.
  const float batteryPower = batteryVoltage * batteryCurrent;
  const uint16_t status = byteCount >= 66 ? reg(32) : 0;
  const String chargingMode = chargingModeName(status & 0xff);
  const float netCurrent = chargeCurrent - reg(5) * 0.01f;
  updateCalculatedBattery(batteryVoltage, netCurrent, reg(0) & 0xff);
  const bool calcValid = calculatedBatteryReady() && gCalcRemainingAh >= 0;
  // Load source split: BMS net power in Controller + BMS Mode, calculated net
  // power in Only Controller Mode.
  const bool bmsSampleFresh = gControllerOnlyMode ? calcValid : gLatestBmsSampleAt != 0 && millis() - gLatestBmsSampleAt <= kMaxSampleGapMs;
  const float bmsPower = !bmsSampleFresh ? 0 : gControllerOnlyMode ? batteryVoltage * netCurrent : gLatestBmsVoltage * gLatestBmsCurrent;
  const float bmsCurrent = !bmsSampleFresh ? 0 : gControllerOnlyMode ? netCurrent : gLatestBmsCurrent;
  updateDailySummary(panelPower, reg(7) * 0.1f, panelCurrent, bmsPower, bmsCurrent, bmsSampleFresh, loadPower, loadCurrent, batteryCurrent);
  const String sampleTimestamp = currentTimestampMillis(gDecodedReceivedAt);
  String json = String("{\"controller_connected\":true,\"timestamp\":") + sampleTimestamp +
    ",\"controller_updated_at\":" + sampleTimestamp +
    ",\"soc\":" + String(reg(0) & 0xff) +
    ",\"battery_voltage\":" + String(batteryVoltage, 3) +
    ",\"battery_current\":" + String(batteryCurrent, 3) +
    ",\"battery_power\":" + String(batteryPower, 2) +
    ",\"battery_charge_current\":" + String(chargeCurrent, 3) +
    ",\"load_voltage\":" + String(reg(4) * 0.1f, 2) +
    ",\"load_current\":" + String(loadCurrent, 3) +
    ",\"load_power\":" + String(loadPower, 2) +
    ",\"panel_voltage\":" + String(reg(7) * 0.1f, 2) +
    ",\"panel_current\":" + String(panelCurrent, 3) +
    ",\"panel_power\":" + String(panelPower, 2) +
    ",\"load_switch\":" + String((status & 0x8000)?"true":"false") + ",\"controller_temperature\":" + String((reg(3)&0x8000)?-int((reg(3)>>8)&0x7f):int((reg(3)>>8)&0x7f)) + ",\"battery_temperature\":" + String((reg(3)&0x80)?-int(reg(3)&0x7f):int(reg(3)&0x7f)) + ",\"charging_mode_code\":" + String(status & 0xff) +
    ",\"charging_mode\":\"" + chargingMode + "\"" +
    ",\"panel_output_pct\":" + panelOutputPct(panelPower) +
    // How far the BMS shunt disagrees with the share the controller implies.
    ",\"battery_meter_gap_w\":" + String(gBatteryMeterGapW, 2) +
    ",\"battery_mode\":\"" + (gControllerOnlyMode ? "controller" : "controller_bms") + "\"";
  if (!gControllerOnlyMode) {
    // The controller's own reading and how it was corrected, for diagnostics.
    json += ",\"load_current_raw\":" + String(rawLoadCurrent, 3) +
      ",\"load_power_raw\":" + String(rawLoadPower, 2) +
      ",\"load_cal_ratio\":" + String(gLoadCalLearned ? gLoadCalRatio : 1.0f, 4) +
      ",\"load_cal_learned\":" + String(gLoadCalLearned ? "true" : "false") +
      ",\"load_capped\":" + String(loadCapped ? "true" : "false");
  }
  if (gControllerOnlyMode) {
    json += ",\"battery_calc_current\":" + String(netCurrent, 3) +
      ",\"battery_calc_power\":" + String(batteryVoltage * netCurrent, 2) +
      ",\"battery_calc_valid\":" + String(calcValid ? "true" : "false");
    if (calcValid) {
      json += ",\"battery_calc_soc\":" + String(gCalcRemainingAh / gBatteryCapacityAh * 100.0, 1) +
        ",\"battery_calc_remaining_ah\":" + String(gCalcRemainingAh, 2) +
        ",\"battery_calc_capacity_ah\":" + String(gBatteryCapacityAh, 1);
    } else {
      // Cleared, not left behind. These three used to be omitted while the
      // calculation was invalid, so Firebase kept whatever was last written and
      // the app went on showing it as current: a gateway whose battery type and
      // capacity had been cleared still displayed "SOC 77% - Calculated - 100
      // Ah", from a reading hours old, right next to battery_calc_valid false.
      // Sending null deletes them, the same way the daily summary already
      // clears the figures it cannot stand behind.
      json += ",\"battery_calc_soc\":null,\"battery_calc_remaining_ah\":null,\"battery_calc_capacity_ah\":null";
    }
  }
  if (byteCount >= 70) {
    const uint32_t faults = (static_cast<uint32_t>(reg(33)) << 16) | reg(34);
    json += ",\"controller_fault_code\":" + String(faults) + ",\"controller_faults\":" + controllerFaultNames(faults);
  }
  const bool flowPairFresh = gLatestBmsSampleAt != 0 && millis() - gLatestBmsSampleAt <= 1000;
  if (flowPairFresh) {
    json += ",\"flow_panel_power\":" + String(panelPower, 2) +
      ",\"flow_load_power\":" + String(loadPower, 2) +
      ",\"flow_battery_power\":" + String(gLatestBmsVoltage * gLatestBmsCurrent, 2) +
      ",\"flow_updated_at\":" + sampleTimestamp;
  }
  json += ",\"controller_mac\":\"" + getEffectiveControllerMac() + "\"}";
  gatewayOnLive(data,length);
  firebasePatchLive(json, true);
}

void publishSrneSettings(const uint8_t *data, size_t length) {
  if (length < 3 || data[0] != 0xff || data[1] != 0x03 || (data[2] != 32 && data[2] != 34) || length < static_cast<size_t>(3 + data[2])) return;
  // The register cache composes the full controller_settings object.
  gatewayOnSettings(data,length);
  gatewayPublishControllerSettings();
}

void updateLifetimeBatteryCounts(uint8_t soc, float batteryCurrent) {
  bool changed = false;
  const bool fullCandidate = soc >= 100 && batteryCurrent > 0.05f;
  const bool emptyCandidate = soc == 0 && batteryCurrent < -0.05f;
  if (gSocMilestoneState < 0) {
    // First observation establishes the starting position; it is not a cycle.
    gSocMilestoneState = fullCandidate ? 2 : emptyCandidate ? 0 : 1;
  } else if (gSocMilestoneState == 2) {
    // After a full event the next one counts once SOC has dropped to 90%
    // (a normal daily cycle), not only after a deep discharge.
    if (soc <= 90) { gSocMilestoneState = 1; gFullChargeStreak = 0; }
  } else if (gSocMilestoneState == 0) {
    if (soc >= 10) { gSocMilestoneState = 1; gFullDischargeStreak = 0; }
  } else {
    gFullChargeStreak = fullCandidate ? (gFullChargeStreak < 3 ? gFullChargeStreak + 1 : 3) : 0;
    gFullDischargeStreak = emptyCandidate ? (gFullDischargeStreak < 3 ? gFullDischargeStreak + 1 : 3) : 0;
    if (gFullChargeStreak >= 3) {
      ++gFullChargeCount;
      if (time(nullptr) >= 1700000000) gLastFullChargeAt = static_cast<uint64_t>(time(nullptr)) * 1000ULL;
      // Remaining Ah from the BMS, or capacity x the controller's SOC in Only
      // Controller Mode (unknown without a saved capacity).
      gLastFullSoc = soc;
      gLastFullAh = gControllerOnlyMode ? (gBatteryCapacityAh > 0 ? gBatteryCapacityAh * soc / 100.0f : -1) : gLatestBmsRemainingAh;
      // Only the first full charge of the reporting day is the day's. A
      // battery that reaches 100%, falls and climbs back has not earned a
      // second "Full Charge At" to show; the lifetime count below still rises.
      // Cleared by the daily reset, whose conditions are unchanged.
      if (!gDayFullChargeAt) { gDayFullChargeAt = gLastFullChargeAt; gDayFullSoc = gLastFullSoc; gDayFullAh = gLastFullAh; }
      gSocMilestoneState = 2;
      gFullChargeStreak = 0;
      changed = true;
    } else if (gFullDischargeStreak >= 3) {
      ++gFullDischargeCount;
      gSocMilestoneState = 0;
      gFullDischargeStreak = 0;
      changed = true;
    }
  }
  if (!gLifetimePublished || changed) {
    gLifetimePublished = true;
    publishLifetimeState();
    saveDailySummaryToFlash();
  }
}

// One BMS reading (JK or JBD). The vendor decoders fill it; the shared part
// below validates it, updates the energy totals and publishes the live keys.
struct BmsSample {
  float voltage=0, current=0, remainingAh=0, nominalAh=0, cellSum=0, cellDifference=0;
  uint8_t soc=0;
  uint32_t cycles=0;
  String cells;           // JSON array of cell voltages
  const char *source="";  // bms_cell_difference_source
  String extra;           // vendor-specific JSON members, each starting with ','
};

bool publishBmsSample(const BmsSample &s) {
  const float bmsVoltage = s.voltage;
  const float bmsCurrent = s.current;
  const float nominalCapacity = s.nominalAh;
  // Reject malformed/stale reconnect frames before they can affect live data,
  // energy totals, or lifetime counters.
  if (!isfinite(bmsVoltage) || !isfinite(bmsCurrent) || bmsVoltage < 5.0f || bmsVoltage > 120.0f ||
      bmsCurrent < -1000.0f || bmsCurrent > 1000.0f || s.soc > 100 ||
      !isfinite(nominalCapacity) || nominalCapacity <= 0.0f || nominalCapacity > 10000.0f) {
    gLatestBmsSampleAt = 0;
    Serial.printf("BMS_SAMPLE_REJECTED voltage=%.3f current=%.3f soc=%u capacity=%.3f\n",
                  bmsVoltage, bmsCurrent, s.soc, nominalCapacity);
#ifdef NOXBRAIN_BENCH
    BENCH_PORT.printf("BENCH_JK reject %s: voltage=%.3f current=%.3f soc=%u capacity=%.3f\n",
                  gJkProfile.c_str(), bmsVoltage, bmsCurrent, s.soc, nominalCapacity);
#endif
    return false;
  }
  if (fabsf(s.cellSum-bmsVoltage)>max(1.0f,bmsVoltage*0.05f)) {
#ifdef NOXBRAIN_BENCH
    BENCH_PORT.printf("BENCH_JK reject %s: cell sum %.3f vs pack %.3f\n",gJkProfile.c_str(),s.cellSum,bmsVoltage);
#endif
    return false;
  }
  if(ensureSummaryDay()) {
  if (bmsCurrent > 0) { gChargeAMax = gChargeAMax < 0 ? bmsCurrent : max(gChargeAMax, bmsCurrent); gChargeAMin = gChargeAMin < 0 ? bmsCurrent : min(gChargeAMin, bmsCurrent); gChargeASum += bmsCurrent; ++gChargeSamples; }
    const uint32_t nowMs=gDecodedReceivedAt;
    if(gLastBmsEnergyAt && nowMs-gLastBmsEnergyAt<=kMaxSampleGapMs) {
      const double hours=(nowMs-gLastBmsEnergyAt)/3600000.0;
      const float power=bmsVoltage*bmsCurrent;
      gBatteryChargeWh+=(max(0.0f,gPreviousBmsPower)+max(0.0f,power))*0.5*hours;
      gBatteryChargeAh+=(max(0.0f,gPreviousBmsCurrent)+max(0.0f,bmsCurrent))*0.5*hours;
      gBatteryDischargeWh+=(max(0.0f,-gPreviousBmsPower)+max(0.0f,-power))*0.5*hours;
      gBatteryCoverageSeconds+=hours*3600;
    }
    gLastBmsEnergyAt=nowMs;gPreviousBmsPower=bmsVoltage*bmsCurrent;gPreviousBmsCurrent=bmsCurrent;
    publishDailySummary();
  } else {
    const uint32_t at=gDecodedReceivedAt;const float power=bmsVoltage*bmsCurrent;
    if(gPreSyncLastBms && at-gPreSyncLastBms<=kMaxSampleGapMs) {
      const double h=(at-gPreSyncLastBms)/3600000.0;
      gPreSyncChargeWh+=(max(0.0f,gPreSyncPrevBmsPower)+max(0.0f,power))*0.5*h;
      gPreSyncChargeAh+=(max(0.0f,gPreSyncPrevBmsCurrent)+max(0.0f,bmsCurrent))*0.5*h;
      gPreSyncDischargeWh+=(max(0.0f,-gPreSyncPrevBmsPower)+max(0.0f,-power))*0.5*h;
      gPreSyncCoverage+=h*3600;
    }
    gPreSyncLastBms=at;gPreSyncPrevBmsPower=power;gPreSyncPrevBmsCurrent=bmsCurrent;
  }
  gLatestBmsVoltage = bmsVoltage;
  gLatestBmsCurrent = bmsCurrent;
  gLatestBmsSoc = s.soc;
  gLatestBmsRemainingAh = s.remainingAh;
  if (!gLatestBmsSampleAt) diagLog("BMS_FIRST_SAMPLE soc=%u", static_cast<unsigned>(gLatestBmsSoc));
  gLatestBmsSampleAt = gDecodedReceivedAt;
  updateLifetimeBatteryCounts(s.soc, bmsCurrent);
  const String sampleTimestamp = currentTimestampMillis(gDecodedReceivedAt);
  String json = String("{\"bms_cell_difference_v\":") + String(s.cellDifference,3) + ",\"bms_cell_difference_source\":\"" + s.source + "\",\"bms_profile\":\"" + gJkProfile + "\",\"bms_connected\":true,\"timestamp\":" + sampleTimestamp +
    ",\"bms_updated_at\":" + sampleTimestamp +
    ",\"bms_battery_voltage\":" + String(bmsVoltage, 3) +
    ",\"bms_battery_current\":" + String(bmsCurrent, 3) +
    ",\"bms_battery_power\":" + String(bmsVoltage * bmsCurrent, 2) +
    ",\"bms_soc\":" + String(s.soc) +
    ",\"bms_remaining_capacity_ah\":" + String(s.remainingAh, 3) +
    ",\"bms_nominal_capacity_ah\":" + String(nominalCapacity, 3) +
    ",\"bms_cycle_count\":" + String(s.cycles) + s.extra +
    ",\"bms_cell_voltages\":" + s.cells +
    ",\"bms_mac\":\"" + getEffectiveBmsMac() + "\"}";
  firebasePatchLive(json, false);
  return true;
  // Controller and BMS polling are independent.
}

bool publishJkLive(const uint8_t *data, size_t length) {
  if ((length != 300 && length != 320) || data[0] != 0x55 || data[1] != 0xaa || data[2] != 0xeb || data[3] != 0x90 || data[4] != 0x02) return false;
  uint8_t checksum=0; for(size_t i=0;i<length-1;++i) checksum+=data[i]; if(checksum!=data[length-1]) return false;
  const bool jk32=gJkProfile=="jk02_32";
  const size_t fields=jk32?32:0;
  const size_t delta=jk32?76:60;
  auto u16 = [&](size_t p) -> uint16_t { return static_cast<uint16_t>(data[p]) | (static_cast<uint16_t>(data[p + 1]) << 8); };
  auto u32 = [&](size_t p) -> uint32_t { return static_cast<uint32_t>(u16(p)) | (static_cast<uint32_t>(u16(p + 2)) << 16); };
  auto s32 = [&](size_t p) -> int32_t { return static_cast<int32_t>(u32(p)); };
  String cells = "[";
  uint8_t activeCells=0; float cellSum=0;
  for (uint8_t i=0;i<(jk32?32:24);++i) {
    float cell=u16(6+i*2)*0.001f; if(cell==0) continue;
    if(cell<0.5f || cell>5.0f) {
#ifdef NOXBRAIN_BENCH
      BENCH_PORT.printf("BENCH_JK reject %s: cell %u = %.3f V\n",gJkProfile.c_str(),i,cell);
#endif
      return false;}
    if(activeCells++) cells+=','; cells+=String(cell,3); cellSum+=cell;
  }
  if(activeCells<2) {
#ifdef NOXBRAIN_BENCH
    BENCH_PORT.printf("BENCH_JK reject %s: only %u cells\n",gJkProfile.c_str(),activeCells);
#endif
    return false;}
  cells += ']';
  String balancingStatus = data[140+fields] == 1 ? "charging" : data[140+fields] == 2 ? "discharging" : "off";
  BmsSample s;
  s.voltage = u32(118+fields) * 0.001f;
  s.current = s32(126+fields) * 0.001f;
  s.nominalAh = u32(146+fields) * 0.001f;
  s.remainingAh = u32(142+fields) * 0.001f;
  s.soc = data[141+fields];
  s.cycles = u32(150+fields);
  s.cells = cells;
  s.cellSum = cellSum;
  s.cellDifference = u16(delta)*0.001f;
  s.source = "jk";
  s.extra = String(",\"bms_uptime_seconds\":") + String(u32(162+fields)) + ",\"bms_sensor2_temperature\":" + String(static_cast<int16_t>(u16(132+fields))*0.1f,1) + ",\"bms_mos_temperature\":" + String(static_cast<int16_t>(u16(jk32?144:134))*0.1f,1) +
    ",\"bms_temperature\":" + String(static_cast<int16_t>(u16(130+fields)) * 0.1f, 1) +
    ",\"bms_sensor1_temperature\":" + String(static_cast<int16_t>(u16(130+fields)) * 0.1f, 1) +
    ",\"bms_balancing_current\":" + String(static_cast<int16_t>(u16(138+fields)) * 0.001f, 3) +
    ",\"bms_balancing_status\":\"" + balancingStatus + "\"";
  return publishBmsSample(s);
}

// JBD / Xiaoxiang reply "DD <cmd> <status> <len> <data...> <sum hi> <sum lo> 77"
// (framing and checksum checked by the caller). 0x04 = cell voltages (mV,
// big-endian), kept until the next 0x03 = pack state, which publishes one
// sample with those cells.
bool publishJbdFrame(const uint8_t *frame, size_t size) {
  const uint8_t command=frame[1], length=frame[3];
  if(size!=size_t(length)+7) return false;
  const uint8_t *d=frame+4;
  auto u16 = [&](size_t p) -> uint16_t { return (uint16_t(d[p]) << 8) | d[p + 1]; };
  if(command==0x04) {
    const uint8_t count=length/2;
    if(count<2 || count>32) return false;
    for(uint8_t i=0;i<count;++i) {
      const uint16_t mv=u16(i*2);
      if(mv<500 || mv>5000) return false;
      gJbdCells[i]=mv;
    }
    gJbdCellCount=count;gJbdCellsAt=gDecodedReceivedAt;
    return true;
  }
  if(command!=0x03 || length<23) return false;
  const uint8_t cellCount=d[21], ntcCount=d[22];
  if(23+size_t(ntcCount)*2>length) return false;
  // Cells must be fresh and match the pack's own cell count.
  if(!gJbdCellsAt || gDecodedReceivedAt-gJbdCellsAt>5000 || gJbdCellCount!=cellCount) return false;
  BmsSample s;
  s.voltage = u16(0) * 0.01f;
  s.current = int16_t(u16(2)) * 0.01f;
  s.remainingAh = u16(4) * 0.01f;
  s.nominalAh = u16(6) * 0.01f;
  s.cycles = u16(8);
  s.soc = d[19];
  String cells="[";uint16_t low=0xffff,high=0;
  for(uint8_t i=0;i<cellCount;++i) {
    if(i)cells+=',';cells+=String(gJbdCells[i]*0.001f,3);s.cellSum+=gJbdCells[i]*0.001f;
    low=min(low,gJbdCells[i]);high=max(high,gJbdCells[i]);
  }
  cells+=']';
  s.cells=cells;s.cellDifference=(high-low)*0.001f;s.source="jbd";
  // Temperatures come in 0.1 K. Balancing bits set: shown like JK's charge or
  // discharge balancing, by the current direction.
  const uint32_t balance=uint32_t(u16(12))|(uint32_t(u16(14))<<16);
  String extra=String(",\"bms_charge_mos\":")+((d[20]&1)?"true":"false")+",\"bms_discharge_mos\":"+((d[20]&2)?"true":"false")+
    ",\"bms_protection_code\":"+String(u16(16))+
    ",\"bms_balancing_status\":\""+(balance?(s.current>=0?"charging":"discharging"):"off")+"\"";
  if(ntcCount>=1) {const float t=(int32_t(u16(23))-2731)*0.1f;extra+=",\"bms_temperature\":"+String(t,1)+",\"bms_sensor1_temperature\":"+String(t,1);}
  if(ntcCount>=2) {const float t=(int32_t(u16(25))-2731)*0.1f;extra+=",\"bms_sensor2_temperature\":"+String(t,1);}
  s.extra=extra;
  return publishBmsSample(s);
}

void setStatusLed(uint8_t red, uint8_t green, uint8_t blue) {
#if CONFIG_IDF_TARGET_ESP32S3
  gStatusLed.setPixelColor(0, gStatusLed.Color(red, green, blue));
  gStatusLed.show();
#endif
}

void onNotify(NimBLERemoteCharacteristic *c, uint8_t *data, size_t length, bool notify) { gatewayNotify(c,data,length,notify); }

uint16_t modbusCrc(const uint8_t *data, size_t length) {
  uint16_t crc = 0xffff;
  for (size_t index = 0; index < length; ++index) {
    crc ^= data[index];
    for (uint8_t bit = 0; bit < 8; ++bit) {
      crc = (crc & 1) ? ((crc >> 1) ^ 0xa001) : (crc >> 1);
    }
  }
  return crc;
}

// Controller transport. Bluetooth keeps its original checks unchanged; RS485
// counts as up while its port is open (no link layer exists on the bus).
bool srneRs485() { return gCtrlLink == 1; }
bool srneLinkUp() { return srneRs485() ? gRs485Open : (gSrneClient && gSrneClient->isConnected()); }
bool srneWriterReady() { return srneRs485() ? gRs485Open : gSrneWriter != nullptr; }
// RS485 controller is "connected" only while it answers (valid reply < 10 s).
bool srneRs485Alive() { return srneRs485() && gRs485Open && gLatestSrneSampleAt && millis() - gLatestSrneSampleAt < 10000; }

void srneSend(const uint8_t *frame, size_t length) {
  // Frames are built with address 0xFF. Whenever the link needs a different
  // one -- the controller's own address on RS485, or a candidate while
  // Bluetooth is still being probed -- the byte and the CRC are rewritten.
  if (length < 4 || length > 64) return;
  // Only sendSrneLiveRead sets this again, straight after its own call.
  gSrneLastTxLive = false;
  const uint8_t addr = srneRs485() ? gRs485Addr : gSrneBleAddr;
  uint8_t wire[64];
  memcpy(wire, frame, length);
  if (addr != 0xff) {
    wire[0] = addr;
    const uint16_t crc = modbusCrc(wire, length - 2);
    wire[length - 2] = crc & 0xff;
    wire[length - 1] = crc >> 8;
  }
  // Callers check srneWriterReady(), but a dropped link clears the writer
  // from the same loop that sends, and one unguarded caller would reboot the
  // gateway rather than miss a frame.
  if (!srneRs485()) {
    if (gSrneWriter && !gSrneWriter->writeValue(wire, length, gSrneRespMode == 1) && !gSrneWriteFailLogged) {
      gSrneWriteFailLogged = true;
      diagLog("CTRL_WRITE_FAIL mode=%u len=%u addr=0x%02x", unsigned(gSrneRespMode), unsigned(length), unsigned(wire[0]));
    }
    return;
  }
  if (!gRs485Open) return;
  Serial1.write(wire, length);
  Serial1.flush();
}

// Steps through the candidate addresses while a Bluetooth link is up but
// silent, and remembers the one that answers. Returns false once every
// candidate has been tried without a reply.
bool srneAddressProbeTick() {
  if (srneRs485() || !srneLinkUp() || !srneWriterReady()) return true;
  // A locked module answers nothing at any address: walking the ladder (and
  // reconnecting for it) cannot help until it is paired with its PIN.
  if (gSrneLocked) return true;
  if (gSrneAnsweredAt) {  // this address works: any valid reply proves it
    if (!gSrneAddrSettled) {
      gSrneAddrSettled = true;
      gLinkError = "";
      if (gDailyStore.getUChar("srne_ble_addr", 0xff) != gSrneBleAddr)
        gDailyStore.putUChar("srne_ble_addr", gSrneBleAddr);
      if (gDailyStore.getUChar("srne_ble_mode", 0) != gSrneRespMode)
        gDailyStore.putUChar("srne_ble_mode", gSrneRespMode);
      diagLog("SRNE_BLE_ADDR answered=0x%02x mode=%u", unsigned(gSrneBleAddr), unsigned(gSrneRespMode));
    }
    return true;
  }
  // Five seconds is four or five live reads at the one-second poll: enough to
  // tell silence from a single dropped frame.
  if (millis() - gSrneAddrTriedAt < 5000) return true;
  // Wrap around rather than walking off the end: when the remembered
  // address belongs to a controller that has since been swapped for
  // another model, the candidates before it must still be reachable.
  if (++gSrneAddrTries >= sizeof(kSrneBleAddresses)) {
    if (gSrneRespMode == 0) { gSrneRespMode = 1; diagLog("SRNE_BLE_MODE with_response"); return false; }
    gSrneLadderDone = true;
    return false;
  }
  gSrneAddrIndex = uint8_t((gSrneAddrIndex + 1) % sizeof(kSrneBleAddresses));
  gSrneBleAddr = kSrneBleAddresses[gSrneAddrIndex];
  gSrneAddrTriedAt = millis();
  diagLog("SRNE_BLE_ADDR trying=0x%02x", unsigned(gSrneBleAddr));
  return true;
}

// A fresh link starts from the address that answered last time.
void srneAddressProbeReset() {
  gSrneBleAddr = gDailyStore.getUChar("srne_ble_addr", 0xff);
  // Mid-ladder the response mode must survive the reconnect it asked for, but
  // once a whole ladder is spent the next one starts from the remembered mode
  // again -- otherwise a module needing writes without a reply got a single
  // chance per boot, because nothing ever set the mode back to 0.
  if (gSrneLadderDone) gSrneRespMode = gDailyStore.getUChar("srne_ble_mode", 0);
  gSrneLadderDone = false;
  gSrneAddrIndex = 0;
  for (uint8_t i = 0; i < sizeof(kSrneBleAddresses); ++i)
    if (kSrneBleAddresses[i] == gSrneBleAddr) gSrneAddrIndex = i;
  gSrneAddrTries = 0;
  gSrneAddrTriedAt = millis();
  gSrneAddrSettled = false;
}

void sendSrneLiveRead() {
  // 0x0100 upwards: live values, load/charging state and, at the full 0x23,
  // both fault words. gSrneLiveCount shortens the block for a controller that
  // refuses to read past the end of its own register map.
  uint8_t request[] = {0xff, 0x03, 0x01, 0x00, static_cast<uint8_t>(gSrneLiveCount >> 8), static_cast<uint8_t>(gSrneLiveCount & 0xff), 0x00, 0x00};
  const uint16_t crc = modbusCrc(request, 6);
  request[6] = crc & 0xff;
  request[7] = crc >> 8;
  srneSend(request, sizeof(request));
  gSrneLastTxAt = millis();
  gSrneLastTxLive = true;
  Serial.println("DUAL_SRNE_READ_SENT");
}

// A Modbus exception is a refusal of one request, not a broken controller.
// When the live read was the last frame out, the block is tried one step
// shorter before the controller is written off. Returns true once the live
// read has taken responsibility for the exception; the caller asks only when
// no other request could have earned it.
bool srneLiveReadStepDown() {
  if (!gSrneLastTxLive) return false;
  if (gSrneLiveCount > 0x22) {
    gSrneLiveCount = 0x22;
    diagLog("CTRL_LIVE_SHORTER count=0x%02x", unsigned(gSrneLiveCount));
    return true;
  }
  // Both lengths refused: the address and the module are right, the register
  // map is not. Say that instead of letting the ladder blame the hardware.
  gLinkError = "The controller answers on Bluetooth but refuses the live measurement block at 0x0100, at full length and shortened. Its register map is not the one this firmware reads.";
  gCtrlVerdict = gLinkError;
  return true;
}

void sendSrneLoadCommand(bool on) {
  // SRNE Shiner load control: holding register 0x010A, 1=ON and 0=OFF.
  uint8_t request[] = {0xff, 0x06, 0x01, 0x0a, 0x00, static_cast<uint8_t>(on ? 0x01 : 0x00), 0x00, 0x00};
  const uint16_t crc = modbusCrc(request, 6);
  request[6] = crc & 0xff;
  request[7] = crc >> 8;
  srneSend(request, sizeof(request));
  gSrneLastTxAt = millis();
  Serial.printf("DUAL_SRNE_LOAD_WRITE value=%s register=010A\n", on ? "ON" : "OFF");
}

void sendSrneRegisterRead(uint16_t address, const char *label) {
  uint8_t request[] = {0xff, 0x03, static_cast<uint8_t>(address >> 8), static_cast<uint8_t>(address & 0xff), 0x00, 0x01, 0x00, 0x00};
  const uint16_t crc = modbusCrc(request, 6);
  request[6] = crc & 0xff;
  request[7] = crc >> 8;
  srneSend(request, sizeof(request));
  gSrneLastTxAt = millis();
  Serial.printf("DUAL_SRNE_REGISTER_READ label=%s address=%04X\n", label, address);
}

void sendSrneRead(uint16_t address, uint16_t count) {
  uint8_t request[] = {0xff, 0x03, static_cast<uint8_t>(address >> 8), static_cast<uint8_t>(address & 0xff), static_cast<uint8_t>(count >> 8), static_cast<uint8_t>(count & 0xff), 0x00, 0x00};
  const uint16_t crc = modbusCrc(request, 6);
  request[6] = crc & 0xff;
  request[7] = crc >> 8;
  srneSend(request, sizeof(request));
  gSrneLastTxAt = millis();
  Serial.printf("DUAL_SRNE_READ address=%04X count=%u\n", address, count);
}

void sendSrneRegisterWrite(uint16_t address, uint16_t value, const char *label) {
  uint8_t request[] = {0xff, 0x06, static_cast<uint8_t>(address >> 8), static_cast<uint8_t>(address & 0xff), static_cast<uint8_t>(value >> 8), static_cast<uint8_t>(value & 0xff), 0x00, 0x00};
  const uint16_t crc = modbusCrc(request, 6);
  request[6] = crc & 0xff;
  request[7] = crc >> 8;
  srneSend(request, sizeof(request));
  gSrneLastTxAt = millis();
  Serial.printf("DUAL_SRNE_REGISTER_WRITE label=%s address=%04X value=%04X\n", label, address, value);
}

void sendSrneSettingsWrite(const uint16_t *values) {
  uint8_t request[41] = {0xff, 0x10, 0xe0, 0x05, 0x00, 0x10, 0x20};
  for (uint8_t index = 0; index < 16; ++index) {
    request[7 + index * 2] = static_cast<uint8_t>(values[index] >> 8);
    request[8 + index * 2] = static_cast<uint8_t>(values[index] & 0xff);
  }
  const uint16_t crc = modbusCrc(request, 39);
  request[39] = crc & 0xff; request[40] = crc >> 8;
  srneSend(request, sizeof(request));
  gSrneLastTxAt = millis();
  Serial.println("DUAL_SRNE_SETTINGS_BATCH_WRITE start=E005 count=16");
}

// Read-only SRNE battery-setting block: E005..E014. Sent 300 ms after the
// information block, from the loop rather than from inside a delay.
void sendSrneSettingsBlockRead() {
  uint8_t request[] = {0xff, 0x03, 0xe0, 0x04, 0x00, 0x11, 0x00, 0x00};
  const uint16_t crc = modbusCrc(request, 6);
  request[6] = crc & 0xff;
  request[7] = crc >> 8;
  srneSend(request, sizeof(request));
  gSrneLastTxAt = millis();
  Serial.println("DUAL_SRNE_SETTINGS_READ_SENT start=E004 count=17");
}

void sendSrneSettingsRead() {
  // SRNE expects the controller information block before the settings block.
  uint8_t initRequest[] = {0xff, 0x03, 0x00, 0x0c, 0x00, 0x08, 0x00, 0x00};
  const uint16_t crc = modbusCrc(initRequest, 6);
  initRequest[6] = crc & 0xff;
  initRequest[7] = crc >> 8;
  srneSend(initRequest, sizeof(initRequest));
  gSrneLastTxAt = millis();
  srneSendAfter(kSrneSendSettingsBlock, 300);
}

void sendJkRead() {
  uint8_t request[20] = {0xaa, 0x55, 0x90, 0xeb, 0x96};
  uint8_t checksum = 0;
  for (size_t index = 0; index < sizeof(request) - 1; ++index) checksum += request[index];
  request[sizeof(request) - 1] = checksum;
#ifdef NOXBRAIN_BENCH
  { const bool ok = gJkChar->writeValue(request, sizeof(request), false);
    static uint32_t printed = 0;
    if (printed++ < 6 || !ok) BENCH_PORT.printf("BENCH_JK write cmd=0x%02x ok=%d\n", request[4], ok); }
#else
  gJkChar->writeValue(request, sizeof(request), false);
#endif
  Serial.println("DUAL_JK_READ_SENT");
}

void sendJkDeviceInfo() {
  uint8_t request[20] = {0xaa, 0x55, 0x90, 0xeb, 0x96};
  request[4] = 0x97;
  uint8_t checksum = 0;
  for (size_t index = 0; index < sizeof(request) - 1; ++index) checksum += request[index];
  request[sizeof(request) - 1] = checksum;
#ifdef NOXBRAIN_BENCH
  { const bool ok = gJkChar->writeValue(request, sizeof(request), false);
    static uint32_t printed = 0;
    if (printed++ < 6 || !ok) BENCH_PORT.printf("BENCH_JK write cmd=0x%02x ok=%d\n", request[4], ok); }
#else
  gJkChar->writeValue(request, sizeof(request), false);
#endif
  Serial.println("DUAL_JK_DEVICE_INFO_SENT");
}

// JBD read request "DD A5 <cmd> 00 <sum hi> <sum lo> 77" (sum = 0x10000 - cmd).
// Cells (0x04) and pack state (0x03) alternate, one request per second, so
// the BMS Bluetooth module never gets two frames at once.
void sendJbdRead() {
  if(!gJbdWriter) return;
  const uint8_t command=gJbdNextRequest;
  gJbdNextRequest=command==0x04?0x03:0x04;
  const uint16_t sum=uint16_t(0x10000-command);
  uint8_t request[7] = {0xdd, 0xa5, command, 0x00, uint8_t(sum >> 8), uint8_t(sum & 0xff), 0x77};
  gJbdWriter->writeValue(request, sizeof(request), false);
}

#include "universal_gateway.h"
} // namespace
// Keep an OTA image in "pending verify" until gatewayRollbackTick() confirms it.
extern "C" bool verifyRollbackLater() { return true; }
// The default 8 KB loop stack overflowed in a TLS handshake started from
// gatewayPollCommands() (command result upload); 16 KB leaves ample margin.
SET_LOOP_TASK_STACK_SIZE(16 * 1024);
void setup() { gatewaySetup(); }
void loop() { gatewayLoop(); }
