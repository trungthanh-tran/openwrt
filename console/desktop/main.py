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
import os
from pathlib import Path
import re
import sys
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, simpledialog, ttk
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


APP_NAME = "sbproxy Console Native"
DEFAULT_BASE = "http://192.168.8.1"
CONFIG_DIR = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "sbproxy-console-native"
CONFIG_FILE = CONFIG_DIR / "connection.json"

PALETTE = {
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
}

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
        if label == vendor_label(oui):
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


def save_connection(base_url: str, token: str) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        "base_url": base_url.strip().rstrip("/"),
        "token_dpapi": _dpapi_protect(token.strip()),
    }
    temp = CONFIG_FILE.with_suffix(".tmp")
    temp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    temp.replace(CONFIG_FILE)


def load_connection() -> tuple[str, str]:
    if not CONFIG_FILE.exists():
        return DEFAULT_BASE, ""
    try:
        payload = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        return (
            str(payload.get("base_url") or DEFAULT_BASE).rstrip("/"),
            _dpapi_unprotect(str(payload.get("token_dpapi") or "")),
        )
    except Exception:
        return DEFAULT_BASE, ""


def provision_from_environment() -> bool:
    token = os.environ.get("SBPROXY_TOKEN", "").strip()
    if not token:
        return False
    base_url = os.environ.get("SBPROXY_BASE", DEFAULT_BASE).strip().rstrip("/")
    save_connection(base_url, token)
    os.environ.pop("SBPROXY_TOKEN", None)
    return True


class AgentClient:
    def __init__(self, base_url: str, token: str, timeout: int = 30):
        self.base_url = base_url.strip().rstrip("/")
        self.token = token.strip()
        self.timeout = timeout

    def _request(self, action: str, method: str = "GET", body=None, text=False, timeout=None):
        url = f"{self.base_url}/cgi-bin/sbproxy?{urlencode({'action': action})}"
        request_timeout = timeout if timeout is not None else self.timeout
        data = None
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/json"}
        if body is not None:
            if isinstance(body, str):
                data = body.encode("utf-8")
                headers["Content-Type"] = "text/plain; charset=utf-8"
            else:
                data = json.dumps(body).encode("utf-8")
                headers["Content-Type"] = "application/json"
        request = Request(url, data=data, headers=headers, method=method)
        try:
            with urlopen(request, timeout=request_timeout) as response:
                raw = response.read()
        except HTTPError as exc:
            raw = exc.read()
            try:
                detail = json.loads(raw.decode("utf-8")).get("error")
            except Exception:
                detail = raw.decode("utf-8", "replace") or str(exc)
            raise AgentError(f"HTTP {exc.code}: {detail}") from exc
        except (URLError, TimeoutError, OSError) as exc:
            raise AgentError(f"Không kết nối được {self.base_url} trong {request_timeout}s: {exc}") from exc

        decoded = raw.decode("utf-8", "replace")
        if text:
            return decoded
        try:
            payload = json.loads(decoded)
        except json.JSONDecodeError as exc:
            raise AgentError("Agent trả dữ liệu không phải JSON") from exc
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
        return cls(
            name=columns[0], band=columns[1].strip(), idx=int(columns[2].strip()),
            wifi_password=columns[3], host=columns[4].strip(),
            port=int(columns[5].strip()), user=columns[6], socks_password=columns[7],
            isolate=columns[8].strip() == "1", webrtc=columns[9].strip() == "1",
            mac_oui=columns[10].strip(),
        )

    def validate(self) -> None:
        values = [self.name, self.wifi_password, self.host, self.user, self.socks_password]
        if any("|" in value or "\n" in value or "\r" in value for value in values):
            raise ValueError("Các trường không được chứa | hoặc xuống dòng")
        if not 1 <= len(self.name) <= 32:
            raise ValueError("SSID phải dài 1–32 ký tự")
        if self.band not in ("2g", "5g"):
            raise ValueError("Băng tần phải là 2g hoặc 5g")
        if not 1 <= self.idx <= 200:
            raise ValueError("IDX phải từ 1 đến 200")
        if not 8 <= len(self.wifi_password) <= 63:
            raise ValueError("Mật khẩu Wi‑Fi phải dài 8–63 ký tự")
        if not self.host:
            raise ValueError("Thiếu địa chỉ SOCKS5")
        if not 1 <= self.port <= 65535:
            raise ValueError("Port SOCKS5 không hợp lệ")
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
    for line in content.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        records.append(WifiRecord.from_row(line))
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


def human_bytes(value) -> str:
    size = float(value or 0)
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return "0 B"


def human_time(seconds) -> str:
    seconds = int(seconds or 0)
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
    for item in clients:
        if ssid != ALL_SSIDS and str(item.get("ssid") or "") != ssid:
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
        if state == "Đang cấm" and not banned:
            continue
        if state == "Không cấm" and banned:
            continue
        raw_signal = item.get("signal_dbm")
        try:
            signal_dbm = float(raw_signal) if raw_signal is not None else None
        except (TypeError, ValueError):
            signal_dbm = None
        if signal == "Rất tốt (≥ -60 dBm)" and (signal_dbm is None or signal_dbm < -60):
            continue
        if signal == "Tốt (-70 đến -61 dBm)" and (
            signal_dbm is None or signal_dbm < -70 or signal_dbm >= -60
        ):
            continue
        if signal == "Yếu (-80 đến -71 dBm)" and (
            signal_dbm is None or signal_dbm < -80 or signal_dbm >= -70
        ):
            continue
        if signal == "Rất yếu (< -80 dBm)" and (signal_dbm is None or signal_dbm >= -80):
            continue
        if signal == "Không rõ" and signal_dbm is not None:
            continue
        total_bytes = int(item.get("rx_bytes") or 0) + int(item.get("tx_bytes") or 0)
        if traffic == "Có lưu lượng" and total_bytes <= 0:
            continue
        if traffic == "Không lưu lượng" and total_bytes > 0:
            continue
        if traffic == "Từ 10 MB" and total_bytes < 10 * 1024 * 1024:
            continue
        if traffic == "Từ 100 MB" and total_bytes < 100 * 1024 * 1024:
            continue
        connected = int(item.get("connected_s") or 0)
        if duration == "Dưới 5 phút" and not (online and connected < 300):
            continue
        if duration == "5–60 phút" and not (online and 300 <= connected <= 3600):
            continue
        if duration == "Trên 1 giờ" and not (online and connected > 3600):
            continue
        result.append(item)
    return result


