// db.js — SQLite (better-sqlite3) schema + helpers.
"use strict";
const path = require("path");
const Database = require("better-sqlite3");

const DB_PATH = process.env.SBPROXY_DB || path.join(__dirname, "data", "sbproxy.db");
require("fs").mkdirSync(path.dirname(DB_PATH), { recursive: true });

const db = new Database(DB_PATH);
db.pragma("journal_mode = WAL");

db.exec(`
CREATE TABLE IF NOT EXISTS users (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  username      TEXT UNIQUE NOT NULL,
  pass_hash     TEXT NOT NULL,
  is_super      INTEGER NOT NULL DEFAULT 0,
  permissions   TEXT NOT NULL DEFAULT '[]',   -- JSON array
  device_scope  TEXT NOT NULL DEFAULT '[]',   -- JSON: "all" | [ids]
  disabled      INTEGER NOT NULL DEFAULT 0,
  created_at    INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  name           TEXT NOT NULL,
  key_hash       TEXT NOT NULL,
  desired_conf   TEXT NOT NULL DEFAULT '',
  config_version INTEGER NOT NULL DEFAULT 0,
  applied_version INTEGER NOT NULL DEFAULT -1,
  last_seen      INTEGER,
  last_ip        TEXT,
  backups        TEXT NOT NULL DEFAULT '[]',   -- JSON array of backup names
  created_at     INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS health (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  device_id  INTEGER NOT NULL,
  ts         INTEGER NOT NULL,
  probes     TEXT NOT NULL              -- JSON {idx:{state,latency_ms,code}}
);
CREATE INDEX IF NOT EXISTS idx_health_dev_ts ON health(device_id, ts);
CREATE TABLE IF NOT EXISTS commands (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  device_id  INTEGER NOT NULL,
  type       TEXT NOT NULL,            -- backup | rollback | set_sock
  payload    TEXT NOT NULL DEFAULT '{}',
  status     TEXT NOT NULL DEFAULT 'pending',  -- pending | done | error
  result     TEXT,
  created_by INTEGER,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_cmd_dev_status ON commands(device_id, status);
CREATE TABLE IF NOT EXISTS audit (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  ts        INTEGER NOT NULL,
  user_id   INTEGER,
  username  TEXT,
  action    TEXT NOT NULL,
  detail    TEXT
);
`);

const now = () => Math.floor(Date.now() / 1000);

function parseUser(r) {
  if (!r) return null;
  let scope;
  try { scope = JSON.parse(r.device_scope); } catch (e) { scope = []; }
  return {
    id: r.id, username: r.username, pass_hash: r.pass_hash,
    is_super: !!r.is_super,
    permissions: JSON.parse(r.permissions || "[]"),
    device_scope: scope,
    disabled: !!r.disabled, created_at: r.created_at,
  };
}

const Users = {
  byId: id => parseUser(db.prepare("SELECT * FROM users WHERE id=?").get(id)),
  byName: n => parseUser(db.prepare("SELECT * FROM users WHERE username=?").get(n)),
  all: () => db.prepare("SELECT * FROM users ORDER BY id").all().map(parseUser),
  create(u) {
    const info = db.prepare(
      "INSERT INTO users (username,pass_hash,is_super,permissions,device_scope,created_at) VALUES (?,?,?,?,?,?)"
    ).run(u.username, u.pass_hash, u.is_super ? 1 : 0,
      JSON.stringify(u.permissions || []),
      JSON.stringify(u.device_scope || []), now());
    return Users.byId(info.lastInsertRowid);
  },
  update(id, fields) {
    const cur = db.prepare("SELECT * FROM users WHERE id=?").get(id);
    if (!cur) return null;
    const m = {
      pass_hash: fields.pass_hash != null ? fields.pass_hash : cur.pass_hash,
      permissions: fields.permissions != null ? JSON.stringify(fields.permissions) : cur.permissions,
      device_scope: fields.device_scope != null ? JSON.stringify(fields.device_scope) : cur.device_scope,
      disabled: fields.disabled != null ? (fields.disabled ? 1 : 0) : cur.disabled,
    };
    db.prepare("UPDATE users SET pass_hash=?,permissions=?,device_scope=?,disabled=? WHERE id=?")
      .run(m.pass_hash, m.permissions, m.device_scope, m.disabled, id);
    return Users.byId(id);
  },
  remove: id => db.prepare("DELETE FROM users WHERE id=?").run(id),
  countSupers: () => db.prepare("SELECT COUNT(*) c FROM users WHERE is_super=1 AND disabled=0").get().c,
};

