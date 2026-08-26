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
import random
from logging.handlers import TimedRotatingFileHandler
import getpass
import math
import os
from pathlib import Path
import re
import shlex
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
APP_VERSION = "0.5.1"
APP_DIR_NAME = "sbproxy-console-native"
DEFAULT_BASE = "http://192.168.8.1"
# Fallbacks for an agent too old to report the router's effective settings.sh
# values; a connected agent overrides these from status meta.
DEFAULT_NET_BASE = 10
DEFAULT_TPROXY_PORT_BASE = 12000

# Logs roll over at midnight and nothing older than a week is kept, so a
# long-lived install never grows without bound and stale operational data does
# not linger on an operator's machine.
LOG_RETENTION_DAYS = 7
LOG_ROTATION_SUFFIX = "%Y-%m-%d"


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
# Who connected, and every change made to a router, kept apart from the
# technical log so it can be read (or handed over) on its own.
AUDIT_FILE = LOG_DIR / "audit.log"
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
audit_log = logging.getLogger("sbproxy.audit")


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


def daily_handler(path: Path, formatter: logging.Formatter):
    """A log file that rolls at midnight and keeps LOG_RETENTION_DAYS of history."""
    handler = TimedRotatingFileHandler(
        path, when="midnight", backupCount=LOG_RETENTION_DAYS, encoding="utf-8",
    )
    handler.suffix = LOG_ROTATION_SUFFIX
    handler.setFormatter(formatter)
    if os.name != "nt":
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
    return handler


def purge_old_logs(now=None) -> list:
    """Delete rotated logs past the retention window.

    TimedRotatingFileHandler only prunes when it rotates, which never happens
    in an app that is opened for ten minutes a day, and it ignores files left
    by the previous size-based scheme. This runs at every start instead.
    """
    cutoff = (now if now is not None else time.time()) - LOG_RETENTION_DAYS * 86400
    removed = []
    for path in sorted(LOG_DIR.glob("*.log.*")):
        try:
            if path.is_file() and path.stat().st_mtime < cutoff:
                path.unlink()
                removed.append(path)
        except OSError:
            continue  # locked or already gone: nothing to do about it here
    return removed


def audit(action: str, **fields) -> str:
    """Record a connection or a change made to a router.

    Values are redacted like everything else that reaches a log file, so a
    token or password in a field cannot leak into the audit trail.
    """
    details = " ".join(f"{key}={value}" for key, value in fields.items()
                       if value is not None and value != "")
    try:
        who = getpass.getuser()
    except Exception:  # no password database entry, no USER/USERNAME
        who = "?"
    entry = redact(f"{action} user={who}" + (f" {details}" if details else ""))
    audit_log.info(entry)
    return entry


def setup_logging(verbose: bool = False) -> Path:
    """Daily file logs plus stderr, so field issues can be diagnosed later."""
    ensure_app_home()
    log.setLevel(logging.DEBUG if verbose else logging.INFO)
    audit_log.setLevel(logging.INFO)
    for logger in (log, audit_log):
        for handler in list(logger.handlers):
            logger.removeHandler(handler)
            handler.close()
    fmt = logging.Formatter("%(asctime)s %(levelname)-7s %(threadName)s %(message)s")
    try:
        purge_old_logs()
        log.addHandler(daily_handler(LOG_FILE, fmt))
        # Audit entries also reach console.log through propagation, so a
        # support bundle keeps one timeline.
        audit_log.addHandler(daily_handler(AUDIT_FILE, logging.Formatter("%(asctime)s %(message)s")))
    except OSError:
        pass  # A read-only home must not stop the app from starting.
    stream = logging.StreamHandler()
    stream.setFormatter(fmt)
    log.addHandler(stream)
    log.info(
        "start %s v%s | python %s | frozen=%s | home=%s | log retention=%s days",
        APP_NAME, APP_VERSION, sys.version.split()[0], bool(getattr(sys, "frozen", False)),
        APP_HOME, LOG_RETENTION_DAYS,
    )
    return LOG_FILE


def install_exception_logging() -> None:
    """Uncaught failures â€” main thread and workers â€” must reach the log file."""
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
    "ChÆ°a káº¿t ná»‘i": "Not connected",
    "Káº¿t ná»‘i": "Connect",
    "LÃ m má»›i": "Refresh",
    "Kiá»ƒm tra cá»•ng ra": "Check gateway",
    "Cá»”NG RA INTERNET": "INTERNET GATEWAY",
    "â— Internet chÆ°a kiá»ƒm tra": "â— Gateway not checked",
    "â— Internet chÆ°a xÃ¡c Ä‘á»‹nh": "â— Gateway unknown",
    "â— Máº¥t káº¿t ná»‘i Internet": "â— Gateway down",
    "â— Internet suy giáº£m": "â— Gateway degraded",
    "â— Internet hoáº¡t Ä‘á»™ng": "â— Gateway OK",
    "ÄÆ°á»ng ra: â€”": "Egress: â€”",
    "Káº¿t ná»‘i/DNS: â€”": "Link/DNS: â€”",
    "Internet HTTP: â€”": "Internet HTTP: â€”",
    "Wiâ€‘Fi / SOCKS5": "Wi-Fi / SOCKS5",
    "Thiáº¿t bá»‹": "Devices",
    "Backup / Nháº­t kÃ½": "Backups / Logs",
    "ï¼‹ ThÃªm SSID": "+ Add SSID",
    "Äáº©y cáº¥u hÃ¬nh & Apply": "Push configuration & Apply",
    "CHá»ˆNH Sá»¬A SSID ÄANG CHá»ŒN": "EDIT SELECTED SSID",
    "Sá»­a cáº¥u hÃ¬nh": "Edit configuration",
    "Äá»•i SOCKS": "Change SOCKS",
    "XoÃ¡ SSID": "Delete SSID",
    "Chá»n má»™t SSID trong báº£ng Ä‘á»ƒ chá»‰nh sá»­a": "Select an SSID in the table to edit",
    "LÃ m má»›i": "Refresh",
    "Cháº·n MACâ€¦": "Block MACâ€¦",
    "Xuáº¥t CSV": "Export CSV",
    "Tá»± lÃ m má»›i": "Auto refresh",
    "Káº¿t ná»‘i": "Connection",
    "Quyá»n": "Access",
    "TÃ¬m IP / tÃªn / MAC": "Find IP / name / MAC",
    "TÃ­n hiá»‡u": "Signal",
    "LÆ°u lÆ°á»£ng": "Traffic",
    "Thá»i gian": "Duration",
    "Äáº·t láº¡i bá»™ lá»c": "Reset filters",
    "ÄIá»€U KHIá»‚N THIáº¾T Bá»Š ÄANG CHá»ŒN": "CONTROL SELECTED DEVICES",
    "Chi tiáº¿t": "Details",
    "Copy IP/MAC": "Copy IP/MAC",
    "Cáº¥m": "Block",
    "Bá» cáº¥m": "Unblock",
    "Táº£i danh sÃ¡ch": "Load list",
    "Táº¡o backup": "Create backup",
    "Rollback backup Ä‘ang chá»n": "Roll back selected backup",
    "Nháº­t kÃ½ thao tÃ¡c": "Operation log",
    "Táº¥t cáº£ SSID": "All SSIDs",
    "Táº¥t cáº£ band": "All bands",
    "Táº¥t cáº£ káº¿t ná»‘i": "All connections",
    "Táº¥t cáº£ quyá»n truy cáº­p": "All access states",
    "Táº¥t cáº£ tÃ­n hiá»‡u": "All signal levels",
    "Táº¥t cáº£ lÆ°u lÆ°á»£ng": "All traffic",
    "Táº¥t cáº£ thá»i gian": "All durations",
    "Äang cáº¥m": "Blocked",
    "KhÃ´ng cáº¥m": "Not blocked",
    "Ráº¥t tá»‘t (â‰¥ -60 dBm)": "Excellent (â‰¥ -60 dBm)",
    "Tá»‘t (-70 Ä‘áº¿n -61 dBm)": "Good (-70 to -61 dBm)",
    "Yáº¿u (-80 Ä‘áº¿n -71 dBm)": "Weak (-80 to -71 dBm)",
    "Ráº¥t yáº¿u (< -80 dBm)": "Very weak (< -80 dBm)",
    "KhÃ´ng rÃµ": "Unknown",
    "CÃ³ lÆ°u lÆ°á»£ng": "Has traffic",
    "KhÃ´ng lÆ°u lÆ°á»£ng": "No traffic",
    "Tá»« 10 MB": "At least 10 MB",
    "Tá»« 100 MB": "At least 100 MB",
    "DÆ°á»›i 5 phÃºt": "Under 5 minutes",
    "5â€“60 phÃºt": "5â€“60 minutes",
    "TrÃªn 1 giá»": "Over 1 hour",
    "Sá»­a Wiâ€‘Fi": "Edit Wi-Fi",
    "ThÃªm Wiâ€‘Fi": "Add Wi-Fi",
    "BÄƒng táº§n": "Band",
    "Máº­t kháº©u Wiâ€‘Fi": "Wi-Fi password",
    "HÃ£ng router / MAC": "Router vendor / MAC",
    "CÃ¡ch ly client": "Client isolation",
    "Cháº·n WebRTC": "Block WebRTC",
    "Huá»·": "Cancel",
    "LÆ°u": "Save",
    "Dá»¯ liá»‡u khÃ´ng há»£p lá»‡": "Invalid data",
    "Chá»n hÃ£ng router": "Select router vendor",
    "Provider / OUI": "Provider / OUI",
    "Random sáº½ cáº­p nháº­t provider trong config, táº¡o BSSID má»›i vÃ  reload radio.": "Randomization updates the provider, creates a new BSSID, and reloads the radio.",
    "OUI khÃ´ng há»£p lá»‡": "Invalid OUI",
    "Provider khÃ´ng há»£p lá»‡": "Invalid provider",
    "Ngáº«u nhiÃªn / áº©n danh": "Random / anonymous",
    "OUI tuá»³ chá»‰nh Â· ": "Custom OUI Â· ",
    "ThÃªm MAC vÃ o blocklist": "Add MAC to blocklist",
    "Cháº·n thiáº¿t bá»‹ theo MAC": "Block device by MAC",
    "VÃ­ dá»¥: AA:BB:CC:DD:EE:FF": "Example: AA:BB:CC:DD:EE:FF",
    "ThÃªm vÃ o blocklist": "Add to blocklist",
    "MAC khÃ´ng há»£p lá»‡": "Invalid MAC",
    "MAC pháº£i cÃ³ dáº¡ng AA:BB:CC:DD:EE:FF": "MAC must use AA:BB:CC:DD:EE:FF format",
    "Thiáº¿u SSID": "Missing SSID",
    "HÃ£y chá»n SSID cáº§n cháº·n": "Select the SSID to block on",
    "sbproxy Â· Äang xá»­ lÃ½": "sbproxy Â· Working",
    "Äang kiá»ƒm tra vÃ  Ã¡p dá»¥ng": "Validating and applying",
    "Cáº¢NH BÃO Â· TÃC Vá»¤ QUAN TRá»ŒNG": "WARNING Â· IMPORTANT ACTION",
    "Thao tÃ¡c": "Action",
    "áº¢nh hÆ°á»Ÿng cÃ³ thá»ƒ xáº£y ra": "Possible impact",
    "Chá»‰ tiáº¿p tá»¥c khi báº¡n Ä‘Ã£ kiá»ƒm tra Ä‘Ãºng SSID/thiáº¿t bá»‹ vÃ  cháº¥p nháº­n áº£nh hÆ°á»Ÿng.": "Continue only after verifying the target SSID/device and accepting the impact.",
    "Cáº£nh bÃ¡o": "Warning",
    "Dá»¯ liá»‡u khÃ´ng há»£p lá»‡": "Invalid data",
    "IDX bá»‹ trÃ¹ng": "Duplicate IDX",
    "IDX nÃ y Ä‘Ã£ Ä‘Æ°á»£c sá»­ dá»¥ng": "This IDX is already in use",
    "HÃ£y chá»n má»™t Wiâ€‘Fi": "Select a Wi-Fi network",
    "HÃ£y chá»n má»™t Wiâ€‘Fi cáº§n random MAC": "Select a Wi-Fi network to randomize",
    "Äá»•i SOCKS nhanh": "Quick SOCKS change",
    "Dry-run vÃ  Apply": "Dry-run and Apply",
    "ChÆ°a cÃ³ SSID nÃ o Ä‘á»ƒ Ã¡p dá»¥ng blocklist": "No SSID is available for the blocklist",
    "HÃ£y chá»n má»™t hoáº·c nhiá»u thiáº¿t bá»‹": "Select one or more devices",
    "CÃ¡c thiáº¿t bá»‹ Ä‘Ã£ chá»n Ä‘á»u offline": "All selected devices are offline",
    "KhÃ´ng cÃ³ thiáº¿t bá»‹ bá»‹ cáº¥m trong lá»±a chá»n": "No blocked device is selected",
    "CÃ¡c thiáº¿t bá»‹ Ä‘Ã£ chá»n Ä‘á»u Ä‘Ã£ bá»‹ cáº¥m": "All selected devices are already blocked",
    "HÃ£y chá»n thiáº¿t bá»‹ cáº§n copy": "Select devices to copy",
    "KhÃ´ng xuáº¥t Ä‘Æ°á»£c CSV": "Could not export CSV",
    "Chi tiáº¿t thiáº¿t bá»‹": "Device details",
    "NhÃ£n backup": "Backup label",
    "NhÃ£n chá»‰ Ä‘Æ°á»£c chá»©a chá»¯, sá»‘, dáº¥u . _ -": "The label may only contain letters, numbers, dots, underscores, and hyphens",
    "HÃ£y chá»n má»™t backup": "Select a backup",
    "CÃ³": "Yes",
    "KhÃ´ng": "No",
    "Cháº·n": "Blocked",
    "Cho phÃ©p": "Allowed",
    "Tráº¡ng thÃ¡i": "Status",
    "TÃªn mÃ¡y": "Hostname",
    "ÄÆ°á»ng ra": "Egress",
    "khÃ´ng kiá»ƒm tra": "not checked",
    "khÃ´ng truy cáº­p Ä‘Æ°á»£c": "unreachable",
    "khÃ´ng cÃ³ route": "no route",
    "Ä‘ang cháº¡y": "running",
    "KHÃ”NG cháº¡y": "NOT running",
    "HoÃ n táº¥t": "Completed",
    "Lá»–I": "ERROR",
    "Lá»—i": "Error",
    "Táº¥t cáº£ file": "All files",
    "NgÃ´n ngá»¯": "Language",
    "Giao diá»‡n": "Theme",
    "ThÆ° má»¥c log": "Log folder",
    "Chá»n thiáº¿t bá»‹ trong báº£ng Ä‘á»ƒ Ä‘iá»u khiá»ƒn": "Select devices in the table to control",
    "Chá»n má»™t backup Ä‘á»ƒ khÃ´i phá»¥c": "Select a backup to restore",
    "Äá»•i SOCKS5": "Change SOCKS5",
    "Loáº¡i proxy": "Proxy type",
    "Nháº­p nhanh proxy": "Quick proxy input",
    "TÃ¡ch & Ä‘iá»n": "Parse & fill",
    "Nháº­p proxy theo dáº¡ng host:port:user:password": "Enter the proxy as host:port:user:password",
    "Chuá»—i proxy nháº­p nhanh khÃ´ng há»£p lá»‡": "Invalid quick proxy value",
    "Loáº¡i proxy pháº£i lÃ  SOCKS5 hoáº·c HTTP": "Proxy type must be SOCKS5 or HTTP",
    "Agent tráº£ dá»¯ liá»‡u khÃ´ng pháº£i JSON": "The Agent returned non-JSON data",
    "Agent tráº£ JSON khÃ´ng pháº£i object": "The Agent returned JSON that is not an object",
    "Agent bÃ¡o lá»—i": "The Agent reported an error",
    "IDX Wiâ€‘Fi bá»‹ trÃ¹ng": "Duplicate Wi-Fi IDX",
    "Base URL pháº£i báº¯t Ä‘áº§u báº±ng http:// hoáº·c https://": "Base URL must start with http:// or https://",
    "Thiáº¿u token Agent": "Agent token is required",
    "ChÆ°a káº¿t ná»‘i Agent": "Not connected to the Agent",
    "DPAPI chá»‰ cÃ³ trÃªn Windows": "DPAPI is only available on Windows",
    "CÃ¡c trÆ°á»ng khÃ´ng Ä‘Æ°á»£c chá»©a | hoáº·c xuá»‘ng dÃ²ng": "Fields cannot contain | or line breaks",
    "SSID pháº£i dÃ i 1â€“32 kÃ½ tá»±": "SSID must be 1â€“32 characters long",
    "BÄƒng táº§n pháº£i lÃ  2g hoáº·c 5g": "Band must be 2g or 5g",
    "IDX pháº£i tá»« 1 Ä‘áº¿n 200": "IDX must be between 1 and 200",
    "Máº­t kháº©u Wiâ€‘Fi pháº£i dÃ i 8â€“63 kÃ½ tá»±": "Wi-Fi password must be 8â€“63 characters long",
    "Thiáº¿u Ä‘á»‹a chá»‰ SOCKS5": "SOCKS5 address is required",
    "Port SOCKS5 khÃ´ng há»£p lá»‡": "Invalid SOCKS5 port",
    "MAC OUI pháº£i cÃ³ dáº¡ng AA:BB:CC": "MAC OUI must use AA:BB:CC format",
    "KhÃ´ng xÃ¡c Ä‘á»‹nh Ä‘Æ°á»£c OUI cá»§a hÃ£ng Ä‘Ã£ chá»n": "Could not determine the selected vendor OUI",
    "Äang káº¿t ná»‘i Agentâ€¦": "Connecting to Agentâ€¦",
    "Äang lÃ m má»›iâ€¦": "Refreshingâ€¦",
    "Äang kiá»ƒm tra cá»•ng ra Internetâ€¦": "Checking Internet gatewayâ€¦",
    "Äang Ä‘á»•i SOCKSâ€¦": "Changing SOCKSâ€¦",
    "Äang dry-run trÆ°á»›c khi applyâ€¦": "Running dry-run before applyâ€¦",
    "Äang Ä‘á»c backupâ€¦": "Loading backupsâ€¦",
    "Äang táº¡o backupâ€¦": "Creating backupâ€¦",
    "Äang rollbackâ€¦": "Rolling backâ€¦",
    "Dry-run tháº¥t báº¡i": "Dry-run failed",
    "Apply tháº¥t báº¡i": "Apply failed",
    "isolate vÃ  webrtc pháº£i lÃ  0 hoáº·c 1": "isolate and webrtc must be 0 or 1",
    "isolate vÃ  webrtc pháº£i lÃ  boolean": "isolate and webrtc must be boolean values",
    "CÃ¡c trÆ°á»ng vÄƒn báº£n pháº£i lÃ  chuá»—i": "Text fields must be strings",
    "ÄÃ£ Ä‘áº¡t giá»›i háº¡n 200 SSID": "The 200-SSID limit has been reached",
    "Bá» qua": "Skipped",
    'Router Ä‘ang cháº¡y báº£n má»›i hÆ¡n gÃ³i cÃ i, hÃ£y dÃ¹ng console má»›i hÆ¡n': 'The router runs a newer build than this package; use a newer console',
    'NÃ¢ng cáº¥p agent': 'Upgrade the agent',
    'CÃ i Ä‘Ã¨ agent qua SSH': 'Reinstall the agent over SSH',
    'NÃ¢ng cáº¥p tá»± Ä‘á»™ng': 'Automatic upgrade',
    'Äá»ƒ sau': 'Later',
    'Cáº¬P NHáº¬T AGENT': 'UPDATE AGENT',
    'Chá»n cÃ¡ch cáº­p nháº­t phÃ¹ há»£p. Cáº£ hai cÃ¡ch Ä‘á»u giá»¯ nguyÃªn wifi-socks.conf vÃ  settings.sh.': 'Choose an update method. Both methods preserve wifi-socks.conf and settings.sh.',
    'DÃ¹ng API self-update cá»§a agent. Nhanh nháº¥t khi agent hiá»‡n táº¡i hoáº¡t Ä‘á»™ng bÃ¬nh thÆ°á»ng.': 'Use the agent self-update API. This is fastest when the current agent works normally.',
    'DÃ¹ng SSH Ä‘á»ƒ cÃ i Ä‘Ã¨ agent, dÃ nh cho agent cÅ© bá»‹ lá»—i nháº­n diá»‡n gÃ³i .tar.gz. KhÃ´ng cháº¡y apply cáº¥u hÃ¬nh.': 'Use SSH to reinstall the agent when an old agent cannot recognize .tar.gz packages. Configuration is not applied.',
    'Äang nÃ¢ng cáº¥p agentâ€¦': 'Upgrading the agentâ€¦',
    'Agent trÃªn router lÃ  v{agent}, má»›i hÆ¡n console v{app}. HÃ£y dÃ¹ng báº£n console má»›i hÆ¡n; console cÅ© chá»‰ Ä‘Æ°á»£c phÃ©p xem, má»i thao tÃ¡c thay Ä‘á»•i bá»‹ khoÃ¡.': 'The router runs agent v{agent}, newer than console v{app}. Use a newer console; this one is read-only and every change is blocked.',
    'Agent trÃªn router lÃ  v{agent}, cÅ© hÆ¡n console v{app}.': 'The router runs agent v{agent}, older than console v{app}.',
    'NÃ¢ng cáº¥p agent lÃªn v{app} ngay bÃ¢y giá»? Cáº¥u hÃ¬nh wifi-socks.conf vÃ  settings.sh trÃªn router Ä‘Æ°á»£c giá»¯ nguyÃªn, router tá»± backup trÆ°á»›c khi cáº­p nháº­t.': 'Upgrade the agent to v{app} now? The router keeps its wifi-socks.conf and settings.sh, and backs itself up before updating.',
    'Agent Ä‘Ã£ á»Ÿ v{agent}; console nÃ y khÃ´ng cÃ³ báº£n má»›i hÆ¡n Ä‘á»ƒ Ä‘áº©y lÃªn.': 'The agent is already at v{agent}; this console has nothing newer to push.',
    'ÄÃ£ nÃ¢ng cáº¥p agent: {old} â†’ {new}': 'Agent upgraded: {old} â†’ {new}',
    'Console v{app} cÅ© hÆ¡n agent v{agent} â€” hÃ£y cáº­p nháº­t console trÆ°á»›c khi thay Ä‘á»•i router.': 'Console v{app} is older than agent v{agent} â€” update the console before changing the router.',
    'Agent váº«n cháº¡y version cÅ©, hÃ£y cháº¡y láº¡i vÃ  tick â€œCÃ i láº¡i agent dÃ¹ Ä‘Ã£ cÃ³â€': 'The agent still runs the old version; run again with â€œReinstall the agent even if it is presentâ€',
    'So khá»›p agent Ä‘Ã£ cÃ i': 'Compare the installed agent',
    'Kiá»ƒm tra hiá»‡n tráº¡ng router': 'Check what the router already has',
    'ÄÃ£ cÃ³': 'Present',
    'ChÆ°a cÃ³': 'Missing',
    'MÃ£ nguá»“n trÃªn router': 'Code on the router',
    'Cáº¥u hÃ¬nh wifi-socks.conf': 'wifi-socks.conf configuration',
    'GÃ³i phá»¥ thuá»™c (sing-box)': 'Dependencies (sing-box)',
    'Agent CGI': 'Agent CGI',
    'Token agent': 'Agent token',
    'sing-box Ä‘ang cháº¡y': 'sing-box running',
    'Ghi Ä‘Ã¨ cáº¥u hÃ¬nh Ä‘Ã£ cÃ³ trÃªn router': 'Overwrite the configuration already on the router',
    'CÃ i láº¡i agent dÃ¹ Ä‘Ã£ cÃ³': 'Reinstall the agent even if it is present',
    'Äang kiá»ƒm tra routerâ€¦': 'Checking the routerâ€¦',
    'ChÆ°a kiá»ƒm tra Ä‘Æ°á»£c router': 'The router has not been checked yet',
    # Post-flash provisioning
    'Thiáº¿u Ä‘á»‹a chá»‰ router': 'Router address is required',
    'Thiáº¿u tÃ i khoáº£n SSH': 'SSH account is required',
    'Port SSH khÃ´ng há»£p lá»‡': 'Invalid SSH port',
    'ThÆ° má»¥c trÃªn router pháº£i lÃ  Ä‘Æ°á»ng dáº«n tuyá»‡t Ä‘á»‘i': 'The router directory must be an absolute path',
    'KhÃ´ng tháº¥y SSH key': 'SSH key not found',
    'ChÆ°a chá»n mÃ£ nguá»“n hoáº·c gÃ³i cáº­p nháº­t': 'Select the source folder or the update package',
    'KhÃ´ng tháº¥y mÃ£ nguá»“n hoáº·c gÃ³i cáº­p nháº­t': 'Source folder or update package not found',
    'ThÆ° má»¥c mÃ£ nguá»“n khÃ´ng há»£p lá»‡ (thiáº¿u scripts/ hoáº·c agent/)': 'Invalid source folder (scripts/ or agent/ is missing)',
    'KhÃ´ng tháº¥y file wifi-socks.conf Ä‘Ã£ chá»n': 'The selected wifi-socks.conf file was not found',
    'KhÃ´ng tháº¥y file settings.sh Ä‘Ã£ chá»n': 'The selected settings.sh file was not found',
    'KhÃ´ng Ä‘á»c Ä‘Æ°á»£c token agent trÃªn router': 'Could not read the agent token on the router',
    'Agent chÆ°a tráº£ lá»i Ä‘Ãºng': 'The agent did not answer correctly',
    'ÄÃ£ dá»«ng theo yÃªu cáº§u': 'Stopped on request',
    'quÃ¡ thá»i gian chá»': 'timed out',
    'Kiá»ƒm tra káº¿t ná»‘i SSH': 'Check the SSH connection',
    'Äáº©y mÃ£ nguá»“n lÃªn router': 'Push the code to the router',
    'CÃ i gÃ³i phá»¥ thuá»™c': 'Install dependencies',
    'Äáº©y cáº¥u hÃ¬nh wifi-socks.conf': 'Push the wifi-socks.conf configuration',
    'Cháº¡y preflight vÃ  dry-run': 'Run preflight and dry-run',
    'Cháº¡y apply.sh khá»Ÿi táº¡o': 'Run the initial apply.sh',
    'CÃ i / cáº­p nháº­t agent': 'Install / update the agent',
    'Láº¥y token agent': 'Fetch the agent token',
    'Kiá»ƒm tra agent API': 'Check the agent API',
    'ÄÃ³ng gÃ³i mÃ£ nguá»“n': 'Package the code',
    'Äáº©y mÃ£ nguá»“n': 'Upload the code',
    'Giáº£i nÃ©n mÃ£ nguá»“n': 'Extract the code',
    'Äáº©y wifi-socks.conf': 'Upload wifi-socks.conf',
    'Äáº©y settings.sh': 'Upload settings.sh',
    'Äáº·t quyá»n cáº¥u hÃ¬nh': 'Set configuration permissions',
    'Cháº¡y preflight': 'Run preflight',
    'Dry-run apply': 'Dry-run apply',
    'Cháº¡y apply.sh': 'Run apply.sh',
    'CÃ i agent': 'Install the agent',
    'Äá»c token agent': 'Read the agent token',
    'CÃ i Ä‘áº·t router sau khi flash': 'Router setup after flashing',
    'CÃ€I Äáº¶T SAU KHI FLASH Láº I ROUTER': 'POST-FLASH ROUTER SETUP',
    'Äáº©y mÃ£ nguá»“n, cÃ i phá»¥ thuá»™c, Ä‘áº©y cáº¥u hÃ¬nh, cháº¡y script khá»Ÿi táº¡o, cÃ i agent rá»“i láº¥y token.': 'Push the code, install dependencies, push the configuration, run the initial scripts, install the agent, then fetch the token.',
    'ChÆ°a cháº¡y bÆ°á»›c nÃ o': 'No step has run yet',
    'TÃ i khoáº£n SSH': 'SSH account',
    'Port SSH': 'SSH port',
    'Máº­t kháº©u SSH': 'SSH password',
    'SSH key (tuá»³ chá»n)': 'SSH key (optional)',
    'ThÆ° má»¥c trÃªn router': 'Router directory',
    'MÃ£ nguá»“n hoáº·c gÃ³i .tar.gz': 'Source folder or .tar.gz package',
    'settings.sh (tuá»³ chá»n)': 'settings.sh (optional)',
    'Cháº¡y apply.sh sau khi Ä‘áº©y cáº¥u hÃ¬nh': 'Run apply.sh after pushing the configuration',
    'Báº¯t Ä‘áº§u cÃ i Ä‘áº·t': 'Start setup',
    'Kiá»ƒm tra tÃ¬nh tráº¡ng': 'Check status',
    'KHÃ”NG Cáº¤U HÃŒNH ÄÆ¯á»¢C ROUTER': 'ROUTER CANNOT BE CONFIGURED',
    'CÃ i agent ngay': 'Install the agent now',
    'Káº¿t ná»‘i SSH thÃ nh cÃ´ng nhÆ°ng router chÆ°a cÃ i xong agent. CÃ i ngay bÃ¢y giá»?': 'The SSH login works but the router has no agent installed yet. Install it now?',
    'Router Ä‘Ã£ cÃ³ agent vÃ  token â€” khÃ´ng cáº§n cÃ i láº¡i.': 'The router already has an agent and a token â€” no reinstall is needed.',
    'ÄÃ£ chá»n khÃ´ng cÃ i â€” console bá»‹ khoÃ¡ cho tá»›i khi agent Ä‘Æ°á»£c cÃ i.': 'Installing was declined â€” the console stays locked until an agent is installed.',
    'Router chÆ°a cÃ i agent nÃªn console khÃ´ng Ä‘iá»u khiá»ƒn Ä‘Æ°á»£c gÃ¬. HÃ£y cÃ i agent rá»“i thá»­ láº¡i.': 'With no agent on the router this console cannot control anything. Install the agent, then try again.',
    'KhÃ´ng cáº¥u hÃ¬nh Ä‘Æ°á»£c router â€” chÆ°a cÃ i agent': 'The router cannot be configured â€” no agent installed',
    'Dá»«ng': 'Stop',
    'ÄÃ³ng': 'Close',
    'BÆ°á»›c': 'Step',
    'Chá»n gÃ³i cáº­p nháº­t': 'Select the update package',
    'Chá»n thÆ° má»¥c mÃ£ nguá»“n': 'Select the source folder',
    'Chá»n file': 'Select a file',
    'Chá»': 'Pending',
    'Äang cháº¡y': 'Running',
    'Xong': 'Done',
    'CÃ i Ä‘áº·t chÆ°a hoÃ n táº¥t': 'Setup did not complete',
    'CÃ i Ä‘áº·t chÆ°a hoÃ n táº¥t â€” hÃ£y xá»­ lÃ½ bÆ°á»›c lá»—i rá»“i cháº¡y láº¡i.': 'Setup did not complete â€” fix the failed step and run it again.',
    'CÃ i Ä‘áº·t hoÃ n táº¥t': 'Setup complete',
    'CÃ i Ä‘áº·t hoÃ n táº¥t â€” Ä‘Ã£ láº¥y token vÃ  má»Ÿ mÃ n hÃ¬nh Ä‘iá»u khiá»ƒn.': 'Setup complete â€” the token was fetched and the control screens are open.',
    'Äang cÃ i Ä‘áº·t â€” váº«n Ä‘Ã³ng cá»­a sá»•?': 'Setup is running â€” close the window anyway?',
    'Agent tráº£ lá»i OK vá»›i token hiá»‡n táº¡i': 'The agent answers OK with the current token',
    'Agent Ä‘ang cháº¡y nhÆ°ng token sai hoáº·c thiáº¿u': 'The agent is running but the token is wrong or missing',
    'Router tráº£ lá»i nhÆ°ng chÆ°a cÃ i agent': 'The router answers but the agent is not installed',
    'KhÃ´ng liÃªn láº¡c Ä‘Æ°á»£c vá»›i router': 'The router cannot be reached',
    'ChÆ°a cáº¥u hÃ¬nh router â€” hÃ£y cháº¡y cÃ i Ä‘áº·t sau khi flash': 'Router not configured â€” run the post-flash setup',
    'CHÆ¯A Cáº¤U HÃŒNH ROUTER': 'ROUTER NOT CONFIGURED',
    'Router vá»«a flash láº¡i chÆ°a cÃ³ agent hoáº·c token. Cháº¡y cÃ i Ä‘áº·t Ä‘á»ƒ Ä‘áº©y mÃ£ nguá»“n, cáº¥u hÃ¬nh, script khá»Ÿi táº¡o vÃ  láº¥y token.': 'A freshly flashed router has no agent and no token. Run the setup to push the code, the configuration, and the initial scripts, then fetch the token.',
    'CÃ i Ä‘áº·t sau khi flashâ€¦': 'Post-flash setupâ€¦',
    'NÃ¢ng cáº¥p agent trÃªn router': 'Upgrade the router agent',
    'NÃ‚NG Cáº¤P AGENT TRÃŠN ROUTER': 'UPGRADE THE ROUTER AGENT',
    'Äáº©y gÃ³i cá»§a console lÃªn agent. Cáº¥u hÃ¬nh wifi-socks.conf vÃ  settings.sh Ä‘Æ°á»£c giá»¯ nguyÃªn.': "Upload this console's package to the agent. wifi-socks.conf and settings.sh are kept.",
    'Äang cháº¡yâ€¦': 'Runningâ€¦',
    'NÃ¢ng cáº¥p xong': 'Upgrade complete',
    'NÃ¢ng cáº¥p tháº¥t báº¡i': 'Upgrade failed',
    'NÃ¢ng cáº¥p xong â€” agent Ä‘Ã£ cháº¡y báº£n má»›i.': 'Upgrade complete â€” the agent is on the new version.',
    'NÃ¢ng cáº¥p dá»«ng láº¡i á»Ÿ bÆ°á»›c lá»—i. Sá»­a nguyÃªn nhÃ¢n rá»“i thá»­ láº¡i, hoáº·c cÃ i láº¡i agent qua SSH báº±ng CÃ i Ä‘áº·t sau khi flash â†’ CÃ i láº¡i agent dÃ¹ Ä‘Ã£ cÃ³.': 'The upgrade stopped at the failed step. Fix the cause and try again, or reinstall the agent over SSH with Post-flash setup â†’ Reinstall the agent even if it is present.',
    'Chuáº©n bá»‹ gÃ³i cáº­p nháº­t': 'Prepare the update package',
    'Kiá»ƒm tra phiÃªn báº£n agent': 'Check the agent version',
    'Äáº©y gÃ³i lÃªn agent': 'Upload the package to the agent',
    'Kiá»ƒm tra agent sau nÃ¢ng cáº¥p': 'Verify the agent afterwards',
    'KhÃ´ng tÃ¬m tháº¥y gÃ³i cáº­p nháº­t': 'No update package was found',
    'GÃ³i cáº­p nháº­t rá»—ng': 'The update package is empty',
    'ÄÆ°á»ng ra': 'Egress',
    'Äang Ä‘á»•i Ä‘Æ°á»ng raâ€¦': 'Changing the egressâ€¦',
    'Äang cáº­p nháº­t gateway trÃªn routerâ€¦': 'Updating the gateway setting on the routerâ€¦',
    'Äang lÆ°u lá»±a chá»n gatewayâ€¦': 'Saving the gateway selectionâ€¦',
    'ÄÃ£ lÆ°u lá»±a chá»n; Ä‘ang kiá»ƒm tra káº¿t ná»‘i qua gatewayâ€¦': 'Selection saved; checking connectivity through the gatewayâ€¦',
    'ÄÃ£ cáº­p nháº­t gateway: {interface}': 'Gateway updated: {interface}',
    'CÃ i agent riÃªng â€” bá» qua gÃ³i phá»¥ thuá»™c': 'Agent-only install â€” dependencies are unchanged',
    'CÃ i agent riÃªng â€” giá»¯ nguyÃªn cáº¥u hÃ¬nh': 'Agent-only install â€” configuration is preserved',
    'CÃ i agent riÃªng â€” khÃ´ng cháº¡y preflight': 'Agent-only install â€” preflight is skipped',
    'CÃ i agent riÃªng â€” khÃ´ng apply cáº¥u hÃ¬nh': 'Agent-only install â€” configuration is not applied',
    'ÄÆ°á»ng ra: dÃ¹ng {interface}': 'Egress: using {interface}',
    'tá»± Ä‘á»™ng': 'automatic',
    'KhÃ´ng má»Ÿ Ä‘Æ°á»£c cá»­a sá»• cÃ i Ä‘áº·t': 'Cannot open the setup window',
    'Äang kiá»ƒm tra tÃ¬nh tráº¡ng routerâ€¦': 'Checking the router statusâ€¦',
    'Pool proxyâ€¦': 'Proxy poolâ€¦',
    'Pool proxy': 'Proxy pool',
    'Äá»•i proxy cho thiáº¿t bá»‹ Ä‘Ã£ chá»nâ€¦': 'Change the proxy of the selected devicesâ€¦',
    'Äá»•i proxyâ€¦': 'Change proxyâ€¦',
    'GÃ¡n proxyâ€¦': 'Assign a proxyâ€¦',
    'HÃ£y chá»n thiáº¿t bá»‹ trong báº£ng trÆ°á»›c': 'Select devices in the table first',
    'Chá»‰ Ä‘á»•i proxy cho cÃ¡c thiáº¿t bá»‹ trong cÃ¹ng má»™t Wiâ€‘Fi':
        'Devices must be on the same Wi-Fi to share one split',
    'Wiâ€‘Fi nÃ y chÆ°a cÃ³ proxy nÃ o trong pool': 'This Wi-Fi has no proxy in its pool yet',
    'HÃ£y chá»n Ä‘Ãºng má»™t thiáº¿t bá»‹': 'Select exactly one device',
    'chÆ°a ghim': 'not pinned',
    'slot {slot} Ä‘Ã£ biáº¿n máº¥t': 'slot {slot} no longer exists',
    'KhÃ´ng ghim proxy': 'Do not pin a proxy',
    'MÃ¡y': 'Devices',
    'DÃ¡n danh sÃ¡ch proxy (má»—i dÃ²ng má»™t proxy)': 'Paste a proxy list, one per line',
    'Ghi pool': 'Save the pool',
    'Äang ghi pool proxyâ€¦': 'Saving the proxy poolâ€¦',
    'Äang Ä‘á»•i proxy cho thiáº¿t bá»‹â€¦': 'Changing the proxy of the devicesâ€¦',
    'Xem trÆ°á»›c cÃ¡ch chia proxy': 'Preview of the split',
    'Ãp dá»¥ng': 'Apply',
    'Nhá»¯ng dÃ²ng bá»‹ bá» qua': 'Lines that were left out',
    'KhÃ´ng cÃ³ dÃ²ng nÃ o dÃ¹ng Ä‘Æ°á»£c': 'No usable line in what was pasted',
}


