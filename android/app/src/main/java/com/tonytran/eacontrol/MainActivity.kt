package com.tonytran.eacontrol

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { TonyApp() }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TonyApp() {
    var tab by remember { mutableIntStateOf(0) }
    var host by remember { mutableStateOf("http://100.x.y.z:8765") }
    var token by remember { mutableStateOf("CHANGE_THIS_TOKEN") }
    var status by remember { mutableStateOf("Chưa kết nối / Disconnected") }
    var result by remember { mutableStateOf("Chưa có thao tác / No action yet") }
    var movePips by remember { mutableStateOf("10") }
    var initialStop by remember { mutableStateOf("100") }
    var lots by remember { mutableStateOf("0.01") }
    var maxPositions by remember { mutableStateOf("10") }
    var target by remember { mutableStateOf("5.0") }
    var eaEnabled by remember { mutableStateOf<Boolean?>(null) }
    val scope = rememberCoroutineScope()

    MaterialTheme {
        Scaffold(
            topBar = { TopAppBar(title = { Text("TONY TRAN EA CONTROL") }) },
            bottomBar = {
                NavigationBar {
                    val labels = listOf("Tổng quan", "Điều khiển", "Cài đặt EA", "Thống kê")
                    val icons = listOf(Icons.Default.Dashboard, Icons.Default.Tune, Icons.Default.Settings, Icons.Default.Assessment)
                    labels.forEachIndexed { i, label ->
                        NavigationBarItem(selected = tab == i, onClick = { tab = i },
                            icon = { Icon(icons[i], contentDescription = label) }, label = { Text(label) })
                    }
                }
            }
        ) { pad ->
            Column(Modifier.padding(pad).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                when (tab) {
                    0 -> {
                        Text("TỔNG QUAN / DASHBOARD", style = MaterialTheme.typography.titleLarge)
                        Info("Kết nối / Connection", status)
                        Info("Trạng thái EA", when (eaEnabled) { true -> "ĐANG BẬT – cho phép lệnh mới"; false -> "ĐANG TẮT – chặn lệnh mới"; null -> "Chưa xác nhận từ EA" })
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button(onClick = { scope.launch { result = post(host, token, "/api/command", """{"type":"EA_ENABLE"}"""); status = "Đã gửi yêu cầu BẬT EA; chờ EA xác nhận" } }, modifier = Modifier.weight(1f), enabled = eaEnabled != true) { Text("BẬT EA") }
                            Button(onClick = { scope.launch { result = post(host, token, "/api/command", """{"type":"EA_DISABLE"}"""); status = "Đã gửi yêu cầu TẮT EA; chờ EA xác nhận" } }, modifier = Modifier.weight(1f), enabled = eaEnabled != false, colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)) { Text("TẮT EA") }
                        }
                        OutlinedButton(onClick = { scope.launch { val raw = get(host, token); status = raw; eaEnabled = when { Regex("""\"trading_enabled\"\s*:\s*true""").containsMatchIn(raw) -> true; Regex("""\"trading_enabled\"\s*:\s*false""").containsMatchIn(raw) -> false; else -> null } } }, modifier = Modifier.fillMaxWidth()) { Text("LÀM MỚI TRẠNG THÁI EA") }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Info("Số lệnh hôm nay", "—", Modifier.weight(1f))
                            Info("Tổng lot hôm nay", "—", Modifier.weight(1f))
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Info("Lệnh đang mở", "—", Modifier.weight(1f))
                            Info("Lợi nhuận", "—", Modifier.weight(1f))
                        }
                        Text("Dữ liệu thật sẽ hiển thị sau khi tích hợp EA Bridge.")
                    }
                    1 -> {
                        Text("ĐIỀU KHIỂN / CONTROL", style = MaterialTheme.typography.titleLarge)
                        Text("Điều khiển qua Bridge; mọi lệnh giao dịch chỉ thử trên Demo trước.")
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button(onClick = { scope.launch { result = post(host, token, "/api/command", """{"type":"BUY"}""") } }, modifier = Modifier.weight(1f)) { Text("MUA / BUY") }
                            Button(onClick = { scope.launch { result = post(host, token, "/api/command", """{"type":"SELL"}""") } }, modifier = Modifier.weight(1f),
                                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)) { Text("BÁN / SELL") }
                        }
                        OutlinedButton(onClick = { scope.launch { result = post(host, token, "/api/command", """{"type":"CLOSE_ALL"}""") } }, modifier = Modifier.fillMaxWidth()) { Text("ĐÓNG TẤT CẢ / CLOSE ALL") }
                        OutlinedTextField(movePips, { movePips = it }, label = { Text("Mỗi lần dời Stop (pip)") }, modifier = Modifier.fillMaxWidth())
                        Button(onClick = {
                            val n = movePips.toDoubleOrNull() ?: 0.0
                            scope.launch { result = post(host, token, "/api/command", """{"type":"MOVE_STOP","step_pips":$n}""") }
                        }, modifier = Modifier.fillMaxWidth()) { Text("DỜI STOP / MOVE STOP") }
                        Text(result)
                        Text("Khi TẮT: EA chặn lệnh BUY/SELL mới và lệnh thêm vị thế. Quản lý vị thế hiện có và Stop bảo vệ vẫn tiếp tục; Stop đối ứng đã đặt sẵn vẫn có thể được kích hoạt.", style = MaterialTheme.typography.bodySmall)
                    }
                    2 -> {
                        Text("CÀI ĐẶT EA / EA SETTINGS", style = MaterialTheme.typography.titleLarge)
                        OutlinedTextField(lots, { lots = it }, label = { Text("Lot ban đầu / Initial lot") }, modifier = Modifier.fillMaxWidth())
                        OutlinedTextField(initialStop, { initialStop = it }, label = { Text("Stop ban đầu (100 = 10 pip)") }, modifier = Modifier.fillMaxWidth())
                        OutlinedTextField(maxPositions, { maxPositions = it }, label = { Text("Số lệnh tối đa / Max positions") }, modifier = Modifier.fillMaxWidth())
                        OutlinedTextField(target, { target = it }, label = { Text("Mục tiêu chu kỳ / Cycle target USD") }, modifier = Modifier.fillMaxWidth())
                        Button(onClick = {
                            val payload = """{"lots":${lots.toDoubleOrNull() ?: 0.01},"initial_stop_units":${initialStop.toDoubleOrNull() ?: 100.0},"max_positions":${maxPositions.toIntOrNull() ?: 10},"cycle_target_usd":${target.toDoubleOrNull() ?: 5.0}}"""
                            scope.launch { result = post(host, token, "/api/settings", payload) }
                        }, modifier = Modifier.fillMaxWidth()) { Text("LƯU CẤU HÌNH / SAVE SETTINGS") }
                        Text("Bản hiện tại chỉ lưu cấu hình chờ (STAGED_ONLY), CHƯA áp dụng vào EA. Inputs MQL5 không thể sửa trực tiếp khi EA đang chạy. Không dùng các giá trị này để điều khiển giao dịch cho đến khi có module xác thực và ACK riêng.")
                    }
                    else -> {
                        Text("THỐNG KÊ / STATISTICS", style = MaterialTheme.typography.titleLarge)
                        Info("Số lệnh trong ngày", "Chờ dữ liệu EA")
                        Info("Tổng lot trong ngày", "Chờ dữ liệu EA")
                        Info("Lịch sử", "Chưa đồng bộ")
                    }
                }
                HorizontalDivider()
                Text("KẾT NỐI / CONNECTION", style = MaterialTheme.typography.titleMedium)
                OutlinedTextField(host, { host = it }, label = { Text("Bridge URL (LAN/Tailscale)") }, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(token, { token = it }, label = { Text("Access token") }, modifier = Modifier.fillMaxWidth())
                Button(onClick = { scope.launch { status = get(host, token) } }, modifier = Modifier.fillMaxWidth()) {
                    Text("KIỂM TRA KẾT NỐI / TEST CONNECTION")
                }
            }
        }
    }
}

