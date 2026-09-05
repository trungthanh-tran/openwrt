#!/usr/bin/env python3
"""Small sbproxy Web installer/updater; intentionally has no controller UI."""

from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import threading
import tkinter as tk
from tkinter import messagebox, ttk
import webbrowser


# Keep this utility's settings/logs separate from the full desktop console.
if "SBPROXY_HOME" not in os.environ:
    if os.name == "nt":
        app_base = Path(os.environ.get("LOCALAPPDATA") or Path.home())
    else:
        app_base = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
    os.environ["SBPROXY_HOME"] = str(app_base / "sbproxy-web-deployer")

# build.ps1 adds console/desktop to the import path. A source checkout gets the
# same path here, keeping provisioning behavior shared with the tested desktop app.
desktop_dir = Path(__file__).resolve().parents[1] / "desktop"
if str(desktop_dir) not in sys.path:
    sys.path.insert(0, str(desktop_dir))
import main as core  # noqa: E402


APP_TITLE = "sbproxy Web Deploy"
HOST_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$")
USER_RE = re.compile(r"^[A-Za-z0-9_.-]{1,32}$")


def validate_connection_fields(host: str, user: str, port_text: str) -> tuple[str, str, int]:
    """Validate the only editable deployment fields without requiring a Tk window."""
    clean_host = host.strip()
    clean_user = user.strip()
    if not HOST_RE.fullmatch(clean_host):
        raise ValueError("IP hoặc hostname không hợp lệ")
    if not USER_RE.fullmatch(clean_user):
        raise ValueError("Username SSH không hợp lệ")
    try:
        port = int(port_text.strip())
    except ValueError:
        raise ValueError("SSH port không hợp lệ") from None
    if not 1 <= port <= 65535:
        raise ValueError("SSH port không hợp lệ")
    return clean_host, clean_user, port


class WebDeployRunner(core.ProvisionRunner):
    """Provision like the desktop app while preserving all live router config."""

    def step_push_code(self) -> str:
        remote = self.settings.remote_dir
        available = core.payload_version(self.settings.payload)
        if self.router_version and available and core.compare_versions(available, self.router_version) == -1:
            raise core.ProvisionError(
                f"Router đang chạy bản mới hơn gói cài: {self.router_version} > {available}"
            )
        core.ensure_app_home()
        workdir = Path(tempfile.mkdtemp(prefix="sbproxy-web-deploy-", dir=str(core.CACHE_DIR)))
        try:
            package = self.package_payload(workdir)
            self.upload(package, "/tmp/sbproxy-web-deploy.tar.gz", "Đẩy gói sbproxy")
            # settings.sh, SSIDs and pools belong to the router operator. Keep
            # them around extraction even if a future package ships defaults.
            command = (
                "set -e; KEEP=$(mktemp -d /tmp/sbproxy-web-keep.XXXXXX); "
                f"mkdir -p {remote}/config; "
                f"for f in wifi-socks.conf proxy-pools.conf settings.sh; do "
                f"[ ! -f {remote}/config/$f ] || cp {remote}/config/$f $KEEP/$f; done; "
                f"tar xzf /tmp/sbproxy-web-deploy.tar.gz -C {remote}; "
                f"for f in wifi-socks.conf proxy-pools.conf settings.sh; do "
                f"[ ! -f $KEEP/$f ] || cp $KEEP/$f {remote}/config/$f; done; "
                f"chmod +x {remote}/scripts/*.sh {remote}/agent/install-agent.sh; "
                "rm -rf $KEEP /tmp/sbproxy-web-deploy.tar.gz"
            )
            self.ssh(command, "Giải nén gói sbproxy", timeout=300)
            self.pushed_version = core.payload_version(package) or available
            return f"{remote} · v{self.pushed_version or '?'}"
        finally:
            shutil.rmtree(workdir, ignore_errors=True)

    def step_apply(self) -> str:
        # Existing installations are code/web updates only. Never reload their
        # working Wi-Fi merely because the deploy utility was opened.
        if self.inventory.get("code"):
            return core.Skipped("Cập nhật web/agent · không apply lại Wi-Fi")
        return super().step_apply()


