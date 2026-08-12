// seed.js — tạo/đặt lại SUPERUSER qua CLI (an toàn hơn tạo qua web).
//   node seed.js <username> <password>
// Nếu username đã tồn tại: nâng thành superuser + đổi mật khẩu.
"use strict";
const bcrypt = require("bcryptjs");
const { Users } = require("./db");

const [, , username, password] = process.argv;
if (!username || !password || password.length < 8) {
  console.error("Dùng: node seed.js <username> <password (>=8 ký tự)>");
  process.exit(1);
}
const hash = bcrypt.hashSync(password, 10);
const existing = Users.byName(username);
if (existing) {
  require("./db").db.prepare("UPDATE users SET pass_hash=?, is_super=1, disabled=0, device_scope='\"all\"' WHERE id=?")
    .run(hash, existing.id);
  console.log(`Đã cập nhật '${username}' thành SUPERUSER.`);
} else {
  const u = Users.create({ username, pass_hash: hash, is_super: true, permissions: [], device_scope: "all" });
  console.log(`Đã tạo SUPERUSER '${username}' (id=${u.id}).`);
}
console.log("Đăng nhập tại /login.html");