const Devices = {
  byId: id => db.prepare("SELECT * FROM devices WHERE id=?").get(id),
  all: () => db.prepare("SELECT * FROM devices ORDER BY id").all(),
  create(name, keyHash) {
    const info = db.prepare("INSERT INTO devices (name,key_hash,created_at) VALUES (?,?,?)").run(name, keyHash, now());
    return Devices.byId(info.lastInsertRowid);
  },
  remove(id) {
    db.prepare("DELETE FROM devices WHERE id=?").run(id);
    db.prepare("DELETE FROM health WHERE device_id=?").run(id);
    db.prepare("DELETE FROM commands WHERE device_id=?").run(id);
  },
  setConf(id, conf) {
    db.prepare("UPDATE devices SET desired_conf=?, config_version=config_version+1 WHERE id=?").run(conf, id);
    return Devices.byId(id);
  },
  touch(id, ip, applied, backups) {
    db.prepare("UPDATE devices SET last_seen=?, last_ip=?, applied_version=?, backups=? WHERE id=?")
      .run(now(), ip || null, applied != null ? applied : -1, JSON.stringify(backups || []), id);
  },
  listForKeyHash: h => db.prepare("SELECT * FROM devices WHERE key_hash=?").get(h),
};

const Health = {
  insert(deviceId, probes) {
    db.prepare("INSERT INTO health (device_id,ts,probes) VALUES (?,?,?)").run(deviceId, now(), JSON.stringify(probes || {}));
    // prune: giữ 800 bản ghi/thiết bị
    db.prepare(`DELETE FROM health WHERE device_id=? AND id NOT IN
      (SELECT id FROM health WHERE device_id=? ORDER BY id DESC LIMIT 800)`).run(deviceId, deviceId);
  },
  latest: deviceId => db.prepare("SELECT * FROM health WHERE device_id=? ORDER BY id DESC LIMIT 1").get(deviceId),
  history: (deviceId, limit) => db.prepare("SELECT ts,probes FROM health WHERE device_id=? ORDER BY id DESC LIMIT ?")
    .all(deviceId, limit || 200).reverse(),
};

const Commands = {
  enqueue(deviceId, type, payload, userId) {
    const info = db.prepare("INSERT INTO commands (device_id,type,payload,created_by,created_at) VALUES (?,?,?,?,?)")
      .run(deviceId, type, JSON.stringify(payload || {}), userId || null, now());
    return info.lastInsertRowid;
  },
  pending: deviceId => db.prepare("SELECT * FROM commands WHERE device_id=? AND status='pending' ORDER BY id").all(deviceId),
  ack(id, status, result) {
    db.prepare("UPDATE commands SET status=?, result=? WHERE id=?").run(status, result ? String(result).slice(0, 4000) : null, id);
  },
  recent: (deviceId, limit) => db.prepare("SELECT * FROM commands WHERE device_id=? ORDER BY id DESC LIMIT ?").all(deviceId, limit || 20),
};

const Audit = {
  log(user, action, detail) {
    db.prepare("INSERT INTO audit (ts,user_id,username,action,detail) VALUES (?,?,?,?,?)")
      .run(now(), user ? user.id : null, user ? user.username : "device", action, detail ? String(detail).slice(0, 500) : null);
  },
  recent: limit => db.prepare("SELECT * FROM audit ORDER BY id DESC LIMIT ?").all(limit || 100),
};

module.exports = { db, now, Users, Devices, Health, Commands, Audit };