def client_sort_key(item, column):
    if column == "ip":
        try:
            return int(ipaddress.ip_address(item.get("ip") or "0.0.0.0"))
        except ValueError:
            return -1
    if column == "time":
        return int(item.get("connected_s") or 0)
    if column == "rx":
        return int(item.get("rx_bytes") or 0)
    if column == "tx":
        return int(item.get("tx_bytes") or 0)
    if column == "signal":
        return float(item.get("signal_dbm")) if item.get("signal_dbm") is not None else -999.0
    if column == "status":
        return (not bool(item.get("online", True)), bool(item.get("banned")))
    return str(item.get(column) or "").casefold()


class WifiDialog(tk.Toplevel):
    def __init__(self, parent, record: WifiRecord | None, next_idx: int):
        super().__init__(parent)
        self.title("Sửa Wi‑Fi" if record else "Thêm Wi‑Fi")
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
            messagebox.showerror("Dữ liệu không hợp lệ", str(exc), parent=self)
            return
        self.result = result
        self.destroy()


class RandomMacDialog(tk.Toplevel):
    def __init__(self, parent, record: WifiRecord, current_mac: str):
        super().__init__(parent)
        self.title(f"Random MAC · {record.name}")
        self.resizable(False, False)
        self.transient(parent)
        self.grab_set()
        self.configure(bg=PALETTE["bg"])
        self.result = None
        self.vendor_var = tk.StringVar(value=vendor_label(record.mac_oui))
        self.preview_var = tk.StringVar()

        body = ttk.Frame(self, style="Card.TFrame", padding=18)
        body.grid(sticky="nsew")
        ttk.Label(body, text="Chọn hãng router", font=("Segoe UI Semibold", 13)).grid(row=0, column=0, columnspan=2, sticky="w")
        ttk.Label(body, text=f"SSID: {record.name}  ·  MAC hiện tại: {current_mac}", style="Muted.TLabel").grid(row=1, column=0, columnspan=2, sticky="w", pady=(4, 14))
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

    def _update_preview(self):
        try:
            oui = vendor_oui(self.vendor_var.get())
        except ValueError:
            self.preview_var.set("OUI không hợp lệ")
            return
        pattern = f"{oui}:xx:xx:xx" if oui else "02:xx:xx:xx:xx:xx"
        self.preview_var.set(f"Mẫu MAC mới: {pattern}")

    def _submit(self):
        try:
            self.result = vendor_oui(self.vendor_var.get())
        except ValueError as exc:
            messagebox.showerror("Provider không hợp lệ", str(exc), parent=self)
            return
        self.destroy()


