package il.planechat.plane_chat

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.AdvertisingOptions
import com.google.android.gms.nearby.connection.ConnectionInfo
import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback
import com.google.android.gms.nearby.connection.ConnectionOptions
import com.google.android.gms.nearby.connection.ConnectionResolution
import com.google.android.gms.nearby.connection.ConnectionType
import com.google.android.gms.nearby.connection.ConnectionsClient
import com.google.android.gms.nearby.connection.ConnectionsStatusCodes
import com.google.android.gms.nearby.connection.DiscoveredEndpointInfo
import com.google.android.gms.nearby.connection.DiscoveryOptions
import com.google.android.gms.nearby.connection.EndpointDiscoveryCallback
import com.google.android.gms.nearby.connection.Payload
import com.google.android.gms.nearby.connection.PayloadCallback
import com.google.android.gms.nearby.connection.PayloadTransferUpdate
import com.google.android.gms.nearby.connection.Strategy
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * v4: automatic Bluetooth link with Google Nearby Connections.
 * Same service id and P2P_CLUSTER strategy as the iOS side (google/nearby
 * Swift package, Strategy.cluster). NON_DISRUPTIVE so Nearby never turns
 * the user's hotspot / Wi‑Fi off to "upgrade" the link.
 */
class NearbyBridge(context: Context, messenger: BinaryMessenger) {
    private val client: ConnectionsClient = Nearby.getConnectionsClient(context)
    private val channel = MethodChannel(messenger, "planechat/nearby")
    private val main = Handler(Looper.getMainLooper())
    private var serviceId: String? = null
    private var info: ByteArray = ByteArray(0)
    private var running = false
    private val connected = mutableSetOf<String>()

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                handle(call, result)
            } catch (e: Exception) {
                result.error("error", e.message, null)
            }
        }
    }

    private fun emit(method: String, args: Map<String, Any?>) {
        main.post { channel.invokeMethod(method, args) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                serviceId = call.argument<String>("serviceId")
                info = (call.argument<String>("info") ?: "").toByteArray(Charsets.UTF_8)
                running = true
                startBoth(result)
            }
            "stop" -> {
                running = false
                client.stopAdvertising()
                client.stopDiscovery()
                client.stopAllEndpoints()
                connected.clear()
                result.success(null)
            }
            "connect" -> {
                val id = call.argument<String>("id")!!
                val opts = ConnectionOptions.Builder()
                    .setConnectionType(ConnectionType.NON_DISRUPTIVE)
                    .build()
                client.requestConnection(info, id, lifecycle, opts)
                    .addOnSuccessListener { result.success(null) }
                    .addOnFailureListener { e -> result.error(codeOf(e), describe(e), null) }
            }
            "send" -> {
                val id = call.argument<String>("id")!!
                val bytes = call.argument<ByteArray>("bytes")!!
                client.sendPayload(id, Payload.fromBytes(bytes))
                    .addOnSuccessListener { result.success(null) }
                    .addOnFailureListener { e -> result.error(codeOf(e), describe(e), null) }
            }
            "disconnect" -> {
                val id = call.argument<String>("id")!!
                client.disconnectFromEndpoint(id)
                connected.remove(id)
                // The local side gets no onDisconnected: look for the peer again.
                if (running && connected.isEmpty()) restart()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun advertisingOptions() = AdvertisingOptions.Builder()
        .setStrategy(Strategy.P2P_CLUSTER)
        .setConnectionType(ConnectionType.NON_DISRUPTIVE)
        .build()

    private fun discoveryOptions() = DiscoveryOptions.Builder()
        .setStrategy(Strategy.P2P_CLUSTER)
        .build()

    /** Advertise and discover at the same time; ok if at least one works. */
    private fun startBoth(result: MethodChannel.Result?) {
        val sid = serviceId ?: run { result?.error("error", "no service id", null); return }
        var pending = 2
        var ok = false
        var err: Exception? = null
        fun done(success: Boolean, e: Exception?) {
            if (success) ok = true else if (err == null) err = e
            pending--
            if (pending == 0 && result != null) {
                if (ok) result.success(null)
                else result.error(codeOf(err), describe(err), null)
            }
        }
        client.startAdvertising(info, sid, lifecycle, advertisingOptions())
            .addOnSuccessListener { done(true, null) }
            .addOnFailureListener { e -> done(alreadyRunning(e), e) }
        client.startDiscovery(sid, discovery, discoveryOptions())
            .addOnSuccessListener { done(true, null) }
            .addOnFailureListener { e -> done(alreadyRunning(e), e) }
    }

    private fun restart() {
        client.stopAdvertising()
        client.stopDiscovery()
        main.postDelayed({ if (running) startBoth(null) }, 500)
    }

    private fun alreadyRunning(e: Exception): Boolean {
        val c = (e as? ApiException)?.statusCode ?: return false
        return c == ConnectionsStatusCodes.STATUS_ALREADY_ADVERTISING ||
            c == ConnectionsStatusCodes.STATUS_ALREADY_DISCOVERING
    }

    private fun codeOf(e: Exception?): String {
        val msg = describe(e)
        return if (msg.contains("MISSING_PERMISSION") || msg.contains("permission", true)) "permission" else "error"
    }

    private fun describe(e: Exception?): String {
        if (e is ApiException) {
            return "${e.statusCode} ${ConnectionsStatusCodes.getStatusCodeString(e.statusCode)} ${e.message ?: ""}".trim()
        }
        return e?.message ?: "unknown"
    }

    private val discovery = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(endpointId: String, i: DiscoveredEndpointInfo) {
            val bytes = try { i.endpointInfo } catch (_: Throwable) { null }
            val text = if (bytes != null && bytes.isNotEmpty()) String(bytes, Charsets.UTF_8) else i.endpointName
            emit("found", mapOf("id" to endpointId, "info" to text))
        }

        override fun onEndpointLost(endpointId: String) {
            emit("lost", mapOf("id" to endpointId))
        }
    }

    private val payloads = object : PayloadCallback() {
        override fun onPayloadReceived(endpointId: String, payload: Payload) {
            if (payload.type == Payload.Type.BYTES) {
                val b = payload.asBytes() ?: return
                emit("data", mapOf("id" to endpointId, "bytes" to b))
            }
        }

        override fun onPayloadTransferUpdate(endpointId: String, update: PayloadTransferUpdate) {}
    }

    private val lifecycle = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(endpointId: String, ci: ConnectionInfo) {
            // Only our own app advertises this service id; the chat itself
            // checks the peer in its hello frame. Accept on both sides.
            emit("initiated", mapOf("id" to endpointId, "incoming" to ci.isIncomingConnection))
            client.acceptConnection(endpointId, payloads)
                .addOnFailureListener { e -> emit("error", mapOf("message" to describe(e))) }
        }

        override fun onConnectionResult(endpointId: String, r: ConnectionResolution) {
            if (r.status.statusCode == ConnectionsStatusCodes.STATUS_OK) {
                connected.add(endpointId)
                // Stop scanning while connected: steadier link, less battery.
                client.stopDiscovery()
                client.stopAdvertising()
                emit("connected", mapOf("id" to endpointId))
            } else {
                emit("rejected", mapOf("id" to endpointId,
                    "reason" to "${r.status.statusCode} ${ConnectionsStatusCodes.getStatusCodeString(r.status.statusCode)}"))
            }
        }

        override fun onDisconnected(endpointId: String) {
            connected.remove(endpointId)
            emit("disconnected", mapOf("id" to endpointId))
            if (running && connected.isEmpty()) restart()
        }
    }
}
