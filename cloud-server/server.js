// server.js — sbproxy Cloud control server.
// Auth (đăng nhập riêng) + RBAC + quản lý user/device + giao thức pull cho router.
"use strict";
const express = require("express");
const cookieParser = require("cookie-parser");
const bcrypt = require("bcryptjs");
const jwt = require("jsonwebtoken");
const crypto = require("crypto");
const path = require("path");
const { Users, Devices, Health, Commands, Audit } = require("./db");
const rbac = require("./rbac");

const PORT = process.env.PORT || 8088;
const JWT_SECRET = process.env.JWT_SECRET || require("./secret")();
const COOKIE = "sbp_session";

const app = express();
app.use(express.json({ limit: "512kb" }));
app.use(cookieParser());
app.use(express.static(path.join(__dirname, "public")));

// ---------- helpers ----------
const sha256 = s => crypto.createHash("sha256").update(s).digest("hex");
function sign(user) { return jwt.sign({ uid: user.id }, JWT_SECRET, { expiresIn: "7d" }); }
function currentUser(req) {
  const t = req.cookies[COOKIE];
  if (!t) return null;
  try { const p = jwt.verify(t, JWT_SECRET); const u = Users.byId(p.uid); return u && !u.disabled ? u : null; }
  catch (e) { return null; }
}
function auth(req, res, next) {
  const u = currentUser(req);
  if (!u) return res.status(401).json({ error: "chưa đăng nhập" });
  req.user = u; next();
}
const requirePerm = perm => (req, res, next) =>
  rbac.has(req.user, perm) ? next() : res.status(403).json({ error: "thiếu quyền: " + perm });
function requireDevice(req, res, next) {
  const d = Devices.byId(Number(req.params.id));
  if (!d) return res.status(404).json({ error: "không thấy router" });
  if (!rbac.canDevice(req.user, d.id)) return res.status(403).json({ error: "không có quyền trên router này" });
  req.device = d; next();
}
const visibleDevices = user => Devices.all().filter(d => rbac.canDevice(user, d.id));

// ---------- auth endpoints ----------
app.post("/api/login", (req, res) => {
  const { username, password } = req.body || {};
  const u = Users.byName(String(username || ""));
  if (!u || u.disabled || !bcrypt.compareSync(String(password || ""), u.pass_hash))
    return res.status(401).json({ error: "sai tài khoản hoặc mật khẩu" });
  res.cookie(COOKIE, sign(u), { httpOnly: true, sameSite: "lax", maxAge: 7 * 864e5, secure: !!process.env.HTTPS });
  Audit.log(u, "login", null);
  res.json({ ok: true });
});
app.post("/api/logout", (req, res) => { res.clearCookie(COOKIE); res.json({ ok: true }); });
app.get("/api/me", auth, (req, res) => {
  res.json({
    id: req.user.id, username: req.user.username, is_super: req.user.is_super,
    permissions: rbac.effective(req.user), device_scope: req.user.device_scope,
    catalog: rbac.PERMISSIONS,
  });
});
app.post("/api/me/password", auth, (req, res) => {
  const { password } = req.body || {};
  if (!password || String(password).length < 8) return res.status(400).json({ error: "mật khẩu ≥ 8 ký tự" });
  Users.update(req.user.id, { pass_hash: bcrypt.hashSync(String(password), 10) });
  Audit.log(req.user, "change_own_password", null);
  res.json({ ok: true });
});

// ---------- devices (user-facing) ----------
app.get("/api/devices", auth, requirePerm("health.view"), (req, res) => {
  res.json(visibleDevices(req.user).map(d => {
    const h = Health.latest(d.id);
    return {
      id: d.id, name: d.name, config_version: d.config_version, applied_version: d.applied_version,
      last_seen: d.last_seen, last_ip: d.last_ip,
      online: d.last_seen && (Date.now() / 1000 - d.last_seen < 60),
      health: h ? JSON.parse(h.probes) : {}, health_ts: h ? h.ts : null,
    };
  }));
});
app.get("/api/devices/:id", auth, requireDevice, (req, res) => {
  const d = req.device, h = Health.latest(d.id);
  res.json({
    id: d.id, name: d.name, config_version: d.config_version, applied_version: d.applied_version,
    last_seen: d.last_seen, last_ip: d.last_ip, backups: JSON.parse(d.backups || "[]"),
    conf: rbac.has(req.user, "wifi.view") ? d.desired_conf : undefined,
    health: h ? JSON.parse(h.probes) : {}, health_ts: h ? h.ts : null,
    commands: Commands.recent(d.id, 10),
  });
});
app.get("/api/devices/:id/health", auth, requireDevice, requirePerm("health.view"), (req, res) => {
  res.json(Health.history(d_id(req), Number(req.query.limit) || 200).map(r => ({ ts: r.ts, probes: JSON.parse(r.probes) })));
});
function d_id(req) { return req.device.id; }

