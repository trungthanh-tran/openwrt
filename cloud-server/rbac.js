// rbac.js — định nghĩa quyền theo tính năng + helper kiểm tra.
"use strict";

// Danh mục quyền (feature-level). Key dùng trong DB; value là nhãn hiển thị.
const PERMISSIONS = {
  "health.view":     "Xem trạng thái & latency proxy",
  "wifi.view":       "Xem danh sách WiFi/SOCKS",
  "wifi.manage":     "Thêm / sửa / xoá WiFi",
  "sock.change":     "Đổi SOCKS không reload WiFi",
  "config.apply":    "Đẩy & áp cấu hình lên router",
  "backup.create":   "Tạo / tải backup",
  "backup.rollback": "Khôi phục (rollback)",
  "device.manage":   "Quản lý router (thêm/xoá, cấp key)",
  "user.manage":     "Quản lý người dùng & phân quyền",
  "audit.view":      "Xem nhật ký hoạt động",
};

const ALL = Object.keys(PERMISSIONS);

// Quyền chỉ superuser mới được cấp/giữ (nhạy cảm).
const SUPER_ONLY = ["user.manage", "device.manage"];

// Tập quyền gợi ý cho "user vận hành thường".
const DEFAULT_OPERATOR = ["health.view", "wifi.view", "sock.change", "backup.create"];

function effective(user) {
  return user.is_super ? ALL.slice() : (user.permissions || []);
}
function has(user, perm) {
  return !!user && (user.is_super || (user.permissions || []).indexOf(perm) !== -1);
}
// Giới hạn phạm vi thiết bị: 'all' hoặc mảng id.
function canDevice(user, deviceId) {
  if (!user) return false;
  if (user.is_super) return true;
  const s = user.device_scope;
  if (s === "all") return true;
  return Array.isArray(s) && s.indexOf(Number(deviceId)) !== -1;
}
// Lọc danh sách quyền hợp lệ khi tạo/sửa user thường (bỏ quyền super-only).
function sanitizePermissions(list) {
  if (!Array.isArray(list)) return [];
  return list.filter(p => ALL.indexOf(p) !== -1 && SUPER_ONLY.indexOf(p) === -1);
}

module.exports = { PERMISSIONS, ALL, SUPER_ONLY, DEFAULT_OPERATOR, effective, has, canDevice, sanitizePermissions };