def translate(text: str, language: str = "en", **values) -> str:
    translated = EN_TRANSLATIONS.get(text, text) if language == "en" else text
    if language == "en" and translated == text:
        dynamic_prefixes = (
            ("DÃ²ng cáº¥u hÃ¬nh cáº§n 10 hoáº·c 11 cá»™t: ", "Configuration row must have 10 or 11 columns: "),
            ("KhÃ´ng káº¿t ná»‘i Ä‘Æ°á»£c ", "Could not connect to "),
            ("Thiáº¿u cÃ´ng cá»¥ ", "Missing local tool "),
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

ALL_SSIDS = "Táº¥t cáº£ SSID"
ALL_BANDS = "Táº¥t cáº£ band"
ALL_PRESENCE = "Táº¥t cáº£ káº¿t ná»‘i"
ALL_STATES = "Táº¥t cáº£ quyá»n truy cáº­p"
ALL_SIGNALS = "Táº¥t cáº£ tÃ­n hiá»‡u"
ALL_TRAFFIC = "Táº¥t cáº£ lÆ°u lÆ°á»£ng"
ALL_DURATIONS = "Táº¥t cáº£ thá»i gian"
PRESENCE_FILTERS = (ALL_PRESENCE, "Online", "Offline")
CLIENT_STATES = (ALL_STATES, "Äang cáº¥m", "KhÃ´ng cáº¥m")
BAND_FILTERS = (ALL_BANDS, "2.4 GHz", "5 GHz")
SIGNAL_FILTERS = (
    ALL_SIGNALS,
    "Ráº¥t tá»‘t (â‰¥ -60 dBm)",
    "Tá»‘t (-70 Ä‘áº¿n -61 dBm)",
    "Yáº¿u (-80 Ä‘áº¿n -71 dBm)",
    "Ráº¥t yáº¿u (< -80 dBm)",
    "KhÃ´ng rÃµ",
)
TRAFFIC_FILTERS = (
    ALL_TRAFFIC,
    "CÃ³ lÆ°u lÆ°á»£ng",
    "KhÃ´ng lÆ°u lÆ°á»£ng",
    "Tá»« 10 MB",
    "Tá»« 100 MB",
)
DURATION_FILTERS = (
    ALL_DURATIONS,
    "DÆ°á»›i 5 phÃºt",
    "5â€“60 phÃºt",
    "TrÃªn 1 giá»",
)

MAC_VENDORS = (
    ("Ngáº«u nhiÃªn / áº©n danh", ""),
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
            suffix = f" Â· {item_oui}" if item_oui else " Â· 02:xx local"
            return name + suffix
    return f"OUI tuá»³ chá»‰nh Â· {normalized}"


def vendor_oui(label: str) -> str:
    for name, oui in MAC_VENDORS:
        if label in (vendor_label(oui), translate(vendor_label(oui), "en")):
            return oui
    match = re.search(r"([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){2})$", label)
    if match:
        return match.group(1).upper()
    raise ValueError("KhÃ´ng xÃ¡c Ä‘á»‹nh Ä‘Æ°á»£c OUI cá»§a hÃ£ng Ä‘Ã£ chá»n")


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
        raise RuntimeError("DPAPI chá»‰ cÃ³ trÃªn Windows")
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
        raise RuntimeError("DPAPI chá»‰ cÃ³ trÃªn Windows")
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


# --- Proxy pool ------------------------------------------------------------
# A slot is a row's position in the pool, so identity here must match the one
# lib.sh uses when it carries pins across a replacement: the endpoint and its
# credentials, never the label.
PROXY_SCHEMES = {"socks5": "socks5", "socks5h": "socks5", "socks": "socks5", "http": "http"}
DEFAULT_PROXY_TYPE = "socks5"


def _proxy_port(value: str) -> int:
    """Port as an int, or ValueError with a message the operator can act on."""
    if not value.isdigit():
        raise ValueError("cá»•ng pháº£i lÃ  sá»‘")
    port = int(value)
    if not 1 <= port <= 65535:
        raise ValueError("cá»•ng pháº£i trong khoáº£ng 1..65535")
    return port


def _proxy_host(value: str) -> str:
    if not value:
        raise ValueError("thiáº¿u host")
    if len(value) > 253 or any(c.isspace() for c in value):
        raise ValueError("host khÃ´ng há»£p lá»‡")
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:-_")
    if set(value) - allowed:
        raise ValueError("host khÃ´ng há»£p lá»‡")
    return value


def parse_proxy_line(line: str) -> tuple:
    """One pasted line -> (type, host, port, user, password, label).

    Accepted, in the order they are tried:
        scheme://user:pass@host:port
        scheme://host:port
        user:pass@host:port
        host:port:user:pass
        host:port
    """
    text = line.strip()
    proxy_type = DEFAULT_PROXY_TYPE
    if "://" in text:
        scheme, _, text = text.partition("://")
        scheme = scheme.strip().lower()
        if scheme not in PROXY_SCHEMES:
            raise ValueError(f"loáº¡i proxy khÃ´ng há»— trá»£: {scheme}")
        proxy_type = PROXY_SCHEMES[scheme]

    user = password = ""
    if "@" in text:
        # Split on the LAST @: a password is allowed to contain one, and
        # splitting on the first would read the host out of the password.
        credentials, _, text = text.rpartition("@")
        # Split credentials on the FIRST colon, for the same reason.
        user, _, password = credentials.partition(":")

    parts = text.split(":")
    if len(parts) == 4 and not user:
        # host:port:user:pass -- only meaningful when no @ supplied credentials.
        host, port, user, password = parts
    elif len(parts) == 2:
        host, port = parts
    else:
        raise ValueError("thiáº¿u cá»•ng" if len(parts) == 1 else "khÃ´ng nháº­n ra Ä‘á»‹nh dáº¡ng")

    return (proxy_type, _proxy_host(host.strip()), _proxy_port(port.strip()),
            user, password, "")


def parse_proxy_list(text: str, limit: int | None = None) -> tuple:
    """Parse a pasted list into (rows, dropped).

    `dropped` carries (line number, original text, reason) for every line left
    out, so the console can say what happened instead of quietly shortening the
    list -- including when the cap is reached.
    """
    rows: list = []
    dropped: list = []
    seen: set = set()
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "|" in line:
            dropped.append((number, line, "chá»©a kÃ½ tá»± | vá»‘n lÃ  dáº¥u phÃ¢n cÃ¡ch cá»§a cáº¥u hÃ¬nh"))
            continue
        if any(ord(c) < 32 or ord(c) == 127 for c in line):
            dropped.append((number, line, "chá»©a kÃ½ tá»± Ä‘iá»u khiá»ƒn"))
            continue
        try:
            row = parse_proxy_line(line)
        except ValueError as exc:
            dropped.append((number, line, str(exc)))
            continue
        identity = row[:5]
        if identity in seen:
            dropped.append((number, line, "trÃ¹ng vá»›i má»™t proxy Ä‘Ã£ cÃ³ á»Ÿ trÃªn"))
            continue
        if limit is not None and len(rows) >= limit:
            dropped.append((number, line, f"vÆ°á»£t quÃ¡ giá»›i háº¡n {limit} proxy cho má»™t Wi-Fi"))
            continue
        seen.add(identity)
        rows.append(row)
    return rows, dropped


def split_devices_evenly(devices, slots: int, seed=None) -> dict:
    """Deal devices over slots: shuffle, then round-robin.

    The counts differ by at most one, and the layout is reproducible from the
    seed -- which is what lets the preview and the request that follows it agree
    instead of shuffling twice.
    """
    if slots <= 0:
        raise ValueError("Wi-Fi nÃ y chÆ°a cÃ³ proxy nÃ o trong pool")
    unique: list = []
    for mac in devices:
        mac = str(mac).strip().lower()
        if mac and mac not in unique:
            unique.append(mac)
    if not unique:
        return {}
    order = list(unique)
    random.Random(seed).shuffle(order)
    return {mac: index % slots for index, mac in enumerate(order)}


POOL_SLOTS_PER_SSID_MAX = 256


def proxy_display(row) -> str:
    """One pool row as the operator named it, or as its endpoint.

    Credentials are deliberately absent: this string ends up in tables, logs and
    screenshots, and the label is what an operator recognises anyway.
    """
    if not isinstance(row, dict):
        return ""
    label = str(row.get("label") or "").strip()
    if label:
        return label
    host = str(row.get("host") or "").strip()
    port = row.get("port")
    return f"{host}:{port}" if host and port else host


def client_proxy_text(item, language: str = "vi") -> str:
    """The Proxy column for one device.

    Four states, not two: an SSID with no pool, a device nobody pinned, a pin
    that resolves, and a pin left pointing past the end of a shortened pool.
    That last one has to stand out, because it is the one that needs fixing.
    """
    state = str((item or {}).get("proxy_state") or "")
    if state == "pinned":
        return str(item.get("proxy_label") or "").strip() or str(item.get("proxy_host") or "")
    if state == "unpinned":
        return translate("chÆ°a ghim", language)
    if state == "stale":
        return translate("slot {slot} Ä‘Ã£ biáº¿n máº¥t", language, slot=item.get("slot"))
    return "â€”"


def pool_slot_usage(clients, idx, slots: int) -> list:
    """How many devices sit on each slot of one Wi-Fi's pool.

    A pin past the end of the pool is left out rather than wrapped: crediting it
    to `slot % len(pool)` would blame an unrelated proxy for the load.
    """
    counts = [0] * max(0, int(slots))
    for item in clients or []:
        if not isinstance(item, dict):
            continue
        try:
            if int(item.get("idx")) != int(idx):
                continue
            slot = int(item.get("slot"))
        except (TypeError, ValueError):
            continue
        if 0 <= slot < len(counts):
            counts[slot] += 1
    return counts


def parse_version(value) -> tuple | None:
    """`"0.4.0"` -> `(0, 4, 0)`; anything else -> None."""
    match = re.fullmatch(r"\s*([0-9]+)\.([0-9]+)\.([0-9]+)(?:-SNAPSHOT)?\s*", str(value or ""))
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


class Skipped(str):
    """A step that legitimately did nothing; the text says why."""


class ProvisionError(RuntimeError):
    """A provisioning step failed; the message is already operator-readable.

    `output` keeps everything the failed command printed, so the wizard can
    show the router's own words even though the checklist has room for one
    line.
    """

    def __init__(self, message, output=""):
        super().__init__(message)
        self.output = output


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
    written through the file descriptor (and the Win32 handle) instead â€” that
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


def hidden_process_options() -> dict:
    """subprocess keywords that keep a console window from appearing.

    ssh, scp and tar are console programs. Started from a windowed build (which
    has no console of its own) Windows gives each one a fresh console window,
    so a provisioning run flashes a black window for every single step.
    CREATE_NO_WINDOW suppresses that; STARTF_USESHOWWINDOW covers the shells
    that ignore it. Both are Windows-only.
    """
    if os.name != "nt":
        return {}
    startupinfo = subprocess.STARTUPINFO()
    startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startupinfo.wShowWindow = subprocess.SW_HIDE
    return {
        "creationflags": getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000),
        "startupinfo": startupinfo,
    }


# Onefile bootloader state that a grandchild process must not inherit.
PYINSTALLER_CHILD_VARS = (
    "_PYI_ARCHIVE_FILE",
    "_PYI_APPLICATION_HOME_DIR",
    "_PYI_PARENT_PROCESS_LEVEL",
    "_PYI_SPLASH_IPC",
    "_MEIPASS2",
)


def clean_child_environment(env: dict) -> dict:
    """Strip the PyInstaller state ssh would pass on to the askpass helper.

    ssh spawns SSH_ASKPASS itself, so this executable runs with ssh â€” not with
    itself â€” as its parent. The onefile bootloader finds its own variables in
    the inherited environment, checks that the parent runs the same executable,
    and aborts with "Security validation failure: parent process has different
    executable!". Removing those variables (and asking the bootloader to reset)
    makes the askpass call bootstrap like any ordinary first run.
    """
    for name in PYINSTALLER_CHILD_VARS:
        env.pop(name, None)
    env["PYINSTALLER_RESET_ENVIRONMENT"] = "1"
    return env


def is_decoration(line: str) -> bool:
    """True for a banner or section header that explains no failure.

    Router scripts print headings like `==== 2. Radio-to-band mapping ====`.
    When a script dies right after one, that heading is the last unindented
    line and makes a useless error message.
    """
    stripped = line.strip()
    if not stripped:
        return True
    return bool(re.fullmatch(r"[=\-*#~_]{2,}.*?[=\-*#~_]{2,}", stripped)) or \
        bool(re.fullmatch(r"[=\-*#~_]{3,}", stripped))


def failure_line(output: str) -> str:
    """The most useful single line of a failed command's output.

    Three cases this has to survive: a tool that rejects its arguments and
    answers with a wrapped usage block (whose last line is the meaningless
    fragment "[-S program] source ... target"), a router script that dies
    right after printing a section header, and an ordinary error on the last
    line.
    """
    lines = [line.rstrip() for line in str(output or "").splitlines() if line.strip()]
    if not lines:
        return ""
    for line in lines:
        if line.lower().startswith("usage:"):
            return line
    for line in reversed(lines):
        if line.lower().startswith(("[sbproxy][err]", "error", "fatal")):
            return line
    for line in reversed(lines):
        if not is_decoration(line):
            return line.strip()
    return lines[-1].strip()


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
    agent_only: bool = False

    def validate(self) -> None:
        if not str(self.host).strip():
            raise ValueError("Thiáº¿u Ä‘á»‹a chá»‰ router")
        if not str(self.user).strip():
            raise ValueError("Thiáº¿u tÃ i khoáº£n SSH")
        try:
            port = int(self.port)
        except (TypeError, ValueError):
            raise ValueError("Port SSH khÃ´ng há»£p lá»‡") from None
        if not 1 <= port <= 65535:
            raise ValueError("Port SSH khÃ´ng há»£p lá»‡")
        if not str(self.remote_dir).startswith("/"):
            raise ValueError("ThÆ° má»¥c trÃªn router pháº£i lÃ  Ä‘Æ°á»ng dáº«n tuyá»‡t Ä‘á»‘i")
        if self.key_path and not Path(self.key_path).is_file():
            raise ValueError("KhÃ´ng tháº¥y SSH key")
        if not self.payload:
            raise ValueError("ChÆ°a chá»n mÃ£ nguá»“n hoáº·c gÃ³i cáº­p nháº­t")
        if not Path(self.payload).exists():
            raise ValueError("KhÃ´ng tháº¥y mÃ£ nguá»“n hoáº·c gÃ³i cáº­p nháº­t")

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

    def upload_command(self, remote: str) -> list[str]:
        """Write a file on the router by piping it into `cat` over ssh.

        scp is deliberately not used. Its SFTP mode needs an sftp-server the
        stock OpenWrt/dropbear images do not carry, its legacy mode needs an
        `scp` binary on the router that those images do not carry either, and
        the `-O` flag that selects legacy mode does not exist in OpenSSH
        clients older than 8.6 -- those answer with a usage message instead of
        copying anything. `cat` is in BusyBox on every image.
        """
        return self.ssh_command(f"cat > {shlex.quote(remote)}")

    def to_payload(self) -> dict:
        """Persistable form â€” the password is deliberately left out."""
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
        raise ProvisionError("ChÆ°a chá»n mÃ£ nguá»“n hoáº·c gÃ³i cáº­p nháº­t")
    if source.is_file():
        return source
    entries = [name for name in PAYLOAD_ENTRIES if (source / name).exists()]
    if "scripts" not in entries or "agent" not in entries:
        raise ProvisionError("ThÆ° má»¥c mÃ£ nguá»“n khÃ´ng há»£p lá»‡ (thiáº¿u scripts/ hoáº·c agent/)")
    ensure_app_home()
    package = CACHE_DIR / f"sbproxy-update-{payload_version(source) or APP_VERSION}.tar.gz"
    completed = subprocess.run(  # noqa: S603 - fixed argv, never a shell
        ["tar", "-czf", str(package), "-C", str(source), "--exclude=node_modules",
         "--exclude=__pycache__", "--exclude=dist", "--exclude=build", *entries],
        capture_output=True, text=True, timeout=300, errors="replace",
        **hidden_process_options(),
    )
    if completed.returncode != 0:
        raise ProvisionError(f"ÄÃ³ng gÃ³i mÃ£ nguá»“n: {(completed.stderr or '').strip() or 'tar lá»—i'}")
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
        raise ProvisionError("KhÃ´ng Ä‘á»c Ä‘Æ°á»£c token agent trÃªn router")
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
    match = re.search(r"sbproxy-update-([0-9]+\.[0-9]+\.[0-9]+(?:-SNAPSHOT)?)\.tar\.gz$", candidate.name)
    return match.group(1) if match else ""


ROUTER_INVENTORY_KEYS = ("code", "conf", "deps", "agent", "token", "running")

ROUTER_INVENTORY_LABELS = {
    "code": "MÃ£ nguá»“n trÃªn router",
    "conf": "Cáº¥u hÃ¬nh wifi-socks.conf",
    "deps": "GÃ³i phá»¥ thuá»™c (sing-box)",
    "agent": "Agent CGI",
    "token": "Token agent",
    "running": "sing-box Ä‘ang cháº¡y",
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
        parts.append(translate("ÄÃ£ cÃ³", language) + ": " + ", ".join(translate(item, language) for item in present))
    if missing:
        parts.append(translate("ChÆ°a cÃ³", language) + ": " + ", ".join(translate(item, language) for item in missing))
    return " Â· ".join(parts)


class ProvisionRunner:
    """Drive the post-flash sequence step by step and report progress.

    `emit(index, state, detail)` fires on every state change so the UI can tick
    the checklist live; `runner` and `prober` are injectable so tests never
    shell out or touch the network.
    """

    def __init__(self, settings: ProvisionSettings, emit=None, runner=None, prober=None,
                 version_reader=None, on_output=None):
        self.settings = settings
        self.emit = emit or (lambda *_args: None)
        # Everything a failing command printed, for the log pane.
        self.on_output = on_output or (lambda _text: None)
        self._execute = runner or self._run_process
        self._probe = prober or probe_router_state
        self._agent_version = version_reader or read_agent_version
        self.token = ""
        self.cancelled = False
        self.inventory = {key: False for key in ROUTER_INVENTORY_KEYS}
        self.pushed_version = ""  # version of the package this run put on the router
        self.router_version = ""   # version already on the router, before the push
        self.steps = [
            ("Kiá»ƒm tra káº¿t ná»‘i SSH", self.step_check_ssh),
            ("Kiá»ƒm tra hiá»‡n tráº¡ng router", self.step_inventory),
            ("Äáº©y mÃ£ nguá»“n lÃªn router", self.step_push_code),
            ("CÃ i gÃ³i phá»¥ thuá»™c", self.step_install_deps),
            ("Äáº©y cáº¥u hÃ¬nh wifi-socks.conf", self.step_push_config),
            ("Cháº¡y preflight vÃ  dry-run", self.step_preflight),
            ("Cháº¡y apply.sh khá»Ÿi táº¡o", self.step_apply),
            ("CÃ i / cáº­p nháº­t agent", self.step_install_agent),
            ("Láº¥y token agent", self.step_fetch_token),
            ("Kiá»ƒm tra agent API", self.step_verify_agent),
        ]

    # -- process plumbing ---------------------------------------------------

    def _environment(self) -> dict:
        env = clean_child_environment(os.environ.copy())
        if self.settings.password:
            env["SBPROXY_SSH_PASSWORD"] = self.settings.password
            env["SBPROXY_ASKPASS"] = "1"
            env["SSH_ASKPASS"] = askpass_helper()
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env.setdefault("DISPLAY", ":0")
        else:
            env.pop("SBPROXY_SSH_PASSWORD", None)
        return env

    def _run_process(self, argv, timeout=600, stdin_path=None):
        options = dict(
            capture_output=True, text=True, timeout=timeout,
            env=self._environment(), errors="replace", **hidden_process_options(),
        )
        if stdin_path is None:
            completed = subprocess.run(argv, **options)  # noqa: S603 - fixed argv, never a shell
        else:
            with open(stdin_path, "rb") as source:
                completed = subprocess.run(argv, stdin=source, **options)  # noqa: S603
        return completed.returncode, completed.stdout or "", completed.stderr or ""

    def run_command(self, argv, description, timeout=600, stdin_path=None) -> str:
        if self.cancelled:
            raise ProvisionError("ÄÃ£ dá»«ng theo yÃªu cáº§u")
        log.info("provision: %s", redact(" ".join(argv)))
        # Only pass the keyword when it is used, so an injected runner that
        # does not take it keeps working for every other call.
        extra = {"stdin_path": stdin_path} if stdin_path else {}
        try:
            code, out, err = self._execute(argv, timeout=timeout, **extra)
        except FileNotFoundError as exc:
            raise ProvisionError(f"Thiáº¿u cÃ´ng cá»¥ {argv[0]}") from exc
        except subprocess.TimeoutExpired as exc:
            raise ProvisionError(f"{description}: quÃ¡ thá»i gian chá»") from exc
        output = (out + ("\n" + err if err.strip() else "")).strip()
        if code != 0:
            # One line reaches the checklist; the whole thing reaches the log,
            # which is what a support bundle needs.
            log.warning("provision failed (%s): %s", description, redact(output) or f"exit {code}")
            if output:
                self.on_output(output)
            raise ProvisionError(f"{description}: {failure_line(output) or f'exit {code}'}", output)
        return output

    def ssh(self, remote_command, description, timeout=600) -> str:
        return self.run_command(self.settings.ssh_command(remote_command), description, timeout)

    def upload(self, local, remote, description) -> str:
        """Send a local file to `remote` and prove that all of it arrived."""
        source = Path(local)
        try:
            size = source.stat().st_size
        except OSError as exc:
            raise ProvisionError(f"{description}: khÃ´ng Ä‘á»c Ä‘Æ°á»£c file cáº§n Ä‘áº©y") from exc
        self.run_command(self.settings.upload_command(remote), description,
                         timeout=600, stdin_path=str(source))
        # A truncated transfer can still exit 0, so compare what actually landed.
        answer = self.ssh(f"wc -c < {shlex.quote(remote)}", description, timeout=120)
        landed = answer.split()[-1] if answer.split() else ""
        if landed != str(size):
            raise ProvisionError(
                f"{description}: file trÃªn router lá»‡ch kÃ­ch thÆ°á»›c "
                f"({landed or '?'} / {size} byte)"
            )
        return f"{remote} Â· {human_bytes(size)}"

    # -- steps --------------------------------------------------------------

    def step_check_ssh(self) -> str:
        board = self.ssh(
            'uname -sr; . /etc/openwrt_release 2>/dev/null && echo "$DISTRIB_DESCRIPTION"; exit 0',
            "Kiá»ƒm tra káº¿t ná»‘i SSH", timeout=90,
        )
        return board.replace("\n", " Â· ") or self.settings.target

    def step_inventory(self) -> str:
        """Look before installing: reuse dependencies, config, and agent."""
        output = self.ssh(router_inventory_command(self.settings.remote_dir),
                          "Kiá»ƒm tra hiá»‡n tráº¡ng router", timeout=90)
        self.inventory = parse_router_inventory(output)
        self.router_version = parse_inventory_version(output)
        summary = describe_router_inventory(self.inventory)
        return f"v{self.router_version} Â· {summary}" if self.router_version else summary

    def package_payload(self, workdir: Path) -> Path:
        """Return a tarball of router-side files, building one from a checkout."""
        source = Path(self.settings.payload)
        if source.is_file():
            return source
        entries = [name for name in PAYLOAD_ENTRIES if (source / name).exists()]
        if "scripts" not in entries or "agent" not in entries:
            raise ProvisionError("ThÆ° má»¥c mÃ£ nguá»“n khÃ´ng há»£p lá»‡ (thiáº¿u scripts/ hoáº·c agent/)")
        package = workdir / "sbproxy-payload.tar.gz"
        self.run_command(
            ["tar", "-czf", str(package), "-C", str(source), "--exclude=node_modules", *entries],
            "ÄÃ³ng gÃ³i mÃ£ nguá»“n", timeout=300,
        )
        return package

    def step_push_code(self) -> str:
        remote = self.settings.remote_dir
        available = payload_version(self.settings.payload)
        if self.router_version and available and compare_versions(available, self.router_version) == -1:
            raise ProvisionError(
                "Router Ä‘ang cháº¡y báº£n má»›i hÆ¡n gÃ³i cÃ i, hÃ£y dÃ¹ng console má»›i hÆ¡n: "
                f"{self.router_version} > {available}"
            )
        workdir = Path(tempfile.mkdtemp(prefix="sbproxy-provision-", dir=str(CACHE_DIR) if CACHE_DIR.is_dir() else None))
        try:
            package = self.package_payload(workdir)
            self.upload(package, "/tmp/sbproxy-update.tar.gz", "Äáº©y mÃ£ nguá»“n")
            self.ssh(
                f"set -e; mkdir -p {remote}; tar xzf /tmp/sbproxy-update.tar.gz -C {remote}; "
                f"chmod +x {remote}/scripts/*.sh {remote}/agent/install-agent.sh; "
                "rm -f /tmp/sbproxy-update.tar.gz",
                "Giáº£i nÃ©n mÃ£ nguá»“n", timeout=300,
            )
            self.pushed_version = payload_version(package) or payload_version(self.settings.payload)
            size = package.stat().st_size if package.is_file() else 0
            detail = f"{remote} Â· {human_bytes(size)}" if size else remote
            return f"{detail} Â· v{self.pushed_version}" if self.pushed_version else detail
        finally:
            shutil.rmtree(workdir, ignore_errors=True)

    def step_install_deps(self) -> str:
        if self.settings.agent_only:
            return Skipped("CÃ i agent riÃªng â€” bá» qua gÃ³i phá»¥ thuá»™c")
        if self.inventory.get("deps"):
            return ""  # sing-box is already installed; nothing to add
        output = self.ssh(
            f"cd {self.settings.remote_dir}; sh scripts/install-deps.sh",
            "CÃ i gÃ³i phá»¥ thuá»™c", timeout=1200,
        )
        lines = output.splitlines()
        return lines[-1] if lines else "OK"

    def step_push_config(self) -> str:
        if self.settings.agent_only:
            return Skipped("CÃ i agent riÃªng â€” giá»¯ nguyÃªn cáº¥u hÃ¬nh")
        remote = self.settings.remote_dir
        if self.inventory.get("conf") and not self.settings.overwrite_config:
            return ""  # the router already has a configuration; keep it
        pushed = []
        if self.settings.config_path:
            if not Path(self.settings.config_path).is_file():
                raise ProvisionError("KhÃ´ng tháº¥y file wifi-socks.conf Ä‘Ã£ chá»n")
            self.upload(self.settings.config_path, f"{remote}/config/wifi-socks.conf", "Äáº©y wifi-socks.conf")
            pushed.append("wifi-socks.conf")
        if self.settings.settings_path:
            if not Path(self.settings.settings_path).is_file():
                raise ProvisionError("KhÃ´ng tháº¥y file settings.sh Ä‘Ã£ chá»n")
            self.upload(self.settings.settings_path, f"{remote}/config/settings.sh", "Äáº©y settings.sh")
            pushed.append("settings.sh")
        if not pushed:
            return self.seed_empty_config()
        self.ssh(f"chmod 600 {remote}/config/wifi-socks.conf 2>/dev/null; exit 0",
                 "Äáº·t quyá»n cáº¥u hÃ¬nh", timeout=60)
        return " + ".join(pushed)

    def seed_empty_config(self) -> str:
        """Give the router an empty wifi-socks.conf carrying the column notes.

        Nothing else creates this file: the real one is never committed, so a
        package only ships `wifi-socks.conf.example`. Without it `apply.sh`
        refuses to run, and the operator has nothing to read when they open the
        file later. The comment header of the example is exactly that
        documentation, so it is copied without the sample rows.
        """
        remote = self.settings.remote_dir
        answer = self.ssh(
            f"cd {remote} || exit 1; "
            "if [ -s config/wifi-socks.conf ]; then echo state=kept; exit 0; fi; "
            "mkdir -p config; "
            "if [ -f config/wifi-socks.conf.example ]; then "
            "grep '^#' config/wifi-socks.conf.example > config/wifi-socks.conf; "
            "else { "
            "echo '# wifi-socks.conf - one Wi-Fi per row, fields separated by |'; "
            "echo '# name|band|idx|wifi_key|proxy_host|proxy_port|proxy_user|proxy_pass|isolate|webrtc|mac_oui|proxy_type'; "
            "} > config/wifi-socks.conf; fi; "
            "chmod 600 config/wifi-socks.conf; echo state=created",
            "Táº¡o wifi-socks.conf trá»‘ng", timeout=90,
        )
        if "state=created" not in answer:
            return ""  # the router already had one; nothing was written
        return "wifi-socks.conf trá»‘ng (kÃ¨m chÃº thÃ­ch cÃ¡c cá»™t)"

    def router_has_config(self) -> bool:
        """True when the router carries a non-empty wifi-socks.conf.

        Asked of the router rather than inferred, so it stays right whether the
        file was pushed by this run, left over from an earlier one, or absent
        because the operator has none yet.
        """
        answer = self.ssh(
            f"[ -s {self.settings.remote_dir}/config/wifi-socks.conf ] && echo have=1; exit 0",
            "Kiá»ƒm tra wifi-socks.conf", timeout=60,
        )
        return "have=1" in answer

    def step_preflight(self) -> str:
        if self.settings.agent_only:
            return Skipped("CÃ i agent riÃªng â€” khÃ´ng cháº¡y preflight")
        self.ssh(f"cd {self.settings.remote_dir}; sh scripts/preflight.sh", "Cháº¡y preflight", timeout=600)
        # apply.sh refuses to run without a configuration, and starting without
        # one is a supported path: Wi-Fi entries get added in the console after
        # the agent is up.
        if not self.router_has_config():
            return Skipped("preflight OK Â· chÆ°a cÃ³ wifi-socks.conf nÃªn bá» qua dry-run")
        self.ssh(f"cd {self.settings.remote_dir}; DRYRUN=1 sh scripts/apply.sh >/dev/null",
                 "Dry-run apply", timeout=600)
        return "preflight + dry-run OK"

    def step_apply(self) -> str:
        if self.settings.agent_only:
            return Skipped("CÃ i agent riÃªng â€” khÃ´ng apply cáº¥u hÃ¬nh")
        if not self.settings.run_apply:
            return ""
        if not self.router_has_config():
            return Skipped("ChÆ°a cÃ³ wifi-socks.conf â€” thÃªm Wi-Fi trong app rá»“i báº¥m Äáº©y cáº¥u hÃ¬nh & Apply")
        output = self.ssh(f"cd {self.settings.remote_dir}; sh scripts/apply.sh",
                          "Cháº¡y apply.sh", timeout=1800)
        lines = output.splitlines()
        return lines[-1] if lines else "apply OK"

    def step_install_agent(self) -> str:
        if not self.settings.reinstall_agent and self.agent_matches_pushed_code():
            return ""  # the installed agent is already this exact code
        self.ssh(f"cd {self.settings.remote_dir}; sh agent/install-agent.sh", "CÃ i agent", timeout=1200)
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
            "So khá»›p agent Ä‘Ã£ cÃ i", timeout=90,
        )
        return "same=1" in answer

    def step_fetch_token(self) -> str:
        raw = self.ssh(f"cat {REMOTE_TOKEN_FILE}", "Äá»c token agent", timeout=60)
        self.token = parse_router_token(raw)
        save_connection(self.settings.base_url, self.token)
        return f"{self.settings.base_url} Â· token ok"

    def step_verify_agent(self) -> str:
        state = self._probe(self.settings.base_url, self.token)
        if state != "ok":
            raise ProvisionError(f"Agent chÆ°a tráº£ lá»i Ä‘Ãºng: {ROUTER_STATE_LABELS.get(state, state)}")
        expected = self.pushed_version or APP_VERSION
        reported = self._agent_version(self.settings.base_url, self.token)
        if reported and compare_versions(reported, expected) != 0:
            # "head: detail" so translate() renders both halves in English.
            raise ProvisionError(
                f"Agent váº«n cháº¡y version cÅ©, hÃ£y cháº¡y láº¡i vÃ  tick â€œCÃ i láº¡i agent dÃ¹ Ä‘Ã£ cÃ³â€: "
                f"{reported} â‰  {expected}"
            )
        return f"status ok Â· agent v{reported}" if reported else "status ok"

    # -- orchestration ------------------------------------------------------

    def cancel(self) -> None:
        self.cancelled = True

    def run(self) -> bool:
        """Execute every step in order and stop at the first failure."""
        self.settings.validate()
        audit("provision.start", router=self.settings.target,
              payload=payload_version(self.settings.payload) or "?")
        for index, (label, function) in enumerate(self.steps):
            if self.cancelled:
                audit("provision.cancelled", router=self.settings.target, step=label)
                self.emit(index, STEP_FAILED, "ÄÃ£ dá»«ng theo yÃªu cáº§u")
                return False
            self.emit(index, STEP_RUNNING, "")
            try:
                detail = function()
            except ProvisionError as exc:
                audit("provision.failed", router=self.settings.target, step=label, detail=exc)
                self.emit(index, STEP_FAILED, str(exc))
                return False
            except Exception as exc:  # unexpected local failure, same UI path
                log.exception("provision step failed: %s", label)
                audit("provision.failed", router=self.settings.target, step=label, detail=exc)
                self.emit(index, STEP_FAILED, str(exc))
                return False
            skipped = isinstance(detail, Skipped) or not detail
            self.emit(index, STEP_SKIPPED if skipped else STEP_OK, detail or "Bá» qua")
        audit("provision.finished", router=self.settings.target,
              agent=self.pushed_version or self.router_version or "?")
        return True


# Actions that change the router. Reads (status, clients, gateway, backups)
# are polled constantly and would drown the audit trail without adding
# anything to it.
AUDITED_ACTIONS = frozenset({
    "save_conf", "apply", "set_sock", "rotate_mac", "backup", "rollback",
    "update", "uninstall", "kick", "ban", "unban", "rotate_token", "set_gateway",
    "save_pool", "assign_proxy", "rebalance",
})


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
            # CGI agents (especially uhttpd/dropbear-era deployments) rely on
            # CONTENT_LENGTH to expose a POST body on stdin.  urllib normally
            # adds this header later, but making it explicit is important for
            # raw archive uploads: some frozen/runtime HTTP stacks otherwise
            # send the request without a length and the CGI sees an empty
            # temporary file, producing the misleading "not a .tar.gz" error.
            headers["Content-Length"] = str(len(data))
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
            self._audit(action, router=self.base_url, result=f"http-{exc.code}", detail=detail)
            raise AgentError(f"HTTP {exc.code}: {detail}") from exc
        except (URLError, TimeoutError, OSError) as exc:
            log.warning("agent %s %s -> transport error: %s", method, action, redact(exc))
            self._audit(action, router=self.base_url, result="unreachable", detail=exc)
            raise AgentError(f"KhÃ´ng káº¿t ná»‘i Ä‘Æ°á»£c {self.base_url} trong {request_timeout}s: {exc}") from exc
        elapsed = (time.monotonic() - started) * 1000
        log.info("agent %s %s -> %s bytes in %.0f ms", method, action, len(raw), elapsed)
        self._audit(action, router=self.base_url, result="ok", ms=f"{elapsed:.0f}")

        decoded = raw.decode("utf-8", "replace")
        if text:
            return decoded
        try:
            payload = json.loads(decoded)
        except json.JSONDecodeError as exc:
            raise AgentError("Agent tráº£ dá»¯ liá»‡u khÃ´ng pháº£i JSON") from exc
        if not isinstance(payload, dict):
            raise AgentError("Agent tráº£ JSON khÃ´ng pháº£i object")
        if payload.get("ok") is False:
            raise AgentError(payload.get("error") or payload.get("log") or "Agent bÃ¡o lá»—i")
        return payload

    def _audit(self, action: str, **fields) -> None:
        if action in AUDITED_ACTIONS:
            audit(f"agent.{action}", **fields)

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
            "type": record.proxy_type,
        }, timeout=60)

    def set_gateway(self, interface: str):
        """Pin which interface counts as the uplink; "" means automatic."""
        return self._request("set_gateway", "POST", {"interface": interface}, timeout=30)

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

    def get_pool(self, idx: int):
        return self._request("get_pool", query={"idx": str(idx)}, timeout=20)

    @staticmethod
    def _pool_objects(rows) -> list:
        """Parser tuples -> the object shape the agent's jq schema validates."""
        return [{"type": row[0], "host": row[1], "port": row[2],
                 "user": row[3], "pass": row[4], "label": row[5]} for row in rows]

    def save_pool(self, idx: int, rows):
        return self._request("save_pool", "POST",
                             body={"idx": idx, "proxies": self._pool_objects(rows)},
                             timeout=120)

    def assign_proxy(self, idx: int, assignments):
        return self._request("assign_proxy", "POST",
                             body={"idx": idx, "assignments": list(assignments)},
                             timeout=120)

    def rebalance(self, idx: int, macs, proxies=None, seed=None):
        body = {"idx": idx, "macs": list(macs)}
        if proxies is not None:
            body["proxies"] = self._pool_objects(proxies)
        if seed is not None:
            body["seed"] = seed
        return self._request("rebalance", "POST", body=body, timeout=180)

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