// set desired conf (thay toàn bộ WiFi)
app.put("/api/devices/:id/config", auth, requireDevice, requirePerm("wifi.manage"), (req, res) => {
  const conf = String((req.body && req.body.conf) || "");
  const d = Devices.setConf(req.device.id, conf);
  Audit.log(req.user, "set_config", `device=${d.id} v=${d.config_version}`);
  res.json({ ok: true, config_version: d.config_version });
});
// đổi sock 1 WiFi (enqueue command set_sock, không rớt WiFi)
app.post("/api/devices/:id/sock", auth, requireDevice, requirePerm("sock.change"), (req, res) => {
  const { idx, host, port, user, pass } = req.body || {};
  if (!idx || !host || !port) return res.status(400).json({ error: "thiếu idx/host/port" });
  const cid = Commands.enqueue(req.device.id, "set_sock", { idx, host, port, user: user || "", pass: pass || "" }, req.user.id);
  Audit.log(req.user, "set_sock", `device=${req.device.id} idx=${idx} -> ${host}:${port}`);
  res.json({ ok: true, command_id: cid });
});
// áp cấu hình (bump version để router apply)
app.post("/api/devices/:id/apply", auth, requireDevice, requirePerm("config.apply"), (req, res) => {
  const d = Devices.setConf(req.device.id, req.device.desired_conf);
  Audit.log(req.user, "apply", `device=${d.id} v=${d.config_version}`);
  res.json({ ok: true, config_version: d.config_version });
});
app.post("/api/devices/:id/backup", auth, requireDevice, requirePerm("backup.create"), (req, res) => {
  const cid = Commands.enqueue(req.device.id, "backup", { label: "cloud" }, req.user.id);
  Audit.log(req.user, "backup", `device=${req.device.id}`);
  res.json({ ok: true, command_id: cid });
});
app.post("/api/devices/:id/rollback", auth, requireDevice, requirePerm("backup.rollback"), (req, res) => {
  const name = String((req.body && req.body.name) || "");
  const cid = Commands.enqueue(req.device.id, "rollback", { name }, req.user.id);
  Audit.log(req.user, "rollback", `device=${req.device.id} name=${name}`);
  res.json({ ok: true, command_id: cid });
});

// ---------- device management (superuser / device.manage) ----------
app.get("/api/admin/devices", auth, requirePerm("device.manage"), (req, res) => {
  res.json(Devices.all().map(d => ({
    id: d.id, name: d.name, last_seen: d.last_seen, last_ip: d.last_ip,
    config_version: d.config_version, applied_version: d.applied_version,
    online: d.last_seen && (Date.now() / 1000 - d.last_seen < 60),
  })));
});
app.post("/api/admin/devices", auth, requirePerm("device.manage"), (req, res) => {
  const name = String((req.body && req.body.name) || "").trim();
  if (!name) return res.status(400).json({ error: "thiếu tên" });
  const key = crypto.randomBytes(24).toString("hex");   // chỉ hiển thị 1 lần
  const d = Devices.create(name, sha256(key));
  Audit.log(req.user, "device_create", `id=${d.id} name=${name}`);
  res.json({ ok: true, id: d.id, name, device_key: key });   // lưu key ngay, server không giữ bản rõ
});
app.delete("/api/admin/devices/:id", auth, requirePerm("device.manage"), (req, res) => {
  Devices.remove(Number(req.params.id));
  Audit.log(req.user, "device_delete", `id=${req.params.id}`);
  res.json({ ok: true });
});
app.post("/api/admin/devices/:id/rekey", auth, requirePerm("device.manage"), (req, res) => {
  const d = Devices.byId(Number(req.params.id));
  if (!d) return res.status(404).json({ error: "không thấy" });
  const key = crypto.randomBytes(24).toString("hex");
  require("./db").db.prepare("UPDATE devices SET key_hash=? WHERE id=?").run(sha256(key), d.id);
  Audit.log(req.user, "device_rekey", `id=${d.id}`);
  res.json({ ok: true, device_key: key });
});

