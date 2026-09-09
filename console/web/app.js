// app.js — the sbproxy web console. Every page under /sbproxy/ loads this one
// file; it used to be pasted into each of them, which is how config.html and
// its siblings drifted four releases behind control-panel.html.

(function () {
  "use strict";
  // Kept in sync with the repo VERSION file; tests/run.sh enforces the match.
  const UI_VERSION = "0.5.35-SNAPSHOT";
  const LS_KEY = "sbproxy.ssids.v1";
  const LANGUAGE_KEY = "sbproxy.language";
  let language = localStorage.getItem(LANGUAGE_KEY) === "vi" ? "vi" : "en";
  const pick = (en, vi) => language === "vi" ? vi : en;
  const EN_TEXT = window.SBPROXY_I18N_EN.EN_TEXT;
  const EN_HTML = window.SBPROXY_I18N_EN.EN_HTML;
  const EN_ATTR = window.SBPROXY_I18N_EN.EN_ATTR;
  // Dynamic labels are translated here, where the live language state exists.
  // Keeping this beside pick() avoids crossing the private IIFE boundary of
  // i18n.en.js, which only exports the translation tables.
  const ICON_PREFIX = /^([^\p{L}\p{N}(]*)(.*)$/su;
  function translatePhrase(vi) {
    const match = String(vi || "").match(ICON_PREFIX);
    if (!match || language === "vi") return vi;
    const body = EN_TEXT[match[2].trim()];
    return body === undefined ? vi : match[1] + body;
  }
  function localizeStatic(root = document.body) {
    root.querySelectorAll("[data-i18n-html]").forEach(el => {
      const key = el.dataset.i18nHtml;
      if (!el.dataset.i18nHtmlVi) el.dataset.i18nHtmlVi = el.innerHTML;
      el.innerHTML = language === "vi" ? el.dataset.i18nHtmlVi : (EN_HTML[key] || el.dataset.i18nHtmlVi);
    });
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
      if (node.parentElement && ["SCRIPT", "STYLE", "PRE", "CODE", "OPTION"].includes(node.parentElement.tagName)) continue;
      if (node.parentElement && node.parentElement.closest("[data-i18n-html], [data-i18n-skip]")) continue;
      const raw = node.nodeValue;
      const trimmed = raw.trim();
      if (!trimmed) continue;
      if (!node.parentElement.dataset.i18nVi) node.parentElement.dataset.i18nVi = trimmed;
      const vi = node.parentElement.dataset.i18nVi;
      node.nodeValue = raw.replace(trimmed, translatePhrase(vi));
    }
    root.querySelectorAll("[title]").forEach(el => {
      if (!el.dataset.i18nTitleVi) el.dataset.i18nTitleVi = el.title;
      el.title = language === "vi" ? el.dataset.i18nTitleVi : (EN_ATTR[el.dataset.i18nTitleVi] || el.dataset.i18nTitleVi);
    });
    document.documentElement.lang = language;
    document.getElementById("languageSelect").value = language;
    scheduleDialogActions();
  }

  function setLanguage(next) {
    language = next === "vi" ? "vi" : "en";
    localStorage.setItem(LANGUAGE_KEY, language);
    localizeStatic();
    renderVendorOptions();
    render();
    updateConnHint();
    renderVersion();
  }
  // Defaults only: a connected agent reports the router's effective
  // config/settings.sh values through status meta (see applyRouterSettings).
  let NET_BASE = 10, TPROXY_BASE = 12000, BSSID_LIMIT = 16, SOCKS_UDP = true, POOL_UNASSIGNED = "default";
  const MARK = 1;
  const STUN_TCP = "3478, 3479, 5349, 5350";
  const STUN_UDP = "3478, 3479, 5349, 5350, 19302-19309";

  // WebRTC handling per Wi-Fi, column 10 of wifi-socks.conf. It used to be a
  // 0/1 flag, so a stored boolean still reads back as the mode it meant.
  const WEBRTC_KEEP = 0, WEBRTC_BLOCK = 1, WEBRTC_BYPASS = 2;
  function webrtcMode(value) {
    if (value === true) return WEBRTC_BLOCK;
    const n = parseInt(value, 10);
    return (n === WEBRTC_BLOCK || n === WEBRTC_BYPASS) ? n : WEBRTC_KEEP;
  }
  function webrtcText(value) {
    switch (webrtcMode(value)) {
      case WEBRTC_BLOCK: return pick("Block WebRTC", "Chặn WebRTC");
      case WEBRTC_BYPASS: return pick("Bypass WebRTC", "Bypass WebRTC");
      default: return pick("Keep as-is", "Giữ nguyên");
    }
  }
  function webrtcCell(value) {
    const mode = webrtcMode(value);
    if (mode === WEBRTC_BLOCK) return '<span class="chip on warnhue"><span class="dot"></span>' + pick("block", "chặn") + '</span>';
    if (mode === WEBRTC_BYPASS) return '<span class="chip on"><span class="dot"></span>' + pick("bypass", "bypass") + '</span>';
    return '<span class="chip">' + pick("keep", "giữ nguyên") + '</span>';
  }
  function updateWebrtcHint() {
    const hint = $("f_webrtc_hint");
    if (!hint) return;
    switch (webrtcMode($("f_webrtc").value)) {
      case WEBRTC_BLOCK:
        hint.textContent = pick("Drops STUN/TURN, so WebRTC cannot leak an address — and calls stop working.",
                                "Chặn STUN/TURN nên WebRTC không lộ IP — đồng thời cuộc gọi cũng không chạy.");
        break;
      case WEBRTC_BYPASS:
        hint.textContent = pick("Forces STUN/TURN through the proxy, so WebRTC reports the proxy IP. Needs a proxy that relays UDP.",
                                "Đẩy STUN/TURN qua proxy để WebRTC báo IP của proxy. Cần proxy hỗ trợ UDP.");
        break;
      default:
        hint.textContent = pick("No WebRTC-specific rule.", "Không áp rule riêng cho WebRTC.");
    }
  }

  // Common Wi-Fi vendor OUIs (first 3 MAC bytes). Keep in sync with the list in
  // config/wifi-socks.conf.example. Empty oui = random locally-administered 02:.
  const VENDORS = [
    { name: "Ngẫu nhiên / ẩn danh (02:xx)", oui: "" },
    { name: "TP-Link", oui: "50:C7:BF" },
    { name: "Netgear", oui: "20:E5:2A" },
    { name: "ASUS", oui: "AC:9E:17" },
    { name: "Xiaomi", oui: "64:09:80" },
    { name: "Huawei", oui: "00:E0:FC" },
    { name: "D-Link", oui: "1C:BD:B9" },
    { name: "Linksys", oui: "C0:56:27" },
    { name: "Tenda", oui: "C8:3A:35" },
    { name: "Apple", oui: "3C:15:C2" },
    { name: "Samsung", oui: "5C:0A:5B" },
    { name: "Ubiquiti", oui: "24:A4:3C" },
    { name: "Aruba", oui: "00:0B:86" }
  ];
  const vendorLabel = v => v.oui ? v.name : pick("Random / anonymous (02:xx)", "Ngẫu nhiên / ẩn danh (02:xx)");
  const vendorName = oui => {
    const v = VENDORS.find(x => x.oui.toUpperCase() === String(oui || "").toUpperCase());
    return v ? vendorLabel(v) : (oui ? oui : vendorLabel(VENDORS[0]));
  };

  /** @type {Array} */
  let ssids = load();
  const poolCounts = {};
  let poolCountSignature = "";
  let configDirty = false;
  let editId = null;
  let curTab = "conf";

  // ---- persistence ----
  function load() {
    try { return JSON.parse(localStorage.getItem(LS_KEY)) || []; } catch (e) { return []; }
  }
  function save() { localStorage.setItem(LS_KEY, JSON.stringify(ssids)); }

  // ---- derived ----
  // The router is the source of truth for these; an agent too old to send them
  // leaves the defaults in place.
  function applyRouterSettings(meta) {
    if (!meta) return;
    const take = (value, fallback) =>
      (Number.isInteger(value) && value >= 0) ? value : fallback;
    NET_BASE = take(meta.net_base, NET_BASE);
    TPROXY_BASE = take(meta.tproxy_port_base, TPROXY_BASE);
    BSSID_LIMIT = take(meta.bssid_limit, BSSID_LIMIT);
    if (typeof meta.socks_udp === "boolean") SOCKS_UDP = meta.socks_udp;
    if (meta.pool_unassigned === "block" || meta.pool_unassigned === "default") POOL_UNASSIGNED = meta.pool_unassigned;
  }

  const octet = i => NET_BASE + i;
  const rowForIdx = i => ssids.find(s => Number(s.idx) === Number(i));
  const subnet = i => {
    const s = rowForIdx(i);
    return s && s.local_subnet ? s.local_subnet : `192.168.${octet(i)}.0/24`;
  };
  const gw = i => subnet(i).replace(/\.0\/24$/, ".1");
  const tport = i => TPROXY_BASE + i;
  const isIP = h => /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/.test(h);
  // Patch a <tbody> from a keyed list instead of rebuilding it.
  //
  // Replacing innerHTML on a timer re-creates every row: the table blinks, the
  // scroll position jumps, a text selection disappears and a checkbox the
  // operator just clicked is thrown away mid-poll. Here a row whose rendered
  // HTML is unchanged keeps its DOM node untouched; only genuinely changed
  // rows are rewritten, new keys inserted and gone keys removed.
  function patchTable(tbody, items, keyOf, cellsOf, classOf) {
    const existing = new Map();
    Array.from(tbody.children).forEach(tr => {
      const key = tr.getAttribute("data-key");
      if (key === null) tr.remove();      // placeholder ("Loading…", empty state)
      else existing.set(key, tr);
    });
    let prev = null;
    items.forEach(item => {
      const key = String(keyOf(item));
      const cells = cellsOf(item);
      const cls = classOf ? (classOf(item) || "") : "";
      let tr = existing.get(key);
      if (tr) existing.delete(key);
      else {
        tr = document.createElement("tr");
        tr.setAttribute("data-key", key);
      }
      // The cached string is what makes this cheap: no DOM work at all for a
      // row the router reported identically.
      if (tr._cells !== cells) { tr.innerHTML = cells; tr._cells = cells; }
      if (tr.className !== cls) tr.className = cls;
      const want = prev ? prev.nextElementSibling : tbody.firstElementChild;
      if (want !== tr) tbody.insertBefore(tr, want);
      prev = tr;
    });
    existing.forEach(tr => tr.remove());
  }

  const esc = s => String(s).replace(/[&<>]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));

  function nextIdx() {
    const used = new Set(ssids.map(s => s.idx));
    let i = 1; while (used.has(i)) i++; return i;
  }

  // ---- Local router agent (uhttpd CGI) ----
  const agent = {
    base: localStorage.getItem("sbproxy.agent.base") || "",
    token: localStorage.getItem("sbproxy.agent.token") || "",
    user: localStorage.getItem("sbproxy.agent.user") || "",
    connected: false, health: {}, timer: null, version: ""
  };
  const apiUrl = a => (agent.base || "") + "/cgi-bin/sbproxy?action=" + a;

  // Every answer from the agent is JSON. When it is not -- uhttpd replying
  // "Unable to launch the requested CGI program" because the agent was never
  // installed, a 404 from a router without the CGI, an empty 502 from a
  // reloading uhttpd -- the browser's own "Unexpected token 'U'" message hides
  // what actually happened, so translate the body into something actionable.
  function agentBodyError(res, text) {
    const body = String(text || "").replace(/\s+/g, " ").trim();
    if (/Unable to launch the requested CGI/i.test(body) || res.status === 404) {
      return pick(
        "The router has no sbproxy agent: uhttpd cannot run /cgi-bin/sbproxy. Install it over SSH with: sh /root/sbproxy/agent/install-agent.sh (or use sbproxy Web Deploy → Install / Update).",
        "Router chưa cài agent sbproxy: uhttpd không chạy được /cgi-bin/sbproxy. Cài qua SSH: sh /root/sbproxy/agent/install-agent.sh (hoặc dùng sbproxy Web Deploy → Cài / Cập nhật).");
    }
    if (!body) {
      return pick(`HTTP ${res.status}: the router answered with an empty body.`,
                  `HTTP ${res.status}: router trả về rỗng.`);
    }
    const short = body.length > 200 ? body.slice(0, 200) + "…" : body;
    return pick(`HTTP ${res.status}: the answer is not JSON — ${short}`,
                `HTTP ${res.status}: phản hồi không phải JSON — ${short}`);
  }
  function readJson(res) {
    return res.text().then(text => {
      let data;
      try { data = text ? JSON.parse(text) : null; } catch (e) { data = null; }
      if (data && typeof data === "object") return data;
      throw new Error(agentBodyError(res, text));
    });
  }
  // What the router said, trimmed to something a toast can hold. Router
  // scripts answer with `log` (their own stdout+stderr) or `error` (the CGI's
  // own refusal); a generic "X failed" hides both.
  // Every write to the router goes through this: the chip says which step is
  // running and the page stops accepting a second write until it is done.
  function busy(step) {
    toast(step);
    setBusyChip(step, true);
  }
  function busyDone() { setBusyChip("", false); }
  // Decoration only: these functions are also cut out of this file and run
  // under Node by the tests, and a chip that throws would take the reset or
  // the apply down with it.
  function setBusyChip(step, on) {
    if (typeof document === "undefined" || !document.body) return;
    document.body.classList.toggle("busy", on);
    const chip = document.getElementById("busyText");
    if (chip) chip.textContent = step;
  }
  // Every mutating action -- SSID, proxy or device -- is a write to the
  // router, and they all owe the operator the same three things: the wait
  // while it happens, the router's own words when it refuses, and a refresh
  // of whatever it changed. Wrapping them one by one drifted; this is the path.
  function routerWrite(label, run, after) {
    busy(label + "…");
    return Promise.resolve().then(run).then(d => {
      if (d && d.ok === false) throw new Error(routerReason(d, label));
      toast(label + " ✓");
      if (after) after(d);
      return d;
    }).catch(err => {
      toast(pick("Error: ", "Lỗi: ") + (err.message || err));
      throw err;
    }).finally(busyDone);
  }
  function routerReason(d, fallback) {
    const raw = String((d && (d.error || d.log)) || "").replace(/\s+/g, " ").trim();
    if (!raw) return fallback;
    // Scripts print progress first and the reason last, so search upwards and
    // fall back to the final line rather than to the first "Backing up..." one.
    const lines = String((d && (d.error || d.log)) || "").split(/\r?\n/).map(l => l.trim()).filter(Boolean);
    const blame = [...lines].reverse().find(l => /\[ERR\]|error|failed|denied|invalid|refus/i.test(l))
      || lines[lines.length - 1] || raw;
    return blame.length > 240 ? blame.slice(0, 240) + "…" : blame;
  }
  function api(action, method, body, isText) {
    const headers = { "Authorization": `Bearer ${agent.token}` };
    if (body != null) headers["Content-Type"] = isText ? "text/plain" : "application/json";
    return fetch(apiUrl(action), {
      method: method || "GET", headers,
      body: body == null ? undefined : (isText ? body : JSON.stringify(body))
    }).then(r => isText === "resp" ? r.text() : readJson(r));
  }

  const healthHistory = {};   // idx -> [{ms,state}], accumulated on each poll
  const HIST_MAX = 60;

  function sparkline(idx) {
    const h = healthHistory[idx];
    if (!h || h.length < 2) return "";
    const w = 72, ht = 18, n = h.length;
    const max = Math.max(300, ...h.map(p => p.ms));
    const pts = h.map((p, i) => `${((i / (n - 1)) * w).toFixed(1)},${(ht - (p.ms / max) * ht).toFixed(1)}`).join(" ");
    const last = h[h.length - 1];
    const col = last.state === "fail" ? "var(--crit)" : last.state === "slow" ? "var(--warn)" : "var(--good)";
    const lx = w, ly = (ht - (last.ms / max) * ht).toFixed(1);
    return `<svg class="spark" width="${w}" height="${ht}" viewBox="0 0 ${w} ${ht}" aria-hidden="true">
      <polyline points="${pts}" fill="none" stroke="${col}" stroke-width="1.5" stroke-linejoin="round"/>
      <circle cx="${lx}" cy="${ly}" r="1.8" fill="${col}"/></svg>`;
  }

  function healthCell(idx) {
    if (!agent.connected) return '<span class="sub">—</span>';
    const h = agent.health[idx];
    if (!h) return '<span class="hp wait">…</span>';
    const where = h.endpoint ? String(h.endpoint) + " · " : "";
    const why = (where + (h.error ? String(h.error) : "")).trim();
    const pill = h.state === "fail"
      ? `<span class="hp bad" title="${esc(why || pick("The probe did not get through this proxy.", "Probe không đi qua được proxy này."))}"><span class="dot"></span>fail${h.code ? " " + h.code : ""}${why ? " ⓘ" : ""}</span>`
      : `<span class="hp ${h.state === "slow" ? "warnp" : "okp"}" title="${esc(pick(`HTTP ${h.code} in ${h.latency_ms}ms`, `HTTP ${h.code} trong ${h.latency_ms}ms`))}"><span class="dot"></span>${h.latency_ms}ms</span>`;
    return `<span class="healthwrap">${pill}${sparkline(idx)}</span>`;
  }

  function setConnStatus(msg, cls) {
    const el = document.getElementById("connStatus");
    el.textContent = msg; el.className = "conn-status" + (cls ? " " + cls : "");
  }
  function updateLiveUI() {
    document.documentElement.dataset.authenticated = agent.connected ? "true" : "false";
    document.body.classList.toggle("authenticated", agent.connected);
    const connButton = document.getElementById("connBtn");
    const authLogoutButton = document.getElementById("authLogoutBtn");
    const settingsConnect = document.getElementById("settingsConnect");
    if (connButton) connButton.hidden = agent.connected;
    if (authLogoutButton) authLogoutButton.hidden = !agent.connected;
    if (settingsConnect) settingsConnect.hidden = agent.connected;
    document.getElementById("liveBadge").classList.toggle("on", agent.connected);
    document.getElementById("liveTools").classList.toggle("on", agent.connected);
    document.getElementById("topRouterTools").classList.toggle("on", agent.connected);
    const who = document.getElementById("whoami");
    who.hidden = !(agent.connected && agent.user);
    who.textContent = agent.user ? "👤 " + agent.user : "";
    renderVersion();
  }
  function renderVersion() {
    const el = document.getElementById("verLine");
    if (!el) return;
    let txt = "v" + UI_VERSION;
    if (agent.connected && agent.version) txt += " · agent v" + agent.version;
    el.textContent = txt;
    el.style.color = (agent.connected && agent.version && agent.version !== UI_VERSION)
      ? "var(--warn)" : "";
    el.title = (agent.connected && agent.version && agent.version !== UI_VERSION)
      ? pick("The agent version differs from the UI version — consider using ⬆ Update",
             "Version agent khác version UI — cân nhắc dùng ⬆ Cập nhật") : "";
  }

  // The conf text the router last handed us. A refresh that finds the same
  // text touches nothing on the page: re-rendering the table, the stats and
  // the preview every tick was what made the console blink and lose scroll.
  let lastRouterConf = null;
  function refreshConfFromRouter() {
    // Do not overwrite a form while the operator is editing it.
    if (configDirty || featureOpen("backdrop")) return;
    api("get_conf", "GET", null, "resp").then(txt => {
      if (txt == null || txt === lastRouterConf) return;
      lastRouterConf = txt;
      parseConfInto(txt); render();
    }).catch(() => {});
  }
  // Status (health, sing-box, version) every 10 s — cheap, and a dead sing-box
  // should show within seconds. The conf is compared every 60 s.
  function startPoll() {
    stopPoll();
    poll();
    refreshConfFromRouter();
    let tick = 0;
    agent.timer = setInterval(() => {
      poll();
      if (++tick % 6 === 0) refreshConfFromRouter();
    }, 10000);
  }
  function stopPoll() { if (agent.timer) clearInterval(agent.timer); agent.timer = null; }
  function poll() {
    api("status").then(d => {
      if (!d || !d.ok) throw new Error((d && d.error) || pick("bad response", "phản hồi lỗi"));
      const wasConnected = agent.connected;
      agent.connected = true;
      agent.health = (d.health && d.health.probes) || {};
      agent.version = (d.meta && d.meta.version) || "";
      applyRouterSettings(d.meta);
      recordHistory();
      const run = !!(d.meta && d.meta.singbox_running);
      const up = (d.meta && typeof d.meta.singbox_uptime_s === "number") ? d.meta.singbox_uptime_s : null;
      // Uptime running backwards means procd replaced the process between two
      // polls: it is alive at every glance yet never actually stays up. That
      // is the crash loop a single "is there a pid?" check reported as
      // healthy, so the card gets to say so.
      const was = agent.singbox;
      const restarted = !!(was && was.running && run && was.uptime != null && up != null && up < was.uptime);
      agent.singbox = {
        running: run, uptime: up, checked: Date.now(),
        flapping: restarted || !!(was && was.flapping && run && (up == null || up < 60))
      };
      updateLiveUI();
      // Only what a poll can change is touched: the health cells and the
      // sing-box indicator. The rows come from the local SSID list, so they
      // are rebuilt once, on the transition to connected (row buttons appear).
      if (wasConnected) updateHealthCells(); else renderRows();
      const poolSignature = ssids.map(s => s.idx).sort((a, b) => a - b).join(",");
      if (poolSignature !== poolCountSignature) refreshPoolCounts();
      updateSingboxUI();
      if (!$('settingsPage').hidden) renderSettings();
      setConnStatus(pick("Connected · sing-box " + (run ? "running" : "NOT running"),
                         "Đã kết nối · sing-box " + (run ? "đang chạy" : "KHÔNG chạy")), run ? "ok" : "bad");
    }).catch(err => {
      if (agent.connected) { agent.connected = false; agent.singbox = null; updateLiveUI(); renderRows(); updateSingboxUI(); }
      stopPoll();
      setConnStatus(pick("Connection lost: " + err.message + " (mixed content? wrong token? agent not installed?)",
                         "Mất kết nối: " + err.message + " (mixed-content? token sai? agent chưa cài?)"), "bad");
    });
  }

  // ---- sing-box: the one process whose silence kills every proxied SSID ----
  // Its state lives on the main page (a stats card and a top-bar chip), not
  // only inside the Connect dialog, and every poll refreshes it in place.
  function singboxCard() {
    const sb = agent.singbox;
    if (!agent.connected || !sb) {
      return `<div class="stat sb" id="sbCard"><div class="label">sing-box</div><div class="val"><small>—</small></div></div>`;
    }
    if (sb.running && sb.flapping) {
      return `<div class="stat sb warnstate" id="sbCard">
        <div class="label">sing-box</div>
        <div class="val" style="color:var(--crit)">${pick("RESTARTING", "KHỞI ĐỘNG LẠI LIÊN TỤC")}</div>
        <div class="sub">${pick("it starts and dies again — the proxy engine never settles", "cứ chạy lên rồi chết — engine proxy không trụ được")}</div>
        <button class="btn primary" id="sbRestartBtn">↻ ${pick("Restart sing-box", "Khởi động lại sing-box")}</button></div>`;
    }
    if (sb.running) {
      return `<div class="stat sb" id="sbCard" title="${pick("Click to restart sing-box", "Bấm để khởi động lại sing-box")}">
        <div class="label">sing-box</div>
        <div class="val" style="color:var(--good)">${pick("running", "đang chạy")}</div>
        <div class="sub">${sb.uptime != null ? pick(`up ${fmtDuration(sb.uptime)}`, `đã chạy ${fmtDuration(sb.uptime)}`) : pick("proxy engine", "engine proxy")}</div></div>`;
    }
    return `<div class="stat sb warnstate" id="sbCard">
      <div class="label">sing-box</div>
      <div class="val" style="color:var(--crit)">${pick("NOT RUNNING", "KHÔNG CHẠY")}</div>
      <div class="sub">${pick("every proxied Wi-Fi has no Internet", "mọi WiFi proxy đang mất mạng")}</div>
      <button class="btn primary" id="sbRestartBtn">↻ ${pick("Restart sing-box", "Khởi động lại sing-box")}</button></div>`;
  }
  function updateSingboxUI() {
    const card = document.getElementById("sbCard");
    if (card) card.outerHTML = singboxCard();
    renderAnalytics();
    const chip = document.getElementById("sbChip");
    const sb = agent.singbox;
    chip.hidden = !(agent.connected && sb);
    if (chip.hidden) return;
    const healthy = sb.running && !sb.flapping;
    chip.className = "chip sbchip " + (healthy ? "ok" : "down");
    chip.textContent = healthy ? "sing-box ✓"
      : sb.running ? pick("sing-box RESTARTING", "sing-box CHẠY LẠI LIÊN TỤC")
      : pick("sing-box DOWN", "sing-box KHÔNG CHẠY");
    chip.title = healthy
      ? pick("The proxy engine is running — click to re-check", "Engine proxy đang chạy — bấm để kiểm tra lại")
      : pick("sing-box is not staying up — click to restart and repair it", "sing-box không trụ được — bấm để khởi động lại và tự sửa");
  }
  // Patch only the health cells: the rows themselves come from the local SSID
  // list, which a status poll never changes.
  function updateHealthCells() {
    document.querySelectorAll("td[data-health]").forEach(td => {
      const html = healthCell(parseInt(td.getAttribute("data-health"), 10));
      if (td._cells !== html) { td.innerHTML = html; td._cells = html; }
    });
  }
  function formatSingbox(d) {
    const yn = v => v === true ? pick("yes", "có") : v === false ? pick("no", "không") : "?";
    return [
      `${pick("Running", "Đang chạy")}: ${yn(d.running)}${d.pid ? " (pid " + d.pid + ")" : ""}` +
        (d.uptime_s != null ? ` · ${pick("up", "đã chạy")} ${fmtDuration(d.uptime_s)}` : ""),
      d.repaired ? `${pick("Repaired", "Đã sửa")}: ${d.repaired}` : "",
      `${pick("Service enabled", "Service được bật")}: ${yn(d.enabled)}`,
      `${pick("config.json valid", "config.json hợp lệ")}: ${yn(d.config_ok)}`,
      d.hint ? `${pick("Hint", "Gợi ý")}: ${d.hint}` : "",
      d.log ? "\n" + d.log : ""
    ].filter(Boolean).join("\n");
  }
  function restartSingbox() {
    if (!agent.connected) return toast(pick("Not connected to the router.", "Chưa kết nối router."));
    if (!confirm(pick("Restart sing-box now? Open sessions on every proxied Wi-Fi drop for a few seconds.",
                      "Khởi động lại sing-box ngay? Phiên đang mở trên mọi WiFi proxy sẽ gián đoạn vài giây."))) return;
    busy(pick("Restarting sing-box…", "Đang khởi động lại sing-box…"));
    api("restart_singbox", "POST", {}).then(d => {
      if (!d) throw new Error(pick("empty answer", "không có phản hồi"));
      // A fresh start is not flapping: the operator just asked for it.
      agent.singbox = { running: !!d.running, uptime: (typeof d.uptime_s === "number" ? d.uptime_s : null),
                        flapping: false, checked: Date.now() };
      updateSingboxUI();
      showLog("sing-box restart", { ok: !!d.ok, log: formatSingbox(d) || d.error || "" });
      poll();
    }).catch(err => toast(pick("Error: ", "Lỗi: ") + err.message)).finally(busyDone);
  }

  // ---- the router's own troubleshooting assistant -------------------------
  // Everything here is answered by scripts/debug-agent.sh on the router; this
  // side only renders findings and asks before running the fix each one names.
  let debugReport = null;
  const fixLabel = id => ({
    singbox_restart: pick("Restart sing-box", "Khởi động lại sing-box"),
    config_eol: pick("Strip the CR characters", "Bỏ ký tự CR"),
    bridge_nf: pick("Turn bridge-nf off", "Tắt bridge-nf"),
    apply: pick("Apply (reloads Wi-Fi)", "Áp dụng (reload WiFi)"),
    install_agent: pick("Reinstall the agent", "Cài lại agent")
  }[id] || id);
  const fixWarning = id => ({
    apply: pick("Wi-Fi is reloaded: connected devices drop for a few seconds.",
                "WiFi sẽ được reload: thiết bị đang kết nối rớt vài giây."),
    install_agent: pick("uhttpd is restarted; reload the page afterwards.",
                        "uhttpd sẽ khởi động lại; sau đó hãy tải lại trang.")
  }[id] || "");

  function openDebug() {
    if (!agent.connected) return toast(pick("Not connected to the router.", "Chưa kết nối router."));
    showInline("debugBackdrop");
    if (!debugReport) loadDebug();
  }
  function loadDebug() {
    $("debugMeta").textContent = pick("Scanning…", "Đang quét…");
    api("debug").then(d => {
      if (!d || d.ok === false) throw new Error((d && d.error) || "debug failed");
      debugReport = d;
      renderDebug();
    }).catch(err => {
      $("debugMeta").textContent = "";
      $("debugVerdict").className = "conn-status bad";
      $("debugVerdict").textContent = pick("Scan failed: ", "Quét lỗi thất bại: ") + err.message;
    });
  }
  function findingTitle(f) { return pick(f.title_en || f.title, f.title); }
  function findingDetail(f) { return pick(f.detail_en || f.detail, f.detail); }
  function debugRowCells(f) {
    const sev = f.severity === "crit" ? pick("CRITICAL", "NGHIÊM TRỌNG")
              : f.severity === "warn" ? pick("WARNING", "CẢNH BÁO")
              : pick("NOTE", "GHI CHÚ");
    const evidence = f.evidence
      ? `<details><summary>${pick("Router log", "Log của router")}</summary><div class="logbox">${esc(f.evidence)}</div></details>`
      : "";
    const action = f.fix
      ? `<button class="btn ghost" data-fix="${esc(f.fix)}">${esc(fixLabel(f.fix))}</button>`
      : `<span class="sub">${pick("Manual fix", "Tự xử lý")}</span>`;
    return `<td><span class="sev ${esc(f.severity)}">${sev}</span></td>
      <td><b>${esc(findingTitle(f))}</b><div class="sub">${esc(findingDetail(f))}</div>${evidence}</td>
      <td>${action}</td>`;
  }
  function renderDebug() {
    const d = debugReport;
    if (!d) return;
    const when = d.ts ? new Date(d.ts * 1000).toLocaleTimeString() : "";
    $("debugMeta").textContent = pick(
      `${d.summary.crit} critical · ${d.summary.warn} warning · ${d.summary.info} note · scanned at ${when}`,
      `${d.summary.crit} nghiêm trọng · ${d.summary.warn} cảnh báo · ${d.summary.info} ghi chú · quét lúc ${when}`);
    const verdict = pick(d.verdict_en || d.verdict, d.verdict);
    $("debugVerdict").className = "conn-status " + (d.summary.crit ? "bad" : d.summary.warn ? "" : "ok");
    $("debugVerdict").textContent = verdict;
    patchTable($("debugRows"), d.findings || [], f => f.id, debugRowCells, () => "findrow");
  }
  function runDebugFix(fix) {
    let question = pick(`Run this fix now: ${fixLabel(fix)}?`, `Chạy cách sửa này: ${fixLabel(fix)}?`);
    const warning = fixWarning(fix);
    if (warning) question += "\n" + warning;
    if (!confirm(question)) return;
    busy(pick("Running the fix on the router…", "Router đang chạy cách sửa…"));
    api("debug_fix", "POST", { id: fix }).then(d => {
      if (!d || d.ok === false) throw new Error((d && d.error) || "fix failed");
      const hint = pick(d.hint_en || d.hint || "", d.hint || "");
      showLog(pick("Fix: ", "Sửa: ") + fixLabel(fix), { ok: d.ok, log: [d.log, hint].filter(Boolean).join("\n\n") });
      loadDebug();
      poll();
    }).catch(err => toast(pick("Fix failed: ", "Sửa thất bại: ") + err.message)).finally(busyDone);
  }

  // Bootstrap actions the CGI accepts without a Bearer header.
  function postUnauthed(action, body) {
    return fetch(apiUrl(action), {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body)
    }).then(readJson);
  }
  // ---- first-run: the router has no web account yet ------------------------
  function openSetup() {
    $("su_err").textContent = "";
    $("su_pass").value = ""; $("su_pass2").value = "";
    if (!$("su_user").value.trim()) $("su_user").value = "admin";
    showInline("setupBackdrop");
    $("su_user").focus();
  }
  function submitSetup() {
    const user = $("su_user").value.trim();
    const pass = $("su_pass").value;
    const err = m => { $("su_err").textContent = m; };
    if (!/^[A-Za-z0-9._-]{1,32}$/.test(user)) return err(pick("Username must be 1-32 characters of letters, digits, . _ -", "Tên đăng nhập phải 1-32 ký tự chữ, số, . _ -"));
    if (pass.length < 8) return err(pick("The password needs at least 8 characters.", "Mật khẩu phải có ít nhất 8 ký tự."));
    if (pass !== $("su_pass2").value) return err(pick("The two passwords do not match.", "Hai mật khẩu không khớp."));
    postUnauthed("setup_account", { user, pass }).then(d => {
      if (!d || !d.ok || !d.token) throw new Error((d && d.error) || pick("could not create the account", "không tạo được tài khoản"));
      agent.token = d.token; agent.user = d.user || user;
      localStorage.setItem("sbproxy.agent.token", agent.token);
      localStorage.setItem("sbproxy.agent.user", agent.user);
      $("su_pass").value = ""; $("su_pass2").value = "";
      hideInline("setupBackdrop");
      toast(pick("Account created ✓", "Đã tạo tài khoản ✓"));
      finishConnect();
    }).catch(e => err(String(e.message || e)));
  }
  // ---- change the web account password (Bearer + current password) ---------
  function openChangePassword() {
    if (!agent.connected) return toast(pick("Not connected to the router.", "Chưa kết nối router."));
    $("cp_err").textContent = "";
    $("cp_old").value = ""; $("cp_new").value = ""; $("cp_new2").value = "";
    showInline("cpBackdrop");
    $("cp_old").focus();
  }
  function submitChangePassword() {
    const oldPass = $("cp_old").value;
    const newPass = $("cp_new").value;
    const err = m => { $("cp_err").textContent = m; };
    if (newPass.length < 8) return err(pick("The new password needs at least 8 characters.", "Mật khẩu mới phải có ít nhất 8 ký tự."));
    if (newPass !== $("cp_new2").value) return err(pick("The two passwords do not match.", "Hai mật khẩu không khớp."));
    api("change_password", "POST", { old_pass: oldPass, new_pass: newPass }).then(d => {
      if (!d || !d.ok) throw new Error((d && d.error) || pick("could not change the password", "không đổi được mật khẩu"));
      $("cp_old").value = ""; $("cp_new").value = ""; $("cp_new2").value = "";
      hideInline("cpBackdrop");
      toast(pick("Password changed ✓", "Đã đổi mật khẩu ✓"));
    }).catch(e => err(String(e.message || e)));
  }
  // Two ways in: the dedicated sbproxy username/password (the CGI trades it
  // for the token via action=login), or a raw token under "Advanced".
  let loginMethod = "account";
  function setLoginMethod(next) {
    loginMethod = next === "token" ? "token" : "account";
    document.querySelectorAll("[data-login-method]").forEach(button => {
      const active = button.dataset.loginMethod === loginMethod;
      button.classList.toggle("active", active);
      button.setAttribute("aria-selected", active ? "true" : "false");
    });
    const account = document.getElementById("accountLoginPanel");
    const token = document.getElementById("tokenLoginPanel");
    if (account) account.hidden = loginMethod !== "account";
    if (token) token.hidden = loginMethod !== "token";
  }
  function connect() {
    agent.base = document.getElementById("c_base").value.trim().replace(/\/$/, "");
    localStorage.setItem("sbproxy.agent.base", agent.base);
    const user = document.getElementById("c_user").value.trim();
    const pass = document.getElementById("c_pass").value;
    const typedToken = document.getElementById("c_token").value.trim();
    if (loginMethod === "account") {
      setConnStatus(pick("Logging in…", "Đang đăng nhập…"));
      postUnauthed("login", { user, pass }).then(d => {
        if (d && d.setup_required) {
          // No account exists yet: first-run setup instead of a dead end.
          hideInline("connBackdrop");
          openSetup();
          return;
        }
        if (!d || !d.ok || !d.token) throw new Error((d && d.error) || pick("login failed", "đăng nhập lỗi"));
        agent.token = d.token; agent.user = d.user || user;
        localStorage.setItem("sbproxy.agent.token", agent.token);
        localStorage.setItem("sbproxy.agent.user", agent.user);
        document.getElementById("c_pass").value = "";
        finishConnect();
      }).catch(err => setConnStatus(pick("Cannot log in: ", "Không đăng nhập được: ") + err.message, "bad"));
      return;
    }
    if (!typedToken) return setConnStatus(pick("Enter the username and password (or a token under Advanced).",
                                               "Nhập tên đăng nhập và mật khẩu (hoặc token trong mục Nâng cao)."), "bad");
    agent.token = typedToken;
    localStorage.setItem("sbproxy.agent.token", agent.token);
    finishConnect();
  }
  function finishConnect() {
    setConnStatus(pick("Connecting…", "Đang kết nối…"));
    api("status").then(d => {
      if (!d || !d.ok) throw new Error((d && d.error) || pick("bad response", "phản hồi lỗi"));
      agent.connected = true; agent.health = (d.health && d.health.probes) || {};
      agent.version = (d.meta && d.meta.version) || "";
      applyRouterSettings(d.meta);
      updateLiveUI(); renderRows(); startPoll(); syncAuthenticatedWorkspace();
      setConnStatus(pick("Connected ✓", "Đã kết nối ✓"), "ok");
      toast(pick("Connected to the router", "Đã kết nối router"));
      setTimeout(() => hideInline("connBackdrop"), 700);
    }).catch(err => setConnStatus(pick("Cannot connect: ", "Không kết nối được: ") + err.message, "bad"));
  }
  function disconnect() {
    agent.connected = false; agent.singbox = null; lastRouterConf = null;
    stopPoll(); updateLiveUI(); renderRows(); updateSingboxUI();
    if (typeof closeDevices === "function") closeDevices();
    setConnStatus(pick("Disconnected.", "Đã ngắt kết nối."));
  }
  function syncAuthenticatedWorkspace() {
    const page = document.body.dataset.page || "config";
    if (page === "devices") return openDevices();
    if (["settings", "status", "egress", "diagnose", "maintenance"].includes(page)) return openSettings();
    if (page === "analytics") {
      $("dashboardPage").hidden = true; $("settingsPage").hidden = true; $("devicesPage").hidden = true; $("analyticsPage").hidden = false;
      renderAnalytics(); scrollTo({ top: 0, behavior: "smooth" }); return;
    }
    showDashboard();
  }
  // Log out = disconnect AND forget the stored token/username, so the next
  // person at this browser has to know the sbproxy password.
  function logout() {
    localStorage.removeItem("sbproxy.agent.token");
    localStorage.removeItem("sbproxy.agent.user");
    agent.token = ""; agent.user = "";
    document.getElementById("c_token").value = "";
    document.getElementById("c_pass").value = "";
    disconnect();
    setConnStatus(pick("Logged out.", "Đã đăng xuất."));
  }

  function updateConnHint() {
    const el = document.getElementById("mixedNote");
    if (!el) return;
    el.textContent = pick("Connection help ⓘ", "Hướng dẫn kết nối ⓘ");
    el.title = pick(
      "If this UI is served over HTTPS, the browser may block HTTP calls to the router. Open it over HTTP from the management LAN or use the Desktop app.",
      "Nếu mở UI qua HTTPS, trình duyệt có thể chặn gọi HTTP tới router. Hãy mở UI bằng HTTP từ mạng quản trị hoặc dùng bản Desktop.");
  }

  let logRetryAction = null;
  function showLog(title, d, retry) {
    document.getElementById("logTitle").textContent = title + (d && d.ok ? " ✓" : " ✗");
    document.getElementById("logBox").textContent = (d && (d.log || d.error)) || JSON.stringify(d, null, 2);
    logRetryAction = typeof retry === "function" ? retry : null;
    const retryButton = document.getElementById("logRetry");
    if (retryButton) {
      retryButton.hidden = !logRetryAction;
      retryButton.disabled = false;
      retryButton.classList.remove("loading");
      retryButton.textContent = pick("↻ Retry", "↻ Thử lại");
    }
    showInline("logBackdrop");
  }

  let configApplying = false;
  function applyConfigText(conf, showResult) {
    if (!agent.connected) return Promise.reject(new Error(pick("Not connected to the router.", "Chưa kết nối router.")));
    if (configApplying) return Promise.reject(new Error(pick("Another configuration change is being applied.", "Một thay đổi cấu hình khác đang được apply.")));
    configApplying = true;
    busy(pick("Step 1/3 · Checking the configuration…", "Bước 1/3 · Kiểm tra cấu hình…"));
    return api("dryrun_conf", "POST", conf, true).then(dr => {
      if (!dr || !dr.ok) throw new Error(routerReason(dr, pick("dry-run failed", "dry-run lỗi")));
      busy(pick("Step 2/3 · Writing to the router…", "Bước 2/3 · Ghi lên router…"));
      return api("save_conf", "POST", conf, true);
    }).then(sv => {
      if (!sv || !sv.ok) throw new Error(routerReason(sv, pick("writing the config failed", "ghi conf lỗi")));
      busy(pick("Step 3/3 · Applying on the router…", "Bước 3/3 · Router đang apply…"));
      return api("apply", "POST", {});
    }).then(d => {
      if (!d || !d.ok) throw new Error(routerReason(d, pick("apply failed", "apply lỗi")));
      configDirty = false;
      if (showResult) showLog("apply.sh", d);
      poll();
      return d;
    }).catch(err => {
      // A reload/apply can fail after the config was written. Keep the exact
      // failure visible and offer a safe retry of the complete three-step
      // operation instead of leaving the operator with a disappearing toast.
      showLog(pick("Apply failed", "Apply thất bại"),
        { ok: false, error: err.message || String(err) },
        () => applyConfigText(conf, true).catch(() => {}));
      throw err;
    }).finally(() => { configApplying = false; busyDone(); });
  }
  // Resolves to whether the change actually landed on the router: it swallows
  // the error to roll the list back, so a caller with follow-up work of its own
  // cannot tell from the promise alone.
  function autoApplyConfig(previous, successMessage) {
    return applyConfigText(genConf(), false).then(() => { toast(successMessage + " ✓"); return true; }).catch(async err => {
      ssids = previous; configDirty = true; render();
      toast(pick("Change was not applied: ", "Không apply được thay đổi: ") + err.message);
      return false;
    });
  }
  function pushApply() {
    if (!agent.connected) return;
    if (!confirm(pick("Write the current wifi-socks.conf to the router and run apply.sh (reloads Wi-Fi)?",
                      "Ghi wifi-socks.conf hiện tại lên router rồi chạy apply.sh (reload WiFi)?"))) return;
    const conf = genConf();
    // Dry-run before writing, the way the desktop console does: a config the
    // router rejects is caught while the live one is still in place, instead
    // of being written first and blowing up during apply.
    applyConfigText(conf, true).then(() => {
      configDirty = false;
    }).catch(err => toast(pick("Error: ", "Lỗi: ") + err.message));
  }
  // ---- Reset: back to zero SSIDs on the router -------------------------------
  // Kick every online device, empty every pool, write an empty wifi-socks.conf,
  // apply. Destructive, so a default-deny confirm AND a typed word are required.
  const RESET_WORD = "RESET";
  function resetEverything() {
    if (!agent.connected) return;
    // The ROUTER is the source of truth for what gets wiped. This browser's
    // localStorage list may be empty or stale (a fresh browser once showed
    // "Delete ALL 0 SSIDs", skipped every pool, and still wiped the router),
    // so pull wifi-socks.conf first and derive the numbers from it.
    api("get_conf", "GET", null, "resp").then(conf => {
      const rows = String(conf || "").split(/\r?\n/).filter(l => l.trim() && !l.trim().startsWith("#"));
      const idxs = rows.map(l => parseInt(l.split("|")[2], 10)).filter(n => isFinite(n));
      resetWithRouterState(idxs.length, idxs);
    }).catch(err => toast(pick("Cannot read the router configuration: ", "Không đọc được cấu hình từ router: ") + (err.message || err)));
  }
  function resetWithRouterState(count, idxs) {
    if (!confirm(pick(
        `WARNING · RESET EVERYTHING\n\nDelete ALL ${count} SSIDs and their proxy pools, kick every connected device, then apply to the router.\n\nEvery sbproxy-managed Wi-Fi disappears immediately and every device loses its connection. The router keeps a pre-apply backup for a manual rollback. This cannot be undone here.`,
        `CẢNH BÁO · RESET TOÀN BỘ\n\nXoá TẤT CẢ ${count} SSID và pool proxy, đá mọi thiết bị đang kết nối, rồi apply lên router.\n\nMọi Wi-Fi do sbproxy quản lý biến mất ngay; mọi thiết bị mất kết nối. Router giữ một backup pre-apply để rollback bằng tay. Không hoàn tác được ở đây.`))) return;
    const typed = prompt(pick(`Type ${RESET_WORD} to confirm wiping the whole configuration:`,
                              `Gõ ${RESET_WORD} để xác nhận xoá toàn bộ cấu hình:`), "");
    if ((typed || "").trim().toUpperCase() !== RESET_WORD) { toast(pick("Reset cancelled.", "Đã huỷ reset.")); return; }
    const skipped = [];
    let kicked = 0;
    busy(pick("Step 1/4 · Kicking devices…", "Bước 1/4 · Đá thiết bị…"));
    api("clients").then(d => {
      const online = ((d && d.clients) || []).filter(c => c && c.online && c.mac);
      return online.reduce((chain, c) => chain.then(() =>
        api("kick", "POST", { idx: c.idx, mac: c.mac }).then(() => { kicked++; }).catch(e => skipped.push(`${c.mac}: ${e.message || e}`))
      ), Promise.resolve());
    }).then(() => {
      busy(pick("Step 2/4 · Emptying proxy pools…", "Bước 2/4 · Xoá pool proxy…"));
      return idxs.reduce((chain, idx) => chain.then(() =>
        api("save_pool", "POST", { idx, proxies: [] }).catch(e => skipped.push(`pool idx=${idx}: ${e.message || e}`))
      ), Promise.resolve());
    }).then(() => {
      busy(pick("Step 3/4 · Writing the empty configuration…", "Bước 3/4 · Ghi cấu hình rỗng…"));
      const before = ssids; ssids = []; const emptyConf = genConf(); ssids = before;
      return api("dryrun_conf", "POST", emptyConf, true).then(dr => {
        if (!dr || !dr.ok) throw new Error(routerReason(dr, pick("dry-run failed", "dry-run lỗi")));
        return api("save_conf", "POST", emptyConf, true);
      });
    }).then(sv => {
      if (!sv || !sv.ok) throw new Error(routerReason(sv, pick("writing the config failed", "ghi conf lỗi")));
      busy(pick("Step 4/4 · Applying on the router…", "Bước 4/4 · Router đang apply…"));
      return api("apply", "POST", {});
    }).then(d => {
      if (!d || !d.ok) throw new Error(routerReason(d, pick("apply failed", "apply lỗi")));
      ssids = []; configDirty = false; save(); render();
      const summary = pick(`RESET done: kicked ${kicked} devices, removed ${count} SSIDs and pools, apply succeeded.`,
                           `RESET xong: đã đá ${kicked} thiết bị, xoá ${count} SSID và pool, apply thành công.`)
        + (skipped.length ? "\n" + pick(`${skipped.length} minor errors were skipped:`, `Bỏ qua ${skipped.length} lỗi nhỏ:`) + "\n" + skipped.slice(0, 10).join("\n") : "");
      showLog(pick("Reset everything", "Reset toàn bộ"), { ok: true, log: summary + "\n\n" + (d.log || "") });
      poll();
    }).catch(err => toast(pick("Error: ", "Lỗi: ") + (err.message || err))).finally(busyDone);
  }
  function bundleIndices(conf) {
    const out = [];
    String(conf || "").split(/\r?\n/).forEach(line => {
      const p = line.split("|"); const idx = parseInt(p[2], 10);
      if (p.length >= 4 && Number.isInteger(idx) && !out.includes(idx)) out.push(idx);
    });
    return out.sort((a, b) => a - b);
  }
  async function collectRouterBundle() {
    const wifi_socks_conf = await api("get_conf", "GET", null, "resp");
    if (!wifi_socks_conf) throw new Error(pick("The router has no Wi-Fi config yet.", "Router chưa có cấu hình WiFi."));
    const proxy_pools = {}, device_mapping = {};
    await Promise.all(bundleIndices(wifi_socks_conf).map(async idx => {
      const url = apiUrl("get_pool") + "&idx=" + encodeURIComponent(idx);
      const r = await fetch(url, { headers: { "Authorization": `Bearer ${agent.token}` } }).then(readJson);
      if (!r || r.ok === false) throw new Error(routerReason(r, `get_pool idx=${idx} failed`));
      proxy_pools[idx] = Array.isArray(r.proxies) ? r.proxies : [];
      device_mapping[idx] = Array.isArray(r.assignments) ? r.assignments : [];
    }));
    return { format: "sbproxy-bundle-v1", exported_at: new Date().toISOString(), wifi_socks_conf, proxy_pools, device_mapping };
  }
  async function exportBundle() {
    if (!agent.connected) return toast(pick("Connect to the router before exporting.", "Hãy kết nối router trước khi export."));
    try {
      busy(pick("Reading the complete router bundle…", "Đang đọc bundle đầy đủ từ router…"));
      download("sbproxy-bundle.json", JSON.stringify(await collectRouterBundle(), null, 2));
      toast(pick("Complete bundle exported ✓", "Đã export đầy đủ WiFi, pool và device mapping ✓"));
    } catch (err) { toast(pick("Export failed: ", "Export thất bại: ") + (err.message || err)); }
    finally { busyDone(); }
  }
  async function clearAssignmentsFor(idx, assignments) {
    const rows = (assignments || []).map(a => ({ mac: a.mac, slot: "none" }));
    if (!rows.length) return;
    busy(pick("Clearing device mapping…", "Đang xoá device mapping…"));
    let d;
    try { d = await api("assign_proxy", "POST", { idx: Number(idx), assignments: rows }); }
    finally { busyDone(); }
    if (!d || d.ok === false) throw new Error(routerReason(d, `clearing device mapping idx=${idx} failed`));
  }
  async function importBundleObject(bundle) {
    if (!bundle || bundle.format !== "sbproxy-bundle-v1" || typeof bundle.wifi_socks_conf !== "string" || !bundle.proxy_pools || !bundle.device_mapping) {
      throw new Error(pick("Invalid sbproxy bundle.", "Bundle sbproxy không hợp lệ."));
    }
    const current = await collectRouterBundle();
    await applyConfigText(bundle.wifi_socks_conf, true);
    for (const idx of Object.keys(current.device_mapping)) await clearAssignmentsFor(idx, current.device_mapping[idx]);
    const targetIdx = Object.keys(bundle.proxy_pools).map(Number).filter(Number.isInteger).sort((a, b) => a - b);
    for (const idx of targetIdx) {
      const d = await api("save_pool", "POST", { idx, proxies: Array.isArray(bundle.proxy_pools[idx]) ? bundle.proxy_pools[idx] : [] });
      if (!d || d.ok === false) throw new Error(routerReason(d, `saving pool idx=${idx} failed`));
      const assignments = Array.isArray(bundle.device_mapping[idx]) ? bundle.device_mapping[idx] : [];
      if (assignments.length) {
        busy(pick("Restoring device mapping…", "Đang khôi phục device mapping…"));
        let a;
        try { a = await api("assign_proxy", "POST", { idx, assignments: assignments.map(x => ({ mac: x.mac, slot: Number(x.slot) })) }); }
        finally { busyDone(); }
        if (!a || a.ok === false) throw new Error(routerReason(a, `restoring device mapping idx=${idx} failed`));
      }
    }
    parseConfInto(bundle.wifi_socks_conf); render(); poll();
  }
  function importBundle() { if (agent.connected) { $("bundleFile").value = ""; $("bundleFile").click(); } }
  function handleBundleFile() {
    const file = $("bundleFile").files[0]; if (!file) return;
    file.text().then(text => {
      const bundle = JSON.parse(text);
      if (!confirm(pick("Import the complete bundle? This replaces Wi-Fi config, proxy pools and device mappings on the router.", "Import bundle đầy đủ? Thao tác này thay WiFi, proxy pool và device mapping trên router."))) return;
      busy(pick("Importing the complete bundle…", "Đang import bundle đầy đủ…"));
      return importBundleObject(bundle).then(() => toast(pick("Complete bundle imported ✓", "Đã import đầy đủ bundle ✓")));
    }).catch(err => toast(pick("Import failed: ", "Import thất bại: ") + (err.message || err))).finally(busyDone);
  }
  function pullFromRouter() {
    collectRouterBundle().then(bundle => {
      lastRouterConf = bundle.wifi_socks_conf; parseConfInto(bundle.wifi_socks_conf); render();
      toast(pick("Pulled Wi-Fi, proxy pools and device mappings from the router ✓", "Đã pull WiFi, proxy pool và device mapping từ router ✓"));
    }).catch(err => toast(pick("Pull failed: ", "Pull thất bại: ") + err.message));
  }
  function zapSock(s) {
    if (!agent.connected) return;
    if (!confirm(pick(`Change the SOCKS endpoint of "${s.name}" now? Wi-Fi is not reloaded, but open sessions may drop.\n→ ${s.host}:${s.port}`,
                      `Đổi SOCKS của "${s.name}" ngay? WiFi không reload nhưng phiên đang mở có thể gián đoạn.\n→ ${s.host}:${s.port}`))) return;
    routerWrite(pick("Changing the SOCKS endpoint", "Đổi sock"),
      () => api("set_sock", "POST", { idx: s.idx, host: s.host, port: s.port, user: s.user || "", pass: s.pass || "", type: s.proxy_type || "socks5" }),
      d => { showLog("set-sock.sh idx=" + s.idx, d); poll(); }).catch(() => {});
  }

  // ---- diagnostics: the same tools the desktop app has ----
  // Walk the data path of one SSID on the router and name the broken link.
  function diagnoseSsid(idx) {
    if (!agent.connected) return;
    toast(pick("Diagnosing… (this can take up to a minute)", "Đang chẩn đoán… (có thể mất tới một phút)"));
    api("diagnose_ssid&idx=" + idx).then(d => {
      if (!d || d.ok === false) throw new Error((d && d.error) || pick("diagnose failed", "chẩn đoán lỗi"));
      const lines = [];
      if (d.verdict) lines.push(pick("Verdict: ", "Kết luận: ") + d.verdict);
      if (d.report) lines.push("", d.report);
      if (d.singbox_log) lines.push("", "sing-box log:", d.singbox_log);
      showLog(pick("Diagnose Wi-Fi", "Chẩn đoán WiFi") + " idx=" + idx,
              { ok: true, log: lines.join("\n") || JSON.stringify(d, null, 2) });
    }).catch(err => toast(pick("Error: ", "Lỗi: ") + err.message));
  }
  // Probe the proxy currently typed in the edit form, from the router, and
  // show why it fails (curl exit, handshake tail) instead of a bare "fail".
  function probeFromForm() {
    if (!agent.connected) return toast(pick("Not connected to the router.", "Chưa kết nối router."));
    const host = $("f_host").value.trim();
    const port = parseInt($("f_port").value, 10);
    if (!host || !isFinite(port)) { $("f_err").textContent = pick("Enter the proxy host and port first.", "Nhập host và cổng proxy trước."); return; }
    toast(pick("Testing the proxy from the router…", "Đang test proxy từ router…"));
    api("probe_proxy", "POST", {
      host, port, user: $("f_user").value.trim(), pass: $("f_pass").value, type: $("f_proxy_type").value
    }).then(d => {
      if (!d || d.ok === false) throw new Error((d && d.error) || pick("probe failed", "probe lỗi"));
      const lines = [host + ":" + port + " (" + $("f_proxy_type").value + ")"];
      lines.push(pick("State: ", "Trạng thái: ") + (d.state || "?") + (d.latency_ms ? " · " + d.latency_ms + "ms" : ""));
      if (d.verdict) lines.push(pick("Verdict: ", "Kết luận: ") + d.verdict);
      if (d.error) lines.push(pick("Reason: ", "Lý do: ") + d.error);
      if (d.hint) lines.push(pick("Hint: ", "Gợi ý: ") + d.hint);
      if (d.public_ip) lines.push(pick("Public IP through the proxy: ", "IP công khai qua proxy: ") + d.public_ip);
      if (d.transcript) lines.push("", d.transcript);
      showLog(pick("Proxy test", "Test proxy"), { ok: d.state === "ok" || d.state === "slow", log: lines.join("\n") });
    }).catch(err => toast(pick("Error: ", "Lỗi: ") + err.message));
  }

  // ---- self-update ----
  function openUpdate() {
    if (!agent.connected) return;
    document.getElementById("upCurVer").textContent =
      agent.version ? "v" + agent.version : pick("unknown (older agent)", "không rõ (agent cũ)");
    document.getElementById("upFile").value = "";
    document.getElementById("upForce").checked = false;
    showInline("upBackdrop");
  }
  function doUpdate() {
    const f = document.getElementById("upFile").files[0];
    if (!f) return toast(pick("No package file selected.", "Chưa chọn file package."));
    if (!/\.(tar\.gz|tgz|zip)$/i.test(f.name)) return toast(pick("Only .tar.gz / .tgz / .zip is accepted", "Chỉ nhận .tar.gz / .tgz / .zip"));
    const force = document.getElementById("upForce").checked;
    if (!confirm(pick(`Update sbproxy on the router with "${f.name}"${force ? " (FORCE — downgrade allowed)" : ""}?\nThe router backs up first; Wi-Fi is not reloaded.`,
                      `Cập nhật code sbproxy trên router bằng "${f.name}"${force ? " (FORCE — cho phép hạ version)" : ""}?\nRouter tự backup trước; WiFi không reload.`))) return;
    busy(pick("Uploading and updating…", "Đang upload & cập nhật…"));
    fetch(apiUrl("update") + (force ? "&force=1" : ""), {
      method: "POST",
      headers: { "Authorization": `Bearer ${agent.token}`, "Content-Type": "application/octet-stream" },
      body: f
    }).then(readJson).then(d => {
      hideInline("upBackdrop");
      showLog("self-update.sh" + (d && d.ok ? ` (${d.from} → ${d.to})` : ""), d);
      // uhttpd may reload; re-poll shortly after to pick up the new version.
      setTimeout(poll, 1500);
    }).catch(err => toast(pick("Update failed: ", "Lỗi cập nhật: ") + err.message)).finally(busyDone);
  }

  function recordHistory() {
    Object.keys(agent.health).forEach(idx => {
      const p = agent.health[idx];
      const arr = healthHistory[idx] || (healthHistory[idx] = []);
      arr.push({ ms: p.latency_ms || 0, state: p.state });
      if (arr.length > HIST_MAX) arr.shift();
    });
  }

  // ---- backup / rollback ----
  // ---- Egress: which interface carries the router's Internet traffic ----
  let gwChoice = "";
  function openGateway() {
    if (!agent.connected) return;
    showInline("gwBackdrop");
    loadGateway();
  }
  function loadGateway() {
    const box = $("gwList"), state = $("gwState");
    box.innerHTML = `<div class="sub">${pick("Loading…", "Đang tải…")}</div>`;
    state.textContent = "…";
    api("gateway").then(d => {
      if (!d || d.ok === false) { state.textContent = pick("Cannot read the gateway state.", "Không đọc được trạng thái đường ra."); box.innerHTML = ""; return; }
      const stateTxt = { ok: pick("OK", "Hoạt động"), degraded: pick("degraded", "suy giảm"), down: pick("down", "mất kết nối") }[d.state] || d.state;
      const problem = d.egress_problem === "proxied-bridge" ? " · " + pick("EGRESS THROUGH A PROXIED SSID", "ĐI RA QUA SSID PROXY")
        : d.egress_problem === "not-expected" ? " · " + pick("not the pinned interface", "không phải interface đã ghim") : "";
      state.textContent = `${pick("State", "Trạng thái")}: ${stateTxt} · ${pick("current", "hiện tại")}: ${d.interface || "?"} (${d.device || "?"})`
        + (d.expected_interface ? ` · ${pick("pinned", "đã ghim")}: ${d.expected_interface}` : "") + problem;
      const list = (d.interfaces || []).filter(i => !i.proxied);
      if (!list.length) { box.innerHTML = `<div class="sub">${pick("No interfaces reported.", "Router không báo interface nào.")}</div>`; return; }
      if (!list.some(i => i.name === gwChoice)) gwChoice = (list.find(i => i.current) || {}).name || "";
      box.innerHTML = list.map(i => {
        const flags = [];
        if (i.current) flags.push(pick("in use", "đang dùng"));
        if (!i.up) flags.push(pick("down", "không hoạt động"));
        if (i.default_route) flags.push(pick("has default route", "có default route"));
        const can = i.up && i.default_route;
        return `<label class="rbitem" style="cursor:${can ? "pointer" : "not-allowed"};opacity:${can ? 1 : .55}">
          <div class="nm"><input type="radio" name="gwIface" value="${esc(i.name)}" ${i.name === gwChoice ? "checked" : ""} ${can ? "" : "disabled"}>
            ${esc(i.name)} <small>(${esc(i.device || "?")}${i.ipv4 ? " · " + esc(i.ipv4) : ""})</small></div>
          <small>${esc(flags.join(" · "))}</small></label>`;
      }).join("");
    }).catch(e => { state.textContent = String(e); box.innerHTML = ""; });
  }
  // Pinning is not switching: set_gateway only records which uplink the health
  // check should expect, so a router that drifts onto another one is reported
  // as wrong. An empty name means "accept whatever the default route uses".
  function pinGateway() {
    const picked = document.querySelector('input[name="gwIface"]:checked');
    const name = picked ? picked.value : "";
    const label = name || pick("automatic", "tự động");
    if (!confirm(pick(`Expect ${label} as the uplink from now on? Nothing is switched; only the health check's expectation changes.`,
                      `Từ giờ coi ${label} là đường ra mong đợi? Không đổi gì trên router, chỉ đổi kỳ vọng của phần kiểm tra.`))) return;
    routerWrite(pick(`Uplink expectation: ${label}`, `Đường ra mong đợi: ${label}`),
      () => api("set_gateway", "POST", { interface: name }), loadGateway).catch(() => {});
  }
  function unpinGateway() {
    if (!confirm(pick("Stop expecting a specific uplink (automatic)?", "Bỏ ghim đường ra (để tự động)?"))) return;
    routerWrite(pick("Uplink expectation: automatic", "Đường ra mong đợi: tự động"),
      () => api("set_gateway", "POST", { interface: "" }), loadGateway).catch(() => {});
  }
  function switchGateway() {
    const picked = document.querySelector('input[name="gwIface"]:checked');
    if (!picked) { toast(pick("Pick an interface first.", "Hãy chọn một interface trước.")); return; }
    const name = picked.value;
    if (!confirm(pick(`Switch the router's Internet egress to ${name}? The router network reloads; Wi-Fi and proxies are unchanged.`,
                      `Đổi đường ra Internet của router sang ${name}? Network trên router sẽ reload; Wi-Fi và proxy không đổi.`))) return;
    gwChoice = name;
    $("gwSwitch").disabled = true;
    routerWrite(pick(`Egress switched to ${name}`, `Đã đổi đường ra sang ${name}`),
      () => api("switch_gateway", "POST", { interface: name }), loadGateway)
      .catch(() => loadGateway())
      .finally(() => { $("gwSwitch").disabled = false; });
  }

  function openRollback() {
    showInline("rbBackdrop");
    loadBackups();
  }
  function loadBackups() {
    const box = document.getElementById("rbList");
    box.innerHTML = `<div class="sub">${pick("Loading list…", "Đang tải danh sách…")}</div>`;
    api("backups").then(d => {
      const list = (d && d.backups) || [];
      if (!list.length) { box.innerHTML = `<div class="sub">${pick("No backups available.", "Chưa có backup nào.")}</div>`; return; }
      box.innerHTML = list.map((name, i) => {
        const parts = name.split("-");
        const label = parts.slice(2).join("-") || "manual";
        return `<div class="rbitem">
          <div class="nm">${esc(name)}<small>${i === 0 ? pick("latest · ", "mới nhất · ") : ""}${esc(label)}</small></div>
          <div class="rowbtns">
            <button class="iconbtn" data-dl="${esc(name)}" title="${pick("Download the backup to your computer (safe against reflash/brick)", "Tải file backup về máy tính (an toàn khi reflash/brick)")}">⭳ ${pick("Download", "Về máy")}</button>
            <button class="btn ghost danger" data-restore="${esc(name)}">↩ ${pick("Restore", "Khôi phục")}</button>
          </div>
        </div>`;
      }).join("");
    }).catch(err => { box.innerHTML = `<div class="conn-status bad">${pick("Error: ", "Lỗi: ")}${esc(err.message)}</div>`; });
  }
  function backupNow() {
    // The label ends up in the snapshot's directory name, so it is restricted
    // to the characters the router-side script accepts.
    const answer = prompt(pick("Backup label (letters, digits, . _ - only):", "Nhãn backup (chỉ chữ, số, . _ -):"), "web");
    if (answer == null) return;
    const label = answer.trim() || "web";
    if (!/^[A-Za-z0-9._-]+$/.test(label)) return toast(pick("Invalid label.", "Nhãn không hợp lệ."));
    toast(pick("Creating a backup…", "Đang tạo backup…"));
    api("backup", "POST", { label }).then(d => { showLog("backup.sh", d); loadBackups(); })
      .catch(err => toast(pick("Error: ", "Lỗi: ") + err.message));
  }
  function downloadBackup(name) {
    toast(pick("Downloading the backup…", "Đang tải backup về máy…"));
    fetch(apiUrl("download_backup") + "&name=" + encodeURIComponent(name), { headers: { "Authorization": `Bearer ${agent.token}` } })
      .then(r => { if (!r.ok) throw new Error("HTTP " + r.status); return r.blob(); })
      .then(b => {
        const a = document.createElement("a");
        a.href = URL.createObjectURL(b); a.download = "sbproxy-" + name + ".tar.gz"; a.click();
        setTimeout(() => URL.revokeObjectURL(a.href), 1500);
        toast(pick("Backup downloaded ✓", "Đã tải backup về máy ✓"));
      }).catch(err => toast(pick("Download failed: ", "Lỗi tải: ") + err.message));
  }

  function openDailyLogs() {
    if (!agent.connected) return toast(pick("Not connected to the router.", "Chưa kết nối router."));
    showInline("dailyLogBackdrop");
    loadDailyLogs();
  }
  function loadDailyLogs(requestedDate) {
    const date = requestedDate || $("dailyLogDate").value || "";
    $("dailyLogBox").textContent = pick("Loading…", "Đang tải…");
    fetch(apiUrl("logs") + (date ? "&date=" + encodeURIComponent(date) : ""), {
      headers: { "Authorization": `Bearer ${agent.token}` }
    }).then(readJson).then(d => {
      if (!d || d.ok === false) throw new Error((d && d.error) || "logs failed");
      const select = $("dailyLogDate");
      const dates = d.dates || [];
      if (!dates.includes(d.date)) dates.unshift(d.date);
      select.innerHTML = dates.map(x => `<option value="${esc(x)}">${esc(x)}</option>`).join("");
      select.value = d.date;
      $("dailyLogMeta").textContent = pick(
        `${dates.length} day(s) available · kept ${d.retention_days || 7} days`,
        `Có ${dates.length} ngày · lưu ${d.retention_days || 7} ngày`
      );
      $("dailyLogBox").textContent = d.log || pick("No log entries for this day.", "Ngày này chưa có log.");
    }).catch(err => {
      $("dailyLogBox").textContent = pick("Cannot load logs: ", "Không tải được log: ") + err.message;
    });
  }
  function downloadDailyLogs() {
    const date = $("dailyLogDate").value || new Date().toISOString().slice(0, 10);
    fetch(apiUrl("download_logs") + "&date=" + encodeURIComponent(date), {
      headers: { "Authorization": `Bearer ${agent.token}` }
    }).then(r => { if (!r.ok) throw new Error("HTTP " + r.status); return r.blob(); })
      .then(blob => {
        const a = document.createElement("a");
        a.href = URL.createObjectURL(blob); a.download = "sbproxy-debug-" + date + ".txt"; a.click();
        setTimeout(() => URL.revokeObjectURL(a.href), 1500);
        toast(pick("Debug report downloaded ✓", "Đã tải gói debug ✓"));
      }).catch(err => toast(pick("Download failed: ", "Lỗi tải: ") + err.message));
  }
  function restore(name) {
    if (!confirm(pick(`Restore the configuration from backup:\n${name}\n\nThis OVERWRITES the current config and reloads services. Continue?`,
                      `Khôi phục cấu hình từ backup:\n${name}\n\nSẽ GHI ĐÈ config hiện tại và reload dịch vụ. Tiếp tục?`))) return;
    toast(pick("Rolling back…", "Đang rollback…"));
    api("rollback", "POST", { name }).then(d => {
      showLog("rollback.sh " + name, d);
      hideInline("rbBackdrop");
      poll();
    }).catch(err => toast(pick("Error: ", "Lỗi: ") + err.message));
  }

  // ---- devices / clients ----
  let devTimer = null;
  function fmtBytes(n) {
    n = Number(n) || 0;
    const u = ["B", "KB", "MB", "GB", "TB"];
    let i = 0; while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return (i === 0 ? n : n.toFixed(1)) + " " + u[i];
  }
  function fmtDuration(s) {
    s = Math.max(0, Math.floor(Number(s) || 0));
    const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600),
          m = Math.floor((s % 3600) / 60), sec = s % 60;
    if (d) return `${d}n ${h}g`;
    if (h) return `${h}g ${m}p`;
    if (m) return `${m}p ${sec}s`;
    return `${sec}s`;
  }
  function ssidNameByIdx(idx) {
    const s = ssids.find(x => x.idx === idx);
    return s ? s.name : "w" + idx;
  }
  let activePoolIdx = 0;
  let activePool = [];
  const poolSelected = new Set();
  const poolStatus = {};
  let activePoolHealth = {};
  // The pool list is plain text, so its words go through pick() like every
  // other runtime string, and one formatter keeps the four places that draw a
  // slot from drifting apart.
  const poolWord = {
    untested: () => pick("not tested", "chưa test"),
    testing: () => pick("testing", "đang test"),
    more: () => pick("Show more", "Xem thêm"),
    less: () => pick("Show less", "Thu gọn")
  };
  const poolLine = (p, i, status) =>
    `${i}: [${String(p.type || "socks5").toUpperCase()}] ${p.host}:${p.port}` +
    `${p.user ? " · auth" : ""}${p.label ? " · " + p.label : ""} · ${status}`;
  const poolStatusKey = (p, i) => p.slot == null ? i : p.slot;
  function poolHealthState(i) {
    const h = activePoolHealth[String(i)] || activePoolHealth[i];
    return h && (h.state === "ok" || h.state === "slow" || h.state === "fail") ? h.state : "";
  }
  function poolHealthLabel(i) {
    const h = activePoolHealth[String(i)] || activePoolHealth[i];
    if (h && h.udp_state === "fail") return "UDP FAIL ⚠";
    return poolHealthState(i) === "fail" ? "FAIL ⚠" : poolHealthState(i) === "slow" ? "SLOW ⚠" :
      poolHealthState(i) === "ok" ? "OK" : poolWord.untested();
  }
  const activePoolNeedsUdp = () => {
    const current = ssids.find(s => s.idx === activePoolIdx);
    return !!current && Number(current.webrtc) === 2;
  };
  let poolExpanded = false;
  // Which slot the add form is editing, or null when it is adding. Editing
  // rewrites the slot in place: slot numbers are positions in
  // proxy-pools.conf and devices are pinned by position, so a pinned device
  // keeps its slot and simply starts using the new endpoint.
  let poolEditSlot = null;
  let poolLoadSeq = 0;
  let poolLoadController = null;
  function updatePoolSelection() {
    const visible = (poolExpanded ? activePool : activePool.slice(0, 2)).map((_p, i) => i);
    const selectedVisible = visible.filter(i => poolSelected.has(i)).length;
    $("poolSelectAll").checked = visible.length > 0 && selectedVisible === visible.length;
    $("poolSelectAll").indeterminate = selectedVisible > 0 && selectedVisible < visible.length;
    $("poolBulkRun").disabled = poolSelected.size === 0 || !$("poolBulkAction").value;
    $("poolSelectedCount").textContent = pick(`${poolSelected.size} selected`, `${poolSelected.size} đã chọn`);
  }
  function renderPoolList() {
    const shown = poolExpanded ? activePool : activePool.slice(0, 2);
    $("poolRows").innerHTML = shown.length
      ? shown.map((p, i) => `<div class="pool-select-row${poolSelected.has(i) ? " selected" : ""}" data-pool-row="${i}">
          <input type="checkbox" data-pool-select="${i}" ${poolSelected.has(i) ? "checked" : ""} aria-label="${pick("Select proxy slot", "Chọn proxy slot")} ${i}">
          <span class="mono">${esc(poolLine(p, i, poolStatus[poolStatusKey(p, i)] || poolHealthLabel(i)))}</span>
        </div>`).join("")
      : `<div class="sub" style="padding:10px">${pick("Pool is empty.", "Pool đang trống.")}</div>`;
    $("poolMore").hidden = activePool.length <= 2;
    $("poolMore").textContent = poolExpanded ? poolWord.less() : poolWord.more();
    updatePoolSelection();
  }
  function openPool(idx) {
    if (!agent.connected) return toast(pick("Not connected to the router.", "Chưa kết nối router."));
    activePoolIdx = idx;
    poolExpanded = false;
    poolSelected.clear();
    $("poolTitle").textContent = ssidNameByIdx(idx) + " · idx " + idx;
    // Slot numbers belong to one pool, so an edit left open on the previous
    // SSID would aim at a slot of this one.
    cancelPoolEdit();
    showInline("poolBackdrop");
    loadPool();
  }
  // Render only two pool entries until the operator asks for the full list.
  function loadPool(attempt = 0) {
    const idx = activePoolIdx;
    const seq = ++poolLoadSeq;
    if (poolLoadController) poolLoadController.abort();
    const controller = new AbortController();
    poolLoadController = controller;
    const timer = setTimeout(() => controller.abort(), 8000);
    $("poolRows").textContent = attempt
      ? pick("Connection was slow. Retrying…", "Kết nối chậm. Đang thử lại…")
      : pick("Loading…", "Đang tải…");
    fetch(apiUrl("get_pool") + "&idx=" + encodeURIComponent(idx), {
      headers: { "Authorization": `Bearer ${agent.token}` }, signal: controller.signal
    }).then(readJson).then(d => {
        if (seq !== poolLoadSeq || idx !== activePoolIdx) return;
        if (!d || d.ok === false) throw new Error((d && d.error) || "pool error");
        activePool = d.proxies || [];
        activePoolHealth = d.pool_health || {};
        if (!activePool.length) {
          const current = ssids.find(s => s.idx === activePoolIdx);
          if (current && current.host && current.port) activePool = [{
            slot: 0, type: current.proxy_type || "socks5", host: current.host, port: Number(current.port),
            user: current.user || "", pass: current.pass || "", label: "current"
          }];
        }
        Object.keys(poolStatus).forEach(k => delete poolStatus[k]);
        poolSelected.clear();
        renderPoolList();
      }).catch(e => {
        if (seq !== poolLoadSeq || idx !== activePoolIdx) return;
        if (attempt < 1 && featureOpen("poolBackdrop")) {
          $("poolRows").textContent = pick("Connection was slow. Retrying…", "Kết nối chậm. Đang thử lại…");
          setTimeout(() => {
            if (idx === activePoolIdx && featureOpen("poolBackdrop")) loadPool(1);
          }, 300);
          return;
        }
        $("poolRows").textContent = pick("Cannot load the pool. Tap Retry.", "Không tải được pool. Bấm Thử lại.");
      }).finally(() => {
        clearTimeout(timer);
        if (poolLoadController === controller) poolLoadController = null;
      });
  }
  function testPoolSlots(slots) {
    const rows = slots == null ? activePool.map((p, i) => ({ p, i }))
      : [...slots].sort((a, b) => a - b).map(i => ({ p: activePool[i], i })).filter(x => x.p);
    if (!rows.length) return toast(pick("Select at least one proxy.", "Chọn ít nhất một proxy."));
    rows.forEach(({ p, i }) => { poolStatus[poolStatusKey(p, i)] = poolWord.testing(); });
    renderPoolList();
    const checkUdp = activePoolNeedsUdp();
    Promise.all(rows.map(({ p, i }) =>
      api("probe_proxy", "POST", { host: p.host, port: p.port, user: p.user || "", pass: p.pass || "", type: p.type || "socks5", check_udp: checkUdp })
        .then(d => { const state = d && (d.state === "ok" || d.state === "slow") ? d.state : "fail"; const udpState = d && d.udp_state; poolStatus[poolStatusKey(p, i)] = udpState === "fail" ? "UDP FAIL ⚠" : state === "ok" ? "OK" : state === "slow" ? "SLOW ⚠" : "FAIL ⚠"; activePoolHealth[String(i)] = { state, udp_state: udpState }; })
        .catch(() => { poolStatus[poolStatusKey(p, i)] = "FAIL ⚠"; activePoolHealth[String(i)] = { state: "fail" }; })
    )).then(() => {
      renderPoolList();
    });
  }
  function testAllPool() { testPoolSlots(null); }
  const poolProbeIdentity = p => [String(p.type || "socks5").toLowerCase(), String(p.host || "").toLowerCase(),
    Number(p.port), p.user || "", p.pass || ""].join("|");
  function probeNewPoolRows(rows) {
    const known = new Set(activePool.map(poolProbeIdentity));
    const targets = rows.map((p, i) => ({ p, i })).filter(x => !known.has(poolProbeIdentity(x.p)));
    if (!targets.length) return Promise.resolve();
    let cursor = 0;
    const failed = [];
    const checkUdp = activePoolNeedsUdp();
    const worker = () => {
      const item = targets[cursor++];
      if (!item) return Promise.resolve();
      const p = item.p;
      return api("probe_proxy", "POST", { host: p.host, port: p.port, user: p.user || "", pass: p.pass || "", type: p.type || "socks5", check_udp: checkUdp })
        .then(d => {
          const state = d && (d.state === "ok" || d.state === "slow") ? d.state : "fail";
          if (state === "fail") failed.push(`${p.host}:${p.port}`);
          poolStatus[poolStatusKey(p, item.i)] = d && d.udp_state === "fail" ? "UDP FAIL ⚠" : state === "ok" ? "OK" : state === "slow" ? "SLOW ⚠" : "FAIL ⚠";
        }).catch(() => {
          failed.push(`${p.host}:${p.port}`);
          poolStatus[poolStatusKey(p, item.i)] = "FAIL ⚠";
        }).then(worker);
    };
    const workers = Array.from({ length: Math.min(4, targets.length) }, worker);
    return Promise.all(workers).then(() => {
      if (failed.length) throw new Error(pick(
        `Proxy check failed; not saved: ${failed.join(", ")}`,
        `Kiểm tra proxy lỗi, chưa lưu: ${failed.join(", ")}`));
    });
  }
  function savePoolRows(rows) {
    // pool.sh rebuilds sing-box and nftables and restarts them, so this is a
    // router-side apply in every sense except that Wi-Fi is not reloaded.
    busy(pick("Checking new proxies…", "Đang kiểm tra proxy mới…"));
    return probeNewPoolRows(rows).then(() => {
      busy(pick("Saving the pool on the router…", "Đang lưu pool lên router…"));
      return api("save_pool", "POST", { idx: activePoolIdx, proxies: rows });
    }).then(d => {
      // The script's own output is the only place that says WHY: reading just
      // .error left the operator with "save_pool failed" and nothing to act on.
      if (!d || d.ok === false) throw new Error(routerReason(d, pick("saving the pool failed", "lưu pool thất bại")));
      activePool = rows;
      poolCounts[activePoolIdx] = rows.length;
      poolExpanded = false;
      poolSelected.clear();
      Object.keys(poolStatus).forEach(k => delete poolStatus[k]);
      renderPoolList();
      toast(pick("Pool saved and applied ✓", "Đã lưu và áp pool ✓"));
      poll();
    }).finally(busyDone);
  }
  function closePool() {
    poolLoadSeq++;
    if (poolLoadController) poolLoadController.abort();
    poolLoadController = null;
    hideInline("poolBackdrop");
  }
  // Providers hand out proxy lists in a handful of shapes; the desktop console
  // accepts all of them, so this one does too. Returns null for a line that
  // does not fit the chosen format, so the caller can report it by number.
  function parseProxyLine(line, format, defaultType) {
    const cleaned = line.replace(/^\s*(socks5h?|https?):\/\//i, (m) => m).trim();
    const url = cleaned.match(/^(socks5h?|https?):\/\/(?:([^:@\/]*):([^@\/]*)@)?([^:\/@]+):(\d+)\/?$/i);
    const build = (host, port, user, pass, type) => {
      const p = Number(port);
      if (!host || !Number.isInteger(p) || p < 1 || p > 65535) return null;
      return { type: type || defaultType || $("poolType").value || "socks5", host: host.trim(), port: p,
               user: (user || "").trim(), pass: pass || "" };
    };
    const bySep = (sep) => {
      const parts = cleaned.split(sep);
      if (parts.length < 2) return null;
      // user and password may themselves contain the separator only for ':'
      // in the host:port:user:pass shape, where everything after the third
      // field belongs to the password.
      const host = parts[0], port = parts[1];
      const user = parts[2] || "";
      const pass = parts.length > 3 ? parts.slice(3).join(sep) : "";
      return build(host, port, user, pass);
    };
    switch (format) {
      case "url": return url ? build(url[4], url[5], url[2], url[3], /^http/i.test(url[1]) ? "http" : "socks5") : null;
      case "uphp": {
        const m = cleaned.match(/^([^:@]*):([^@]*)@([^:]+):(\d+)$/);
        return m ? build(m[3], m[4], m[1], m[2]) : null;
      }
      case "hp": {
        const m = cleaned.match(/^([^:]+):(\d+)$/);
        return m ? build(m[1], m[2], "", "") : null;
      }
      case "csv": return bySep(",");
      case "semi": return bySep(";");
      case "hpup": return bySep(":");
      default: {  // auto: try each shape, most specific first
        if (url) return parseProxyLine(line, "url", defaultType);
        if (/^[^:@]*:[^@]*@[^:]+:\d+$/.test(cleaned)) return parseProxyLine(line, "uphp", defaultType);
        if (cleaned.includes(",")) return parseProxyLine(line, "csv", defaultType);
        if (cleaned.includes(";")) return parseProxyLine(line, "semi", defaultType);
        return parseProxyLine(line, "hpup", defaultType);
      }
    }
  }
  function setPoolAddState(loading, message) {
    const button = $("poolSave");
    const status = $("poolAddStatus");
    if (!button) return;
    const editing = poolEditSlot !== null;
    button.disabled = loading;
    button.classList.toggle("loading", loading);
    button.textContent = loading
      ? (editing ? pick("Saving…", "Đang lưu…") : pick("Adding…", "Đang thêm…"))
      : (editing ? pick(`Save slot ${poolEditSlot}`, `Lưu slot ${poolEditSlot}`)
                 : pick("Add to pool", "Thêm vào pool"));
    const cancel = $("poolEditCancel");
    if (cancel) { cancel.hidden = !editing; cancel.disabled = loading; }
    if (status) status.textContent = message || "";
  }

  // Replace one proxy without deleting it first. Deleting a slot renumbers the
  // ones after it and repoints every device pinned to them, so "change this
  // proxy" had to be spelled delete-then-add, which was neither.
  function beginPoolEdit(slots) {
    const list = [...new Set(slots || [])].map(Number);
    if (list.length !== 1) {
      return toast(pick("Select exactly one proxy to edit.", "Chọn đúng một proxy để sửa."));
    }
    const slot = list[0];
    if (!Number.isInteger(slot) || slot < 0 || slot >= activePool.length) {
      return toast(pick("Invalid slot number.", "Số slot không hợp lệ."));
    }
    const row = activePool[slot];
    poolEditSlot = slot;
    // host:port:user:pass round-trips through parseProxyLine, so the operator
    // can retype any part of it in the format they already paste.
    $("poolFormat").value = "hpup";
    $("poolType").value = (row.type === "http") ? "http" : "socks5";
    $("poolInput").value = `${row.host}:${row.port}:${row.user || ""}:${row.pass || ""}`;
    setPoolAddState(false, pick(
      `Editing slot ${slot}. Devices pinned to it keep their pin and move to the new proxy.`,
      `Đang sửa slot ${slot}. Thiết bị đang ghim vào slot này giữ nguyên ghim và chuyển sang proxy mới.`));
    $("poolInput").focus();
  }
  function cancelPoolEdit() {
    poolEditSlot = null;
    $("poolInput").value = "";
    setPoolAddState(false, "");
  }
  function addPoolLines() {
    const lines = $("poolInput").value.split(/\r?\n/).map(x => x.trim()).filter(Boolean);
    if (!lines.length) return toast(pick("Paste at least one proxy.", "Hãy dán ít nhất một proxy."));
    const format = $("poolFormat").value;
    const added = [], dropped = [];
    lines.forEach((line, i) => {
      const row = parseProxyLine(line, format);
      if (row) added.push(row); else dropped.push(`${i + 1}: ${line}`);
    });
    if (dropped.length) {
      // Unparsable lines are named rather than silently swallowed.
      const detail = dropped.slice(0, 10).join("\n");
      if (!added.length) return showLog(pick("Unreadable proxy lines", "Dòng proxy không đọc được"),
                                        { ok: false, log: detail });
      if (!confirm(pick(`${dropped.length} line(s) could not be read and will be skipped:\n${detail}\n\nAdd the other ${added.length}?`,
                        `${dropped.length} dòng không đọc được và sẽ bị bỏ qua:\n${detail}\n\nVẫn thêm ${added.length} dòng còn lại?`))) return;
    }
    if (poolEditSlot !== null) return savePoolEdit(added);
    setPoolAddState(true, pick("Adding proxies to the pool…", "Đang thêm proxy vào pool…"));
    savePoolRows(activePool.concat(added)).then(() => {
      $("poolInput").value = "";
      setPoolAddState(false, pick("Added and saved to proxy-pools.conf.", "Đã thêm và lưu vào proxy-pools.conf."));
      toast(pick("Proxy pool added and applied ✓", "Đã thêm proxy và apply ✓"));
    }).catch(e => {
      setPoolAddState(false, pick("Could not finish adding: ", "Chưa hoàn tất thêm proxy: ") + (e.message || e));
      toast(pick("Error: ", "Lỗi: ") + (e.message || e));
    });
  }
  // The edited slot keeps its position and its label; only the endpoint moves.
  // Every other row is written back exactly as it was, so no other pin shifts.
  function savePoolEdit(parsed) {
    const slot = poolEditSlot;
    if (parsed.length !== 1) {
      return toast(pick("Editing a slot takes exactly one proxy line.", "Sửa một slot chỉ nhận đúng một dòng proxy."));
    }
    if (!Number.isInteger(slot) || slot < 0 || slot >= activePool.length) {
      cancelPoolEdit();
      return toast(pick("That slot is gone; reload the pool.", "Slot đó không còn; hãy tải lại pool."));
    }
    const current = activePool[slot];
    const next = { ...parsed[0], label: current.label || "" };
    const rows = activePool.map((row, i) => (i === slot ? next : row));
    setPoolAddState(true, pick("Saving the proxy…", "Đang lưu proxy…"));
    return savePoolRows(rows).then(() => {
      cancelPoolEdit();
      setPoolAddState(false, pick("Slot updated and saved to proxy-pools.conf.", "Đã cập nhật slot và lưu vào proxy-pools.conf."));
      toast(pick(`Slot ${slot} updated and applied ✓`, `Đã cập nhật slot ${slot} và apply ✓`));
    }).catch(e => {
      setPoolAddState(false, pick("Could not save the slot: ", "Chưa lưu được slot: ") + (e.message || e));
      toast(pick("Error: ", "Lỗi: ") + (e.message || e));
    });
  }

  // Remove named slots instead of the whole pool. Slot numbers are positions in
  // proxy-pools.conf, and devices are pinned by position, so the ones still in
  // use are refused rather than quietly repointing someone's device.
  function deletePoolSlots(selectedSlots) {
    const slots = [...new Set(selectedSlots || [])].map(Number);
    if (slots.some(n => !Number.isInteger(n) || n < 0 || n >= activePool.length)) {
      return toast(pick("Invalid slot number.", "Số slot không hợp lệ."));
    }
    api("clients").then(d => {
      const inUse = ((d && d.clients) || []).filter(c => c.idx === activePoolIdx && c.online && slots.includes(c.slot));
      if (inUse.length) throw new Error(pick(
        `Slot(s) still used by ${inUse.length} online device(s): ${inUse.map(c => c.mac).join(", ")}`,
        `Slot đang được ${inUse.length} thiết bị online dùng: ${inUse.map(c => c.mac).join(", ")}`));
      if (!confirm(pick(`Remove ${slots.length} proxy slot(s) from this pool?`,
                        `Xoá ${slots.length} slot proxy khỏi pool này?`))) return null;
      return savePoolRows(activePool.filter((_p, i) => !slots.includes(i)));
    }).then(r => { if (r !== null) {
      // Deleting renumbers every slot after the removed one, so an edit
      // still open would now be aimed at a different proxy.
      cancelPoolEdit(); poolSelected.clear(); renderPoolRows();
    } })
      .catch(e => toast(pick("Error: ", "Lỗi: ") + (e.message || e)));
  }
  function runPoolBulk() {
    const action = $("poolBulkAction").value;
    if (!poolSelected.size) return toast(pick("Select at least one proxy.", "Chọn ít nhất một proxy."));
    if (action === "test") return testPoolSlots(poolSelected);
    if (action === "edit") return beginPoolEdit([...poolSelected]);
    if (action === "delete") {
      deletePoolSlots([...poolSelected]);
    }
  }
  function clearPool() {
    if (confirm(pick("Delete this proxy pool?", "Xóa pool proxy này?"))) savePoolRows([]).catch(e => toast(pick("Error: ", "Lỗi: ") + e.message));
  }
  function rebalancePoolClientsLegacy() {
    api("clients").then(d => {
      if (!d || !d.ok) throw new Error((d && d.error) || pick("could not load clients", "không tải được danh sách thiết bị"));
      const macs = (d.clients || []).filter(c => c.idx === activePoolIdx && c.online && c.mac).map(c => c.mac);
      if (!macs.length) throw new Error(pick("No online clients on this SSID.", "SSID này không có client online."));
      return routerWrite(pick("Clients rebalanced", "Rebalance client"),
        () => api("rebalance", "POST", { idx: activePoolIdx, macs }),
        () => { loadDevices(); poll(); });
    }).catch(e => toast(pick("Error: ", "Lỗi: ") + e.message));
  }

  function setDeviceProxyState(loading, message) {
    const button = $("devProxySave");
    const status = $("devProxyStatus");
    if (button) {
      button.disabled = loading;
      button.classList.toggle("loading", loading);
      button.textContent = loading ? pick("Working…", "Đang xử lý…") : pick("Add & distribute", "Thêm & phân phối");
    }
    if (status) status.textContent = message || "";
  }
  function rebalancePoolClients() {
    const button = $("poolRebalance"), status = $("poolActionStatus");
    if (button) { button.disabled = true; button.classList.add("loading"); button.textContent = pick("Rebalancing…", "Đang rebalance…"); }
    if (status) status.textContent = pick("Step 1/2 · Rebalancing online clients…", "Bước 1/2 · Đang rebalance thiết bị online…");
    api("clients").then(d => {
      if (!d || !d.ok) throw new Error((d && d.error) || pick("could not load clients", "không tải được danh sách thiết bị"));
      const macs = (d.clients || []).filter(c => c.idx === activePoolIdx && c.online && c.mac).map(c => c.mac);
      if (!macs.length) throw new Error(pick("No online clients on this SSID.", "SSID này không có client online."));
      return api("rebalance", "POST", { idx: activePoolIdx, macs });
    }).then(d => {
      if (!d || d.ok === false) throw new Error(routerReason(d, pick("rebalance failed", "rebalance thất bại")));
      if (status) status.textContent = pick("Step 2/2 · Applying router configuration…", "Bước 2/2 · Đang apply cấu hình router…");
      return applyConfigText(genConf(), false);
    }).then(() => {
      if (status) status.textContent = pick("Rebalance and apply completed.", "Rebalance và apply đã hoàn tất.");
      toast(pick("Clients rebalanced and applied ✓", "Đã rebalance và apply thiết bị ✓"));
      loadDevices(); poll();
    }).catch(e => { if (status) status.textContent = pick("Error: ", "Lỗi: ") + (e.message || e); toast(pick("Error: ", "Lỗi: ") + (e.message || e));
    }).finally(() => { if (button) { button.disabled = false; button.classList.remove("loading"); button.textContent = pick("Rebalance client", "Rebalance thiết bị"); } });
  }

  // The device table keeps the last payload so filtering, sorting and CSV
  // export never have to re-ask the router.
  let devicesData = [];
  let devSort = { key: "", desc: false };
  const deviceSelected = new Set();
  const DEV_COLS = 10;
  const deviceKey = (idx, mac) => `${idx}|${String(mac).toLowerCase()}`;

  function setupDevicesPage() {
    const source = $("devBackdrop").querySelector(":scope > .device-modal");
    const page = $("devicesPage");
    if (!source || page.children.length) return;
    while (source.firstChild) page.appendChild(source.firstChild);
    source.remove();
  }

  function updateDeviceSelection() {
    const visible = visibleDevices().map(c => deviceKey(c.idx, c.mac));
    const selectedVisible = visible.filter(k => deviceSelected.has(k)).length;
    const chosen = selectedDevices();
    const oneSsid = chosen.length > 0 && new Set(chosen.map(c => c.idx)).size === 1;
    $("devProxyAction").hidden = !oneSsid;
    $("devProxyAction").disabled = !oneSsid;
    if (!oneSsid && $("devBulkAction").value === "replace_proxy") $("devBulkAction").value = "";
    $("devSelectAll").checked = visible.length > 0 && selectedVisible === visible.length;
    $("devSelectAll").indeterminate = selectedVisible > 0 && selectedVisible < visible.length;
    $("devBulkRun").disabled = deviceSelected.size === 0 || !$("devBulkAction").value;
    $("devSelectedCount").textContent = chosen.length && new Set(chosen.map(c => c.idx)).size !== 1
      ? pick(`${deviceSelected.size} selected · choose one Wi-Fi`, `${deviceSelected.size} đã chọn · hãy chọn cùng một WiFi`)
      : pick(`${deviceSelected.size} selected`, `${deviceSelected.size} đã chọn`);
  }

  function openDevices() {
    if (!agent.connected) return toast(pick("Not connected to the router.", "Chưa kết nối router."));
    $("dashboardPage").hidden = true;
    $("analyticsPage").hidden = true;
    $("settingsPage").hidden = true;
    $("devicesPage").hidden = false;
    $("settingsBtn").classList.remove("page-active");
    $("configBtn").classList.remove("page-active");
    closeRouterTools();
    $("devicesBtn").classList.add("page-active");
    scrollTo({ top: 0, behavior: "smooth" });
    scheduleDialogActions();
    loadDevices();
    scheduleDeviceRefresh();
  }
  function closeDevices() {
    $("devicesPage").hidden = true;
    $("settingsPage").hidden = true;
    $("analyticsPage").hidden = true;
    $("dashboardPage").hidden = false;
    $("devicesBtn").classList.remove("page-active");
    $("settingsBtn").classList.remove("page-active");
    $("configBtn").classList.remove("page-active");
    clearInterval(devTimer); devTimer = null;
  }
  function setupConfigToolbar() {
    const toolbar = $("configToolbar");
    if (toolbar.dataset.ready) return;
    ["addBtn", "importBundleBtn", "exportBundleBtn", "pullBtn", "clearBtn"]
      .forEach(id => { const el = $(id); if (el) toolbar.appendChild(el); });
    toolbar.dataset.ready = "1";
  }
  function closeRouterTools() {
    // Router tools are now always visible in the left menu when connected.
  }
  function showDashboard() {
    closeDevices();
    setupConfigToolbar();
    $("dashboardPage").hidden = false;
    $("analyticsPage").hidden = true;
    $("configBtn").classList.add("page-active");
    $("settingsBtn").classList.remove("page-active");
    closeRouterTools();
    scrollTo({ top: 0, behavior: "smooth" });
  }
  function settingsStatusText() {
    if (!agent.connected) return pick("Not connected", "Chưa kết nối");
    const sb = agent.singbox && agent.singbox.running ? "sing-box running" : "sing-box DOWN";
    const probes = Object.keys(agent.health || {}).length;
    return `agent v${agent.version || "?"} · ${sb} · ${probes} health probe(s)`;
  }
  function renderSettings() {
    $("settingsStatus").textContent = settingsStatusText();
    const select = $("settingsDiagSsid");
    const keep = select.value;
    select.innerHTML = ssids.length
      ? ssids.map(s => `<option value="${s.idx}">${esc(s.name)} · idx ${s.idx}</option>`).join("")
      : `<option value="">${pick("No Wi-Fi", "Chưa có WiFi")}</option>`;
    if ([...select.options].some(o => o.value === keep)) select.value = keep;
    const policy = $("poolUnassignedSelect");
    const status = $("poolUnassignedStatus");
    if (policy) policy.value = POOL_UNASSIGNED;
    if (status) status.textContent = POOL_UNASSIGNED === "block"
      ? pick("Enabled: unassigned devices are blocked", "Đang bật: thiết bị chưa gán bị chặn")
      : pick("Disabled: unassigned devices use the default proxy", "Đang tắt: thiết bị chưa gán dùng proxy mặc định");
  }
  function savePoolUnassigned() {
    if (!agent.connected) return toast(pick("Connect to the router first.", "Hãy kết nối router trước."));
    const policy = $("poolUnassignedSelect").value;
    const label = policy === "block" ? pick("Block Internet", "Chặn Internet") : pick("Use the default proxy", "Dùng proxy mặc định");
    if (!confirm(pick(`Set unassigned devices to: ${label}? The router will dry-run and apply now.`, `Đặt thiết bị chưa gán thành: ${label}? Router sẽ dry-run và apply ngay.`))) return;
    const button = $("poolUnassignedSave");
    button.disabled = true; button.textContent = pick("Applying…", "Đang apply…");
    api("set_pool_unassigned", "POST", { policy }).then(d => {
      if (!d || !d.ok) throw new Error(routerReason(d, pick("Apply failed", "Apply thất bại")));
      POOL_UNASSIGNED = policy; renderSettings(); poll();
      toast(pick("Unassigned-device policy applied", "Đã apply chính sách thiết bị chưa gán"));
    }).catch(e => toast(`${pick("Error: ", "Lỗi: ")}${e.message || e}`))
      .finally(() => { button.disabled = false; button.textContent = pick("Save & Apply", "Lưu & Apply"); });
  }
  function loadSettingsGateway() {
    const box = $("settingsGateway");
    if (!agent.connected) { box.textContent = pick("Not connected", "Chưa kết nối"); return; }
    box.textContent = pick("Checking…", "Đang kiểm tra…");
    api("gateway").then(d => {
      if (!d || d.ok === false) throw new Error((d && d.error) || "gateway failed");
      const state = d.state || "?";
      box.textContent = `${state} · ${d.interface || "?"} (${d.device || "?"})${d.ipv4 ? " · " + d.ipv4 : ""}`
        + (d.expected_interface ? ` · pinned ${d.expected_interface}` : "");
    }).catch(e => { box.textContent = `${pick("Error: ", "Lỗi: ")}${e.message || e}`; });
  }
  function openSettings() {
    closeDevices();
    $("dashboardPage").hidden = true;
    $("analyticsPage").hidden = true;
    $("settingsPage").hidden = false;
    $("settingsBtn").classList.add("page-active");
    $("configBtn").classList.remove("page-active");
    closeRouterTools();
    renderSettings();
    loadSettingsGateway();
    scrollTo({ top: 0, behavior: "smooth" });
  }
  function refreshSettings() {
    if (!agent.connected) return toast(pick("Connect to the router first.", "Hãy kết nối router trước."));
    poll();
    renderSettings();
    loadSettingsGateway();
  }
  function runSettingsHealth() {
    if (!agent.connected) return toast(pick("Connect to the router first.", "Hãy kết nối router trước."));
    api("health_now").then(d => { if (!d || d.ok === false) throw new Error((d && d.error) || "health check failed"); poll(); toast(pick("Health checked", "Đã kiểm tra health")); })
      .catch(e => toast(`${pick("Error: ", "Lỗi: ")}${e.message || e}`));
  }
  function runSettingsDiagnosis() {
    const idx = parseInt($("settingsDiagSsid").value, 10);
    if (!agent.connected || !isFinite(idx)) return toast(pick("Connect and choose a Wi-Fi.", "Hãy kết nối và chọn WiFi."));
    diagnoseSsid(idx);
  }
  function scheduleDeviceRefresh() {
    clearInterval(devTimer); devTimer = null;
    if (!$("devAuto").checked) return;
    const every = Math.max(5, parseInt($("devInterval").value, 10) || 10);
    devTimer = setInterval(loadDevices, every * 1000);
  }
  // status is what the router decided; the duration beside it is what makes it
  // actionable ("blocked", "active for 3m", "last seen 2h ago").
  function deviceStatusCell(c) {
    if (c.banned) return `<span class="chip warnhue on"><span class="dot"></span>${pick("blocked", "bị cấm")}</span>`;
    if (c.online) return `<span class="chip on"><span class="dot"></span>${pick("active", "đang kết nối")} ${fmtDuration(c.connected_s)}</span>`;
    const idle = c.inactive_s != null
      ? pick(`idle ${fmtDuration(c.inactive_s)}`, `đã ngắt ${fmtDuration(c.inactive_s)}`)
      : pick("seen before", "từng kết nối");
    return `<span class="chip">${esc(idle)}</span>`;
  }
  function visibleDevices() {
    const query = $("devSearch").value.trim().toLowerCase();
    const ssidPick = $("devSsidFilter").value;
    const state = $("devStateFilter").value;
    let list = devicesData.filter(c => {
      if (query && ![c.mac, c.ip, c.host, c.ssid, ssidNameByIdx(c.idx)]
          .some(v => String(v || "").toLowerCase().includes(query))) return false;
      if (ssidPick !== "" && String(c.idx) !== ssidPick) return false;
      if (state === "online" && !c.online) return false;
      if (state === "blocked" && !c.banned) return false;
      if (state === "offline" && (c.online || c.banned)) return false;
      return true;
    });
    if (devSort.key) {
      const key = devSort.key;
      list = list.slice().sort((a, b) => {
        const av = a[key], bv = b[key];
        const cmp = (typeof av === "number" && typeof bv === "number")
          ? av - bv : String(av ?? "").localeCompare(String(bv ?? ""));
        return devSort.desc ? -cmp : cmp;
      });
    }
    return list;
  }
  function renderDevices() {
    const box = $("devRows");
    const list = visibleDevices();
    const online = devicesData.filter(c => c.online).length;
    const blocked = devicesData.filter(c => c.banned).length;
    const traffic = devicesData.reduce((n, c) => n + (Number(c.rx_bytes) || 0) + (Number(c.tx_bytes) || 0), 0);
    $("devSummary").textContent = pick(
      `${list.length} shown · ${online} online · ${blocked} blocked · ${devicesData.length} known · ${fmtBytes(traffic)} total`,
      `Hiện ${list.length} · ${online} đang kết nối · ${blocked} bị cấm · ${devicesData.length} đã từng vào · ${fmtBytes(traffic)} lưu lượng`);
    if (!list.length) {
      box.innerHTML = `<tr><td colspan="${DEV_COLS}" class="sub">${pick("No device matches the filter.", "Không có thiết bị nào khớp bộ lọc.")}</td></tr>`;
      updateDeviceSelection();
      return;
    }
    patchTable(box, list, c => deviceKey(c.idx, c.mac), c => {
      const ipHost = [c.ip || "", c.host || ""].filter(Boolean).join(" · ") || "—";
      const sig = (c.signal_dbm != null) ? c.signal_dbm + " dBm" : "—";
      const proxy = c.pool_size > 0
        ? `${c.proxy_state === "pinned" ? "slot " + c.slot + " · " : pick("unpinned · ", "chưa gán · ")}${esc(c.proxy_host || "pool")}`
        : pick("single proxy", "proxy đơn");
      const proxyBtn = c.pool_size > 0
        ? `<button class="iconbtn" data-proxy="${esc(c.mac)}" data-idx="${c.idx}">${pick("Proxy", "Đổi proxy")}</button>`
        : "";
      const act = (c.banned
        ? `<button class="iconbtn" data-unban="${esc(c.mac)}" data-idx="${c.idx}">✓ ${pick("Unblock", "Bỏ cấm")}</button>`
        : (c.online
            ? `<button class="iconbtn" data-kick="${esc(c.mac)}" data-idx="${c.idx}" title="${pick("Temporary disconnect (the device may reconnect)", "Ngắt tạm (thiết bị có thể nối lại)")}">⏏ ${pick("Disconnect", "Kick")}</button>`
            : "") +
          `<button class="iconbtn del" data-ban="${esc(c.mac)}" data-idx="${c.idx}" title="${pick("Persistently block this MAC", "Chặn MAC lâu dài")}">⛔ ${pick("Block", "Cấm")}</button>`)
        + `<button class="iconbtn" data-detail="${esc(c.mac)}" data-idx="${c.idx}" title="${pick("Details", "Chi tiết")}">ℹ</button>`;
      const key = deviceKey(c.idx, c.mac);
      return `
        <td class="select-cell"><input type="checkbox" data-device-select="${esc(key)}" ${deviceSelected.has(key) ? "checked" : ""} aria-label="${pick("Select device", "Chọn thiết bị")} ${esc(c.mac)}"></td>
        <td><span class="idxpill">${c.idx}</span> ${esc(ssidNameByIdx(c.idx))}</td>
        <td class="mono">${esc(c.mac)}</td>
        <td class="mono sub">${esc(ipHost)}</td>
        <td>${deviceStatusCell(c)}</td>
        <td class="mono">${fmtBytes(c.rx_bytes)}</td>
        <td class="mono">${fmtBytes(c.tx_bytes)}</td>
        <td class="mono sub">${esc(sig)}</td>
        <td class="mono sub">${proxy} ${proxyBtn}</td>
        <td><div class="rowbtns">${act}</div></td>`;
    }, c => [c.online ? "" : "dim",
             deviceSelected.has(deviceKey(c.idx, c.mac)) ? "selected" : ""].filter(Boolean).join(" "));
    updateDeviceSelection();
  }
  function loadDevices() {
    api("clients").then(d => {
      // The ok check comes first: an error payload has no clients, and reading
      // "no devices" when the agent actually failed hides the real problem.
      if (!d || !d.ok) throw new Error((d && d.error) || pick("error", "lỗi"));
      devicesData = (d.clients || []).filter(c => c && c.mac);
      const currentKeys = new Set(devicesData.map(c => deviceKey(c.idx, c.mac)));
      [...deviceSelected].forEach(k => { if (!currentKeys.has(k)) deviceSelected.delete(k); });
      const chosen = $("devSsidFilter").value;
      const seen = [...new Set(devicesData.map(c => c.idx))].sort((a, b) => a - b);
      $("devSsidFilter").innerHTML = `<option value="">${pick("Wi-Fi: all", "WiFi: tất cả")}</option>` +
        seen.map(i => `<option value="${i}">${esc(ssidNameByIdx(i))} (idx ${i})</option>`).join("");
      $("devSsidFilter").value = seen.some(i => String(i) === chosen) ? chosen : "";
      renderDevices();
    }).catch(err => {
      $("devRows").innerHTML = `<tr><td colspan="${DEV_COLS}"><span class="conn-status bad">${pick("Error: ", "Lỗi: ")}${esc(err.message)}</span></td></tr>`;
    });
  }
  function deviceDetails(idx, mac) {
    const c = devicesData.find(x => x.mac === mac && x.idx === idx);
    if (!c) return;
    const when = t => t ? new Date(t * 1000).toLocaleString() : "—";
    const lines = [
      `${pick("Wi-Fi", "WiFi")}: ${ssidNameByIdx(c.idx)} (idx ${c.idx}${c.band ? " · " + c.band : ""})`,
      `MAC: ${c.mac}`,
      `IP: ${c.ip || "—"}`,
      `${pick("Hostname", "Tên máy")}: ${c.host || "—"}`,
      `${pick("Status", "Trạng thái")}: ${c.banned ? pick("blocked", "bị cấm") : c.online ? pick("online", "đang kết nối") : pick("offline", "đã ngắt")}`,
      `${pick("Connected for", "Đã kết nối")}: ${c.online ? fmtDuration(c.connected_s) : "—"}`,
      `${pick("Idle for", "Ngắt được")}: ${c.inactive_s != null ? fmtDuration(c.inactive_s) : "—"}`,
      `${pick("First seen", "Lần đầu thấy")}: ${when(c.first_seen)}`,
      `${pick("Last seen", "Lần cuối thấy")}: ${when(c.last_seen)}`,
      `${pick("Signal", "Sóng")}: ${c.signal_dbm != null ? c.signal_dbm + " dBm" : "—"}`,
      `${pick("Received", "Vào")}: ${fmtBytes(c.rx_bytes)} · ${pick("Sent", "Ra")}: ${fmtBytes(c.tx_bytes)}`,
      `${pick("Proxy", "Proxy")}: ${c.pool_size > 0 ? `${c.proxy_state} ${c.slot != null ? "slot " + c.slot : ""} ${c.proxy_host || ""} ${c.proxy_label ? "(" + c.proxy_label + ")" : ""}` : pick("single proxy (no pool)", "proxy đơn (không dùng pool)")}`,
      `${pick("Interface", "Interface")}: ${c.ifname || "—"}`
    ];
    showLog(pick("Device details", "Chi tiết thiết bị") + " · " + c.mac, { ok: true, log: lines.join("\n") });
  }
  function exportDevicesCsv() {
    const list = visibleDevices();
    if (!list.length) return toast(pick("Nothing to export.", "Không có gì để xuất."));
    const cols = ["idx", "ssid", "band", "mac", "ip", "host", "status", "online", "banned",
                  "connected_s", "inactive_s", "first_seen", "last_seen",
                  "rx_bytes", "tx_bytes", "signal_dbm", "slot", "proxy_host", "proxy_state"];
    const cell = v => {
      const s = v == null ? "" : String(v);
      return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
    };
    const rows = list.map(c => cols.map(k => cell(k === "ssid" ? (c.ssid || ssidNameByIdx(c.idx)) : c[k])).join(","));
    // The BOM keeps Excel from mangling UTF-8 hostnames.
    download("sbproxy-devices.csv", "﻿" + cols.join(",") + "\n" + rows.join("\n") + "\n");
    toast(pick("CSV downloaded ✓", "Đã tải CSV ✓"));
  }
  // Block a MAC that is not in the list — a device that has never connected
  // cannot be selected, but it can still be kept out in advance.
  function manualBan() {
    const idxs = ssids.map(s => s.idx).sort((a, b) => a - b);
    if (!idxs.length) return toast(pick("No Wi-Fi is configured.", "Chưa có WiFi nào."));
    const idxAnswer = prompt(pick("Block on which Wi-Fi? Enter its idx:\n", "Cấm trên WiFi nào? Nhập idx:\n") +
      idxs.map(i => `${i}: ${ssidNameByIdx(i)}`).join("\n"), String(idxs[0]));
    if (idxAnswer == null) return;
    const idx = parseInt(idxAnswer.trim(), 10);
    if (!idxs.includes(idx)) return toast(pick("Unknown idx.", "idx không tồn tại."));
    const macAnswer = prompt(pick("MAC address to block (aa:bb:cc:dd:ee:ff):", "MAC cần cấm (aa:bb:cc:dd:ee:ff):"), "");
    if (macAnswer == null) return;
    const mac = macAnswer.trim().toLowerCase().replace(/-/g, ":");
    if (!/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(mac)) return toast(pick("Invalid MAC address.", "MAC không hợp lệ."));
    deviceAction("ban", idx, mac);
  }
  function changeClientProxy(idx, mac) {
    fetch(apiUrl("get_pool") + "&idx=" + encodeURIComponent(idx), { headers: { "Authorization": `Bearer ${agent.token}` } }).then(readJson)
      .then(d => {
        const pool = (d && d.proxies) || [];
        if (!pool.length) throw new Error(pick("This SSID has no proxy pool.", "SSID này chưa có proxy pool."));
        const choices = pool.map((p, i) => `${i}: ${p.host}:${p.port}${p.label ? " (" + p.label + ")" : ""}`).join("\n");
        const answer = prompt(pick("Choose proxy slot (type 'none' to unpin):\n", "Chọn slot proxy (gõ 'none' để bỏ ghim):\n") + choices);
        if (answer == null) return;
        const value = answer.trim().toLowerCase();
        const slot = value === "none" ? "none" : Number(value);
        if (slot !== "none" && (!Number.isInteger(slot) || slot < 0 || slot >= pool.length)) throw new Error(pick("Invalid proxy slot.", "Slot proxy không hợp lệ."));
        return routerWrite(pick("Proxy changed", "Đổi proxy"),
          () => api("assign_proxy", "POST", { idx, assignments: [{ mac, slot }] }),
          () => { loadDevices(); poll(); });
      }).catch(err => toast(pick("Error: ", "Lỗi: ") + (err.message || err)));
  }

  // Random MAC: a new BSSID for one SSID, optionally from another vendor's OUI.
  // The router reloads that Wi-Fi, so every client on it reconnects.
  function rotateMac(idx) {
    if (!agent.connected) return;
    const rec = ssids.find(s => s.idx === idx);
    const current = rec ? (rec.mac_oui || "") : "";
    const menu = VENDORS.map((v, i) => `${i}: ${vendorLabel(v)}${v.oui ? " · " + v.oui : ""}`).join("\n");
    const answer = prompt(pick(
      `Vendor for the new MAC of "${rec ? rec.name : "w" + idx}" (number, or Enter to keep the current one):\n`,
      `Hãng cho MAC mới của "${rec ? rec.name : "w" + idx}" (nhập số, Enter để giữ nguyên):\n`) + menu, "");
    if (answer == null) return;
    const choice = answer.trim();
    let oui = current;
    if (choice !== "") {
      const n = Number(choice);
      if (!Number.isInteger(n) || n < 0 || n >= VENDORS.length) return toast(pick("Invalid vendor.", "Hãng không hợp lệ."));
      oui = VENDORS[n].oui;
    }
    if (!confirm(pick(`Give "${rec ? rec.name : "w" + idx}" a new random MAC now? That Wi-Fi reloads and every device on it must reconnect.`,
                      `Đổi MAC ngẫu nhiên cho "${rec ? rec.name : "w" + idx}" ngay? WiFi đó sẽ reload, mọi thiết bị phải kết nối lại.`))) return;
    routerWrite(pick("Rotating the MAC", "Đổi MAC"),
      () => api("rotate_mac", "POST", oui ? { idx, oui } : { idx }),
      d => {
        showLog("rotate-mac.sh idx=" + idx, d);
        if (rec) { rec.mac_oui = oui; save(); }
        // The radio reloads; give it a moment before believing the next poll.
        setTimeout(() => { poll(); render(); }, 4000);
      }).catch(() => {});
  }

  function deviceAction(action, idx, mac) {
    const verb = action === "kick" ? pick("Disconnect (temporary)", "Kick (ngắt tạm)")
      : action === "ban" ? pick("Block (persistent)", "Cấm (chặn lâu dài)")
      : pick("Unblock", "Bỏ cấm");
    if (action !== "kick" && !confirm(
        pick(`${verb} device ${mac} from Wi-Fi "${ssidNameByIdx(idx)}"?`,
             `${verb} thiết bị ${mac} khỏi WiFi "${ssidNameByIdx(idx)}"?`) +
        (action === "ban"
          ? pick("\n\n⚠️ The band of this Wi-Fi will reload (clients on the same band drop briefly).",
                 "\n\n⚠️ Băng tần của WiFi này sẽ reload (các client cùng băng bị ngắt trong giây lát).")
          : ""))) return;
    routerWrite(verb, () => api(action, "POST", { idx, mac }),
      () => { loadDevices(); poll(); }).catch(() => {});
  }

  function selectedDevices() {
    return devicesData.filter(c => deviceSelected.has(deviceKey(c.idx, c.mac)));
  }
  let devProxyBatch = null;
  const cleanProxy = p => ({ type: p.type || "socks5", host: p.host, port: Number(p.port),
    user: p.user || "", pass: p.pass || "", label: p.label || "" });
  const proxyIdentity = p => [String(p.type || "socks5").toLowerCase(), String(p.host).toLowerCase(),
    Number(p.port), p.user || "", p.pass || ""].join("|");
  function fetchPoolForIdx(idx) {
    return fetch(apiUrl("get_pool") + "&idx=" + encodeURIComponent(idx), {
      headers: { "Authorization": `Bearer ${agent.token}` }
    }).then(readJson).then(d => {
      if (!d || d.ok === false) throw new Error((d && d.error) || "pool error");
      return d.proxies || [];
    });
  }
  function closeDeviceProxyBatch() {
    hideInline("devProxyBackdrop");
    devProxyBatch = null;
  }
  function openDeviceProxyBatch() {
    const rows = selectedDevices();
    const idxs = new Set(rows.map(c => c.idx));
    if (!rows.length || idxs.size !== 1) {
      return toast(pick("Select devices from one SSID only.", "Chỉ chọn thiết bị trong cùng một SSID."));
    }
    const idx = rows[0].idx;
    devProxyBatch = { idx, devices: rows.map(c => ({ idx: c.idx, mac: c.mac })), pool: null };
    $("devProxyTitle").textContent = ssidNameByIdx(idx);
    $("devProxyHint").textContent = pick(
      `${rows.length} selected device(s). New proxies stay in this SSID; other devices keep their assignment.`,
      `${rows.length} thiết bị đã chọn. Proxy mới được giữ trong SSID; thiết bị khác giữ nguyên.`);
    $("devProxyCurrent").textContent = pick("Loading pool…", "Đang tải pool…");
    $("devProxyInput").value = "";
    $("devProxyError").textContent = "";
    $("devProxyStatus").textContent = "";
    $("devProxySave").disabled = true;
    showInline("devProxyBackdrop");
    fetchPoolForIdx(idx).then(pool => {
      if (!devProxyBatch || devProxyBatch.idx !== idx) return;
      devProxyBatch.pool = pool.map(cleanProxy);
      $("devProxyCurrent").textContent = pick(
        `${pool.length} current proxy(s) · pasted proxies will be appended`,
        `${pool.length} proxy hiện tại · proxy dán vào sẽ được thêm cuối pool`);
      $("devProxySave").disabled = false;
      $("devProxyInput").focus();
    }).catch(e => {
      $("devProxyError").textContent = pick("Cannot load this SSID pool: ", "Không tải được pool của SSID: ") + e.message;
    });
  }
  function submitDeviceProxyBatch() {
    if (!devProxyBatch || !Array.isArray(devProxyBatch.pool)) return;
    const lines = $("devProxyInput").value.split(/\r?\n/).map(x => x.trim()).filter(Boolean);
    if (!lines.length) { $("devProxyError").textContent = pick("Paste at least one proxy.", "Hãy dán ít nhất một proxy."); return; }
    const format = $("devProxyFormat").value, type = $("devProxyType").value;
    const parsed = [], bad = [];
    lines.forEach((line, i) => {
      const proxy = parseProxyLine(line, format, type);
      if (proxy) parsed.push(cleanProxy(proxy)); else bad.push(i + 1);
    });
    if (bad.length) {
      $("devProxyError").textContent = pick(`Unreadable line(s): ${bad.join(", ")}`, `Không đọc được dòng: ${bad.join(", ")}`);
      return;
    }
    const targetById = new Map();
    parsed.forEach(p => targetById.set(proxyIdentity(p), p));
    const existingIds = new Set(devProxyBatch.pool.map(proxyIdentity));
    const added = [...targetById.values()].filter(p => !existingIds.has(proxyIdentity(p)));
    const merged = devProxyBatch.pool.concat(added);
    const idx = devProxyBatch.idx, devices = devProxyBatch.devices.slice();
    $("devProxyError").textContent = "";
    setDeviceProxyState(true, pick("Step 1/4 · Saving the proxy pool…", "Bước 1/4 · Đang lưu proxy vào pool…"));
    const save = added.length ? api("save_pool", "POST", { idx, proxies: merged }) : Promise.resolve({ ok: true });
    save.then(d => {
      if (!d || d.ok === false) throw new Error(routerReason(d, pick("saving the pool failed", "lưu pool thất bại")));
      setDeviceProxyState(true, pick("Step 2/4 · Reading saved proxy slots…", "Bước 2/4 · Đang đọc slot proxy đã lưu…"));
      return fetchPoolForIdx(idx);
    }).then(savedPool => {
      const targetIds = new Set(targetById.keys());
      const slots = savedPool.map((p, slot) => ({ p, slot })).filter(x => targetIds.has(proxyIdentity(x.p))).map(x => x.slot);
      if (!slots.length) throw new Error(pick("The pasted proxies were not found after saving.", "Không tìm thấy proxy vừa dán sau khi lưu."));
      // Shuffle before round-robin so repeated runs do not always give the
      // first device the first proxy, while counts still differ by at most one.
      for (let i = devices.length - 1; i > 0; i--) {
        const random = new Uint32Array(1); crypto.getRandomValues(random);
        const j = random[0] % (i + 1); [devices[i], devices[j]] = [devices[j], devices[i]];
      }
      const assignments = devices.map((device, i) => ({ mac: device.mac, slot: slots[i % slots.length] }));
      setDeviceProxyState(true, pick("Step 3/4 · Assigning proxies to devices…", "Bước 3/4 · Đang gán proxy cho thiết bị…"));
      return api("assign_proxy", "POST", { idx, assignments });
    }).then(d => {
      if (!d || d.ok === false) throw new Error(routerReason(d, pick("Some devices could not be assigned.", "Không gán được một số thiết bị.")));
      setDeviceProxyState(true, pick("Step 4/4 · Applying router configuration…", "Bước 4/4 · Đang apply cấu hình router…"));
      return applyConfigText(genConf(), false);
    }).then(() => {
      closeDeviceProxyBatch();
      deviceSelected.clear(); $("devBulkAction").value = "";
      toast(pick(`${devices.length} device(s) distributed across ${targetById.size} proxy(s) ✓`,
                 `Đã phân phối ${devices.length} thiết bị qua ${targetById.size} proxy ✓`));
      loadDevices(); poll();
    }).catch(e => {
      $("devProxyError").textContent = pick("Error: ", "Lỗi: ") + (e.message || e);
      setDeviceProxyState(false, pick("Could not finish the operation.", "Chưa hoàn tất thao tác."));
    });
  }
  function runDeviceBulk() {
    const action = $("devBulkAction").value;
    const rows = selectedDevices();
    if (!action || !rows.length) return toast(pick("Select at least one device.", "Chọn ít nhất một thiết bị."));
    if (action === "replace_proxy") return openDeviceProxyBatch();
    const verb = action === "kick" ? pick("disconnect", "ngắt")
      : action === "ban" ? pick("block", "cấm") : pick("unblock", "bỏ cấm");
    if (!confirm(pick(`${verb} ${rows.length} selected device(s)?`, `${verb} ${rows.length} thiết bị đã chọn?`))) return;
    busy(pick(`Working on ${rows.length} device(s)…`, `Đang xử lý ${rows.length} thiết bị…`));
    rows.reduce((chain, c) => chain.then(async results => {
      try {
        const d = await api(action, "POST", { idx: c.idx, mac: c.mac });
        results.push({ ok: !!(d && d.ok), c });
      } catch (_e) { results.push({ ok: false, c }); }
      return results;
    }), Promise.resolve([])).then(results => {
        const failed = results.filter(r => !r.ok).length;
        if (!failed) deviceSelected.clear();
        toast(failed
          ? pick(`${failed}/${rows.length} failed.`, `Lỗi ${failed}/${rows.length} thiết bị.`)
          : pick(`${rows.length} device(s) updated ✓`, `Đã cập nhật ${rows.length} thiết bị ✓`));
        loadDevices(); poll();
      }).finally(busyDone);
  }

  // ---- render ----
  function render() {
    renderStats();
    renderAnalytics();
    renderRows();
    renderOutput();
    save();
    localizeStatic();
  }

  function renderStats() {
    const c2 = ssids.filter(s => s.band === "2g").length;
    const c5 = ssids.filter(s => s.band === "5g").length;
    const proxies = new Set(ssids.map(s => s.host + ":" + s.port)).size;
    const iso = ssids.filter(s => s.isolate).length;
    const web = ssids.filter(s => webrtcMode(s.webrtc) === WEBRTC_BLOCK).length;
    const meter = (n, cls) => {
      const over = n > BSSID_LIMIT;
      const w = Math.min(100, (n / BSSID_LIMIT) * 100);
      return `<div class="stat ${over ? "warnstate" : ""}">
        <div class="label">${cls}</div>
        <div class="val">${n}<small> / ${BSSID_LIMIT} BSSID</small></div>
        <div class="meter ${over ? "over" : ""}"><i style="width:${w}%"></i></div>
      </div>`;
    };
    document.getElementById("stats").innerHTML =
      `<div class="stat"><div class="label">${pick("Total Wi-Fi", "Tổng WiFi")}</div><div class="val">${ssids.length}</div></div>` +
      meter(c2, "2.4 GHz") + meter(c5, "5 GHz") +
      `<div class="stat"><div class="label">${pick("Distinct SOCKS", "SOCKS riêng biệt")}</div><div class="val">${proxies}</div></div>` +
      `<div class="stat"><div class="label">${pick("Isolation / WebRTC", "Cách ly / WebRTC")}</div><div class="val">${iso}<small> / ${web}</small></div></div>` +
      singboxCard();
  }

  function renderAnalytics() {
    const count = id => document.getElementById(id);
    if (!count("analyticsSsidCount")) return;
    const c2 = ssids.filter(s => s.band === "2g").length;
    const c5 = ssids.filter(s => s.band === "5g").length;
    const proxies = new Set(ssids.map(s => s.host + ":" + s.port)).size;
    count("analyticsSsidCount").textContent = ssids.length;
    count("analytics24").textContent = c2;
    count("analytics5").textContent = c5;
    count("analyticsProxyCount").textContent = proxies;
    count("analyticsIsolation").textContent = ssids.filter(s => s.isolate).length;
    count("analyticsWebrtc").textContent = ssids.filter(s => webrtcMode(s.webrtc) === WEBRTC_BLOCK).length;
    const sb = agent.singbox;
    const dot = count("analyticsSingboxDot");
    const status = count("analyticsSingboxStatus");
    const meta = count("analyticsSingboxMeta");
    const restart = count("analyticsRestartBtn");
    restart.disabled = !agent.connected;
    dot.className = "state-dot";
    if (!agent.connected || !sb) {
      status.textContent = pick("Not connected", "Chưa kết nối");
      meta.textContent = pick("Waiting for agent status", "Đang chờ trạng thái agent");
      return;
    }
    const healthy = sb.running && !sb.flapping;
    dot.classList.add(healthy ? "ok" : "bad");
    status.textContent = sb.flapping ? pick("Restarting", "Đang khởi động lại") : sb.running ? pick("Running", "Đang chạy") : pick("Down", "Không chạy");
    meta.textContent = sb.uptime != null ? pick(`Uptime ${fmtDuration(sb.uptime)}`, `Đã chạy ${fmtDuration(sb.uptime)}`) : pick("Proxy engine status", "Trạng thái engine proxy");
  }

  function refreshPoolCounts() {
    if (!agent.connected || !ssids.length) return;
    const signature = ssids.map(s => s.idx).sort((a, b) => a - b).join(",");
    poolCountSignature = signature;
    Promise.all(ssids.map(s => fetch(apiUrl("get_pool") + "&idx=" + encodeURIComponent(s.idx), {
      headers: { "Authorization": `Bearer ${agent.token}` }
    }).then(readJson).then(d => {
      let count = Array.isArray(d && d.proxies) ? d.proxies.length : 0;
      if (!count && s.host && s.port) count = 1;
      poolCounts[s.idx] = count;
    }).catch(() => { poolCounts[s.idx] = null; }))).then(() => {
      if (poolCountSignature === signature) renderRows();
    });
  }
  function wifiRowCells(s) {
      const auth = `<span class="chip on"><span class="dot"></span>${pick("Pool-only", "Chỉ dùng pool")}</span>`;
      return `
        <td><span class="idxpill">${s.idx}</span></td>
        <td><div class="ssid-name">${esc(s.name)}</div><div class="sub mono">${gw(s.idx)} · tproxy :${tport(s.idx)} · MAC ${esc(s.mac_oui ? s.mac_oui + " " + vendorName(s.mac_oui) : pick("02: anonymous", "02: ẩn danh"))}</div><div class="proxy-count">${poolCounts[s.idx] == null ? pick("Proxy count…", "Đang tải số proxy…") : `${poolCounts[s.idx]} proxy`}</div></td>
        <td><span class="band ${s.band === "2g" ? "b2" : "b5"}">${s.band === "2g" ? "2.4G" : "5G"}</span></td>
        <td class="mono sub">${subnet(s.idx)}</td>
        <td>${auth}</td>
        <td>${s.isolate ? '<span class="chip on"><span class="dot"></span>on</span>' : '<span class="chip">off</span>'}</td>
        <td>${webrtcCell(s.webrtc)}</td>
        <td data-health="${s.idx}">${healthCell(s.idx)}</td>
        <td><button class="iconbtn" data-pool="${s.idx}">${pick("Pool", "Pool")}</button></td>
        <td><div class="rowbtns">
          ${agent.connected ? `<button class="iconbtn zap" data-zap="${s.id}" title="${pick("Change SOCKS without reloading Wi-Fi; open sessions may drop", "Đổi SOCKS không reload WiFi; phiên đang mở có thể gián đoạn")}">⚡</button>` : ""}
          ${agent.connected ? `<button class="iconbtn" data-diag="${s.idx}" title="${pick("Diagnose this Wi-Fi's data path on the router", "Chẩn đoán đường đi dữ liệu của WiFi này trên router")}">🩺</button>` : ""}
          ${agent.connected ? `<button class="iconbtn" data-mac="${s.idx}" title="${pick("New random BSSID/MAC for this Wi-Fi (clients reconnect)", "Đổi BSSID/MAC ngẫu nhiên cho WiFi này (client phải nối lại)")}">🎲</button>` : ""}
          <button class="iconbtn" data-edit="${s.id}">${pick("Edit", "Sửa")}</button>
          <button class="iconbtn" data-dup="${s.id}">⧉</button>
          <button class="iconbtn del" data-del="${s.id}">✕</button>
        </div></td>`;
  }
  function renderRows() {
    const tb = document.getElementById("rows");
    document.getElementById("empty").style.display = ssids.length ? "none" : "block";
    const sorted = [...ssids].sort((a, b) => a.idx - b.idx);
    // Keyed on the local row id, which survives editing the idx: renaming a
    // Wi-Fi rewrites one row, it does not rebuild the table.
    patchTable(tb, sorted, s => s.id, wifiRowCells);
  }

  // ---- Generators matching scripts/lib.sh ----
  function genConf() {
    const head =
`# wifi-socks.conf — generated by sbproxy Console
# name|band|idx|wifi_key|proxy_host|proxy_port|proxy_user|proxy_pass|isolate|webrtc|mac_oui|proxy_type|local_subnet
`;
    const lines = [...ssids].sort((a, b) => a.idx - b.idx).map(s =>
      [s.name, s.band, s.idx, s.key, "", "", "", "", s.isolate ? 1 : 0, webrtcMode(s.webrtc), s.mac_oui || "", "socks5", s.local_subnet || ""].join("|")
    );
    return head + lines.join("\n") + (lines.length ? "\n" : "");
  }

  function genSingbox() {
    const sorted = [...ssids].sort((a, b) => a.idx - b.idx);
    const inbounds = sorted.map(s => ({
      type: "tproxy", tag: `in-w${s.idx}`, listen: "0.0.0.0", listen_port: tport(s.idx), sniff: true
    }));
    const outbounds = sorted.map(s => {
      const isHttp = (s.proxy_type || "socks5") === "http";
      const o = { type: isHttp ? "http" : "socks", tag: `out-w${s.idx}`, server: s.host, server_port: Number(s.port) };
      // SOCKS_UDP on the router decides whether a socks outbound is pinned to
      // TCP; unpinned means sing-box also relays UDP ASSOCIATE. An HTTP proxy
      // has no UDP transport, so it is never pinned either way.
      if (!isHttp) { o.version = "5"; if (!SOCKS_UDP) o.network = "tcp"; }
      if (s.user) { o.username = s.user; o.password = s.pass || ""; }
      return o;
    });
    outbounds.push({ type: "direct", tag: "direct" }, { type: "block", tag: "block" });
    const rules = sorted.map(s => ({ inbound: [`in-w${s.idx}`], outbound: `out-w${s.idx}` }));
    return JSON.stringify({
      log: { level: "warn", timestamp: true },
      inbounds, outbounds, route: { rules, final: "direct" }
    }, null, 2);
  }

  function genNft() {
    const sorted = [...ssids].sort((a, b) => a.idx - b.idx);
    const webrtc = sorted.filter(s => webrtcMode(s.webrtc) === WEBRTC_BLOCK).flatMap(s => [
      `    iifname "br-w${s.idx}" tcp dport { ${STUN_TCP} } drop`,
      `    iifname "br-w${s.idx}" udp dport { ${STUN_UDP} } drop`
    ]);
    // Bypass hijacks STUN/TURN ahead of every return rule, so the STUN server
    // sees the proxy and hands back the proxy's IP as the reflexive candidate.
    const webrtcBypass = sorted.filter(s => webrtcMode(s.webrtc) === WEBRTC_BYPASS).flatMap(s => [
      `    iifname "br-w${s.idx}" tcp dport { ${STUN_TCP} } tproxy ip to :${tport(s.idx)} meta mark set ${MARK} accept`,
      `    iifname "br-w${s.idx}" udp dport { ${STUN_UDP} } tproxy ip to :${tport(s.idx)} meta mark set ${MARK} accept`
    ]);
    const bypass = [...new Set(sorted.map(s => s.host).filter(isIP))].map(h => `    ip daddr ${h} return`);
    const tproxy = sorted.flatMap(s => [
      `    iifname "br-w${s.idx}" meta l4proto tcp tproxy ip to :${tport(s.idx)} meta mark set ${MARK} accept`,
      `    iifname "br-w${s.idx}" meta l4proto udp tproxy ip to :${tport(s.idx)} meta mark set ${MARK} accept`
    ]);
    return [
      "# GENERATED by sbproxy Console — matches scripts/lib.sh build_nft",
      "table inet sbproxy {",
      "  chain webrtc {",
      "    type filter hook forward priority filter; policy accept;",
      ...webrtc,
      "  }",
      "  chain prerouting {",
      "    type filter hook prerouting priority mangle; policy accept;",
      ...webrtcBypass,
      "    ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } return",
      ...bypass,
      ...tproxy,
      "  }",
      "}"
    ].join("\n");
  }

  const TABS = {
    conf: { name: "config/wifi-socks.conf", gen: genConf,
      hint: () => pick(`Copy this content to <code>config/wifi-socks.conf</code> on the router, then run <code>sh scripts/apply.sh</code>. Quickly change one SOCKS endpoint with: <code>sh scripts/set-sock.sh &lt;idx&gt; host port user pass</code>.`, `Copy nội dung này vào <code>config/wifi-socks.conf</code> trên router, rồi chạy <code>sh scripts/apply.sh</code>. Đổi 1 sock nhanh: <code>sh scripts/set-sock.sh &lt;idx&gt; host port user pass</code>.`) },
    singbox: { name: "/etc/sing-box/config.json", gen: genSingbox,
      hint: () => pick(`This file is generated by <code>apply.sh</code> on the router — this is only a <b>preview</b>. Validate it with: <code>sing-box check -c /etc/sing-box/config.json</code>.`, `File này do <code>apply.sh</code> tự sinh trên router — đây chỉ là <b>xem trước</b> để đối chiếu. Validate: <code>sing-box check -c /etc/sing-box/config.json</code>.`) },
    nft: { name: "/etc/sbproxy.nft", gen: genNft,
      hint: () => pick(`The TPROXY and WebRTC-blocking ruleset is generated by <code>apply.sh</code> and loaded through <code>/etc/init.d/sbproxy</code>. Inspect it with: <code>nft list table inet sbproxy</code>.`, `Ruleset TPROXY + chặn WebRTC, do <code>apply.sh</code> sinh và nạp qua <code>/etc/init.d/sbproxy</code>. Xem trên router: <code>nft list table inet sbproxy</code>.`) }
  };

  function renderOutput() {
    const t = TABS[curTab];
    document.getElementById("outName").textContent = t.name;
    document.getElementById("outCode").textContent = t.gen();
    document.getElementById("applyHint").innerHTML = t.hint();
  }

  // ---- modal ----
  const $ = id => document.getElementById(id);
  let inlineFeature = null;
  function showInline(backdropId) {
    const backdrop = $(backdropId), modal = backdrop && backdrop.querySelector(":scope > .modal");
    if (!modal) return;
    if (inlineFeature) hideInline(inlineFeature.id);
    backdrop.classList.remove("show");
    modal.classList.remove("show");
    inlineFeature = {
      id: backdropId, modal, parent: backdrop,
      next: modal.nextSibling,
      returnPage: !$('settingsPage').hidden ? 'settings' : (!$('devicesPage').hidden ? 'devices' : 'dashboard')
    };
    $("dashboardPage").hidden = true;
    $("settingsPage").hidden = true;
    $("devicesPage").hidden = true;
    $("featurePage").hidden = false;
    modal.classList.add("inline-feature");
    $("featurePage").appendChild(modal);
    scrollTo({ top: 0, behavior: "smooth" });
    scheduleDialogActions();
  }
  function hideInline(backdropId) {
    if (!inlineFeature || inlineFeature.id !== backdropId) {
      $(backdropId)?.classList.remove("show");
      return;
    }
    const item = inlineFeature;
    item.modal.classList.remove("inline-feature");
    item.parent.insertBefore(item.modal, item.next && item.next.parentNode === item.parent ? item.next : null);
    $("featurePage").hidden = true;
    inlineFeature = null;
    if (item.returnPage === "settings") openSettings();
    else if (item.returnPage === "devices") openDevices();
    else showDashboard();
  }
  function featureOpen(backdropId) { return inlineFeature?.id === backdropId || $(backdropId)?.classList.contains("show"); }
  let dialogActionFrame = 0;
  function dialogActionsWidth(foot) {
    const style = getComputedStyle(foot);
    const visible = [...foot.children].filter(el => !el.hidden && !el.classList.contains("folded-action"));
    const gap = parseFloat(style.columnGap || style.gap) || 0;
    return (parseFloat(style.paddingLeft) || 0) + (parseFloat(style.paddingRight) || 0) +
      visible.reduce((sum, el) => sum + el.getBoundingClientRect().width, 0) + gap * Math.max(0, visible.length - 1);
  }
  function layoutDialogActions(foot) {
    if (!foot || !foot.offsetParent) return;
    const more = foot.querySelector(".action-overflow");
    const buttons = [...foot.querySelectorAll(":scope > .btn:not(.action-overflow)")];
    buttons.forEach(button => button.classList.remove("folded-action"));
    more.hidden = true;
    const visible = buttons.filter(button => !button.hidden);
    if (dialogActionsWidth(foot) <= foot.clientWidth + 1) return;
    more.hidden = false;
    // Preserve the primary/right-most action. Fold secondary actions from the
    // left until the title-bar toolbar fits on one line.
    const keep = new Set([...visible.filter(button => button.classList.contains("primary")), visible[visible.length - 1]]);
    const foldable = visible.filter(button => !keep.has(button)).concat(visible.filter(button => keep.has(button) && !button.classList.contains("primary") && button !== visible[visible.length - 1]));
    while (dialogActionsWidth(foot) > foot.clientWidth + 1 && foldable.length) foldable.shift().classList.add("folded-action");
  }
  function scheduleDialogActions() {
    cancelAnimationFrame(dialogActionFrame);
    dialogActionFrame = requestAnimationFrame(() => {
      document.querySelectorAll(".backdrop.show .modal > .foot, #featurePage > .modal > .foot, .device-page:not([hidden]) > .foot").forEach(layoutDialogActions);
    });
  }
  function setupDialogActionFolding() {
    const resizeObserver = new ResizeObserver(entries => entries.forEach(entry => layoutDialogActions(entry.target)));
    document.querySelectorAll(".modal > .foot, .device-page > .foot").forEach(foot => {
      const more = document.createElement("button");
      more.type = "button"; more.className = "btn ghost action-overflow"; more.textContent = "⋯";
      more.setAttribute("aria-label", pick("More actions", "Thêm tác vụ")); more.hidden = true;
      more.onclick = e => {
        e.stopPropagation(); layoutDialogActions(foot);
        const folded = [...foot.querySelectorAll(":scope > .folded-action")].filter(button => !button.hidden && !button.disabled);
        if (!folded.length) return;
        const rect = more.getBoundingClientRect();
        openContextMenu(rect.right, rect.bottom, folded.map(button => ({
          label: button.textContent.trim(), danger: button.classList.contains("danger"), run: () => button.click()
        })));
      };
      foot.prepend(more); resizeObserver.observe(foot);
      const surface = foot.closest(".backdrop") || foot.closest("#featurePage") || foot.closest(".device-page");
      if (surface) new MutationObserver(scheduleDialogActions).observe(surface, { attributes: true, attributeFilter: ["class", "hidden"] });
    });
  }
  function closeContextMenu() { $("contextMenu").hidden = true; }
  function openContextMenu(x, y, items) {
    const menu = $("contextMenu");
    menu.replaceChildren();
    items.filter(item => !item.hidden).forEach(item => {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = item.label;
      if (item.danger) button.className = "danger";
      button.onclick = e => { e.stopPropagation(); closeContextMenu(); item.run(); };
      menu.appendChild(button);
    });
    menu.hidden = false;
    const rect = menu.getBoundingClientRect();
    const opensLeft = x + rect.width + 6 > innerWidth;
    const opensUp = y + rect.height + 6 > innerHeight;
    const left = opensLeft ? x - rect.width - 2 : x + 2;
    const top = opensUp ? y - rect.height - 2 : y + 2;
    menu.style.left = Math.max(6, Math.min(left, innerWidth - rect.width - 6)) + "px";
    menu.style.top = Math.max(6, Math.min(top, innerHeight - rect.height - 6)) + "px";
    menu.style.transformOrigin = `${opensLeft ? "right" : "left"} ${opensUp ? "bottom" : "top"}`;
    menu.querySelector("button")?.focus({ preventScroll: true });
  }
  function bindLongPress(root, selector, callback) {
    let timer = null, startX = 0, startY = 0;
    const cancel = () => { clearTimeout(timer); timer = null; };
    root.addEventListener("pointerdown", e => {
      if (e.pointerType === "mouse" || e.target.closest("button,input,select,a")) return;
      const target = e.target.closest(selector);
      if (!target) return;
      startX = e.clientX; startY = e.clientY;
      timer = setTimeout(() => { timer = null; callback(target, startX, startY); }, 550);
    });
    root.addEventListener("pointermove", e => {
      if (timer && (Math.abs(e.clientX - startX) > 10 || Math.abs(e.clientY - startY) > 10)) cancel();
    });
    ["pointerup", "pointercancel", "pointerleave"].forEach(name => root.addEventListener(name, cancel));
  }
  function deviceByKey(key) { return devicesData.find(c => deviceKey(c.idx, c.mac) === key); }
  function selectContextDevice(key) {
    if (!deviceSelected.has(key)) { deviceSelected.clear(); deviceSelected.add(key); renderDevices(); }
    return deviceByKey(key);
  }
  function runDeviceContext(action, device) {
    if (deviceSelected.size > 1) {
      $("devBulkAction").value = action; updateDeviceSelection(); runDeviceBulk();
    } else deviceAction(action, device.idx, device.mac);
  }
  function showDeviceContext(target, x, y) {
    const device = selectContextDevice(target.dataset.key);
    if (!device) return;
    const contextDevices = selectedDevices();
    const oneSsid = contextDevices.length > 0 && new Set(contextDevices.map(c => c.idx)).size === 1;
    openContextMenu(x, y, [
      { label: pick("Details", "Chi tiết"), run: () => deviceDetails(device.idx, device.mac) },
      { label: pick("Add proxies & distribute", "Thêm proxy & phân phối"), hidden: !oneSsid, run: openDeviceProxyBatch },
      { label: pick("Disconnect selected", "Ngắt mục đã chọn"), hidden: !device.online, run: () => runDeviceContext("kick", device) },
      { label: pick("Unblock selected", "Bỏ cấm mục đã chọn"), hidden: !device.banned, run: () => runDeviceContext("unban", device) },
      { label: pick("Block selected", "Cấm mục đã chọn"), hidden: device.banned, danger: true, run: () => runDeviceContext("ban", device) }
    ]);
  }
  function selectContextPool(slot) {
    if (!poolSelected.has(slot)) { poolSelected.clear(); poolSelected.add(slot); renderPoolList(); }
  }
  function showPoolContext(target, x, y) {
    const slot = Number(target.dataset.poolRow);
    if (!Number.isInteger(slot)) return;
    selectContextPool(slot);
    openContextMenu(x, y, [
      { label: pick("Test selected", "Test mục đã chọn"), run: () => testPoolSlots(poolSelected) },
      { label: pick("Edit this proxy", "Sửa proxy này"), run: () => beginPoolEdit([slot]) },
      { label: pick("Delete selected", "Xóa mục đã chọn"), danger: true, run: () => {
        deletePoolSlots([...poolSelected]);
      } }
    ]);
  }
  function openModal(id) {
    editId = id;
    const s = id ? ssids.find(x => x.id === id) : null;
    $("modalTitle").textContent = s ? pick("Edit Wi-Fi", "Sửa WiFi") : pick("Add Wi-Fi", "Thêm WiFi");
    $("f_name").value = s ? s.name : "";
    $("f_band").value = s ? s.band : "2g";
    $("f_idx").value = s ? s.idx : nextIdx();
    $("f_key").value = s ? s.key : "";
    $("f_subnet").value = s ? (s.local_subnet || "") : "";
    // Pool-only mode: the SSID form never pre-fills or persists an upstream
    // address. Proxy credentials are edited in the Pool dialog.
    $("f_host").value = "";
    $("f_proxy_type").value = "socks5";
    $("f_proxy_compact").value = "";
    $("f_port").value = "";
    $("f_user").value = "";
    $("f_pass").value = "";
    $("f_isolate").checked = s ? !!s.isolate : true;
    $("f_webrtc").value = String(s ? webrtcMode(s.webrtc) : WEBRTC_BLOCK);
    updateWebrtcHint();
    $("f_vendor").value = s ? (s.mac_oui || "") : "";
    $("f_err").textContent = "";
    $("probeBtn").hidden = !agent.connected;
    updateDerived();
    showInline("backdrop");
    $("f_name").focus();
  }
  function closeModal() { hideInline("backdrop"); editId = null; }

  function updateDerived() {
    const i = parseInt($("f_idx").value, 10);
    const oui = $("f_vendor").value;
    const macTxt = oui ? `${oui}:xx:xx:xx (${vendorName(oui)})` : "02:xx (locally-administered)";
    $("f_derived").textContent = isFinite(i)
      ? `→ subnet ${subnet(i)} · gateway ${gw(i)} · bridge br-w${i} · tproxy :${tport(i)} · MAC ${macTxt}`
      : "";
  }

  function saveForm() {
    if (!agent.connected) return $("f_err").textContent = pick("Connect to the router before changing Wi-Fi.", "Hãy kết nối router trước khi đổi WiFi.");
    if (configApplying) return $("f_err").textContent = pick("Wait for the current apply to finish.", "Hãy chờ lần apply hiện tại hoàn tất.");
    const previous = ssids.map(s => ({ ...s }));
    const name = $("f_name").value.trim();
    const band = $("f_band").value;
    const idx = parseInt($("f_idx").value, 10);
    const key = $("f_key").value.trim();
    const local_subnet = $("f_subnet").value.trim();
    const host = "";
    const port = "";
    const user = "";
    const pass = "";
    const proxy_type = "socks5";
    const err = m => { $("f_err").textContent = m; return false; };

    if (!name) return err(pick("Wi-Fi name is required.", "Thiếu tên WiFi."));
    if (/[|]/.test(name)) return err(pick("Wi-Fi name must not contain '|'.", "Tên WiFi không được chứa ký tự '|'."));
    if (!isFinite(idx) || idx < 1) return err(pick("idx must be a number ≥ 1.", "idx phải là số ≥ 1."));
    if (ssids.some(s => s.idx === idx && s.id !== editId)) return err(pick(`idx ${idx} is already used by another Wi-Fi.`, `idx ${idx} đã dùng cho WiFi khác.`));
    if (key.length < 8) return err(pick("Wi-Fi password must contain at least 8 characters (WPA2).", "Mật khẩu WiFi phải ≥ 8 ký tự (WPA2)."));
    if (local_subnet && !/^(10\.(?:\d{1,3}\.){2}|172\.(?:1[6-9]|2\d|3[01])\.(?:\d{1,3}\.)|192\.168\.(?:\d{1,3})\.)0\/24$/.test(local_subnet)) return err(pick("Local subnet must be a private IPv4 /24 (for example 10.50.7.0/24).", "Dải local phải là IPv4 private /24 (ví dụ 10.50.7.0/24)."));
    if (local_subnet && ssids.some(s => s.local_subnet === local_subnet && s.id !== editId)) return err(pick("This local subnet is already used by another Wi-Fi.", "Dải local này đã được WiFi khác sử dụng."));
    const mac_oui = $("f_vendor").value;
    if (mac_oui && !/^[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}$/.test(mac_oui)) return err(pick("mac_oui must look like AA:BB:CC.", "mac_oui phải dạng AA:BB:CC."));

    const rec = { name, band, idx, key, host, port: String(port), user, pass, proxy_type, local_subnet, isolate: $("f_isolate").checked, webrtc: webrtcMode($("f_webrtc").value), mac_oui };
    const before = editId ? ssids.find(x => x.id === editId) : null;
    if (editId) { Object.assign(before, rec); }
    else { rec.id = "s" + idx + "_" + Math.floor(performance.now()); ssids.push(rec); }
    configDirty = true;
    const wasEditing = !!editId;
    closeModal(); render();
    autoApplyConfig(previous, wasEditing ? pick("Updated and applied", "Đã cập nhật và apply") : pick("Wi-Fi added and applied", "Đã thêm WiFi và apply"));
  }

  function fillCompactProxy() {
    const value = $("f_proxy_compact").value.trim();
    const match = value.match(/^([^:]+):(\d+):([^:]*):(.*)$/);
    if (!match) {
      $("f_err").textContent = pick("Enter the proxy as host:port:user:password.", "Nhập proxy theo dạng host:port:user:password.");
      return;
    }
    const port = Number(match[2]);
    if (port < 1 || port > 65535) {
      $("f_err").textContent = pick("Invalid proxy port.", "Cổng proxy không hợp lệ.");
      return;
    }
    $("f_host").value = match[1].trim();
    $("f_port").value = String(port);
    $("f_user").value = match[3].trim();
    $("f_pass").value = match[4].trim();
    $("f_err").textContent = "";
  }

  // ---- import ----
  function parseConfInto(txt) {
    const rows = [];
    const seenIdx = new Set();
    txt.split(/\r?\n/).forEach(line => {
      const l = line.trim();
      if (!l || l.startsWith("#")) return;
      const p = l.split("|");
      if (p.length < 4) return;
      const idx = parseInt(p[2], 10);
      if (!isFinite(idx)) return;
      // The router accepts one row per idx. Ignore stale duplicate rows when
      // importing/pulling so a later push cannot reproduce them in the UI.
      if (seenIdx.has(idx)) return;
      seenIdx.add(idx);
      rows.push({
        id: "s" + idx + "_" + rows.length,
        name: p[0].trim(), band: (p[1] || "2g").trim(), idx,
        key: (p[3] || "").trim(), host: (p[4] || "").trim(), port: (p[5] || "1080").trim(),
        user: (p[6] || "").trim(), pass: (p[7] || "").trim(),
        isolate: (p[8] || "1").trim() === "1", webrtc: webrtcMode((p[9] || "0").trim()),
        mac_oui: (p[10] || "").trim(), proxy_type: (p[11] || "socks5").trim().toLowerCase(), local_subnet: (p[12] || "").trim()
      });
    });
    ssids = rows;
    configDirty = false;
    return rows.length;
  }
  function importConf() {
    if (!agent.connected) return toast(pick("Connect to the router before importing.", "Hãy kết nối router trước khi nhập cấu hình."));
    const previous = ssids.map(s => ({ ...s }));
    const txt = prompt(pick("Paste the contents of wifi-socks.conf:", "Dán nội dung wifi-socks.conf:"));
    if (!txt) return;
    const n = parseConfInto(txt);
    configDirty = true;
    if (!n) return toast(pick("No valid Wi-Fi rows were found.", "Không đọc được dòng WiFi nào."));
    render(); autoApplyConfig(previous, pick(`Imported and applied ${n} Wi-Fi row(s)`, `Đã nhập và apply ${n} WiFi`));
  }

  // ---- download / copy ----
  function download(fname, text) {
    const b = new Blob([text], { type: "text/plain" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(b); a.download = fname; a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }
  function copy(text) {
    navigator.clipboard.writeText(text).then(() => toast(pick("Copied", "Đã copy")), () => toast(pick("Copy failed", "Không copy được")));
  }
  let toastT;
  function toast(m) {
    const el = $("toast"); el.textContent = m; el.classList.add("show");
    clearTimeout(toastT); toastT = setTimeout(() => el.classList.remove("show"), 1600);
  }

  // ---- theme ----
  function initTheme() {
    const saved = localStorage.getItem("sbproxy.theme");
    if (saved) document.documentElement.setAttribute("data-theme", saved);
    updateThemeButton();
  }
  // "Theme" told nobody what pressing it would do. The button names the
  // theme it switches TO, which is also how the operator learns there is one.
  function updateThemeButton() {
    const button = document.getElementById("themeBtn");
    if (!button) return;
    const dark = (document.documentElement.getAttribute("data-theme") || "dark") === "dark";
    button.textContent = dark ? pick("☀ Light", "☀ Sáng") : pick("🌙 Dark", "🌙 Tối");
  }
  function toggleTheme() {
    // Dark is the default skin now, so an unset attribute means dark and the
    // first click has to go to light -- otherwise it appears to do nothing.
    const cur = document.documentElement.getAttribute("data-theme") || "dark";
    const next = cur === "dark" ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", next);
    localStorage.setItem("sbproxy.theme", next);
    updateThemeButton();
  }

  setupConfigToolbar();
  setupDevicesPage();

  // ---- events ----
  $("configBtn").onclick = showDashboard;
  $("addBtn").onclick = () => openModal(null);
  $("saveBtn").onclick = saveForm;
  $("cancelBtn").onclick = closeModal;
  $("backdrop").onclick = e => { if (e.target.id === "backdrop") closeModal(); };
  $("f_idx").oninput = updateDerived;
  $("f_subnet").oninput = updateDerived;
  $("f_vendor").onchange = updateDerived;
  $("f_webrtc").onchange = updateWebrtcHint;
  $("parseProxyBtn").onclick = fillCompactProxy;
  $("f_proxy_compact").onkeydown = e => { if (e.key === "Enter") { e.preventDefault(); fillCompactProxy(); } };
  $("languageSelect").onchange = e => setLanguage(e.target.value);
  $("themeBtn").onclick = toggleTheme;
  $("loginAccountTab").onclick = () => setLoginMethod("account");
  $("loginTokenTab").onclick = () => setLoginMethod("token");
  setLoginMethod("account");
  $("outputToggle").onclick = () => {
    const output = $("configOutput");
    output.hidden = !output.hidden;
    $("outputToggle").textContent = `${output.hidden ? "⌄" : "⌃"} Configuration preview`;
  };
  $("importBundleBtn").onclick = importBundle;
  $("exportBundleBtn").onclick = exportBundle;
  $("bundleFile").onchange = handleBundleFile;
  $("copyBtn").onclick = () => copy(TABS[curTab].gen());
  $("clearBtn").onclick = resetEverything;

  // live mode events
  $("connBtn").onclick = () => {
    $("c_base").value = agent.base; $("c_token").value = agent.token; $("c_user").value = agent.user;
    $("cpBtn").hidden = !agent.connected;
    if (!agent.connected) setConnStatus(pick("Not connected. Log in with the sbproxy account.", "Chưa kết nối. Đăng nhập bằng tài khoản sbproxy."));
    showInline("connBackdrop");
  };
  $("connectBtn").onclick = connect;
  $("sbChip").onclick = () => {
    const sb = agent.singbox;
    if (sb && (!sb.running || sb.flapping)) restartSingbox(); else poll();
  };
  $("stats").onclick = e => { if (e.target.closest("#sbCard") && agent.connected) restartSingbox(); };
  $("disconnectBtn").onclick = disconnect;
  $("logoutBtn").onclick = logout;
  $("authLogoutBtn").onclick = logout;
  $("menuBtn").onclick = () => $("layout").classList.toggle("side-open");
  $("sidebar").onclick = e => {
    const button = e.target.closest("button");
    const workspaceNav = ["devicesBtn", "settingsBtn", "configBtn"];
    if (button && !workspaceNav.includes(button.id)) closeDevices();
    if (button && !workspaceNav.includes(button.id)) {
      $("sidebar").querySelectorAll(".action-active").forEach(el => el.classList.remove("action-active"));
      button.classList.add("action-active");
    }
    if (button && matchMedia("(max-width: 920px)").matches) {
      $("layout").classList.remove("side-open");
    }
  };
  $("probeBtn").onclick = probeFromForm;
  $("setupGo").onclick = submitSetup;
  $("setupCancel").onclick = () => hideInline("setupBackdrop");
  $("setupBackdrop").onclick = e => { if (e.target.id === "setupBackdrop") hideInline("setupBackdrop"); };
  $("cpBtn").onclick = openChangePassword;
  $("cpGo").onclick = submitChangePassword;
  $("cpCancel").onclick = () => hideInline("cpBackdrop");
  $("cpBackdrop").onclick = e => { if (e.target.id === "cpBackdrop") hideInline("cpBackdrop"); };
  $("connCancel").onclick = () => hideInline("connBackdrop");
  $("connBackdrop").onclick = e => { if (e.target.id === "connBackdrop") hideInline("connBackdrop"); };
  $("devicesBtn").onclick = openDevices;
  $("devClose").onclick = closeDevices;
  $("devRefresh").onclick = loadDevices;
  // Filtering and sorting work on the payload already in hand; only Refresh
  // and the timer go back to the router.
  $("devSearch").oninput = renderDevices;
  $("devSsidFilter").onchange = renderDevices;
  $("devStateFilter").onchange = renderDevices;
  $("devAuto").onchange = scheduleDeviceRefresh;
  $("devInterval").onchange = scheduleDeviceRefresh;
  $("devCsv").onclick = exportDevicesCsv;
  $("devBan").onclick = manualBan;
  $("devBulkAction").onchange = updateDeviceSelection;
  $("devBulkRun").onclick = runDeviceBulk;
  $("devProxySave").onclick = submitDeviceProxyBatch;
  $("devProxyCancel").onclick = closeDeviceProxyBatch;
  $("devProxyBackdrop").onclick = e => { if (e.target.id === "devProxyBackdrop") closeDeviceProxyBatch(); };
  $("devSelectAll").onchange = e => {
    visibleDevices().forEach(c => {
      const key = deviceKey(c.idx, c.mac);
      if (e.target.checked) deviceSelected.add(key); else deviceSelected.delete(key);
    });
    renderDevices();
  };
  $("devicesPage").querySelector("thead").onclick = e => {
    const key = e.target.getAttribute("data-sort");
    if (!key) return;
    devSort = { key, desc: devSort.key === key ? !devSort.desc : false };
    renderDevices();
  };
  $("devBackdrop").onclick = e => { if (e.target.id === "devBackdrop") closeDevices(); };
  $("poolClose").onclick = closePool;
  $("poolBackdrop").onclick = e => { if (e.target.id === "poolBackdrop") closePool(); };
  $("poolSave").onclick = addPoolLines;
  $("poolEditCancel").onclick = cancelPoolEdit;
  $("poolClear").onclick = clearPool;
  $("poolTest").onclick = testAllPool;
  $("poolRebalance").onclick = rebalancePoolClients;
  $("poolRefresh").onclick = () => loadPool();
  $("poolMore").onclick = () => { poolExpanded = !poolExpanded; renderPoolList(); };
  $("poolBulkAction").onchange = updatePoolSelection;
  $("poolBulkRun").onclick = runPoolBulk;
  $("poolSelectAll").onchange = e => {
    const count = poolExpanded ? activePool.length : Math.min(2, activePool.length);
    for (let i = 0; i < count; i++) {
      if (e.target.checked) poolSelected.add(i); else poolSelected.delete(i);
    }
    renderPoolList();
  };
  $("poolRows").onclick = e => {
    const checkbox = e.target.closest("[data-pool-select]");
    if (!checkbox) return;
    const slot = Number(checkbox.dataset.poolSelect);
    if (checkbox.checked) poolSelected.add(slot); else poolSelected.delete(slot);
    renderPoolList();
  };
  $("devRows").onclick = e => {
    const checkbox = e.target.closest("[data-device-select]");
    if (checkbox) {
      const key = checkbox.dataset.deviceSelect;
      if (checkbox.checked) deviceSelected.add(key); else deviceSelected.delete(key);
      renderDevices();
      return;
    }
    const button = e.target.closest("button");
    if (!button) return;
    const k = button.getAttribute("data-kick");
    const b = button.getAttribute("data-ban");
    const u = button.getAttribute("data-unban");
    const p = button.getAttribute("data-proxy");
    const info = button.getAttribute("data-detail");
    const idx = parseInt(button.getAttribute("data-idx"), 10);
    if (info) return deviceDetails(idx, info);
    if (p) return changeClientProxy(idx, p);
    if (k) return deviceAction("kick", idx, k);
    if (b) return deviceAction("ban", idx, b);
    if (u) return deviceAction("unban", idx, u);
  };
  $("devRows").oncontextmenu = e => {
    const row = e.target.closest("tr[data-key]");
    if (!row) return;
    e.preventDefault(); showDeviceContext(row, e.clientX, e.clientY);
  };
  $("poolRows").oncontextmenu = e => {
    const row = e.target.closest("[data-pool-row]");
    if (!row) return;
    e.preventDefault(); showPoolContext(row, e.clientX, e.clientY);
  };
  bindLongPress($("devRows"), "tr[data-key]", showDeviceContext);
  bindLongPress($("poolRows"), "[data-pool-row]", showPoolContext);
  $("pullBtn").onclick = pullFromRouter;
  $("upBtn").onclick = openUpdate;
  $("topUpBtn").onclick = openUpdate;
  $("upGo").onclick = doUpdate;
  $("upCancel").onclick = () => hideInline("upBackdrop");
  $("upBackdrop").onclick = e => { if (e.target.id === "upBackdrop") hideInline("upBackdrop"); };
  $("dailyLogBtn").onclick = openDailyLogs;
  $("dailyLogRefresh").onclick = () => loadDailyLogs($("dailyLogDate").value);
  $("dailyLogDate").onchange = e => loadDailyLogs(e.target.value);
  $("dailyLogCopy").onclick = () => copy($("dailyLogBox").textContent);
  $("dailyLogDownload").onclick = downloadDailyLogs;
  $("debugBtn").onclick = openDebug;
  $("debugRun").onclick = loadDebug;
  $("debugClose").onclick = () => hideInline("debugBackdrop");
  $("debugBackdrop").onclick = e => { if (e.target.id === "debugBackdrop") hideInline("debugBackdrop"); };
  $("debugRows").onclick = e => {
    const button = e.target.closest("button[data-fix]");
    if (button) runDebugFix(button.getAttribute("data-fix"));
  };
  $("dailyLogClose").onclick = () => hideInline("dailyLogBackdrop");
  $("dailyLogBackdrop").onclick = e => { if (e.target.id === "dailyLogBackdrop") hideInline("dailyLogBackdrop"); };
  $("gwBtn").onclick = openGateway;
  $("topGwBtn").onclick = openGateway;
  $("resetAllBtn").onclick = resetEverything;
  $("settingsBtn").onclick = openSettings;
  $("settingsRefresh").onclick = refreshSettings;
  $("poolUnassignedSave").onclick = savePoolUnassigned;
  $("settingsHealth").onclick = runSettingsHealth;
  $("settingsRestart").onclick = restartSingbox;
  $("settingsGatewayOpen").onclick = openGateway;
  $("settingsDiagRun").onclick = runSettingsDiagnosis;
  $("settingsLogs").onclick = openDailyLogs;
  $("settingsBackup").onclick = openRollback;
  $("settingsUpdate").onclick = openUpdate;
  $("settingsConnect").onclick = () => $("connBtn").click();
  $("analyticsRestartBtn").onclick = restartSingbox;
  $("gwRefresh").onclick = loadGateway;
  $("gwPin").onclick = pinGateway;
  $("gwAuto").onclick = unpinGateway;
  $("gwSwitch").onclick = switchGateway;
  $("gwClose").onclick = () => hideInline("gwBackdrop");
  $("gwBackdrop").onclick = e => { if (e.target.id === "gwBackdrop") hideInline("gwBackdrop"); };
  $("rbBtn").onclick = openRollback;
  $("topRbBtn").onclick = openRollback;
  $("rbClose").onclick = () => hideInline("rbBackdrop");
  $("rbBackupNow").onclick = backupNow;
  $("rbBackdrop").onclick = e => { if (e.target.id === "rbBackdrop") hideInline("rbBackdrop"); };
  $("rbList").onclick = e => {
    const r = e.target.getAttribute("data-restore");
    const d = e.target.getAttribute("data-dl");
    if (r) return restore(r);
    if (d) return downloadBackup(d);
  };
  $("logClose").onclick = () => hideInline("logBackdrop");
  $("logRetry").onclick = () => {
    if (!logRetryAction) return;
    const retry = logRetryAction;
    logRetryAction = null;
    const button = $("logRetry");
    button.disabled = true;
    button.classList.add("loading");
    button.textContent = pick("Retrying…", "Đang thử lại…");
    retry().catch(() => {});
  };
  $("logBackdrop").onclick = e => { if (e.target.id === "logBackdrop") hideInline("logBackdrop"); };

  document.getElementById("rows").onclick = e => {
    const ed = e.target.getAttribute("data-edit");
    const du = e.target.getAttribute("data-dup");
    const de = e.target.getAttribute("data-del");
    const zp = e.target.getAttribute("data-zap");
    const dg = e.target.getAttribute("data-diag");
    const po = e.target.getAttribute("data-pool");
    const mc = e.target.getAttribute("data-mac");
    if (po) return openPool(parseInt(po, 10));
    if (mc) return rotateMac(parseInt(mc, 10));
    if (dg) return diagnoseSsid(parseInt(dg, 10));
    if (zp) return zapSock(ssids.find(x => x.id === zp));
    if (ed) return openModal(ed);
    if (du) {
      if (!agent.connected) return toast(pick("Connect to the router before changing Wi-Fi.", "Hãy kết nối router trước khi đổi WiFi."));
      const previous = ssids.map(x => ({ ...x }));
      const s = ssids.find(x => x.id === du);
      const clone = { ...s, id: "s" + Date.now(), idx: nextIdx(), name: s.name + "-copy" };
      ssids.push(clone); configDirty = true; render(); autoApplyConfig(previous, pick("Duplicated and applied", "Đã nhân bản và apply"));
    }
    if (de) {
      const s = ssids.find(x => x.id === de);
      if (!agent.connected) return toast(pick("Connect to the router before deleting Wi-Fi.", "Hãy kết nối router trước khi xoá WiFi."));
      if (confirm(pick(`Delete Wi-Fi "${s.name}" and apply immediately? Connected devices will disconnect.`, `Xoá WiFi "${s.name}" và apply ngay? Thiết bị đang dùng sẽ mất kết nối.`))) {
        const previous = ssids.map(x => ({ ...x }));
        ssids = ssids.filter(x => x.id !== de); configDirty = true; render();
        autoApplyConfig(previous, pick("Wi-Fi deleted and applied", "Đã xoá WiFi và apply"));
      }
    }
  };

  document.getElementById("outTabs").onclick = e => {
    const t = e.target.getAttribute("data-t"); if (!t) return;
    curTab = t;
    document.querySelectorAll(".tab").forEach(b => b.classList.toggle("active", b.getAttribute("data-t") === t));
    renderOutput();
  };

  document.addEventListener("pointerdown", e => { if (!e.target.closest("#contextMenu")) closeContextMenu(); });
  addEventListener("resize", closeContextMenu);
  document.addEventListener("scroll", closeContextMenu, true);
  document.addEventListener("keydown", e => {
    if (e.key === "Escape") {
      closeContextMenu(); closeModal();
      if (featureOpen("devProxyBackdrop")) closeDeviceProxyBatch();
    }
    if (e.key === "Enter" && featureOpen("backdrop") && e.target.tagName === "INPUT") saveForm();
  });

  // ---- seed demo on first run ----
  if (!ssids.length && !localStorage.getItem("sbproxy.seeded")) {
    localStorage.setItem("sbproxy.seeded", "1");
    ssids = [
      { id: "s1", name: "Alpha", band: "2g", idx: 1, key: "Alpha_pass_123", host: "1.2.3.4", port: "1080", user: "user1", pass: "pass1", isolate: true, webrtc: true, mac_oui: "50:C7:BF" },
      { id: "s2", name: "Bravo", band: "2g", idx: 2, key: "Bravo_pass_123", host: "5.6.7.8", port: "1080", user: "user2", pass: "pass2", isolate: true, webrtc: true, mac_oui: "20:E5:2A" },
      { id: "s3", name: "Charlie", band: "5g", idx: 3, key: "Charlie_pass_123", host: "9.9.9.9", port: "1080", user: "", pass: "", isolate: true, webrtc: false, mac_oui: "" }
    ];
  }

  // A stored token is only a credential cache, not an authenticated session.
  // Require an explicit login on every page load so nobody can see router
  // data merely by opening a browser that was used by someone else.
  function initAgent() {
    updateLiveUI();
    if (!agent.token) {
      // First run: when the router has no web account at all, open the
      // setup form right away instead of a login that can only fail.
      fetch(apiUrl("login_state")).then(readJson).then(d => {
        if (d && d.ok && d.account_configured === false) openSetup();
      }).catch(() => {});
      return;
    }
    // Restore the saved session after a full page refresh. The auth gate stays
    // visible while this request is pending, so router data never flashes.
    setConnStatus(pick("Restoring your session…", "Đang khôi phục phiên đăng nhập…"));
    api("status").then(d => {
      if (!d || !d.ok) throw new Error((d && d.error) || pick("session expired", "phiên đăng nhập đã hết hạn"));
      agent.connected = true;
      agent.health = (d.health && d.health.probes) || {};
      agent.version = (d.meta && d.meta.version) || "";
      applyRouterSettings(d.meta);
      updateLiveUI(); renderRows(); startPoll(); syncAuthenticatedWorkspace();
    }).catch(() => {
      agent.connected = false;
      updateLiveUI();
      setConnStatus(pick("Sign in to continue.", "Đăng nhập để tiếp tục."));
    });
  }

  // Populate the MAC vendor dropdown once.
  function renderVendorOptions() {
    const keep = $("f_vendor").value;
    $("f_vendor").innerHTML = VENDORS.map(v =>
      `<option value="${v.oui}">${esc(vendorLabel(v))}${v.oui ? " · " + v.oui : ""}</option>`
    ).join("");
    $("f_vendor").value = keep;
  }

  // One page, one workspace at a time. The workspace is the URL fragment, so a
  // bookmark, a reload and the back button all land where the operator was,
  // without the router having to serve a file per entry point -- those were
  // eight copies of this same shell, and they drifted four releases apart.
  const SPA_PAGES = ["config", "devices", "analytics", "settings", "status", "egress", "diagnose", "maintenance"];
  function spaPageFromLocation() {
    const hash = decodeURIComponent((location.hash || "").replace(/^#/, "")).toLowerCase();
    if (SPA_PAGES.includes(hash)) return hash;
    // Bookmarks and router deployments from before the fragment router still
    // point at <page>.html; honour them so an old link is not a dead end.
    const file = (location.pathname.split("/").pop() || "").toLowerCase().replace(/\.html$/, "");
    return SPA_PAGES.includes(file) ? file : "config";
  }
  function setupSinglePage() {
    let page = spaPageFromLocation();
    document.body.dataset.page = page;
    const settingsPages = ["settings", "status", "egress", "diagnose", "maintenance"];
    function setWorkspace(next) {
      page = next;
      document.body.dataset.page = page;
      $("dashboardPage").hidden = page !== "config";
      $("analyticsPage").hidden = page !== "analytics";
      $("settingsPage").hidden = !settingsPages.includes(page);
      $("devicesPage").hidden = page !== "devices";
      $("featurePage").hidden = true;
      $("configBtn").classList.toggle("page-active", page === "config");
      $("devicesBtn").classList.toggle("page-active", page === "devices");
      $("settingsBtn").classList.toggle("page-active", page === "settings");
      document.querySelectorAll(".spa-link").forEach(link => {
        link.classList.toggle("page-active", link.dataset.spaPage === page);
      });
      if (page === "config") showDashboard();
      if (page === "devices") openDevices();
      if (page === "analytics") { renderAnalytics(); scrollTo({ top: 0, behavior: "smooth" }); }
      if (settingsPages.includes(page)) {
        openSettings();
        const cards = { status: "statusCard", egress: "egressCard", diagnose: "diagnoseCard", maintenance: "maintenanceCard" };
        $("settingsPage").querySelectorAll(".settings-card").forEach(card => {
          card.hidden = false;
          card.classList.toggle("page-focus", card.id === cards[page]);
          card.classList.toggle("is-collapsed", !!cards[page] && card.id !== cards[page]);
        });
      }
    }
    // Navigation goes through the fragment rather than calling setWorkspace
    // directly, so every route change -- button, link, typed URL, back button
    // -- arrives the same way and the URL never disagrees with the screen.
    const go = next => {
      if (spaPageFromLocation() === next) setWorkspace(next);
      else location.hash = next;
    };
    addEventListener("hashchange", () => setWorkspace(spaPageFromLocation()));
    $("configBtn").onclick = () => go("config");
    $("devicesBtn").onclick = () => go("devices");
    $("settingsBtn").onclick = () => go("settings");
    document.querySelectorAll(".spa-link").forEach(link => {
      link.onclick = event => { event.preventDefault(); go(link.dataset.spaPage); };
    });
    $("settingsPage").onclick = event => {
      const heading = event.target.closest(".settings-card h3");
      if (heading) heading.closest(".settings-card").classList.toggle("is-collapsed");
    };
    setWorkspace(page);
    // Focused pages use their own in-page actions; the old modal action list
    // is intentionally not shown as a second competing menu.
    $("liveTools").hidden = true;
  }
  setupSinglePage();
  renderVendorOptions();

  setupDialogActionFolding();
  initTheme();
  localizeStatic();
  render();
  initAgent();
  updateConnHint();
})();