class DeployApp:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.runner: WebDeployRunner | None = None
        self.busy = False
        self.payload = core.find_payload()
        saved = core.load_provision_settings()

        root.title(APP_TITLE)
        root.geometry("920x680")
        root.minsize(760, 560)
        self._style()

        self.host = tk.StringVar(value=saved.host or "192.168.8.1")
        self.port = tk.StringVar(value=str(saved.port or 22))
        self.user = tk.StringVar(value=saved.user or "root")
        self.password = tk.StringVar()
        self.show_password = tk.BooleanVar(value=False)
        self.open_after = tk.BooleanVar(value=True)
        self.status = tk.StringVar(value="Sẵn sàng kiểm tra hoặc cài đặt")

        shell = ttk.Frame(root, padding=20)
        shell.pack(fill="both", expand=True)
        ttk.Label(shell, text="sbproxy Web Deploy", style="Title.TLabel").pack(anchor="w")
        ttk.Label(
            shell,
            text="Chỉ kiểm tra, cài hoặc cập nhật Web Console. Không có chức năng quản lý Wi‑Fi/proxy.",
            style="Muted.TLabel",
        ).pack(anchor="w", pady=(2, 16))

        form = ttk.LabelFrame(shell, text="Kết nối SSH", padding=12)
        form.pack(fill="x")
        fields = (("Router IP / host", self.host, 0, 0), ("SSH port", self.port, 0, 2),
                  ("Username", self.user, 1, 0), ("Password", self.password, 1, 2))
        self.password_entry = None
        for label, variable, row, column in fields:
            ttk.Label(form, text=label).grid(row=row, column=column, sticky="w", padx=(0, 8), pady=6)
            entry = ttk.Entry(form, textvariable=variable, show="•" if variable is self.password else "")
            entry.grid(row=row, column=column + 1, sticky="ew", padx=(0, 18), pady=6)
            if variable is self.password:
                self.password_entry = entry
        form.columnconfigure(1, weight=3)
        form.columnconfigure(3, weight=2)
        ttk.Checkbutton(form, text="Hiện mật khẩu", variable=self.show_password,
                        command=self._toggle_password).grid(row=2, column=3, sticky="w", pady=(2, 0))

        actions = ttk.Frame(shell)
        actions.pack(fill="x", pady=14)
        self.check_button = ttk.Button(actions, text="Kiểm tra router", command=self.check)
        self.check_button.pack(side="left")
        self.install_button = ttk.Button(actions, text="Cài / Cập nhật", style="Accent.TButton", command=self.install)
        self.install_button.pack(side="left", padx=8)
        self.open_button = ttk.Button(actions, text="Mở Web Console", command=self.open_web)
        self.open_button.pack(side="left")
        ttk.Checkbutton(actions, text="Tự mở web khi hoàn tất", variable=self.open_after).pack(side="right")

        ttk.Label(shell, textvariable=self.status, style="Status.TLabel").pack(anchor="w", pady=(0, 6))
        self.progress = ttk.Progressbar(shell, mode="determinate")
        self.progress.pack(fill="x", pady=(0, 10))

        columns = ("state", "step", "detail")
        self.steps = ttk.Treeview(shell, columns=columns, show="headings", height=10)
        for key, title, width in (("state", "Trạng thái", 100), ("step", "Bước", 250), ("detail", "Chi tiết", 470)):
            self.steps.heading(key, text=title)
            self.steps.column(key, width=width, anchor="w")
        self.steps.pack(fill="both", expand=True)

        ttk.Label(shell, text="Nhật ký").pack(anchor="w", pady=(10, 4))
        self.log = tk.Text(shell, height=7, wrap="word", state="disabled", font=("Cascadia Mono", 9),
                           bg="#f5f5f7", relief="flat", padx=10, pady=8)
        self.log.pack(fill="both", expand=True)
        self._reset_steps()

    def _style(self):
        style = ttk.Style(self.root)
        if "vista" in style.theme_names():
            style.theme_use("vista")
        style.configure("Title.TLabel", font=("Segoe UI", 20, "bold"))
        style.configure("Muted.TLabel", foreground="#6e6e73")
        style.configure("Status.TLabel", foreground="#0066cc", font=("Segoe UI", 10, "bold"))
        style.configure("Accent.TButton", font=("Segoe UI", 10, "bold"))

    def _toggle_password(self):
        self.password_entry.configure(show="" if self.show_password.get() else "•")

    def _settings(self) -> core.ProvisionSettings:
        host, user, port = validate_connection_fields(
            self.host.get(), self.user.get(), self.port.get()
        )
        if not self.payload:
            raise ValueError("Ứng dụng không chứa gói cài sbproxy")
        settings = core.ProvisionSettings(
            host=host, user=user, port=port, password=self.password.get(),
            remote_dir=core.REMOTE_DIR_DEFAULT, payload=self.payload,
            run_apply=True, overwrite_config=False, reinstall_agent=False,
        )
        settings.validate()
        # ProvisionSettings intentionally omits password from persisted data.
        core.save_provision_settings(settings)
        return settings

    def _reset_steps(self):
        self.steps.delete(*self.steps.get_children())
        labels = [label for label, _fn in WebDeployRunner(self._safe_settings()).steps]
        for index, label in enumerate(labels):
            self.steps.insert("", "end", iid=str(index), values=("○ Chờ", label, ""))
        self.progress.configure(maximum=max(1, len(labels)), value=0)

    def _safe_settings(self):
        return core.ProvisionSettings(payload=self.payload or str(Path(__file__)), remote_dir=core.REMOTE_DIR_DEFAULT)

    def _append(self, text):
        safe = core.redact(str(text).strip())
        if not safe:
            return
        self.log.configure(state="normal")
        self.log.insert("end", safe + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def _busy(self, value):
        self.busy = value
        state = "disabled" if value else "normal"
        self.check_button.configure(state=state)
        self.install_button.configure(state=state)

    def _collect_or_error(self):
        try:
            return self._settings()
        except ValueError as exc:
            messagebox.showerror(APP_TITLE, str(exc), parent=self.root)
            return None

    def _emit(self, index, state, detail):
        def update():
            icons = {core.STEP_RUNNING: "● Đang chạy", core.STEP_OK: "✓ Xong",
                     core.STEP_SKIPPED: "– Bỏ qua", core.STEP_FAILED: "✕ Lỗi"}
            self.steps.item(str(index), values=(icons.get(state, state), self.runner.steps[index][0], detail or ""))
            self.steps.see(str(index))
            if state != core.STEP_RUNNING:
                self.progress.configure(value=index + 1)
        self.root.after(0, update)

    def check(self):
        if self.busy:
            return
        settings = self._collect_or_error()
        if not settings:
            return
        self._busy(True)
        self.status.set("Đang kiểm tra router…")

        def worker():
            runner = WebDeployRunner(settings)
            try:
                ssh_info = runner.step_check_ssh()
                inventory = runner.step_inventory()
                message = f"SSH OK · {ssh_info}\n{inventory}"
                self.root.after(0, lambda value=message: self._check_done(True, value))
            except Exception as exc:
                message = str(exc)
                self.root.after(0, lambda value=message: self._check_done(False, value))
        threading.Thread(target=worker, daemon=True).start()

    def _check_done(self, ok, message):
        self._busy(False)
        self.status.set("Router sẵn sàng" if ok else "Không kiểm tra được router")
        self._append(message)
        (messagebox.showinfo if ok else messagebox.showerror)(APP_TITLE, message, parent=self.root)

    def install(self):
        if self.busy:
            return
        settings = self._collect_or_error()
        if not settings:
            return
        self._reset_steps()
        self._busy(True)
        self.status.set("Đang cài hoặc cập nhật…")
        self._append(f"Bắt đầu · {settings.target}")
        self.runner = WebDeployRunner(
            settings, emit=self._emit,
            on_output=lambda text: self.root.after(0, lambda value=text: self._append(value)),
        )

        def worker():
            try:
                success = self.runner.run()
                self.root.after(0, lambda: self._install_done(success, ""))
            except Exception as exc:
                message = str(exc)
                self.root.after(0, lambda value=message: self._install_done(False, value))
        threading.Thread(target=worker, daemon=True).start()

    def _install_done(self, success, error):
        self._busy(False)
        if not success:
            message = error or "Cài đặt dừng ở bước lỗi. Xem chi tiết trong danh sách và nhật ký."
            self.status.set("Cài / cập nhật chưa hoàn tất")
            self._append(message)
            messagebox.showerror(APP_TITLE, message, parent=self.root)
            return
        self.status.set("Hoàn tất · Web Console đã sẵn sàng")
        self._append("Hoàn tất · đã kiểm tra Agent API")
        if self.open_after.get():
            self.open_web()
        else:
            messagebox.showinfo(APP_TITLE, "Cài / cập nhật thành công.", parent=self.root)

    def open_web(self):
        host = self.host.get().strip()
        if not HOST_RE.fullmatch(host):
            return messagebox.showerror(APP_TITLE, "IP hoặc hostname không hợp lệ", parent=self.root)
        webbrowser.open(f"http://{host}/sbproxy/", new=2)


def main() -> int:
    if os.environ.get("SBPROXY_ASKPASS") == "1":
        return 0 if core.write_stdout(os.environ.get("SBPROXY_SSH_PASSWORD", "") + "\n") else 1
    if "--self-test" in sys.argv or "--self-test-gui" in sys.argv:
        payload = core.find_payload()
        if not payload or not Path(payload).exists() or not core.payload_version(payload):
            return 1
        validate_connection_fields("192.168.8.1", "root", "22")
        if "--self-test-gui" in sys.argv:
            root = tk.Tk()
            root.withdraw()
            try:
                DeployApp(root)
                root.update_idletasks()
            finally:
                root.destroy()
        return 0
    core.setup_logging(verbose=False)
    root = tk.Tk()
    DeployApp(root)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