def parse_proxy_compact(value: str) -> tuple[str, int, str, str]:
    """Parse host:port:user:password copied from a proxy provider."""
    if not isinstance(value, str):
        raise ValueError("Chuá»—i proxy nháº­p nhanh khÃ´ng há»£p lá»‡")
    parts = value.strip().split(":", 3)
    if len(parts) != 4:
        raise ValueError("Nháº­p proxy theo dáº¡ng host:port:user:password")
    host, port_text, user, password = (part.strip() for part in parts)
    if not host:
        raise ValueError("Thiáº¿u Ä‘á»‹a chá»‰ SOCKS5")
    try:
        port = int(port_text)
    except ValueError as exc:
        raise ValueError("Port SOCKS5 khÃ´ng há»£p lá»‡") from exc
    if not 1 <= port <= 65535:
        raise ValueError("Port SOCKS5 khÃ´ng há»£p lá»‡")
    return host, port, user, password


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
    proxy_type: str = "socks5"

    @classmethod
    def from_row(cls, row: str) -> "WifiRecord":
        columns = row.rstrip("\r\n").split("|")
        if len(columns) not in (10, 11, 12):
            raise ValueError(f"DÃ²ng cáº¥u hÃ¬nh cáº§n 10, 11 hoáº·c 12 cá»™t: {row}")
        if len(columns) == 10:
            columns.append("")
        if len(columns) == 11:
            columns.append("socks5")
        if columns[8].strip() not in ("0", "1") or columns[9].strip() not in ("0", "1"):
            raise ValueError("isolate vÃ  webrtc pháº£i lÃ  0 hoáº·c 1")
        record = cls(
            name=columns[0], band=columns[1].strip(), idx=int(columns[2].strip()),
            wifi_password=columns[3], host=columns[4].strip(),
            port=int(columns[5].strip()), user=columns[6], socks_password=columns[7],
            isolate=columns[8].strip() == "1", webrtc=columns[9].strip() == "1",
            mac_oui=columns[10].strip(),
            proxy_type=columns[11].strip().lower() or "socks5",
        )
        record.validate()
        return record

    def validate(self) -> None:
        values = [self.name, self.wifi_password, self.host, self.user, self.socks_password]
        if any(not isinstance(value, str) for value in values):
            raise ValueError("CÃ¡c trÆ°á»ng vÄƒn báº£n pháº£i lÃ  chuá»—i")
        if any("|" in value or any(unicodedata.category(char) == "Cc" for char in value) for value in values):
            raise ValueError("CÃ¡c trÆ°á»ng khÃ´ng Ä‘Æ°á»£c chá»©a | hoáº·c kÃ½ tá»± Ä‘iá»u khiá»ƒn")
        try:
            name_size = len(self.name.encode("utf-8"))
            wifi_password_size = len(self.wifi_password.encode("utf-8"))
            user_size = len(self.user.encode("utf-8"))
            socks_password_size = len(self.socks_password.encode("utf-8"))
        except UnicodeEncodeError as exc:
            raise ValueError("CÃ¡c trÆ°á»ng vÄƒn báº£n chá»©a Unicode khÃ´ng há»£p lá»‡") from exc
        if not 1 <= name_size <= 32:
            raise ValueError("SSID pháº£i dÃ i 1â€“32 byte UTF-8")
        if self.band not in ("2g", "5g"):
            raise ValueError("BÄƒng táº§n pháº£i lÃ  2g hoáº·c 5g")
        if isinstance(self.idx, bool) or not isinstance(self.idx, int) or not 1 <= self.idx <= 200:
            raise ValueError("IDX pháº£i tá»« 1 Ä‘áº¿n 200")
        if not 8 <= wifi_password_size <= 63:
            raise ValueError("Máº­t kháº©u Wiâ€‘Fi pháº£i dÃ i 8â€“63 byte UTF-8")
        if not self.host.strip():
            raise ValueError("Thiáº¿u Ä‘á»‹a chá»‰ SOCKS5")
        if len(self.host) > 253 or not re.fullmatch(r"[A-Za-z0-9._:-]+", self.host):
            raise ValueError("Äá»‹a chá»‰ SOCKS5 khÃ´ng há»£p lá»‡")
        if user_size > 255 or socks_password_size > 255:
            raise ValueError("ThÃ´ng tin xÃ¡c thá»±c SOCKS5 quÃ¡ dÃ i")
        if isinstance(self.port, bool) or not isinstance(self.port, int) or not 1 <= self.port <= 65535:
            raise ValueError("Port SOCKS5 khÃ´ng há»£p lá»‡")
        if self.proxy_type not in ("socks5", "http"):
            raise ValueError("Loáº¡i proxy pháº£i lÃ  SOCKS5 hoáº·c HTTP")
        if not isinstance(self.isolate, bool) or not isinstance(self.webrtc, bool):
            raise ValueError("isolate vÃ  webrtc pháº£i lÃ  boolean")
        if not isinstance(self.mac_oui, str):
            raise ValueError("MAC OUI pháº£i cÃ³ dáº¡ng AA:BB:CC")
        if self.mac_oui and not re.fullmatch(r"[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){2}", self.mac_oui):
            raise ValueError("MAC OUI pháº£i cÃ³ dáº¡ng AA:BB:CC")

    def to_row(self) -> str:
        self.validate()
        return "|".join([
            self.name, self.band, str(self.idx), self.wifi_password, self.host,
            str(self.port), self.user, self.socks_password,
            "1" if self.isolate else "0", "1" if self.webrtc else "0",
            self.mac_oui.upper(),
            self.proxy_type,
        ])


