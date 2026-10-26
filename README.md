# Cosmos-Based Chain Auto-Upgrade Script

Script tự động nâng cấp (Auto-Upgrade) chuẩn xác và an toàn dành cho các node Validator / Fullnode chạy trên nền tảng **Cosmos SDK** (như Cosmos Hub `gaiad`, Hippo `hippod`, Osmosis `osmosisd`, Celestia, v.v.).

---

## 🌟 Tính Năng Nổi Bật

- **Dùng binary có sẵn (`NEW_BIN`)**: Không cần tải link trực tiếp khi đang chạy; binary được upload hoặc biên dịch sẵn trên server, hạn chế rủi ro mạng chập chờn khi đến giờ upgrade.
- **Xử lý đặc thù Cosmos SDK Halt/Panic**:
  - Khi đến `UPGRADE_HEIGHT`, daemon Cosmos SDK sẽ tự panic và dừng (`UPGRADE "..." NEEDED at height: ...`), làm cổng RPC bị tắt.
  - Script tự động nhận diện việc node dừng ở `UPGRADE_HEIGHT - 1` hoặc `UPGRADE_HEIGHT` qua `journalctl` và trạng thái service, kích hoạt quy trình thay thế binary ngay lập tức mà không bị treo lặp vô tận.
- **Khắc phục lỗi Systemd `start-limit-hit`**:
  - Dừng service và chạy `systemctl reset-failed` trước khi copy file để giải phóng binary cũ và xóa bộ đếm crash-loop của systemd.
  - Khởi động lại service sạch sẽ và ổn định.
- **Theo dõi Proposal tự động (Polkachu API)**:
  - Tự động kiểm tra trạng thái Proposal nâng cấp qua Gov API. Nếu proposal bị `REJECTED`, script sẽ tự động dừng quy trình nâng cấp để bảo vệ node.
- **Ước tính thời gian thực (Estimated Time)**:
  - Tính toán `Avg Block Time` dựa trên dữ liệu thực tế luỹ kế của node để hiển thị thời gian còn lại (ngày, giờ, phút, giây) chính xác nhất.
- **Chạy nền qua Screen an toàn**:
  - Tự động khởi tạo phiên `screen` riêng biệt, có cơ chế chống chạy đè (`screen -ls`). Bạn có thể an tâm tắt terminal / SSH.
- **Kiểm tra an toàn 2 lớp**:
  - Chạy thử `$NEW_BIN version` ngay lúc khởi động script và kiểm tra lại một lần nữa trước khi swap binary.
- **Gửi thông báo Telegram**:
  - Báo cáo kết quả nâng cấp thành công hoặc gửi thông báo sự cố về group / cá nhân.

---

## 📁 Cấu Trúc Thư Mục Khuyến Nghị

```text
/root/auto-upgrade/ (hoặc $HOME/auto-upgrade/)
├── cosmos.sh        # Script auto-upgrade chính
├── gaiad            # Binary phiên bản mới đã tải sẵn
├── tg.conf          # File cấu hình Telegram (tuỳ chọn)
├── README.md
└── CHANGELOG.md
```

---

## ⚙️ Cấu Hình

Bạn có thể chỉnh sửa trực tiếp các biến mặc định ở đầu file `cosmos.sh` hoặc truyền qua biến môi trường khi chạy:

| Biến | Mặc định trong code | Mô tả |
| :--- | :--- | :--- |
| `UPGRADE_HEIGHT` | `33618500` | Block height diễn ra nâng cấp chain |
| `BINARY` | `gaiad` | Tên binary của daemon node |
| `SCREEN_NAME` | `cosmos-upgrade` | Tên session screen chạy nền |
| `PROJECT_HOME` | `$HOME` | Thư mục home của user chạy node |
| `NEW_BIN` | `$PROJECT_HOME/auto-upgrade/gaiad` | Đường dẫn file binary mới đã tải sẵn |
| `CONFIG_DIR` | `$PROJECT_HOME/.gaia/config` | Thư mục config của node (để tự dò `RPC_PORT`) |
| `PROPOSAL_URL` | `https://cosmos-api.polkachu.com/...` | API kiểm tra trạng thái proposal |

### Cấu hình thông báo Telegram (`tg.conf`)
Tạo file `tg.conf` nằm cùng thư mục với script hoặc tại `/root/auto-upgrade/tg.conf`:
```bash
BOT_TOKEN="123456789:ABCdefGhIJKlmNoPQRsTUVwxyZ"
CHAT_ID_ALARM="-1001234567890"
```

---

## 🚀 Hướng Dẫn Sử Dụng

### 1. Phân quyền thực thi
```bash
chmod +x cosmos.sh
chmod +x /root/auto-upgrade/gaiad  # hoặc đường dẫn đến NEW_BIN
```

### 2. Khởi chạy Script
Chạy với quyền `root` hoặc `sudo`:
```bash
bash cosmos.sh
```
*Hoặc tuỳ biến biến môi trường khi khởi chạy:*
```bash
UPGRADE_HEIGHT=33618500 NEW_BIN=$HOME/auto-upgrade/gaiad bash cosmos.sh
```

### 3. Các lệnh quản lý phiên Screen
Sau khi chạy, script sẽ tự detach ra một màn hình ảo `screen`. Bạn có thể:

- **Xem tiến trình watcher đang chạy:**
  ```bash
  screen -r cosmos-upgrade
  ```
- **Rời khỏi màn hình mà KHÔNG tắt watcher:**
  Nhấn tổ hợp phím: `Ctrl + A` sau đó nhấn `D`
- **Tắt hẳn watcher (khi cần huỷ):**
  ```bash
  screen -S cosmos-upgrade -X quit
  ```
- **Xem danh sách các screen đang có:**
  ```bash
  screen -ls
  ```

---

## 🔍 Log & Kiểm Tra Sau Upgrade

- File log nâng cấp được ghi tại: `$PROJECT_HOME/upgrade.log`
- Kiểm tra trạng thái service:
  ```bash
  systemctl status gaiad --no-pager
  journalctl -u gaiad -n 100 -f --no-pager
  ```

---

## ⚠️ Lưu Ý Quan Trọng
- Tuyệt đối **không nhấn `Ctrl + C`** khi đang gắn (`attach`) vào session screen, vì sẽ làm tắt script auto-upgrade. Hãy dùng `Ctrl + A` rồi nhấn `D`.
- Sau khi nâng cấp và service khởi động thành công, screen session sẽ tự động chờ 15 phút để bạn tiện quan sát rồi mới đóng.