// ---------- user management (superuser / user.manage) ----------
app.get("/api/admin/users", auth, requirePerm("user.manage"), (req, res) => {
  res.json(Users.all().map(u => ({
    id: u.id, username: u.username, is_super: u.is_super, disabled: u.disabled,
    permissions: u.permissions, device_scope: u.device_scope,
  })));
});
app.post("/api/admin/users", auth, requirePerm("user.manage"), (req, res) => {
  const { username, password, permissions, device_scope } = req.body || {};
  if (!username || !password || String(password).length < 8)
    return res.status(400).json({ error: "cần username + mật khẩu ≥ 8 ký tự" });
  if (Users.byName(username)) return res.status(409).json({ error: "username đã tồn tại" });
  const u = Users.create({
    username: String(username), pass_hash: bcrypt.hashSync(String(password), 10),
    is_super: false,   // tạo superuser chỉ bằng seed.js (CLI) cho an toàn
    permissions: rbac.sanitizePermissions(permissions),
    device_scope: device_scope === "all" ? "all" : (Array.isArray(device_scope) ? device_scope.map(Number) : []),
  });
  Audit.log(req.user, "user_create", `id=${u.id} name=${u.username}`);
  res.json({ ok: true, id: u.id });
});
app.patch("/api/admin/users/:id", auth, requirePerm("user.manage"), (req, res) => {
  const id = Number(req.params.id);
  const target = Users.byId(id);
  if (!target) return res.status(404).json({ error: "không thấy user" });
  if (target.is_super) return res.status(403).json({ error: "không sửa superuser qua UI (dùng seed.js)" });
  const f = {};
  if (Array.isArray(req.body.permissions)) f.permissions = rbac.sanitizePermissions(req.body.permissions);
  if (req.body.device_scope !== undefined)
    f.device_scope = req.body.device_scope === "all" ? "all" : (Array.isArray(req.body.device_scope) ? req.body.device_scope.map(Number) : []);
  if (req.body.disabled !== undefined) f.disabled = !!req.body.disabled;
  if (req.body.password) { if (String(req.body.password).length < 8) return res.status(400).json({ error: "mật khẩu ≥ 8" }); f.pass_hash = bcrypt.hashSync(String(req.body.password), 10); }
  Users.update(id, f);
  Audit.log(req.user, "user_update", `id=${id}`);
  res.json({ ok: true });
});
app.delete("/api/admin/users/:id", auth, requirePerm("user.manage"), (req, res) => {
  const target = Users.byId(Number(req.params.id));
  if (!target) return res.status(404).json({ error: "không thấy" });
  if (target.is_super && Users.countSupers() <= 1) return res.status(400).json({ error: "không xoá superuser cuối cùng" });
  Users.remove(target.id);
  Audit.log(req.user, "user_delete", `id=${target.id} name=${target.username}`);
  res.json({ ok: true });
});

// ---------- audit ----------
app.get("/api/admin/audit", auth, requirePerm("audit.view"), (req, res) => res.json(Audit.recent(200)));

// ---------- DEVICE protocol (router poll ra, auth bằng X-Device-Key) ----------
function deviceAuth(req, res, next) {
  const key = req.get("X-Device-Key") || "";
  if (!key) return res.status(401).json({ error: "thiếu X-Device-Key" });
  const d = Devices.listForKeyHash(sha256(key));
  if (!d) return res.status(401).json({ error: "device key sai" });
  req.dev = d; next();
}
app.get("/api/device/poll", deviceAuth, (req, res) => {
  const d = req.dev;
  res.json({
    config_version: d.config_version,
    wifi_socks_conf: d.desired_conf,
    commands: Commands.pending(d.id).map(c => ({ id: c.id, type: c.type, payload: JSON.parse(c.payload || "{}") })),
    interval: Number(process.env.POLL_INTERVAL || 10),
  });
});
app.post("/api/device/report", deviceAuth, (req, res) => {
  const d = req.dev, b = req.body || {};
  const ip = (req.headers["x-forwarded-for"] || req.socket.remoteAddress || "").toString().split(",")[0].trim();
  const probes = (b.health && b.health.probes) || b.health || {};
  Health.insert(d.id, probes);
  Devices.touch(d.id, ip, b.applied_version != null ? Number(b.applied_version) : d.applied_version, b.backups || []);
  res.json({ ok: true });
});
app.post("/api/device/ack", deviceAuth, (req, res) => {
  const { command_id, status, result } = req.body || {};
  if (command_id) Commands.ack(Number(command_id), status === "done" ? "done" : "error", result);
  res.json({ ok: true });
});

// ---------- pages ----------
app.get("/", (req, res) => res.redirect(currentUser(req) ? "/app.html" : "/login.html"));

app.listen(PORT, () => console.log(`sbproxy-cloud đang chạy: http://0.0.0.0:${PORT}`));