@Composable
fun Info(title: String, value: String, modifier: Modifier = Modifier) {
    ElevatedCard(modifier) {
        Column(Modifier.padding(14.dp)) {
            Text(title, style = MaterialTheme.typography.labelMedium)
            Spacer(Modifier.height(5.dp))
            Text(value, style = MaterialTheme.typography.titleMedium)
        }
    }
}

suspend fun get(host: String, token: String): String = withContext(Dispatchers.IO) {
    try {
        val c = URL(host.trimEnd('/') + "/api/status").openConnection() as HttpURLConnection
        c.connectTimeout = 3000; c.readTimeout = 3000
        c.setRequestProperty("Authorization", "Bearer $token")
        val body = c.inputStream.bufferedReader().readText()
        c.disconnect()
        "Bridge phản hồi / Bridge response: $body"
    } catch (e: Exception) { "Lỗi kết nối / Connection error: ${e.message}" }
}

suspend fun post(host: String, token: String, path: String, body: String): String = withContext(Dispatchers.IO) {
    try {
        val c = URL(host.trimEnd('/') + path).openConnection() as HttpURLConnection
        c.requestMethod = "POST"; c.doOutput = true
        c.connectTimeout = 3000; c.readTimeout = 3000
        c.setRequestProperty("Authorization", "Bearer $token")
        c.setRequestProperty("Content-Type", "application/json")
        c.outputStream.use { it.write(body.toByteArray()) }
        val stream = if (c.responseCode in 200..299) c.inputStream else c.errorStream
        val response = stream.bufferedReader().readText()
        c.disconnect()
        response
    } catch (e: Exception) { "Lỗi gửi yêu cầu / Request error: ${e.message}" }
}
