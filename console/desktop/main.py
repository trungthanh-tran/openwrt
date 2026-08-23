#!/usr/bin/env python3
"""Native Windows controller for the sbproxy OpenWrt agent.

This desktop application deliberately does not embed the web console or use a
WebView. It talks directly to the router CGI API and stores its bearer token
with Windows DPAPI for the current Windows user.
"""

from __future__ import annotations

import base64
import csv
import ctypes
from ctypes import wintypes
from dataclasses import dataclass
import ipaddress
import json
import logging
from logging.handlers import RotatingFileHandler
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import tkinter as tk
import unicodedata
from tkinter import filedialog, messagebox, simpledialog, ttk
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


APP_NAME = "sbproxy Console Native"
# Kept in sync with the repo VERSION file; tests/run.sh enforces the match.
APP_VERSION = "0.4.1"
APP_DIR_NAME = "sbproxy-console-native"
DEFAULT_BASE = "http://192.168.8.1"

LOG_MAX_BYTES = 1024 * 1024
LOG_BACKUP_COUNT = 5


def frozen_dir() -> Path:
    """Directory holding the running executable (or main.py when run from source)."""
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def resolve_app_home() -> Path:
    """Every file this app writes lives under one root, isolated per install.

    Precedence: SBPROXY_HOME, a portable `data/` folder beside the executable,
    then the per-user OS location. The portable form keeps a USB/copy-anywhere
    install fully self-contained.
    """
    override = os.environ.get("SBPROXY_HOME", "").strip()
    if override:
        return Path(override).expanduser()
    portable = frozen_dir() / "data"
    if portable.is_dir():
        return portable
    if os.name == "nt":
        base = os.environ.get("LOCALAPPDATA") or str(Path.home())
    else:
        base = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
    return Path(base) / APP_DIR_NAME


APP_HOME = resolve_app_home()
CONFIG_DIR = APP_HOME / "config"
CONFIG_FILE = CONFIG_DIR / "connection.json"
LOG_DIR = APP_HOME / "logs"
LOG_FILE = LOG_DIR / "console.log"
CACHE_DIR = APP_HOME / "cache"
# PyInstaller unpacks the bundled Python runtime and dependencies here (set via
# --runtime-tmpdir at build time) so nothing lands in the shared system temp.
RUNTIME_DIR = APP_HOME / "runtime"

