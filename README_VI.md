# TONY TRAN EA CONTROL – Bridge integration MVP

## Thành phần trong gói
- `Dynamic_Trailing_Hedge_EA_AI_Extreme_v1_026_BRIDGE.mq5`: bản v1.025 được bổ sung module Bridge. Logic quản lý lệnh hiện hữu được giữ nguyên; thêm các lệnh từ điện thoại: BUY, SELL, CLOSE_ALL, MOVE_STOP và PING.
- `windows-bridge/bridge.py`: Windows Bridge API, xác thực Bearer token, hàng đợi lệnh, heartbeat, ACK/REJECT.
- `android/`: mã nguồn Android Kotlin/Jetpack Compose cho Dashboard, Control, EA Settings, Statistics.
- `ea-bridge-contract/PROTOCOL_V1.md`: mô tả giao thức.

## Trạng thái trung thực
Đây là **gói mã nguồn tích hợp thử nghiệm**, chưa phải bộ cài hoàn chỉnh. Bridge API đã được chạy kiểm thử HTTP cục bộ (xác thực, queue, dequeue, heartbeat và settings staging). EA MQL5 chưa được biên dịch bằng MetaEditor; APK chưa được build vì môi trường hiện tại không có Android SDK/Gradle; EXE Windows chưa được build vì PyInstaller/Windows build environment chưa có. Bắt buộc compile EA trong MetaEditor và chạy Demo trước khi dùng.

## 1. Windows 10 – Bridge
1. Giải nén ZIP vào một thư mục, ví dụ `C:\TONY_TRAN_EA_CONTROL`.
2. Để tự build EXE: cài Python 3.11+ trên Windows, mở CMD trong `windows-bridge`, chạy `build_windows.bat`. File EXE sau khi build nằm ở `dist\TonyTranBridge.exe`.
3. Chạy `start_bridge.bat`; nhập token bí mật dài ít nhất 32 ký tự. Dùng cùng token ở EA và Android. Không gửi token cho người khác.
4. Bridge lắng nghe cổng TCP 8765 trên các giao diện mạng để hỗ trợ LAN/Tailscale. Chỉ cho phép Windows Firewall nhận kết nối cổng 8765 từ mạng LAN riêng và/hoặc dải Tailscale của bạn. **Không port-forward cổng này ra Internet công cộng.**

## 2. MT5 – cài EA Bridge
1. Mở MetaEditor từ MT5, mở file `Dynamic_Trailing_Hedge_EA_AI_Extreme_v1_026_BRIDGE.mq5`, nhấn Compile.
2. Nếu MetaEditor báo lỗi, dừng lại và gửi ảnh/tab Errors để sửa; không gắn EA lên tài khoản Real.
3. Trong MT5: Tools → Options → Expert Advisors → bật Allow WebRequest for listed URL và thêm `http://127.0.0.1:8765`.
4. Gắn EA lên chart XAUUSD. Trong Inputs: `InpEnablePhoneBridge=true`, `InpBridgeUrl=http://127.0.0.1:8765`, `InpBridgeToken` nhập đúng token, `InpBridgePollSeconds=1` (lệnh điện thoại được kiểm tra luân phiên với heartbeat, thông thường khoảng 2 giây).
5. Giữ AutoTrading tắt hoặc dùng tài khoản Demo trong giai đoạn kiểm thử. EA chỉ nhận lệnh khi chart/EA/MT5 và Bridge đang chạy.

## 3. Android – build APK
Máy hiện tại của người dùng chưa cài Android Studio. Cách dễ nhất là cài Android Studio trên Windows 10, mở thư mục `android`, chờ Gradle Sync, chọn Build → Build APK(s). APK debug thường nằm tại `android\app\build\outputs\apk\debug\app-debug.apk`.

Trong ứng dụng, đặt Bridge URL:
- Cùng Wi-Fi: `http://IP-LAN-cua-PC:8765`
- Qua Internet bằng Tailscale: `http://IP-Tailscale-cua-PC:8765`