def parse_conf(content: str) -> list[WifiRecord]:
    records = []
    indexes = set()
    for line in content.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        record = WifiRecord.from_row(line)
        if record.idx in indexes:
            raise ValueError("IDX Wiâ€‘Fi bá»‹ trÃ¹ng")
        indexes.add(record.idx)
        records.append(record)
    return sorted(records, key=lambda item: item.idx)


def render_conf(records: list[WifiRecord]) -> str:
    indexes = [record.idx for record in records]
    if len(indexes) != len(set(indexes)):
        raise ValueError("IDX Wiâ€‘Fi bá»‹ trÃ¹ng")
    rows = [record.to_row() for record in sorted(records, key=lambda item: item.idx)]
    header = (
        "# wifi-socks.conf â€” generated by sbproxy Console Native\n"
        "# name|band|idx|wifi_key|proxy_host|proxy_port|proxy_user|proxy_pass|isolate|webrtc|mac_oui|proxy_type\n"
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
        if state in ("Äang cáº¥m", "Blocked") and not banned:
            continue
        if state in ("KhÃ´ng cáº¥m", "Not blocked") and banned:
            continue
        raw_signal = item.get("signal_dbm")
        try:
            signal_dbm = _finite_float(raw_signal, math.nan) if raw_signal is not None else None
            if signal_dbm is not None and not math.isfinite(signal_dbm):
                signal_dbm = None
        except (TypeError, ValueError):
            signal_dbm = None
        if signal in ("Ráº¥t tá»‘t (â‰¥ -60 dBm)", "Excellent (â‰¥ -60 dBm)") and (signal_dbm is None or signal_dbm < -60):
            continue
        if signal in ("Tá»‘t (-70 Ä‘áº¿n -61 dBm)", "Good (-70 to -61 dBm)") and (
            signal_dbm is None or signal_dbm < -70 or signal_dbm >= -60
        ):
            continue
        if signal in ("Yáº¿u (-80 Ä‘áº¿n -71 dBm)", "Weak (-80 to -71 dBm)") and (
            signal_dbm is None or signal_dbm < -80 or signal_dbm >= -70
        ):
            continue
        if signal in ("Ráº¥t yáº¿u (< -80 dBm)", "Very weak (< -80 dBm)") and (signal_dbm is None or signal_dbm >= -80):
            continue
        if signal in ("KhÃ´ng rÃµ", "Unknown") and signal_dbm is not None:
            continue
        total_bytes = _nonnegative_int(item.get("rx_bytes")) + _nonnegative_int(item.get("tx_bytes"))
        if traffic in ("CÃ³ lÆ°u lÆ°á»£ng", "Has traffic") and total_bytes <= 0:
            continue
        if traffic in ("KhÃ´ng lÆ°u lÆ°á»£ng", "No traffic") and total_bytes > 0:
            continue
        if traffic in ("Tá»« 10 MB", "At least 10 MB") and total_bytes < 10 * 1024 * 1024:
            continue
        if traffic in ("Tá»« 100 MB", "At least 100 MB") and total_bytes < 100 * 1024 * 1024:
            continue
        connected = _nonnegative_int(item.get("connected_s"))
        if duration in ("DÆ°á»›i 5 phÃºt", "Under 5 minutes") and not (online and connected < 300):
            continue
        if duration in ("5â€“60 phÃºt", "5â€“60 minutes") and not (online and 300 <= connected <= 3600):
            continue
        if duration in ("TrÃªn 1 giá»", "Over 1 hour") and not (online and connected > 3600):
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


def center_dialog(window: tk.Toplevel) -> None:
    """Place a dialog in the center of its current screen."""
    window.update_idletasks()
    width = max(window.winfo_width(), window.winfo_reqwidth())
    height = max(window.winfo_height(), window.winfo_reqheight())
    screen_width = window.winfo_screenwidth()
    screen_height = window.winfo_screenheight()
    x = max(0, (screen_width - width) // 2)
    y = max(0, (screen_height - height) // 2)
    window.geometry(f"+{x}+{y}")


class WifiDialog(tk.Toplevel):
    def __init__(self, parent, record: WifiRecord | None, next_idx: int, language="en", palette=None):
        super().__init__(parent)
        self.language = language
        self.t = lambda text, **values: translate(text, self.language, **values)
        self.palette = palette or DARK_PALETTE
        self.title(self.t("Sá»­a Wiâ€‘Fi" if record else "ThÃªm Wiâ€‘Fi"))
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
            "proxy_type": tk.StringVar(value=record.proxy_type.upper()),
        }
        self.compact_socks = tk.StringVar()
        fields = [
            ("SSID", "name", None), ("BÄƒng táº§n", "band", "combo"), ("IDX", "idx", None),
            ("Loáº¡i proxy", "proxy_type", "proxy_type"),
            ("Máº­t kháº©u Wiâ€‘Fi", "wifi_password", "secret"), ("SOCKS host", "host", None),
            ("SOCKS port", "port", None), ("SOCKS user", "user", None),
            ("SOCKS password", "socks_password", "secret"), ("HÃ£ng router / MAC", "vendor", "vendor"),
        ]
        body = ttk.Frame(self, padding=14)
        body.grid(sticky="nsew")
        ttk.Label(body, text="Nháº­p nhanh proxy").grid(row=0, column=0, sticky="w", padx=(0, 12), pady=(0, 8))
        compact = ttk.Frame(body)
        compact.grid(row=0, column=1, sticky="ew", pady=(0, 8))
        compact_entry = ttk.Entry(compact, textvariable=self.compact_socks, width=27)
        compact_entry.pack(side="left", fill="x", expand=True)
        ttk.Button(compact, text="TÃ¡ch & Ä‘iá»n", command=self._fill_compact_socks).pack(side="left", padx=(8, 0))
        compact_entry.bind("<Return>", lambda _event: self._fill_compact_socks())
        first = None
        for row, (label, key, kind) in enumerate(fields):
            row += 1
            ttk.Label(body, text=label).grid(row=row, column=0, sticky="w", padx=(0, 12), pady=4)
            if kind == "combo":
                widget = ttk.Combobox(body, textvariable=self.values[key], values=("2g", "5g"), state="readonly", width=33)
            elif kind == "proxy_type":
                widget = ttk.Combobox(body, textvariable=self.values[key], values=("SOCKS5", "HTTP"), state="readonly", width=33)
            elif kind == "vendor":
                widget = ttk.Combobox(body, textvariable=self.values[key], values=vendor_choices(record.mac_oui), state="readonly", width=33)
            else:
                widget = ttk.Entry(body, textvariable=self.values[key], width=36, show="â€¢" if kind == "secret" else "")
            widget.grid(row=row, column=1, sticky="ew", pady=4)
            first = first or widget
        checks = ttk.Frame(body)
        checks.grid(row=len(fields) + 1, column=0, columnspan=2, sticky="w", pady=(8, 4))
        ttk.Checkbutton(checks, text="CÃ¡ch ly client", variable=self.values["isolate"]).pack(side="left", padx=(0, 18))
        ttk.Checkbutton(checks, text="Cháº·n WebRTC", variable=self.values["webrtc"]).pack(side="left")
        actions = ttk.Frame(body)
        actions.grid(row=len(fields) + 2, column=0, columnspan=2, sticky="e", pady=(14, 0))
        ttk.Button(actions, text="Huá»·", command=self.destroy).pack(side="right")
        ttk.Button(actions, text="LÆ°u", command=self._save).pack(side="right", padx=(0, 8))
        self.bind("<Return>", lambda _event: self._save())
        self.bind("<Escape>", lambda _event: self.destroy())
        if first:
            first.focus_set()
        localize_widget_tree(self, self.language)
        center_dialog(self)

    def _fill_compact_socks(self):
        try:
            host, port, user, password = parse_proxy_compact(self.compact_socks.get())
        except ValueError as exc:
            messagebox.showerror(self.t("Dá»¯ liá»‡u khÃ´ng há»£p lá»‡"), self.t(str(exc)), parent=self)
            return
        self.values["host"].set(host)
        self.values["port"].set(str(port))
        self.values["user"].set(user)
        self.values["socks_password"].set(password)

    def _save(self):
        try:
            result = WifiRecord(
                name=self.values["name"].get().strip(), band=self.values["band"].get(),
                idx=int(self.values["idx"].get()), wifi_password=self.values["wifi_password"].get(),
                host=self.values["host"].get().strip(), port=int(self.values["port"].get()),
                user=self.values["user"].get(), socks_password=self.values["socks_password"].get(),
                isolate=self.values["isolate"].get(), webrtc=self.values["webrtc"].get(),
                mac_oui=vendor_oui(self.values["vendor"].get()),
                proxy_type=self.values["proxy_type"].get().lower(),
            )
            result.validate()
        except (ValueError, TypeError) as exc:
            messagebox.showerror(self.t("Dá»¯ liá»‡u khÃ´ng há»£p lá»‡"), self.t(str(exc)), parent=self)
            return
        self.result = result
        self.destroy()


class RandomMacDialog(tk.Toplevel):
    def __init__(self, parent, record: WifiRecord, current_mac: str, language="en", palette=None):
        super().__init__(parent)
        self.language = language
        self.t = lambda text, **values: translate(text, self.language, **values)
        self.palette = palette or DARK_PALETTE
        self.title(f"Random MAC Â· {record.name}")
        self.resizable(False, False)
        self.transient(parent)
        self.grab_set()
        self.configure(bg=self.palette["bg"])
        self.result = None
        self.vendor_var = tk.StringVar(value=vendor_label(record.mac_oui))
        self.preview_var = tk.StringVar()

        body = ttk.Frame(self, style="Card.TFrame", padding=18)
        body.grid(sticky="nsew")
        ttk.Label(body, text="Chá»n hÃ£ng router", font=("Segoe UI Semibold", 13)).grid(row=0, column=0, columnspan=2, sticky="w")
        current_label = (
            f"SSID: {record.name}  Â·  Current MAC: {current_mac}"
            if self.language == "en" else
            f"SSID: {record.name}  Â·  MAC hiá»‡n táº¡i: {current_mac}"
        )
        ttk.Label(body, text=current_label, style="Muted.TLabel").grid(row=1, column=0, columnspan=2, sticky="w", pady=(4, 14))
        ttk.Label(body, text="Provider / OUI").grid(row=2, column=0, sticky="w", padx=(0, 12))
        provider = ttk.Combobox(body, textvariable=self.vendor_var, values=vendor_choices(record.mac_oui), state="readonly", width=38)
        provider.grid(row=2, column=1, sticky="ew")
        ttk.Label(body, textvariable=self.preview_var, style="Muted.TLabel").grid(row=3, column=0, columnspan=2, sticky="w", pady=(10, 4))
        ttk.Label(
            body,
            text="Random sáº½ cáº­p nháº­t provider trong config, táº¡o BSSID má»›i vÃ  reload radio.",
            style="Muted.TLabel",
        ).grid(row=4, column=0, columnspan=2, sticky="w", pady=(0, 14))

        actions = ttk.Frame(body, style="Card.TFrame")
        actions.grid(row=5, column=0, columnspan=2, sticky="e")
        ttk.Button(actions, text="Huá»·", command=self.destroy).pack(side="right")
        ttk.Button(actions, text="Random MAC", command=self._submit, style="Warning.TButton").pack(side="right", padx=(0, 8))
        self.vendor_var.trace_add("write", lambda *_args: self._update_preview())
        self._update_preview()
        self.bind("<Return>", lambda _event: self._submit())
        self.bind("<Escape>", lambda _event: self.destroy())
        provider.focus_set()
        localize_widget_tree(self, self.language)
        center_dialog(self)

    def _update_preview(self):
        try:
            oui = vendor_oui(self.vendor_var.get())
        except ValueError:
            self.preview_var.set(self.t("OUI khÃ´ng há»£p lá»‡"))
            return
        pattern = f"{oui}:xx:xx:xx" if oui else "02:xx:xx:xx:xx:xx"
        prefix = "New MAC pattern: " if self.language == "en" else "Máº«u MAC má»›i: "
        self.preview_var.set(f"{prefix}{pattern}")

    def _submit(self):
        try:
            self.result = vendor_oui(self.vendor_var.get())
        except ValueError as exc:
            messagebox.showerror(self.t("Provider khÃ´ng há»£p lá»‡"), self.t(str(exc)), parent=self)
            return
        self.destroy()


class ManualBanDialog(tk.Toplevel):
    def __init__(self, parent, records, language="en", palette=None):
        super().__init__(parent)
        self.language = language
        self.t = lambda text, **values: translate(text, self.language, **values)
        self.palette = palette or DARK_PALETTE
        self.title(self.t("ThÃªm MAC vÃ o blocklist"))
        self.configure(bg=self.palette["bg"])
        self.resizable(False, False)
        self.transient(parent)
        self.grab_set()
        self.result = None
        self.choices = {f"{record.name} Â· idx {record.idx}": record.idx for record in records}
        first = next(iter(self.choices), "")
        self.ssid_var = tk.StringVar(value=first)
        self.mac_var = tk.StringVar()

        body = ttk.Frame(self, style="Card.TFrame", padding=18)
        body.grid(sticky="nsew")
        ttk.Label(body, text="Cháº·n thiáº¿t bá»‹ theo MAC", font=("Segoe UI Semibold", 13)).grid(row=0, column=0, columnspan=2, sticky="w", pady=(0, 12))
        ttk.Label(body, text="SSID").grid(row=1, column=0, sticky="w", padx=(0, 12), pady=5)
        ttk.Combobox(body, textvariable=self.ssid_var, values=tuple(self.choices), state="readonly", width=34).grid(row=1, column=1, pady=5)
        ttk.Label(body, text="MAC").grid(row=2, column=0, sticky="w", padx=(0, 12), pady=5)
        mac_entry = ttk.Entry(body, textvariable=self.mac_var, width=37)
        mac_entry.grid(row=2, column=1, pady=5)
        ttk.Label(body, text="VÃ­ dá»¥: AA:BB:CC:DD:EE:FF", style="Muted.TLabel").grid(row=3, column=0, columnspan=2, sticky="w", pady=(2, 12))
        actions = ttk.Frame(body, style="Card.TFrame")
        actions.grid(row=4, column=0, columnspan=2, sticky="e")
        ttk.Button(actions, text="Huá»·", command=self.destroy).pack(side="right")
        ttk.Button(actions, text="ThÃªm vÃ o blocklist", command=self._submit, style="Danger.TButton").pack(side="right", padx=(0, 8))
        self.bind("<Return>", lambda _event: self._submit())
        self.bind("<Escape>", lambda _event: self.destroy())
        mac_entry.focus_set()
        localize_widget_tree(self, self.language)
        center_dialog(self)

    def _submit(self):
        mac = self.mac_var.get().strip().lower()
        if not re.fullmatch(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", mac):
            messagebox.showerror(self.t("MAC khÃ´ng há»£p lá»‡"), self.t("MAC pháº£i cÃ³ dáº¡ng AA:BB:CC:DD:EE:FF"), parent=self)
            return
        idx = self.choices.get(self.ssid_var.get())
        if idx is None:
            messagebox.showerror(self.t("Thiáº¿u SSID"), self.t("HÃ£y chá»n SSID cáº§n cháº·n"), parent=self)
            return
        self.result = idx, mac
        self.destroy()


class PoolDialog(tk.Toplevel):
    """Show one Wi-Fi's proxy pool, and take a replacement list for it."""

    def __init__(self, parent, record, proxies, usage, language="en", palette=None):
        super().__init__(parent)
        self.language = language
        self.t = lambda text, **values: translate(text, self.language, **values)
        self.palette = palette or DARK_PALETTE
        self.title(f"{self.t('Pool proxy')} Â· {record.name}")
        self.transient(parent)
        self.grab_set()
        self.configure(bg=self.palette["bg"])
        self.result = None

        body = ttk.Frame(self, style="Card.TFrame", padding=18)
        body.pack(fill="both", expand=True)
        ttk.Label(body, text=f"SSID: {record.name}  Â·  IDX {record.idx}",
                  style="Muted.TLabel").pack(anchor="w", pady=(0, 8))

        columns = ("slot", "proxy", "type", "devices")
        titles = (self.t("Slot"), self.t("Proxy"), "Type", self.t("MÃ¡y"))
        table = ttk.Treeview(body, columns=columns, show="headings", height=8)
        for column, title, width in zip(columns, titles, (50, 260, 70, 70)):
            table.heading(column, text=title)
            table.column(column, width=width, anchor="w")
        for position, row in enumerate(proxies):
            count = usage[position] if position < len(usage) else 0
            table.insert("", "end", values=(position, proxy_display(row),
                                            row.get("type", ""), count))
        table.pack(fill="both", expand=True, pady=(0, 10))

        ttk.Label(body, text="DÃ¡n danh sÃ¡ch proxy (má»—i dÃ²ng má»™t proxy)",
                  style="Muted.TLabel").pack(anchor="w")
        self.text = tk.Text(body, height=8, width=64, background=self.palette["card"],
                            foreground=self.palette["text"], insertbackground=self.palette["text"],
                            relief="flat", borderwidth=1)
        self.text.pack(fill="both", expand=True, pady=(4, 4))
        ttk.Label(
            body,
            text=("Replacing keeps every device on the proxy it is using, as long as that "
                  "proxy is still in the list. Wi-Fi is not interrupted."
                  if language == "en" else
                  "Thay pool váº«n giá»¯ má»—i mÃ¡y á»Ÿ Ä‘Ãºng proxy nÃ³ Ä‘ang dÃ¹ng, miá»…n lÃ  proxy Ä‘Ã³ cÃ²n "
                  "trong danh sÃ¡ch. Wiâ€‘Fi khÃ´ng bá»‹ ngáº¯t."),
            style="Muted.TLabel", wraplength=460, justify="left",
        ).pack(anchor="w", pady=(0, 12))

        actions = ttk.Frame(body, style="Card.TFrame")
        actions.pack(fill="x")
        ttk.Button(actions, text="Huá»·", command=self.destroy).pack(side="right")
        ttk.Button(actions, text="Ghi pool", command=self._submit,
                   style="Warning.TButton").pack(side="right", padx=(0, 8))
        self.bind("<Escape>", lambda _event: self.destroy())
        self.text.focus_set()
        localize_widget_tree(self, self.language)
        center_dialog(self)

    def _submit(self):
        self.result = self.text.get("1.0", "end")
        self.destroy()


class BulkProxyDialog(tk.Toplevel):
    """The split the operator is about to commit, device by device."""

    def __init__(self, parent, rows, language="en", palette=None):
        super().__init__(parent)
        self.language = language
        self.t = lambda text, **values: translate(text, self.language, **values)
        self.palette = palette or DARK_PALETTE
        self.title(self.t("Xem trÆ°á»›c cÃ¡ch chia proxy"))
        self.transient(parent)
        self.grab_set()
        self.configure(bg=self.palette["bg"])
        self.result = False

        body = ttk.Frame(self, style="Card.TFrame", padding=18)
        body.pack(fill="both", expand=True)
        summary = (f"{len(rows)} devices over {len({slot for _mac, slot, _label in rows})} proxies"
                   if language == "en" else
                   f"{len(rows)} thiáº¿t bá»‹ chia cho {len({slot for _mac, slot, _label in rows})} proxy")
        ttk.Label(body, text=summary, style="Muted.TLabel").pack(anchor="w", pady=(0, 8))

        columns = ("mac", "slot", "proxy")
        table = ttk.Treeview(body, columns=columns, show="headings", height=12)
        for column, title, width in zip(columns, ("MAC", self.t("Slot"), self.t("Proxy")),
                                        (150, 50, 260)):
            table.heading(column, text=title)
            table.column(column, width=width, anchor="w")
        for mac, slot, label in rows:
            table.insert("", "end", values=(mac, slot, label))
        table.pack(fill="both", expand=True, pady=(0, 12))

        actions = ttk.Frame(body, style="Card.TFrame")
        actions.pack(fill="x")
        ttk.Button(actions, text="Huá»·", command=self.destroy).pack(side="right")
        ttk.Button(actions, text="Ãp dá»¥ng", command=self._submit,
                   style="Warning.TButton").pack(side="right", padx=(0, 8))
        self.bind("<Escape>", lambda _event: self.destroy())
        localize_widget_tree(self, self.language)
        center_dialog(self)

    def _submit(self):
        self.result = True
        self.destroy()


class SlotChoiceDialog(tk.Toplevel):
    """Pick the pool slot one device should be pinned to, or unpin it."""

    def __init__(self, parent, proxies, current, language="en", palette=None):
        super().__init__(parent)
        self.language = language
        self.t = lambda text, **values: translate(text, self.language, **values)
        self.palette = palette or DARK_PALETTE
        self.title(self.t("GÃ¡n proxyâ€¦"))
        self.resizable(False, False)
        self.transient(parent)
        self.grab_set()
        self.configure(bg=self.palette["bg"])
        self.result = None
        self._choices = {self.t("KhÃ´ng ghim proxy"): "none"}
        for position, row in enumerate(proxies):
            self._choices[f"{position} Â· {proxy_display(row)}"] = position
        preselect = next((text for text, value in self._choices.items() if value == current),
                         next(iter(self._choices)))
        self.choice_var = tk.StringVar(value=preselect)

        body = ttk.Frame(self, style="Card.TFrame", padding=18)
        body.pack(fill="both", expand=True)
        ttk.Label(body, text="Proxy").pack(anchor="w", pady=(0, 6))
        ttk.Combobox(body, textvariable=self.choice_var, values=list(self._choices),
                     state="readonly", width=46).pack(fill="x", pady=(0, 14))
        actions = ttk.Frame(body, style="Card.TFrame")
        actions.pack(fill="x")
        ttk.Button(actions, text="Huá»·", command=self.destroy).pack(side="right")
        ttk.Button(actions, text="Ãp dá»¥ng", command=self._submit,
                   style="Warning.TButton").pack(side="right", padx=(0, 8))
        self.bind("<Return>", lambda _event: self._submit())
        self.bind("<Escape>", lambda _event: self.destroy())
        localize_widget_tree(self, self.language)
        center_dialog(self)

    def _submit(self):
        self.result = self._choices.get(self.choice_var.get())
        self.destroy()


class LoadingWindow(tk.Toplevel):
    """Modal progress window used while a background router mutation runs."""

    def __init__(self, parent, title: str, timeout_hint: int | None = None, language="en", palette=None):
        super().__init__(parent)
        self.language = language
        self.t = lambda text, **values: translate(text, self.language, **values)
        self.palette = palette or DARK_PALETTE
        self.title(self.t("sbproxy Â· Äang xá»­ lÃ½"))
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
        ttk.Label(body, text="Äang kiá»ƒm tra vÃ  Ã¡p dá»¥ng", font=("Segoe UI Semibold", 15)).pack(anchor="w")
        ttk.Label(body, textvariable=self.detail_var, style="Muted.TLabel", wraplength=440).pack(anchor="w", pady=(7, 14))
        self.progress = ttk.Progressbar(body, mode="indeterminate", length=440)
        self.progress.pack(fill="x")
        self.progress.start(10)
        ttk.Label(body, textvariable=self.elapsed_var, style="Muted.TLabel").pack(anchor="e", pady=(9, 0))

        localize_widget_tree(self, self.language)
        center_dialog(self)
        self.grab_set()
        self._tick()

    def _tick(self):
        if not self.winfo_exists():
            return
        elapsed = int(time.monotonic() - self.started)
        if self.timeout_hint:
            self.elapsed_var.set(
                f"Running {elapsed}s Â· maximum about {self.timeout_hint}s"
                if self.language == "en" else
                f"ÄÃ£ cháº¡y {elapsed}s Â· giá»›i háº¡n tá»‘i Ä‘a khoáº£ng {self.timeout_hint}s"
            )
        else:
            self.elapsed_var.set(f"Running {elapsed}s" if self.language == "en" else f"ÄÃ£ cháº¡y {elapsed}s")
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
    STEP_PENDING: "â—‹",
    STEP_RUNNING: "â–¶",
    STEP_OK: "âœ“",
    STEP_SKIPPED: "â€“",
    STEP_FAILED: "âœ—",
}

STEP_STATE_LABELS = {
    STEP_PENDING: "Chá»",
    STEP_RUNNING: "Äang cháº¡y",
    STEP_OK: "Xong",
    STEP_SKIPPED: "Bá» qua",
    STEP_FAILED: "Lá»—i",
}

def set_widget_tree_disabled(widget, disabled, remembered=None):
    """Grey out (or restore) every ttk control below `widget`.

    `remembered` collects what this call actually disabled, so lifting the lock
    never enables a control that was already disabled for its own reason (an
    empty selection, a task in flight).
    """
    for child in widget.winfo_children():
        try:
            if disabled:
                if not child.instate(["disabled"]):
                    child.state(["disabled"])
                    if remembered is not None:
                        remembered.append(child)
            elif remembered is None or child in remembered:
                child.state(["!disabled"])
        except (AttributeError, tk.TclError):
            pass
        set_widget_tree_disabled(child, disabled, remembered)
    return remembered


class AgentUpdateError(RuntimeError):
    """An agent upgrade step failed; the message is already operator-readable."""

    def __init__(self, message, output=""):
        super().__init__(message)
        self.output = output


def package_problem(path) -> str:
    """Why this file cannot be an update package, or "" when it looks fine.

    Checked before uploading so a broken bundle is named here instead of coming
    back as the router's puzzling "package is not a .tar.gz or .zip file".
    """
    if not path:
        return "KhÃ´ng tÃ¬m tháº¥y gÃ³i cáº­p nháº­t"
    file = Path(path)
    if not file.is_file():
        return f"KhÃ´ng tháº¥y file gÃ³i: {file}"
    try:
        size = file.stat().st_size
        with open(file, "rb") as handle:
            head = handle.read(4)
    except OSError as exc:
        return f"KhÃ´ng Ä‘á»c Ä‘Æ°á»£c gÃ³i: {exc}"
    if size == 0:
        return "GÃ³i cáº­p nháº­t rá»—ng"
    if head[:2] != b"\x1f\x8b" and head != b"PK\x03\x04":
        return f"GÃ³i khÃ´ng pháº£i .tar.gz hoáº·c .zip (báº¯t Ä‘áº§u báº±ng {head.hex() or '?'})"
    return ""


class AgentUpdater:
    """Push this console's package to the agent, one visible step at a time."""

    def __init__(self, client, package="", emit=None, on_output=None, builder=None):
        self.client = client
        self.package = package
        self.emit = emit or (lambda *_args: None)
        self.on_output = on_output or (lambda _text: None)
        self._build = builder or build_update_package
        self.from_version = ""
        self.to_version = ""
        self.package_path = None
        self.package_version = ""
        self.steps = [
            ("Chuáº©n bá»‹ gÃ³i cáº­p nháº­t", self.step_prepare),
            ("Kiá»ƒm tra phiÃªn báº£n agent", self.step_check_versions),
            ("Äáº©y gÃ³i lÃªn agent", self.step_upload),
            ("Kiá»ƒm tra agent sau nÃ¢ng cáº¥p", self.step_verify),
        ]

    # -- steps --------------------------------------------------------------

    def step_prepare(self) -> str:
        try:
            package = self._build(self.package)
        except Exception as exc:
            raise AgentUpdateError(f"KhÃ´ng dá»±ng Ä‘Æ°á»£c gÃ³i cáº­p nháº­t: {exc}") from exc
        problem = package_problem(package)
        if problem:
            raise AgentUpdateError(problem)
        self.package_path = Path(package)
        self.package_version = payload_version(self.package_path) or APP_VERSION
        size = self.package_path.stat().st_size
        return f"v{self.package_version} Â· {human_bytes(size)}"

    def step_check_versions(self) -> str:
        try:
            status = self.client.status()
        except AgentError as exc:
            raise AgentUpdateError(f"KhÃ´ng Ä‘á»c Ä‘Æ°á»£c tráº¡ng thÃ¡i agent: {exc}") from exc
        meta = status.get("meta") if isinstance(status, dict) else {}
        self.from_version = clean_agent_version(meta if isinstance(meta, dict) else {})
        order = compare_versions(self.package_version, self.from_version)
        if order == -1:
            raise AgentUpdateError(
                f"GÃ³i v{self.package_version} cÅ© hÆ¡n agent v{self.from_version} â€” "
                "hÃ£y dÃ¹ng console má»›i hÆ¡n thay vÃ¬ háº¡ cáº¥p"
            )
        if order == 0:
            return Skipped(f"Agent Ä‘Ã£ á»Ÿ v{self.from_version}; váº«n cÃ i láº¡i Ä‘á»ƒ sá»­a file há»ng")
        return f"v{self.from_version or '?'} â†’ v{self.package_version}"

    def step_upload(self) -> str:
        try:
            payload = self.package_path.read_bytes()
        except OSError as exc:
            raise AgentUpdateError(f"KhÃ´ng Ä‘á»c Ä‘Æ°á»£c gÃ³i cáº­p nháº­t: {exc}") from exc
        try:
            result = self.client.update(payload)
        except AgentError as exc:
            raise AgentUpdateError(f"Agent tá»« chá»‘i gÃ³i: {exc}") from exc
        result = result if isinstance(result, dict) else {}
        router_log = str(result.get("log") or "").strip()
        if router_log:
            self.on_output(router_log)
        if result.get("ok") is False:
            raise AgentUpdateError(
                f"Agent khÃ´ng cÃ i Ä‘Æ°á»£c gÃ³i: {failure_line(router_log) or 'khÃ´ng rÃµ lÃ½ do'}",
                router_log,
            )
        self.to_version = str(result.get("to") or "")
        return f"{human_bytes(len(payload))} Â· {result.get('from') or '?'} â†’ {self.to_version or '?'}"

    def step_verify(self) -> str:
        try:
            status = self.client.status()
        except AgentError as exc:
            raise AgentUpdateError(
                f"Agent khÃ´ng tráº£ lá»i sau khi nÃ¢ng cáº¥p: {exc}") from exc
        meta = status.get("meta") if isinstance(status, dict) else {}
        running = clean_agent_version(meta if isinstance(meta, dict) else {})
        if running and self.package_version and running != self.package_version:
            raise AgentUpdateError(
                f"Agent váº«n bÃ¡o version {running} thay vÃ¬ {self.package_version} â€” "
                "hÃ£y cÃ i láº¡i agent qua SSH (CÃ i Ä‘áº·t sau khi flash â†’ CÃ i láº¡i agent)"
            )
        return f"agent v{running or '?'}"

    def run(self) -> bool:
        """Run every step in order; the first failure stops the run."""
        for index, (label, function) in enumerate(self.steps):
            self.emit(index, STEP_RUNNING, "")
            try:
                detail = function()
            except AgentUpdateError as exc:
                self.emit(index, STEP_FAILED, str(exc))
                return False
            except Exception as exc:  # never leave the window without a verdict
                log.exception("agent update step failed: %s", label)
                self.emit(index, STEP_FAILED, str(exc))
                return False
            skipped = isinstance(detail, Skipped) or not detail
            self.emit(index, STEP_SKIPPED if skipped else STEP_OK, detail or "Bá» qua")
        return True


ROUTER_STATE_LABELS = {
    "ok": "Agent tráº£ lá»i OK vá»›i token hiá»‡n táº¡i",
    "unauthorized": "Agent Ä‘ang cháº¡y nhÆ°ng token sai hoáº·c thiáº¿u",
    "absent": "Router tráº£ lá»i nhÆ°ng chÆ°a cÃ i agent",
    "unreachable": "KhÃ´ng liÃªn láº¡c Ä‘Æ°á»£c vá»›i router",
}


class SetupWizard(tk.Toplevel):
    """Post-flash bring-up screen: run every step and show progress live."""

    def __init__(self, parent, settings: ProvisionSettings, language="en", palette=None,
                 on_success=None, on_decline=None, autostart=False):
        super().__init__(parent)
        self.language = language
        self.t = lambda text, **values: translate(text, self.language, **values)
        self.palette = palette or DARK_PALETTE
        self.on_success = on_success
        self.on_decline = on_decline
        self.runner: ProvisionRunner | None = None
        self.busy = False
        self.declined = False
        self.last_settings: ProvisionSettings | None = None
        self.title(self.t("CÃ i Ä‘áº·t router sau khi flash"))
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
        self.agent_only = bool(settings.agent_only)
        self.state_var = tk.StringVar(value=self.t("ChÆ°a cháº¡y bÆ°á»›c nÃ o"))

        body = ttk.Frame(self, style="Card.TFrame", padding=14)
        body.pack(fill="both", expand=True)
        ttk.Label(body, text="CÃ€I Äáº¶T SAU KHI FLASH Láº I ROUTER", style="MetricBlue.TLabel").pack(anchor="w")
        ttk.Label(
            body,
            text="Äáº©y mÃ£ nguá»“n, cÃ i phá»¥ thuá»™c, Ä‘áº©y cáº¥u hÃ¬nh, cháº¡y script khá»Ÿi táº¡o, cÃ i agent rá»“i láº¥y token.",
            style="Muted.TLabel", wraplength=820,
        ).pack(anchor="w", pady=(3, 10))

        form = ttk.Frame(body, style="Card.TFrame")
        form.pack(fill="x")
        self._field(form, 0, 0, "Router (IP)", self.host_var, width=18)
        self._field(form, 0, 2, "TÃ i khoáº£n SSH", self.user_var, width=14)
        self._field(form, 0, 4, "Port SSH", self.port_var, width=8)
        self._field(form, 1, 0, "Máº­t kháº©u SSH", self.password_var, width=18, show="â€¢")
        self._field(form, 1, 2, "SSH key (tuá»³ chá»n)", self.key_var, width=24, browse="file")
        self._field(form, 1, 4, "ThÆ° má»¥c trÃªn router", self.remote_var, width=18)
        self._field(form, 2, 0, "MÃ£ nguá»“n hoáº·c gÃ³i .tar.gz", self.payload_var, width=34, browse="any", span=3)
        self._field(form, 2, 4, "wifi-socks.conf", self.config_var, width=18, browse="file")
        self._field(form, 3, 0, "settings.sh (tuá»³ chá»n)", self.settings_var, width=34, browse="file", span=3)
        ttk.Checkbutton(form, text="Cháº¡y apply.sh sau khi Ä‘áº©y cáº¥u hÃ¬nh", variable=self.apply_var).grid(
            row=3, column=4, columnspan=2, sticky="w", padx=(8, 0), pady=4)
        # Default to reusing what the router already carries; both boxes are
        # opt-in because either one overwrites working router state.
        ttk.Checkbutton(form, text="Ghi Ä‘Ã¨ cáº¥u hÃ¬nh Ä‘Ã£ cÃ³ trÃªn router", variable=self.overwrite_var).grid(
            row=4, column=1, columnspan=3, sticky="w", pady=4)
        ttk.Checkbutton(form, text="CÃ i láº¡i agent dÃ¹ Ä‘Ã£ cÃ³", variable=self.reinstall_var).grid(
            row=4, column=4, columnspan=2, sticky="w", padx=(8, 0), pady=4)
        for column in (1, 3, 5):
            form.columnconfigure(column, weight=1)

        actions = ttk.Frame(body, style="Card.TFrame")
        actions.pack(fill="x", pady=(10, 8))
        self.run_button = ttk.Button(actions, text="Báº¯t Ä‘áº§u cÃ i Ä‘áº·t", command=self.start, style="Primary.TButton")
        self.run_button.pack(side="left")
        self.check_button = ttk.Button(actions, text="Kiá»ƒm tra tÃ¬nh tráº¡ng", command=self.check_state)
        self.check_button.pack(side="left", padx=(8, 0))
        self.stop_button = ttk.Button(actions, text="Dá»«ng", command=self.stop, style="Warning.TButton", state="disabled")
        self.stop_button.pack(side="left", padx=(8, 0))
        ttk.Button(actions, text="ÄÃ³ng", command=self.close).pack(side="right")
        ttk.Label(actions, textvariable=self.state_var, style="Muted.TLabel").pack(side="right", padx=(0, 14))

        self.progress = ttk.Progressbar(body, mode="determinate", maximum=1)
        self.progress.pack(fill="x", pady=(0, 8))

        self.steps_tree = ttk.Treeview(body, columns=("state", "step", "detail"), show="headings", height=9)
        for column, title, width in (("state", "Tráº¡ng thÃ¡i", 110), ("step", "BÆ°á»›c", 260), ("detail", "Chi tiáº¿t", 430)):
            self.steps_tree.heading(column, text=title)
            self.steps_tree.column(column, width=width, anchor="w")
        self.steps_tree.pack(fill="x")

        ttk.Label(body, text="Nháº­t kÃ½ thao tÃ¡c").pack(anchor="w", pady=(10, 3))
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
        center_dialog(self)
        if autostart:
            # Reached from the locked console, where installing was already
            # chosen: do not ask the same question twice.
            self.after(250, self.start)

    # -- form helpers -------------------------------------------------------

    def _field(self, parent, row, column, label, variable, width=16, show=None, browse=None, span=1):
        ttk.Label(parent, text=label).grid(row=row, column=column, sticky="w", pady=4)
        holder = ttk.Frame(parent, style="Card.TFrame")
        holder.grid(row=row, column=column + 1, columnspan=span, sticky="ew", padx=(8, 16), pady=4)
        entry = ttk.Entry(holder, textvariable=variable, width=width, show=show)
        entry.pack(side="left", fill="x", expand=True)
        if browse:
            ttk.Button(holder, text="â€¦", width=3,
                       command=lambda: self._browse(variable, browse)).pack(side="left", padx=(5, 0))

    def _browse(self, variable, kind):
        if kind == "any":
            path = filedialog.askopenfilename(
                parent=self, title=self.t("Chá»n gÃ³i cáº­p nháº­t"),
                filetypes=[("tar.gz", "*.tar.gz"), (self.t("Táº¥t cáº£ file"), "*.*")],
            ) or filedialog.askdirectory(parent=self, title=self.t("Chá»n thÆ° má»¥c mÃ£ nguá»“n"))
        else:
            path = filedialog.askopenfilename(parent=self, title=self.t("Chá»n file"))
        if path:
            variable.set(path)

    def collect(self) -> ProvisionSettings:
        try:
            port = int(self.port_var.get().strip() or "22")
        except ValueError:
            raise ValueError("Port SSH khÃ´ng há»£p lá»‡") from None
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
            agent_only=self.agent_only,
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
            f"{STEP_ICONS.get(state, 'â—‹')} {self.t(STEP_STATE_LABELS.get(state, state))}",
            self.t(self.step_labels[index]),
            self.t(detail) if detail else "",
        ))
        self.steps_tree.see(str(index))
        done = index + (0 if state == STEP_RUNNING else 1)
        self.progress.configure(value=done)
        self.state_var.set(f"{done}/{len(self.step_labels)} Â· {self.t(self.step_labels[index])}")
        if state == STEP_RUNNING:
            self.append(f"â†’ {self.t(self.step_labels[index])}")
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
        self.last_settings = settings
        self.reset_steps()
        self._set_busy(True)
        self.append(self.t("Báº¯t Ä‘áº§u cÃ i Ä‘áº·t") + f" Â· {settings.target}")

        def emit(index, state, detail):
            self.after(0, lambda: self.set_step(index, state, detail))

        def show_output(text):
            self.after(0, lambda: self.append(text))

        self.runner = ProvisionRunner(settings, emit=emit, on_output=show_output)

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
            self.append(f"âœ— {self.t(error)}")
            messagebox.showerror(APP_NAME, self.t(error), parent=self)
            return
        if not success:
            self.state_var.set(self.t("CÃ i Ä‘áº·t chÆ°a hoÃ n táº¥t"))
            self.append(self.t("CÃ i Ä‘áº·t chÆ°a hoÃ n táº¥t â€” hÃ£y xá»­ lÃ½ bÆ°á»›c lá»—i rá»“i cháº¡y láº¡i."))
            return
        self.state_var.set(self.t("CÃ i Ä‘áº·t hoÃ n táº¥t"))
        self.append(self.t("CÃ i Ä‘áº·t hoÃ n táº¥t â€” Ä‘Ã£ láº¥y token vÃ  má»Ÿ mÃ n hÃ¬nh Ä‘iá»u khiá»ƒn."))
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
            messagebox.showerror(APP_NAME, self.t("Thiáº¿u Ä‘á»‹a chá»‰ router"), parent=self)
            return
        base_url = f"http://{host}"
        _base, token = load_connection()
        try:
            settings = self.collect()
        except ValueError:
            settings = None  # SSH inventory needs valid settings; HTTP probe does not
        self._set_busy(True)
        self.state_var.set(self.t("Äang kiá»ƒm tra routerâ€¦"))

        self.last_settings = settings

        def worker():
            state = probe_router_state(base_url, token)
            inventory, details, reachable = "", None, False
            if settings:
                runner = ProvisionRunner(settings)
                try:
                    inventory = runner.step_inventory()
                    details = dict(runner.inventory)
                    reachable = True
                except ProvisionError as exc:
                    inventory = str(exc)
            self.after(0, lambda: self._show_state(state, inventory, details, reachable))

        threading.Thread(target=worker, daemon=True).start()

    def _show_state(self, state, inventory="", details=None, reachable=False):
        self._set_busy(False)
        message = self.t(ROUTER_STATE_LABELS.get(state, state))
        self.state_var.set(message)
        self.append(f"â€¢ {message}")
        if inventory:
            self.append(f"â€¢ {self.t(inventory)}")
        if reachable and details is not None:
            # SSH works, so the only open question left is whether to install.
            self._offer_install(details)
            return
        messagebox.showinfo(APP_NAME, f"{message}\n\n{self.t(inventory)}" if inventory else message, parent=self)

    def current_settings(self) -> ProvisionSettings | None:
        """Whatever the form holds right now, or the last run's settings."""
        try:
            return self.collect()
        except ValueError:
            return self.last_settings

    def _offer_install(self, inventory):
        """Ask, right after a working SSH login, whether to provision now."""
        if inventory.get("agent") and inventory.get("token"):
            messagebox.showinfo(
                APP_NAME, self.t("Router Ä‘Ã£ cÃ³ agent vÃ  token â€” khÃ´ng cáº§n cÃ i láº¡i."), parent=self,
            )
            return
        if messagebox.askyesno(
            APP_NAME,
            self.t("Káº¿t ná»‘i SSH thÃ nh cÃ´ng nhÆ°ng router chÆ°a cÃ i xong agent. CÃ i ngay bÃ¢y giá»?"),
            parent=self,
        ):
            self.start()
            return
        self.declined = True
        self.append(self.t("ÄÃ£ chá»n khÃ´ng cÃ i â€” console bá»‹ khoÃ¡ cho tá»›i khi agent Ä‘Æ°á»£c cÃ i."))
        if self.on_decline:
            self.on_decline(self.current_settings())
        self.close()

    def stop(self):
        if self.runner:
            self.runner.cancel()
            self.append(self.t("ÄÃ£ dá»«ng theo yÃªu cáº§u"))

    def close(self):
        if self.busy and not messagebox.askyesno(
            APP_NAME, self.t("Äang cÃ i Ä‘áº·t â€” váº«n Ä‘Ã³ng cá»­a sá»•?"), parent=self
        ):
            return
        if self.runner:
            self.runner.cancel()
        try:
            self.grab_release()
        except tk.TclError:
            pass
        self.destroy()


