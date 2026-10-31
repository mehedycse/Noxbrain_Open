package com.noxbrainsolarmonitoring

import android.content.*
import android.net.*
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.HttpURLConnection
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject
import org.json.JSONArray

class MainActivity : FlutterFragmentActivity() {
    private val handler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val connectivity by lazy { getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager }
    private val gatewayAddress = "192.168.4.1" // ESP32 soft-AP default address
    private val vaultAlias = "noxbrain.firebase.v1"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.noxbrainsolarmonitoring/credentials").setMethodCallHandler { call, result ->
            try {
                val prefs = getSharedPreferences("private_credentials", Context.MODE_PRIVATE)
                if (call.method == "save") {
                    val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
                    val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                    if (!store.containsAlias(vaultAlias)) {
                        generator.init(KeyGenParameterSpec.Builder(vaultAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
                        generator.generateKey()
                    }
                    val key = store.getKey(vaultAlias, null) as SecretKey
                    val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key) }
                    val encrypted = cipher.doFinal(JSONObject(call.arguments as Map<*, *>).toString().toByteArray(Charsets.UTF_8))
                    val saved = prefs.edit().putString("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
                        .putString("data", Base64.encodeToString(encrypted, Base64.NO_WRAP)).commit()
                    check(saved) { "Secure credential storage failed" }
                    result.success(true)
                } else if (call.method == "load") {
                    val data = prefs.getString("data", null)
                    if (data == null) result.success(null) else {
                        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                        val key = store.getKey(vaultAlias, null) as SecretKey
                        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
                            init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, Base64.decode(prefs.getString("iv", ""), Base64.NO_WRAP)))
                        }
                        val json = JSONObject(String(cipher.doFinal(Base64.decode(data, Base64.NO_WRAP)), Charsets.UTF_8))
                        result.success(decodeJson(json))
                    }
                } else if (call.method == "clear") {
                    // Full app reset / logout: remove every stored secret and its key.
                    prefs.edit().clear().commit()
                    val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                    if (store.containsAlias(vaultAlias)) store.deleteEntry(vaultAlias)
                    result.success(true)
                } else result.notImplemented()
            } catch (_: Exception) { result.error("SECURE_STORAGE", "Secure credentials are unavailable. Verify Firebase login again.", null) }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.noxbrainsolarmonitoring/wifi_scanner").setMethodCallHandler { call, result ->
            when (call.method) {
                "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                "openWifiSettings" -> { startActivity(Intent(Settings.ACTION_WIFI_SETTINGS)); result.success(true) }
                "installApk" -> {
                    // Opens Android's own installer for an APK the app has already
                    // verified (size + SHA-256). Only files in this app's cache.
                    val file = java.io.File(call.argument<String>("path") ?: "")
                    if (!file.exists() || !file.canonicalPath.startsWith(cacheDir.canonicalPath)) {
                        result.error("INVALID_APK", "Update file not found.", null); return@setMethodCallHandler
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                        startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                        result.error("INSTALL_PERMISSION", "Allow this app to install updates, then tap Update again.", null); return@setMethodCallHandler
                    }
                    val uri = androidx.core.content.FileProvider.getUriForFile(this, "$packageName.updates", file)
                    startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(true)
                }
                "gatewayRequest" -> {
                    // The user joins the gateway hotspot from the phone's own Wi-Fi
                    // settings. Only gateway traffic goes over that Wi-Fi, and only to
                    // the gateway's fixed soft-AP address; Firebase keeps the normal
                    // Internet route. The app checks the gateway identity first.
                    val network = gatewayWifiNetwork()
                    val path = call.argument<String>("path") ?: ""
                    if (network == null || !path.startsWith("/") || path.contains("://")) {
                        result.error("NO_GATEWAY", "Connect the phone to the NoxBrain gateway Wi-Fi from its Wi-Fi settings.", null); return@setMethodCallHandler
                    }
                    val method = call.argument<String>("method") ?: "GET"
                    val body = call.argument<String>("body")
                    val token = call.argument<String>("token")
                    worker.execute {
                        try {
                            val conn = network.openConnection(java.net.URL("http://$gatewayAddress$path")) as HttpURLConnection
                            conn.connectTimeout = 10000; conn.readTimeout = 20000; conn.requestMethod = method
                            if (token != null) conn.setRequestProperty("X-Setup-Token", token)
                            if (body != null) { conn.doOutput = true; conn.setRequestProperty("Content-Type", "application/json"); conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) } }
                            val status = conn.responseCode
                            val text = (if (status < 400) conn.inputStream else conn.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
                            conn.disconnect()
                            handler.post { result.success(mapOf("status" to status, "body" to text)) }
                        } catch (_: Exception) { handler.post { result.error("GATEWAY_REQUEST", "Gateway did not respond. Stay connected to its Wi-Fi and retry.", null) } }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** The phone's Wi-Fi network that is the gateway hotspot (192.168.4.x). */
    @Suppress("DEPRECATION")
    private fun gatewayWifiNetwork(): Network? = connectivity.allNetworks.firstOrNull { network ->
        val wifi = connectivity.getNetworkCapabilities(network)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        val link = connectivity.getLinkProperties(network)
        wifi && link != null && (
            link.routes.any { it.gateway is Inet4Address && it.gateway?.hostAddress == gatewayAddress } ||
            link.linkAddresses.any { it.address is Inet4Address && it.address.hostAddress?.startsWith("192.168.4.") == true })
    }

    private fun decodeJson(value: Any?): Any? = when(value) {
        is JSONObject -> value.keys().asSequence().associateWith { decodeJson(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { decodeJson(value.get(it)) }
        JSONObject.NULL -> null
        else -> value
    }

    override fun onDestroy() {
        worker.shutdownNow()
        super.onDestroy()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setHighRefreshRate()
    }

    override fun onResume() {
        super.onResume()
        setHighRefreshRate()
    }

    private fun setHighRefreshRate() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val currentWindow = window ?: return
            val currentDisplay = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                display
            } else {
                @Suppress("DEPRECATION")
                currentWindow.windowManager.defaultDisplay
            } ?: return

            val modes = currentDisplay.supportedModes
            var bestMode = currentDisplay.mode
            for (m in modes) {
                if (m.refreshRate > bestMode.refreshRate) {
                    bestMode = m
                }
            }

            val params = currentWindow.attributes
            params.preferredDisplayModeId = bestMode.modeId
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                params.preferredRefreshRate = bestMode.refreshRate
            }
            currentWindow.attributes = params
        }
    }
}
