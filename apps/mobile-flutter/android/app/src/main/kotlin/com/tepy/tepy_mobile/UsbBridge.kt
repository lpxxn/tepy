package com.tepy.tepy_mobile

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.hoho.android.usbserial.driver.UsbSerialDriver
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import com.hoho.android.usbserial.util.SerialInputOutputManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Flutter 平台通道：Dart 负责业务协议，这里仅提供 Android USB Host 字节流。
 * 成熟的 usb-serial-for-android 负责 CDC/ACM 驱动，不在应用里重写 USB 协议。
 * 所有可能阻塞的串口操作都放在工作线程；不输出收到的启动日志、口令或配置。
 */
class UsbBridge(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val methods = MethodChannel(messenger, "tepy/usb")
    private val events = EventChannel(messenger, "tepy/usb/events")
    private val manager = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val permissionAction = "${context.packageName}.USB_PERMISSION"
    private var sink: EventChannel.EventSink? = null
    private data class Pending(val driver: UsbSerialDriver, val port: Int, val result: MethodChannel.Result)
    private var pending: Pending? = null
    @Volatile private var generation = 0
    @Volatile private var port: UsbSerialPort? = null
    private var connection: UsbDeviceConnection? = null
    private var reader: SerialInputOutputManager? = null

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val device = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                else @Suppress("DEPRECATION") (intent.getParcelableExtra(UsbManager.EXTRA_DEVICE) as? UsbDevice)
            if (intent.action == permissionAction) {
                val request = pending ?: return
                if (device?.deviceId != request.driver.device.deviceId) return
                pending = null
                // 真正授权以 UsbManager 为准，不信任广播里自报的 granted 字段。
                if (manager.hasPermission(device)) openPort(request)
                else request.result.error("usb_permission", "USB 访问未获授权。", null)
            } else if (intent.action == UsbManager.ACTION_USB_DEVICE_DETACHED) {
                if (pending?.driver?.device?.deviceId == device?.deviceId) {
                    pending?.result?.error("usb_detached", "USB 已拔出。", null); pending = null
                }
                if (port?.driver?.device?.deviceId == device?.deviceId) closePort(notify = true)
            }
        }
    }

    init {
        methods.setMethodCallHandler(this); events.setStreamHandler(this)
        val filter = IntentFilter(permissionAction).apply { addAction(UsbManager.ACTION_USB_DEVICE_DETACHED) }
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else @Suppress("DEPRECATION") context.registerReceiver(receiver, filter)
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) { sink = eventSink }
    override fun onCancel(arguments: Any?) { sink = null }

    private fun drivers(): List<UsbSerialDriver> = UsbSerialProber.getDefaultProber()
        .findAllDrivers(manager).filter { it.device.vendorId == 0x303A }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "list" -> result.success(drivers().flatMap { driver -> driver.ports.mapIndexed { index, _ ->
                mapOf("id" to "${driver.device.deviceId}:$index", "name" to (driver.device.productName ?: "ESP32 USB Serial"),
                    "vendor_id" to driver.device.vendorId, "product_id" to driver.device.productId)
            } })
            "open" -> {
                if (pending != null || port != null) { result.error("usb_busy", "USB 已连接或正在申请授权。", null); return }
                val id = call.argument<String>("id") ?: ""
                val selected = drivers().flatMap { driver -> driver.ports.indices.map { index -> Pair(driver, index) } }
                    .firstOrNull { "${it.first.device.deviceId}:${it.second}" == id }
                if (selected == null) { result.error("usb_missing", "没有找到 ESP32 原生 USB 串口。", null); return }
                val request = Pending(selected.first, selected.second, result)
                if (manager.hasPermission(selected.first.device)) openPort(request)
                else {
                    pending = request
                    // 新版 Android 要求可变 PendingIntent 使用显式包名。
                    val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                        (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                    val permission = PendingIntent.getBroadcast(context, 0, Intent(permissionAction).setPackage(context.packageName), flags)
                    manager.requestPermission(selected.first.device, permission)
                }
            }
            "write" -> {
                val bytes = call.argument<ByteArray>("bytes")
                val current = port; val lease = generation
                if (bytes == null || bytes.size > 20007 || current == null) {
                    result.error("usb_write", "USB 未连接或帧过大。", null); return
                }
                worker.execute {
                    try {
                        if (current !== port || lease != generation) throw IllegalStateException()
                        current.write(bytes, 3000)
                        main.post { result.success(null) }
                    } catch (_: Exception) { main.post { result.error("usb_write", "USB 写入结果未确认。", null) } }
                    finally { bytes.fill(0) }
                }
            }
            "close" -> {
                pending?.result?.error("usb_cancelled", "USB 授权已取消。", null); pending = null
                closePort(notify = false); result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun openPort(request: Pending) {
        val lease = ++generation
        worker.execute {
            var opened: UsbSerialPort? = null
            var usb: UsbDeviceConnection? = null
            try {
                usb = manager.openDevice(request.driver.device) ?: throw IllegalStateException()
                val selected = request.driver.ports[request.port]
                opened = selected
                selected.open(usb)
                selected.setParameters(115200, 8, UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE)
                selected.setRTS(false); selected.setDTR(true)
                val io = SerialInputOutputManager(selected, object : SerialInputOutputManager.Listener {
                    override fun onNewData(data: ByteArray) {
                        val copy = data.copyOf()
                        main.post {
                            if (generation == lease && port === selected) sink?.success(mapOf("event" to "data", "lease" to lease, "bytes" to copy))
                            copy.fill(0)
                        }
                    }
                    override fun onRunError(error: Exception) {
                        main.post { if (generation == lease) closePort(notify = true) }
                    }
                })
                main.post {
                    if (generation != lease) {
                        try { selected.close() } catch (_: Exception) {}
                        usb?.close()
                        request.result.error("usb_cancelled", "USB 连接已取消。", null)
                    } else {
                        connection = usb; port = selected; reader = io
                        io.start(); request.result.success(mapOf("lease" to lease))
                    }
                }
            } catch (_: Exception) {
                try { opened?.close() } catch (_: Exception) {}
                usb?.close()
                main.post { request.result.error("usb_open", "无法打开串口，请确认原生 USB 接口和 OTG 授权。", null) }
            }
        }
    }

    private fun closePort(notify: Boolean) {
        val lease = generation++
        val old = port; port = null
        reader?.stop(); reader = null
        try { old?.close() } catch (_: Exception) {}
        connection?.close(); connection = null
        if (notify) sink?.success(mapOf("event" to "closed", "lease" to lease))
    }

    fun dispose() {
        pending?.result?.error("usb_cancelled", "USB 已关闭。", null); pending = null
        closePort(notify = false)
        context.unregisterReceiver(receiver)
        methods.setMethodCallHandler(null); events.setStreamHandler(null); sink = null
        worker.shutdownNow()
    }
    fun pause() {
        pending?.result?.error("usb_cancelled", "应用已进入后台。", null); pending = null
        closePort(notify = true)
    }
}
