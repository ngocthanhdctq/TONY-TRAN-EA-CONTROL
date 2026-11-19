# TONY TRAN EA CONTROL - Quy trình tạo bộ cài tự động

## Mục tiêu đầu ra
- Android: `app-debug.apk` (APK debug đã được Android tự ký để cài thử nghiệm).
- Windows: `TonyTranBridge.exe`, kèm `start_bridge.bat` và README trong ZIP.

## Build tự động bằng GitHub Actions
1. Đưa toàn bộ thư mục dự án lên một GitHub repository của bạn.
2. Mở tab **Actions** của repository.
3. Chọn workflow **Build TONY TRAN EA CONTROL installers**.
4. Nhấn **Run workflow** và chờ cả hai job `android-apk` và `windows-exe` hoàn tất.
5. Mở lần chạy vừa xong, tải hai Artifacts:
   - `TONY_TRAN_EA_CONTROL-Android-APK`
   - `TONY_TRAN_EA_CONTROL-Windows-EXE`
6. Giải nén ZIP Windows; chạy `start_bridge.bat`. Cài APK trên điện thoại Android.

Workflow dùng runner Ubuntu để build APK và runner Windows để build EXE đúng hệ điều hành. APK hiện là bản debug để thử nghiệm, chưa phải bản phát hành Play Store. EXE chưa có chứng thư ký số nên SmartScreen có thể cảnh báo.

## Thiết lập MT5 và kết nối
1. Trong MT5 > Tools > Options > Expert Advisors, thêm `http://127.0.0.1:8765` vào danh sách WebRequest.
2. Trong EA v1.026, bật `InpEnablePhoneBridge=true`, nhập token trùng token Bridge và giữ URL `http://127.0.0.1:8765` khi chạy Bridge cùng máy.
3. Chỉ thử trên tài khoản Demo. Nếu điều khiển qua LAN/Tailscale, giới hạn Windows Firewall vào mạng tin cậy; không mở port router ra Internet.

## Giới hạn chưa phát hành
- EA Settings trên app vẫn là cấu hình chờ (`STAGED_ONLY`), không được hiểu là đã áp dụng vào EA.
- Dashboard chưa đồng bộ thống kê lịch sử đầy đủ.
- Phải kiểm thử luồng điện thoại → Bridge → EA → ACK trên MT5 Demo trước khi dùng tài khoản thật.
- `TẮT EA` chỉ chặn lệnh mới; quản lý vị thế và Stop bảo vệ đang có vẫn tiếp tục.