class AgentUpgradeChoiceDialog(tk.Toplevel):
    """Explicit three-way choice shown when the console finds an old agent."""

    def __init__(self, parent, message, language="en", palette=None):
        super().__init__(parent)
        self.language = language
        self.t = lambda text, **values: translate(text, self.language, **values)
        self.palette = palette or DARK_PALETTE
        self.choice = None
        self.title(self.t("NÃ¢ng cáº¥p agent"))
        self.configure(bg=self.palette["bg"])
        self.transient(parent)
        self.resizable(False, False)

        body = ttk.Frame(self, style="Card.TFrame", padding=18)
        body.pack(fill="both", expand=True)
        ttk.Label(body, text="Cáº¬P NHáº¬T AGENT", style="MetricBlue.TLabel").pack(anchor="w")
        ttk.Label(body, text=message, style="Muted.TLabel", wraplength=620).pack(
            anchor="w", fill="x", pady=(6, 12)
        )
        ttk.Label(
            body,
            text="Chá»n cÃ¡ch cáº­p nháº­t phÃ¹ há»£p. Cáº£ hai cÃ¡ch Ä‘á»u giá»¯ nguyÃªn wifi-socks.conf vÃ  settings.sh.",
            style="Muted.TLabel", wraplength=620,
        ).pack(anchor="w", fill="x", pady=(0, 14))

        api = ttk.Frame(body, style="Card.TFrame")
        api.pack(fill="x", pady=(0, 8))
        ttk.Button(
            api, text="NÃ¢ng cáº¥p tá»± Ä‘á»™ng", command=lambda: self.finish("api"),
            style="Success.TButton", width=24,
        ).pack(side="left")
        ttk.Label(
            api,
            text="DÃ¹ng API self-update cá»§a agent. Nhanh nháº¥t khi agent hiá»‡n táº¡i hoáº¡t Ä‘á»™ng bÃ¬nh thÆ°á»ng.",
            style="Muted.TLabel", wraplength=390,
        ).pack(side="left", padx=(12, 0))

        ssh = ttk.Frame(body, style="Card.TFrame")
        ssh.pack(fill="x", pady=(0, 14))
        ttk.Button(
            ssh, text="CÃ i Ä‘Ã¨ agent qua SSH", command=lambda: self.finish("ssh"), width=24,
        ).pack(side="left")
        ttk.Label(
            ssh,
            text="DÃ¹ng SSH Ä‘á»ƒ cÃ i Ä‘Ã¨ agent, dÃ nh cho agent cÅ© bá»‹ lá»—i nháº­n diá»‡n gÃ³i .tar.gz. KhÃ´ng cháº¡y apply cáº¥u hÃ¬nh.",
            style="Muted.TLabel", wraplength=390,
        ).pack(side="left", padx=(12, 0))

        ttk.Button(body, text="Äá»ƒ sau", command=lambda: self.finish(None)).pack(anchor="e")
        self.protocol("WM_DELETE_WINDOW", lambda: self.finish(None))
        localize_widget_tree(self, self.language)
        center_dialog(self)
        self.grab_set()

    def finish(self, choice):
        self.choice = choice
        try:
            self.grab_release()
        except tk.TclError:
            pass
        self.destroy()


def ask_agent_upgrade_choice(parent, message, language="en", palette=None):
    dialog = AgentUpgradeChoiceDialog(parent, message, language, palette)
    dialog.wait_window()
    return dialog.choice


class AgentUpdateWindow(tk.Toplevel):
    """Live checklist for an agent upgrade: every step, the router's own log."""

    def __init__(self, parent, updater: AgentUpdater, language="en", palette=None, on_success=None):
        super().__init__(parent)
        self.language = language
        self.t = lambda text, **values: translate(text, self.language, **values)
        self.palette = palette or DARK_PALETTE
        self.updater = updater
        self.on_success = on_success
        self.busy = True
        self.title(self.t("NÃ¢ng cáº¥p agent"))
        self.configure(bg=self.palette["bg"])
        self.transient(parent)
        self.minsize(720, 460)

        body = ttk.Frame(self, style="Card.TFrame", padding=14)
        body.pack(fill="both", expand=True)
        ttk.Label(body, text="NÃ‚NG Cáº¤P AGENT TRÃŠN ROUTER", style="MetricBlue.TLabel").pack(anchor="w")
        ttk.Label(
            body,
            text="Äáº©y gÃ³i cá»§a console lÃªn agent. Cáº¥u hÃ¬nh wifi-socks.conf vÃ  settings.sh Ä‘Æ°á»£c giá»¯ nguyÃªn.",
            style="Muted.TLabel", wraplength=660,
        ).pack(anchor="w", pady=(3, 10))

        self.state_var = tk.StringVar(value=self.t("Äang cháº¡yâ€¦"))
        self.progress = ttk.Progressbar(body, mode="determinate", maximum=len(updater.steps))
        self.progress.pack(fill="x", pady=(0, 8))
        self.steps_tree = ttk.Treeview(body, columns=("state", "step", "detail"), show="headings", height=5)
        for column, title, width in (("state", "Tráº¡ng thÃ¡i", 110), ("step", "BÆ°á»›c", 220), ("detail", "Chi tiáº¿t", 380)):
            self.steps_tree.heading(column, text=title)
            self.steps_tree.column(column, width=width, anchor="w")
        self.steps_tree.pack(fill="x")
        for index, (label, _function) in enumerate(updater.steps):
            self.steps_tree.insert("", "end", iid=str(index), values=(
                f"{STEP_ICONS[STEP_PENDING]} {self.t(STEP_STATE_LABELS[STEP_PENDING])}", self.t(label), ""))

        ttk.Label(body, text="Nháº­t kÃ½ thao tÃ¡c").pack(anchor="w", pady=(10, 3))
        self.log_text = tk.Text(
            body, height=9, wrap="word", state="disabled",
            bg=self.palette["input"], fg=self.palette["log_text"], borderwidth=0,
            highlightthickness=1, highlightbackground=self.palette["border"],
            padx=10, pady=8, font=("Cascadia Mono", 9),
        )
        self.log_text.pack(fill="both", expand=True)

        actions = ttk.Frame(body, style="Card.TFrame")
        actions.pack(fill="x", pady=(10, 0))
        ttk.Label(actions, textvariable=self.state_var, style="Muted.TLabel").pack(side="left")
        self.close_button = ttk.Button(actions, text="ÄÃ³ng", command=self.close, state="disabled")
        self.close_button.pack(side="right")
        self.protocol("WM_DELETE_WINDOW", self.close)
        localize_widget_tree(self, self.language)
        center_dialog(self)
        self.after(120, self.start)

    def append(self, text):
        entry = redact(str(text).rstrip())
        log.info("agent-update: %s", entry)
        if not self.winfo_exists():
            return
        self.log_text.configure(state="normal")
        self.log_text.insert("end", entry + "\n")
        self.log_text.see("end")
        self.log_text.configure(state="disabled")

    def set_step(self, index, state, detail):
        if not self.winfo_exists() or index >= len(self.updater.steps):
            return
        label = self.updater.steps[index][0]
        self.steps_tree.item(str(index), values=(
            f"{STEP_ICONS.get(state, 'â—‹')} {self.t(STEP_STATE_LABELS.get(state, state))}",
            self.t(label), self.t(detail) if detail else "",
        ))
        self.steps_tree.see(str(index))
        done = index + (0 if state == STEP_RUNNING else 1)
        self.progress.configure(value=done)
        self.state_var.set(f"{done}/{len(self.updater.steps)} Â· {self.t(label)}")
        if state == STEP_RUNNING:
            self.append(f"â†’ {self.t(label)}")
        elif detail:
            self.append(f"   {STEP_ICONS.get(state, '')} {self.t(detail)}")

    def start(self):
        self.updater.emit = lambda index, state, detail: self.after(
            0, lambda: self.set_step(index, state, detail))
        self.updater.on_output = lambda text: self.after(0, lambda: self.append(text))

        def worker():
            try:
                success = self.updater.run()
            except Exception as exc:  # a crash must not leave the window hanging
                log.exception("agent update crashed")
                self.after(0, lambda: self.finish(False, str(exc)))
                return
            self.after(0, lambda: self.finish(success, ""))

        threading.Thread(target=worker, daemon=True).start()

    def finish(self, success, error):
        self.busy = False
        if self.winfo_exists():
            self.close_button.configure(state="normal")
        if error:
            self.append(f"âœ— {self.t(error)}")
        if success:
            self.state_var.set(self.t("NÃ¢ng cáº¥p xong"))
            self.append(self.t("NÃ¢ng cáº¥p xong â€” agent Ä‘Ã£ cháº¡y báº£n má»›i."))
            if self.on_success:
                self.on_success(self.updater.to_version)
            self.close()
            return
        self.state_var.set(self.t("NÃ¢ng cáº¥p tháº¥t báº¡i"))
        self.append(self.t(
            "NÃ¢ng cáº¥p dá»«ng láº¡i á»Ÿ bÆ°á»›c lá»—i. Sá»­a nguyÃªn nhÃ¢n rá»“i thá»­ láº¡i, hoáº·c cÃ i láº¡i agent"
            " qua SSH báº±ng CÃ i Ä‘áº·t sau khi flash â†’ CÃ i láº¡i agent dÃ¹ Ä‘Ã£ cÃ³."
        ))

    def close(self):
        if self.busy:
            return  # a step is still running; the Close button stays disabled
        if self.winfo_exists():
            self.destroy()


