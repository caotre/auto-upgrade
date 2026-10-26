# Changelog

Tất cả các thay đổi quan trọng của bộ script **Auto-Upgrade Cosmos-Based Chains** sẽ được ghi lại trong tài liệu này.

Định dạng dựa trên [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) và tuân theo [Semantic Versioning](https://semver.org/).

---

## [1.2.0] - 2026-10-26

### Added
- **Cơ chế phát hiện Node Panic/Halt ở Upgrade Height**:
  - Khi node Cosmos SDK chạm mốc `UPGRADE_HEIGHT` và panic dừng tiến trình (`UPGRADE NEEDED`), cổng RPC sẽ bị ngắt kết nối.
  - Thêm logic kiểm tra: nếu RPC sập khi `last_known_height >= UPGRADE_HEIGHT - 1` kết hợp kiểm tra `journalctl` và trạng thái `systemctl`, script sẽ lập tức phát hiện node đã dừng theo đúng kế hoạch và tiến hành thay thế binary, không bị lặp vô tận.
- **Xử lý lỗi `start-limit-hit` của Systemd**:
  - Thêm lệnh `systemctl stop "$BINARY"` và `systemctl reset-failed "$BINARY"` trước khi thay thế binary.
  - Thêm lệnh `systemctl reset-failed` và `systemctl daemon-reload` trước khi khởi động lại service với binary mới để xóa trạng thái crash-loop rate limit.
- **Linh hoạt vị trí tìm `tg.conf`**:
  - Hỗ trợ tự động dò file cấu hình Telegram tại `/root/auto-upgrade/tg.conf`, `${PROJECT_HOME}/auto-upgrade/tg.conf` hoặc ngay trong thư mục chứa script.

### Changed
- Cập nhật banner thông tin từ Hippo thành `COSMOS-BASED CHAIN AUTO UPGRADE`.
- Cải thiện cấu trúc `run_watcher`: tách biệt rõ ràng vòng lặp theo dõi (`WATCH LOOP`) và khối thực thi nâng cấp (`UPGRADE EXECUTION`).

---

## [1.1.0] - 2026-10-26

### Added
- Kiểm tra file binary local (`NEW_BIN`): kiểm tra tồn tại (`-f`), kích thước khác 0 (`-s`), tự động cấp quyền thực thi `chmod +x` và in thông tin file.

### Changed
- **Chuyển sang sử dụng binary có sẵn trên server**:
  - Loại bỏ hoàn toàn bước tải qua URL và biến `BINARY_URL`.
  - Loại bỏ dependency `wget` khỏi danh sách công cụ bắt buộc.
  - Đổi phương thức thay thế binary từ `mv -f` sang `cp -f` an toàn (kèm kiểm tra tránh tự copy chính nó) để giữ lại file binary gốc phục vụ việc kiểm tra hoặc rollback khi cần.

---

## [1.0.0] - 2026-10-25

### Added
- Khởi tạo script tự động nâng cấp cho node Cosmos-based chain.
- Tự động nhận diện cấu hình `RPC_PORT` qua file `config.toml` và `client.toml`.
- Chạy nền trong phiên ảo `screen` kèm cơ chế chống mở trùng session.
- Ước tính thời gian đến block upgrade (`Estimated Time`) dựa trên tốc độ sinh block thực tế (`avg_time`).
- Tích hợp kiểm tra trạng thái proposal qua Polkachu API, tự động huỷ nếu proposal bị `REJECTED`.
- Tích hợp gửi thông báo trạng thái qua Telegram Bot.
- Tự động ghi nhật ký quá trình nâng cấp vào file `upgrade.log`.