Nhập token giống Windows Bridge. Điện thoại cũng phải tham gia cùng Tailnet khi truy cập từ xa. Nếu PC tắt, MT5/EA tắt hoặc mất mạng thì không điều khiển được.

## 4. Chức năng và giới hạn bản tích hợp này
- BUY/SELL gọi lại `OpenInitialPosition()` hiện có, không tạo logic vào lệnh thứ hai.
- CLOSE_ALL gọi `CloseAllAndReset()` hiện có.
- MOVE_STOP dùng `MoveOppositeStopOneStep(step_pips)` hiện có; 10 nghĩa là 10 pip theo `PipSize()` hiện tại.
- Lệnh được gửi ACK/REJECT; hàng đợi Bridge đánh dấu DELIVERED trước khi EA thực thi để giảm nguy cơ gửi trùng khi retry mạng. Nếu ACK thất lạc, cần kiểm tra tab Experts và trạng thái Bridge trước khi gửi lại.
- Settings trong app hiện chỉ lưu `STAGED_ONLY`, **chưa áp dụng vào thông số EA**. Không coi nút lưu cài đặt là thay đổi thông số đang chạy.
- Dashboard/Statistics Android chưa đồng bộ đầy đủ các trường thống kê lịch sử; heartbeat hiện gửi symbol, balance, equity, số vị thế EA và floating profit tài khoản.
- Bridge dùng HTTP nội bộ, không có TLS riêng. Chỉ dùng trong LAN tin cậy hoặc qua Tailscale; không mở cổng trực tiếp ra Internet.

## 5. Quy trình kiểm thử an toàn
1. Compile EA trong MetaEditor và xử lý hết lỗi.
2. Chạy Bridge, kiểm tra `/api/status` từ điện thoại.
3. Bật Bridge trong EA, xác nhận heartbeat `CONNECTED`.
4. Thử PING trước; sau đó kiểm tra từng lệnh trên tài khoản Demo với khối lượng nhỏ.
5. Kiểm tra lệnh không bị lặp, ACK/REJECT, ngắt mạng, khởi động lại MT5 và Bridge.
6. Chỉ xem xét tài khoản Real sau khi toàn bộ kiểm thử thành công và người dùng chủ động xác nhận.


## 6. Bật / tắt EA trên điện thoại (bổ sung v0.4)
- Dashboard có nút **BẬT EA** và **TẮT EA**, kèm nút làm mới trạng thái.
- Lệnh `EA_DISABLE` chặn lệnh thị trường mới: tự động BUY đầu chu kỳ, lệnh thêm vị thế và BUY/SELL thủ công từ app/chart.
- Khi tắt, EA **vẫn chạy quản lý vị thế hiện có**, trailing/Stop bảo vệ, kiểm tra mục tiêu chu kỳ và Bridge heartbeat. Stop đối ứng đã đặt sẵn vẫn có thể kích hoạt; đây là cơ chế bảo vệ đang tồn tại, không bị tự ý xóa khi tắt.
- `EA_ENABLE` cho phép các lệnh mới trở lại theo cấu hình hiện hữu (bao gồm `InpEnableAutoEntry`).
- Trạng thái bật/tắt được lưu bằng Terminal Global Variable theo Magic + Symbol và được khôi phục sau khi khởi động lại EA/MT5.
- Trạng thái trên app chỉ đổi sau khi Bridge nhận heartbeat từ EA; thao tác gửi lệnh chỉ là yêu cầu xếp hàng, không phải xác nhận đã thực thi. Nhấn **LÀM MỚI TRẠNG THÁI EA** để đọc trạng thái mới nhất.
- Đây là **tạm dừng phát sinh lệnh mới**, không phải gỡ EA khỏi chart, không tắt MT5 và không đóng các vị thế đang mở.