# Config used to live directly in the app folder; keep older installs working.
LEGACY_CONFIG_FILES = (
    Path(os.environ.get("LOCALAPPDATA") or str(Path.home())) / APP_DIR_NAME / "connection.json",
    Path(os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")) / APP_DIR_NAME / "connection.json",
)

log = logging.getLogger("sbproxy")


def ensure_app_home() -> Path:
    """Create the private directory tree; POSIX keeps it owner-only."""
    for path in (APP_HOME, CONFIG_DIR, LOG_DIR, CACHE_DIR, RUNTIME_DIR):
        path.mkdir(parents=True, exist_ok=True)
        if os.name != "nt":
            try:
                os.chmod(path, 0o700)
            except OSError:
                pass
    return APP_HOME


def migrate_legacy_config() -> bool:
    """Move a pre-0.5 connection.json into the isolated config folder once."""
    if CONFIG_FILE.exists():
        return False
    for legacy in LEGACY_CONFIG_FILES:
        try:
            if legacy.resolve() == CONFIG_FILE.resolve() or not legacy.is_file():
                continue
            CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            CONFIG_FILE.write_bytes(legacy.read_bytes())
            if os.name != "nt":
                os.chmod(CONFIG_FILE, 0o600)
            log.info("migrated legacy config from %s", legacy)
            return True
        except OSError:
            continue
    return False


SECRET_PATTERN = re.compile(
    r"(?i)(token|authorization|bearer|password|passwd|pass|wifi_key|key)"
    r"(\s*[=:]\s*|\s+)"
    # "Bearer <tok>" must be consumed whole, otherwise only the scheme is masked.
    r"(Bearer\s+\S+|\"[^\"]*\"|'[^']*'|\S+)"
)


def redact(text) -> str:
    """Strip credentials before anything reaches the log file."""
    return SECRET_PATTERN.sub(lambda m: f"{m.group(1)}{m.group(2)}***", str(text))


def setup_logging(verbose: bool = False) -> Path:
    """Rotating file log plus stderr, so field issues can be diagnosed later."""
    ensure_app_home()
    log.setLevel(logging.DEBUG if verbose else logging.INFO)
    for handler in list(log.handlers):
        log.removeHandler(handler)
        handler.close()
    fmt = logging.Formatter("%(asctime)s %(levelname)-7s %(threadName)s %(message)s")
    try:
        file_handler = RotatingFileHandler(
            LOG_FILE, maxBytes=LOG_MAX_BYTES, backupCount=LOG_BACKUP_COUNT, encoding="utf-8"
        )
        file_handler.setFormatter(fmt)
        log.addHandler(file_handler)
        if os.name != "nt":
            try:
                os.chmod(LOG_FILE, 0o600)
            except OSError:
                pass
    except OSError:
        pass  # A read-only home must not stop the app from starting.
    stream = logging.StreamHandler()
    stream.setFormatter(fmt)
    log.addHandler(stream)
    log.info(
        "start %s v%s | python %s | frozen=%s | home=%s",
        APP_NAME, APP_VERSION, sys.version.split()[0], bool(getattr(sys, "frozen", False)), APP_HOME,
    )
    return LOG_FILE


def install_exception_logging() -> None:
    """Uncaught failures — main thread and workers — must reach the log file."""
    previous = sys.excepthook

    def hook(exc_type, exc, tb):
        log.critical("uncaught exception", exc_info=(exc_type, exc, tb))
        previous(exc_type, exc, tb)

    sys.excepthook = hook
    if hasattr(threading, "excepthook"):
        def thread_hook(args):
            log.critical(
                "uncaught exception in %s", args.thread.name if args.thread else "thread",
                exc_info=(args.exc_type, args.exc_value, args.exc_traceback),
            )
        threading.excepthook = thread_hook

DARK_PALETTE = {
    "bg": "#08111f",
    "header": "#0d1b2e",
    "card": "#111f33",
    "input": "#0b1728",
    "border": "#263a55",
    "text": "#edf4ff",
    "muted": "#93a4bc",
    "primary": "#3b82f6",
    "primary_active": "#2563eb",
    "success": "#16a36a",
    "success_active": "#128158",
    "warning": "#d97706",
    "warning_active": "#b45309",
    "danger": "#dc4c64",
    "danger_active": "#be334d",
    "metric": "#0d1b2e",
    "heading": "#1a2b43",
    "heading_active": "#223956",
    "tab_strip": "#08111f",
    "tab_idle": "#0b1728",
    "tab_hover": "#172a42",
    "tab_selected": "#111f33",
    "tab_selected_text": "#edf4ff",
    "table_border": "#31465f",
    "table_header_border": "#3a526f",
    "table_row_even": "#0b1728",
    "table_row_odd": "#101e31",
    "button": "#263a55",
    "button_active": "#334b6b",
    "button_pressed": "#1d2d45",
    "scroll": "#263a55",
    "log_text": "#c9d8ec",
    "selection_text": "#ffffff",
    "info": "#67e8f9",
    "good_text": "#7ee7b8",
    "warn_text": "#facc73",
    "bad_text": "#ff8da1",
    "heading_text": "#c7d7eb",
}

LIGHT_PALETTE = {
    "bg": "#eaf0f7",
    "header": "#ffffff",
    "card": "#f8fafc",
    "input": "#ffffff",
    "border": "#cbd5e1",
    "text": "#172033",
    "muted": "#64748b",
    "primary": "#2563eb",
    "primary_active": "#1d4ed8",
    "success": "#15805d",
    "success_active": "#116149",
    "warning": "#c26708",
    "warning_active": "#9a4d06",
    "danger": "#cf3854",
    "danger_active": "#ad2843",
    "metric": "#e2eaf5",
    "heading": "#dce6f2",
    "heading_active": "#cbd9e9",
    "tab_strip": "#dce4ee",
    "tab_idle": "#e5ebf3",
    "tab_hover": "#eef3f8",
    "tab_selected": "#f8fafc",
    "tab_selected_text": "#172033",
    "table_border": "#aebdce",
    "table_header_border": "#b8c6d6",
    "table_row_even": "#ffffff",
    "table_row_odd": "#f3f7fb",
    "button": "#dbe5f1",
    "button_active": "#c9d7e8",
    "button_pressed": "#b9cbe0",
    "scroll": "#b8c7d9",
    "log_text": "#26364b",
    "selection_text": "#ffffff",
    "info": "#1d4ed8",
    "good_text": "#087a55",
    "warn_text": "#9a4d06",
    "bad_text": "#b4233d",
    "heading_text": "#26364b",
}

PALETTES = {"dark": DARK_PALETTE, "light": LIGHT_PALETTE}
PALETTE = DARK_PALETTE


def rounded_tab_image(master, color: str, width=32, height=30, radius=9):
    """Create a stretchable tab surface with Chrome-like rounded top corners."""
    image = tk.PhotoImage(master=master, width=width, height=height)
    radius = max(1, min(int(radius), width // 2, height))
    for y in range(height):
        if y >= radius:
            inset = 0
        else:
            dy = radius - y - 0.5
            inset = max(0, math.ceil(radius - math.sqrt(max(0.0, radius * radius - dy * dy))))
        image.put(color, to=(inset, y, width - inset, y + 1))
    return image

EN_TRANSLATIONS = {
    "Chưa kết nối": "Not connected",
    "Kết nối": "Connect",
    "Làm mới": "Refresh",
    "Kiểm tra cổng ra": "Check gateway",
    "CỔNG RA INTERNET": "INTERNET GATEWAY",
    "● Internet chưa kiểm tra": "● Gateway not checked",
    "● Internet chưa xác định": "● Gateway unknown",
    "● Mất kết nối Internet": "● Gateway down",
    "● Internet suy giảm": "● Gateway degraded",
    "● Internet hoạt động": "● Gateway OK",
    "Đường ra: —": "Egress: —",
    "Kết nối/DNS: —": "Link/DNS: —",
    "Internet HTTP: —": "Internet HTTP: —",
    "Wi‑Fi / SOCKS5": "Wi-Fi / SOCKS5",
    "Thiết bị": "Devices",
    "Backup / Nhật ký": "Backups / Logs",
    "＋ Thêm SSID": "+ Add SSID",
    "Đẩy cấu hình & Apply": "Push configuration & Apply",
    "CHỈNH SỬA SSID ĐANG CHỌN": "EDIT SELECTED SSID",
    "Sửa cấu hình": "Edit configuration",
    "Đổi SOCKS": "Change SOCKS",
    "Xoá SSID": "Delete SSID",
    "Chọn một SSID trong bảng để chỉnh sửa": "Select an SSID in the table to edit",
    "Làm mới": "Refresh",
    "Chặn MAC…": "Block MAC…",
    "Xuất CSV": "Export CSV",
    "Tự làm mới": "Auto refresh",
    "Kết nối": "Connection",
    "Quyền": "Access",
    "Tìm IP / tên / MAC": "Find IP / name / MAC",
    "Tín hiệu": "Signal",
    "Lưu lượng": "Traffic",
    "Thời gian": "Duration",
    "Đặt lại bộ lọc": "Reset filters",
    "ĐIỀU KHIỂN THIẾT BỊ ĐANG CHỌN": "CONTROL SELECTED DEVICES",
    "Chi tiết": "Details",
    "Copy IP/MAC": "Copy IP/MAC",
    "Cấm": "Block",
    "Bỏ cấm": "Unblock",
    "Tải danh sách": "Load list",
    "Tạo backup": "Create backup",
    "Rollback backup đang chọn": "Roll back selected backup",
    "Nhật ký thao tác": "Operation log",
    "Tất cả SSID": "All SSIDs",
    "Tất cả band": "All bands",
    "Tất cả kết nối": "All connections",
    "Tất cả quyền truy cập": "All access states",
    "Tất cả tín hiệu": "All signal levels",
    "Tất cả lưu lượng": "All traffic",
    "Tất cả thời gian": "All durations",
    "Đang cấm": "Blocked",
    "Không cấm": "Not blocked",
    "Rất tốt (≥ -60 dBm)": "Excellent (≥ -60 dBm)",
    "Tốt (-70 đến -61 dBm)": "Good (-70 to -61 dBm)",
    "Yếu (-80 đến -71 dBm)": "Weak (-80 to -71 dBm)",
    "Rất yếu (< -80 dBm)": "Very weak (< -80 dBm)",
    "Không rõ": "Unknown",
    "Có lưu lượng": "Has traffic",
    "Không lưu lượng": "No traffic",
    "Từ 10 MB": "At least 10 MB",
    "Từ 100 MB": "At least 100 MB",
    "Dưới 5 phút": "Under 5 minutes",
    "5–60 phút": "5–60 minutes",
    "Trên 1 giờ": "Over 1 hour",
    "Sửa Wi‑Fi": "Edit Wi-Fi",
    "Thêm Wi‑Fi": "Add Wi-Fi",
    "Băng tần": "Band",
    "Mật khẩu Wi‑Fi": "Wi-Fi password",
    "Hãng router / MAC": "Router vendor / MAC",
    "Cách ly client": "Client isolation",
    "Chặn WebRTC": "Block WebRTC",
    "Huỷ": "Cancel",
    "Lưu": "Save",
    "Dữ liệu không hợp lệ": "Invalid data",
    "Chọn hãng router": "Select router vendor",
    "Provider / OUI": "Provider / OUI",
    "Random sẽ cập nhật provider trong config, tạo BSSID mới và reload radio.": "Randomization updates the provider, creates a new BSSID, and reloads the radio.",
    "OUI không hợp lệ": "Invalid OUI",
    "Provider không hợp lệ": "Invalid provider",
    "Ngẫu nhiên / ẩn danh": "Random / anonymous",
    "OUI tuỳ chỉnh · ": "Custom OUI · ",
    "Thêm MAC vào blocklist": "Add MAC to blocklist",
    "Chặn thiết bị theo MAC": "Block device by MAC",
    "Ví dụ: AA:BB:CC:DD:EE:FF": "Example: AA:BB:CC:DD:EE:FF",
    "Thêm vào blocklist": "Add to blocklist",
    "MAC không hợp lệ": "Invalid MAC",
    "MAC phải có dạng AA:BB:CC:DD:EE:FF": "MAC must use AA:BB:CC:DD:EE:FF format",
    "Thiếu SSID": "Missing SSID",
    "Hãy chọn SSID cần chặn": "Select the SSID to block on",
    "sbproxy · Đang xử lý": "sbproxy · Working",
    "Đang kiểm tra và áp dụng": "Validating and applying",
    "CẢNH BÁO · TÁC VỤ QUAN TRỌNG": "WARNING · IMPORTANT ACTION",
    "Thao tác": "Action",
    "Ảnh hưởng có thể xảy ra": "Possible impact",
    "Chỉ tiếp tục khi bạn đã kiểm tra đúng SSID/thiết bị và chấp nhận ảnh hưởng.": "Continue only after verifying the target SSID/device and accepting the impact.",
    "Cảnh báo": "Warning",
    "Dữ liệu không hợp lệ": "Invalid data",
    "IDX bị trùng": "Duplicate IDX",
    "IDX này đã được sử dụng": "This IDX is already in use",
    "Hãy chọn một Wi‑Fi": "Select a Wi-Fi network",
    "Hãy chọn một Wi‑Fi cần random MAC": "Select a Wi-Fi network to randomize",
    "Đổi SOCKS nhanh": "Quick SOCKS change",
    "Dry-run và Apply": "Dry-run and Apply",
    "Chưa có SSID nào để áp dụng blocklist": "No SSID is available for the blocklist",
    "Hãy chọn một hoặc nhiều thiết bị": "Select one or more devices",
    "Các thiết bị đã chọn đều offline": "All selected devices are offline",
    "Không có thiết bị bị cấm trong lựa chọn": "No blocked device is selected",
    "Các thiết bị đã chọn đều đã bị cấm": "All selected devices are already blocked",
    "Hãy chọn thiết bị cần copy": "Select devices to copy",
    "Không xuất được CSV": "Could not export CSV",
    "Chi tiết thiết bị": "Device details",
    "Nhãn backup": "Backup label",
    "Nhãn chỉ được chứa chữ, số, dấu . _ -": "The label may only contain letters, numbers, dots, underscores, and hyphens",
    "Hãy chọn một backup": "Select a backup",
    "Có": "Yes",
    "Không": "No",
    "Chặn": "Blocked",
    "Cho phép": "Allowed",
    "Trạng thái": "Status",
    "Tên máy": "Hostname",
    "Đường ra": "Egress",
    "không kiểm tra": "not checked",
    "không truy cập được": "unreachable",
    "không có route": "no route",
    "đang chạy": "running",
    "KHÔNG chạy": "NOT running",
    "Hoàn tất": "Completed",
    "LỖI": "ERROR",
    "Lỗi": "Error",
    "Tất cả file": "All files",
    "Ngôn ngữ": "Language",
    "Giao diện": "Theme",
    "Thư mục log": "Log folder",
    "Chọn thiết bị trong bảng để điều khiển": "Select devices in the table to control",
    "Chọn một backup để khôi phục": "Select a backup to restore",
    "Đổi SOCKS5": "Change SOCKS5",
    "Agent trả dữ liệu không phải JSON": "The Agent returned non-JSON data",
    "Agent trả JSON không phải object": "The Agent returned JSON that is not an object",
    "Agent báo lỗi": "The Agent reported an error",
    "IDX Wi‑Fi bị trùng": "Duplicate Wi-Fi IDX",
    "Base URL phải bắt đầu bằng http:// hoặc https://": "Base URL must start with http:// or https://",
    "Thiếu token Agent": "Agent token is required",
    "Chưa kết nối Agent": "Not connected to the Agent",
    "DPAPI chỉ có trên Windows": "DPAPI is only available on Windows",
    "Các trường không được chứa | hoặc xuống dòng": "Fields cannot contain | or line breaks",
    "SSID phải dài 1–32 ký tự": "SSID must be 1–32 characters long",
    "Băng tần phải là 2g hoặc 5g": "Band must be 2g or 5g",
    "IDX phải từ 1 đến 200": "IDX must be between 1 and 200",
    "Mật khẩu Wi‑Fi phải dài 8–63 ký tự": "Wi-Fi password must be 8–63 characters long",
    "Thiếu địa chỉ SOCKS5": "SOCKS5 address is required",
    "Port SOCKS5 không hợp lệ": "Invalid SOCKS5 port",
    "MAC OUI phải có dạng AA:BB:CC": "MAC OUI must use AA:BB:CC format",
    "Không xác định được OUI của hãng đã chọn": "Could not determine the selected vendor OUI",
    "Đang kết nối Agent…": "Connecting to Agent…",
    "Đang làm mới…": "Refreshing…",
    "Đang kiểm tra cổng ra Internet…": "Checking Internet gateway…",
    "Đang đổi SOCKS…": "Changing SOCKS…",
    "Đang dry-run trước khi apply…": "Running dry-run before apply…",
    "Đang đọc backup…": "Loading backups…",
    "Đang tạo backup…": "Creating backup…",
    "Đang rollback…": "Rolling back…",
    "Dry-run thất bại": "Dry-run failed",
    "Apply thất bại": "Apply failed",
    "isolate và webrtc phải là 0 hoặc 1": "isolate and webrtc must be 0 or 1",
    "isolate và webrtc phải là boolean": "isolate and webrtc must be boolean values",
    "Các trường văn bản phải là chuỗi": "Text fields must be strings",
    "Đã đạt giới hạn 200 SSID": "The 200-SSID limit has been reached",
    "Bỏ qua": "Skipped",
    'Router đang chạy bản mới hơn gói cài, hãy dùng console mới hơn': 'The router runs a newer build than this package; use a newer console',
    'Nâng cấp agent': 'Upgrade the agent',
    'Đang nâng cấp agent…': 'Upgrading the agent…',
    'Agent trên router là v{agent}, mới hơn console v{app}. Hãy dùng bản console mới hơn; console cũ chỉ được phép xem, mọi thao tác thay đổi bị khoá.': 'The router runs agent v{agent}, newer than console v{app}. Use a newer console; this one is read-only and every change is blocked.',
    'Agent trên router là v{agent}, cũ hơn console v{app}.': 'The router runs agent v{agent}, older than console v{app}.',
    'Nâng cấp agent lên v{app} ngay bây giờ? Cấu hình wifi-socks.conf và settings.sh trên router được giữ nguyên, router tự backup trước khi cập nhật.': 'Upgrade the agent to v{app} now? The router keeps its wifi-socks.conf and settings.sh, and backs itself up before updating.',
    'Agent đã ở v{agent}; console này không có bản mới hơn để đẩy lên.': 'The agent is already at v{agent}; this console has nothing newer to push.',
    'Đã nâng cấp agent: {old} → {new}': 'Agent upgraded: {old} → {new}',
    'Console v{app} cũ hơn agent v{agent} — hãy cập nhật console trước khi thay đổi router.': 'Console v{app} is older than agent v{agent} — update the console before changing the router.',
    'Agent vẫn chạy version cũ, hãy chạy lại và tick “Cài lại agent dù đã có”': 'The agent still runs the old version; run again with “Reinstall the agent even if it is present”',
    'So khớp agent đã cài': 'Compare the installed agent',
    'Kiểm tra hiện trạng router': 'Check what the router already has',
    'Đã có': 'Present',
    'Chưa có': 'Missing',
    'Mã nguồn trên router': 'Code on the router',
    'Cấu hình wifi-socks.conf': 'wifi-socks.conf configuration',
    'Gói phụ thuộc (sing-box)': 'Dependencies (sing-box)',
    'Agent CGI': 'Agent CGI',
    'Token agent': 'Agent token',
    'sing-box đang chạy': 'sing-box running',
    'Ghi đè cấu hình đã có trên router': 'Overwrite the configuration already on the router',
    'Cài lại agent dù đã có': 'Reinstall the agent even if it is present',
    'Đang kiểm tra router…': 'Checking the router…',
    'Chưa kiểm tra được router': 'The router has not been checked yet',
    # Post-flash provisioning
    'Thiếu địa chỉ router': 'Router address is required',
    'Thiếu tài khoản SSH': 'SSH account is required',
    'Port SSH không hợp lệ': 'Invalid SSH port',
    'Thư mục trên router phải là đường dẫn tuyệt đối': 'The router directory must be an absolute path',
    'Không thấy SSH key': 'SSH key not found',
    'Chưa chọn mã nguồn hoặc gói cập nhật': 'Select the source folder or the update package',
    'Không thấy mã nguồn hoặc gói cập nhật': 'Source folder or update package not found',
    'Thư mục mã nguồn không hợp lệ (thiếu scripts/ hoặc agent/)': 'Invalid source folder (scripts/ or agent/ is missing)',
    'Không thấy file wifi-socks.conf đã chọn': 'The selected wifi-socks.conf file was not found',
    'Không thấy file settings.sh đã chọn': 'The selected settings.sh file was not found',
    'Không đọc được token agent trên router': 'Could not read the agent token on the router',
    'Agent chưa trả lời đúng': 'The agent did not answer correctly',
    'Đã dừng theo yêu cầu': 'Stopped on request',
    'quá thời gian chờ': 'timed out',
    'Kiểm tra kết nối SSH': 'Check the SSH connection',
    'Đẩy mã nguồn lên router': 'Push the code to the router',
    'Cài gói phụ thuộc': 'Install dependencies',
    'Đẩy cấu hình wifi-socks.conf': 'Push the wifi-socks.conf configuration',
    'Chạy preflight và dry-run': 'Run preflight and dry-run',
    'Chạy apply.sh khởi tạo': 'Run the initial apply.sh',
    'Cài / cập nhật agent': 'Install / update the agent',
    'Lấy token agent': 'Fetch the agent token',
    'Kiểm tra agent API': 'Check the agent API',
    'Đóng gói mã nguồn': 'Package the code',
    'Đẩy mã nguồn': 'Upload the code',
    'Giải nén mã nguồn': 'Extract the code',
    'Đẩy wifi-socks.conf': 'Upload wifi-socks.conf',
    'Đẩy settings.sh': 'Upload settings.sh',
    'Đặt quyền cấu hình': 'Set configuration permissions',
    'Chạy preflight': 'Run preflight',
    'Dry-run apply': 'Dry-run apply',
    'Chạy apply.sh': 'Run apply.sh',
    'Cài agent': 'Install the agent',
    'Đọc token agent': 'Read the agent token',
    'Cài đặt router sau khi flash': 'Router setup after flashing',
    'CÀI ĐẶT SAU KHI FLASH LẠI ROUTER': 'POST-FLASH ROUTER SETUP',
    'Đẩy mã nguồn, cài phụ thuộc, đẩy cấu hình, chạy script khởi tạo, cài agent rồi lấy token.': 'Push the code, install dependencies, push the configuration, run the initial scripts, install the agent, then fetch the token.',
    'Chưa chạy bước nào': 'No step has run yet',
    'Tài khoản SSH': 'SSH account',
    'Port SSH': 'SSH port',
    'Mật khẩu SSH': 'SSH password',
    'SSH key (tuỳ chọn)': 'SSH key (optional)',
    'Thư mục trên router': 'Router directory',
    'Mã nguồn hoặc gói .tar.gz': 'Source folder or .tar.gz package',
    'settings.sh (tuỳ chọn)': 'settings.sh (optional)',
    'Chạy apply.sh sau khi đẩy cấu hình': 'Run apply.sh after pushing the configuration',
    'Bắt đầu cài đặt': 'Start setup',
    'Kiểm tra tình trạng': 'Check status',
    'Dừng': 'Stop',
    'Đóng': 'Close',
    'Bước': 'Step',
    'Chọn gói cập nhật': 'Select the update package',
    'Chọn thư mục mã nguồn': 'Select the source folder',
    'Chọn file': 'Select a file',
    'Chờ': 'Pending',
    'Đang chạy': 'Running',
    'Xong': 'Done',
    'Cài đặt chưa hoàn tất': 'Setup did not complete',
    'Cài đặt chưa hoàn tất — hãy xử lý bước lỗi rồi chạy lại.': 'Setup did not complete — fix the failed step and run it again.',
    'Cài đặt hoàn tất': 'Setup complete',
    'Cài đặt hoàn tất — đã lấy token và mở màn hình điều khiển.': 'Setup complete — the token was fetched and the control screens are open.',
    'Đang cài đặt — vẫn đóng cửa sổ?': 'Setup is running — close the window anyway?',
    'Agent trả lời OK với token hiện tại': 'The agent answers OK with the current token',
    'Agent đang chạy nhưng token sai hoặc thiếu': 'The agent is running but the token is wrong or missing',
    'Router trả lời nhưng chưa cài agent': 'The router answers but the agent is not installed',
    'Không liên lạc được với router': 'The router cannot be reached',
    'Chưa cấu hình router — hãy chạy cài đặt sau khi flash': 'Router not configured — run the post-flash setup',
    'CHƯA CẤU HÌNH ROUTER': 'ROUTER NOT CONFIGURED',
    'Router vừa flash lại chưa có agent hoặc token. Chạy cài đặt để đẩy mã nguồn, cấu hình, script khởi tạo và lấy token.': 'A freshly flashed router has no agent and no token. Run the setup to push the code, the configuration, and the initial scripts, then fetch the token.',
    'Cài đặt sau khi flash…': 'Post-flash setup…',
    'Đang kiểm tra tình trạng router…': 'Checking the router status…',
}


def translate(text: str, language: str = "en", **values) -> str:
    translated = EN_TRANSLATIONS.get(text, text) if language == "en" else text
    if language == "en" and translated == text:
        dynamic_prefixes = (
            ("Dòng cấu hình cần 10 hoặc 11 cột: ", "Configuration row must have 10 or 11 columns: "),
            ("Không kết nối được ", "Could not connect to "),
            ("Thiếu công cụ ", "Missing local tool "),
        )
        for source, target in dynamic_prefixes:
            if text.startswith(source):
                translated = target + text[len(source):]
                break
        if translated == text and ": " in text:
            # Provisioning errors read "<step>: <detail>"; translate both parts.
            head, _separator, tail = text.partition(": ")
            head_en = EN_TRANSLATIONS.get(head)
            if head_en:
                translated = f"{head_en}: {translate(tail, language)}"
    return translated.format(**values) if values else translated


def source_text(text: str) -> str:
    for source, english in EN_TRANSLATIONS.items():
        if text == english:
            return source
    return text


def localize_widget_tree(widget, language: str) -> None:
    """Translate static Tk/ttk labels, tabs, headings, and combobox values."""
    try:
        current = widget.cget("text")
        if isinstance(current, str) and current:
            widget.configure(text=translate(current, language))
    except (tk.TclError, AttributeError):
        pass
    if isinstance(widget, ttk.Notebook):
        for tab_id in widget.tabs():
            widget.tab(tab_id, text=translate(widget.tab(tab_id, "text"), language))
    if isinstance(widget, ttk.Treeview):
        for column in widget["columns"]:
            title = widget.heading(column, "text")
            widget.heading(column, text=translate(title, language))
    if isinstance(widget, ttk.Combobox):
        values = tuple(translate(str(value), language) for value in widget.cget("values"))
        widget.configure(values=values)
        current = widget.get()
        localized = translate(current, language)
        if localized != current:
            widget.set(localized)
    for child in widget.winfo_children():
        localize_widget_tree(child, language)

ALL_SSIDS = "Tất cả SSID"
ALL_BANDS = "Tất cả band"
ALL_PRESENCE = "Tất cả kết nối"
ALL_STATES = "Tất cả quyền truy cập"
ALL_SIGNALS = "Tất cả tín hiệu"
ALL_TRAFFIC = "Tất cả lưu lượng"
ALL_DURATIONS = "Tất cả thời gian"
PRESENCE_FILTERS = (ALL_PRESENCE, "Online", "Offline")
CLIENT_STATES = (ALL_STATES, "Đang cấm", "Không cấm")
BAND_FILTERS = (ALL_BANDS, "2.4 GHz", "5 GHz")
SIGNAL_FILTERS = (
    ALL_SIGNALS,
    "Rất tốt (≥ -60 dBm)",
    "Tốt (-70 đến -61 dBm)",
    "Yếu (-80 đến -71 dBm)",
    "Rất yếu (< -80 dBm)",
    "Không rõ",
)
TRAFFIC_FILTERS = (
    ALL_TRAFFIC,
    "Có lưu lượng",
    "Không lưu lượng",
    "Từ 10 MB",
    "Từ 100 MB",
)
DURATION_FILTERS = (
    ALL_DURATIONS,
    "Dưới 5 phút",
    "5–60 phút",
    "Trên 1 giờ",
)

MAC_VENDORS = (
    ("Ngẫu nhiên / ẩn danh", ""),
    ("TP-Link", "50:C7:BF"),
    ("Netgear", "20:E5:2A"),
    ("ASUS", "AC:9E:17"),
    ("Xiaomi", "64:09:80"),
    ("Huawei", "00:E0:FC"),
    ("D-Link", "1C:BD:B9"),
    ("Linksys", "C0:56:27"),
    ("Tenda", "C8:3A:35"),
    ("Apple", "3C:15:C2"),
    ("Samsung", "5C:0A:5B"),
    ("Ubiquiti", "24:A4:3C"),
    ("Aruba", "00:0B:86"),
)


def vendor_label(oui: str) -> str:
    normalized = str(oui or "").upper()
    for name, item_oui in MAC_VENDORS:
        if item_oui == normalized:
            suffix = f" · {item_oui}" if item_oui else " · 02:xx local"
            return name + suffix
    return f"OUI tuỳ chỉnh · {normalized}"


def vendor_oui(label: str) -> str:
    for name, oui in MAC_VENDORS:
        if label in (vendor_label(oui), translate(vendor_label(oui), "en")):
            return oui
    match = re.search(r"([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){2})$", label)
    if match:
        return match.group(1).upper()
    raise ValueError("Không xác định được OUI của hãng đã chọn")


def vendor_choices(current_oui=""):
    choices = [vendor_label(oui) for _name, oui in MAC_VENDORS]
    current = vendor_label(current_oui)
    if current not in choices:
        choices.append(current)
    return tuple(choices)


class AgentError(RuntimeError):
    pass


class DATA_BLOB(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_byte))]


def _dpapi_protect(value: str) -> str:
    if os.name != "nt":
        raise RuntimeError("DPAPI chỉ có trên Windows")
    raw = value.encode("utf-8")
    buf = ctypes.create_string_buffer(raw)
    source = DATA_BLOB(len(raw), ctypes.cast(buf, ctypes.POINTER(ctypes.c_byte)))
    target = DATA_BLOB()
    crypt32 = ctypes.windll.crypt32
    crypt32.CryptProtectData.argtypes = [
        ctypes.POINTER(DATA_BLOB), wintypes.LPCWSTR, ctypes.c_void_p,
        ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD,
        ctypes.POINTER(DATA_BLOB),
    ]
    crypt32.CryptProtectData.restype = wintypes.BOOL
    if not crypt32.CryptProtectData(
        ctypes.byref(source), APP_NAME, None, None, None, 1, ctypes.byref(target)
    ):
        raise ctypes.WinError()
    try:
        encrypted = ctypes.string_at(target.pbData, target.cbData)
        return base64.b64encode(encrypted).decode("ascii")
    finally:
        ctypes.windll.kernel32.LocalFree(target.pbData)


def _dpapi_unprotect(value: str) -> str:
    if os.name != "nt":
        raise RuntimeError("DPAPI chỉ có trên Windows")
    encrypted = base64.b64decode(value)
    buf = ctypes.create_string_buffer(encrypted)
    source = DATA_BLOB(len(encrypted), ctypes.cast(buf, ctypes.POINTER(ctypes.c_byte)))
    target = DATA_BLOB()
    crypt32 = ctypes.windll.crypt32
    crypt32.CryptUnprotectData.argtypes = [
        ctypes.POINTER(DATA_BLOB), ctypes.POINTER(wintypes.LPWSTR), ctypes.c_void_p,
        ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD,
        ctypes.POINTER(DATA_BLOB),
    ]
    crypt32.CryptUnprotectData.restype = wintypes.BOOL
    if not crypt32.CryptUnprotectData(
        ctypes.byref(source), None, None, None, None, 1, ctypes.byref(target)
    ):
        raise ctypes.WinError()
    try:
        return ctypes.string_at(target.pbData, target.cbData).decode("utf-8")
    finally:
        ctypes.windll.kernel32.LocalFree(target.pbData)


def _read_config_payload() -> dict:
    if not CONFIG_FILE.exists():
        return {}
    try:
        payload = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        return payload if isinstance(payload, dict) else {}
    except Exception:
        return {}


def _write_config_payload(payload: dict) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    if os.name != "nt":
        os.chmod(CONFIG_DIR, 0o700)
    temp = CONFIG_FILE.with_suffix(".tmp")
    temp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    temp.replace(CONFIG_FILE)
    if os.name != "nt":
        os.chmod(CONFIG_FILE, 0o600)


def save_connection(base_url: str, token: str) -> None:
    payload = _read_config_payload()
    payload.pop("token_dpapi", None)
    payload.pop("token_plain", None)
    # DPAPI on Windows; on Linux/macOS the config file itself is chmod 600.
    try:
        secret = {"token_dpapi": _dpapi_protect(token.strip())}
    except Exception:
        secret = {"token_plain": token.strip()}
    payload.update({"base_url": base_url.strip().rstrip("/"), **secret})
    payload.setdefault("language", "en")
    payload.setdefault("theme", "dark")
    _write_config_payload(payload)


def load_connection() -> tuple[str, str]:
    payload = _read_config_payload()
    if not payload:
        return DEFAULT_BASE, ""
    try:
        sealed = str(payload.get("token_dpapi") or "")
        token = _dpapi_unprotect(sealed) if sealed else str(payload.get("token_plain") or "")
        return (str(payload.get("base_url") or DEFAULT_BASE).rstrip("/"), token)
    except Exception:
        return DEFAULT_BASE, ""


def load_preferences() -> tuple[str, str]:
    payload = _read_config_payload()
    language = str(payload.get("language") or "en")
    theme = str(payload.get("theme") or "dark")
    return (language if language in ("en", "vi") else "en",
            theme if theme in PALETTES else "dark")


def save_preferences(language: str, theme: str) -> None:
    payload = _read_config_payload()
    payload["language"] = language if language in ("en", "vi") else "en"
    payload["theme"] = theme if theme in PALETTES else "dark"
    _write_config_payload(payload)


def parse_version(value) -> tuple | None:
    """`"0.4.0"` -> `(0, 4, 0)`; anything else -> None."""
    match = re.fullmatch(r"\s*([0-9]+)\.([0-9]+)\.([0-9]+)\s*", str(value or ""))
    return tuple(int(part) for part in match.groups()) if match else None


def compare_versions(left, right) -> int | None:
    """-1 if left is older, 0 if equal, 1 if newer, None if either is unusable."""
    first, second = parse_version(left), parse_version(right)
    if first is None or second is None:
        return None
    return (first > second) - (first < second)


def clean_agent_version(meta) -> str:
    """Return the agent's semver from status meta, or "" for dirty payloads."""
    value = meta.get("version") if isinstance(meta, dict) else None
    if isinstance(value, str) and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
        return value
    return ""


def provision_from_environment() -> bool:
    token = os.environ.get("SBPROXY_TOKEN", "").strip()
    if not token:
        return False
    base_url = os.environ.get("SBPROXY_BASE", DEFAULT_BASE).strip().rstrip("/")
    save_connection(base_url, token)
    os.environ.pop("SBPROXY_TOKEN", None)
    return True


# --------------------------------------------------------------------------
# Post-flash provisioning over SSH
#
# After the router is re-flashed nothing of sbproxy survives: no code, no
# agent, no token. These helpers drive the whole bring-up sequence (push code,
# install dependencies, push configuration, run the initial scripts, install
# the agent, read the token back) from the desktop console so the operator
# never has to open an SSH session by hand. Every step reports progress to the
# UI, and the fetched token is stored exactly like a manually typed one.
# --------------------------------------------------------------------------

SSH_CONNECT_TIMEOUT = 12
REMOTE_DIR_DEFAULT = "/root/sbproxy"
REMOTE_TOKEN_FILE = "/etc/sbproxy/token"
# Same router-side file list as pc/update.sh; pc/ may hold local secrets.
PAYLOAD_ENTRIES = ("README.md", "VERSION", "agent", "config", "console", "docs", "etc", "scripts")
KNOWN_HOSTS_FILE = CONFIG_DIR / "known_hosts"

STEP_PENDING = "pending"
STEP_RUNNING = "running"
STEP_OK = "ok"
STEP_SKIPPED = "skipped"
STEP_FAILED = "failed"


class ProvisionError(RuntimeError):
    """A provisioning step failed; the message is already operator-readable."""


def askpass_helper() -> str:
    """Path to a program ssh can call for the router password.

    The frozen executable answers this itself (see main()); running from source
    needs a tiny generated script instead because SSH_ASKPASS takes no
    arguments.
    """
    if getattr(sys, "frozen", False):
        return sys.executable
    ensure_app_home()
    if os.name == "nt":
        helper = RUNTIME_DIR / "askpass.cmd"
        helper.write_text("@echo off\r\necho %SBPROXY_SSH_PASSWORD%\r\n", encoding="utf-8")
    else:
        helper = RUNTIME_DIR / "askpass.sh"
        helper.write_text("#!/bin/sh\nprintf '%s\\n' \"$SBPROXY_SSH_PASSWORD\"\n", encoding="utf-8")
        os.chmod(helper, 0o700)
    return str(helper)


def write_stdout(text: str) -> bool:
    """Write to whatever stdout this build has.

    A windowed PyInstaller build has no `sys.stdout`, so the inherited pipe is
    written through the file descriptor (and the Win32 handle) instead — that
    pipe is how `ssh` reads an askpass answer.
    """
    data = text.encode("utf-8")
    try:
        os.write(1, data)
        return True
    except (OSError, ValueError, AttributeError):
        pass
    if os.name == "nt":
        try:
            handle = ctypes.windll.kernel32.GetStdHandle(-11)  # STD_OUTPUT_HANDLE
            written = wintypes.DWORD(0)
            if handle and handle != -1 and ctypes.windll.kernel32.WriteFile(
                handle, data, len(data), ctypes.byref(written), None
            ):
                return True
        except Exception:  # no console, no pipe: fall through to sys.stdout
            pass
    try:
        sys.stdout.write(text)
        sys.stdout.flush()
        return True
    except Exception:
        return False


def write_askpass_answer(password: str) -> int:
    """Hand the password to ssh; a nonzero result makes ssh fail loudly."""
    if write_stdout(f"{password}\n"):
        return 0
    log.error("askpass could not write the password to stdout")
    return 1


@dataclass
class ProvisionSettings:
    """Everything needed to reach a freshly flashed router over SSH."""

    host: str = "192.168.8.1"
    user: str = "root"
    port: int = 22
    key_path: str = ""
    password: str = ""  # session-only; never written to connection.json
    remote_dir: str = REMOTE_DIR_DEFAULT
    payload: str = ""  # repository directory or sbproxy-update-<ver>.tar.gz
    config_path: str = ""
    settings_path: str = ""
    run_apply: bool = True
    overwrite_config: bool = False
    reinstall_agent: bool = False

    def validate(self) -> None:
        if not str(self.host).strip():
            raise ValueError("Thiếu địa chỉ router")
        if not str(self.user).strip():
            raise ValueError("Thiếu tài khoản SSH")
        try:
            port = int(self.port)
        except (TypeError, ValueError):
            raise ValueError("Port SSH không hợp lệ") from None
        if not 1 <= port <= 65535:
            raise ValueError("Port SSH không hợp lệ")
        if not str(self.remote_dir).startswith("/"):
            raise ValueError("Thư mục trên router phải là đường dẫn tuyệt đối")
        if self.key_path and not Path(self.key_path).is_file():
            raise ValueError("Không thấy SSH key")
        if not self.payload:
            raise ValueError("Chưa chọn mã nguồn hoặc gói cập nhật")
        if not Path(self.payload).exists():
            raise ValueError("Không thấy mã nguồn hoặc gói cập nhật")

    @property
    def target(self) -> str:
        return f"{str(self.user).strip()}@{str(self.host).strip()}"

    @property
    def base_url(self) -> str:
        return f"http://{str(self.host).strip()}"

    def _common_options(self) -> list[str]:
        options = [
            "-o", f"ConnectTimeout={SSH_CONNECT_TIMEOUT}",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", f"UserKnownHostsFile={KNOWN_HOSTS_FILE}",
        ]
        if self.key_path:
            options += ["-i", self.key_path]
        if self.password:
            # An askpass helper answers the prompt; one attempt, then fail.
            options += ["-o", "NumberOfPasswordPrompts=1",
                        "-o", "PreferredAuthentications=publickey,password,keyboard-interactive"]
        else:
            # No password on hand: never hang the UI on an interactive prompt.
            options += ["-o", "BatchMode=yes"]
        return options

    def ssh_command(self, remote_command: str) -> list[str]:
        return ["ssh", "-p", str(int(self.port))] + self._common_options() + [self.target, remote_command]

    def scp_command(self, local: str, remote: str) -> list[str]:
        # OpenWrt images usually ship without sftp-server, so force legacy SCP.
        return (["scp", "-O", "-P", str(int(self.port))] + self._common_options()
                + [local, f"{self.target}:{remote}"])

    def to_payload(self) -> dict:
        """Persistable form — the password is deliberately left out."""
        return {
            "host": str(self.host).strip(),
            "user": str(self.user).strip(),
            "port": int(self.port),
            "key_path": self.key_path,
            "remote_dir": self.remote_dir,
            # The bundle is unpacked to a new temp path on every launch, so a
            # bundled payload is re-resolved instead of being remembered.
            "payload": "" if is_bundled_payload(self.payload) else self.payload,
            "config_path": self.config_path,
            "settings_path": self.settings_path,
            "run_apply": bool(self.run_apply),
            "overwrite_config": bool(self.overwrite_config),
            "reinstall_agent": bool(self.reinstall_agent),
        }


def repo_root_candidate() -> str:
    """Repository directory when the console runs from a source checkout."""
    root = Path(__file__).resolve().parents[2]
    if (root / "scripts" / "apply.sh").is_file() and (root / "VERSION").is_file():
        return str(root)
    return ""


def bundled_payload() -> str:
    """Router package shipped inside the executable, if this is a frozen build.

    build.ps1/build.sh embed `sbproxy-update-<version>.tar.gz` under `payload/`
    so a single .exe can provision a freshly flashed router with no checkout.
    """
    root = getattr(sys, "_MEIPASS", "")
    if not root:
        return ""
    try:
        packages = sorted((Path(root) / "payload").glob("sbproxy-update-*.tar.gz"))
    except OSError:
        return ""
    return str(packages[-1]) if packages else ""


def is_bundled_payload(path) -> bool:
    """True for a path inside the unpacked bundle, which changes every launch."""
    root = getattr(sys, "_MEIPASS", "")
    if not root or not path:
        return False
    try:
        return Path(path).resolve().is_relative_to(Path(root).resolve())
    except (OSError, ValueError):
        return False


def find_payload() -> str:
    """Locate router-side code: env override, bundle, checkout, or a package."""
    override = os.environ.get("SBPROXY_PAYLOAD", "").strip()
    if override and Path(override).exists():
        return override
    bundled = bundled_payload()
    if bundled:
        return bundled
    repo = repo_root_candidate()
    if repo:
        return repo
    packages = []
    for folder in (frozen_dir(), frozen_dir() / "dist", APP_HOME):
        try:
            packages.extend(item for item in folder.glob("sbproxy-update-*.tar.gz") if item.is_file())
        except OSError:
            continue
    if packages:
        return str(max(packages, key=lambda item: item.stat().st_mtime))
    return ""


def build_update_package(payload: str = "") -> Path:
    """Return a router package to upload: the payload itself, or a fresh tarball.

    A shipped executable carries `sbproxy-update-<version>.tar.gz`; a source
    checkout is packaged on the fly with the same file list.
    """
    source = Path(payload or find_payload() or "")
    if not str(source) or not source.exists():
        raise ProvisionError("Chưa chọn mã nguồn hoặc gói cập nhật")
    if source.is_file():
        return source
    entries = [name for name in PAYLOAD_ENTRIES if (source / name).exists()]
    if "scripts" not in entries or "agent" not in entries:
        raise ProvisionError("Thư mục mã nguồn không hợp lệ (thiếu scripts/ hoặc agent/)")
    ensure_app_home()
    package = CACHE_DIR / f"sbproxy-update-{payload_version(source) or APP_VERSION}.tar.gz"
    completed = subprocess.run(  # noqa: S603 - fixed argv, never a shell
        ["tar", "-czf", str(package), "-C", str(source), "--exclude=node_modules",
         "--exclude=__pycache__", "--exclude=dist", "--exclude=build", *entries],
        capture_output=True, text=True, timeout=300, errors="replace",
    )
    if completed.returncode != 0:
        raise ProvisionError(f"Đóng gói mã nguồn: {(completed.stderr or '').strip() or 'tar lỗi'}")
    return package


def load_provision_settings() -> ProvisionSettings:
    stored = _read_config_payload().get("provision")
    settings = ProvisionSettings()
    if isinstance(stored, dict):
        settings.host = str(stored.get("host") or settings.host)
        settings.user = str(stored.get("user") or settings.user)
        settings.key_path = str(stored.get("key_path") or "")
        settings.remote_dir = str(stored.get("remote_dir") or REMOTE_DIR_DEFAULT)
        settings.payload = str(stored.get("payload") or "")
        settings.config_path = str(stored.get("config_path") or "")
        settings.settings_path = str(stored.get("settings_path") or "")
        settings.run_apply = bool(stored.get("run_apply", True))
        settings.overwrite_config = bool(stored.get("overwrite_config", False))
        settings.reinstall_agent = bool(stored.get("reinstall_agent", False))
        try:
            settings.port = int(stored.get("port") or 22)
        except (TypeError, ValueError):
            settings.port = 22
    # A remembered checkout can disappear (or belong to another machine), so
    # fall back to whatever this install actually carries.
    if not settings.payload or not Path(settings.payload).exists():
        settings.payload = find_payload()
    if not settings.config_path and settings.payload and Path(settings.payload).is_dir():
        candidate = Path(settings.payload) / "config" / "wifi-socks.conf"
        if candidate.is_file():
            settings.config_path = str(candidate)
    return settings


def save_provision_settings(settings: ProvisionSettings) -> None:
    payload = _read_config_payload()
    payload["provision"] = settings.to_payload()
    _write_config_payload(payload)


def parse_router_token(text: str) -> str:
    """Accept only a token shaped like the one install-agent.sh generates."""
    lines = [line.strip() for line in str(text or "").splitlines() if line.strip()]
    token = lines[0] if lines else ""
    if not re.fullmatch(r"[A-Za-z0-9._-]{16,128}", token):
        raise ProvisionError("Không đọc được token agent trên router")
    return token


def probe_router_state(base_url: str, token: str, timeout: int = 8) -> str:
    """Classify the router: ok, unauthorized, absent, or unreachable."""
    url = f"{base_url.rstrip('/')}/cgi-bin/sbproxy?action=status"
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        with urlopen(Request(url, headers=headers), timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8", "replace"))
        return "ok" if isinstance(payload, dict) and payload.get("ok") else "unauthorized"
    except HTTPError as exc:
        if exc.code in (401, 403):
            return "unauthorized"
        if exc.code == 404:
            return "absent"
        return "unreachable"
    except (URLError, TimeoutError, ValueError, OSError):
        return "unreachable"


def read_agent_version(base_url: str, token: str, timeout: int = 8) -> str:
    """Agent semver from `?action=status`, or "" when it cannot be read."""
    url = f"{base_url.rstrip('/')}/cgi-bin/sbproxy?action=status"
    headers = {"Accept": "application/json", "Authorization": f"Bearer {token}"}
    try:
        with urlopen(Request(url, headers=headers), timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8", "replace"))
    except (HTTPError, URLError, TimeoutError, ValueError, OSError):
        return ""
    meta = payload.get("meta") if isinstance(payload, dict) else None
    return clean_agent_version(meta)


def payload_version(path) -> str:
    """Version of a router package or checkout, from its name or VERSION file."""
    candidate = Path(path) if path else None
    if not candidate or not candidate.exists():
        return ""
    if candidate.is_dir():
        try:
            return (candidate / "VERSION").read_text(encoding="utf-8").strip()
        except OSError:
            return ""
    match = re.search(r"sbproxy-update-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz$", candidate.name)
    return match.group(1) if match else ""


ROUTER_INVENTORY_KEYS = ("code", "conf", "deps", "agent", "token", "running")

ROUTER_INVENTORY_LABELS = {
    "code": "Mã nguồn trên router",
    "conf": "Cấu hình wifi-socks.conf",
    "deps": "Gói phụ thuộc (sing-box)",
    "agent": "Agent CGI",
    "token": "Token agent",
    "running": "sing-box đang chạy",
}


def router_inventory_command(remote_dir: str) -> str:
    """Read-only shell that reports what a router already carries."""
    yes = "echo 1 || echo 0"
    return "; ".join((
        f'echo "code=$([ -f {remote_dir}/scripts/apply.sh ] && {yes})"',
        f'echo "conf=$([ -s {remote_dir}/config/wifi-socks.conf ] && {yes})"',
        f'echo "deps=$(command -v sing-box >/dev/null 2>&1 && {yes})"',
        f'echo "agent=$([ -x /www/cgi-bin/sbproxy ] && {yes})"',
        f'echo "token=$([ -s {REMOTE_TOKEN_FILE} ] && {yes})"',
        f'echo "running=$(pgrep sing-box >/dev/null 2>&1 && {yes})"',
        f'echo "version=$(tr -d \' \\r\\n\' < {remote_dir}/VERSION 2>/dev/null)"',
        "exit 0",
    ))


def parse_router_inventory(text: str) -> dict:
    """Turn `key=1` lines into flags; anything unreported counts as absent."""
    inventory = {key: False for key in ROUTER_INVENTORY_KEYS}
    for line in str(text or "").splitlines():
        key, _separator, value = line.strip().partition("=")
        if key in inventory:
            inventory[key] = value.strip() == "1"
    return inventory


def parse_inventory_version(text: str) -> str:
    """The `version=` line of the inventory output, or "" when absent."""
    for line in str(text or "").splitlines():
        key, _separator, value = line.strip().partition("=")
        if key == "version" and parse_version(value):
            return value.strip()
    return ""


def describe_router_inventory(inventory: dict, language: str = "en") -> str:
    """One line an operator can read: what is present, what is missing."""
    present = [ROUTER_INVENTORY_LABELS[key] for key in ROUTER_INVENTORY_KEYS if inventory.get(key)]
    missing = [ROUTER_INVENTORY_LABELS[key] for key in ROUTER_INVENTORY_KEYS if not inventory.get(key)]
    parts = []
    if present:
        parts.append(translate("Đã có", language) + ": " + ", ".join(translate(item, language) for item in present))
    if missing:
        parts.append(translate("Chưa có", language) + ": " + ", ".join(translate(item, language) for item in missing))
    return " · ".join(parts)


class ProvisionRunner:
    """Drive the post-flash sequence step by step and report progress.

    `emit(index, state, detail)` fires on every state change so the UI can tick
    the checklist live; `runner` and `prober` are injectable so tests never
    shell out or touch the network.
    """

    def __init__(self, settings: ProvisionSettings, emit=None, runner=None, prober=None,
                 version_reader=None):
        self.settings = settings
        self.emit = emit or (lambda *_args: None)
        self._execute = runner or self._run_process
        self._probe = prober or probe_router_state
        self._agent_version = version_reader or read_agent_version
        self.token = ""
        self.cancelled = False
        self.inventory = {key: False for key in ROUTER_INVENTORY_KEYS}
        self.pushed_version = ""  # version of the package this run put on the router
        self.router_version = ""   # version already on the router, before the push
        self.steps = [
            ("Kiểm tra kết nối SSH", self.step_check_ssh),
            ("Kiểm tra hiện trạng router", self.step_inventory),
            ("Đẩy mã nguồn lên router", self.step_push_code),
            ("Cài gói phụ thuộc", self.step_install_deps),
            ("Đẩy cấu hình wifi-socks.conf", self.step_push_config),
            ("Chạy preflight và dry-run", self.step_preflight),
            ("Chạy apply.sh khởi tạo", self.step_apply),
            ("Cài / cập nhật agent", self.step_install_agent),
            ("Lấy token agent", self.step_fetch_token),
            ("Kiểm tra agent API", self.step_verify_agent),
        ]

    # -- process plumbing ---------------------------------------------------

    def _environment(self) -> dict:
        env = os.environ.copy()
        if self.settings.password:
            env["SBPROXY_SSH_PASSWORD"] = self.settings.password
            env["SBPROXY_ASKPASS"] = "1"
            env["SSH_ASKPASS"] = askpass_helper()
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env.setdefault("DISPLAY", ":0")
        else:
            env.pop("SBPROXY_SSH_PASSWORD", None)
        return env

    def _run_process(self, argv, timeout=600):
        completed = subprocess.run(  # noqa: S603 - fixed argv, never a shell
            argv, capture_output=True, text=True, timeout=timeout,
            env=self._environment(), errors="replace",
        )
        return completed.returncode, completed.stdout or "", completed.stderr or ""

    def run_command(self, argv, description, timeout=600) -> str:
        if self.cancelled:
            raise ProvisionError("Đã dừng theo yêu cầu")
        log.info("provision: %s", redact(" ".join(argv)))
        try:
            code, out, err = self._execute(argv, timeout=timeout)
        except FileNotFoundError as exc:
            raise ProvisionError(f"Thiếu công cụ {argv[0]}") from exc
        except subprocess.TimeoutExpired as exc:
            raise ProvisionError(f"{description}: quá thời gian chờ") from exc
        output = (out + ("\n" + err if err.strip() else "")).strip()
        if code != 0:
            lines = output.splitlines()
            raise ProvisionError(f"{description}: {lines[-1] if lines else f'exit {code}'}")
        return output

    def ssh(self, remote_command, description, timeout=600) -> str:
        return self.run_command(self.settings.ssh_command(remote_command), description, timeout)

    def upload(self, local, remote, description) -> str:
        return self.run_command(self.settings.scp_command(str(local), remote), description, timeout=600)

    # -- steps --------------------------------------------------------------

    def step_check_ssh(self) -> str:
        board = self.ssh(
            'uname -sr; . /etc/openwrt_release 2>/dev/null && echo "$DISTRIB_DESCRIPTION"; exit 0',
            "Kiểm tra kết nối SSH", timeout=90,
        )
        return board.replace("\n", " · ") or self.settings.target

    def step_inventory(self) -> str:
        """Look before installing: reuse dependencies, config, and agent."""
        output = self.ssh(router_inventory_command(self.settings.remote_dir),
                          "Kiểm tra hiện trạng router", timeout=90)
        self.inventory = parse_router_inventory(output)
        self.router_version = parse_inventory_version(output)
        summary = describe_router_inventory(self.inventory)
        return f"v{self.router_version} · {summary}" if self.router_version else summary

    def package_payload(self, workdir: Path) -> Path:
        """Return a tarball of router-side files, building one from a checkout."""
        source = Path(self.settings.payload)
        if source.is_file():
            return source
        entries = [name for name in PAYLOAD_ENTRIES if (source / name).exists()]
        if "scripts" not in entries or "agent" not in entries:
            raise ProvisionError("Thư mục mã nguồn không hợp lệ (thiếu scripts/ hoặc agent/)")
        package = workdir / "sbproxy-payload.tar.gz"
        self.run_command(
            ["tar", "-czf", str(package), "-C", str(source), "--exclude=node_modules", *entries],
            "Đóng gói mã nguồn", timeout=300,
        )
        return package

    def step_push_code(self) -> str:
        remote = self.settings.remote_dir
        available = payload_version(self.settings.payload)
        if self.router_version and available and compare_versions(available, self.router_version) == -1:
            raise ProvisionError(
                "Router đang chạy bản mới hơn gói cài, hãy dùng console mới hơn: "
                f"{self.router_version} > {available}"
            )
        workdir = Path(tempfile.mkdtemp(prefix="sbproxy-provision-", dir=str(CACHE_DIR) if CACHE_DIR.is_dir() else None))
        try:
            package = self.package_payload(workdir)
            self.upload(package, "/tmp/sbproxy-update.tar.gz", "Đẩy mã nguồn")
            self.ssh(
                f"set -e; mkdir -p {remote}; tar xzf /tmp/sbproxy-update.tar.gz -C {remote}; "
                f"chmod +x {remote}/scripts/*.sh {remote}/agent/install-agent.sh; "
                "rm -f /tmp/sbproxy-update.tar.gz",
                "Giải nén mã nguồn", timeout=300,
            )
            self.pushed_version = payload_version(package) or payload_version(self.settings.payload)
            size = package.stat().st_size if package.is_file() else 0
            detail = f"{remote} · {human_bytes(size)}" if size else remote
            return f"{detail} · v{self.pushed_version}" if self.pushed_version else detail
        finally:
            shutil.rmtree(workdir, ignore_errors=True)

    def step_install_deps(self) -> str:
        if self.inventory.get("deps"):
            return ""  # sing-box is already installed; nothing to add
        output = self.ssh(
            f"cd {self.settings.remote_dir}; sh scripts/install-deps.sh",
            "Cài gói phụ thuộc", timeout=1200,
        )
        lines = output.splitlines()
        return lines[-1] if lines else "OK"

    def step_push_config(self) -> str:
        remote = self.settings.remote_dir
        if self.inventory.get("conf") and not self.settings.overwrite_config:
            return ""  # the router already has a configuration; keep it
        pushed = []
        if self.settings.config_path:
            if not Path(self.settings.config_path).is_file():
                raise ProvisionError("Không thấy file wifi-socks.conf đã chọn")
            self.upload(self.settings.config_path, f"{remote}/config/wifi-socks.conf", "Đẩy wifi-socks.conf")
            pushed.append("wifi-socks.conf")
        if self.settings.settings_path:
            if not Path(self.settings.settings_path).is_file():
                raise ProvisionError("Không thấy file settings.sh đã chọn")
            self.upload(self.settings.settings_path, f"{remote}/config/settings.sh", "Đẩy settings.sh")
            pushed.append("settings.sh")
        if not pushed:
            return ""
        self.ssh(f"chmod 600 {remote}/config/wifi-socks.conf 2>/dev/null; exit 0",
                 "Đặt quyền cấu hình", timeout=60)
        return " + ".join(pushed)

    def step_preflight(self) -> str:
        self.ssh(f"cd {self.settings.remote_dir}; sh scripts/preflight.sh", "Chạy preflight", timeout=600)
        self.ssh(f"cd {self.settings.remote_dir}; DRYRUN=1 sh scripts/apply.sh >/dev/null",
                 "Dry-run apply", timeout=600)
        return "preflight + dry-run OK"

    def step_apply(self) -> str:
        if not self.settings.run_apply:
            return ""
        output = self.ssh(f"cd {self.settings.remote_dir}; sh scripts/apply.sh",
                          "Chạy apply.sh", timeout=1800)
        lines = output.splitlines()
        return lines[-1] if lines else "apply OK"

    def step_install_agent(self) -> str:
        if not self.settings.reinstall_agent and self.agent_matches_pushed_code():
            return ""  # the installed agent is already this exact code
        self.ssh(f"cd {self.settings.remote_dir}; sh agent/install-agent.sh", "Cài agent", timeout=1200)
        return f"uhttpd CGI + healthd v{self.pushed_version}" if self.pushed_version else "uhttpd CGI + healthd"

    def agent_matches_pushed_code(self) -> bool:
        """True only when the deployed agent files are the ones just pushed.

        The agent is installed by copying files, so an older CGI keeps serving
        after a version bump unless it is reinstalled. Comparing the deployed
        copies with the freshly pushed sources catches that regardless of what
        any VERSION file claims.
        """
        if not (self.inventory.get("agent") and self.inventory.get("token")):
            return False
        remote = self.settings.remote_dir
        answer = self.ssh(
            "same=1; "
            f"cmp -s /www/cgi-bin/sbproxy {remote}/agent/cgi/sbproxy || same=0; "
            f"cmp -s /usr/sbin/sbproxy-healthd {remote}/agent/sbproxy-healthd || same=0; "
            f"cmp -s /www/sbproxy/index.html {remote}/console/web/control-panel.html || same=0; "
            'echo "same=$same"; exit 0',
            "So khớp agent đã cài", timeout=90,
        )
        return "same=1" in answer

    def step_fetch_token(self) -> str:
        raw = self.ssh(f"cat {REMOTE_TOKEN_FILE}", "Đọc token agent", timeout=60)
        self.token = parse_router_token(raw)
        save_connection(self.settings.base_url, self.token)
        return f"{self.settings.base_url} · token ok"

    def step_verify_agent(self) -> str:
        state = self._probe(self.settings.base_url, self.token)
        if state != "ok":
            raise ProvisionError(f"Agent chưa trả lời đúng: {ROUTER_STATE_LABELS.get(state, state)}")
        expected = self.pushed_version or APP_VERSION
        reported = self._agent_version(self.settings.base_url, self.token)
        if reported and compare_versions(reported, expected) != 0:
            # "head: detail" so translate() renders both halves in English.
            raise ProvisionError(
                f"Agent vẫn chạy version cũ, hãy chạy lại và tick “Cài lại agent dù đã có”: "
                f"{reported} ≠ {expected}"
            )
        return f"status ok · agent v{reported}" if reported else "status ok"

    # -- orchestration ------------------------------------------------------

    def cancel(self) -> None:
        self.cancelled = True

    def run(self) -> bool:
        """Execute every step in order and stop at the first failure."""
        self.settings.validate()
        for index, (label, function) in enumerate(self.steps):
            if self.cancelled:
                self.emit(index, STEP_FAILED, "Đã dừng theo yêu cầu")
                return False
            self.emit(index, STEP_RUNNING, "")
            try:
                detail = function()
            except ProvisionError as exc:
                self.emit(index, STEP_FAILED, str(exc))
                return False
            except Exception as exc:  # unexpected local failure, same UI path
                log.exception("provision step failed: %s", label)
                self.emit(index, STEP_FAILED, str(exc))
                return False
            self.emit(index, STEP_OK if detail else STEP_SKIPPED, detail or "Bỏ qua")
        return True


class AgentClient:
    def __init__(self, base_url: str, token: str, timeout: int = 30):
        self.base_url = base_url.strip().rstrip("/")
        self.token = token.strip()
        self.timeout = timeout

    def _request(self, action: str, method: str = "GET", body=None, text=False, timeout=None, query=None):
        parameters = {"action": action}
        parameters.update(query or {})
        url = f"{self.base_url}/cgi-bin/sbproxy?{urlencode(parameters)}"
        request_timeout = timeout if timeout is not None else self.timeout
        data = None
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/json"}
        if body is not None:
            if isinstance(body, bytes):
                data = body
                headers["Content-Type"] = "application/octet-stream"
            elif isinstance(body, str):
                data = body.encode("utf-8")
                headers["Content-Type"] = "text/plain; charset=utf-8"
            else:
                data = json.dumps(body).encode("utf-8")
                headers["Content-Type"] = "application/json"
        request = Request(url, data=data, headers=headers, method=method)
        started = time.monotonic()
        log.debug("agent %s %s (timeout=%ss, body=%s bytes)",
                  method, action, request_timeout, len(data) if data else 0)
        try:
            with urlopen(request, timeout=request_timeout) as response:
                raw = response.read()
        except HTTPError as exc:
            raw = exc.read()
            try:
                detail = json.loads(raw.decode("utf-8")).get("error")
            except Exception:
                detail = raw.decode("utf-8", "replace") or str(exc)
            log.warning("agent %s %s -> HTTP %s: %s", method, action, exc.code, redact(detail))
            raise AgentError(f"HTTP {exc.code}: {detail}") from exc
        except (URLError, TimeoutError, OSError) as exc:
            log.warning("agent %s %s -> transport error: %s", method, action, redact(exc))
            raise AgentError(f"Không kết nối được {self.base_url} trong {request_timeout}s: {exc}") from exc
        log.info("agent %s %s -> %s bytes in %.0f ms",
                 method, action, len(raw), (time.monotonic() - started) * 1000)

        decoded = raw.decode("utf-8", "replace")
        if text:
            return decoded
        try:
            payload = json.loads(decoded)
        except json.JSONDecodeError as exc:
            raise AgentError("Agent trả dữ liệu không phải JSON") from exc
        if not isinstance(payload, dict):
            raise AgentError("Agent trả JSON không phải object")
        if payload.get("ok") is False:
            raise AgentError(payload.get("error") or payload.get("log") or "Agent báo lỗi")
        return payload

    def status(self):
        return self._request("status", timeout=15)

    def get_conf(self) -> str:
        return self._request("get_conf", text=True, timeout=20)

    def dryrun_conf(self, content: str):
        return self._request("dryrun_conf", "POST", content, timeout=60)

    def save_conf(self, content: str):
        return self._request("save_conf", "POST", content, timeout=45)

    def apply(self):
        return self._request("apply", "POST", {}, timeout=120)

    def set_sock(self, record: "WifiRecord"):
        return self._request("set_sock", "POST", {
            "idx": record.idx, "host": record.host, "port": record.port,
            "user": record.user, "pass": record.socks_password,
        }, timeout=60)

    def clients(self):
        return self._request("clients", timeout=30)

    def gateway(self):
        return self._request("gateway", timeout=15)

    def client_action(self, action: str, idx: int, mac: str):
        return self._request(action, "POST", {"idx": idx, "mac": mac}, timeout=45)

    def rotate_mac(self, idx: int, oui: str | None = None):
        body = {"idx": idx}
        if oui is not None:
            body["oui"] = oui
        return self._request("rotate_mac", "POST", body, timeout=120)

    def backups(self):
        return self._request("backups", timeout=30)

    def backup(self, label="native"):
        return self._request("backup", "POST", {"label": label}, timeout=120)

    def update(self, package: bytes, force: bool = False):
        """Upload a router package; self-update.sh keeps the live configuration."""
        return self._request(
            "update", "POST", body=package, timeout=300,
            query={"force": "1"} if force else None,
        )

    def rollback(self, name: str):
        return self._request("rollback", "POST", {"name": name}, timeout=180)


@dataclass
class WifiRecord:
    name: str
    band: str
    idx: int
    wifi_password: str
    host: str
    port: int
    user: str = ""
    socks_password: str = ""
    isolate: bool = True
    webrtc: bool = True
    mac_oui: str = ""

    @classmethod
    def from_row(cls, row: str) -> "WifiRecord":
        columns = row.rstrip("\r\n").split("|")
        if len(columns) not in (10, 11):
            raise ValueError(f"Dòng cấu hình cần 10 hoặc 11 cột: {row}")
        if len(columns) == 10:
            columns.append("")
        if columns[8].strip() not in ("0", "1") or columns[9].strip() not in ("0", "1"):
            raise ValueError("isolate và webrtc phải là 0 hoặc 1")
        record = cls(
            name=columns[0], band=columns[1].strip(), idx=int(columns[2].strip()),
            wifi_password=columns[3], host=columns[4].strip(),
            port=int(columns[5].strip()), user=columns[6], socks_password=columns[7],
            isolate=columns[8].strip() == "1", webrtc=columns[9].strip() == "1",
            mac_oui=columns[10].strip(),
        )
        record.validate()
        return record

    def validate(self) -> None:
        values = [self.name, self.wifi_password, self.host, self.user, self.socks_password]
        if any(not isinstance(value, str) for value in values):
            raise ValueError("Các trường văn bản phải là chuỗi")
        if any("|" in value or any(unicodedata.category(char) == "Cc" for char in value) for value in values):
            raise ValueError("Các trường không được chứa | hoặc ký tự điều khiển")
        try:
            name_size = len(self.name.encode("utf-8"))
            wifi_password_size = len(self.wifi_password.encode("utf-8"))
            user_size = len(self.user.encode("utf-8"))
            socks_password_size = len(self.socks_password.encode("utf-8"))
        except UnicodeEncodeError as exc:
            raise ValueError("Các trường văn bản chứa Unicode không hợp lệ") from exc
        if not 1 <= name_size <= 32:
            raise ValueError("SSID phải dài 1–32 byte UTF-8")
        if self.band not in ("2g", "5g"):
            raise ValueError("Băng tần phải là 2g hoặc 5g")
        if isinstance(self.idx, bool) or not isinstance(self.idx, int) or not 1 <= self.idx <= 200:
            raise ValueError("IDX phải từ 1 đến 200")
        if not 8 <= wifi_password_size <= 63:
            raise ValueError("Mật khẩu Wi‑Fi phải dài 8–63 byte UTF-8")
        if not self.host.strip():
            raise ValueError("Thiếu địa chỉ SOCKS5")
        if len(self.host) > 253 or not re.fullmatch(r"[A-Za-z0-9._:-]+", self.host):
            raise ValueError("Địa chỉ SOCKS5 không hợp lệ")
        if user_size > 255 or socks_password_size > 255:
            raise ValueError("Thông tin xác thực SOCKS5 quá dài")
        if isinstance(self.port, bool) or not isinstance(self.port, int) or not 1 <= self.port <= 65535:
            raise ValueError("Port SOCKS5 không hợp lệ")
        if not isinstance(self.isolate, bool) or not isinstance(self.webrtc, bool):
            raise ValueError("isolate và webrtc phải là boolean")
        if not isinstance(self.mac_oui, str):
            raise ValueError("MAC OUI phải có dạng AA:BB:CC")
        if self.mac_oui and not re.fullmatch(r"[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){2}", self.mac_oui):
            raise ValueError("MAC OUI phải có dạng AA:BB:CC")

    def to_row(self) -> str:
        self.validate()
        return "|".join([
            self.name, self.band, str(self.idx), self.wifi_password, self.host,
            str(self.port), self.user, self.socks_password,
            "1" if self.isolate else "0", "1" if self.webrtc else "0",
            self.mac_oui.upper(),
        ])


def parse_conf(content: str) -> list[WifiRecord]:
    records = []
    indexes = set()
    for line in content.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        record = WifiRecord.from_row(line)
        if record.idx in indexes:
            raise ValueError("IDX Wi‑Fi bị trùng")
        indexes.add(record.idx)
        records.append(record)
    return sorted(records, key=lambda item: item.idx)


def render_conf(records: list[WifiRecord]) -> str:
    indexes = [record.idx for record in records]
    if len(indexes) != len(set(indexes)):
        raise ValueError("IDX Wi‑Fi bị trùng")
    rows = [record.to_row() for record in sorted(records, key=lambda item: item.idx)]
    header = (
        "# wifi-socks.conf — generated by sbproxy Console Native\n"
        "# name|band|idx|wifi_key|sock_host|sock_port|sock_user|sock_pass|isolate|webrtc|mac_oui\n"
    )
    return header + "\n".join(rows) + ("\n" if rows else "")


def _finite_float(value, default=0.0) -> float:
    try:
        number = float(value or 0)
    except (TypeError, ValueError, OverflowError):
        return float(default)
    return number if math.isfinite(number) else float(default)


def _nonnegative_int(value) -> int:
    try:
        return max(0, int(value or 0))
    except (TypeError, ValueError, OverflowError):
        return 0


def normalize_clients(value) -> list[dict]:
    """Keep only object rows from an untrusted Agent clients payload."""
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, dict)]


def normalize_health_probes(value) -> dict:
    """Extract only object probe entries from an untrusted status payload."""
    if not isinstance(value, dict):
        return {}
    health = value.get("health")
    if not isinstance(health, dict) or not isinstance(health.get("probes"), dict):
        return {}
    return {
        str(key): probe
        for key, probe in health["probes"].items()
        if isinstance(probe, dict)
    }


def normalize_backup_names(value) -> list[str]:
    if not isinstance(value, list):
        return []
    return [
        name for name in value
        if isinstance(name, str)
        and len(name) <= 128
        and re.fullmatch(r"[A-Za-z0-9._-]+", name)
        and ".." not in name
    ]


def human_bytes(value) -> str:
    size = max(0.0, _finite_float(value))
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return "0 B"


def human_time(seconds) -> str:
    seconds = _nonnegative_int(seconds)
    hours, seconds = divmod(seconds, 3600)
    minutes, seconds = divmod(seconds, 60)
    return f"{hours}h {minutes}m" if hours else f"{minutes}m {seconds}s"


def filter_clients(
    clients,
    ssid=ALL_SSIDS,
    query="",
    state=ALL_STATES,
    signal=ALL_SIGNALS,
    band=ALL_BANDS,
    presence=ALL_PRESENCE,
    traffic=ALL_TRAFFIC,
    duration=ALL_DURATIONS,
):
    """Return client rows matching all active UI filters."""
    query = query.strip().casefold()
    result = []
    for item in normalize_clients(clients):
        if ssid not in (ALL_SSIDS, EN_TRANSLATIONS[ALL_SSIDS]) and str(item.get("ssid") or "") != ssid:
            continue
        item_band = str(item.get("band") or "").casefold()
        if band == "2.4 GHz" and item_band != "2g":
            continue
        if band == "5 GHz" and item_band != "5g":
            continue
        searchable = " ".join(
            str(item.get(key) or "")
            for key in ("ssid", "band", "ip", "host", "mac", "ifname")
        ).casefold()
        if query and query not in searchable:
            continue
        online = bool(item.get("online", True))
        if presence == "Online" and not online:
            continue
        if presence == "Offline" and online:
            continue
        banned = bool(item.get("banned"))
        if state in ("Đang cấm", "Blocked") and not banned:
            continue
        if state in ("Không cấm", "Not blocked") and banned:
            continue
        raw_signal = item.get("signal_dbm")
        try:
            signal_dbm = _finite_float(raw_signal, math.nan) if raw_signal is not None else None
            if signal_dbm is not None and not math.isfinite(signal_dbm):
                signal_dbm = None
        except (TypeError, ValueError):
            signal_dbm = None
        if signal in ("Rất tốt (≥ -60 dBm)", "Excellent (≥ -60 dBm)") and (signal_dbm is None or signal_dbm < -60):
            continue
        if signal in ("Tốt (-70 đến -61 dBm)", "Good (-70 to -61 dBm)") and (
            signal_dbm is None or signal_dbm < -70 or signal_dbm >= -60
        ):
            continue
        if signal in ("Yếu (-80 đến -71 dBm)", "Weak (-80 to -71 dBm)") and (
            signal_dbm is None or signal_dbm < -80 or signal_dbm >= -70
        ):
            continue
        if signal in ("Rất yếu (< -80 dBm)", "Very weak (< -80 dBm)") and (signal_dbm is None or signal_dbm >= -80):
            continue
        if signal in ("Không rõ", "Unknown") and signal_dbm is not None:
            continue
        total_bytes = _nonnegative_int(item.get("rx_bytes")) + _nonnegative_int(item.get("tx_bytes"))
        if traffic in ("Có lưu lượng", "Has traffic") and total_bytes <= 0:
            continue
        if traffic in ("Không lưu lượng", "No traffic") and total_bytes > 0:
            continue
        if traffic in ("Từ 10 MB", "At least 10 MB") and total_bytes < 10 * 1024 * 1024:
            continue
        if traffic in ("Từ 100 MB", "At least 100 MB") and total_bytes < 100 * 1024 * 1024:
            continue
        connected = _nonnegative_int(item.get("connected_s"))
        if duration in ("Dưới 5 phút", "Under 5 minutes") and not (online and connected < 300):
            continue
        if duration in ("5–60 phút", "5–60 minutes") and not (online and 300 <= connected <= 3600):
            continue
        if duration in ("Trên 1 giờ", "Over 1 hour") and not (online and connected > 3600):
            continue
        result.append(item)
    return result


def client_sort_key(item, column):
    if not isinstance(item, dict):
        if column == "status":
            return (True, True)
        return -1 if column in ("ip", "time", "rx", "tx", "signal") else ""
    if column == "ip":
        raw_ip = item.get("ip") or "0.0.0.0"
        if isinstance(raw_ip, bool) or not isinstance(raw_ip, (str, int)):
            return -1
        try:
            return int(ipaddress.ip_address(raw_ip))
        except (TypeError, ValueError):
            return -1
    if column == "time":
        return _nonnegative_int(item.get("connected_s"))
    if column == "rx":
        return _nonnegative_int(item.get("rx_bytes"))
    if column == "tx":
        return _nonnegative_int(item.get("tx_bytes"))
    if column == "signal":
        return _finite_float(item.get("signal_dbm"), -999.0) if item.get("signal_dbm") is not None else -999.0
    if column == "status":
        return (not bool(item.get("online", True)), bool(item.get("banned")))
    return str(item.get(column) or "").casefold()


def wifi_sort_key(record, column, health=None, runtime=None):
    """Return a stable, naturally ordered key for every Wi-Fi table column."""
    health = health if isinstance(health, dict) else {}
    runtime = runtime if isinstance(runtime, dict) else {}
    idx = _nonnegative_int(getattr(record, "idx", 0))

    if column in ("idx", "subnet"):
        return idx
    if column == "name":
        return str(getattr(record, "name", "") or "").casefold()
    if column == "band":
        band = str(getattr(record, "band", "") or "").casefold()
        return ({"2g": 0, "5g": 1}.get(band, 2), band)
    if column == "mac":
        mac = str(runtime.get("macaddr") or "").casefold()
        provider = vendor_label(getattr(record, "mac_oui", "")).casefold()
        return (mac, provider)
    if column == "socks":
        host = str(getattr(record, "host", "") or "").casefold()
        port = _nonnegative_int(getattr(record, "port", 0))
        return (host, port)
    if column == "isolate":
        return int(bool(getattr(record, "isolate", False)))
    if column == "webrtc":
        return int(bool(getattr(record, "webrtc", False)))
    if column == "health":
        state = str(health.get("state") or "").casefold()
        if any(word in state for word in ("ok", "up", "healthy")):
            rank = 0
        elif any(word in state for word in ("slow", "warn")):
            rank = 1
        elif state:
            rank = 2
        else:
            rank = 3
        latency = _finite_float(health.get("latency_ms"), math.inf)
        return (rank, latency, state)
    return ""


class WifiDialog(tk.Toplevel):
    def __init__(self, parent, record: WifiRecord | None, next_idx: int, language="en", palette=None):
        super().__init__(parent)
        self.language = language
        self.t = lambda text, **values: translate(text, self.language, **values)
        self.palette = palette or DARK_PALETTE
        self.title(self.t("Sửa Wi‑Fi" if record else "Thêm Wi‑Fi"))
        self.configure(bg=self.palette["bg"])
        self.resizable(False, False)
        self.transient(parent)
        self.grab_set()
        self.result = None
        record = record or WifiRecord("", "2g", next_idx, "", "", 1080)
        self.values = {
            "name": tk.StringVar(value=record.name), "band": tk.StringVar(value=record.band),
            "idx": tk.StringVar(value=str(record.idx)), "wifi_password": tk.StringVar(value=record.wifi_password),
            "host": tk.StringVar(value=record.host), "port": tk.StringVar(value=str(record.port)),
            "user": tk.StringVar(value=record.user), "socks_password": tk.StringVar(value=record.socks_password),
            "vendor": tk.StringVar(value=vendor_label(record.mac_oui)), "isolate": tk.BooleanVar(value=record.isolate),
            "webrtc": tk.BooleanVar(value=record.webrtc),
        }
        fields = [
            ("SSID", "name", None), ("Băng tần", "band", "combo"), ("IDX", "idx", None),
            ("Mật khẩu Wi‑Fi", "wifi_password", "secret"), ("SOCKS host", "host", None),
            ("SOCKS port", "port", None), ("SOCKS user", "user", None),
            ("SOCKS password", "socks_password", "secret"), ("Hãng router / MAC", "vendor", "vendor"),
        ]
        body = ttk.Frame(self, padding=14)
        body.grid(sticky="nsew")
        first = None
        for row, (label, key, kind) in enumerate(fields):
            ttk.Label(body, text=label).grid(row=row, column=0, sticky="w", padx=(0, 12), pady=4)
            if kind == "combo":
                widget = ttk.Combobox(body, textvariable=self.values[key], values=("2g", "5g"), state="readonly", width=33)
            elif kind == "vendor":
                widget = ttk.Combobox(body, textvariable=self.values[key], values=vendor_choices(record.mac_oui), state="readonly", width=33)
            else:
                widget = ttk.Entry(body, textvariable=self.values[key], width=36, show="•" if kind == "secret" else "")
            widget.grid(row=row, column=1, sticky="ew", pady=4)
            first = first or widget
        checks = ttk.Frame(body)
        checks.grid(row=len(fields), column=0, columnspan=2, sticky="w", pady=(8, 4))
        ttk.Checkbutton(checks, text="Cách ly client", variable=self.values["isolate"]).pack(side="left", padx=(0, 18))
        ttk.Checkbutton(checks, text="Chặn WebRTC", variable=self.values["webrtc"]).pack(side="left")
        actions = ttk.Frame(body)
        actions.grid(row=len(fields) + 1, column=0, columnspan=2, sticky="e", pady=(14, 0))
        ttk.Button(actions, text="Huỷ", command=self.destroy).pack(side="right")
        ttk.Button(actions, text="Lưu", command=self._save).pack(side="right", padx=(0, 8))
        self.bind("<Return>", lambda _event: self._save())
        self.bind("<Escape>", lambda _event: self.destroy())
        self.update_idletasks()
        self.geometry(f"+{parent.winfo_rootx() + 120}+{parent.winfo_rooty() + 70}")
        if first:
            first.focus_set()
        localize_widget_tree(self, self.language)

    def _save(self):
        try:
            result = WifiRecord(
                name=self.values["name"].get().strip(), band=self.values["band"].get(),
                idx=int(self.values["idx"].get()), wifi_password=self.values["wifi_password"].get(),
                host=self.values["host"].get().strip(), port=int(self.values["port"].get()),
                user=self.values["user"].get(), socks_password=self.values["socks_password"].get(),
                isolate=self.values["isolate"].get(), webrtc=self.values["webrtc"].get(),
                mac_oui=vendor_oui(self.values["vendor"].get()),
            )
            result.validate()
        except (ValueError, TypeError) as exc:
            messagebox.showerror(self.t("Dữ liệu không hợp lệ"), self.t(str(exc)), parent=self)
            return
        self.result = result
        self.destroy()


class RandomMacDialog(tk.Toplevel):
    def __init__(self, parent, record: WifiRecord, current_mac: str, language="en", palette=None):
        super().__init__(parent)
        self.language = language
        self.t = lambda text, **values: translate(text, self.language, **values)
        self.palette = palette or DARK_PALETTE
        self.title(f"Random MAC · {record.name}")
        self.resizable(False, False)
        self.transient(parent)
        self.grab_set()
        self.configure(bg=self.palette["bg"])
        self.result = None
        self.vendor_var = tk.StringVar(value=vendor_label(record.mac_oui))
        self.preview_var = tk.StringVar()

        body = ttk.Frame(self, style="Card.TFrame", padding=18)
        body.grid(sticky="nsew")
        ttk.Label(body, text="Chọn hãng router", font=("Segoe UI Semibold", 13)).grid(row=0, column=0, columnspan=2, sticky="w")
        current_label = (
            f"SSID: {record.name}  ·  Current MAC: {current_mac}"
            if self.language == "en" else
            f"SSID: {record.name}  ·  MAC hiện tại: {current_mac}"
        )
        ttk.Label(body, text=current_label, style="Muted.TLabel").grid(row=1, column=0, columnspan=2, sticky="w", pady=(4, 14))
        ttk.Label(body, text="Provider / OUI").grid(row=2, column=0, sticky="w", padx=(0, 12))
        provider = ttk.Combobox(body, textvariable=self.vendor_var, values=vendor_choices(record.mac_oui), state="readonly", width=38)
        provider.grid(row=2, column=1, sticky="ew")
        ttk.Label(body, textvariable=self.preview_var, style="Muted.TLabel").grid(row=3, column=0, columnspan=2, sticky="w", pady=(10, 4))
        ttk.Label(
            body,
            text="Random sẽ cập nhật provider trong config, tạo BSSID mới và reload radio.",
            style="Muted.TLabel",
        ).grid(row=4, column=0, columnspan=2, sticky="w", pady=(0, 14))

        actions = ttk.Frame(body, style="Card.TFrame")
        actions.grid(row=5, column=0, columnspan=2, sticky="e")
        ttk.Button(actions, text="Huỷ", command=self.destroy).pack(side="right")
        ttk.Button(actions, text="Random MAC", command=self._submit, style="Warning.TButton").pack(side="right", padx=(0, 8))
        self.vendor_var.trace_add("write", lambda *_args: self._update_preview())
        self._update_preview()
        self.bind("<Return>", lambda _event: self._submit())
        self.bind("<Escape>", lambda _event: self.destroy())
        self.update_idletasks()
        self.geometry(f"+{parent.winfo_rootx() + 180}+{parent.winfo_rooty() + 120}")
        provider.focus_set()
        localize_widget_tree(self, self.language)

    def _update_preview(self):
        try:
            oui = vendor_oui(self.vendor_var.get())
        except ValueError:
            self.preview_var.set(self.t("OUI không hợp lệ"))
            return
        pattern = f"{oui}:xx:xx:xx" if oui else "02:xx:xx:xx:xx:xx"
        prefix = "New MAC pattern: " if self.language == "en" else "Mẫu MAC mới: "
        self.preview_var.set(f"{prefix}{pattern}")

    def _submit(self):
        try:
            self.result = vendor_oui(self.vendor_var.get())
        except ValueError as exc:
            messagebox.showerror(self.t("Provider không hợp lệ"), self.t(str(exc)), parent=self)
            return
        self.destroy()


class ManualBanDialog(tk.Toplevel):
    def __init__(self, parent, records, language="en", palette=None):
        super().__init__(parent)
        self.language = language
        self.t = lambda text, **values: translate(text, self.language, **values)
        self.palette = palette or DARK_PALETTE
        self.title(self.t("Thêm MAC vào blocklist"))
        self.configure(bg=self.palette["bg"])
        self.resizable(False, False)
        self.transient(parent)
        self.grab_set()
        self.result = None
        self.choices = {f"{record.name} · idx {record.idx}": record.idx for record in records}
        first = next(iter(self.choices), "")
        self.ssid_var = tk.StringVar(value=first)
        self.mac_var = tk.StringVar()

        body = ttk.Frame(self, style="Card.TFrame", padding=18)
        body.grid(sticky="nsew")
        ttk.Label(body, text="Chặn thiết bị theo MAC", font=("Segoe UI Semibold", 13)).grid(row=0, column=0, columnspan=2, sticky="w", pady=(0, 12))
        ttk.Label(body, text="SSID").grid(row=1, column=0, sticky="w", padx=(0, 12), pady=5)
        ttk.Combobox(body, textvariable=self.ssid_var, values=tuple(self.choices), state="readonly", width=34).grid(row=1, column=1, pady=5)
        ttk.Label(body, text="MAC").grid(row=2, column=0, sticky="w", padx=(0, 12), pady=5)
        mac_entry = ttk.Entry(body, textvariable=self.mac_var, width=37)
        mac_entry.grid(row=2, column=1, pady=5)
        ttk.Label(body, text="Ví dụ: AA:BB:CC:DD:EE:FF", style="Muted.TLabel").grid(row=3, column=0, columnspan=2, sticky="w", pady=(2, 12))
        actions = ttk.Frame(body, style="Card.TFrame")
        actions.grid(row=4, column=0, columnspan=2, sticky="e")
        ttk.Button(actions, text="Huỷ", command=self.destroy).pack(side="right")
        ttk.Button(actions, text="Thêm vào blocklist", command=self._submit, style="Danger.TButton").pack(side="right", padx=(0, 8))
        self.bind("<Return>", lambda _event: self._submit())
        self.bind("<Escape>", lambda _event: self.destroy())
        self.update_idletasks()
        self.geometry(f"+{parent.winfo_rootx() + 200}+{parent.winfo_rooty() + 140}")
        mac_entry.focus_set()
        localize_widget_tree(self, self.language)

    def _submit(self):
        mac = self.mac_var.get().strip().lower()
        if not re.fullmatch(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", mac):
            messagebox.showerror(self.t("MAC không hợp lệ"), self.t("MAC phải có dạng AA:BB:CC:DD:EE:FF"), parent=self)
            return
        idx = self.choices.get(self.ssid_var.get())
        if idx is None:
            messagebox.showerror(self.t("Thiếu SSID"), self.t("Hãy chọn SSID cần chặn"), parent=self)
            return
        self.result = idx, mac
        self.destroy()


class LoadingWindow(tk.Toplevel):
    """Modal progress window used while a background router mutation runs."""

    def __init__(self, parent, title: str, timeout_hint: int | None = None, language="en", palette=None):
        super().__init__(parent)
        self.language = language
        self.t = lambda text, **values: translate(text, self.language, **values)
        self.palette = palette or DARK_PALETTE
        self.title(self.t("sbproxy · Đang xử lý"))
        self.resizable(False, False)
        self.transient(parent)
        self.configure(bg=self.palette["bg"])
        self.protocol("WM_DELETE_WINDOW", lambda: None)
        self.started = time.monotonic()
        self.timeout_hint = timeout_hint
        self.detail_var = tk.StringVar(value=title)
        self.elapsed_var = tk.StringVar()

        body = ttk.Frame(self, style="Card.TFrame", padding=22)
        body.grid(sticky="nsew")
        ttk.Label(body, text="Đang kiểm tra và áp dụng", font=("Segoe UI Semibold", 15)).pack(anchor="w")
        ttk.Label(body, textvariable=self.detail_var, style="Muted.TLabel", wraplength=440).pack(anchor="w", pady=(7, 14))
        self.progress = ttk.Progressbar(body, mode="indeterminate", length=440)
        self.progress.pack(fill="x")
        self.progress.start(10)
        ttk.Label(body, textvariable=self.elapsed_var, style="Muted.TLabel").pack(anchor="e", pady=(9, 0))

        self.update_idletasks()
        x = parent.winfo_rootx() + max(20, (parent.winfo_width() - self.winfo_reqwidth()) // 2)
        y = parent.winfo_rooty() + max(20, (parent.winfo_height() - self.winfo_reqheight()) // 2)
        self.geometry(f"+{x}+{y}")
        self.grab_set()
        localize_widget_tree(self, self.language)
        self._tick()

    def _tick(self):
        if not self.winfo_exists():
            return
        elapsed = int(time.monotonic() - self.started)
        if self.timeout_hint:
            self.elapsed_var.set(
                f"Running {elapsed}s · maximum about {self.timeout_hint}s"
                if self.language == "en" else
                f"Đã chạy {elapsed}s · giới hạn tối đa khoảng {self.timeout_hint}s"
            )
        else:
            self.elapsed_var.set(f"Running {elapsed}s" if self.language == "en" else f"Đã chạy {elapsed}s")
        self.after(1000, self._tick)

    def set_detail(self, detail: str):
        if self.winfo_exists():
            self.detail_var.set(detail)

    def close(self):
        if not self.winfo_exists():
            return
        self.progress.stop()
        try:
            self.grab_release()
        except tk.TclError:
            pass
        self.destroy()


STEP_ICONS = {
    STEP_PENDING: "○",
    STEP_RUNNING: "▶",
    STEP_OK: "✓",
    STEP_SKIPPED: "–",
    STEP_FAILED: "✗",
}

STEP_STATE_LABELS = {
    STEP_PENDING: "Chờ",
    STEP_RUNNING: "Đang chạy",
    STEP_OK: "Xong",
    STEP_SKIPPED: "Bỏ qua",
    STEP_FAILED: "Lỗi",
}

ROUTER_STATE_LABELS = {
    "ok": "Agent trả lời OK với token hiện tại",
    "unauthorized": "Agent đang chạy nhưng token sai hoặc thiếu",
    "absent": "Router trả lời nhưng chưa cài agent",
    "unreachable": "Không liên lạc được với router",
}


class SetupWizard(tk.Toplevel):
    """Post-flash bring-up screen: run every step and show progress live."""

    def __init__(self, parent, settings: ProvisionSettings, language="en", palette=None, on_success=None):
        super().__init__(parent)
        self.language = language
        self.t = lambda text, **values: translate(text, self.language, **values)
        self.palette = palette or DARK_PALETTE
        self.on_success = on_success
        self.runner: ProvisionRunner | None = None
        self.busy = False
        self.title(self.t("Cài đặt router sau khi flash"))
        self.configure(bg=self.palette["bg"])
        self.transient(parent)
        self.minsize(880, 640)

        self.host_var = tk.StringVar(value=settings.host)
        self.user_var = tk.StringVar(value=settings.user)
        self.port_var = tk.StringVar(value=str(settings.port))
        self.password_var = tk.StringVar(value=settings.password)
        self.key_var = tk.StringVar(value=settings.key_path)
        self.payload_var = tk.StringVar(value=settings.payload)
        self.config_var = tk.StringVar(value=settings.config_path)
        self.settings_var = tk.StringVar(value=settings.settings_path)
        self.remote_var = tk.StringVar(value=settings.remote_dir)
        self.apply_var = tk.BooleanVar(value=settings.run_apply)
        self.overwrite_var = tk.BooleanVar(value=settings.overwrite_config)
        self.reinstall_var = tk.BooleanVar(value=settings.reinstall_agent)
        self.state_var = tk.StringVar(value=self.t("Chưa chạy bước nào"))

        body = ttk.Frame(self, style="Card.TFrame", padding=14)
        body.pack(fill="both", expand=True)
        ttk.Label(body, text="CÀI ĐẶT SAU KHI FLASH LẠI ROUTER", style="MetricBlue.TLabel").pack(anchor="w")
        ttk.Label(
            body,
            text="Đẩy mã nguồn, cài phụ thuộc, đẩy cấu hình, chạy script khởi tạo, cài agent rồi lấy token.",
            style="Muted.TLabel", wraplength=820,
        ).pack(anchor="w", pady=(3, 10))

        form = ttk.Frame(body, style="Card.TFrame")
        form.pack(fill="x")
        self._field(form, 0, 0, "Router (IP)", self.host_var, width=18)
        self._field(form, 0, 2, "Tài khoản SSH", self.user_var, width=14)
        self._field(form, 0, 4, "Port SSH", self.port_var, width=8)
        self._field(form, 1, 0, "Mật khẩu SSH", self.password_var, width=18, show="•")
        self._field(form, 1, 2, "SSH key (tuỳ chọn)", self.key_var, width=24, browse="file")
        self._field(form, 1, 4, "Thư mục trên router", self.remote_var, width=18)
        self._field(form, 2, 0, "Mã nguồn hoặc gói .tar.gz", self.payload_var, width=34, browse="any", span=3)
        self._field(form, 2, 4, "wifi-socks.conf", self.config_var, width=18, browse="file")
        self._field(form, 3, 0, "settings.sh (tuỳ chọn)", self.settings_var, width=34, browse="file", span=3)
        ttk.Checkbutton(form, text="Chạy apply.sh sau khi đẩy cấu hình", variable=self.apply_var).grid(
            row=3, column=4, columnspan=2, sticky="w", padx=(8, 0), pady=4)
        # Default to reusing what the router already carries; both boxes are
        # opt-in because either one overwrites working router state.
        ttk.Checkbutton(form, text="Ghi đè cấu hình đã có trên router", variable=self.overwrite_var).grid(
            row=4, column=1, columnspan=3, sticky="w", pady=4)
        ttk.Checkbutton(form, text="Cài lại agent dù đã có", variable=self.reinstall_var).grid(
            row=4, column=4, columnspan=2, sticky="w", padx=(8, 0), pady=4)
        for column in (1, 3, 5):
            form.columnconfigure(column, weight=1)

        actions = ttk.Frame(body, style="Card.TFrame")
        actions.pack(fill="x", pady=(10, 8))
        self.run_button = ttk.Button(actions, text="Bắt đầu cài đặt", command=self.start, style="Primary.TButton")
        self.run_button.pack(side="left")
        self.check_button = ttk.Button(actions, text="Kiểm tra tình trạng", command=self.check_state)
        self.check_button.pack(side="left", padx=(8, 0))
        self.stop_button = ttk.Button(actions, text="Dừng", command=self.stop, style="Warning.TButton", state="disabled")
        self.stop_button.pack(side="left", padx=(8, 0))
        ttk.Button(actions, text="Đóng", command=self.close).pack(side="right")
        ttk.Label(actions, textvariable=self.state_var, style="Muted.TLabel").pack(side="right", padx=(0, 14))

        self.progress = ttk.Progressbar(body, mode="determinate", maximum=1)
        self.progress.pack(fill="x", pady=(0, 8))

        self.steps_tree = ttk.Treeview(body, columns=("state", "step", "detail"), show="headings", height=9)
        for column, title, width in (("state", "Trạng thái", 110), ("step", "Bước", 260), ("detail", "Chi tiết", 430)):
            self.steps_tree.heading(column, text=title)
            self.steps_tree.column(column, width=width, anchor="w")
        self.steps_tree.pack(fill="x")

        ttk.Label(body, text="Nhật ký thao tác").pack(anchor="w", pady=(10, 3))
        self.log_text = tk.Text(
            body, height=9, wrap="word", state="disabled",
            bg=self.palette["input"], fg=self.palette["log_text"], borderwidth=0,
            highlightthickness=1, highlightbackground=self.palette["border"],
            padx=10, pady=8, font=("Cascadia Mono", 9),
        )
        self.log_text.pack(fill="both", expand=True)

        self.step_labels = [label for label, _function in ProvisionRunner(settings).steps]
        self.reset_steps()
        self.protocol("WM_DELETE_WINDOW", self.close)
        localize_widget_tree(self, self.language)

    # -- form helpers -------------------------------------------------------

    def _field(self, parent, row, column, label, variable, width=16, show=None, browse=None, span=1):
        ttk.Label(parent, text=label).grid(row=row, column=column, sticky="w", pady=4)
        holder = ttk.Frame(parent, style="Card.TFrame")
        holder.grid(row=row, column=column + 1, columnspan=span, sticky="ew", padx=(8, 16), pady=4)
        entry = ttk.Entry(holder, textvariable=variable, width=width, show=show)
        entry.pack(side="left", fill="x", expand=True)
        if browse:
            ttk.Button(holder, text="…", width=3,
                       command=lambda: self._browse(variable, browse)).pack(side="left", padx=(5, 0))

    def _browse(self, variable, kind):
        if kind == "any":
            path = filedialog.askopenfilename(
                parent=self, title=self.t("Chọn gói cập nhật"),
                filetypes=[("tar.gz", "*.tar.gz"), (self.t("Tất cả file"), "*.*")],
            ) or filedialog.askdirectory(parent=self, title=self.t("Chọn thư mục mã nguồn"))
        else:
            path = filedialog.askopenfilename(parent=self, title=self.t("Chọn file"))
        if path:
            variable.set(path)

    def collect(self) -> ProvisionSettings:
        try:
            port = int(self.port_var.get().strip() or "22")
        except ValueError:
            raise ValueError("Port SSH không hợp lệ") from None
        settings = ProvisionSettings(
            host=self.host_var.get().strip(),
            user=self.user_var.get().strip() or "root",
            port=port,
            key_path=self.key_var.get().strip(),
            password=self.password_var.get(),
            remote_dir=self.remote_var.get().strip() or REMOTE_DIR_DEFAULT,
            payload=self.payload_var.get().strip(),
            config_path=self.config_var.get().strip(),
            settings_path=self.settings_var.get().strip(),
            run_apply=bool(self.apply_var.get()),
            overwrite_config=bool(self.overwrite_var.get()),
            reinstall_agent=bool(self.reinstall_var.get()),
        )
        settings.validate()
        return settings

    # -- checklist rendering ------------------------------------------------

    def reset_steps(self):
        self.steps_tree.delete(*self.steps_tree.get_children())
        for index, label in enumerate(self.step_labels):
            self.steps_tree.insert(
                "", "end", iid=str(index),
                values=(f"{STEP_ICONS[STEP_PENDING]} {self.t(STEP_STATE_LABELS[STEP_PENDING])}",
                        self.t(label), ""),
            )
        self.progress.configure(maximum=max(1, len(self.step_labels)), value=0)

    def set_step(self, index, state, detail):
        if not self.winfo_exists() or index >= len(self.step_labels):
            return
        self.steps_tree.item(str(index), values=(
            f"{STEP_ICONS.get(state, '○')} {self.t(STEP_STATE_LABELS.get(state, state))}",
            self.t(self.step_labels[index]),
            self.t(detail) if detail else "",
        ))
        self.steps_tree.see(str(index))
        done = index + (0 if state == STEP_RUNNING else 1)
        self.progress.configure(value=done)
        self.state_var.set(f"{done}/{len(self.step_labels)} · {self.t(self.step_labels[index])}")
        if state == STEP_RUNNING:
            self.append(f"→ {self.t(self.step_labels[index])}")
        elif detail:
            self.append(f"   {STEP_ICONS.get(state, '')} {self.t(detail)}")

    def append(self, text):
        entry = redact(str(text).rstrip())
        log.info("wizard: %s", entry)
        if not self.winfo_exists():
            return
        self.log_text.configure(state="normal")
        self.log_text.insert("end", entry + "\n")
        self.log_text.see("end")
        self.log_text.configure(state="disabled")

    # -- actions ------------------------------------------------------------

    def _set_busy(self, busy):
        self.busy = busy
        self.run_button.configure(state="disabled" if busy else "normal")
        self.check_button.configure(state="disabled" if busy else "normal")
        self.stop_button.configure(state="normal" if busy else "disabled")

    def start(self):
        if self.busy:
            return
        try:
            settings = self.collect()
        except ValueError as exc:
            messagebox.showerror(APP_NAME, self.t(str(exc)), parent=self)
            return
        save_provision_settings(settings)
        self.reset_steps()
        self._set_busy(True)
        self.append(self.t("Bắt đầu cài đặt") + f" · {settings.target}")

        def emit(index, state, detail):
            self.after(0, lambda: self.set_step(index, state, detail))

        self.runner = ProvisionRunner(settings, emit=emit)

        def worker():
            try:
                success = self.runner.run()
            except Exception as exc:  # validation or unexpected local error
                self.after(0, lambda: self._finish(False, str(exc)))
                return
            self.after(0, lambda: self._finish(success, ""))

        threading.Thread(target=worker, daemon=True).start()

    def _finish(self, success, error):
        self._set_busy(False)
        if error:
            self.append(f"✗ {self.t(error)}")
            messagebox.showerror(APP_NAME, self.t(error), parent=self)
            return
        if not success:
            self.state_var.set(self.t("Cài đặt chưa hoàn tất"))
            self.append(self.t("Cài đặt chưa hoàn tất — hãy xử lý bước lỗi rồi chạy lại."))
            return
        self.state_var.set(self.t("Cài đặt hoàn tất"))
        self.append(self.t("Cài đặt hoàn tất — đã lấy token và mở màn hình điều khiển."))
        token = self.runner.token if self.runner else ""
        base_url = self.runner.settings.base_url if self.runner else ""
        if self.on_success and token:
            self.on_success(base_url, token)
        self.close()

    def check_state(self):
        """Read-only: what does the router answer, and what is installed on it?"""
        if self.busy:
            return
        host = self.host_var.get().strip()
        if not host:
            messagebox.showerror(APP_NAME, self.t("Thiếu địa chỉ router"), parent=self)
            return
        base_url = f"http://{host}"
        _base, token = load_connection()
        try:
            settings = self.collect()
        except ValueError:
            settings = None  # SSH inventory needs valid settings; HTTP probe does not
        self._set_busy(True)
        self.state_var.set(self.t("Đang kiểm tra router…"))

        def worker():
            state = probe_router_state(base_url, token)
            inventory = ""
            if settings:
                runner = ProvisionRunner(settings)
                try:
                    inventory = runner.step_inventory()
                except ProvisionError as exc:
                    inventory = str(exc)
            self.after(0, lambda: self._show_state(state, inventory))

        threading.Thread(target=worker, daemon=True).start()

    def _show_state(self, state, inventory=""):
        self._set_busy(False)
        message = self.t(ROUTER_STATE_LABELS.get(state, state))
        self.state_var.set(message)
        self.append(f"• {message}")
        if inventory:
            self.append(f"• {self.t(inventory)}")
        messagebox.showinfo(APP_NAME, f"{message}\n\n{self.t(inventory)}" if inventory else message, parent=self)

    def stop(self):
        if self.runner:
            self.runner.cancel()
            self.append(self.t("Đã dừng theo yêu cầu"))

    def close(self):
        if self.busy and not messagebox.askyesno(
            APP_NAME, self.t("Đang cài đặt — vẫn đóng cửa sổ?"), parent=self
        ):
            return
        if self.runner:
            self.runner.cancel()
        try:
            self.grab_release()
        except tk.TclError:
            pass
        self.destroy()


class NativeApp:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title(f"{APP_NAME} · v{APP_VERSION}")
        self.root.geometry("1380x840")
        self.root.minsize(1100, 700)
        self.client: AgentClient | None = None
        self.records: list[WifiRecord] = []
        self.clients_data = []
        self.visible_clients = []
        self.client_rows = {}
        self.health = {}
        self.runtime_ssids = {}
        self.gateway_payload = {}
        self.backup_names = []
        self.log_history = []
        self.loading_window: LoadingWindow | None = None
        self._style_images = {}
        self.language, self.theme = load_preferences()
        self.palette = PALETTES[self.theme]
        self.language_var = tk.StringVar(value="English" if self.language == "en" else "Tiếng Việt")
        self.theme_var = tk.StringVar(value="Dark" if self.theme == "dark" else "Light")
        self.t = lambda text, **values: translate(text, self.language, **values)
        base, token = load_connection()
        self.base_var = tk.StringVar(value=base)
        self.token_var = tk.StringVar(value=token)
        self.status_var = tk.StringVar(value=self.t("Chưa kết nối"))
        self.setup_hint_var = tk.StringVar(value=self.t(
            "Router vừa flash lại chưa có agent hoặc token. Chạy cài đặt để đẩy mã nguồn, cấu hình, script khởi tạo và lấy token."
        ))
        self.agent_version = ""
        # Set when the router runs a NEWER agent than this console: the API may
        # have moved on, so every mutation is refused until the app is updated.
        self.agent_too_new = False
        self.agent_outdated = False
        self.upgrade_offered = False
        self.client_ssid_var = tk.StringVar(value=self.t(ALL_SSIDS))
        self.client_query_var = tk.StringVar()
        self.client_state_var = tk.StringVar(value=self.t(ALL_STATES))
        self.client_signal_var = tk.StringVar(value=self.t(ALL_SIGNALS))
        self.client_band_var = tk.StringVar(value=self.t(ALL_BANDS))
        self.client_presence_var = tk.StringVar(value=self.t(ALL_PRESENCE))
        self.client_traffic_var = tk.StringVar(value=self.t(ALL_TRAFFIC))
        self.client_duration_var = tk.StringVar(value=self.t(ALL_DURATIONS))
        self.client_count_var = tk.StringVar(value="0 devices" if self.language == "en" else "0 thiết bị")
        self.client_online_count_var = tk.StringVar(value="0 online")
        self.client_weak_count_var = tk.StringVar(value="0 weak signal" if self.language == "en" else "0 tín hiệu yếu")
        self.client_blocked_count_var = tk.StringVar(value="0 blocked" if self.language == "en" else "0 đã chặn")
        self.client_traffic_total_var = tk.StringVar(value="0 B total traffic" if self.language == "en" else "0 B tổng lưu lượng")
        self.gateway_state_var = tk.StringVar(value=self.t("● Internet chưa kiểm tra"))
        self.gateway_route_var = tk.StringVar(value=self.t("Đường ra: —"))
        self.gateway_link_var = tk.StringVar(value=self.t("Kết nối/DNS: —"))
        self.gateway_http_var = tk.StringVar(value=self.t("Internet HTTP: —"))
        self.wifi_selection_var = tk.StringVar(value=self.t("Chọn một SSID trong bảng để chỉnh sửa"))
        self.client_selection_var = tk.StringVar(value=self.t("Chọn thiết bị trong bảng để điều khiển"))
        self.backup_selection_var = tk.StringVar(value=self.t("Chọn một backup để khôi phục"))
        self.client_auto_var = tk.BooleanVar(value=True)
        self.client_interval_var = tk.StringVar(value="15s")
        self.client_refresh_job = None
        self.client_refreshing = False
        self.wifi_sort_column = "idx"
        self.wifi_sort_reverse = False
        self.wifi_column_titles = {}
        self.client_sort_column = "ssid"
        self.client_sort_reverse = False
        self.client_column_titles = {}
        self.wifi_edit_buttons = {}
        self.client_edit_buttons = {}
        self._configure_styles()
        self._build_ui()
        for variable in (
            self.client_ssid_var,
            self.client_query_var,
            self.client_state_var,
            self.client_signal_var,
            self.client_band_var,
            self.client_presence_var,
            self.client_traffic_var,
            self.client_duration_var,
        ):
            variable.trace_add("write", lambda *_args: self.render_clients())
        self.client_interval_var.trace_add("write", lambda *_args: self.schedule_client_refresh())
        if token:
            # A token is already provisioned: go straight into the live tool.
            self.root.after(350, self.connect)
        else:
            self.status_var.set(self.t("Chưa cấu hình router — hãy chạy cài đặt sau khi flash"))
            # A known router may already be installed: say so before anyone
            # starts a setup run that would repeat work.
            self.root.after(700, lambda: self.check_router_state(announce=False))

    def _configure_styles(self):
        p = self.palette
        self.root.configure(bg=p["bg"])
        self.root.option_add("*Font", ("Segoe UI", 10))
        self.root.option_add("*TCombobox*Listbox.background", p["input"])
        self.root.option_add("*TCombobox*Listbox.foreground", p["text"])
        self.root.option_add("*TCombobox*Listbox.selectBackground", p["primary"])
        self.root.option_add("*TCombobox*Listbox.selectForeground", p["selection_text"])
        style = ttk.Style(self.root)
        style.theme_use("clam")
        style.configure("TFrame", background=p["card"])
        style.configure("Header.TFrame", background=p["header"])
        style.configure("Card.TFrame", background=p["card"])
        style.configure("Toolbar.TFrame", background=p["header"])
        style.configure(
            "Table.TFrame",
            background=p["table_border"],
            bordercolor=p["table_border"],
            lightcolor=p["table_border"],
            darkcolor=p["table_border"],
            borderwidth=1,
            relief="solid",
        )
        style.configure("TLabel", background=p["card"], foreground=p["text"])
        style.configure("Header.TLabel", background=p["header"], foreground=p["text"])
        style.configure("Title.TLabel", background=p["header"], foreground=p["text"], font=("Segoe UI Semibold", 19))
        style.configure("Subtitle.TLabel", background=p["header"], foreground=p["muted"], font=("Segoe UI", 9))
        style.configure("Status.TLabel", background=p["header"], foreground=p["info"], font=("Segoe UI Semibold", 10))
        style.configure("Muted.TLabel", background=p["card"], foreground=p["muted"])
        style.configure("Toolbar.TLabel", background=p["header"], foreground=p["muted"])
        style.configure("Count.TLabel", background=p["header"], foreground=p["info"], font=("Segoe UI Semibold", 10))
        style.configure("Metric.TFrame", background=p["metric"])
        style.configure("MetricBlue.TLabel", background=p["metric"], foreground=p["info"], font=("Segoe UI Semibold", 11))
        style.configure("MetricGreen.TLabel", background=p["metric"], foreground=p["good_text"], font=("Segoe UI Semibold", 11))
        style.configure("MetricYellow.TLabel", background=p["metric"], foreground=p["warn_text"], font=("Segoe UI Semibold", 11))
        style.configure("MetricRed.TLabel", background=p["metric"], foreground=p["bad_text"], font=("Segoe UI Semibold", 11))
        style.configure("TButton", background=p["button"], foreground=p["text"], borderwidth=0, padding=(12, 8), font=("Segoe UI Semibold", 9))
        style.map("TButton", background=[("active", p["button_active"]), ("pressed", p["button_pressed"])])
        for name, color, active in (
            ("Primary", p["primary"], p["primary_active"]),
            ("Success", p["success"], p["success_active"]),
            ("Warning", p["warning"], p["warning_active"]),
            ("Danger", p["danger"], p["danger_active"]),
        ):
            style.configure(f"{name}.TButton", background=color, foreground="white", borderwidth=0, padding=(13, 8), font=("Segoe UI Semibold", 9))
            style.map(f"{name}.TButton", background=[("active", active), ("pressed", active)])
        style.configure("TEntry", fieldbackground=p["input"], foreground=p["text"], bordercolor=p["border"], lightcolor=p["border"], darkcolor=p["border"], padding=7)
        style.configure("TCombobox", fieldbackground=p["input"], background=p["input"], foreground=p["text"], arrowcolor=p["muted"], bordercolor=p["border"], padding=6)
        style.map("TCombobox", fieldbackground=[("readonly", p["input"])], foreground=[("readonly", p["text"])])
        style.configure("TCheckbutton", background=p["card"], foreground=p["text"], indicatorcolor=p["input"], padding=3)
        style.map("TCheckbutton", background=[("active", p["card"])], indicatorcolor=[("selected", p["primary"])])
        style.configure("Toolbar.TCheckbutton", background=p["header"], foreground=p["text"], indicatorcolor=p["input"], padding=3)
        style.map("Toolbar.TCheckbutton", background=[("active", p["header"])], indicatorcolor=[("selected", p["primary"])])
        tab_images = self._style_images.get(self.theme)
        if tab_images is None:
            tab_images = {
                "idle": rounded_tab_image(self.root, p["tab_idle"]),
                "hover": rounded_tab_image(self.root, p["tab_hover"]),
                "selected": rounded_tab_image(self.root, p["tab_selected"]),
            }
            self._style_images[self.theme] = tab_images
        tab_element = f"Chrome.{self.theme}.tab"
        if tab_element not in style.element_names():
            style.element_create(
                tab_element,
                "image",
                tab_images["idle"],
                ("selected", tab_images["selected"]),
                ("active", tab_images["hover"]),
                border=(12, 10, 12, 2),
                sticky="nsew",
            )
        style.configure(
            "Chrome.TNotebook",
            background=p["tab_strip"],
            borderwidth=0,
            tabmargins=(8, 6, 8, 0),
        )
        style.layout(
            "Chrome.TNotebook.Tab",
            [(tab_element, {
                "sticky": "nsew",
                "children": [("Notebook.padding", {
                    "side": "top",
                    "sticky": "nsew",
                    "children": [("Notebook.focus", {
                        "side": "top",
                        "sticky": "nsew",
                        "children": [("Notebook.label", {"side": "top", "sticky": ""})],
                    })],
                })],
            })],
        )
        style.configure(
            "Chrome.TNotebook.Tab",
            background=p["tab_idle"],
            foreground=p["muted"],
            borderwidth=0,
            relief="flat",
            padding=(18, 9),
            font=("Segoe UI", 9),
        )
        style.map(
            "Chrome.TNotebook.Tab",
            background=[("selected", p["tab_selected"]), ("active", p["tab_hover"])],
            foreground=[("selected", p["tab_selected_text"]), ("active", p["text"])],
        )
        style.configure(
            "Treeview",
            background=p["table_row_even"],
            fieldbackground=p["table_row_even"],
            foreground=p["text"],
            bordercolor=p["table_border"],
            lightcolor=p["table_border"],
            darkcolor=p["table_border"],
            borderwidth=1,
            relief="solid",
            rowheight=32,
            font=("Segoe UI", 9),
        )
        style.configure(
            "Treeview.Heading",
            background=p["heading"],
            foreground=p["heading_text"],
            bordercolor=p["table_header_border"],
            lightcolor=p["table_header_border"],
            darkcolor=p["table_header_border"],
            borderwidth=1,
            relief="solid",
            padding=(8, 8),
            font=("Segoe UI Semibold", 9),
        )
        style.map("Treeview", background=[("selected", p["primary"])], foreground=[("selected", p["selection_text"])])
        style.map("Treeview.Heading", background=[("active", p["heading_active"])])
        style.configure("Vertical.TScrollbar", background=p["scroll"], troughcolor=p["input"], borderwidth=0)
        style.configure("Horizontal.TScrollbar", background=p["scroll"], troughcolor=p["input"], borderwidth=0)

    def _build_ui(self):
        header = ttk.Frame(self.root, style="Header.TFrame", padding=(18, 13))
        header.pack(fill="x")
        brand = ttk.Frame(header, style="Header.TFrame")
        brand.pack(side="left")
        ttk.Label(brand, text="sbproxy", style="Title.TLabel").pack(anchor="w")
        ttk.Label(brand, text=f"OPENWRT · MULTI-SSID SOCKS5 CONTROL CENTER · v{APP_VERSION}",
                  style="Subtitle.TLabel").pack(anchor="w")
        ttk.Label(header, textvariable=self.status_var, style="Status.TLabel").pack(side="right", padx=(20, 0))
        preferences = ttk.Frame(header, style="Header.TFrame")
        preferences.pack(side="right", padx=(18, 0))
        ttk.Label(preferences, text="Ngôn ngữ", style="Header.TLabel").pack(side="left", padx=(0, 5))
        language = ttk.Combobox(preferences, textvariable=self.language_var, values=("English", "Tiếng Việt"), state="readonly", width=11)
        language.pack(side="left", padx=(0, 10))
        language.bind("<<ComboboxSelected>>", self._on_language_changed)
        ttk.Label(preferences, text="Giao diện", style="Header.TLabel").pack(side="left", padx=(0, 5))
        theme = ttk.Combobox(preferences, textvariable=self.theme_var, values=("Dark", "Light"), state="readonly", width=7)
        theme.pack(side="left")
        theme.bind("<<ComboboxSelected>>", self._on_theme_changed)
        ttk.Button(preferences, text=self.t("Thư mục log"), command=self.open_log_folder).pack(side="left", padx=(10, 0))

        top = ttk.Frame(self.root, style="Card.TFrame", padding=(14, 12))
        top.pack(fill="x", padx=14, pady=(12, 8))
        ttk.Label(top, text="Router").grid(row=0, column=0, sticky="w")
        ttk.Entry(top, textvariable=self.base_var, width=31).grid(row=0, column=1, padx=(8, 18), sticky="ew")
        ttk.Label(top, text="Agent token").grid(row=0, column=2, sticky="w")
        ttk.Entry(top, textvariable=self.token_var, show="•", width=37).grid(row=0, column=3, padx=(8, 18), sticky="ew")
        ttk.Button(top, text="Kết nối", command=self.connect, style="Primary.TButton").grid(row=0, column=4, padx=4)
        ttk.Button(top, text="Làm mới", command=self.refresh_all).grid(row=0, column=5, padx=4)
        # Always reachable: a router can be reflashed while a token is still stored.
        ttk.Button(top, text="Cài đặt sau khi flash…", command=self.open_setup_wizard).grid(row=0, column=6, padx=(4, 0))
        top.columnconfigure(1, weight=1)
        top.columnconfigure(3, weight=1)

        self.setup_bar = ttk.Frame(self.root, style="Metric.TFrame", padding=(14, 10))
        ttk.Label(self.setup_bar, text="CHƯA CẤU HÌNH ROUTER", style="MetricYellow.TLabel").pack(side="left", padx=(0, 14))
        ttk.Label(self.setup_bar, textvariable=self.setup_hint_var,
                  style="MetricYellow.TLabel", wraplength=760).pack(side="left")
        ttk.Button(self.setup_bar, text="Kiểm tra tình trạng", command=self.check_router_state).pack(side="right")
        self.upgrade_button = ttk.Button(self.setup_bar, text="Nâng cấp agent",
                                         command=self.upgrade_agent, style="Success.TButton")
        ttk.Button(self.setup_bar, text="Cài đặt sau khi flash…", command=self.open_setup_wizard,
                   style="Primary.TButton").pack(side="right", padx=(0, 8))

        gateway = ttk.Frame(self.root, style="Metric.TFrame", padding=(14, 10))
        self.gateway_bar = gateway
        gateway.pack(fill="x", padx=14, pady=(0, 8))
        gateway_head = ttk.Frame(gateway, style="Metric.TFrame")
        gateway_head.pack(fill="x")
        ttk.Label(gateway_head, text="CỔNG RA INTERNET", style="MetricBlue.TLabel").pack(side="left", padx=(0, 18))
        self.gateway_state_label = ttk.Label(gateway_head, textvariable=self.gateway_state_var, style="MetricBlue.TLabel")
        self.gateway_state_label.pack(side="left")
        ttk.Button(gateway_head, text="Kiểm tra cổng ra", command=self.refresh_gateway, style="Primary.TButton").pack(side="right")
        gateway_detail = ttk.Frame(gateway, style="Metric.TFrame")
        gateway_detail.pack(fill="x", pady=(7, 0))
        ttk.Label(gateway_detail, textvariable=self.gateway_route_var, style="MetricBlue.TLabel").pack(side="left", padx=(0, 28))
        ttk.Label(gateway_detail, textvariable=self.gateway_link_var, style="MetricBlue.TLabel").pack(side="left", padx=(0, 28))
        ttk.Label(gateway_detail, textvariable=self.gateway_http_var, style="MetricBlue.TLabel").pack(side="left")

        self.tabs = ttk.Notebook(self.root, style="Chrome.TNotebook")
        self.tabs.pack(fill="both", expand=True, padx=14, pady=(6, 14))
        self._build_wifi_tab()
        self._build_clients_tab()
        self._build_backup_tab()
        localize_widget_tree(self.root, self.language)
        self.update_setup_banner()

    def _on_language_changed(self, _event=None):
        language = "vi" if self.language_var.get() == "Tiếng Việt" else "en"
        if language == self.language:
            return
        filter_vars = (
            self.client_ssid_var, self.client_state_var, self.client_signal_var,
            self.client_band_var, self.client_presence_var,
            self.client_traffic_var, self.client_duration_var,
        )
        current_values = [source_text(variable.get()) for variable in filter_vars]
        self.language = language
        self.t = lambda text, **values: translate(text, self.language, **values)
        for variable, value in zip(filter_vars, current_values):
            variable.set(self.t(value))
        save_preferences(self.language, self.theme)
        self._rebuild_ui()

    def _on_theme_changed(self, _event=None):
        theme = "light" if self.theme_var.get() == "Light" else "dark"
        if theme == self.theme:
            return
        self.theme = theme
        self.palette = PALETTES[self.theme]
        save_preferences(self.language, self.theme)
        self._rebuild_ui()

    def _rebuild_ui(self):
        if self.client_refresh_job:
            self.root.after_cancel(self.client_refresh_job)
            self.client_refresh_job = None
        if self.loading_window:
            self.hide_loading()
        for child in self.root.winfo_children():
            child.destroy()
        self.wifi_edit_buttons = {}
        self.client_edit_buttons = {}
        self.wifi_column_titles = {}
        self.client_column_titles = {}
        self._configure_styles()
        self._build_ui()
        self.render_wifi()
        self.render_clients()
        self.update_client_summary()
        if self.gateway_payload:
            self.render_gateway(self.gateway_payload)
        else:
            self.gateway_state_var.set(self.t("● Internet chưa kiểm tra"))
            self.gateway_route_var.set(self.t("Đường ra: —"))
            self.gateway_link_var.set(self.t("Kết nối/DNS: —"))
            self.gateway_http_var.set(self.t("Internet HTTP: —"))
        for name in self.backup_names:
            self.backup_list.insert("end", name)
        for entry in self.log_history:
            self._write_log_widget(entry)
        if self.client:
            self.status_var.set(
                f"Connected to {self.client.base_url}" if self.language == "en"
                else f"Đã kết nối {self.client.base_url}"
            )
        else:
            self.status_var.set(self.t("Chưa kết nối"))
        self.schedule_client_refresh()

    def _tree(self, parent, columns, widths, selectmode="browse"):
        frame = ttk.Frame(parent, style="Table.TFrame", padding=1)
        frame.pack(fill="both", expand=True)
        tree = ttk.Treeview(frame, columns=tuple(columns), show="headings", selectmode=selectmode)
        tree.tag_configure("row_even", background=self.palette["table_row_even"])
        tree.tag_configure("row_odd", background=self.palette["table_row_odd"])
        for name, title in columns.items():
            tree.heading(name, text=title, anchor="center")
            tree.column(name, width=widths.get(name, 100), anchor="center")
        vscroll = ttk.Scrollbar(frame, orient="vertical", command=tree.yview)
        hscroll = ttk.Scrollbar(frame, orient="horizontal", command=tree.xview)
        tree.configure(yscrollcommand=vscroll.set, xscrollcommand=hscroll.set)
        tree.grid(row=0, column=0, sticky="nsew")
        vscroll.grid(row=0, column=1, sticky="ns")
        hscroll.grid(row=1, column=0, sticky="ew")
        frame.columnconfigure(0, weight=1)
        frame.rowconfigure(0, weight=1)
        return tree

    def _build_wifi_tab(self):
        tab = ttk.Frame(self.tabs, style="Card.TFrame", padding=12)
        self.tabs.add(tab, text="Wi‑Fi / SOCKS5")
        bar = ttk.Frame(tab, style="Toolbar.TFrame", padding=9)
        bar.pack(fill="x", pady=(0, 10))
        for text, command, button_style in [
            ("＋ Thêm SSID", self.add_wifi, "Success.TButton"),
            ("Đẩy cấu hình & Apply", self.save_apply, "Success.TButton"),
        ]:
            ttk.Button(bar, text=text, command=command, style=button_style).pack(side="left", padx=(0, 7))
        columns = {"idx": "IDX", "name": "SSID", "band": "Band", "subnet": "Subnet", "mac": "BSSID / Provider", "socks": "SOCKS5", "isolate": "Isolate", "webrtc": "WebRTC", "health": "Health"}
        self.wifi_column_titles = columns.copy()
        self.wifi_tree = self._tree(tab, columns, {"idx": 50, "name": 150, "band": 55, "subnet": 130, "mac": 220, "socks": 195, "isolate": 70, "webrtc": 75, "health": 100})
        for column, title in columns.items():
            self.wifi_tree.heading(column, text=title, command=lambda selected=column: self.sort_wifi(selected))
        self.wifi_tree.tag_configure("healthy", foreground=self.palette["good_text"])
        self.wifi_tree.tag_configure("warning", foreground=self.palette["warn_text"])
        self.wifi_tree.tag_configure("error", foreground=self.palette["bad_text"])
        self.wifi_tree.bind("<Double-1>", lambda _event: self.edit_wifi())
        self.wifi_tree.bind("<Button-3>", self.show_wifi_context_menu)
        self.wifi_tree.bind("<<TreeviewSelect>>", self.update_wifi_editor)

        self.wifi_context_menu = tk.Menu(
            self.root,
            tearoff=False,
            background=self.palette["card"],
            foreground=self.palette["text"],
            activebackground=self.palette["primary"],
            activeforeground=self.palette["selection_text"],
            relief="flat",
            borderwidth=1,
        )
        self.wifi_context_entries = {}
        for key, text, command in (
            ("edit", "Sửa cấu hình", self.edit_wifi),
            ("sock", "Đổi SOCKS", self.quick_sock),
            ("mac", "Random MAC", self.rotate_wifi_mac),
        ):
            self.wifi_context_menu.add_command(label=self.t(text), command=command)
            self.wifi_context_entries[key] = self.wifi_context_menu.index("end")
        self.wifi_context_menu.add_separator()
        self.wifi_context_menu.add_command(label=self.t("Xoá SSID"), command=self.delete_wifi)
        self.wifi_context_entries["delete"] = self.wifi_context_menu.index("end")

        editor = ttk.Frame(tab, style="Toolbar.TFrame", padding=9)
        editor.pack(fill="x", pady=(8, 0))
        ttk.Label(editor, text="CHỈNH SỬA SSID ĐANG CHỌN", style="Count.TLabel").pack(side="left", padx=(0, 12))
        ttk.Label(editor, textvariable=self.wifi_selection_var, style="Toolbar.TLabel").pack(side="left", fill="x", expand=True)
        for key, text, command, button_style in (
            ("edit", "Sửa cấu hình", self.edit_wifi, "TButton"),
            ("delete", "Xoá SSID", self.delete_wifi, "Danger.TButton"),
        ):
            button = ttk.Button(editor, text=text, command=command, style=button_style, state="disabled")
            button.pack(side="left", padx=(7, 0))
            self.wifi_edit_buttons[key] = button

    def _build_clients_tab(self):
        tab = ttk.Frame(self.tabs, style="Card.TFrame", padding=12)
        self.tabs.add(tab, text="Thiết bị")
        bar = ttk.Frame(tab, style="Toolbar.TFrame", padding=9)
        bar.pack(fill="x", pady=(0, 8))
        ttk.Button(bar, text="Làm mới", command=self.refresh_clients, style="Primary.TButton").pack(side="left", padx=(0, 7))
        ttk.Button(bar, text="Chặn MAC…", command=self.manual_ban_client, style="Danger.TButton").pack(side="left", padx=(0, 7))
        ttk.Button(bar, text="Xuất CSV", command=self.export_clients_csv).pack(side="left", padx=(0, 7))
        ttk.Combobox(bar, textvariable=self.client_interval_var, values=("5s", "10s", "15s", "30s", "60s"), state="readonly", width=5).pack(side="right", padx=(6, 0))
        ttk.Checkbutton(bar, text="Tự làm mới", variable=self.client_auto_var, command=self.toggle_client_auto_refresh, style="Toolbar.TCheckbutton").pack(side="right")

        filters = ttk.Frame(tab, style="Toolbar.TFrame", padding=9)
        filters.pack(fill="x", pady=(0, 8))
        row1 = ttk.Frame(filters, style="Toolbar.TFrame")
        row1.pack(fill="x", pady=(0, 7))
        ttk.Label(row1, text="SSID", style="Toolbar.TLabel").pack(side="left", padx=(0, 5))
        self.client_ssid_combo = ttk.Combobox(row1, textvariable=self.client_ssid_var, values=(ALL_SSIDS,), state="readonly", width=16)
        self.client_ssid_combo.pack(side="left", padx=(0, 10))
        ttk.Label(row1, text="Band", style="Toolbar.TLabel").pack(side="left", padx=(0, 5))
        ttk.Combobox(row1, textvariable=self.client_band_var, values=BAND_FILTERS, state="readonly", width=13).pack(side="left", padx=(0, 10))
        ttk.Label(row1, text="Kết nối", style="Toolbar.TLabel").pack(side="left", padx=(0, 5))
        ttk.Combobox(row1, textvariable=self.client_presence_var, values=PRESENCE_FILTERS, state="readonly", width=16).pack(side="left", padx=(0, 10))
        ttk.Label(row1, text="Quyền", style="Toolbar.TLabel").pack(side="left", padx=(0, 5))
        ttk.Combobox(row1, textvariable=self.client_state_var, values=CLIENT_STATES, state="readonly", width=20).pack(side="left", padx=(0, 10))
        ttk.Label(row1, text="Tìm IP / tên / MAC", style="Toolbar.TLabel").pack(side="left", padx=(0, 5))
        ttk.Entry(row1, textvariable=self.client_query_var, width=24).pack(side="left", fill="x", expand=True)

        row2 = ttk.Frame(filters, style="Toolbar.TFrame")
        row2.pack(fill="x")
        ttk.Label(row2, text="Tín hiệu", style="Toolbar.TLabel").pack(side="left", padx=(0, 5))
        ttk.Combobox(row2, textvariable=self.client_signal_var, values=SIGNAL_FILTERS, state="readonly", width=24).pack(side="left", padx=(0, 10))
        ttk.Label(row2, text="Lưu lượng", style="Toolbar.TLabel").pack(side="left", padx=(0, 5))
        ttk.Combobox(row2, textvariable=self.client_traffic_var, values=TRAFFIC_FILTERS, state="readonly", width=18).pack(side="left", padx=(0, 10))
        ttk.Label(row2, text="Thời gian", style="Toolbar.TLabel").pack(side="left", padx=(0, 5))
        ttk.Combobox(row2, textvariable=self.client_duration_var, values=DURATION_FILTERS, state="readonly", width=18).pack(side="left", padx=(0, 10))
        ttk.Button(row2, text="Đặt lại bộ lọc", command=self.reset_client_filters).pack(side="left")
        ttk.Label(row2, textvariable=self.client_count_var, style="Count.TLabel").pack(side="right", padx=6)

        summary = ttk.Frame(tab, style="Metric.TFrame", padding=(10, 8))
        summary.pack(fill="x", pady=(0, 8))
        for variable, label_style in (
            (self.client_online_count_var, "MetricGreen.TLabel"),
            (self.client_weak_count_var, "MetricYellow.TLabel"),
            (self.client_blocked_count_var, "MetricRed.TLabel"),
            (self.client_traffic_total_var, "MetricBlue.TLabel"),
        ):
            ttk.Label(summary, textvariable=variable, style=label_style).pack(side="left", padx=(4, 24))

        columns = {"ssid": "SSID", "band": "Band", "ip": "IP", "host": "Tên máy", "mac": "MAC", "time": "Kết nối", "rx": "RX", "tx": "TX", "signal": "Signal", "status": "Trạng thái"}
        self.client_column_titles = columns.copy()
        self.client_tree = self._tree(tab, columns, {"ssid": 125, "band": 60, "ip": 115, "host": 145, "mac": 140, "time": 85, "rx": 85, "tx": 85, "signal": 70, "status": 120}, selectmode="extended")
        for column, title in columns.items():
            self.client_tree.heading(column, text=title, command=lambda selected=column: self.sort_clients(selected))
        self.client_tree.tag_configure("banned", foreground=self.palette["bad_text"])
        self.client_tree.tag_configure("offline", foreground=self.palette["muted"])
        self.client_tree.tag_configure("weak", foreground=self.palette["warn_text"])
        self.client_tree.tag_configure("strong", foreground=self.palette["good_text"])
        self.client_tree.bind("<Double-1>", self.show_client_details)
        self.client_tree.bind("<<TreeviewSelect>>", self.update_client_editor)
        self.client_tree.bind("<Control-c>", lambda _event: self.copy_selected_clients())
        self.client_tree.bind("<Control-a>", self.select_all_clients)

        editor = ttk.Frame(tab, style="Toolbar.TFrame", padding=9)
        editor.pack(fill="x", pady=(8, 0))
        ttk.Label(editor, text="ĐIỀU KHIỂN THIẾT BỊ ĐANG CHỌN", style="Count.TLabel").pack(side="left", padx=(0, 12))
        ttk.Label(editor, textvariable=self.client_selection_var, style="Toolbar.TLabel").pack(side="left", fill="x", expand=True)
        for key, text, command, button_style in (
            ("details", "Chi tiết", self.show_client_details, "TButton"),
            ("copy", "Copy IP/MAC", self.copy_selected_clients, "TButton"),
            ("kick", "Kick", lambda: self.client_action("kick"), "Warning.TButton"),
            ("ban", "Cấm", lambda: self.client_action("ban"), "Danger.TButton"),
            ("unban", "Bỏ cấm", lambda: self.client_action("unban"), "Success.TButton"),
        ):
            button = ttk.Button(editor, text=text, command=command, style=button_style, state="disabled")
            button.pack(side="left", padx=(7, 0))
            self.client_edit_buttons[key] = button

    def _build_backup_tab(self):
        tab = ttk.Frame(self.tabs, style="Card.TFrame", padding=12)
        self.tabs.add(tab, text="Backup / Nhật ký")
        left = ttk.Frame(tab, style="Card.TFrame")
        left.pack(side="left", fill="y", padx=(0, 10))
        ttk.Button(left, text="Tải danh sách", command=self.refresh_backups, style="Primary.TButton").pack(fill="x", pady=(0, 6))
        ttk.Button(left, text="Tạo backup", command=self.create_backup, style="Success.TButton").pack(fill="x", pady=(0, 6))
        self.backup_list = tk.Listbox(left, width=40, height=25, bg=self.palette["input"], fg=self.palette["text"], selectbackground=self.palette["primary"], selectforeground=self.palette["selection_text"], borderwidth=0, highlightthickness=1, highlightbackground=self.palette["border"], font=("Segoe UI", 10))
        self.backup_list.pack(fill="both", expand=True)
        self.backup_list.bind("<<ListboxSelect>>", self.update_backup_editor)
        backup_editor = ttk.Frame(left, style="Toolbar.TFrame", padding=9)
        backup_editor.pack(fill="x", pady=(8, 0))
        ttk.Label(backup_editor, textvariable=self.backup_selection_var, style="Toolbar.TLabel").pack(anchor="w", pady=(0, 7))
        self.rollback_button = ttk.Button(backup_editor, text="Rollback backup đang chọn", command=self.rollback, style="Warning.TButton", state="disabled")
        self.rollback_button.pack(fill="x")
        right = ttk.Frame(tab, style="Card.TFrame")
        right.pack(side="left", fill="both", expand=True)
        ttk.Label(right, text="Nhật ký thao tác").pack(anchor="w")
        self.log = tk.Text(right, wrap="word", state="disabled", bg=self.palette["input"], fg=self.palette["log_text"], insertbackground=self.palette["text"], borderwidth=0, highlightthickness=1, highlightbackground=self.palette["border"], padx=10, pady=10, font=("Cascadia Mono", 9))
        self.log.pack(fill="both", expand=True, pady=(5, 0))

    def append_log(self, text):
        entry = str(text).rstrip()
        self.log_history.append(entry)
        log.info("ui: %s", redact(entry))
        self._write_log_widget(entry)

    def open_log_folder(self):
        """Hand the operator the log directory for a support bundle."""
        path = str(LOG_DIR)
        try:
            if os.name == "nt":
                os.startfile(path)  # noqa: S606 - opening our own data folder
            elif sys.platform == "darwin":
                subprocess.Popen(["open", path])
            else:
                subprocess.Popen(["xdg-open", path])
            log.info("opened log folder %s", path)
        except Exception as exc:
            log.warning("cannot open log folder: %s", exc)
            messagebox.showinfo(APP_NAME, f"{path}\n\n{exc}", parent=self.root)

    def _write_log_widget(self, text):
        if not hasattr(self, "log") or not self.log.winfo_exists():
            return
        self.log.configure(state="normal")
        self.log.insert("end", str(text).rstrip() + "\n\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def show_loading(self, label, timeout_hint=None):
        self.hide_loading()
        self.loading_window = LoadingWindow(
            self.root, label, timeout_hint, self.language, self.palette
        )

    def update_loading(self, detail):
        def update():
            if self.loading_window and self.loading_window.winfo_exists():
                self.loading_window.set_detail(self.t(detail))
        self.root.after(0, update)

    def hide_loading(self):
        if self.loading_window:
            self.loading_window.close()
            self.loading_window = None

    def run_task(self, label, function, success=None, show_loading=False, timeout_hint=None):
        label = self.t(label)
        self.status_var.set(label)
        if show_loading:
            self.show_loading(label, timeout_hint)
        log.info("task start: %s", redact(label))
        def worker():
            try:
                result = function()
            except Exception as exc:
                log.exception("task failed: %s", redact(label))
                self.root.after(0, lambda: self._task_error(exc))
                return
            self.root.after(0, lambda: self._task_success(result, success))
        threading.Thread(target=worker, daemon=True).start()

    def _task_error(self, exc):
        self.hide_loading()
        detail = self.t(str(exc))
        self.status_var.set(f"Error: {detail}" if self.language == "en" else f"Lỗi: {detail}")
        self.append_log(f"ERROR: {detail}" if self.language == "en" else f"LỖI: {detail}")
        messagebox.showerror("sbproxy", detail, parent=self.root)

    def _task_success(self, result, callback):
        self.hide_loading()
        self.status_var.set(self.t("Hoàn tất"))
        if callback:
            callback(result)

    def confirm_important(self, title, action, impact):
        """Require an explicit, default-deny confirmation before router mutations."""
        if self.language == "en":
            message = (
                "WARNING · IMPORTANT ACTION\n\n"
                f"Action:\n{self.t(action)}\n\n"
                f"Possible impact:\n{self.t(impact)}\n\n"
                "Continue only after verifying the target SSID/device and accepting the impact."
            )
            dialog_title = f"Warning — {self.t(title)}"
        else:
            message = (
                "CẢNH BÁO · TÁC VỤ QUAN TRỌNG\n\n"
                f"Thao tác:\n{action}\n\n"
                f"Ảnh hưởng có thể xảy ra:\n{impact}\n\n"
                "Chỉ tiếp tục khi bạn đã kiểm tra đúng SSID/thiết bị và chấp nhận ảnh hưởng."
            )
            dialog_title = f"Cảnh báo — {title}"
        return messagebox.askyesno(
            dialog_title,
            message,
            icon=messagebox.WARNING,
            default=messagebox.NO,
            parent=self.root,
        )

    def _make_client(self):
        base = self.base_var.get().strip().rstrip("/")
        token = self.token_var.get().strip()
        if not base.startswith(("http://", "https://")):
            raise ValueError("Base URL phải bắt đầu bằng http:// hoặc https://")
        if not token:
            raise ValueError("Thiếu token Agent")
        return AgentClient(base, token)

    def connect(self):
        try:
            client = self._make_client()
        except ValueError as exc:
            self._task_error(exc)
            return
        def work():
            status = client.status()
            records = parse_conf(client.get_conf())
            try:
                gateway = client.gateway()
            except AgentError as exc:
                gateway = {"state": "unknown", "error": str(exc)}
            return client, status, records, gateway
        def done(result):
            self.client, status, self.records, gateway = result
            save_connection(self.client.base_url, self.client.token)
            self.health = normalize_health_probes(status)
            self.capture_runtime_ssids(status)
            self.render_gateway(gateway)
            meta = status.get("meta") if isinstance(status.get("meta"), dict) else {}
            running = bool(meta.get("singbox_running"))
            self.agent_version = clean_agent_version(meta)
            self.status_var.set(
                f"Connected to {self.client.base_url} · sing-box {'running' if running else 'NOT running'}"
                if self.language == "en" else
                f"Đã kết nối {self.client.base_url} · sing-box {'đang chạy' if running else 'KHÔNG chạy'}"
            )
            if self.agent_version:
                suffix = f" · agent v{self.agent_version}"
                if self.agent_version != APP_VERSION:
                    suffix += " (≠ app)" if self.language == "en" else " (khác app)"
                self.status_var.set(self.status_var.get() + suffix)
            self.render_wifi()
            self.refresh_clients()
            self.refresh_backups()
            self.evaluate_agent_compatibility()
        self.run_task("Đang kết nối Agent…", work, done)

    def update_setup_banner(self):
        """Show the bar while no token is configured, or on a version mismatch."""
        if not hasattr(self, "setup_bar") or not self.setup_bar.winfo_exists():
            return
        needed = not self.token_var.get().strip() or self.agent_outdated or self.agent_too_new
        if self.agent_outdated and not self.upgrade_button.winfo_manager():
            self.upgrade_button.pack(side="right", padx=(0, 8))
        elif not self.agent_outdated and self.upgrade_button.winfo_manager():
            self.upgrade_button.pack_forget()
        if not needed:
            self.setup_bar.pack_forget()
        elif not self.setup_bar.winfo_manager():
            self.setup_bar.pack(fill="x", padx=14, pady=(0, 8), before=self.gateway_bar)

    def open_setup_wizard(self):
        """Run the post-flash sequence and hand the fetched token to the tool."""
        settings = load_provision_settings()
        if not settings.host and self.base_var.get():
            settings.host = self.base_var.get().split("//")[-1].strip("/")
        SetupWizard(self.root, settings, self.language, self.palette, on_success=self.adopt_token)

    def adopt_token(self, base_url, token):
        """Store a freshly provisioned token and open the control screens."""
        self.base_var.set(base_url)
        self.token_var.set(token)
        save_connection(base_url, token)
        self.append_log(
            f"Provisioning finished · {base_url}" if self.language == "en"
            else f"Cài đặt xong · {base_url}"
        )
        self.update_setup_banner()
        self.connect()

    def check_router_state(self, announce=True):
        """Report what the router currently offers before any change is made."""
        base = self.base_var.get().strip().rstrip("/") or DEFAULT_BASE
        token = self.token_var.get().strip()
        def work():
            return probe_router_state(base, token)
        def done(state):
            message = self.t(ROUTER_STATE_LABELS.get(state, state))
            self.status_var.set(message)
            self.setup_hint_var.set(f"{base} · {message}")
            self.append_log(f"{base} · {message}")
            if announce:
                messagebox.showinfo(APP_NAME, f"{base}\n\n{message}", parent=self.root)
        if not announce:
            # Launch-time check: never pop a dialog, never block the window.
            def worker():
                try:
                    state = work()
                except Exception:
                    return
                self.root.after(0, lambda: done(state))
            threading.Thread(target=worker, daemon=True).start()
            return
        self.run_task("Đang kiểm tra tình trạng router…", work, done)

    def evaluate_agent_compatibility(self):
        """Compare the agent with this console and act on the difference.

        Older agent: offer to upgrade it in place (the router keeps its
        configuration). Newer agent: refuse to drive it — an old console may
        not understand the API or configuration format it serves.
        """
        order = compare_versions(self.agent_version, APP_VERSION)
        self.agent_outdated = order == -1
        self.agent_too_new = order == 1
        if order is None or order == 0:
            self.update_setup_banner()
            return
        if self.agent_too_new:
            message = self.t(
                "Agent trên router là v{agent}, mới hơn console v{app}. Hãy dùng bản console mới hơn;"
                " console cũ chỉ được phép xem, mọi thao tác thay đổi bị khoá.",
                agent=self.agent_version, app=APP_VERSION,
            )
            self.setup_hint_var.set(message)
            self.append_log(message)
            self.update_setup_banner()
            messagebox.showerror(APP_NAME, message, parent=self.root)
            return
        message = self.t(
            "Agent trên router là v{agent}, cũ hơn console v{app}.",
            agent=self.agent_version, app=APP_VERSION,
        )
        self.setup_hint_var.set(message)
        self.append_log(message)
        self.update_setup_banner()
        if self.upgrade_offered:
            return
        self.upgrade_offered = True
        if messagebox.askyesno(
            APP_NAME,
            message + "\n\n" + self.t(
                "Nâng cấp agent lên v{app} ngay bây giờ? Cấu hình wifi-socks.conf và settings.sh"
                " trên router được giữ nguyên, router tự backup trước khi cập nhật.",
                app=APP_VERSION,
            ),
            default=messagebox.YES,
            parent=self.root,
        ):
            self.upgrade_agent()

    def upgrade_agent(self):
        """Upload this console's router package; the agent keeps its config."""
        client = self.require_client()
        if self.agent_version and compare_versions(APP_VERSION, self.agent_version) != 1:
            messagebox.showinfo(APP_NAME, self.t(
                "Agent đã ở v{agent}; console này không có bản mới hơn để đẩy lên.",
                agent=self.agent_version,
            ), parent=self.root)
            return
        def work():
            package = build_update_package()
            version = payload_version(package) or APP_VERSION
            if compare_versions(version, APP_VERSION) not in (0, None):
                log.warning("update package v%s does not match console v%s", version, APP_VERSION)
            return client.update(package.read_bytes())
        def done(result):
            from_version = str(result.get("from") or "?")
            to_version = str(result.get("to") or "?")
            self.append_log(self.t("Đã nâng cấp agent: {old} → {new}", old=from_version, new=to_version))
            self.agent_outdated = False
            self.upgrade_offered = False
            self.update_setup_banner()
            messagebox.showinfo(APP_NAME, self.t(
                "Đã nâng cấp agent: {old} → {new}", old=from_version, new=to_version,
            ), parent=self.root)
            self.connect()
        self.run_task("Đang nâng cấp agent…", work, done, show_loading=True, timeout_hint=300)

    def block_if_incompatible(self) -> bool:
        """Refuse mutations while the router runs a newer agent than this app."""
        if not getattr(self, "agent_too_new", False):
            return False
        message = self.t(
            "Console v{app} cũ hơn agent v{agent} — hãy cập nhật console trước khi thay đổi router.",
            app=APP_VERSION, agent=self.agent_version,
        )
        self.append_log(message)
        messagebox.showerror(APP_NAME, message, parent=self.root)
        return True

    def require_client(self) -> AgentClient:
        if not self.client:
            raise AgentError("Chưa kết nối Agent")
        return self.client

    def refresh_all(self):
        if not self.client:
            self.connect()
            return
        def work():
            status = self.client.status()
            records = parse_conf(self.client.get_conf())
            try:
                gateway = self.client.gateway()
            except AgentError as exc:
                gateway = {"state": "unknown", "error": str(exc)}
            return status, records, gateway
        def done(result):
            status, self.records, gateway = result
            self.health = normalize_health_probes(status)
            self.capture_runtime_ssids(status)
            self.render_gateway(gateway)
            meta = status.get("meta") if isinstance(status.get("meta"), dict) else {}
            running = bool(meta.get("singbox_running"))
            self.agent_version = clean_agent_version(meta)
            self.status_var.set(
                f"Refreshed · sing-box {'running' if running else 'NOT running'}"
                if self.language == "en" else
                f"Đã làm mới · sing-box {'đang chạy' if running else 'KHÔNG chạy'}"
            )
            if self.agent_version:
                suffix = f" · agent v{self.agent_version}"
                if self.agent_version != APP_VERSION:
                    suffix += " (≠ app)" if self.language == "en" else " (khác app)"
                self.status_var.set(self.status_var.get() + suffix)
            self.render_wifi()
        self.run_task("Đang làm mới…", work, done)

    def render_gateway(self, payload):
        payload = payload if isinstance(payload, dict) else {}
        self.gateway_payload = payload
        state = str(payload.get("state") or "unknown")
        labels = {
            "ok": ("● Internet hoạt động", "MetricGreen.TLabel"),
            "degraded": ("● Internet suy giảm", "MetricYellow.TLabel"),
            "down": ("● Mất kết nối Internet", "MetricRed.TLabel"),
            "unknown": ("● Internet chưa xác định", "MetricBlue.TLabel"),
        }
        text, style = labels.get(state, labels["unknown"])
        self.gateway_state_var.set(self.t(text))
        self.gateway_state_label.configure(style=style)

        expected = str(payload.get("expected_interface") or "wwan")
        logical = str(payload.get("interface") or "—")
        device = str(payload.get("device") or "—")
        via = str(payload.get("gateway") or ("direct" if self.language == "en" else "trực tiếp"))
        source = str(payload.get("source_ip") or "—")
        route = (
            f"Egress: {logical}/{device} · via {via} · src {source}"
            if self.language == "en" else
            f"Đường ra: {logical}/{device} · qua {via} · IP nguồn {source}"
        )
        if payload.get("expected_active") is False:
            route += f" · NOT VIA {expected}" if self.language == "en" else f" · KHÔNG QUA {expected}"
        self.gateway_route_var.set(route)

        link = "OK" if payload.get("link_ok") else ("ERROR" if self.language == "en" else "LỖI")
        if not payload.get("dns_checked", True):
            dns = "not checked" if self.language == "en" else "chưa kiểm tra"
        else:
            dns = "OK" if payload.get("dns_ok") else ("ERROR" if self.language == "en" else "LỖI")
        self.gateway_link_var.set(
            f"Link: {link} · DNS: {dns}"
            if self.language == "en" else
            f"Kết nối: {'Tốt' if link == 'OK' else link} · DNS: {'Tốt' if dns == 'OK' else dns}"
        )

        if payload.get("http_ok"):
            self.gateway_http_var.set(
                f"HTTP: {payload.get('http_code') or 0} · {payload.get('latency_ms') or 0} ms"
            )
        else:
            error = str(payload.get("error") or ("unreachable" if self.language == "en" else "không truy cập được"))
            self.gateway_http_var.set(f"HTTP: {'ERROR' if self.language == 'en' else 'LỖI'} · {error}")

    def refresh_gateway(self):
        try:
            client = self.require_client()
        except AgentError as exc:
            self._task_error(exc)
            return
        def done(payload):
            self.render_gateway(payload)
            state = payload.get("state") or "unknown"
            state_vi = {
                "ok": "hoạt động",
                "degraded": "suy giảm",
                "down": "mất kết nối",
                "unknown": "chưa xác định",
            }.get(state, str(state))
            self.append_log(
                f"Gateway check: {state} · {payload.get('route') or 'no route'}"
                if self.language == "en" else
                f"Kiểm tra cổng ra: {state_vi} · {payload.get('route') or 'không có route'}"
            )
        self.run_task("Đang kiểm tra cổng ra Internet…", client.gateway, done)

    def capture_runtime_ssids(self, status):
        self.runtime_ssids = {}
        ssids = status.get("ssids") if isinstance(status, dict) else None
        for item in normalize_clients(ssids):
            try:
                idx = int(item.get("idx"))
            except (TypeError, ValueError, OverflowError):
                continue
            if 1 <= idx <= 200:
                self.runtime_ssids[idx] = item

    def selected_wifi(self):
        selected = self.wifi_tree.selection()
        if not selected:
            return None
        try:
            idx = int(selected[0])
        except (TypeError, ValueError):
            return None
        return next((item for item in self.records if item.idx == idx), None)

    def show_wifi_context_menu(self, event):
        """Select the row under the pointer and open its item action menu."""
        row = self.wifi_tree.identify_row(event.y)
        if not row:
            return None
        self.wifi_tree.selection_set(row)
        self.wifi_tree.focus(row)
        self.update_wifi_editor()
        try:
            self.wifi_context_menu.tk_popup(event.x_root, event.y_root)
        finally:
            self.wifi_context_menu.grab_release()
        return "break"

    def update_wifi_editor(self, _event=None):
        record = self.selected_wifi()
        state = "normal" if record else "disabled"
        for button in self.wifi_edit_buttons.values():
            button.configure(state=state)
        for entry in getattr(self, "wifi_context_entries", {}).values():
            self.wifi_context_menu.entryconfigure(entry, state=state)
        if record:
            self.wifi_selection_var.set(f"{record.name} · IDX {record.idx} · {record.band}")
        else:
            self.wifi_selection_var.set(self.t("Chọn một SSID trong bảng để chỉnh sửa"))

    def next_idx(self):
        used = {item.idx for item in self.records}
        for idx in range(1, 201):
            if idx not in used:
                return idx
        raise AgentError("Đã đạt giới hạn 200 SSID")

    def add_wifi(self):
        if self.block_if_incompatible():
            return
        try:
            next_idx = self.next_idx()
        except AgentError as exc:
            self._task_error(exc)
            return
        dialog = WifiDialog(self.root, None, next_idx, self.language, self.palette)
        self.root.wait_window(dialog)
        if dialog.result:
            if any(item.idx == dialog.result.idx for item in self.records):
                messagebox.showerror(self.t("IDX bị trùng"), self.t("IDX này đã được sử dụng"), parent=self.root)
                return
            self.records.append(dialog.result)
            self.records.sort(key=lambda item: item.idx)
            self.render_wifi()

    def edit_wifi(self):
        if self.block_if_incompatible():
            return
        record = self.selected_wifi()
        if not record:
            messagebox.showinfo(APP_NAME, self.t("Hãy chọn một Wi‑Fi"), parent=self.root)
            return
        dialog = WifiDialog(self.root, record, record.idx, self.language, self.palette)
        self.root.wait_window(dialog)
        if dialog.result:
            if any(item.idx == dialog.result.idx and item is not record for item in self.records):
                messagebox.showerror(self.t("IDX bị trùng"), self.t("IDX này đã được sử dụng"), parent=self.root)
                return
            self.records[self.records.index(record)] = dialog.result
            self.records.sort(key=lambda item: item.idx)
            self.render_wifi()

    def delete_wifi(self):
        if self.block_if_incompatible():
            return
        record = self.selected_wifi()
        action = (
            f"Delete SSID {record.name} (IDX {record.idx}) from the configuration being edited."
            if record and self.language == "en" else
            f"Xoá SSID {record.name} (IDX {record.idx}) khỏi cấu hình đang chỉnh sửa."
            if record else ""
        )
        impact = (
            "The router is not changed yet. On Apply, this SSID, its routing rules, and its connections will be removed."
            if self.language == "en" else
            "Chưa tác động router ngay. Khi Apply, SSID, rule định tuyến và các kết nối của SSID này sẽ bị xoá."
        )
        if record and self.confirm_important(
            "Xoá SSID",
            action,
            impact,
        ):
            self.records.remove(record)
            self.render_wifi()

    def quick_sock(self):
        if self.block_if_incompatible():
            return
        record = self.selected_wifi()
        if not record:
            messagebox.showinfo(APP_NAME, self.t("Hãy chọn một Wi‑Fi"), parent=self.root)
            return
        dialog = WifiDialog(self.root, record, record.idx, self.language, self.palette)
        dialog.title(self.t("Đổi SOCKS nhanh"))
        self.root.wait_window(dialog)
        if not dialog.result:
            return
        updated = dialog.result
        action = (
            f"Change the SOCKS5 endpoint used by SSID {record.name}."
            if self.language == "en" else
            f"Đổi endpoint SOCKS5 đang dùng cho SSID {record.name}."
        )
        impact = (
            "The change is sent to the router immediately. Existing sessions may disconnect, and an invalid endpoint may leave the SSID without Internet access."
            if self.language == "en" else
            "Thay đổi được gửi lên router ngay. Phiên mạng hiện tại có thể bị ngắt; endpoint sai có thể làm SSID mất Internet."
        )
        if not self.confirm_important(
            "Đổi SOCKS5",
            action,
            impact,
        ):
            return
        try:
            client = self.require_client()
        except AgentError as exc:
            self._task_error(exc)
            return
        def done(response):
            self.records[self.records.index(record)] = updated
            self.render_wifi()
            fallback = "SOCKS changed successfully" if self.language == "en" else "Đổi SOCKS thành công"
            self.append_log(response.get("log", fallback))
        self.run_task("Đang đổi SOCKS…", lambda: client.set_sock(updated), done)

    def rotate_wifi_mac(self):
        if self.block_if_incompatible():
            return
        record = self.selected_wifi()
        if not record:
            messagebox.showinfo(APP_NAME, self.t("Hãy chọn một Wi‑Fi cần random MAC"), parent=self.root)
            return
        current = (self.runtime_ssids.get(record.idx) or {}).get("macaddr") or "chưa đặt"
        dialog = RandomMacDialog(self.root, record, current, self.language, self.palette)
        self.root.wait_window(dialog)
        if dialog.result is None:
            return
        selected_oui = dialog.result
        provider = self.t(vendor_label(selected_oui))
        action = (
            f"Change the BSSID/MAC of {record.name}.\nCurrent: {current}\nNew provider: {provider}"
            if self.language == "en" else
            f"Đổi BSSID/MAC của {record.name}.\nHiện tại: {current}\nProvider mới: {provider}"
        )
        impact = (
            "Wi-Fi networks on the same radio will reload, briefly disconnecting devices. The new provider and MAC will persist across future Apply operations."
            if self.language == "en" else
            "Wi‑Fi cùng radio sẽ reload và các thiết bị có thể mất kết nối ngắn. Provider và MAC mới sẽ được lưu qua các lần Apply."
        )
        if not self.confirm_important(
            "Random MAC",
            action,
            impact,
        ):
            return
        try:
            client = self.require_client()
        except AgentError as exc:
            self._task_error(exc)
            return

        def done(payload):
            new_mac = payload.get("mac") or ("changed" if self.language == "en" else "đã đổi")
            record.mac_oui = selected_oui
            runtime = self.runtime_ssids.setdefault(record.idx, {})
            runtime["macaddr"] = new_mac
            runtime["mac_oui"] = selected_oui
            self.render_wifi()
            fallback = (
                f"Rotated MAC {record.name} -> {new_mac}" if self.language == "en" else
                f"Đã xoay MAC {record.name} -> {new_mac}"
            )
            self.append_log(payload.get("log", fallback))
            self.status_var.set(
                f"Rotated BSSID {record.name} → {new_mac}; Wi-Fi is reloading"
                if self.language == "en" else
                f"Đã xoay BSSID {record.name} → {new_mac}; Wi‑Fi đang reload"
            )
            self.root.after(5000, self.refresh_all)

        self.run_task(
            f"Rotating BSSID/MAC for {record.name}…" if self.language == "en" else f"Đang xoay BSSID/MAC của {record.name}…",
            lambda: client.rotate_mac(record.idx, selected_oui),
            done,
        )

    def save_apply(self):
        if self.block_if_incompatible():
            return
        try:
            client = self.require_client()
            content = render_conf(self.records)
        except Exception as exc:
            self._task_error(exc)
            return
        action = (
            f"Save and activate the complete configuration containing {len(self.records)} SSIDs."
            if self.language == "en" else
            f"Ghi và kích hoạt toàn bộ cấu hình gồm {len(self.records)} SSID."
        )
        impact = (
            "The app will run a dry-run and create a backup first, then save the configuration, replace network rules, and reload Wi-Fi. Devices may be disconnected temporarily."
            if self.language == "en" else
            "App sẽ dry-run và backup trước, sau đó ghi cấu hình, thay rule mạng và reload Wi‑Fi. Các thiết bị có thể mất kết nối tạm thời."
        )
        if not self.confirm_important(
            "Dry-run và Apply",
            action,
            impact,
        ):
            return
        def work():
            self.update_loading(
                "Step 1/3 · Dry-running the temporary configuration; the router is unchanged…"
                if self.language == "en" else
                "Bước 1/3 · Dry-run cấu hình tạm, chưa ghi lên router…"
            )
            dryrun = client.dryrun_conf(content)
            if not dryrun.get("ok", False):
                raise AgentError(dryrun.get("log") or "Dry-run thất bại")
            self.update_loading(
                "Step 2/3 · Dry-run passed; creating a backup and saving configuration…"
                if self.language == "en" else
                "Bước 2/3 · Dry-run đạt, đang backup và lưu cấu hình…"
            )
            client.save_conf(content)
            self.update_loading(
                "Step 3/3 · Running the final required dry-run and applying to the router…"
                if self.language == "en" else
                "Bước 3/3 · Dry-run bắt buộc lần cuối và apply lên router…"
            )
            result = client.apply()
            if not result.get("ok", False):
                raise AgentError(result.get("log") or "Apply thất bại")
            return dryrun, result
        def done(payload):
            _dryrun, result = payload
            self.append_log(
                "DRY-RUN OK · No errors found; apply was allowed."
                if self.language == "en" else
                "DRY-RUN OK · Không phát hiện lỗi, đã cho phép apply."
            )
            self.append_log(result.get("log", "Apply succeeded" if self.language == "en" else "Apply thành công"))
            self.status_var.set(
                "Apply succeeded; Wi-Fi is reloading"
                if self.language == "en" else
                "Apply thành công; Wi‑Fi đang reload"
            )
            self.root.after(5000, self.refresh_all)
        self.run_task(
            "Đang dry-run trước khi apply…",
            work,
            done,
            show_loading=True,
            timeout_hint=225,
        )

    def sort_wifi(self, column):
        if column not in self.wifi_column_titles:
            return
        if self.wifi_sort_column == column:
            self.wifi_sort_reverse = not self.wifi_sort_reverse
        else:
            self.wifi_sort_column = column
            self.wifi_sort_reverse = False
        self.render_wifi()

    def render_wifi(self):
        records = sorted(
            self.records,
            key=lambda record: wifi_sort_key(
                record,
                self.wifi_sort_column,
                self.health.get(str(record.idx), self.health.get(record.idx, {})),
                self.runtime_ssids.get(record.idx),
            ),
            reverse=self.wifi_sort_reverse,
        )
        for column, title in self.wifi_column_titles.items():
            marker = " ▼" if self.wifi_sort_reverse else " ▲"
            self.wifi_tree.heading(
                column,
                text=self.t(title) + marker if column == self.wifi_sort_column else self.t(title),
                command=lambda selected=column: self.sort_wifi(selected),
            )
        self.wifi_tree.delete(*self.wifi_tree.get_children())
        for pos, record in enumerate(records):
            probe = self.health.get(str(record.idx), self.health.get(record.idx, {})) or {}
            state = probe.get("state", "—")
            latency = probe.get("latency_ms")
            health = f"{state} {latency}ms" if latency is not None else state
            runtime = self.runtime_ssids.get(record.idx) or {}
            mac = runtime.get("macaddr") or "—"
            provider = self.t(vendor_label(record.mac_oui)).split(" · ", 1)[0]
            mac_display = f"{mac} · {provider}"
            normalized = str(state).casefold()
            tag = ""
            if any(word in normalized for word in ("ok", "up", "healthy")):
                tag = "healthy"
            elif any(word in normalized for word in ("slow", "warn")):
                tag = "warning"
            elif state not in ("", "—", None):
                tag = "error"
            row_tag = "row_even" if pos % 2 == 0 else "row_odd"
            tags = (row_tag, tag) if tag else (row_tag,)
            self.wifi_tree.insert("", "end", iid=str(record.idx), tags=tags, values=(record.idx, record.name, record.band, f"192.168.{10 + record.idx}.0/24", mac_display, f"{record.host}:{record.port}", self.t("Có") if record.isolate else self.t("Không"), self.t("Chặn") if record.webrtc else self.t("Cho phép"), health))
        self.update_client_filter_options()
        self.update_wifi_editor()

    def update_client_filter_options(self):
        ssids = {record.name for record in self.records if record.name}
        ssids.update(str(item.get("ssid")) for item in self.clients_data if item.get("ssid"))
        values = (self.t(ALL_SSIDS), *sorted(ssids, key=str.casefold))
        self.client_ssid_combo.configure(values=values)
        if self.client_ssid_var.get() not in values:
            self.client_ssid_var.set(self.t(ALL_SSIDS))

    def reset_client_filters(self):
        self.client_ssid_var.set(self.t(ALL_SSIDS))
        self.client_query_var.set("")
        self.client_state_var.set(self.t(ALL_STATES))
        self.client_signal_var.set(self.t(ALL_SIGNALS))
        self.client_band_var.set(self.t(ALL_BANDS))
        self.client_presence_var.set(self.t(ALL_PRESENCE))
        self.client_traffic_var.set(self.t(ALL_TRAFFIC))
        self.client_duration_var.set(self.t(ALL_DURATIONS))

    def update_client_summary(self):
        clients = normalize_clients(self.clients_data)
        online = sum(1 for item in clients if item.get("online", True))
        weak = sum(
            1 for item in clients
            if item.get("online", True)
            and item.get("signal_dbm") is not None
            and _finite_float(item.get("signal_dbm"), math.nan) < -70
        )
        blocked = sum(1 for item in clients if item.get("banned"))
        traffic = sum(
            _nonnegative_int(item.get("rx_bytes")) + _nonnegative_int(item.get("tx_bytes"))
            for item in clients
        )
        self.client_online_count_var.set(f"● {online} online")
        self.client_weak_count_var.set(f"● {weak} weak signal" if self.language == "en" else f"● {weak} tín hiệu yếu")
        self.client_blocked_count_var.set(f"● {blocked} blocked" if self.language == "en" else f"● {blocked} đã chặn")
        self.client_traffic_total_var.set(f"● {human_bytes(traffic)} total traffic" if self.language == "en" else f"● {human_bytes(traffic)} tổng lưu lượng")

    def sort_clients(self, column):
        if self.client_sort_column == column:
            self.client_sort_reverse = not self.client_sort_reverse
        else:
            self.client_sort_column = column
            self.client_sort_reverse = False
        self.render_clients()

    def render_clients(self):
        if not hasattr(self, "client_tree"):
            return
        self.visible_clients = filter_clients(
            self.clients_data,
            ssid=self.client_ssid_var.get(),
            query=self.client_query_var.get(),
            state=self.client_state_var.get(),
            signal=self.client_signal_var.get(),
            band=self.client_band_var.get(),
            presence=self.client_presence_var.get(),
            traffic=self.client_traffic_var.get(),
            duration=self.client_duration_var.get(),
        )
        self.visible_clients.sort(
            key=lambda item: client_sort_key(item, self.client_sort_column),
            reverse=self.client_sort_reverse,
        )
        for column, title in self.client_column_titles.items():
            marker = " ▼" if self.client_sort_reverse else " ▲"
            self.client_tree.heading(
                column,
                text=self.t(title) + marker if column == self.client_sort_column else self.t(title),
                command=lambda selected=column: self.sort_clients(selected),
            )
        self.client_rows = {}
        self.client_tree.delete(*self.client_tree.get_children())
        for pos, item in enumerate(self.visible_clients):
            iid = f"client-{pos}"
            self.client_rows[iid] = item
            signal = item.get("signal_dbm")
            online = bool(item.get("online", True))
            tag = "banned" if item.get("banned") else ("offline" if not online else "")
            if not tag and isinstance(signal, (int, float)):
                if signal < -70:
                    tag = "weak"
                elif signal >= -60:
                    tag = "strong"
            if online and item.get("banned"):
                status = "Online · blocked" if self.language == "en" else "Online · đã cấm"
            elif item.get("banned"):
                status = "Offline · blocked" if self.language == "en" else "Offline · đã cấm"
            elif online:
                status = "Online"
            else:
                status = "Offline"
            band = {"2g": "2.4G", "5g": "5G"}.get(str(item.get("band") or "").casefold(), item.get("band", ""))
            row_tag = "row_even" if pos % 2 == 0 else "row_odd"
            tags = (row_tag, tag) if tag else (row_tag,)
            self.client_tree.insert(
                "", "end", iid=iid, tags=tags,
                values=(
                    item.get("ssid", ""), band, item.get("ip", ""), item.get("host", ""),
                    item.get("mac", ""), human_time(item.get("connected_s")) if online else "—",
                    human_bytes(item.get("rx_bytes")), human_bytes(item.get("tx_bytes")),
                    f"{signal} dBm" if signal is not None else "—", status,
                ),
            )
        self.client_count_var.set(
            f"{len(self.visible_clients)} / {len(self.clients_data)} devices"
            if self.language == "en" else
            f"{len(self.visible_clients)} / {len(self.clients_data)} thiết bị"
        )
        self.update_client_editor()

    def schedule_client_refresh(self):
        if self.client_refresh_job:
            self.root.after_cancel(self.client_refresh_job)
            self.client_refresh_job = None
        if self.client_auto_var.get() and self.client:
            try:
                seconds = int(self.client_interval_var.get().rstrip("s"))
            except ValueError:
                seconds = 15
            self.client_refresh_job = self.root.after(seconds * 1000, self._auto_refresh_clients)

    def _auto_refresh_clients(self):
        self.client_refresh_job = None
        self.refresh_clients(auto=True)

    def toggle_client_auto_refresh(self):
        self.schedule_client_refresh()

    def refresh_clients(self, auto=False):
        if self.client_refreshing:
            return
        try:
            client = self.require_client()
        except AgentError:
            return
        self.client_refreshing = True
        def work():
            try:
                return client.clients()
            finally:
                self.root.after(0, self._finish_client_refresh)
        def done(payload):
            self.clients_data = normalize_clients(payload.get("clients"))
            self.update_client_filter_options()
            self.update_client_summary()
            self.render_clients()
            self.schedule_client_refresh()
        if auto:
            def auto_worker():
                try:
                    payload = work()
                except Exception as exc:
                    self.root.after(0, lambda error=exc: self._auto_client_error(error))
                    return
                self.root.after(0, lambda: done(payload))
            threading.Thread(target=auto_worker, daemon=True).start()
        else:
            self.run_task("Reading device list…" if self.language == "en" else "Đang đọc danh sách thiết bị…", work, done)

    def _finish_client_refresh(self):
        self.client_refreshing = False
        if self.client_auto_var.get() and not self.client_refresh_job:
            self.schedule_client_refresh()

    def _auto_client_error(self, exc):
        self.status_var.set(f"Auto-refresh error: {exc}" if self.language == "en" else f"Auto-refresh lỗi: {exc}")
        self.schedule_client_refresh()

    def selected_client_items(self):
        return [self.client_rows[iid] for iid in self.client_tree.selection() if iid in self.client_rows]

    def update_client_editor(self, _event=None):
        items = self.selected_client_items()
        if not items:
            self.client_selection_var.set(self.t("Chọn thiết bị trong bảng để điều khiển"))
            states = {key: "disabled" for key in self.client_edit_buttons}
        else:
            if len(items) == 1:
                item = items[0]
                label = item.get("host") or item.get("ip") or item.get("mac") or self.t("Thiết bị")
                self.client_selection_var.set(f"{label} · {item.get('ssid') or '—'}")
            else:
                self.client_selection_var.set(
                    f"Selected {len(items)} devices" if self.language == "en"
                    else f"Đã chọn {len(items)} thiết bị"
                )
            states = {
                "details": "normal" if len(items) == 1 else "disabled",
                "copy": "normal",
                "kick": "normal" if any(item.get("online", True) for item in items) else "disabled",
                "ban": "normal" if any(not item.get("banned") for item in items) else "disabled",
                "unban": "normal" if any(item.get("banned") for item in items) else "disabled",
            }
        for key, button in self.client_edit_buttons.items():
            button.configure(state=states.get(key, "disabled"))

    def select_all_clients(self, _event=None):
        self.client_tree.selection_set(self.client_tree.get_children())
        self.update_client_editor()
        return "break"

    def manual_ban_client(self):
        if self.block_if_incompatible():
            return
        if not self.records:
            messagebox.showinfo(APP_NAME, self.t("Chưa có SSID nào để áp dụng blocklist"), parent=self.root)
            return
        dialog = ManualBanDialog(self.root, self.records, self.language, self.palette)
        self.root.wait_window(dialog)
        if not dialog.result:
            return
        idx, mac = dialog.result
        record = next((item for item in self.records if item.idx == idx), None)
        target = record.name if record else idx
        if not self.confirm_important(
            "Thêm vào blocklist",
            f"Block MAC {mac} on SSID {target}." if self.language == "en" else f"Chặn MAC {mac} trên SSID {target}.",
            (
                "This device will lose access, and Wi-Fi networks on the same radio may reload briefly."
                if self.language == "en" else
                "Thiết bị này sẽ mất truy cập và Wi‑Fi cùng radio có thể reload ngắn."
            ),
        ):
            return
        try:
            client = self.require_client()
        except AgentError as exc:
            self._task_error(exc)
            return
        def done(payload):
            self.append_log(payload.get("log", f"Blocked {mac}" if self.language == "en" else f"Đã chặn {mac}"))
            self.refresh_clients()
        self.run_task(
            f"Adding {mac} to the blocklist…" if self.language == "en" else f"Đang thêm {mac} vào blocklist…",
            lambda: client.client_action("ban", idx, mac),
            done,
            show_loading=True,
            timeout_hint=45,
        )

    def client_action(self, action):
        if self.block_if_incompatible():
            return
        items = self.selected_client_items()
        if not items:
            messagebox.showinfo(APP_NAME, self.t("Hãy chọn một hoặc nhiều thiết bị"), parent=self.root)
            return
        if action == "kick":
            online_items = [item for item in items if item.get("online", True)]
            if not online_items:
                messagebox.showinfo(APP_NAME, self.t("Các thiết bị đã chọn đều offline"), parent=self.root)
                return
            items = online_items
        if action == "unban":
            items = [item for item in items if item.get("banned")]
            if not items:
                messagebox.showinfo(APP_NAME, self.t("Không có thiết bị bị cấm trong lựa chọn"), parent=self.root)
                return
        if action == "ban":
            items = [item for item in items if not item.get("banned")]
            if not items:
                messagebox.showinfo(APP_NAME, self.t("Các thiết bị đã chọn đều đã bị cấm"), parent=self.root)
                return
        if self.language == "en":
            labels = {"kick": "disconnect", "ban": "block", "unban": "unblock"}
            impacts = {
                "kick": "The devices will disconnect immediately but may reconnect automatically.",
                "ban": "The MAC addresses will be added to the blocklist and lose access; related Wi-Fi networks may reload briefly.",
                "unban": "The MAC addresses will be removed from the blocklist; related Wi-Fi networks may reload briefly.",
            }
            action_text = f"{labels[action].capitalize()} {len(items)} selected devices."
        else:
            labels = {"kick": "kick", "ban": "cấm", "unban": "bỏ cấm"}
            impacts = {
                "kick": "Các thiết bị sẽ bị ngắt kết nối ngay nhưng có thể tự kết nối lại.",
                "ban": "Các MAC sẽ vào blocklist, mất truy cập; Wi‑Fi liên quan có thể reload ngắn.",
                "unban": "Các MAC sẽ được gỡ khỏi blocklist; Wi‑Fi liên quan có thể reload ngắn.",
            }
            action_text = f"{labels[action].capitalize()} {len(items)} thiết bị đã chọn."
        if not self.confirm_important(
            labels[action].capitalize(),
            action_text,
            impacts[action],
        ):
            return
        client = self.require_client()
        def work():
            logs, failures = [], []
            for item in items:
                try:
                    payload = client.client_action(action, item["idx"], item["mac"])
                    fallback = (
                        f"Successfully {labels[action]}ed {item['mac']}"
                        if self.language == "en" else
                        f"{labels[action]} {item['mac']} thành công"
                    )
                    logs.append(payload.get("log", fallback))
                except Exception as exc:
                    failures.append(f"{item.get('mac')}: {exc}")
            return logs, failures
        def done(result):
            logs, failures = result
            no_success = (
                f"No device was successfully {labels[action]}ed"
                if self.language == "en" else
                f"Không có thiết bị nào {labels[action]} thành công"
            )
            self.append_log("\n".join(logs) if logs else no_success)
            if failures:
                self.append_log(("ERROR:\n" if self.language == "en" else "LỖI:\n") + "\n".join(failures))
                warning = (
                    f"Completed with {len(failures)} errors. See the log."
                    if self.language == "en" else
                    f"Hoàn tất với {len(failures)} lỗi. Xem nhật ký."
                )
                messagebox.showwarning(APP_NAME, warning, parent=self.root)
            self.refresh_clients()
        self.run_task(
            (
                f"Processing {labels[action]} for {len(items)} devices…"
                if self.language == "en" else
                f"Đang {labels[action]} {len(items)} thiết bị…"
            ),
            work,
            done,
            show_loading=len(items) > 1,
            timeout_hint=min(300, 45 * len(items)),
        )

    def copy_selected_clients(self):
        items = self.selected_client_items()
        if not items:
            messagebox.showinfo(APP_NAME, self.t("Hãy chọn thiết bị cần copy"), parent=self.root)
            return
        text = "\n".join(
            f"{item.get('ip') or '-'}\t{item.get('mac') or '-'}\t{item.get('host') or '-'}"
            for item in items
        )
        self.root.clipboard_clear()
        self.root.clipboard_append(text)
        self.status_var.set(
            f"Copied IP/MAC for {len(items)} devices"
            if self.language == "en" else
            f"Đã copy IP/MAC của {len(items)} thiết bị"
        )

    def export_clients_csv(self):
        path = filedialog.asksaveasfilename(
            parent=self.root,
            title="Export filtered devices" if self.language == "en" else "Xuất danh sách thiết bị đang lọc",
            defaultextension=".csv",
            filetypes=(("CSV UTF-8", "*.csv"), (self.t("Tất cả file"), "*.*")),
            initialfile="sbproxy-clients.csv",
        )
        if not path:
            return
        try:
            with open(path, "w", encoding="utf-8-sig", newline="") as handle:
                writer = csv.writer(handle)
                writer.writerow(("ssid", "band", "online", "banned", "ip", "host", "mac", "connected_s", "rx_bytes", "tx_bytes", "signal_dbm"))
                for item in self.visible_clients:
                    writer.writerow(tuple(item.get(key, "") for key in ("ssid", "band", "online", "banned", "ip", "host", "mac", "connected_s", "rx_bytes", "tx_bytes", "signal_dbm")))
        except OSError as exc:
            messagebox.showerror(self.t("Không xuất được CSV"), str(exc), parent=self.root)
            return
        self.status_var.set(
            f"Exported {len(self.visible_clients)} devices"
            if self.language == "en" else
            f"Đã xuất {len(self.visible_clients)} thiết bị"
        )

    def show_client_details(self, event=None):
        if event is not None:
            row = self.client_tree.identify_row(event.y)
            if row:
                self.client_tree.selection_set(row)
        items = self.selected_client_items()
        if not items:
            return
        item = items[0]
        total = _nonnegative_int(item.get("rx_bytes")) + _nonnegative_int(item.get("tx_bytes"))
        if self.language == "en":
            details = (
                f"SSID: {item.get('ssid') or '—'} ({item.get('band') or '—'})\n"
                f"Status: {'Online' if item.get('online', True) else 'Offline'}"
                f"{' · Blocked' if item.get('banned') else ''}\n"
                f"Hostname: {item.get('host') or '—'}\nIP: {item.get('ip') or '—'}\n"
                f"MAC: {item.get('mac') or '—'}\nInterface: {item.get('ifname') or '—'}\n"
                f"Signal: {item.get('signal_dbm') if item.get('signal_dbm') is not None else '—'} dBm\n"
                f"Connected: {human_time(item.get('connected_s')) if item.get('online', True) else '—'}\n"
                f"RX / TX: {human_bytes(item.get('rx_bytes'))} / {human_bytes(item.get('tx_bytes'))}\n"
                f"Total: {human_bytes(total)}"
            )
        else:
            details = (
                f"SSID: {item.get('ssid') or '—'} ({item.get('band') or '—'})\n"
                f"Trạng thái: {'Online' if item.get('online', True) else 'Offline'}"
                f"{' · Đã cấm' if item.get('banned') else ''}\n"
                f"Tên máy: {item.get('host') or '—'}\nIP: {item.get('ip') or '—'}\n"
                f"MAC: {item.get('mac') or '—'}\nInterface: {item.get('ifname') or '—'}\n"
                f"Tín hiệu: {item.get('signal_dbm') if item.get('signal_dbm') is not None else '—'} dBm\n"
                f"Kết nối: {human_time(item.get('connected_s')) if item.get('online', True) else '—'}\n"
                f"RX / TX: {human_bytes(item.get('rx_bytes'))} / {human_bytes(item.get('tx_bytes'))}\n"
                f"Tổng: {human_bytes(total)}"
            )
        messagebox.showinfo(self.t("Chi tiết thiết bị"), details, parent=self.root)

    def refresh_backups(self):
        try:
            client = self.require_client()
        except AgentError:
            return
        def done(payload):
            self.backup_names = normalize_backup_names(payload.get("backups"))
            self.backup_list.delete(0, "end")
            for name in self.backup_names:
                self.backup_list.insert("end", name)
            self.update_backup_editor()
        self.run_task("Đang đọc backup…", client.backups, done)

    def update_backup_editor(self, _event=None):
        selected = self.backup_list.curselection()
        if selected:
            name = self.backup_list.get(selected[0])
            self.backup_selection_var.set(f"Selected: {name}" if self.language == "en" else f"Đang chọn: {name}")
            self.rollback_button.configure(state="normal")
        else:
            self.backup_selection_var.set(
                "Select a backup to restore" if self.language == "en" else "Chọn một backup để khôi phục"
            )
            self.rollback_button.configure(state="disabled")

    def create_backup(self):
        if self.block_if_incompatible():
            return
        client = self.require_client()
        label = simpledialog.askstring(self.t("Tạo backup"), self.t("Nhãn backup"), initialvalue="native", parent=self.root)
        if label is None:
            return
        if not re.fullmatch(r"[A-Za-z0-9._-]+", label):
            messagebox.showerror(APP_NAME, self.t("Nhãn chỉ được chứa chữ, số, dấu . _ -"), parent=self.root)
            return
        def done(payload):
            self.append_log(payload.get("log", "Backup succeeded" if self.language == "en" else "Backup thành công"))
            self.refresh_backups()
        self.run_task("Đang tạo backup…", lambda: client.backup(label), done)

    def rollback(self):
        if self.block_if_incompatible():
            return
        selected = self.backup_list.curselection()
        if not selected:
            messagebox.showinfo(APP_NAME, self.t("Hãy chọn một backup"), parent=self.root)
            return
        name = self.backup_list.get(selected[0])
        if not self.confirm_important(
            "Rollback",
            f"Restore the router from backup {name}." if self.language == "en" else f"Khôi phục router từ backup {name}.",
            (
                "The current configuration will be replaced. The router and Wi-Fi will reload, interrupting all connections during recovery."
                if self.language == "en" else
                "Cấu hình hiện tại sẽ bị thay thế. Router và Wi‑Fi sẽ reload, làm gián đoạn toàn bộ kết nối trong lúc khôi phục."
            ),
        ):
            return
        client = self.require_client()
        def done(payload):
            self.append_log(payload.get("log", "Rollback succeeded" if self.language == "en" else "Rollback thành công"))
            self.status_var.set(
                "Rollback completed; waiting for the router"
                if self.language == "en" else
                "Rollback hoàn tất; đang chờ router"
            )
            self.root.after(7000, self.connect)
        self.run_task("Đang rollback…", lambda: client.rollback(name), done)


def probe_saved_connection() -> bool:
    base_url, token = load_connection()
    if not token:
        return False
    try:
        return bool(AgentClient(base_url, token, timeout=10).status().get("ok"))
    except Exception:
        return False


def main() -> int:
    if os.environ.get("SBPROXY_ASKPASS") == "1":
        # ssh called us as its askpass helper; answer on stdout and exit.
        return write_askpass_answer(os.environ.get("SBPROXY_SSH_PASSWORD", ""))
    setup_logging(verbose="--verbose" in sys.argv)
    install_exception_logging()
    migrate_legacy_config()
    if "--where" in sys.argv:
        # write_stdout, not print: a windowed build has no sys.stdout.
        write_stdout(
            f"home={APP_HOME}\nconfig={CONFIG_FILE}\nlogs={LOG_DIR}\n"
            f"runtime={RUNTIME_DIR}\npayload={find_payload() or '—'}\n"
        )
        return 0
    provisioned = provision_from_environment()
    if "--provision" in sys.argv:
        return 0 if provisioned else 2
    if "--probe" in sys.argv:
        return 0 if probe_saved_connection() else 1
    root = tk.Tk()
    NativeApp(root)
    root.mainloop()
    log.info("exit normally")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
