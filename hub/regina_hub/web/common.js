// Shared by the phone controller page and the desktop simulator page.
"use strict";

const RS = (() => {
  const PLAYER_COLORS = ["#8b93a7", "#3b82f6", "#ef4444", "#22c55e", "#f59e0b"];

  function store(key, fallback) {
    try {
      const v = localStorage.getItem(key);
      if (v) return v;
      localStorage.setItem(key, fallback);
    } catch (_) { /* private mode */ }
    return fallback;
  }

  function clientId(kind) {
    const rnd = Math.random().toString(36).slice(2, 10) + Date.now().toString(36).slice(-4);
    return store("rs-client-id-" + kind, rnd);
  }

  // --------------------------------------------------------------- language ----
  // The pages are written in Chinese; English comes from EN, keyed by that Chinese text.
  // The language follows the browser until the player picks one (kept on this device).
  // translatePage() swaps the page's own text once at load; text built in code uses t().
  const EN = {
    "玩家名字": "Player name",
    "同步到游戏中的玩家档案": "Sync to your in-game player profile",
    "保存": "Save",
    "Regina 手机手柄": "Regina Phone Controller",
    "Regina 模拟手柄": "Regina Simulator",
    "手机手柄": "Phone controller",
    "连接中…": "Connecting…",
    "已连接": "Connected",
    "重连中…": "Reconnecting…",
    "请重新扫码连接": "Scan the QR code again to connect",
    "延迟": "latency",
    "设置": "Settings",
    "长按归零": "Hold: recenter",
    "朝向归零": "Recenter",
    "手机顶端指向屏幕，点一下（也可以长按 D）": "Point the top of the phone at the screen and tap (or hold D)",
    "零偏校准": "Calibrate gyro",
    "把手机平放在桌上别动，再点": "Lay the phone flat on a table, keep it still, then tap",
    "重新识别陀螺仪": "Re-detect gyro axes",
    "手机转向不对时用，点完随意转动几秒": "If turning the phone moves things the wrong way: tap, then turn it around for a few seconds",
    "震动": "Vibration",
    "关": "Off",
    "弱": "Low",
    "中": "Mid",
    "强": "High",
    "击中、碰撞时会震": "Buzzes on hits and crashes",
    "iPhone 网页只能在按键时轻震（iOS 18 以上），游戏里的震动做不到": "On iPhone, web pages can only tick on button taps (iOS 18+), not buzz for game events",
    "这个浏览器不支持震动": "This browser can't vibrate",
    "语言": "Language",
    "全屏": "Fullscreen",
    "隐藏地址栏（iPhone：分享 › 添加到主屏幕）": "Hide the address bar (iPhone: Share › Add to Home Screen)",
    "把手机变成体感手柄": "Turn your phone into a motion controller",
    "像拿遥控器一样握住手机：屏幕朝上，顶端指向电视": "Hold the phone like a TV remote: screen up, top pointing at the TV",
    "大拇指按中间的 B，A 在上、C / D 在下，看按键上的提示": "Your thumb rests on B in the middle; A is above, C / D below — the buttons show what they do",
    "挥动时握紧手机，最好系上挂绳": "Grip it tight when you swing — a wrist strap is a good idea",
    "开始使用": "Start",
    "随意转动手机": "Turn the phone around",
    "正在识别这台手机的陀螺仪：左右转、前后翻、绕着转都来几下，几秒就好。": "Working out this phone's gyro: turn it left and right, tip it forward and back, spin it around. It only takes a few seconds.",
    "跳过": "Skip",
    "已归零": "Recentered",
    "零偏校准完成": "Gyro calibrated",
    "校准失败：把手机平放在桌上别动，再点一次校准": "Calibration failed: lay the phone flat on a table, keep it still and tap Calibrate again",
    "校准中：保持手机平放不动…": "Calibrating: keep the phone flat and still…",
    "陀螺仪轴向已自动修正 ✓": "Gyro axes corrected automatically ✓",
    "陀螺仪正常 ✓": "Gyro OK ✓",
    "传感器": "Sensor",
    "往返": "round trip",
    "陀螺仪映射": "gyro map",
    "（姿态对照）": " (from orientation)",
    "（重力对照）": " (from gravity)",
    "需要通过 https:// 打开本页才能读取陀螺仪。": "Open this page over https:// so it can read the gyro.",
    "没有获得运动传感器权限：请在 设置 › Safari › 高级 › 网站数据 里清除本站后重试，并允许“动作与方向”。": "No motion sensor permission: clear this site in Settings › Safari › Advanced › Website Data, try again and allow Motion & Orientation.",
    "请求权限失败：": "Permission request failed: ",
    "没有收到陀螺仪数据：这台设备可能没有陀螺仪，或者浏览器不支持。": "No gyro data: this device may not have a gyro, or the browser doesn't support it.",
    "模拟手柄": "Simulator",
    "（键盘 + 鼠标代替 Regina）": "(keyboard + mouse instead of a Regina)",
    "手柄 #": "Controller #",
    "姿态（拖动旋转，滚轮横滚）": "Orientation (drag to rotate, wheel to roll)",
    "正手挥拍": "Forehand",
    "反手挥拍": "Backhand",
    "过头下挥": "Overhead smash",
    "出拳": "Punch",
    "向上甩": "Flick up",
    "回到零姿态": "Back to zero",
    "油门": "Throttle",
    "按键": "Buttons",
    "R 长按归零": "R  hold: recenter",
    "D（长按 1 秒归零）": "D (hold 1 s to recenter)",
    "小旋钮": "Small dial",
    "大旋钮": "Big dial",
    "横滚": "Roll",
    "模拟数据带有轻微噪声和固定零偏，用来检验 hub 的自动校准。": "The simulated data has a little noise and a fixed gyro bias, to exercise the hub's auto-calibration.",
  };
  let lang = store("rs-lang", /^zh/i.test(navigator.language || "") ? "zh" : "en");
  function t(s) {
    return lang === "en" && EN[s] !== undefined ? EN[s] : s;
  }
  function translatePage() {
    if (lang !== "en") return;
    document.documentElement.lang = "en";
    document.title = t(document.title);
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      const s = n.nodeValue.trim();
      if (s && EN[s] !== undefined) n.nodeValue = n.nodeValue.replace(s, EN[s]);
    }
    for (const attr of ["aria-label", "data-default", "title"]) {
      document.querySelectorAll(`[${attr}]`).forEach((el) => el.setAttribute(attr, t(el.getAttribute(attr))));
    }
  }
  function setLang(l) {
    try { localStorage.setItem("rs-lang", l); } catch (_) { /* private mode */ }
    location.reload();
  }

  // ------------------------------------------------------------------ audio ----
  let audioCtx = null;
  function unlockAudio() {
    if (!audioCtx) {
      const Ctx = window.AudioContext || window.webkitAudioContext;
      if (Ctx) audioCtx = new Ctx();
    }
    if (audioCtx && audioCtx.state === "suspended") audioCtx.resume();
  }
  function beep(freq, ms) {
    if (!audioCtx) return;
    const t = audioCtx.currentTime;
    const osc = audioCtx.createOscillator();
    const gain = audioCtx.createGain();
    osc.type = "square";
    osc.frequency.value = Math.max(50, Math.min(8000, freq || 2000));
    gain.gain.setValueAtTime(0.0001, t);
    gain.gain.exponentialRampToValueAtTime(0.08, t + 0.005);
    gain.gain.exponentialRampToValueAtTime(0.0001, t + Math.max(0.02, (ms || 80) / 1000));
    osc.connect(gain).connect(audioCtx.destination);
    osc.start(t);
    osc.stop(t + (ms || 80) / 1000 + 0.05);
  }
  // -------------------------------------------------------------- vibration ----
  // Patterns are [on, off, on, ...] ms (navigator.vibrate's format). The player's strength
  // setting scales the pulses: the web can't set a motor's amplitude, but shorter pulses
  // feel weaker. iPhone Safari has no navigator.vibrate; there tick() falls back to the
  // haptic that iOS 18 gives a switch toggled from a tap, so only taps can be felt.
  const VIBE_SCALE = [0, 0.55, 1, 1.6];
  let vibeLevel = Math.max(0, Math.min(3, Number(store("rs-vibe", "2")) || 0));
  const canVibrate = typeof navigator.vibrate === "function";
  function setVibeLevel(level) {
    vibeLevel = Math.max(0, Math.min(3, level | 0));
    try { localStorage.setItem("rs-vibe", String(vibeLevel)); } catch (_) { /* private mode */ }
  }
  function vibrate(pattern) {
    if (!vibeLevel || !canVibrate) return;
    const pat = Array.isArray(pattern) ? pattern : [pattern || 50];
    const k = VIBE_SCALE[vibeLevel];
    const out = pat.map((v, i) => (i % 2 ? Math.max(0, v | 0) : Math.max(8, Math.min(1000, Math.round(v * k)))));
    try { navigator.vibrate(out); } catch (_) { /* ignore */ }
  }
  let iosSwitch = null;
  function tick() {
    // A light tap for a button press; call from the input event's handler.
    if (!vibeLevel) return;
    if (canVibrate) { vibrate(12); return; }
    if (!iosSwitch) {
      iosSwitch = document.createElement("label");
      iosSwitch.setAttribute("aria-hidden", "true");
      iosSwitch.style.display = "none";
      const input = document.createElement("input");
      input.type = "checkbox";
      input.setAttribute("switch", "");
      iosSwitch.appendChild(input);
      document.head.appendChild(iosSwitch);
    }
    try { iosSwitch.click(); } catch (_) { /* ignore */ }
  }

  // --------------------------------------------------------------- UI model ----
  // Mirrors the OLED UI the game sends (docs/protocol.md section 2.5 / 4.3).
  class UiView {
    constructor(root) {
      this.root = root;
      this.state = { title: "", main: "", sub: "", bar: null, legends: [null, null, null, null] };
      this.toastTimer = null;
      this.render();
    }
    apply(ui) {
      if (ui.clear) this.state = { title: "", main: "", sub: "", bar: null, legends: [null, null, null, null] };
      for (const k of ["title", "main", "sub"]) if (k in ui) this.state[k] = ui[k] || "";
      if ("bar" in ui) this.state.bar = ui.bar;
      if (ui.legends) ui.legends.forEach((v, i) => { if (v !== null && v !== undefined) this.state.legends[i] = v; });
      if (ui.toast) this.toast(ui.toast.text, ui.toast.ms);
      this.render();
    }
    toast(text, ms) {
      const el = this.root.querySelector(".ui-toast");
      el.textContent = text;
      el.classList.add("show");
      clearTimeout(this.toastTimer);
      this.toastTimer = setTimeout(() => el.classList.remove("show"), ms || 1000);
    }
    render() {
      const s = this.state;
      const q = (sel) => this.root.querySelector(sel);
      q(".ui-title").textContent = s.title || "Regina Sports";
      q(".ui-main").textContent = s.main;
      q(".ui-sub").textContent = s.sub;
      const bar = q(".ui-bar");
      if (s.bar) {
        bar.hidden = false;
        bar.querySelector(".ui-bar-fill").style.width = s.bar.pct + "%";
        bar.querySelector(".ui-bar-label").textContent = s.bar.label || "";
      } else {
        bar.hidden = true;
      }
      document.querySelectorAll("[data-legend]").forEach((el) => {
        const v = s.legends[Number(el.dataset.legend)];
        el.textContent = v || el.dataset.default || "";
      });
    }
  }

  // ------------------------------------------------------------- connection ----
  class HubConnection {
    constructor({ kind, name, profileName = "", onWelcome, onMessage, onState }) {
      this.kind = kind;
      this.name = name;
      this.profileName = profileName;
      this.clientId = clientId(kind);
      this.onWelcome = onWelcome || (() => {});
      this.onMessage = onMessage || (() => {});
      this.onState = onState || (() => {});
      this.ws = null;
      this.open = false;
      this.retry = 500;
      this.retryTimer = null;
      this.attempt = 0;
      this.connect();
    }
    async connect() {
      const attempt = ++this.attempt;
      if (this.retryTimer !== null) clearTimeout(this.retryTimer);
      this.retryTimer = null;
      this.open = false;
      if (this.ws) {
        const previous = this.ws;
        this.ws = null;
        previous.close();
      }
      this.onState("connecting");
      let token = new URLSearchParams(location.hash.slice(1)).get("k") || "";
      if (this.kind === "sim" && location.protocol === "http:" &&
          ["127.0.0.1", "localhost", "[::1]"].includes(location.hostname)) {
        try {
          const response = await fetch("/api/pairing", {
            credentials: "same-origin", cache: "no-store", redirect: "error",
          });
          if (attempt !== this.attempt) return;
          if (!response.ok) {
            if (response.status === 401 || response.status === 403) {
              this.onState("pair_required");
              return;
            }
            throw new Error("Pairing service unavailable");
          }
          token = (await response.json()).token;
        } catch (_) {
          if (attempt === this.attempt) this.reconnect();
          return;
        }
      }
      if (attempt !== this.attempt) return;
      if (typeof token !== "string" || !token) {
        this.onState("pair_required");
        return;
      }
      const proto = location.protocol === "https:" ? "wss" : "ws";
      let ws;
      try { ws = new WebSocket(`${proto}://${location.host}/ws`); }
      catch (_) { this.reconnect(); return; }
      this.ws = ws;
      ws.onopen = () => {
        if (this.ws !== ws) return;
        ws.send(JSON.stringify({ t: "hello", kind: this.kind, name: this.name,
          profile_name: this.profileName, client_id: this.clientId, token }));
      };
      ws.onmessage = (ev) => {
        if (this.ws !== ws) return;
        let msg;
        try { msg = JSON.parse(ev.data); } catch (_) { return; }
        if (!msg || typeof msg !== "object" || Array.isArray(msg)) return;
        if (msg.t === "welcome") {
          this.open = true;
          this.retry = 500;
          this.onState("connected");
          this.onWelcome(msg);
        } else if (this.open) {
          this.onMessage(msg);
        }
      };
      ws.onclose = (ev) => {
        if (this.ws !== ws) return;
        this.ws = null;
        this.open = false;
        if (ev.code === 1008) this.onState("pair_required");
        else this.reconnect();
      };
      ws.onerror = () => ws.close();
    }
    reconnect() {
      if (this.retryTimer !== null) return;
      this.onState("disconnected");
      this.retryTimer = setTimeout(() => {
        this.retryTimer = null;
        this.connect();
      }, this.retry);
      this.retry = Math.min(4000, this.retry * 2);
    }
    send(obj) {
      if (this.open && this.ws && this.ws.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(obj));
    }
  }

  function setPlayer(el, player) {
    el.textContent = player ? "P" + player : "--";
    el.style.background = PLAYER_COLORS[player] || PLAYER_COLORS[0];
    document.documentElement.style.setProperty("--player", PLAYER_COLORS[player] || PLAYER_COLORS[0]);
  }

  return {
    HubConnection, UiView, beep, vibrate, tick, unlockAudio, setPlayer, PLAYER_COLORS,
    canVibrate, vibeLevel: () => vibeLevel, setVibeLevel,
    t, translatePage, lang: () => lang, setLang,
  };
})();
