package il.planechat.plane_chat

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.location.LocationManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pGroup
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.net.Inet4Address
import java.net.NetworkInterface

class MainActivity : FlutterActivity() {
    private var p2p: WifiP2pManager? = null
    private var p2pChannel: WifiP2pManager.Channel? = null
    private var shareChannel: MethodChannel? = null
    private var pendingShare: Map<String, Any?>? = null
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "plane_chat/wifi_direct").setMethodCallHandler { call, result ->
            try {
                handleWifi(call, result)
            } catch (e: SecurityException) {
                result.error("PERMISSION", e.message, null)
            } catch (e: Exception) {
                result.error("ERROR", e.message, null)
            }
        }
        shareChannel = MethodChannel(messenger, "plane_chat/share").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "takeInitialShare" -> { result.success(pendingShare); pendingShare = null }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(messenger, "plane_chat/system").setMethodCallHandler { call, result ->
            when (call.method) {
                "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                "notify" -> { notifyIncoming(call.argument<String>("title") ?: "", call.argument<String>("body") ?: ""); result.success(null) }
                "startKeepAlive" -> { KeepAliveService.start(this); result.success(null) }
                "moveToBack" -> { moveTaskToBack(true); result.success(null) }
                "stopKeepAlive" -> { KeepAliveService.stop(this); result.success(null) }
                else -> result.notImplemented()
            }
        }
        pendingShare = readShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val s = readShare(intent) ?: return
        shareChannel?.invokeMethod("onShare", s)
    }

    // ---------------- Wi-Fi Direct group owner ----------------

    private fun ensureP2p(): Boolean {
        if (p2p == null) {
            p2p = getSystemService(Context.WIFI_P2P_SERVICE) as WifiP2pManager?
            p2pChannel = p2p?.initialize(this, mainLooper) { p2pChannel = null }
        }
        if (p2pChannel == null && p2p != null) p2pChannel = p2p?.initialize(this, mainLooper, null)
        return p2p != null && p2pChannel != null
    }

    private fun handleWifi(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> {
                val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                val lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
                val locOn = if (Build.VERSION.SDK_INT >= 28) lm.isLocationEnabled else true
                result.success(mapOf(
                    "wifiEnabled" to wifi.isWifiEnabled,
                    "p2pSupported" to packageManager.hasSystemFeature("android.hardware.wifi.direct"),
                    "locationEnabled" to locOn,
                    "fixedNameSupported" to (Build.VERSION.SDK_INT >= 29),
                    "sdkInt" to Build.VERSION.SDK_INT,
                ))
            }
            "openWifiSettings" -> { startActivity(Intent(Settings.ACTION_WIFI_SETTINGS)); result.success(null) }
            "openLocationSettings" -> { startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)); result.success(null) }
            "startGroup" -> {
                val ssid = call.argument<String>("ssid")!!
                val pass = call.argument<String>("passphrase")!!
                val band2g = call.argument<Boolean>("band2g") ?: true
                if (!ensureP2p()) { result.error("UNSUPPORTED", "Wi-Fi Direct not available", null); return }
                val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                if (!wifi.isWifiEnabled) { result.error("WIFI_OFF", "Wi-Fi is off", null); return }
                // Remove any old group first, then create ours.
                p2p!!.removeGroup(p2pChannel!!, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() { main.postDelayed({ createGroup(ssid, pass, band2g, result, 0) }, 400) }
                    override fun onFailure(reason: Int) { createGroup(ssid, pass, band2g, result, 0) }
                })
            }
            "stopGroup" -> {
                if (!ensureP2p()) { result.success(null); return }
                p2p!!.removeGroup(p2pChannel!!, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() { result.success(null) }
                    override fun onFailure(reason: Int) { result.success(null) }
                })
            }
            "groupInfo" -> {
                if (!ensureP2p()) { result.success(null); return }
                p2p!!.requestGroupInfo(p2pChannel!!) { g -> result.success(groupMap(g)) }
            }
            else -> result.notImplemented()
        }
    }

    private fun createGroup(ssid: String, pass: String, band2g: Boolean, result: MethodChannel.Result, attempt: Int) {
        val listener = object : WifiP2pManager.ActionListener {
            override fun onSuccess() { waitForGroup(result, 0) }
            override fun onFailure(reason: Int) {
                if (reason == WifiP2pManager.BUSY && attempt < 4) {
                    main.postDelayed({ createGroup(ssid, pass, band2g, result, attempt + 1) }, 1000)
                } else {
                    val name = when (reason) {
                        WifiP2pManager.P2P_UNSUPPORTED -> "P2P_UNSUPPORTED"
                        WifiP2pManager.BUSY -> "BUSY"
                        WifiP2pManager.NO_SERVICE_REQUESTS -> "NO_SERVICE_REQUESTS"
                        else -> "ERROR"
                    }
                    result.error(name, "createGroup failed ($reason)", null)
                }
            }
        }
        if (Build.VERSION.SDK_INT >= 29) {
            val cfg = WifiP2pConfig.Builder()
                .setNetworkName(ssid)
                .setPassphrase(pass)
                .setGroupOperatingBand(if (band2g) WifiP2pConfig.GROUP_OWNER_BAND_2GHZ else WifiP2pConfig.GROUP_OWNER_BAND_AUTO)
                .build()
            p2p!!.createGroup(p2pChannel!!, cfg, listener)
        } else {
            // Android 9 and older: system picks a random name and password.
            p2p!!.createGroup(p2pChannel!!, listener)
        }
    }

    private fun waitForGroup(result: MethodChannel.Result, attempt: Int) {
        p2p!!.requestGroupInfo(p2pChannel!!) { g ->
            if (g != null && g.isGroupOwner && g.passphrase != null) {
                result.success(groupMap(g))
            } else if (attempt < 12) {
                main.postDelayed({ waitForGroup(result, attempt + 1) }, 500)
            } else {
                result.error("NO_GROUP", "group did not come up", null)
            }
        }
    }

    private fun groupMap(g: WifiP2pGroup?): Map<String, Any?>? {
        if (g == null) return null
        var ip: String? = null
        try {
            val ni = NetworkInterface.getByName(g.`interface` ?: "")
            ni?.inetAddresses?.toList()?.firstOrNull { it is Inet4Address }?.let { ip = it.hostAddress }
        } catch (_: Exception) {}
        return mapOf(
            "ssid" to g.networkName,
            "passphrase" to g.passphrase,
            "isOwner" to g.isGroupOwner,
            "interface" to g.`interface`,
            "ownerIp" to (ip ?: "192.168.49.1"),
            "frequency" to (if (Build.VERSION.SDK_INT >= 29) g.frequency else null),
            "clients" to g.clientList.size,
        )
    }

    // ---------------- Share target ----------------

    private fun readShare(intent: Intent?): Map<String, Any?>? {
        if (intent == null) return null
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return null
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        val uris = mutableListOf<Uri>()
        if (action == Intent.ACTION_SEND) {
            val u: Uri? = if (Build.VERSION.SDK_INT >= 33)
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)
            if (u != null) uris.add(u)
        } else {
            val list: ArrayList<Uri>? = if (Build.VERSION.SDK_INT >= 33)
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else @Suppress("DEPRECATION") intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
            if (list != null) uris.addAll(list)
        }
        val paths = uris.take(10).mapNotNull { compressToCache(it) }
        intent.action = null // don't re-handle on rotation
        if (text.isNullOrBlank() && paths.isEmpty()) return null
        return mapOf("text" to text, "images" to paths)
    }

    /** Decode (respecting EXIF rotation), downscale to max 1280 px, JPEG q72. */
    private fun compressToCache(uri: Uri): String? {
        return try {
            val maxSide = 1280
            val bmp: Bitmap = if (Build.VERSION.SDK_INT >= 28) {
                ImageDecoder.decodeBitmap(ImageDecoder.createSource(contentResolver, uri)) { dec, info, _ ->
                    val w = info.size.width; val h = info.size.height
                    val scale = minOf(1.0, maxSide.toDouble() / maxOf(w, h))
                    dec.setTargetSize((w * scale).toInt().coerceAtLeast(1), (h * scale).toInt().coerceAtLeast(1))
                    dec.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                }
            } else {
                val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, opts) }
                var sample = 1
                while (maxOf(opts.outWidth, opts.outHeight) / (sample * 2) >= maxSide) sample *= 2
                val o2 = BitmapFactory.Options().apply { inSampleSize = sample }
                contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, o2) } ?: return null
            }
            val dir = File(cacheDir, "shared").apply { mkdirs() }
            val out = File(dir, "share_${System.currentTimeMillis()}_${(0..9999).random()}.jpg")
            FileOutputStream(out).use { bmp.compress(Bitmap.CompressFormat.JPEG, 72, it) }
            out.absolutePath
        } catch (e: Exception) {
            android.util.Log.w("PlaneChat", "shared image failed: $uri", e)
            null
        }
    }

    // ---------------- Notifications ----------------

    private fun notifyIncoming(title: String, body: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel("messages", "הודעות", NotificationManager.IMPORTANCE_HIGH))
        }
        val pi = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(this, "messages")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
        try { nm.notify(1001, n) } catch (_: SecurityException) {}
    }
}
