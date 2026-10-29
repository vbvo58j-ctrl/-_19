package com.plosap.myapp

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.Intent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.net.Uri
import android.provider.Settings
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.io.PrintWriter
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    companion object {
        private const val METHODS = "com.blousab.messenger/bluetooth"
        private const val EVENTS = "com.blousab.messenger/events"
        private const val SERVICE_NAME = "BlousabRFCOMM"
        private val SERVICE_UUID: UUID =
            UUID.fromString("f0e1d2c3-b4a5-4678-9012-123456789abc")
    }

    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val serverRunning = AtomicBoolean(false)
    private val sockets = ConcurrentHashMap<String, BluetoothSocket>()
    private val writers = ConcurrentHashMap<String, PrintWriter>()
    private val discovered = ConcurrentHashMap<String, BluetoothDevice>()
    @Volatile private var discoveryReceiver: BroadcastReceiver? = null

    @Volatile private var eventSink: EventChannel.EventSink? = null
    @Volatile private var serverSocket: BluetoothServerSocket? = null

    private val adapter: BluetoothAdapter?
        get() = BluetoothAdapter.getDefaultAdapter()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.blousab.messenger/battery")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "isIgnoringBatteryOptimizations" -> {
                            result.success(if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                val powerManager = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
                                powerManager.isIgnoringBatteryOptimizations(packageName)
                            } else true)
                        }
                        "requestIgnoreBatteryOptimizations" -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                                    .setData(Uri.parse("package:$packageName"))
                                if (intent.resolveActivity(packageManager) != null) startActivity(intent)
                                else startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                            }
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("BATTERY_SETTINGS", e.message ?: "تعذر فتح إعدادات البطارية", null)
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHODS)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "isSupported" -> result.success(adapter != null)
                        "getAndroidSdk" -> result.success(Build.VERSION.SDK_INT)
                        "isEnabled" -> {
                            if (!hasConnectPermission()) {
                                result.error("PERMISSION", "امنح صلاحية البلوتوث أولاً", null)
                            } else result.success(adapter?.isEnabled == true)
                        }
                        "requestEnable" -> {
                            if (!hasConnectPermission()) {
                                result.error("PERMISSION", "امنح صلاحية البلوتوث أولاً", null)
                            } else {
                                startActivity(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
                                result.success(true)
                            }
                        }
                        "requestDiscoverable" -> {
                            if (!hasConnectPermission() || !hasAdvertisePermission()) {
                                result.error("PERMISSION", "صلاحية إظهار البلوتوث للأجهزة القريبة غير متاحة", null)
                            } else {
                                startActivity(Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE).putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, 300))
                                result.success(true)
                            }
                        }
                        "startDiscovery" -> {
                            if (!hasConnectPermission() || !hasScanPermission()) {
                                result.error("PERMISSION", "صلاحيات البحث عن أجهزة البلوتوث غير متاحة", null)
                            } else {
                                startDiscovery(result)
                            }
                        }
                        "cancelDiscovery" -> {
                            try { adapter?.cancelDiscovery() } catch (_: Exception) {}
                            result.success(true)
                        }
                        "getPairedDevices" -> {
                            if (!hasConnectPermission()) {
                                result.error("PERMISSION", "صلاحية البلوتوث غير متاحة", null)
                            } else {
                                val devices = adapter?.bondedDevices?.map {
                                    mapOf("name" to (it.name ?: "جهاز"), "address" to it.address)
                                } ?: emptyList<Map<String, String>>()
                                result.success(devices)
                            }
                        }
                        "startServer" -> {
                            if (!hasConnectPermission()) result.error("PERMISSION", "صلاحية البلوتوث غير متاحة", null)
                            else startServer(result)
                        }
                        "connect" -> {
                            if (!hasConnectPermission()) {
                                result.error("PERMISSION", "صلاحية البلوتوث غير متاحة", null)
                            } else {
                                val address = call.argument<String>("address")
                                if (address.isNullOrBlank()) result.error("ADDRESS", "عنوان الجهاز مطلوب", null)
                                else connect(address, result)
                            }
                        }
                        "sendMessage" -> {
                            val address = call.argument<String>("address")
                            val message = call.argument<String>("message")
                            if (address.isNullOrBlank() || message == null) {
                                result.error("ARGUMENT", "بيانات الرسالة ناقصة", null)
                            } else {
                                executor.execute {
                                    try {
                                        val targets = if (address == "*") writers.entries.toList() else {
                                            val writer = writers[address]
                                                ?: throw IllegalStateException("الجهاز غير متصل")
                                            listOf(java.util.AbstractMap.SimpleEntry(address, writer))
                                        }
                                        if (targets.isEmpty()) throw IllegalStateException("لا توجد أجهزة متصلة")
                                        var sent = 0
                                        var lastError: Exception? = null
                                        for ((peerAddress, writer) in targets) {
                                            try {
                                                synchronized(writer) {
                                                    writer.println(message)
                                                    writer.flush()
                                                    if (writer.checkError()) throw java.io.IOException("فشل الإرسال")
                                                }
                                                sent++
                                            } catch (e: Exception) {
                                                lastError = e
                                                closePeer(peerAddress)
                                            }
                                        }
                                        if (sent == 0) throw (lastError ?: java.io.IOException("فشل الإرسال"))
                                        mainHandler.post { result.success(true) }
                                    } catch (e: Exception) {
                                        mainHandler.post {
                                            result.error("SEND", e.message ?: "فشل إرسال الرسالة", null)
                                        }
                                    }
                                }
                            }
                        }
                        "disconnect" -> {
                            val address = call.argument<String>("address")
                            if (address.isNullOrBlank()) closeAll() else closePeer(address)
                            result.success(true)
                        }
                        "stopServer" -> {
                            stopServer()
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: SecurityException) {
                    result.error("PERMISSION", e.message ?: "صلاحية البلوتوث غير متاحة", null)
                } catch (e: Exception) {
                    result.error("NATIVE_ERROR", e.message ?: "حدث خطأ في البلوتوث", null)
                }
            }
    }

    private fun hasConnectPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED

    private fun hasScanPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_SCAN) ==
            PackageManager.PERMISSION_GRANTED

    private fun hasAdvertisePermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_ADVERTISE) ==
            PackageManager.PERMISSION_GRANTED

    private fun startDiscovery(result: MethodChannel.Result) {
        val bluetooth = adapter
        if (bluetooth == null || !bluetooth.isEnabled) {
            result.error("BLUETOOTH_OFF", "شغّل البلوتوث أولاً", null)
            return
        }
        try {
            try { bluetooth.cancelDiscovery() } catch (_: Exception) {}
            discoveryReceiver?.let {
                try { unregisterReceiver(it) } catch (_: Exception) {}
            }
            discovered.clear()
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    if (intent?.action != BluetoothDevice.ACTION_FOUND) return
                    @Suppress("DEPRECATION")
                    val device = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE) as? BluetoothDevice ?: return
                    try {
                        val address = device.address ?: return
                        val name = try { device.name ?: "جهاز بلوتوث" } catch (_: SecurityException) { "جهاز بلوتوث" }
                        discovered[address] = device
                        emit("deviceFound", address, name)
                    } catch (_: SecurityException) { }
                }
            }
            discoveryReceiver = receiver
            val filter = IntentFilter(BluetoothDevice.ACTION_FOUND)
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                registerReceiver(receiver, filter)
            }
            val started = bluetooth.startDiscovery()
            if (!started) {
                try { unregisterReceiver(receiver) } catch (_: Exception) {}
                discoveryReceiver = null
                result.error("DISCOVERY_FAILED", "تعذر بدء البحث عن أجهزة قريبة", null)
            } else result.success(true)
        } catch (e: Exception) {
            result.error("DISCOVERY_FAILED", e.message ?: "تعذر البحث عن الأجهزة", null)
        }
    }

    private fun emit(type: String, address: String? = null, name: String? = null, message: String? = null) {
        val event = mutableMapOf<String, Any>("type" to type)
        address?.let { event["address"] = it }
        name?.let { event["name"] = it }
        message?.let { event["message"] = it }
        mainHandler.post { eventSink?.success(event) }
    }

    private fun startServer(result: MethodChannel.Result) {
        val bluetooth = adapter
        if (bluetooth == null) {
            result.error("UNSUPPORTED", "هذا الجهاز لا يدعم البلوتوث", null)
            return
        }
        if (!bluetooth.isEnabled) {
            result.error("BLUETOOTH_OFF", "شغّل البلوتوث أولاً", null)
            return
        }
        if (!serverRunning.compareAndSet(false, true)) {
            result.success(true)
            return
        }

        executor.execute {
            try {
                val listening = bluetooth.listenUsingRfcommWithServiceRecord(SERVICE_NAME, SERVICE_UUID)
                serverSocket = listening
                mainHandler.post { result.success(true) }
                emit("serverStarted")
                while (serverRunning.get()) {
                    val client = listening.accept()
                    executor.execute { registerPeer(client) }
                }
            } catch (e: Exception) {
                if (serverRunning.get()) emit("serverError", message = e.message ?: "تعذر تشغيل الاستقبال")
                mainHandler.post {
                    // result.error is only safe if the start request has not already completed;
                    // the event channel reports asynchronous listener errors.
                }
            } finally {
                serverRunning.set(false)
                try { serverSocket?.close() } catch (_: Exception) {}
                serverSocket = null
            }
        }
    }

    private fun connect(address: String, result: MethodChannel.Result) {
        executor.execute {
            var socket: BluetoothSocket? = null
            try {
                val device = adapter?.getRemoteDevice(address)
                    ?: throw IllegalStateException("البلوتوث غير متاح")
                try { adapter?.cancelDiscovery() } catch (_: SecurityException) {}
                socket = device.createRfcommSocketToServiceRecord(SERVICE_UUID)
                socket.connect()
                registerPeer(socket)
                mainHandler.post { result.success(true) }
            } catch (e: Exception) {
                try { socket?.close() } catch (_: Exception) {}
                emit("connectionError", address, message = e.message ?: "تعذر الاتصال بالجهاز")
                mainHandler.post { result.error("CONNECT_FAILED", e.message ?: "تعذر الاتصال بالجهاز", null) }
            }
        }
    }

    private fun registerPeer(socket: BluetoothSocket) {
        val address = socket.remoteDevice.address
        val name = try { socket.remoteDevice.name ?: "جهاز" } catch (_: Exception) { "جهاز" }
        // Keep one socket per physical address to avoid duplicate writers/connection conflicts.
        closePeer(address, notify = false)
        try {
            val writer = PrintWriter(OutputStreamWriter(socket.outputStream, Charsets.UTF_8), true)
            sockets[address] = socket
            writers[address] = writer
            emit("connected", address, name)
            executor.execute {
                try {
                    val reader = BufferedReader(InputStreamReader(socket.inputStream, Charsets.UTF_8))
                    while (true) {
                        val line = reader.readLine() ?: break
                        emit("message", address, name, line)
                    }
                } catch (e: Exception) {
                    emit("connectionError", address, message = e.message ?: "انقطع الاتصال")
                } finally {
                    if (sockets[address] === socket) closePeer(address)
                    else try { socket.close() } catch (_: Exception) {}
                }
            }
        } catch (e: Exception) {
            try { socket.close() } catch (_: Exception) {}
            emit("connectionError", address, message = e.message ?: "تعذر إعداد الاتصال")
        }
    }

    private fun closePeer(address: String, notify: Boolean = true) {
        writers.remove(address)
        try { sockets.remove(address)?.close() } catch (_: Exception) {}
        if (notify) emit("disconnected", address)
    }

    private fun closeAll() {
        sockets.keys.toList().forEach { closePeer(it) }
    }

    private fun stopServer() {
        serverRunning.set(false)
        try { serverSocket?.close() } catch (_: Exception) {}
        serverSocket = null
        closeAll()
        emit("serverStopped")
    }

    override fun onDestroy() {
        stopServer()
        try { adapter?.cancelDiscovery() } catch (_: Exception) {}
        discoveryReceiver?.let { try { unregisterReceiver(it) } catch (_: Exception) {} }
        discoveryReceiver = null
        executor.shutdownNow()
        super.onDestroy()
    }
}
