#!/bin/sh
# Run every workstation-safe suite. Router behavior is exercised with stubs;
# this command never connects to or mutates a real router.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ -n "${PYTHON:-}" ]; then
  PYTHON_CMD="$PYTHON"
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import sys' >/dev/null 2>&1; then
  PYTHON_CMD=python3
elif command -v python >/dev/null 2>&1; then
  PYTHON_CMD=python
else
  echo "Python 3 is required for desktop tests" >&2
  exit 1
fi

echo "===== POSIX/OpenWrt generator suite ====="
sh tests/run.sh

echo "===== Proxy pool suite ====="
sh tests/test_pool.sh

echo "===== Proxy pool auto-assign suite ====="
sh tests/test_assignd.sh

echo "===== Native desktop core/workflow suite ====="
"$PYTHON_CMD" -m unittest -v tests.test_pool_console tests.test_desktop_core tests.test_desktop_workflows tests.test_desktop_provision tests.test_desktop_gui tests.test_dirty_data tests.test_web_console_i18n tests.test_reset_parity tests.test_web_table_patch tests.test_web_deployer

echo "===== Agent CGI integration suite ====="
sh tests/test_agent.sh

echo "===== Proxy pool agent suite ====="
sh tests/test_pool_agent.sh

echo "===== Agent health daemon integration suite ====="
sh tests/test_healthd.sh

echo "===== Internet gateway suite ====="
sh tests/test_gateway.sh
sh tests/test_diagnose.sh

echo "===== Client list and device history suite ====="
sh tests/test_clients.sh