class ManualBanDialog(tk.Toplevel):
    def __init__(self, parent, records):
        super().__init__(parent)
        self.title("Thêm MAC vào blocklist")
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

    def _submit(self):
        mac = self.mac_var.get().strip().lower()
        if not re.fullmatch(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", mac):
            messagebox.showerror("MAC không hợp lệ", "MAC phải có dạng AA:BB:CC:DD:EE:FF", parent=self)
            return
        idx = self.choices.get(self.ssid_var.get())
        if idx is None:
            messagebox.showerror("Thiếu SSID", "Hãy chọn SSID cần chặn", parent=self)
            return
        self.result = idx, mac
        self.destroy()


class LoadingWindow(tk.Toplevel):
    """Modal progress window used while a background router mutation runs."""

    def __init__(self, parent, title: str, timeout_hint: int | None = None):
        super().__init__(parent)
        self.title("sbproxy · Đang xử lý")
        self.resizable(False, False)
        self.transient(parent)
        self.configure(bg=PALETTE["bg"])
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
        self._tick()

    def _tick(self):
        if not self.winfo_exists():
            return
        elapsed = int(time.monotonic() - self.started)
        if self.timeout_hint:
            self.elapsed_var.set(f"Đã chạy {elapsed}s · giới hạn tối đa khoảng {self.timeout_hint}s")
        else:
            self.elapsed_var.set(f"Đã chạy {elapsed}s")
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


class NativeApp:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title(APP_NAME)
        self.root.geometry("1380x840")
        self.root.minsize(1100, 700)
        self.client: AgentClient | None = None
        self.records: list[WifiRecord] = []
        self.clients_data = []
        self.visible_clients = []
        self.client_rows = {}
        self.health = {}
        self.runtime_ssids = {}
        self.loading_window: LoadingWindow | None = None
        base, token = load_connection()
        self.base_var = tk.StringVar(value=base)
        self.token_var = tk.StringVar(value=token)
        self.status_var = tk.StringVar(value="Chưa kết nối")
        self.client_ssid_var = tk.StringVar(value=ALL_SSIDS)
        self.client_query_var = tk.StringVar()
        self.client_state_var = tk.StringVar(value=ALL_STATES)
        self.client_signal_var = tk.StringVar(value=ALL_SIGNALS)
        self.client_band_var = tk.StringVar(value=ALL_BANDS)
        self.client_presence_var = tk.StringVar(value=ALL_PRESENCE)
        self.client_traffic_var = tk.StringVar(value=ALL_TRAFFIC)
        self.client_duration_var = tk.StringVar(value=ALL_DURATIONS)
        self.client_count_var = tk.StringVar(value="0 thiết bị")
        self.client_online_count_var = tk.StringVar(value="0 online")
        self.client_weak_count_var = tk.StringVar(value="0 tín hiệu yếu")
        self.client_blocked_count_var = tk.StringVar(value="0 đã chặn")
        self.client_traffic_total_var = tk.StringVar(value="0 B tổng lưu lượng")
        self.gateway_state_var = tk.StringVar(value="● Gateway chưa kiểm tra")
        self.gateway_route_var = tk.StringVar(value="Đường ra: —")
        self.gateway_link_var = tk.StringVar(value="Link/DNS: —")
        self.gateway_http_var = tk.StringVar(value="Internet HTTP: —")
        self.wifi_selection_var = tk.StringVar(value="Chọn một SSID trong bảng để chỉnh sửa")
        self.client_selection_var = tk.StringVar(value="Chọn thiết bị trong bảng để điều khiển")
        self.backup_selection_var = tk.StringVar(value="Chọn một backup để khôi phục")
        self.client_auto_var = tk.BooleanVar(value=True)
        self.client_interval_var = tk.StringVar(value="15s")
        self.client_refresh_job = None
        self.client_refreshing = False
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
            self.root.after(350, self.connect)

    def _configure_styles(self):
        self.root.configure(bg=PALETTE["bg"])
        self.root.option_add("*Font", ("Segoe UI", 10))
        style = ttk.Style(self.root)
        style.theme_use("clam")
        style.configure("TFrame", background=PALETTE["card"])
        style.configure("Header.TFrame", background=PALETTE["header"])
        style.configure("Card.TFrame", background=PALETTE["card"])
        style.configure("Toolbar.TFrame", background=PALETTE["header"])
        style.configure("TLabel", background=PALETTE["card"], foreground=PALETTE["text"])
        style.configure("Header.TLabel", background=PALETTE["header"], foreground=PALETTE["text"])
        style.configure("Title.TLabel", background=PALETTE["header"], foreground=PALETTE["text"], font=("Segoe UI Semibold", 19))
        style.configure("Subtitle.TLabel", background=PALETTE["header"], foreground=PALETTE["muted"], font=("Segoe UI", 9))
        style.configure("Status.TLabel", background=PALETTE["header"], foreground="#67e8f9", font=("Segoe UI Semibold", 10))
        style.configure("Muted.TLabel", background=PALETTE["card"], foreground=PALETTE["muted"])
        style.configure("Toolbar.TLabel", background=PALETTE["header"], foreground=PALETTE["muted"])
        style.configure("Count.TLabel", background=PALETTE["header"], foreground="#67e8f9", font=("Segoe UI Semibold", 10))
        style.configure("Metric.TFrame", background="#0d1b2e")
        style.configure("MetricBlue.TLabel", background="#0d1b2e", foreground="#67e8f9", font=("Segoe UI Semibold", 11))
        style.configure("MetricGreen.TLabel", background="#0d1b2e", foreground="#7ee7b8", font=("Segoe UI Semibold", 11))
        style.configure("MetricYellow.TLabel", background="#0d1b2e", foreground="#facc73", font=("Segoe UI Semibold", 11))
        style.configure("MetricRed.TLabel", background="#0d1b2e", foreground="#ff8da1", font=("Segoe UI Semibold", 11))
        style.configure("TButton", background="#263a55", foreground=PALETTE["text"], borderwidth=0, padding=(12, 8), font=("Segoe UI Semibold", 9))
        style.map("TButton", background=[("active", "#334b6b"), ("pressed", "#1d2d45")])
        for name, color, active in (
            ("Primary", PALETTE["primary"], PALETTE["primary_active"]),
            ("Success", PALETTE["success"], PALETTE["success_active"]),
            ("Warning", PALETTE["warning"], PALETTE["warning_active"]),
            ("Danger", PALETTE["danger"], PALETTE["danger_active"]),
        ):
            style.configure(f"{name}.TButton", background=color, foreground="white", borderwidth=0, padding=(13, 8), font=("Segoe UI Semibold", 9))
            style.map(f"{name}.TButton", background=[("active", active), ("pressed", active)])
        style.configure("TEntry", fieldbackground=PALETTE["input"], foreground=PALETTE["text"], bordercolor=PALETTE["border"], lightcolor=PALETTE["border"], darkcolor=PALETTE["border"], padding=7)
        style.configure("TCombobox", fieldbackground=PALETTE["input"], background=PALETTE["input"], foreground=PALETTE["text"], arrowcolor=PALETTE["muted"], bordercolor=PALETTE["border"], padding=6)
        style.map("TCombobox", fieldbackground=[("readonly", PALETTE["input"])], foreground=[("readonly", PALETTE["text"])])
        style.configure("TCheckbutton", background=PALETTE["card"], foreground=PALETTE["text"], indicatorcolor=PALETTE["input"], padding=3)
        style.map("TCheckbutton", background=[("active", PALETTE["card"])], indicatorcolor=[("selected", PALETTE["primary"])])
        style.configure("Toolbar.TCheckbutton", background=PALETTE["header"], foreground=PALETTE["text"], indicatorcolor=PALETTE["input"], padding=3)
        style.map("Toolbar.TCheckbutton", background=[("active", PALETTE["header"])], indicatorcolor=[("selected", PALETTE["primary"])])
        style.configure("TNotebook", background=PALETTE["bg"], borderwidth=0, tabmargins=(0, 0, 0, 8))
        style.configure("TNotebook.Tab", background=PALETTE["header"], foreground=PALETTE["muted"], borderwidth=0, padding=(18, 10), font=("Segoe UI Semibold", 10))
        style.map("TNotebook.Tab", background=[("selected", PALETTE["primary"]), ("active", "#1d3555")], foreground=[("selected", "white"), ("active", "white")])
        style.configure("Treeview", background=PALETTE["input"], fieldbackground=PALETTE["input"], foreground=PALETTE["text"], borderwidth=0, rowheight=32, font=("Segoe UI", 9))
        style.configure("Treeview.Heading", background="#1a2b43", foreground="#c7d7eb", borderwidth=0, padding=(8, 8), font=("Segoe UI Semibold", 9))
        style.map("Treeview", background=[("selected", PALETTE["primary"])], foreground=[("selected", "white")])
        style.map("Treeview.Heading", background=[("active", "#223956")])
        style.configure("Vertical.TScrollbar", background="#263a55", troughcolor=PALETTE["input"], borderwidth=0)
        style.configure("Horizontal.TScrollbar", background="#263a55", troughcolor=PALETTE["input"], borderwidth=0)

    def _build_ui(self):
        header = ttk.Frame(self.root, style="Header.TFrame", padding=(18, 13))
        header.pack(fill="x")
        brand = ttk.Frame(header, style="Header.TFrame")
        brand.pack(side="left")
        ttk.Label(brand, text="sbproxy", style="Title.TLabel").pack(anchor="w")
        ttk.Label(brand, text="OPENWRT · MULTI-SSID SOCKS5 CONTROL CENTER", style="Subtitle.TLabel").pack(anchor="w")
        ttk.Label(header, textvariable=self.status_var, style="Status.TLabel").pack(side="right", padx=(20, 0))

        top = ttk.Frame(self.root, style="Card.TFrame", padding=(14, 12))
        top.pack(fill="x", padx=14, pady=(12, 8))
        ttk.Label(top, text="Router").grid(row=0, column=0, sticky="w")
        ttk.Entry(top, textvariable=self.base_var, width=31).grid(row=0, column=1, padx=(8, 18), sticky="ew")
        ttk.Label(top, text="Agent token").grid(row=0, column=2, sticky="w")
        ttk.Entry(top, textvariable=self.token_var, show="•", width=37).grid(row=0, column=3, padx=(8, 18), sticky="ew")
        ttk.Button(top, text="Kết nối", command=self.connect, style="Primary.TButton").grid(row=0, column=4, padx=4)
        ttk.Button(top, text="Làm mới", command=self.refresh_all).grid(row=0, column=5, padx=(4, 0))
        top.columnconfigure(1, weight=1)
        top.columnconfigure(3, weight=1)

        gateway = ttk.Frame(self.root, style="Metric.TFrame", padding=(14, 10))
        gateway.pack(fill="x", padx=14, pady=(0, 8))
        gateway_head = ttk.Frame(gateway, style="Metric.TFrame")
        gateway_head.pack(fill="x")
        ttk.Label(gateway_head, text="INTERNET GATEWAY", style="MetricBlue.TLabel").pack(side="left", padx=(0, 18))
        self.gateway_state_label = ttk.Label(gateway_head, textvariable=self.gateway_state_var, style="MetricBlue.TLabel")
        self.gateway_state_label.pack(side="left")
        ttk.Button(gateway_head, text="Kiểm tra gateway", command=self.refresh_gateway, style="Primary.TButton").pack(side="right")
        gateway_detail = ttk.Frame(gateway, style="Metric.TFrame")
        gateway_detail.pack(fill="x", pady=(7, 0))
        ttk.Label(gateway_detail, textvariable=self.gateway_route_var, style="MetricBlue.TLabel").pack(side="left", padx=(0, 28))
        ttk.Label(gateway_detail, textvariable=self.gateway_link_var, style="MetricBlue.TLabel").pack(side="left", padx=(0, 28))
        ttk.Label(gateway_detail, textvariable=self.gateway_http_var, style="MetricBlue.TLabel").pack(side="left")

        self.tabs = ttk.Notebook(self.root)
        self.tabs.pack(fill="both", expand=True, padx=14, pady=(6, 14))
        self._build_wifi_tab()
        self._build_clients_tab()
        self._build_backup_tab()

    def _tree(self, parent, columns, widths, selectmode="browse"):
        frame = ttk.Frame(parent, style="Card.TFrame")
        frame.pack(fill="both", expand=True)
        tree = ttk.Treeview(frame, columns=tuple(columns), show="headings", selectmode=selectmode)
        for name, title in columns.items():
            tree.heading(name, text=title)
            tree.column(name, width=widths.get(name, 100), anchor="w")
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
        self.wifi_tree = self._tree(tab, columns, {"idx": 50, "name": 150, "band": 55, "subnet": 130, "mac": 220, "socks": 195, "isolate": 70, "webrtc": 75, "health": 100})
        self.wifi_tree.tag_configure("healthy", foreground="#7ee7b8")
        self.wifi_tree.tag_configure("warning", foreground="#facc73")
        self.wifi_tree.tag_configure("error", foreground="#ff8da1")
        self.wifi_tree.bind("<Double-1>", lambda _event: self.edit_wifi())
        self.wifi_tree.bind("<<TreeviewSelect>>", self.update_wifi_editor)

        editor = ttk.Frame(tab, style="Toolbar.TFrame", padding=9)
        editor.pack(fill="x", pady=(8, 0))
        ttk.Label(editor, text="CHỈNH SỬA SSID ĐANG CHỌN", style="Count.TLabel").pack(side="left", padx=(0, 12))
        ttk.Label(editor, textvariable=self.wifi_selection_var, style="Toolbar.TLabel").pack(side="left", fill="x", expand=True)
        for key, text, command, button_style in (
            ("edit", "Sửa cấu hình", self.edit_wifi, "TButton"),
            ("sock", "Đổi SOCKS", self.quick_sock, "Primary.TButton"),
            ("mac", "Random MAC", self.rotate_wifi_mac, "Warning.TButton"),
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
        self.client_tree.tag_configure("banned", foreground="#ff8da1")
        self.client_tree.tag_configure("offline", foreground="#7f91aa")
        self.client_tree.tag_configure("weak", foreground="#facc73")
        self.client_tree.tag_configure("strong", foreground="#7ee7b8")
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
        self.backup_list = tk.Listbox(left, width=40, height=25, bg=PALETTE["input"], fg=PALETTE["text"], selectbackground=PALETTE["primary"], selectforeground="white", borderwidth=0, highlightthickness=1, highlightbackground=PALETTE["border"], font=("Segoe UI", 10))
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
        self.log = tk.Text(right, wrap="word", state="disabled", bg=PALETTE["input"], fg="#c9d8ec", insertbackground="white", borderwidth=0, highlightthickness=1, highlightbackground=PALETTE["border"], padx=10, pady=10, font=("Cascadia Mono", 9))
        self.log.pack(fill="both", expand=True, pady=(5, 0))

    def append_log(self, text):
        self.log.configure(state="normal")
        self.log.insert("end", str(text).rstrip() + "\n\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def show_loading(self, label, timeout_hint=None):
        self.hide_loading()
        self.loading_window = LoadingWindow(self.root, label, timeout_hint)

    def update_loading(self, detail):
        def update():
            if self.loading_window and self.loading_window.winfo_exists():
                self.loading_window.set_detail(detail)
        self.root.after(0, update)

    def hide_loading(self):
        if self.loading_window:
            self.loading_window.close()
            self.loading_window = None

    def run_task(self, label, function, success=None, show_loading=False, timeout_hint=None):
        self.status_var.set(label)
        if show_loading:
            self.show_loading(label, timeout_hint)
        def worker():
            try:
                result = function()
            except Exception as exc:
                self.root.after(0, lambda: self._task_error(exc))
                return
            self.root.after(0, lambda: self._task_success(result, success))
        threading.Thread(target=worker, daemon=True).start()

    def _task_error(self, exc):
        self.hide_loading()
        self.status_var.set(f"Lỗi: {exc}")
        self.append_log(f"LỖI: {exc}")
        messagebox.showerror("sbproxy", str(exc), parent=self.root)

    def _task_success(self, result, callback):
        self.hide_loading()
        self.status_var.set("Hoàn tất")
        if callback:
            callback(result)

    def confirm_important(self, title, action, impact):
        """Require an explicit, default-deny confirmation before router mutations."""
        message = (
            "CẢNH BÁO · TÁC VỤ QUAN TRỌNG\n\n"
            f"Thao tác:\n{action}\n\n"
            f"Ảnh hưởng có thể xảy ra:\n{impact}\n\n"
            "Chỉ tiếp tục khi bạn đã kiểm tra đúng SSID/thiết bị và chấp nhận ảnh hưởng."
        )
        return messagebox.askyesno(
            f"Cảnh báo — {title}",
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
            self.health = ((status.get("health") or {}).get("probes") or {})
            self.capture_runtime_ssids(status)
            self.render_gateway(gateway)
            running = bool((status.get("meta") or {}).get("singbox_running"))
            self.status_var.set(f"Đã kết nối {self.client.base_url} · sing-box {'đang chạy' if running else 'KHÔNG chạy'}")
            self.render_wifi()
            self.refresh_clients()
            self.refresh_backups()
        self.run_task("Đang kết nối Agent…", work, done)

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
            self.health = ((status.get("health") or {}).get("probes") or {})
            self.capture_runtime_ssids(status)
            self.render_gateway(gateway)
            running = bool((status.get("meta") or {}).get("singbox_running"))
            self.status_var.set(f"Đã làm mới · sing-box {'đang chạy' if running else 'KHÔNG chạy'}")
            self.render_wifi()
        self.run_task("Đang làm mới…", work, done)

    def render_gateway(self, payload):
        payload = payload or {}
        state = str(payload.get("state") or "unknown")
        labels = {
            "ok": ("● Gateway OK", "MetricGreen.TLabel"),
            "degraded": ("● Gateway suy giảm", "MetricYellow.TLabel"),
            "down": ("● Gateway mất kết nối", "MetricRed.TLabel"),
            "unknown": ("● Gateway chưa xác định", "MetricBlue.TLabel"),
        }
        text, style = labels.get(state, labels["unknown"])
        self.gateway_state_var.set(text)
        self.gateway_state_label.configure(style=style)

        expected = str(payload.get("expected_interface") or "wwan")
        logical = str(payload.get("interface") or "—")
        device = str(payload.get("device") or "—")
        via = str(payload.get("gateway") or "direct")
        source = str(payload.get("source_ip") or "—")
        route = f"Đường ra: {logical}/{device} · via {via} · src {source}"
        if payload.get("expected_active") is False:
            route += f" · KHÔNG QUA {expected}"
        self.gateway_route_var.set(route)

        link = "OK" if payload.get("link_ok") else "LỖI"
        if not payload.get("dns_checked", True):
            dns = "không kiểm tra"
        else:
            dns = "OK" if payload.get("dns_ok") else "LỖI"
        self.gateway_link_var.set(f"Link: {link} · DNS: {dns}")

        if payload.get("http_ok"):
            self.gateway_http_var.set(
                f"HTTP: {payload.get('http_code') or 0} · {payload.get('latency_ms') or 0} ms"
            )
        else:
            error = str(payload.get("error") or "không truy cập được")
            self.gateway_http_var.set(f"HTTP: LỖI · {error}")

    def refresh_gateway(self):
        try:
            client = self.require_client()
        except AgentError as exc:
            self._task_error(exc)
            return
        def done(payload):
            self.render_gateway(payload)
            state = payload.get("state") or "unknown"
            self.append_log(f"Kiểm tra gateway: {state} · {payload.get('route') or 'không có route'}")
        self.run_task("Đang kiểm tra Internet gateway…", client.gateway, done)

    def capture_runtime_ssids(self, status):
        self.runtime_ssids = {}
        for item in status.get("ssids") or []:
            try:
                self.runtime_ssids[int(item.get("idx"))] = item
            except (TypeError, ValueError):
                continue

    def selected_wifi(self):
        selected = self.wifi_tree.selection()
        if not selected:
            return None
        idx = int(selected[0])
        return next((item for item in self.records if item.idx == idx), None)

    def update_wifi_editor(self, _event=None):
        record = self.selected_wifi()
        state = "normal" if record else "disabled"
        for button in self.wifi_edit_buttons.values():
            button.configure(state=state)
        if record:
            self.wifi_selection_var.set(f"{record.name} · IDX {record.idx} · {record.band}")
        else:
            self.wifi_selection_var.set("Chọn một SSID trong bảng để chỉnh sửa")

    def next_idx(self):
        used = {item.idx for item in self.records}
        idx = 1
        while idx in used:
            idx += 1
        return idx

    def add_wifi(self):
        dialog = WifiDialog(self.root, None, self.next_idx())
        self.root.wait_window(dialog)
        if dialog.result:
            if any(item.idx == dialog.result.idx for item in self.records):
                messagebox.showerror("IDX bị trùng", "IDX này đã được sử dụng", parent=self.root)
                return
            self.records.append(dialog.result)
            self.records.sort(key=lambda item: item.idx)
            self.render_wifi()

    def edit_wifi(self):
        record = self.selected_wifi()
        if not record:
            messagebox.showinfo(APP_NAME, "Hãy chọn một Wi‑Fi", parent=self.root)
            return
        dialog = WifiDialog(self.root, record, record.idx)
        self.root.wait_window(dialog)
        if dialog.result:
            if any(item.idx == dialog.result.idx and item is not record for item in self.records):
                messagebox.showerror("IDX bị trùng", "IDX này đã được sử dụng", parent=self.root)
                return
            self.records[self.records.index(record)] = dialog.result
            self.records.sort(key=lambda item: item.idx)
            self.render_wifi()

    def delete_wifi(self):
        record = self.selected_wifi()
        if record and self.confirm_important(
            "Xoá SSID",
            f"Xoá SSID {record.name} (IDX {record.idx}) khỏi cấu hình đang chỉnh sửa.",
            "Chưa tác động router ngay. Khi Apply, SSID, rule định tuyến và các kết nối của SSID này sẽ bị xoá.",
        ):
            self.records.remove(record)
            self.render_wifi()

    def quick_sock(self):
        record = self.selected_wifi()
        if not record:
            messagebox.showinfo(APP_NAME, "Hãy chọn một Wi‑Fi", parent=self.root)
            return
        dialog = WifiDialog(self.root, record, record.idx)
        dialog.title("Đổi SOCKS nhanh")
        self.root.wait_window(dialog)
        if not dialog.result:
            return
        updated = dialog.result
        if not self.confirm_important(
            "Đổi SOCKS5",
            f"Đổi endpoint SOCKS5 đang dùng cho SSID {record.name}.",
            "Thay đổi được gửi lên router ngay. Phiên mạng hiện tại có thể bị ngắt; endpoint sai có thể làm SSID mất Internet.",
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
            self.append_log(response.get("log", "Đổi SOCKS thành công"))
        self.run_task("Đang đổi SOCKS…", lambda: client.set_sock(updated), done)

    def rotate_wifi_mac(self):
        record = self.selected_wifi()
        if not record:
            messagebox.showinfo(APP_NAME, "Hãy chọn một Wi‑Fi cần random MAC", parent=self.root)
            return
        current = (self.runtime_ssids.get(record.idx) or {}).get("macaddr") or "chưa đặt"
        dialog = RandomMacDialog(self.root, record, current)
        self.root.wait_window(dialog)
        if dialog.result is None:
            return
        selected_oui = dialog.result
        provider = vendor_label(selected_oui)
        if not self.confirm_important(
            "Random MAC",
            f"Đổi BSSID/MAC của {record.name}.\nHiện tại: {current}\nProvider mới: {provider}",
            "Wi‑Fi cùng radio sẽ reload và các thiết bị có thể mất kết nối ngắn. Provider và MAC mới sẽ được lưu qua các lần Apply.",
        ):
            return
        try:
            client = self.require_client()
        except AgentError as exc:
            self._task_error(exc)
            return

        def done(payload):
            new_mac = payload.get("mac") or "đã đổi"
            record.mac_oui = selected_oui
            runtime = self.runtime_ssids.setdefault(record.idx, {})
            runtime["macaddr"] = new_mac
            runtime["mac_oui"] = selected_oui
            self.render_wifi()
            self.append_log(payload.get("log", f"Đã xoay MAC {record.name} -> {new_mac}"))
            self.status_var.set(f"Đã xoay BSSID {record.name} → {new_mac}; Wi‑Fi đang reload")
            self.root.after(5000, self.refresh_all)

        self.run_task(
            f"Đang xoay BSSID/MAC của {record.name}…",
            lambda: client.rotate_mac(record.idx, selected_oui),
            done,
        )

    def save_apply(self):
        try:
            client = self.require_client()
            content = render_conf(self.records)
        except Exception as exc:
            self._task_error(exc)
            return
        if not self.confirm_important(
            "Dry-run và Apply",
            f"Ghi và kích hoạt toàn bộ cấu hình gồm {len(self.records)} SSID.",
            "App sẽ dry-run và backup trước, sau đó ghi cấu hình, thay rule mạng và reload Wi‑Fi. Các thiết bị có thể mất kết nối tạm thời.",
        ):
            return
        def work():
            self.update_loading("Bước 1/3 · Dry-run cấu hình tạm, chưa ghi lên router…")
            dryrun = client.dryrun_conf(content)
            if not dryrun.get("ok", False):
                raise AgentError(dryrun.get("log") or "Dry-run thất bại")
            self.update_loading("Bước 2/3 · Dry-run đạt, đang backup và lưu cấu hình…")
            client.save_conf(content)
            self.update_loading("Bước 3/3 · Dry-run bắt buộc lần cuối và apply lên router…")
            result = client.apply()
            if not result.get("ok", False):
                raise AgentError(result.get("log") or "Apply thất bại")
            return dryrun, result
        def done(payload):
            _dryrun, result = payload
            self.append_log("DRY-RUN OK · Không phát hiện lỗi, đã cho phép apply.")
            self.append_log(result.get("log", "Apply thành công"))
            self.status_var.set("Apply thành công; Wi‑Fi đang reload")
            self.root.after(5000, self.refresh_all)
        self.run_task(
            "Đang dry-run trước khi apply…",
            work,
            done,
            show_loading=True,
            timeout_hint=225,
        )

    def render_wifi(self):
        self.wifi_tree.delete(*self.wifi_tree.get_children())
        for record in self.records:
            probe = self.health.get(str(record.idx), self.health.get(record.idx, {})) or {}
            state = probe.get("state", "—")
            latency = probe.get("latency_ms")
            health = f"{state} {latency}ms" if latency is not None else state
            runtime = self.runtime_ssids.get(record.idx) or {}
            mac = runtime.get("macaddr") or "—"
            provider = vendor_label(record.mac_oui).split(" · ", 1)[0]
            mac_display = f"{mac} · {provider}"
            normalized = str(state).casefold()
            tag = ""
            if any(word in normalized for word in ("ok", "up", "healthy")):
                tag = "healthy"
            elif any(word in normalized for word in ("slow", "warn")):
                tag = "warning"
            elif state not in ("", "—", None):
                tag = "error"
            self.wifi_tree.insert("", "end", iid=str(record.idx), tags=(tag,) if tag else (), values=(record.idx, record.name, record.band, f"192.168.{10 + record.idx}.0/24", mac_display, f"{record.host}:{record.port}", "Có" if record.isolate else "Không", "Chặn" if record.webrtc else "Cho phép", health))
        self.update_client_filter_options()
        self.update_wifi_editor()

    def update_client_filter_options(self):
        ssids = {record.name for record in self.records if record.name}
        ssids.update(str(item.get("ssid")) for item in self.clients_data if item.get("ssid"))
        values = (ALL_SSIDS, *sorted(ssids, key=str.casefold))
        self.client_ssid_combo.configure(values=values)
        if self.client_ssid_var.get() not in values:
            self.client_ssid_var.set(ALL_SSIDS)

    def reset_client_filters(self):
        self.client_ssid_var.set(ALL_SSIDS)
        self.client_query_var.set("")
        self.client_state_var.set(ALL_STATES)
        self.client_signal_var.set(ALL_SIGNALS)
        self.client_band_var.set(ALL_BANDS)
        self.client_presence_var.set(ALL_PRESENCE)
        self.client_traffic_var.set(ALL_TRAFFIC)
        self.client_duration_var.set(ALL_DURATIONS)

    def update_client_summary(self):
        online = sum(1 for item in self.clients_data if item.get("online", True))
        weak = sum(
            1 for item in self.clients_data
            if item.get("online", True)
            and item.get("signal_dbm") is not None
            and float(item.get("signal_dbm")) < -70
        )
        blocked = sum(1 for item in self.clients_data if item.get("banned"))
        traffic = sum(
            int(item.get("rx_bytes") or 0) + int(item.get("tx_bytes") or 0)
            for item in self.clients_data
        )
        self.client_online_count_var.set(f"● {online} online")
        self.client_weak_count_var.set(f"● {weak} tín hiệu yếu")
        self.client_blocked_count_var.set(f"● {blocked} đã chặn")
        self.client_traffic_total_var.set(f"● {human_bytes(traffic)} tổng lưu lượng")

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
                text=title + marker if column == self.client_sort_column else title,
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
                status = "Online · đã cấm"
            elif item.get("banned"):
                status = "Offline · đã cấm"
            elif online:
                status = "Online"
            else:
                status = "Offline"
            band = {"2g": "2.4G", "5g": "5G"}.get(str(item.get("band") or "").casefold(), item.get("band", ""))
            self.client_tree.insert(
                "", "end", iid=iid, tags=(tag,) if tag else (),
                values=(
                    item.get("ssid", ""), band, item.get("ip", ""), item.get("host", ""),
                    item.get("mac", ""), human_time(item.get("connected_s")) if online else "—",
                    human_bytes(item.get("rx_bytes")), human_bytes(item.get("tx_bytes")),
                    f"{signal} dBm" if signal is not None else "—", status,
                ),
            )
        self.client_count_var.set(f"{len(self.visible_clients)} / {len(self.clients_data)} thiết bị")
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
            self.clients_data = payload.get("clients") or []
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
            self.run_task("Đang đọc danh sách thiết bị…", work, done)

    def _finish_client_refresh(self):
        self.client_refreshing = False
        if self.client_auto_var.get() and not self.client_refresh_job:
            self.schedule_client_refresh()

    def _auto_client_error(self, exc):
        self.status_var.set(f"Auto-refresh lỗi: {exc}")
        self.schedule_client_refresh()

    def selected_client_items(self):
        return [self.client_rows[iid] for iid in self.client_tree.selection() if iid in self.client_rows]

    def update_client_editor(self, _event=None):
        items = self.selected_client_items()
        if not items:
            self.client_selection_var.set("Chọn thiết bị trong bảng để điều khiển")
            states = {key: "disabled" for key in self.client_edit_buttons}
        else:
            if len(items) == 1:
                item = items[0]
                label = item.get("host") or item.get("ip") or item.get("mac") or "Thiết bị"
                self.client_selection_var.set(f"{label} · {item.get('ssid') or '—'}")
            else:
                self.client_selection_var.set(f"Đã chọn {len(items)} thiết bị")
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
        if not self.records:
            messagebox.showinfo(APP_NAME, "Chưa có SSID nào để áp dụng blocklist", parent=self.root)
            return
        dialog = ManualBanDialog(self.root, self.records)
        self.root.wait_window(dialog)
        if not dialog.result:
            return
        idx, mac = dialog.result
        record = next((item for item in self.records if item.idx == idx), None)
        if not self.confirm_important(
            "Thêm vào blocklist",
            f"Chặn MAC {mac} trên SSID {record.name if record else idx}.",
            "Thiết bị này sẽ mất truy cập và Wi‑Fi cùng radio có thể reload ngắn.",
        ):
            return
        try:
            client = self.require_client()
        except AgentError as exc:
            self._task_error(exc)
            return
        def done(payload):
            self.append_log(payload.get("log", f"Đã chặn {mac}"))
            self.refresh_clients()
        self.run_task(
            f"Đang thêm {mac} vào blocklist…",
            lambda: client.client_action("ban", idx, mac),
            done,
            show_loading=True,
            timeout_hint=45,
        )

    def client_action(self, action):
        items = self.selected_client_items()
        if not items:
            messagebox.showinfo(APP_NAME, "Hãy chọn một hoặc nhiều thiết bị", parent=self.root)
            return
        if action == "kick":
            online_items = [item for item in items if item.get("online", True)]
            if not online_items:
                messagebox.showinfo(APP_NAME, "Các thiết bị đã chọn đều offline", parent=self.root)
                return
            items = online_items
        if action == "unban":
            items = [item for item in items if item.get("banned")]
            if not items:
                messagebox.showinfo(APP_NAME, "Không có thiết bị bị cấm trong lựa chọn", parent=self.root)
                return
        if action == "ban":
            items = [item for item in items if not item.get("banned")]
            if not items:
                messagebox.showinfo(APP_NAME, "Các thiết bị đã chọn đều đã bị cấm", parent=self.root)
                return
        labels = {"kick": "kick", "ban": "cấm", "unban": "bỏ cấm"}
        impacts = {
            "kick": "Các thiết bị sẽ bị ngắt kết nối ngay nhưng có thể tự kết nối lại.",
            "ban": "Các MAC sẽ vào blocklist, mất truy cập; Wi‑Fi liên quan có thể reload ngắn.",
            "unban": "Các MAC sẽ được gỡ khỏi blocklist; Wi‑Fi liên quan có thể reload ngắn.",
        }
        if not self.confirm_important(
            labels[action].capitalize(),
            f"{labels[action].capitalize()} {len(items)} thiết bị đã chọn.",
            impacts[action],
        ):
            return
        client = self.require_client()
        def work():
            logs, failures = [], []
            for item in items:
                try:
                    payload = client.client_action(action, item["idx"], item["mac"])
                    logs.append(payload.get("log", f"{labels[action]} {item['mac']} thành công"))
                except Exception as exc:
                    failures.append(f"{item.get('mac')}: {exc}")
            return logs, failures
        def done(result):
            logs, failures = result
            self.append_log("\n".join(logs) if logs else f"Không có thiết bị nào {labels[action]} thành công")
            if failures:
                self.append_log("LỖI:\n" + "\n".join(failures))
                messagebox.showwarning(APP_NAME, f"Hoàn tất với {len(failures)} lỗi. Xem nhật ký.", parent=self.root)
            self.refresh_clients()
        self.run_task(
            f"Đang {labels[action]} {len(items)} thiết bị…",
            work,
            done,
            show_loading=len(items) > 1,
            timeout_hint=min(300, 45 * len(items)),
        )

    def copy_selected_clients(self):
        items = self.selected_client_items()
        if not items:
            messagebox.showinfo(APP_NAME, "Hãy chọn thiết bị cần copy", parent=self.root)
            return
        text = "\n".join(
            f"{item.get('ip') or '-'}\t{item.get('mac') or '-'}\t{item.get('host') or '-'}"
            for item in items
        )
        self.root.clipboard_clear()
        self.root.clipboard_append(text)
        self.status_var.set(f"Đã copy IP/MAC của {len(items)} thiết bị")

    def export_clients_csv(self):
        path = filedialog.asksaveasfilename(
            parent=self.root,
            title="Xuất danh sách thiết bị đang lọc",
            defaultextension=".csv",
            filetypes=(("CSV UTF-8", "*.csv"), ("Tất cả file", "*.*")),
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
            messagebox.showerror("Không xuất được CSV", str(exc), parent=self.root)
            return
        self.status_var.set(f"Đã xuất {len(self.visible_clients)} thiết bị")

    def show_client_details(self, event=None):
        if event is not None:
            row = self.client_tree.identify_row(event.y)
            if row:
                self.client_tree.selection_set(row)
        items = self.selected_client_items()
        if not items:
            return
        item = items[0]
        total = int(item.get("rx_bytes") or 0) + int(item.get("tx_bytes") or 0)
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
        messagebox.showinfo("Chi tiết thiết bị", details, parent=self.root)

    def refresh_backups(self):
        try:
            client = self.require_client()
        except AgentError:
            return
        def done(payload):
            self.backup_list.delete(0, "end")
            for name in payload.get("backups") or []:
                self.backup_list.insert("end", name)
            self.update_backup_editor()
        self.run_task("Đang đọc backup…", client.backups, done)

    def update_backup_editor(self, _event=None):
        selected = self.backup_list.curselection()
        if selected:
            name = self.backup_list.get(selected[0])
            self.backup_selection_var.set(f"Đang chọn: {name}")
            self.rollback_button.configure(state="normal")
        else:
            self.backup_selection_var.set("Chọn một backup để khôi phục")
            self.rollback_button.configure(state="disabled")

    def create_backup(self):
        client = self.require_client()
        label = simpledialog.askstring("Tạo backup", "Nhãn backup", initialvalue="native", parent=self.root)
        if label is None:
            return
        if not re.fullmatch(r"[A-Za-z0-9._-]+", label):
            messagebox.showerror(APP_NAME, "Nhãn chỉ được chứa chữ, số, dấu . _ -", parent=self.root)
            return
        def done(payload):
            self.append_log(payload.get("log", "Backup thành công"))
            self.refresh_backups()
        self.run_task("Đang tạo backup…", lambda: client.backup(label), done)

    def rollback(self):
        selected = self.backup_list.curselection()
        if not selected:
            messagebox.showinfo(APP_NAME, "Hãy chọn một backup", parent=self.root)
            return
        name = self.backup_list.get(selected[0])
        if not self.confirm_important(
            "Rollback",
            f"Khôi phục router từ backup {name}.",
            "Cấu hình hiện tại sẽ bị thay thế. Router và Wi‑Fi sẽ reload, làm gián đoạn toàn bộ kết nối trong lúc khôi phục.",
        ):
            return
        client = self.require_client()
        def done(payload):
            self.append_log(payload.get("log", "Rollback thành công"))
            self.status_var.set("Rollback hoàn tất; đang chờ router")
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
    provisioned = provision_from_environment()
    if "--provision" in sys.argv:
        return 0 if provisioned else 2
    if "--probe" in sys.argv:
        return 0 if probe_saved_connection() else 1
    root = tk.Tk()
    NativeApp(root)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