class NativeApp:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title(f"{APP_NAME} Â· v{APP_VERSION}")
        self.root.geometry("1380x840")
        self.root.minsize(1100, 700)
        self.client: AgentClient | None = None
        self.records: list[WifiRecord] = []
        self.clients_data = []
        self.visible_clients = []
        self.pool_cache = {}
        self.client_rows = {}
        self.health = {}
        self.runtime_ssids = {}
        self.gateway_payload = {}
        # Uplink choice: display label -> logical interface name ("" = automatic).
        self.gateway_iface_choices = {}
        self.gateway_iface_states = {}
        self.gateway_syncing = False
        self.backup_names = []
        self.log_history = []
        self.loading_window: LoadingWindow | None = None
        self._style_images = {}
        self.language, self.theme = load_preferences()
        self.palette = PALETTES[self.theme]
        self.language_var = tk.StringVar(value="English" if self.language == "en" else "Tiáº¿ng Viá»‡t")
        self.theme_var = tk.StringVar(value="Dark" if self.theme == "dark" else "Light")
        self.t = lambda text, **values: translate(text, self.language, **values)
        base, token = load_connection()
        self.base_var = tk.StringVar(value=base)
        self.token_var = tk.StringVar(value=token)
        self.status_var = tk.StringVar(value=self.t("ChÆ°a káº¿t ná»‘i"))
        self.lock_hint_var = tk.StringVar(value="")
        self.gateway_iface_var = tk.StringVar(value="")
        self.setup_hint_var = tk.StringVar(value=self.t(
            "Router vá»«a flash láº¡i chÆ°a cÃ³ agent hoáº·c token. Cháº¡y cÃ i Ä‘áº·t Ä‘á»ƒ Ä‘áº©y mÃ£ nguá»“n, cáº¥u hÃ¬nh, script khá»Ÿi táº¡o vÃ  láº¥y token."
        ))
        self.agent_version = ""
        # Mirrors config/settings.sh on the router; never assumed, always read.
        self.net_base = DEFAULT_NET_BASE
        self.tproxy_port_base = DEFAULT_TPROXY_PORT_BASE
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
        self.client_count_var = tk.StringVar(value="0 devices" if self.language == "en" else "0 thiáº¿t bá»‹")
        self.client_online_count_var = tk.StringVar(value="0 online")
        self.client_weak_count_var = tk.StringVar(value="0 weak signal" if self.language == "en" else "0 tÃ­n hiá»‡u yáº¿u")
        self.client_blocked_count_var = tk.StringVar(value="0 blocked" if self.language == "en" else "0 Ä‘Ã£ cháº·n")
        self.client_traffic_total_var = tk.StringVar(value="0 B total traffic" if self.language == "en" else "0 B tá»•ng lÆ°u lÆ°á»£ng")
        self.gateway_state_var = tk.StringVar(value=self.t("â— Internet chÆ°a kiá»ƒm tra"))
        self.gateway_route_var = tk.StringVar(value=self.t("ÄÆ°á»ng ra: â€”"))
        self.gateway_link_var = tk.StringVar(value=self.t("Káº¿t ná»‘i/DNS: â€”"))
        self.gateway_http_var = tk.StringVar(value=self.t("Internet HTTP: â€”"))
        self.wifi_selection_var = tk.StringVar(value=self.t("Chá»n má»™t SSID trong báº£ng Ä‘á»ƒ chá»‰nh sá»­a"))
        self.client_selection_var = tk.StringVar(value=self.t("Chá»n thiáº¿t bá»‹ trong báº£ng Ä‘á»ƒ Ä‘iá»u khiá»ƒn"))
        self.backup_selection_var = tk.StringVar(value=self.t("Chá»n má»™t backup Ä‘á»ƒ khÃ´i phá»¥c"))
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
        self.setup_wizard: SetupWizard | None = None
        # Router reachable over SSH but knowingly left without an agent: the
        # console cannot drive anything, so it locks until one is installed.
        self.console_locked = False
        self.locked_widgets = []
        # In-memory only, never written to disk: lets "Install the agent now"
        # reuse the credentials just typed into the wizard.
        self.pending_provision: ProvisionSettings | None = None
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
            self.status_var.set(self.t("ChÆ°a cáº¥u hÃ¬nh router â€” hÃ£y cháº¡y cÃ i Ä‘áº·t sau khi flash"))
            # A known router may already be installed: say so before anyone
            # starts a setup run that would repeat work.
            self.root.after(700, lambda: self.check_router_state(announce=False))
            # Without a token the SSH form is the only useful next action, so
            # open it instead of leaving people to hunt for the button.
            self.root.after(900, self.open_setup_wizard)

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
        for name, color in (
            ("GatewayUp.TCombobox", p["good_text"]),
            ("GatewayDown.TCombobox", p["bad_text"]),
            ("GatewayUnknown.TCombobox", p["text"]),
        ):
            style.configure(name, foreground=color, fieldbackground=p["input"])
            style.map(name, foreground=[("readonly", color)], fieldbackground=[("readonly", p["input"])])
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
        ttk.Label(brand, text=f"OPENWRT Â· MULTI-SSID SOCKS5 CONTROL CENTER Â· v{APP_VERSION}",
                  style="Subtitle.TLabel").pack(anchor="w")
        ttk.Label(header, textvariable=self.status_var, style="Status.TLabel").pack(side="right", padx=(20, 0))
        preferences = ttk.Frame(header, style="Header.TFrame")
        preferences.pack(side="right", padx=(18, 0))
        ttk.Label(preferences, text="NgÃ´n ngá»¯", style="Header.TLabel").pack(side="left", padx=(0, 5))
        language = ttk.Combobox(preferences, textvariable=self.language_var, values=("English", "Tiáº¿ng Viá»‡t"), state="readonly", width=11)
        language.pack(side="left", padx=(0, 10))
        language.bind("<<ComboboxSelected>>", self._on_language_changed)
        ttk.Label(preferences, text="Giao diá»‡n", style="Header.TLabel").pack(side="left", padx=(0, 5))
        theme = ttk.Combobox(preferences, textvariable=self.theme_var, values=("Dark", "Light"), state="readonly", width=7)
        theme.pack(side="left")
        theme.bind("<<ComboboxSelected>>", self._on_theme_changed)
        ttk.Button(preferences, text=self.t("ThÆ° má»¥c log"), command=self.open_log_folder).pack(side="left", padx=(10, 0))

        top = ttk.Frame(self.root, style="Card.TFrame", padding=(14, 12))
        self.connection_row = top
        top.pack(fill="x", padx=14, pady=(12, 8))
        ttk.Label(top, text="Router").grid(row=0, column=0, sticky="w")
        ttk.Entry(top, textvariable=self.base_var, width=31).grid(row=0, column=1, padx=(8, 18), sticky="ew")
        ttk.Label(top, text="Agent token").grid(row=0, column=2, sticky="w")
        ttk.Entry(top, textvariable=self.token_var, show="â€¢", width=37).grid(row=0, column=3, padx=(8, 18), sticky="ew")
        ttk.Button(top, text="Káº¿t ná»‘i", command=self.connect, style="Primary.TButton").grid(row=0, column=4, padx=4)
        ttk.Button(top, text="LÃ m má»›i", command=self.refresh_all).grid(row=0, column=5, padx=4)
        # Always reachable: a router can be reflashed while a token is still stored.
        ttk.Button(top, text="CÃ i Ä‘áº·t sau khi flashâ€¦", command=self.open_setup_wizard).grid(row=0, column=6, padx=(4, 0))
        top.columnconfigure(1, weight=1)
        top.columnconfigure(3, weight=1)

        self.setup_bar = ttk.Frame(self.root, style="Metric.TFrame", padding=(14, 10))
        ttk.Label(self.setup_bar, text="CHÆ¯A Cáº¤U HÃŒNH ROUTER", style="MetricYellow.TLabel").pack(side="left", padx=(0, 14))
        ttk.Label(self.setup_bar, textvariable=self.setup_hint_var,
                  style="MetricYellow.TLabel", wraplength=760).pack(side="left")
        ttk.Button(self.setup_bar, text="Kiá»ƒm tra tÃ¬nh tráº¡ng", command=self.check_router_state).pack(side="right")
        self.upgrade_button = ttk.Button(self.setup_bar, text="NÃ¢ng cáº¥p agent",
                                         command=self.upgrade_agent, style="Success.TButton")
        self.ssh_upgrade_button = ttk.Button(
            self.setup_bar, text="CÃ i Ä‘Ã¨ agent qua SSH",
            command=self.reinstall_agent_over_ssh,
        )
        ttk.Button(self.setup_bar, text="CÃ i Ä‘áº·t sau khi flashâ€¦", command=self.open_setup_wizard,
                   style="Primary.TButton").pack(side="right", padx=(0, 8))

        self.lock_bar = ttk.Frame(self.root, style="Metric.TFrame", padding=(14, 10))
        ttk.Label(self.lock_bar, text="KHÃ”NG Cáº¤U HÃŒNH ÄÆ¯á»¢C ROUTER",
                  style="MetricRed.TLabel").pack(side="left", padx=(0, 14))
        ttk.Label(self.lock_bar, textvariable=self.lock_hint_var,
                  style="MetricRed.TLabel", wraplength=700).pack(side="left")
        self.lock_button = ttk.Button(self.lock_bar, text="CÃ i agent ngay",
                                      command=self.install_agent_now, style="Primary.TButton")
        self.lock_button.pack(side="right")

        gateway = ttk.Frame(self.root, style="Metric.TFrame", padding=(14, 10))
        self.gateway_bar = gateway
        gateway.pack(fill="x", padx=14, pady=(0, 8))
        gateway_head = ttk.Frame(gateway, style="Metric.TFrame")
        gateway_head.pack(fill="x")
        ttk.Label(gateway_head, text="Cá»”NG RA INTERNET", style="MetricBlue.TLabel").pack(side="left", padx=(0, 18))
        self.gateway_state_label = ttk.Label(gateway_head, textvariable=self.gateway_state_var, style="MetricBlue.TLabel")
        self.gateway_state_label.pack(side="left")
        ttk.Button(gateway_head, text="Kiá»ƒm tra cá»•ng ra", command=self.refresh_gateway, style="Primary.TButton").pack(side="right")
        self.gateway_iface_combo = ttk.Combobox(
            gateway_head, textvariable=self.gateway_iface_var, state="readonly", width=34,
            style="GatewayUnknown.TCombobox", postcommand=self._color_gateway_interface_menu,
        )
        self.gateway_iface_combo.pack(side="right", padx=(0, 8))
        self.gateway_iface_combo.bind("<<ComboboxSelected>>", self._on_gateway_interface_changed)
        ttk.Label(gateway_head, text="ÄÆ°á»ng ra", style="MetricBlue.TLabel").pack(side="right", padx=(0, 6))
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
        self._apply_lock_state()

    def _on_language_changed(self, _event=None):
        language = "vi" if self.language_var.get() == "Tiáº¿ng Viá»‡t" else "en"
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
            self.gateway_state_var.set(self.t("â— Internet chÆ°a kiá»ƒm tra"))
            self.gateway_route_var.set(self.t("ÄÆ°á»ng ra: â€”"))
            self.gateway_link_var.set(self.t("Káº¿t ná»‘i/DNS: â€”"))
            self.gateway_http_var.set(self.t("Internet HTTP: â€”"))
        for name in self.backup_names:
            self.backup_list.insert("end", name)
        for entry in self.log_history:
            self._write_log_widget(entry)
        if self.client:
            self.status_var.set(
                f"Connected to {self.client.base_url}" if self.language == "en"
                else f"ÄÃ£ káº¿t ná»‘i {self.client.base_url}"
            )
        else:
            self.status_var.set(self.t("ChÆ°a káº¿t ná»‘i"))
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
        self.tabs.add(tab, text="Wiâ€‘Fi / SOCKS5")
        bar = ttk.Frame(tab, style="Toolbar.TFrame", padding=9)
        bar.pack(fill="x", pady=(0, 10))
        for text, command, button_style in [
            ("ï¼‹ ThÃªm SSID", self.add_wifi, "Success.TButton"),
            ("Pool proxyâ€¦", self.open_pool_editor, "TButton"),
            ("Äáº©y cáº¥u hÃ¬nh & Apply", self.save_apply, "Success.TButton"),
        ]:
            ttk.Button(bar, text=text, command=command, style=button_style).pack(side="left", padx=(0, 7))
        columns = {"idx": "IDX", "name": "SSID", "band": "Band", "subnet": "Subnet", "mac": "BSSID / Provider", "socks": "Proxy", "isolate": "Isolate", "webrtc": "WebRTC", "health": "Health"}
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
            ("edit", "Sá»­a cáº¥u hÃ¬nh", self.edit_wifi),
            ("sock", "Äá»•i SOCKS", self.quick_sock),
            ("pool", "Pool proxyâ€¦", self.open_pool_editor),
            ("mac", "Random MAC", self.rotate_wifi_mac),
        ):
            self.wifi_context_menu.add_command(label=self.t(text), command=command)
            self.wifi_context_entries[key] = self.wifi_context_menu.index("end")
        self.wifi_context_menu.add_separator()
        self.wifi_context_menu.add_command(label=self.t("XoÃ¡ SSID"), command=self.delete_wifi)
        self.wifi_context_entries["delete"] = self.wifi_context_menu.index("end")

        editor = ttk.Frame(tab, style="Toolbar.TFrame", padding=9)
        editor.pack(fill="x", pady=(8, 0))
        ttk.Label(editor, text="CHá»ˆNH Sá»¬A SSID ÄANG CHá»ŒN", style="Count.TLabel").pack(side="left", padx=(0, 12))
        ttk.Label(editor, textvariable=self.wifi_selection_var, style="Toolbar.TLabel").pack(side="left", fill="x", expand=True)
        for key, text, command, button_style in (
            ("edit", "Sá»­a cáº¥u hÃ¬nh", self.edit_wifi, "TButton"),
            ("delete", "XoÃ¡ SSID", self.delete_wifi, "Danger.TButton"),
        ):
            button = ttk.Button(editor, text=text, command=command, style=button_style, state="disabled")
            button.pack(side="left", padx=(7, 0))
            self.wifi_edit_buttons[key] = button

    def _build_clients_tab(self):
        tab = ttk.Frame(self.tabs, style="Card.TFrame", padding=12)
        self.tabs.add(tab, text="Thiáº¿t bá»‹")
        bar = ttk.Frame(tab, style="Toolbar.TFrame", padding=9)
        bar.pack(fill="x", pady=(0, 8))
        ttk.Button(bar, text="LÃ m má»›i", command=self.refresh_clients, style="Primary.TButton").pack(side="left", padx=(0, 7))
        ttk.Button(bar, text="Cháº·n MACâ€¦", command=self.manual_ban_client, style="Danger.TButton").pack(side="left", padx=(0, 7))
        ttk.Button(bar, text="Xuáº¥t CSV", command=self.export_clients_csv).pack(side="left", padx=(0, 7))
        ttk.Combobox(bar, textvariable=self.client_interval_var, values=("5s", "10s", "15s", "30s", "60s"), state="readonly", width=5).pack(side="right", padx=(6, 0))
        ttk.Checkbutton(bar, text="Tá»± lÃ m má»›i", variable=self.client_auto_var, command=self.toggle_client_auto_refresh, style="Toolbar.TCheckbutton").pack(side="right")

        filters = ttk.Frame(tab, style="Toolbar.TFrame", padding=9)
        filters.pack(fill="x", pady=(0, 8))
        row1 = ttk.Frame(filters, style="Toolbar.TFrame")
        row1.pack(fill="x", pady=(0, 7))
        ttk.Label(row1, text="SSID", style="Toolbar.TLabel").pack(side="left", padx=(0, 5))
        self.client_ssid_combo = ttk.Combobox(row1, textvariable=self.client_ssid_var, values=(ALL_SSIDS,), state="readonly", width=16)
        self.client_ssid_combo.pack(side="left", padx=(0, 10))
        ttk.Label(row1, text="Band", style="Toolbar.TLabel").pack(side="left", padx=(0, 5))
        ttk.Combobox(row1, textvariable=self.client_band_var, values=BAND_FILTERS, state="readonly", width=13).pack(side="left", padx=(0, 10))
        ttk.Label(row1, text="Káº¿t ná»‘i", style="Toolbar.TLabel").pack(side="left", padx=(0, 5))
        ttk.Combobox(row1, textvariable=self.client_presence_var, values=PRESENCE_FILTERS, state="readonly", width=16).pack(side="left", padx=(0, 10))
        ttk.Label(row1, text="Quyá»n", style="Toolbar.TLabel").pack(side="left", padx=(0, 5))
        ttk.Combobox(row1, textvariable=self.client_state_var, values=CLIENT_STATES, state="readonly", width=20).pack(side="left", padx=(0, 10))
        ttk.Label(row1, text="TÃ¬m IP / tÃªn / MAC", style="Toolbar.TLabel").pack(side="left", padx=(0, 5))
        ttk.Entry(row1, textvariable=self.client_query_var, width=24).pack(side="left", fill="x", expand=True)

        row2 = ttk.Frame(filters, style="Toolbar.TFrame")
        row2.pack(fill="x")
        ttk.Label(row2, text="TÃ­n hiá»‡u", style="Toolbar.TLabel").pack(side="left", padx=(0, 5))
        ttk.Combobox(row2, textvariable=self.client_signal_var, values=SIGNAL_FILTERS, state="readonly", width=24).pack(side="left", padx=(0, 10))
        ttk.Label(row2, text="LÆ°u lÆ°á»£ng", style="Toolbar.TLabel").pack(side="left", padx=(0, 5))
        ttk.Combobox(row2, textvariable=self.client_traffic_var, values=TRAFFIC_FILTERS, state="readonly", width=18).pack(side="left", padx=(0, 10))
        ttk.Label(row2, text="Thá»i gian", style="Toolbar.TLabel").pack(side="left", padx=(0, 5))
        ttk.Combobox(row2, textvariable=self.client_duration_var, values=DURATION_FILTERS, state="readonly", width=18).pack(side="left", padx=(0, 10))
        ttk.Button(row2, text="Äáº·t láº¡i bá»™ lá»c", command=self.reset_client_filters).pack(side="left")
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

        columns = {"ssid": "SSID", "band": "Band", "ip": "IP", "host": "TÃªn mÃ¡y", "mac": "MAC", "proxy": "Proxy", "time": "Káº¿t ná»‘i", "rx": "RX", "tx": "TX", "signal": "Signal", "status": "Tráº¡ng thÃ¡i"}
        self.client_column_titles = columns.copy()
        self.client_tree = self._tree(tab, columns, {"ssid": 125, "band": 60, "ip": 115, "host": 145, "mac": 140, "proxy": 150, "time": 85, "rx": 85, "tx": 85, "signal": 70, "status": 120}, selectmode="extended")
        for column, title in columns.items():
            self.client_tree.heading(column, text=title, command=lambda selected=column: self.sort_clients(selected))
        self.client_tree.tag_configure("banned", foreground=self.palette["bad_text"])
        self.client_tree.tag_configure("offline", foreground=self.palette["muted"])
        self.client_tree.tag_configure("weak", foreground=self.palette["warn_text"])
        self.client_tree.tag_configure("strong", foreground=self.palette["good_text"])
        self.client_tree.bind("<Double-1>", self.show_client_details)
        self.client_tree.bind("<Button-3>", self.show_client_context_menu)
        self.client_tree.bind("<<TreeviewSelect>>", self.update_client_editor)
        self.client_tree.bind("<Control-c>", lambda _event: self.copy_selected_clients())
        self.client_tree.bind("<Control-a>", self.select_all_clients)

        editor = ttk.Frame(tab, style="Toolbar.TFrame", padding=9)
        editor.pack(fill="x", pady=(8, 0))
        ttk.Label(editor, text="ÄIá»€U KHIá»‚N THIáº¾T Bá»Š ÄANG CHá»ŒN", style="Count.TLabel").pack(side="left", padx=(0, 12))
        ttk.Label(editor, textvariable=self.client_selection_var, style="Toolbar.TLabel").pack(side="left", fill="x", expand=True)
        for key, text, command, button_style in (
            ("details", "Chi tiáº¿t", self.show_client_details, "TButton"),
            ("copy", "Copy IP/MAC", self.copy_selected_clients, "TButton"),
            ("kick", "Kick", lambda: self.client_action("kick"), "Warning.TButton"),
            ("ban", "Cáº¥m", lambda: self.client_action("ban"), "Danger.TButton"),
            ("unban", "Bá» cáº¥m", lambda: self.client_action("unban"), "Success.TButton"),
            ("proxy", "Äá»•i proxyâ€¦", self.bulk_assign_proxy, "Primary.TButton"),
        ):
            button = ttk.Button(editor, text=text, command=command, style=button_style, state="disabled")
            button.pack(side="left", padx=(7, 0))
            self.client_edit_buttons[key] = button

        self.client_context_menu = tk.Menu(
            self.root,
            tearoff=False,
            background=self.palette["card"],
            foreground=self.palette["text"],
            activebackground=self.palette["primary"],
            activeforeground=self.palette["selection_text"],
            relief="flat",
            borderwidth=1,
        )
        self.client_context_menu.add_command(label=self.t("GÃ¡n proxyâ€¦"), command=self.assign_one_proxy)
        self.client_context_menu.add_command(label=self.t("Äá»•i proxy cho thiáº¿t bá»‹ Ä‘Ã£ chá»nâ€¦"),
                                             command=self.bulk_assign_proxy)

    def _build_backup_tab(self):
        tab = ttk.Frame(self.tabs, style="Card.TFrame", padding=12)
        self.tabs.add(tab, text="Backup / Nháº­t kÃ½")
        left = ttk.Frame(tab, style="Card.TFrame")
        left.pack(side="left", fill="y", padx=(0, 10))
        ttk.Button(left, text="Táº£i danh sÃ¡ch", command=self.refresh_backups, style="Primary.TButton").pack(fill="x", pady=(0, 6))
        ttk.Button(left, text="Táº¡o backup", command=self.create_backup, style="Success.TButton").pack(fill="x", pady=(0, 6))
        self.backup_list = tk.Listbox(left, width=40, height=25, bg=self.palette["input"], fg=self.palette["text"], selectbackground=self.palette["primary"], selectforeground=self.palette["selection_text"], borderwidth=0, highlightthickness=1, highlightbackground=self.palette["border"], font=("Segoe UI", 10))
        self.backup_list.pack(fill="both", expand=True)
        self.backup_list.bind("<<ListboxSelect>>", self.update_backup_editor)
        backup_editor = ttk.Frame(left, style="Toolbar.TFrame", padding=9)
        backup_editor.pack(fill="x", pady=(8, 0))
        ttk.Label(backup_editor, textvariable=self.backup_selection_var, style="Toolbar.TLabel").pack(anchor="w", pady=(0, 7))
        self.rollback_button = ttk.Button(backup_editor, text="Rollback backup Ä‘ang chá»n", command=self.rollback, style="Warning.TButton", state="disabled")
        self.rollback_button.pack(fill="x")
        right = ttk.Frame(tab, style="Card.TFrame")
        right.pack(side="left", fill="both", expand=True)
        ttk.Label(right, text="Nháº­t kÃ½ thao tÃ¡c").pack(anchor="w")
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
        self.status_var.set(f"Error: {detail}" if self.language == "en" else f"Lá»—i: {detail}")
        self.append_log(f"ERROR: {detail}" if self.language == "en" else f"Lá»–I: {detail}")
        messagebox.showerror("sbproxy", detail, parent=self.root)

    def _task_success(self, result, callback):
        self.hide_loading()
        self.status_var.set(self.t("HoÃ n táº¥t"))
        if callback:
            callback(result)

    def confirm_important(self, title, action, impact):
        """Require an explicit, default-deny confirmation before router mutations."""
        if self.language == "en":
            message = (
                "WARNING Â· IMPORTANT ACTION\n\n"
                f"Action:\n{self.t(action)}\n\n"
                f"Possible impact:\n{self.t(impact)}\n\n"
                "Continue only after verifying the target SSID/device and accepting the impact."
            )
            dialog_title = f"Warning â€” {self.t(title)}"
        else:
            message = (
                "Cáº¢NH BÃO Â· TÃC Vá»¤ QUAN TRá»ŒNG\n\n"
                f"Thao tÃ¡c:\n{action}\n\n"
                f"áº¢nh hÆ°á»Ÿng cÃ³ thá»ƒ xáº£y ra:\n{impact}\n\n"
                "Chá»‰ tiáº¿p tá»¥c khi báº¡n Ä‘Ã£ kiá»ƒm tra Ä‘Ãºng SSID/thiáº¿t bá»‹ vÃ  cháº¥p nháº­n áº£nh hÆ°á»Ÿng."
            )
            dialog_title = f"Cáº£nh bÃ¡o â€” {title}"
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
            raise ValueError("Base URL pháº£i báº¯t Ä‘áº§u báº±ng http:// hoáº·c https://")
        if not token:
            raise ValueError("Thiáº¿u token Agent")
        return AgentClient(base, token)

    def connect(self):
        try:
            client = self._make_client()
        except ValueError as exc:
            self._task_error(exc)
            return
        def work():
            try:
                status = client.status()
            except AgentError as exc:
                audit("connect", router=client.base_url, result="failed", detail=exc)
                raise
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
            self.adopt_router_settings(meta)
            audit("connect", router=self.client.base_url, result="ok",
                  agent=self.agent_version or "?", console=APP_VERSION,
                  singbox="running" if running else "stopped")
            self.status_var.set(
                f"Connected to {self.client.base_url} Â· sing-box {'running' if running else 'NOT running'}"
                if self.language == "en" else
                f"ÄÃ£ káº¿t ná»‘i {self.client.base_url} Â· sing-box {'Ä‘ang cháº¡y' if running else 'KHÃ”NG cháº¡y'}"
            )
            if self.agent_version:
                suffix = f" Â· agent v{self.agent_version}"
                if self.agent_version != APP_VERSION:
                    suffix += " (â‰  app)" if self.language == "en" else " (khÃ¡c app)"
                self.status_var.set(self.status_var.get() + suffix)
            self.render_wifi()
            self.refresh_clients()
            self.refresh_backups()
            self.evaluate_agent_compatibility()
        self.run_task("Äang káº¿t ná»‘i Agentâ€¦", work, done)

    def lock_console(self, settings=None, reason=""):
        """No agent on the router: dim every control and offer one way out."""
        self.pending_provision = settings or self.pending_provision
        self.console_locked = True
        self.lock_hint_var.set(reason or self.t(
            "Router chÆ°a cÃ i agent nÃªn console khÃ´ng Ä‘iá»u khiá»ƒn Ä‘Æ°á»£c gÃ¬. HÃ£y cÃ i agent rá»“i thá»­ láº¡i."
        ))
        self.status_var.set(self.t("KhÃ´ng cáº¥u hÃ¬nh Ä‘Æ°á»£c router â€” chÆ°a cÃ i agent"))
        self.append_log(self.lock_hint_var.get())
        self._apply_lock_state()

    def unlock_console(self):
        """Lift the lock once an agent is actually installed."""
        if not self.console_locked:
            return
        self.console_locked = False
        self._apply_lock_state()

    def _apply_lock_state(self):
        """Render the current lock state onto freshly built widgets."""
        if not hasattr(self, "lock_bar") or not self.lock_bar.winfo_exists():
            return
        panels = [panel for panel in (getattr(self, "connection_row", None),
                                      getattr(self, "gateway_bar", None),
                                      getattr(self, "tabs", None))
                  if panel is not None and panel.winfo_exists()]
        if self.console_locked:
            if not self.lock_bar.winfo_manager():
                self.lock_bar.pack(fill="x", padx=14, pady=(0, 8), before=self.gateway_bar)
            self.locked_widgets = []
            for panel in panels:
                set_widget_tree_disabled(panel, True, self.locked_widgets)
                try:
                    panel.state(["disabled"])  # the notebook itself, so tabs cannot be switched
                    self.locked_widgets.append(panel)
                except (AttributeError, tk.TclError):
                    pass
            # The setup bar would offer a second, weaker path out of the lock.
            self.setup_bar.pack_forget()
            return
        self.lock_bar.pack_forget()
        for panel in panels:
            set_widget_tree_disabled(panel, False, self.locked_widgets)
            if panel in self.locked_widgets:
                try:
                    panel.state(["!disabled"])
                except (AttributeError, tk.TclError):
                    pass
        self.locked_widgets = []
        self.update_setup_banner()

    def install_agent_now(self):
        """The single action a locked console offers."""
        settings = self.pending_provision
        ready = bool(settings and (settings.password or settings.key_path))
        self.open_setup_wizard(settings=settings, autostart=ready)

    def decline_install(self, settings=None):
        """The wizard reported that installing was refused."""
        self.lock_console(settings)

    def update_setup_banner(self):
        """Show the bar while no token is configured, or on a version mismatch."""
        if not hasattr(self, "setup_bar") or not self.setup_bar.winfo_exists():
            return
        if getattr(self, "console_locked", False):
            # The red lock bar already carries the only available action.
            self.setup_bar.pack_forget()
            return
        needed = not self.token_var.get().strip() or self.agent_outdated or self.agent_too_new
        if self.agent_outdated and not self.upgrade_button.winfo_manager():
            self.upgrade_button.pack(side="right", padx=(0, 8))
        elif not self.agent_outdated and self.upgrade_button.winfo_manager():
            self.upgrade_button.pack_forget()
        if self.agent_outdated and not self.ssh_upgrade_button.winfo_manager():
            self.ssh_upgrade_button.pack(side="right", padx=(0, 8))
        elif not self.agent_outdated and self.ssh_upgrade_button.winfo_manager():
            self.ssh_upgrade_button.pack_forget()
        if not needed:
            self.setup_bar.pack_forget()
        elif not self.setup_bar.winfo_manager():
            self.setup_bar.pack(fill="x", padx=14, pady=(0, 8), before=self.gateway_bar)

    def open_setup_wizard(self, settings=None, autostart=False):
        """Run the post-flash sequence and hand the fetched token to the tool."""
        existing = getattr(self, "setup_wizard", None)
        if existing is not None and existing.winfo_exists():
            # Never stack two wizards: the first-run auto-open and the two
            # buttons all share one window.
            existing.deiconify()
            existing.lift()
            existing.focus_force()
            return
        try:
            if settings is None:
                settings = load_provision_settings()
            if not settings.host and self.base_var.get():
                settings.host = self.base_var.get().split("//")[-1].strip("/")
            self.setup_wizard = SetupWizard(
                self.root, settings, self.language, self.palette,
                on_success=self.adopt_token, on_decline=self.decline_install,
                autostart=autostart,
            )
        except Exception as exc:  # a dead button is worse than a visible error
            log.exception("cannot open the setup wizard")
            self.setup_wizard = None
            messagebox.showerror(
                APP_NAME,
                f'{self.t("KhÃ´ng má»Ÿ Ä‘Æ°á»£c cá»­a sá»• cÃ i Ä‘áº·t")}: {exc}',
                parent=self.root,
            )
            return
        self.setup_wizard.lift()
        self.setup_wizard.focus_force()

    def adopt_token(self, base_url, token):
        """Store a freshly provisioned token and open the control screens."""
        self.pending_provision = None
        self.unlock_console()
        self.base_var.set(base_url)
        self.token_var.set(token)
        save_connection(base_url, token)
        self.append_log(
            f"Provisioning finished Â· {base_url}" if self.language == "en"
            else f"CÃ i Ä‘áº·t xong Â· {base_url}"
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
            self.setup_hint_var.set(f"{base} Â· {message}")
            self.append_log(f"{base} Â· {message}")
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
        self.run_task("Äang kiá»ƒm tra tÃ¬nh tráº¡ng routerâ€¦", work, done)

    def evaluate_agent_compatibility(self):
        """Compare the agent with this console and act on the difference.

        Older agent: offer to upgrade it in place (the router keeps its
        configuration). Newer agent: refuse to drive it â€” an old console may
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
                "Agent trÃªn router lÃ  v{agent}, má»›i hÆ¡n console v{app}. HÃ£y dÃ¹ng báº£n console má»›i hÆ¡n;"
                " console cÅ© chá»‰ Ä‘Æ°á»£c phÃ©p xem, má»i thao tÃ¡c thay Ä‘á»•i bá»‹ khoÃ¡.",
                agent=self.agent_version, app=APP_VERSION,
            )
            self.setup_hint_var.set(message)
            self.append_log(message)
            self.update_setup_banner()
            messagebox.showerror(APP_NAME, message, parent=self.root)
            return
        message = self.t(
            "Agent trÃªn router lÃ  v{agent}, cÅ© hÆ¡n console v{app}.",
            agent=self.agent_version, app=APP_VERSION,
        )
        self.setup_hint_var.set(message)
        self.append_log(message)
        self.update_setup_banner()
        if self.upgrade_offered:
            return
        self.upgrade_offered = True
        choice = ask_agent_upgrade_choice(
            self.root,
            message + "\n\n" + self.t(
                "NÃ¢ng cáº¥p agent lÃªn v{app} ngay bÃ¢y giá»? Cáº¥u hÃ¬nh wifi-socks.conf vÃ  settings.sh"
                " trÃªn router Ä‘Æ°á»£c giá»¯ nguyÃªn, router tá»± backup trÆ°á»›c khi cáº­p nháº­t.",
                app=APP_VERSION,
            ),
            self.language,
            self.palette,
        )
        if choice == "api":
            self.upgrade_agent()
        elif choice == "ssh":
            self.reinstall_agent_over_ssh()

    def upgrade_agent(self):
        """Upload this console's router package; the agent keeps its config."""
        client = self.require_client()
        if self.agent_version and compare_versions(APP_VERSION, self.agent_version) != 1:
            messagebox.showinfo(APP_NAME, self.t(
                "Agent Ä‘Ã£ á»Ÿ v{agent}; console nÃ y khÃ´ng cÃ³ báº£n má»›i hÆ¡n Ä‘á»ƒ Ä‘áº©y lÃªn.",
                agent=self.agent_version,
            ), parent=self.root)
            return
        def done(to_version):
            self.append_log(self.t("ÄÃ£ nÃ¢ng cáº¥p agent: {old} â†’ {new}",
                                   old=self.agent_version or "?", new=to_version or "?"))
            self.agent_outdated = False
            self.upgrade_offered = False
            self.update_setup_banner()
            self.connect()
        AgentUpdateWindow(self.root, AgentUpdater(client), self.language, self.palette, on_success=done)

    def reinstall_agent_over_ssh(self):
        """Repair an old agent without touching router configuration."""
        settings = load_provision_settings()
        settings.host = settings.host or self.base_var.get().split("//")[-1].strip("/")
        settings.payload = settings.payload or find_payload()
        settings.agent_only = True
        settings.reinstall_agent = True
        settings.overwrite_config = False
        settings.run_apply = False
        self.open_setup_wizard(settings=settings)

    def adopt_router_settings(self, meta) -> None:
        """Take the router's own NET_BASE/TPROXY_PORT_BASE from status meta."""
        meta = meta if isinstance(meta, dict) else {}
        for key, attribute, fallback in (
            ("net_base", "net_base", DEFAULT_NET_BASE),
            ("tproxy_port_base", "tproxy_port_base", DEFAULT_TPROXY_PORT_BASE),
        ):
            value = meta.get(key)
            setattr(self, attribute, int(value) if isinstance(value, int) and value >= 0 else fallback)

    def subnet_of(self, idx: int) -> str:
        """Subnet the router gives an SSID, using its own NET_BASE."""
        return f"192.168.{self.net_base + int(idx)}.0/24"

    def block_if_incompatible(self) -> bool:
        """Refuse mutations while the router runs a newer agent than this app."""
        if not getattr(self, "agent_too_new", False):
            return False
        message = self.t(
            "Console v{app} cÅ© hÆ¡n agent v{agent} â€” hÃ£y cáº­p nháº­t console trÆ°á»›c khi thay Ä‘á»•i router.",
            app=APP_VERSION, agent=self.agent_version,
        )
        self.append_log(message)
        messagebox.showerror(APP_NAME, message, parent=self.root)
        return True

    def require_client(self) -> AgentClient:
        if not self.client:
            raise AgentError("ChÆ°a káº¿t ná»‘i Agent")
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
                f"Refreshed Â· sing-box {'running' if running else 'NOT running'}"
                if self.language == "en" else
                f"ÄÃ£ lÃ m má»›i Â· sing-box {'Ä‘ang cháº¡y' if running else 'KHÃ”NG cháº¡y'}"
            )
            if self.agent_version:
                suffix = f" Â· agent v{self.agent_version}"
                if self.agent_version != APP_VERSION:
                    suffix += " (â‰  app)" if self.language == "en" else " (khÃ¡c app)"
                self.status_var.set(self.status_var.get() + suffix)
            self.render_wifi()
        self.run_task("Äang lÃ m má»›iâ€¦", work, done)

    def render_gateway(self, payload):
        payload = payload if isinstance(payload, dict) else {}
        self.gateway_payload = payload
        self.render_gateway_interfaces(payload)
        state = str(payload.get("state") or "unknown")
        labels = {
            "ok": ("â— Internet hoáº¡t Ä‘á»™ng", "MetricGreen.TLabel"),
            "degraded": ("â— Internet suy giáº£m", "MetricYellow.TLabel"),
            "down": ("â— Máº¥t káº¿t ná»‘i Internet", "MetricRed.TLabel"),
            "unknown": ("â— Internet chÆ°a xÃ¡c Ä‘á»‹nh", "MetricBlue.TLabel"),
        }
        text, style = labels.get(state, labels["unknown"])
        self.gateway_state_var.set(self.t(text))
        self.gateway_state_label.configure(style=style)

        # Empty means the agent accepts whatever uplink the default route uses.
        expected = str(payload.get("expected_interface") or "")
        logical = str(payload.get("interface") or "â€”")
        device = str(payload.get("device") or "â€”")
        via = str(payload.get("gateway") or ("direct" if self.language == "en" else "trá»±c tiáº¿p"))
        source = str(payload.get("source_ip") or "â€”")
        route = (
            f"Egress: {logical}/{device} Â· via {via} Â· src {source}"
            if self.language == "en" else
            f"ÄÆ°á»ng ra: {logical}/{device} Â· qua {via} Â· IP nguá»“n {source}"
        )
        if payload.get("expected_active") is False:
            problem = str(payload.get("egress_problem") or "")
            if problem == "proxied-bridge":
                route += (" Â· EGRESS THROUGH A PROXIED SSID" if self.language == "en"
                          else " Â· ÄI QUA SSID ÄÆ¯á»¢C PROXY")
            elif expected:
                route += (f" Â· NOT VIA {expected}" if self.language == "en"
                          else f" Â· KHÃ”NG QUA {expected}")
            else:
                route += (" Â· UNEXPECTED EGRESS" if self.language == "en"
                          else " Â· ÄÆ¯á»œNG RA Báº¤T THÆ¯á»œNG")
        self.gateway_route_var.set(route)

        link = "OK" if payload.get("link_ok") else ("ERROR" if self.language == "en" else "Lá»–I")
        if not payload.get("dns_checked", True):
            dns = "not checked" if self.language == "en" else "chÆ°a kiá»ƒm tra"
        else:
            dns = "OK" if payload.get("dns_ok") else ("ERROR" if self.language == "en" else "Lá»–I")
        self.gateway_link_var.set(
            f"Link: {link} Â· DNS: {dns}"
            if self.language == "en" else
            f"Káº¿t ná»‘i: {'Tá»‘t' if link == 'OK' else link} Â· DNS: {'Tá»‘t' if dns == 'OK' else dns}"
        )

        if payload.get("http_ok"):
            self.gateway_http_var.set(
                f"HTTP: {payload.get('http_code') or 0} Â· {payload.get('latency_ms') or 0} ms"
            )
        else:
            error = str(payload.get("error") or ("unreachable" if self.language == "en" else "khÃ´ng truy cáº­p Ä‘Æ°á»£c"))
            self.gateway_http_var.set(f"HTTP: {'ERROR' if self.language == 'en' else 'Lá»–I'} Â· {error}")

    def render_gateway_interfaces(self, payload):
        """Offer the router's own interfaces, with the live one as automatic.

        Nothing here is hard-coded: the list comes from the router, and the
        default choice follows whichever interface currently reaches the
        Internet.
        """
        if not hasattr(self, "gateway_iface_combo") or not self.gateway_iface_combo.winfo_exists():
            return
        interfaces = payload.get("interfaces")
        interfaces = interfaces if isinstance(interfaces, list) else []
        current = ""
        labels, mapping, states = [], {}, {}
        for entry in interfaces:
            if not isinstance(entry, dict):
                continue
            name = str(entry.get("name") or "")
            if not name:
                continue
            parts = [name]
            device = str(entry.get("device") or "")
            if device:
                parts.append(f"({device})")
            address = str(entry.get("ipv4") or "")
            if address:
                parts.append(f"Â· {address}")
            if entry.get("current"):
                current = name
                parts.append("Â· Ä‘ang dÃ¹ng" if self.language != "en" else "Â· in use")
            elif not entry.get("up"):
                parts.append("Â· khÃ´ng hoáº¡t Ä‘á»™ng" if self.language != "en" else "Â· down")
            if entry.get("proxied"):
                continue
            label = " ".join(parts)
            labels.append(label)
            mapping[label] = name
            states[label] = "up" if entry.get("up") else "down"
        automatic = (
            f"Tá»± Ä‘á»™ng ({current})" if current else "Tá»± Ä‘á»™ng"
        ) if self.language != "en" else (
            f"Automatic ({current})" if current else "Automatic"
        )
        mapping[automatic] = ""
        states[automatic] = "up" if current else "down"
        values = [automatic] + labels
        expected = str(payload.get("expected_interface") or "")
        selected = automatic
        for label, name in mapping.items():
            if expected and name == expected:
                selected = label
                break
        self.gateway_iface_choices = mapping
        self.gateway_iface_states = states
        self.gateway_syncing = True
        try:
            self.gateway_iface_combo.configure(values=values)
            self.gateway_iface_var.set(selected)
            self._style_selected_gateway_interface(selected)
        finally:
            self.gateway_syncing = False

    def _style_selected_gateway_interface(self, label=None):
        label = self.gateway_iface_var.get() if label is None else label
        state = self.gateway_iface_states.get(label, "unknown")
        style = {
            "up": "GatewayUp.TCombobox",
            "down": "GatewayDown.TCombobox",
        }.get(state, "GatewayUnknown.TCombobox")
        self.gateway_iface_combo.configure(style=style)

    def _color_gateway_interface_menu(self):
        """Color rows after ttk has populated the native popdown listbox."""
        self.root.after_idle(self._apply_gateway_interface_menu_colors)

    def _apply_gateway_interface_menu_colors(self):
        try:
            popdown = self.root.tk.call("ttk::combobox::PopdownWindow", str(self.gateway_iface_combo))
            listbox = f"{popdown}.f.l"
            values = self.gateway_iface_combo.cget("values")
            for index, label in enumerate(values):
                state = self.gateway_iface_states.get(str(label), "unknown")
                color = self.palette["good_text"] if state == "up" else (
                    self.palette["bad_text"] if state == "down" else self.palette["text"]
                )
                self.root.tk.call(listbox, "itemconfigure", index, "-foreground", color)
        except (tk.TclError, AttributeError):
            # Themes/platforms without the standard ttk popdown still retain
            # the selected-value color configured above.
            pass

    def _on_gateway_interface_changed(self, _event=None):
        """Persist the operator's uplink choice on the router."""
        if self.gateway_syncing:
            return
        chosen = self.gateway_iface_var.get()
        self._style_selected_gateway_interface(chosen)
        interface = self.gateway_iface_choices.get(chosen, "")
        if interface == str(self.gateway_payload.get("expected_interface") or ""):
            return  # nothing changed
        if self.block_if_incompatible():
            self.render_gateway_interfaces(self.gateway_payload)
            return
        client = self.require_client()
        def work():
            self.update_loading("Äang lÆ°u lá»±a chá»n gatewayâ€¦")
            client.set_gateway(interface)
            self.update_loading("ÄÃ£ lÆ°u lá»±a chá»n; Ä‘ang kiá»ƒm tra káº¿t ná»‘i qua gatewayâ€¦")
            return client.gateway()
        def done(payload):
            selected = interface or self.t("tá»± Ä‘á»™ng")
            message = self.t("ÄÃ£ cáº­p nháº­t gateway: {interface}", interface=selected)
            self.append_log(message)
            self.status_var.set(message)
            self.render_gateway(payload)
        self.run_task(
            "Äang cáº­p nháº­t gateway trÃªn routerâ€¦",
            work,
            done,
            show_loading=True,
            timeout_hint=45,
        )

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
                "ok": "hoáº¡t Ä‘á»™ng",
                "degraded": "suy giáº£m",
                "down": "máº¥t káº¿t ná»‘i",
                "unknown": "chÆ°a xÃ¡c Ä‘á»‹nh",
            }.get(state, str(state))
            self.append_log(
                f"Gateway check: {state} Â· {payload.get('route') or 'no route'}"
                if self.language == "en" else
                f"Kiá»ƒm tra cá»•ng ra: {state_vi} Â· {payload.get('route') or 'khÃ´ng cÃ³ route'}"
            )
        self.run_task("Äang kiá»ƒm tra cá»•ng ra Internetâ€¦", client.gateway, done)

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
            self.wifi_selection_var.set(f"{record.name} Â· IDX {record.idx} Â· {record.band}")
        else:
            self.wifi_selection_var.set(self.t("Chá»n má»™t SSID trong báº£ng Ä‘á»ƒ chá»‰nh sá»­a"))

    def next_idx(self):
        used = {item.idx for item in self.records}
        for idx in range(1, 201):
            if idx not in used:
                return idx
        raise AgentError("ÄÃ£ Ä‘áº¡t giá»›i háº¡n 200 SSID")

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
                messagebox.showerror(self.t("IDX bá»‹ trÃ¹ng"), self.t("IDX nÃ y Ä‘Ã£ Ä‘Æ°á»£c sá»­ dá»¥ng"), parent=self.root)
                return
            self.records.append(dialog.result)
            self.records.sort(key=lambda item: item.idx)
            self.render_wifi()

    def edit_wifi(self):
        if self.block_if_incompatible():
            return
        record = self.selected_wifi()
        if not record:
            messagebox.showinfo(APP_NAME, self.t("HÃ£y chá»n má»™t Wiâ€‘Fi"), parent=self.root)
            return
        dialog = WifiDialog(self.root, record, record.idx, self.language, self.palette)
        self.root.wait_window(dialog)
        if dialog.result:
            if any(item.idx == dialog.result.idx and item is not record for item in self.records):
                messagebox.showerror(self.t("IDX bá»‹ trÃ¹ng"), self.t("IDX nÃ y Ä‘Ã£ Ä‘Æ°á»£c sá»­ dá»¥ng"), parent=self.root)
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
            f"XoÃ¡ SSID {record.name} (IDX {record.idx}) khá»i cáº¥u hÃ¬nh Ä‘ang chá»‰nh sá»­a."
            if record else ""
        )
        impact = (
            "The router is not changed yet. On Apply, this SSID, its routing rules, and its connections will be removed."
            if self.language == "en" else
            "ChÆ°a tÃ¡c Ä‘á»™ng router ngay. Khi Apply, SSID, rule Ä‘á»‹nh tuyáº¿n vÃ  cÃ¡c káº¿t ná»‘i cá»§a SSID nÃ y sáº½ bá»‹ xoÃ¡."
        )
        if record and self.confirm_important(
            "XoÃ¡ SSID",
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
            messagebox.showinfo(APP_NAME, self.t("HÃ£y chá»n má»™t Wiâ€‘Fi"), parent=self.root)
            return
        dialog = WifiDialog(self.root, record, record.idx, self.language, self.palette)
        dialog.title(self.t("Äá»•i SOCKS nhanh"))
        self.root.wait_window(dialog)
        if not dialog.result:
            return
        updated = dialog.result
        action = (
            f"Change the {updated.proxy_type.upper()} proxy used by SSID {record.name}."
            if self.language == "en" else
            f"Äá»•i proxy {updated.proxy_type.upper()} Ä‘ang dÃ¹ng cho SSID {record.name}."
        )
        impact = (
            "The change is sent to the router immediately. Existing sessions may disconnect, and an invalid endpoint may leave the SSID without Internet access."
            if self.language == "en" else
            "Thay Ä‘á»•i Ä‘Æ°á»£c gá»­i lÃªn router ngay. PhiÃªn máº¡ng hiá»‡n táº¡i cÃ³ thá»ƒ bá»‹ ngáº¯t; endpoint sai cÃ³ thá»ƒ lÃ m SSID máº¥t Internet."
        )
        if not self.confirm_important(
            "Äá»•i SOCKS5",
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
            fallback = "SOCKS changed successfully" if self.language == "en" else "Äá»•i SOCKS thÃ nh cÃ´ng"
            self.append_log(response.get("log", fallback))
        self.run_task("Äang Ä‘á»•i SOCKSâ€¦", lambda: client.set_sock(updated), done)

    def rotate_wifi_mac(self):
        if self.block_if_incompatible():
            return
        record = self.selected_wifi()
        if not record:
            messagebox.showinfo(APP_NAME, self.t("HÃ£y chá»n má»™t Wiâ€‘Fi cáº§n random MAC"), parent=self.root)
            return
        current = (self.runtime_ssids.get(record.idx) or {}).get("macaddr") or "chÆ°a Ä‘áº·t"
        dialog = RandomMacDialog(self.root, record, current, self.language, self.palette)
        self.root.wait_window(dialog)
        if dialog.result is None:
            return
        selected_oui = dialog.result
        provider = self.t(vendor_label(selected_oui))
        action = (
            f"Change the BSSID/MAC of {record.name}.\nCurrent: {current}\nNew provider: {provider}"
            if self.language == "en" else
            f"Äá»•i BSSID/MAC cá»§a {record.name}.\nHiá»‡n táº¡i: {current}\nProvider má»›i: {provider}"
        )
        impact = (
            "Wi-Fi networks on the same radio will reload, briefly disconnecting devices. The new provider and MAC will persist across future Apply operations."
            if self.language == "en" else
            "Wiâ€‘Fi cÃ¹ng radio sáº½ reload vÃ  cÃ¡c thiáº¿t bá»‹ cÃ³ thá»ƒ máº¥t káº¿t ná»‘i ngáº¯n. Provider vÃ  MAC má»›i sáº½ Ä‘Æ°á»£c lÆ°u qua cÃ¡c láº§n Apply."
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
            new_mac = payload.get("mac") or ("changed" if self.language == "en" else "Ä‘Ã£ Ä‘á»•i")
            record.mac_oui = selected_oui
            runtime = self.runtime_ssids.setdefault(record.idx, {})
            runtime["macaddr"] = new_mac
            runtime["mac_oui"] = selected_oui
            self.render_wifi()
            fallback = (
                f"Rotated MAC {record.name} -> {new_mac}" if self.language == "en" else
                f"ÄÃ£ xoay MAC {record.name} -> {new_mac}"
            )
            self.append_log(payload.get("log", fallback))
            self.status_var.set(
                f"Rotated BSSID {record.name} â†’ {new_mac}; Wi-Fi is reloading"
                if self.language == "en" else
                f"ÄÃ£ xoay BSSID {record.name} â†’ {new_mac}; Wiâ€‘Fi Ä‘ang reload"
            )
            self.root.after(5000, self.refresh_all)

        self.run_task(
            f"Rotating BSSID/MAC for {record.name}â€¦" if self.language == "en" else f"Äang xoay BSSID/MAC cá»§a {record.name}â€¦",
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
            f"Ghi vÃ  kÃ­ch hoáº¡t toÃ n bá»™ cáº¥u hÃ¬nh gá»“m {len(self.records)} SSID."
        )
        impact = (
            "The app will run a dry-run and create a backup first, then save the configuration, replace network rules, and reload Wi-Fi. Devices may be disconnected temporarily."
            if self.language == "en" else
            "App sáº½ dry-run vÃ  backup trÆ°á»›c, sau Ä‘Ã³ ghi cáº¥u hÃ¬nh, thay rule máº¡ng vÃ  reload Wiâ€‘Fi. CÃ¡c thiáº¿t bá»‹ cÃ³ thá»ƒ máº¥t káº¿t ná»‘i táº¡m thá»i."
        )
        if not self.confirm_important(
            "Dry-run vÃ  Apply",
            action,
            impact,
        ):
            return
        def work():
            self.update_loading(
                "Step 1/3 Â· Dry-running the temporary configuration; the router is unchangedâ€¦"
                if self.language == "en" else
                "BÆ°á»›c 1/3 Â· Dry-run cáº¥u hÃ¬nh táº¡m, chÆ°a ghi lÃªn routerâ€¦"
            )
            dryrun = client.dryrun_conf(content)
            if not dryrun.get("ok", False):
                raise AgentError(dryrun.get("log") or "Dry-run tháº¥t báº¡i")
            self.update_loading(
                "Step 2/3 Â· Dry-run passed; creating a backup and saving configurationâ€¦"
                if self.language == "en" else
                "BÆ°á»›c 2/3 Â· Dry-run Ä‘áº¡t, Ä‘ang backup vÃ  lÆ°u cáº¥u hÃ¬nhâ€¦"
            )
            client.save_conf(content)
            self.update_loading(
                "Step 3/3 Â· Running the final required dry-run and applying to the routerâ€¦"
                if self.language == "en" else
                "BÆ°á»›c 3/3 Â· Dry-run báº¯t buá»™c láº§n cuá»‘i vÃ  apply lÃªn routerâ€¦"
            )
            result = client.apply()
            if not result.get("ok", False):
                raise AgentError(result.get("log") or "Apply tháº¥t báº¡i")
            return dryrun, result
        def done(payload):
            _dryrun, result = payload
            self.append_log(
                "DRY-RUN OK Â· No errors found; apply was allowed."
                if self.language == "en" else
                "DRY-RUN OK Â· KhÃ´ng phÃ¡t hiá»‡n lá»—i, Ä‘Ã£ cho phÃ©p apply."
            )
            self.append_log(result.get("log", "Apply succeeded" if self.language == "en" else "Apply thÃ nh cÃ´ng"))
            self.status_var.set(
                "Apply succeeded; Wi-Fi is reloading"
                if self.language == "en" else
                "Apply thÃ nh cÃ´ng; Wiâ€‘Fi Ä‘ang reload"
            )
            self.root.after(5000, self.refresh_all)
        self.run_task(
            "Äang dry-run trÆ°á»›c khi applyâ€¦",
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
            marker = " â–¼" if self.wifi_sort_reverse else " â–²"
            self.wifi_tree.heading(
                column,
                text=self.t(title) + marker if column == self.wifi_sort_column else self.t(title),
                command=lambda selected=column: self.sort_wifi(selected),
            )
        self.wifi_tree.delete(*self.wifi_tree.get_children())
        for pos, record in enumerate(records):
            probe = self.health.get(str(record.idx), self.health.get(record.idx, {})) or {}
            state = probe.get("state", "â€”")
            latency = probe.get("latency_ms")
            health = f"{state} {latency}ms" if latency is not None else state
            runtime = self.runtime_ssids.get(record.idx) or {}
            mac = runtime.get("macaddr") or "â€”"
            provider = self.t(vendor_label(record.mac_oui)).split(" Â· ", 1)[0]
            mac_display = f"{mac} Â· {provider}"
            normalized = str(state).casefold()
            tag = ""
            if any(word in normalized for word in ("ok", "up", "healthy")):
                tag = "healthy"
            elif any(word in normalized for word in ("slow", "warn")):
                tag = "warning"
            elif state not in ("", "â€”", None):
                tag = "error"
            row_tag = "row_even" if pos % 2 == 0 else "row_odd"
            tags = (row_tag, tag) if tag else (row_tag,)
            proxy_display = f"{record.proxy_type.upper()} Â· {record.host}:{record.port}"
            self.wifi_tree.insert("", "end", iid=str(record.idx), tags=tags, values=(record.idx, record.name, record.band, self.subnet_of(record.idx), mac_display, proxy_display, self.t("CÃ³") if record.isolate else self.t("KhÃ´ng"), self.t("Cháº·n") if record.webrtc else self.t("Cho phÃ©p"), health))
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
        self.client_online_count_var.set(f"â— {online} online")
        self.client_weak_count_var.set(f"â— {weak} weak signal" if self.language == "en" else f"â— {weak} tÃ­n hiá»‡u yáº¿u")
        self.client_blocked_count_var.set(f"â— {blocked} blocked" if self.language == "en" else f"â— {blocked} Ä‘Ã£ cháº·n")
        self.client_traffic_total_var.set(f"â— {human_bytes(traffic)} total traffic" if self.language == "en" else f"â— {human_bytes(traffic)} tá»•ng lÆ°u lÆ°á»£ng")

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
            marker = " â–¼" if self.client_sort_reverse else " â–²"
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
                status = "Online Â· blocked" if self.language == "en" else "Online Â· Ä‘Ã£ cáº¥m"
            elif item.get("banned"):
                status = "Offline Â· blocked" if self.language == "en" else "Offline Â· Ä‘Ã£ cáº¥m"
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
                    item.get("mac", ""), client_proxy_text(item, self.language),
                    human_time(item.get("connected_s")) if online else "â€”",
                    human_bytes(item.get("rx_bytes")), human_bytes(item.get("tx_bytes")),
                    f"{signal} dBm" if signal is not None else "â€”", status,
                ),
            )
        self.client_count_var.set(
            f"{len(self.visible_clients)} / {len(self.clients_data)} devices"
            if self.language == "en" else
            f"{len(self.visible_clients)} / {len(self.clients_data)} thiáº¿t bá»‹"
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
            self.run_task("Reading device listâ€¦" if self.language == "en" else "Äang Ä‘á»c danh sÃ¡ch thiáº¿t bá»‹â€¦", work, done)

    def _finish_client_refresh(self):
        self.client_refreshing = False
        if self.client_auto_var.get() and not self.client_refresh_job:
            self.schedule_client_refresh()

    def _auto_client_error(self, exc):
        self.status_var.set(f"Auto-refresh error: {exc}" if self.language == "en" else f"Auto-refresh lá»—i: {exc}")
        self.schedule_client_refresh()

    def selected_client_items(self):
        return [self.client_rows[iid] for iid in self.client_tree.selection() if iid in self.client_rows]

    def update_client_editor(self, _event=None):
        items = self.selected_client_items()
        if not items:
            self.client_selection_var.set(self.t("Chá»n thiáº¿t bá»‹ trong báº£ng Ä‘á»ƒ Ä‘iá»u khiá»ƒn"))
            states = {key: "disabled" for key in self.client_edit_buttons}
        else:
            if len(items) == 1:
                item = items[0]
                label = item.get("host") or item.get("ip") or item.get("mac") or self.t("Thiáº¿t bá»‹")
                self.client_selection_var.set(f"{label} Â· {item.get('ssid') or 'â€”'}")
            else:
                self.client_selection_var.set(
                    f"Selected {len(items)} devices" if self.language == "en"
                    else f"ÄÃ£ chá»n {len(items)} thiáº¿t bá»‹"
                )
            states = {
                "details": "normal" if len(items) == 1 else "disabled",
                "copy": "normal",
                "kick": "normal" if any(item.get("online", True) for item in items) else "disabled",
                "ban": "normal" if any(not item.get("banned") for item in items) else "disabled",
                "unban": "normal" if any(item.get("banned") for item in items) else "disabled",
                # One split cannot span two Wi-Fis, so a mixed selection has the
                # button greyed out rather than failing once it is pressed.
                "proxy": "normal" if len({item.get("idx") for item in items}) == 1 else "disabled",
            }
        for key, button in self.client_edit_buttons.items():
            button.configure(state=states.get(key, "disabled"))

    # --- proxy pool ------------------------------------------------------

    def pool_for_idx(self, idx, refresh=False):
        """One Wi-Fi's pool, cached because it changes far less often than the
        device list that is drawn from it."""
        if refresh or idx not in self.pool_cache:
            self.pool_cache[idx] = self.require_client().get_pool(idx)
        return self.pool_cache[idx]

    def _pool_or_complaint(self, idx):
        """The proxies of one Wi-Fi, or None having already said why not."""
        try:
            self.require_client()
            pool = self.pool_for_idx(idx, refresh=True)
        except AgentError as exc:
            self._task_error(exc)
            return None
        proxies = pool.get("proxies") or []
        if not proxies:
            messagebox.showinfo(APP_NAME, self.t("Wiâ€‘Fi nÃ y chÆ°a cÃ³ proxy nÃ o trong pool"),
                                parent=self.root)
            return None
        return proxies

    def open_pool_editor(self):
        if self.block_if_incompatible():
            return
        record = self.selected_wifi()
        if not record:
            messagebox.showinfo(APP_NAME, self.t("HÃ£y chá»n má»™t Wiâ€‘Fi"), parent=self.root)
            return
        try:
            self.require_client()
            pool = self.pool_for_idx(record.idx, refresh=True)
        except AgentError as exc:
            self._task_error(exc)
            return
        proxies = pool.get("proxies") or []
        usage = pool_slot_usage(self.clients_data, record.idx, len(proxies))
        dialog = PoolDialog(self.root, record, proxies, usage, self.language, self.palette)
        self.root.wait_window(dialog)
        if dialog.result is None:
            return
        self.apply_pool_text(record.idx, dialog.result)

    def apply_pool_text(self, idx, text):
        """Parse a pasted list and replace one Wi-Fi's pool with it."""
        rows, dropped = parse_proxy_list(text, limit=POOL_SLOTS_PER_SSID_MAX)
        if dropped:
            detail = "\n".join(f"{number}: {line} â€” {reason}" for number, line, reason in dropped[:25])
            if len(dropped) > 25:
                detail += f"\nâ€¦ {len(dropped) - 25}"
            messagebox.showwarning(APP_NAME, f"{self.t('Nhá»¯ng dÃ²ng bá»‹ bá» qua')}:\n{detail}",
                                   parent=self.root)
        if not rows and text.strip():
            # Every line was unusable. Saving now would clear the pool because of
            # a typo, so treat it as nothing having been asked for.
            messagebox.showinfo(APP_NAME, self.t("KhÃ´ng cÃ³ dÃ²ng nÃ o dÃ¹ng Ä‘Æ°á»£c"), parent=self.root)
            return
        action = (f"Replace the proxy pool of Wi-Fi {idx} with {len(rows)} proxies."
                  if self.language == "en" else
                  f"Thay pool proxy cá»§a Wiâ€‘Fi {idx} báº±ng {len(rows)} proxy.")
        impact = ("Devices keep the proxy they are on if it is still in the list; the others "
                  "are moved. Wi-Fi is not reloaded, but sing-box restarts."
                  if self.language == "en" else
                  "MÃ¡y nÃ o cÃ²n proxy cÅ© trong danh sÃ¡ch thÃ¬ giá»¯ nguyÃªn, cÃ²n láº¡i bá»‹ chuyá»ƒn. "
                  "Wiâ€‘Fi khÃ´ng bá»‹ reload, nhÆ°ng sing-box khá»Ÿi Ä‘á»™ng láº¡i.")
        if not self.confirm_important("Pool proxy", action, impact):
            return
        try:
            client = self.require_client()
        except AgentError as exc:
            self._task_error(exc)
            return
        def done(response):
            self.pool_cache.pop(idx, None)
            self.append_log(response.get("log") or self.t("HoÃ n táº¥t"))
            self.refresh_clients()
        self.run_task("Äang ghi pool proxyâ€¦", lambda: client.save_pool(idx, rows), done)

    def bulk_assign_proxy(self, ask=None):
        """Deal the selected devices evenly over their Wi-Fi's pool."""
        if self.block_if_incompatible():
            return
        items = self.selected_client_items()
        if not items:
            messagebox.showinfo(APP_NAME, self.t("HÃ£y chá»n thiáº¿t bá»‹ trong báº£ng trÆ°á»›c"),
                                parent=self.root)
            return
        indices = {item.get("idx") for item in items}
        if len(indices) != 1:
            # Slots are numbered per Wi-Fi, so one split cannot span two of them.
            messagebox.showinfo(APP_NAME,
                                self.t("Chá»‰ Ä‘á»•i proxy cho cÃ¡c thiáº¿t bá»‹ trong cÃ¹ng má»™t Wiâ€‘Fi"),
                                parent=self.root)
            return
        idx = indices.pop()
        proxies = self._pool_or_complaint(idx)
        if proxies is None:
            return
        macs = [str(item.get("mac") or "").strip().lower() for item in items]
        plan = split_devices_evenly(macs, len(proxies), random.randrange(2 ** 32))
        preview = [(mac, slot, proxy_display(proxies[slot])) for mac, slot in plan.items()]
        ask = ask or self._ask_bulk_proxy
        if not ask(preview):
            return
        # The rows the operator just approved are the rows that get sent. Dealing
        # again here would shuffle a second time and commit a different layout
        # than the one on screen.
        assignments = [{"mac": mac, "slot": slot} for mac, slot, _label in preview]
        client = self.require_client()
        def done(response):
            self.append_log(response.get("log") or self.t("HoÃ n táº¥t"))
            self.refresh_clients()
        self.run_task("Äang Ä‘á»•i proxy cho thiáº¿t bá»‹â€¦",
                      lambda: client.assign_proxy(idx, assignments), done)

    def _ask_bulk_proxy(self, rows) -> bool:
        dialog = BulkProxyDialog(self.root, rows, self.language, self.palette)
        self.root.wait_window(dialog)
        return bool(dialog.result)

    def assign_one_proxy(self, ask=None):
        """Pin one device to a chosen slot, or unpin it."""
        if self.block_if_incompatible():
            return
        items = self.selected_client_items()
        if len(items) != 1:
            messagebox.showinfo(APP_NAME, self.t("HÃ£y chá»n Ä‘Ãºng má»™t thiáº¿t bá»‹"), parent=self.root)
            return
        item = items[0]
        idx = item.get("idx")
        proxies = self._pool_or_complaint(idx)
        if proxies is None:
            return
        choice = (ask or self._ask_slot)(proxies, item.get("slot"))
        if choice is None:
            return
        mac = str(item.get("mac") or "").strip().lower()
        client = self.require_client()
        def done(response):
            self.append_log(response.get("log") or self.t("HoÃ n táº¥t"))
            self.refresh_clients()
        self.run_task("Äang Ä‘á»•i proxy cho thiáº¿t bá»‹â€¦",
                      lambda: client.assign_proxy(idx, [{"mac": mac, "slot": choice}]), done)

    def _ask_slot(self, proxies, current):
        dialog = SlotChoiceDialog(self.root, proxies, current, self.language, self.palette)
        self.root.wait_window(dialog)
        return dialog.result

    def show_client_context_menu(self, event):
        """Select the row under the pointer, then open the device action menu."""
        row = self.client_tree.identify_row(event.y)
        if not row:
            return None
        if row not in self.client_tree.selection():
            self.client_tree.selection_set(row)
        self.client_tree.focus(row)
        self.update_client_editor()
        try:
            self.client_context_menu.tk_popup(event.x_root, event.y_root)
        finally:
            self.client_context_menu.grab_release()
        return "break"

    def select_all_clients(self, _event=None):
        self.client_tree.selection_set(self.client_tree.get_children())
        self.update_client_editor()
        return "break"

    def manual_ban_client(self):
        if self.block_if_incompatible():
            return
        if not self.records:
            messagebox.showinfo(APP_NAME, self.t("ChÆ°a cÃ³ SSID nÃ o Ä‘á»ƒ Ã¡p dá»¥ng blocklist"), parent=self.root)
            return
        dialog = ManualBanDialog(self.root, self.records, self.language, self.palette)
        self.root.wait_window(dialog)
        if not dialog.result:
            return
        idx, mac = dialog.result
        record = next((item for item in self.records if item.idx == idx), None)
        target = record.name if record else idx
        if not self.confirm_important(
            "ThÃªm vÃ o blocklist",
            f"Block MAC {mac} on SSID {target}." if self.language == "en" else f"Cháº·n MAC {mac} trÃªn SSID {target}.",
            (
                "This device will lose access, and Wi-Fi networks on the same radio may reload briefly."
                if self.language == "en" else
                "Thiáº¿t bá»‹ nÃ y sáº½ máº¥t truy cáº­p vÃ  Wiâ€‘Fi cÃ¹ng radio cÃ³ thá»ƒ reload ngáº¯n."
            ),
        ):
            return
        try:
            client = self.require_client()
        except AgentError as exc:
            self._task_error(exc)
            return
        def done(payload):
            self.append_log(payload.get("log", f"Blocked {mac}" if self.language == "en" else f"ÄÃ£ cháº·n {mac}"))
            self.refresh_clients()
        self.run_task(
            f"Adding {mac} to the blocklistâ€¦" if self.language == "en" else f"Äang thÃªm {mac} vÃ o blocklistâ€¦",
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
            messagebox.showinfo(APP_NAME, self.t("HÃ£y chá»n má»™t hoáº·c nhiá»u thiáº¿t bá»‹"), parent=self.root)
            return
        if action == "kick":
            online_items = [item for item in items if item.get("online", True)]
            if not online_items:
                messagebox.showinfo(APP_NAME, self.t("CÃ¡c thiáº¿t bá»‹ Ä‘Ã£ chá»n Ä‘á»u offline"), parent=self.root)
                return
            items = online_items
        if action == "unban":
            items = [item for item in items if item.get("banned")]
            if not items:
                messagebox.showinfo(APP_NAME, self.t("KhÃ´ng cÃ³ thiáº¿t bá»‹ bá»‹ cáº¥m trong lá»±a chá»n"), parent=self.root)
                return
        if action == "ban":
            items = [item for item in items if not item.get("banned")]
            if not items:
                messagebox.showinfo(APP_NAME, self.t("CÃ¡c thiáº¿t bá»‹ Ä‘Ã£ chá»n Ä‘á»u Ä‘Ã£ bá»‹ cáº¥m"), parent=self.root)
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
            labels = {"kick": "kick", "ban": "cáº¥m", "unban": "bá» cáº¥m"}
            impacts = {
                "kick": "CÃ¡c thiáº¿t bá»‹ sáº½ bá»‹ ngáº¯t káº¿t ná»‘i ngay nhÆ°ng cÃ³ thá»ƒ tá»± káº¿t ná»‘i láº¡i.",
                "ban": "CÃ¡c MAC sáº½ vÃ o blocklist, máº¥t truy cáº­p; Wiâ€‘Fi liÃªn quan cÃ³ thá»ƒ reload ngáº¯n.",
                "unban": "CÃ¡c MAC sáº½ Ä‘Æ°á»£c gá»¡ khá»i blocklist; Wiâ€‘Fi liÃªn quan cÃ³ thá»ƒ reload ngáº¯n.",
            }
            action_text = f"{labels[action].capitalize()} {len(items)} thiáº¿t bá»‹ Ä‘Ã£ chá»n."
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
                        f"{labels[action]} {item['mac']} thÃ nh cÃ´ng"
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
                f"KhÃ´ng cÃ³ thiáº¿t bá»‹ nÃ o {labels[action]} thÃ nh cÃ´ng"
            )
            self.append_log("\n".join(logs) if logs else no_success)
            if failures:
                self.append_log(("ERROR:\n" if self.language == "en" else "Lá»–I:\n") + "\n".join(failures))
                warning = (
                    f"Completed with {len(failures)} errors. See the log."
                    if self.language == "en" else
                    f"HoÃ n táº¥t vá»›i {len(failures)} lá»—i. Xem nháº­t kÃ½."
                )
                messagebox.showwarning(APP_NAME, warning, parent=self.root)
            self.refresh_clients()
        self.run_task(
            (
                f"Processing {labels[action]} for {len(items)} devicesâ€¦"
                if self.language == "en" else
                f"Äang {labels[action]} {len(items)} thiáº¿t bá»‹â€¦"
            ),
            work,
            done,
            show_loading=len(items) > 1,
            timeout_hint=min(300, 45 * len(items)),
        )

    def copy_selected_clients(self):
        items = self.selected_client_items()
        if not items:
            messagebox.showinfo(APP_NAME, self.t("HÃ£y chá»n thiáº¿t bá»‹ cáº§n copy"), parent=self.root)
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
            f"ÄÃ£ copy IP/MAC cá»§a {len(items)} thiáº¿t bá»‹"
        )

    def export_clients_csv(self):
        path = filedialog.asksaveasfilename(
            parent=self.root,
            title="Export filtered devices" if self.language == "en" else "Xuáº¥t danh sÃ¡ch thiáº¿t bá»‹ Ä‘ang lá»c",
            defaultextension=".csv",
            filetypes=(("CSV UTF-8", "*.csv"), (self.t("Táº¥t cáº£ file"), "*.*")),
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
            messagebox.showerror(self.t("KhÃ´ng xuáº¥t Ä‘Æ°á»£c CSV"), str(exc), parent=self.root)
            return
        self.status_var.set(
            f"Exported {len(self.visible_clients)} devices"
            if self.language == "en" else
            f"ÄÃ£ xuáº¥t {len(self.visible_clients)} thiáº¿t bá»‹"
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
                f"SSID: {item.get('ssid') or 'â€”'} ({item.get('band') or 'â€”'})\n"
                f"Status: {'Online' if item.get('online', True) else 'Offline'}"
                f"{' Â· Blocked' if item.get('banned') else ''}\n"
                f"Hostname: {item.get('host') or 'â€”'}\nIP: {item.get('ip') or 'â€”'}\n"
                f"MAC: {item.get('mac') or 'â€”'}\nInterface: {item.get('ifname') or 'â€”'}\n"
                f"Signal: {item.get('signal_dbm') if item.get('signal_dbm') is not None else 'â€”'} dBm\n"
                f"Connected: {human_time(item.get('connected_s')) if item.get('online', True) else 'â€”'}\n"
                f"RX / TX: {human_bytes(item.get('rx_bytes'))} / {human_bytes(item.get('tx_bytes'))}\n"
                f"Total: {human_bytes(total)}"
            )
        else:
            details = (
                f"SSID: {item.get('ssid') or 'â€”'} ({item.get('band') or 'â€”'})\n"
                f"Tráº¡ng thÃ¡i: {'Online' if item.get('online', True) else 'Offline'}"
                f"{' Â· ÄÃ£ cáº¥m' if item.get('banned') else ''}\n"
                f"TÃªn mÃ¡y: {item.get('host') or 'â€”'}\nIP: {item.get('ip') or 'â€”'}\n"
                f"MAC: {item.get('mac') or 'â€”'}\nInterface: {item.get('ifname') or 'â€”'}\n"
                f"TÃ­n hiá»‡u: {item.get('signal_dbm') if item.get('signal_dbm') is not None else 'â€”'} dBm\n"
                f"Káº¿t ná»‘i: {human_time(item.get('connected_s')) if item.get('online', True) else 'â€”'}\n"
                f"RX / TX: {human_bytes(item.get('rx_bytes'))} / {human_bytes(item.get('tx_bytes'))}\n"
                f"Tá»•ng: {human_bytes(total)}"
            )
        messagebox.showinfo(self.t("Chi tiáº¿t thiáº¿t bá»‹"), details, parent=self.root)

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
        self.run_task("Äang Ä‘á»c backupâ€¦", client.backups, done)

    def update_backup_editor(self, _event=None):
        selected = self.backup_list.curselection()
        if selected:
            name = self.backup_list.get(selected[0])
            self.backup_selection_var.set(f"Selected: {name}" if self.language == "en" else f"Äang chá»n: {name}")
            self.rollback_button.configure(state="normal")
        else:
            self.backup_selection_var.set(
                "Select a backup to restore" if self.language == "en" else "Chá»n má»™t backup Ä‘á»ƒ khÃ´i phá»¥c"
            )
            self.rollback_button.configure(state="disabled")

    def create_backup(self):
        if self.block_if_incompatible():
            return
        client = self.require_client()
        label = simpledialog.askstring(self.t("Táº¡o backup"), self.t("NhÃ£n backup"), initialvalue="native", parent=self.root)
        if label is None:
            return
        if not re.fullmatch(r"[A-Za-z0-9._-]+", label):
            messagebox.showerror(APP_NAME, self.t("NhÃ£n chá»‰ Ä‘Æ°á»£c chá»©a chá»¯, sá»‘, dáº¥u . _ -"), parent=self.root)
            return
        def done(payload):
            self.append_log(payload.get("log", "Backup succeeded" if self.language == "en" else "Backup thÃ nh cÃ´ng"))
            self.refresh_backups()
        self.run_task("Äang táº¡o backupâ€¦", lambda: client.backup(label), done)

    def rollback(self):
        if self.block_if_incompatible():
            return
        selected = self.backup_list.curselection()
        if not selected:
            messagebox.showinfo(APP_NAME, self.t("HÃ£y chá»n má»™t backup"), parent=self.root)
            return
        name = self.backup_list.get(selected[0])
        if not self.confirm_important(
            "Rollback",
            f"Restore the router from backup {name}." if self.language == "en" else f"KhÃ´i phá»¥c router tá»« backup {name}.",
            (
                "The current configuration will be replaced. The router and Wi-Fi will reload, interrupting all connections during recovery."
                if self.language == "en" else
                "Cáº¥u hÃ¬nh hiá»‡n táº¡i sáº½ bá»‹ thay tháº¿. Router vÃ  Wiâ€‘Fi sáº½ reload, lÃ m giÃ¡n Ä‘oáº¡n toÃ n bá»™ káº¿t ná»‘i trong lÃºc khÃ´i phá»¥c."
            ),
        ):
            return
        client = self.require_client()
        def done(payload):
            self.append_log(payload.get("log", "Rollback succeeded" if self.language == "en" else "Rollback thÃ nh cÃ´ng"))
            self.status_var.set(
                "Rollback completed; waiting for the router"
                if self.language == "en" else
                "Rollback hoÃ n táº¥t; Ä‘ang chá» router"
            )
            self.root.after(7000, self.connect)
        self.run_task("Äang rollbackâ€¦", lambda: client.rollback(name), done)


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
            f"runtime={RUNTIME_DIR}\npayload={find_payload() or 'â€”'}\n"
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
