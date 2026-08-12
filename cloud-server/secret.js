// secret.js — sinh & lưu JWT secret bền vững (nếu không đặt env JWT_SECRET).
"use strict";
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

module.exports = function () {
  const dir = path.join(__dirname, "data");
  fs.mkdirSync(dir, { recursive: true });
  const f = path.join(dir, "jwt.secret");
  try { return fs.readFileSync(f, "utf8").trim(); }
  catch (e) {
    const s = crypto.randomBytes(48).toString("hex");
    fs.writeFileSync(f, s, { mode: 0o600 });
    return s;
  }
};
