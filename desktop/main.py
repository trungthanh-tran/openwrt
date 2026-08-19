#!/usr/bin/env python3
"""sbproxy Console — desktop host.

Wraps the shared web UI (ui/control-panel.html) in a native WebView2 window so
it can talk to the router agent over http on the LAN without the browser's
mixed-content restriction (which blocks an https page from calling http). The
UI is identical to the web build; only the shell differs.

Dev run from the repo:   python main.py
Packaged run:            the exe bundles control-panel.html next to itself.
"""
import os
import sys

import webview


def resource_path(name):
    """Locate a bundled resource, whether running from source or a PyInstaller
    one-file exe (which unpacks data into sys._MEIPASS)."""
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, name)


def ui_path():
    bundled = resource_path("control-panel.html")
    if os.path.exists(bundled):
        return bundled
    # Dev fallback: the shared source in the sibling ui/ directory.
    here = os.path.dirname(os.path.abspath(__file__))
    dev = os.path.join(here, "..", "ui", "control-panel.html")
    return os.path.abspath(dev)


def main():
    html = ui_path()
    if not os.path.exists(html):
        sys.stderr.write("Không tìm thấy control-panel.html\n")
        sys.exit(1)

    # Persist localStorage (agent token, router URL, saved SSIDs) between runs.
    storage = os.path.join(os.path.expanduser("~"), ".sbproxy-console")
    os.makedirs(storage, exist_ok=True)

    window = webview.create_window(
        "sbproxy Console (Desktop)",
        url=html,
        width=1200,
        height=820,
        min_size=(900, 600),
        text_select=True,
    )

    # Tell the UI it is running as the desktop app so it drops the
    # mixed-content guidance and asks for the router URL instead.
    def on_loaded():
        try:
            window.evaluate_js(
                "window.SBPROXY_DESKTOP=true;"
                "window.sbproxyApplyDesktop&&window.sbproxyApplyDesktop();"
            )
        except Exception:
            pass

    window.events.loaded += on_loaded
    # http_server gives the page a stable http origin so cross-origin calls to
    # the router (also http) are never treated as mixed content.
    webview.start(private_mode=False, storage_path=storage, http_server=True)


if __name__ == "__main__":
    main()
