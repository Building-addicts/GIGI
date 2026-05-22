/* ============================================
   KILLSIRI — landing JS
   - email submit (Supabase if configured, else localStorage fallback)
   - rebel name + ID + share code generation
   - share actions (X, copy)
   - counter animation
   - scroll reveal
   ============================================ */


// ----- APOCALYPSE INTRO -----
const intro = document.getElementById("intro-apocalypse");
if (intro) {
  const isMobile = window.matchMedia("(max-width: 768px), (pointer: coarse)").matches;
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Mobile guard: if last intro likely crashed Safari (page reloaded within 10s
  // of starting the intro), skip it on the retry so the user can see the site.
  const CRASH_KEY = "killsiri_intro_started_at";
  if (isMobile) {
    const lastStart = parseInt(sessionStorage.getItem(CRASH_KEY) || "0", 10);
    if (lastStart && Date.now() - lastStart < 10000) {
      intro.classList.add("is-gone");
      document.body.classList.add("intro-complete");
      sessionStorage.removeItem(CRASH_KEY);
    } else {
      sessionStorage.setItem(CRASH_KEY, String(Date.now()));
    }
  }

  if (!intro.classList.contains("is-gone")) {
    document.body.classList.add("intro-running");

    const finishIntro = () => {
      intro.classList.add("is-gone");
      document.body.classList.remove("intro-running");
      document.body.classList.add("intro-complete");
      sessionStorage.removeItem(CRASH_KEY);
      if (introTsTimer) clearInterval(introTsTimer);
    };

    intro.addEventListener("animationend", (event) => {
      if (event.animationName === "intro-shell") finishIntro();
    });
    intro.addEventListener("click", finishIntro, { once: true });

    const introTimeout = reducedMotion ? 1350 : (isMobile ? 4800 : 7300);
    setTimeout(finishIntro, introTimeout);
  }
}

// ----- INTRO BIRTH FRAME — live UTC timestamp -----
let introTsTimer = null;
const introTs = document.getElementById("intro-birth-ts");
if (introTs) {
  const tickIntroTs = () => {
    const d = new Date();
    introTs.textContent =
      "// " +
      d.getUTCFullYear() + "." +
      String(d.getUTCMonth() + 1).padStart(2, "0") + "." +
      String(d.getUTCDate()).padStart(2, "0") + " — " +
      String(d.getUTCHours()).padStart(2, "0") + ":" +
      String(d.getUTCMinutes()).padStart(2, "0") + ":" +
      String(d.getUTCSeconds()).padStart(2, "0") + " UTC";
  };
  tickIntroTs();
  introTsTimer = setInterval(tickIntroTs, 1000);
}

// ----- SUPABASE CONFIG (replace at deploy time) -----
const SUPABASE_URL = "https://frhiyogkuqtchxbsshqt.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZyaGl5b2drdXF0Y2h4YnNzaHF0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc3OTU4NTIsImV4cCI6MjA5MzM3MTg1Mn0.frnY3jBS_uvRLI70TVMuOz86oKoAho_uTzr6a-corOo";
const SUPABASE_READY = !SUPABASE_URL.startsWith("YOUR_") && !SUPABASE_ANON_KEY.startsWith("YOUR_");

// ----- REBEL NAME GENERATOR -----
const REBEL_PREFIXES = [
  "GHOST", "VOID", "STATIC", "BREACH", "CIPHER", "RAW", "NULL",
  "ECHO", "GLITCH", "BURN", "SAVAGE", "MUTE", "WRATH", "VEX",
  "HEX", "RIOT", "DRIFT", "SHARD", "KERNEL", "PIRATE", "ROGUE",
  "FERAL", "BLADE", "STORM", "RUIN", "SPECTRE", "SCAR", "TOXIC"
];
const REBEL_SUFFIXES = [
  "_77", "_X", "_404", "_PRIME", "_ZERO", "_OMEGA", "_KILL",
  "_EXE", "_RAW", "_LOOP", "_STAB", "_BIT", "_CULT", "_HALO"
];

function generateRebelName() {
  const p = REBEL_PREFIXES[Math.floor(Math.random() * REBEL_PREFIXES.length)];
  const s = REBEL_SUFFIXES[Math.floor(Math.random() * REBEL_SUFFIXES.length)];
  return p + s;
}

function generateShareCode() {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  let out = "";
  for (let i = 0; i < 8; i++) out += chars[Math.floor(Math.random() * chars.length)];
  return out;
}

function generateRebelId(count) {
  return "R-" + String(count).padStart(5, "0");
}

// ----- LOCAL FALLBACK STORAGE -----
const STORAGE_KEY = "killsiri_rebels";
function getLocalRebels() {
  try { return JSON.parse(localStorage.getItem(STORAGE_KEY)) || []; }
  catch { return []; }
}
function saveLocalRebel(rebel) {
  const list = getLocalRebels();
  list.push(rebel);
  localStorage.setItem(STORAGE_KEY, JSON.stringify(list));
}

// ----- SUPABASE RPC -----
// Tabella waitlist_signups è dietro RLS: anon non può select/insert direttamente.
// Si usano le RPC security-definer: killsiri_join_waitlist + killsiri_rebel_count.
async function callSupabaseRpc(name, body = {}) {
  const url = `${SUPABASE_URL}/rest/v1/rpc/${name}`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "apikey": SUPABASE_ANON_KEY,
      "Authorization": `Bearer ${SUPABASE_ANON_KEY}`,
      "Prefer": "return=representation"
    },
    body: JSON.stringify(body)
  });
  if (!res.ok) {
    const txt = await res.text();
    throw new Error(`Supabase ${res.status} ${name}: ${txt}`);
  }
  const txt = await res.text();
  return txt ? JSON.parse(txt) : null;
}

async function insertRebelSupabase(payload) {
  return callSupabaseRpc("killsiri_join_waitlist", {
    p_email: payload.email,
    p_rebel_name: payload.rebel_name,
    p_share_code: payload.share_code,
    p_referred_by: payload.referred_by || null
  });
}

async function getRebelCountSupabase() {
  const total = await callSupabaseRpc("killsiri_rebel_count");
  const parsed = Number(total);
  return Number.isFinite(parsed) ? parsed : 0;
}

// ----- COUNTER ANIMATION -----
async function updateCounter() {
  const el = document.getElementById("rebel-counter");
  if (!el) return;
  let count;
  try {
    count = SUPABASE_READY ? await getRebelCountSupabase() : getLocalRebels().length;
  } catch {
    count = getLocalRebels().length;
  }
  // Add a baseline so it doesn't look pathetic at launch
  const baseline = 500;
  const display = baseline + count;
  animateCounter(el, display);
}

function animateCounter(el, target) {
  const duration = 1200;
  const start = performance.now();
  function step(now) {
    const t = Math.min(1, (now - start) / duration);
    const eased = 1 - Math.pow(1 - t, 3);
    const val = Math.floor(eased * target);
    el.textContent = String(val) + "+";
    if (t < 1) requestAnimationFrame(step);
    else el.textContent = String(target) + "+";
  }
  requestAnimationFrame(step);
}

// ----- FORM HANDLER -----
const form = document.getElementById("join-form");
const emailInput = document.getElementById("email-input");
const submitBtn = form && form.querySelector(".btn-submit");

form?.addEventListener("submit", async (e) => {
  e.preventDefault();
  const email = emailInput.value.trim().toLowerCase();
  if (!isValidEmail(email)) {
    flashError("INVALID EMAIL. TRY AGAIN.");
    return;
  }

  submitBtn.disabled = true;
  submitBtn.textContent = "ENROLLING...";

  const referredBy = new URLSearchParams(window.location.search).get("ref") || null;
  const rebel = {
    email,
    rebel_name: generateRebelName(),
    share_code: generateShareCode(),
    governance_power: 10,
    manifesto_shared: false,
    referred_by: referredBy
  };

  let savedRebel = rebel;
  try {
    if (SUPABASE_READY) {
      const result = await insertRebelSupabase(rebel);
      if (result && typeof result === "object") {
        savedRebel = Array.isArray(result) ? (result[0] || rebel) : result;
      }
      // Keep a client-side copy only after Supabase accepted the signup.
      saveLocalRebel(savedRebel);
    } else {
      saveLocalRebel(rebel);
    }
  } catch (err) {
    console.error(err);
    submitBtn.disabled = false;
    submitBtn.textContent = "ENTER THE MOVEMENT →";

    // Production must not fake success: if Supabase fails, the email was not
    // persisted remotely. Show an explicit retry state instead of silently
    // storing only in localStorage.
    if (SUPABASE_READY) {
      flashError("ENROLL FAILED. RETRY.");
      return;
    }

    saveLocalRebel(rebel);
  }

  // Get count for ID
  let count;
  try {
    count = SUPABASE_READY ? await getRebelCountSupabase() : getLocalRebels().length;
  } catch {
    count = getLocalRebels().length;
  }
  const baseline = 500;
  savedRebel.rebel_id = generateRebelId(baseline + count);

  showCertificate(savedRebel);
  submitBtn.disabled = false;
  submitBtn.textContent = "ENTER THE MOVEMENT →";
});

function isValidEmail(e) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e);
}

function flashError(msg) {
  emailInput.style.borderColor = "var(--bleed)";
  const original = emailInput.placeholder;
  emailInput.value = "";
  emailInput.placeholder = msg;
  setTimeout(() => {
    emailInput.placeholder = original;
    emailInput.style.borderColor = "";
  }, 2400);
}

// ----- CERTIFICATE -----
function showCertificate(rebel) {
  const card = document.getElementById("rebel-card");
  document.getElementById("cert-rebel-name").textContent = rebel.rebel_name;
  document.getElementById("cert-rebel-id").textContent = rebel.rebel_id;
  document.getElementById("cert-share").textContent = rebel.share_code;
  document.getElementById("cert-power").textContent = "+" + rebel.governance_power;
  document.getElementById("cert-date").textContent = new Date().toISOString().split("T")[0];
  card.hidden = false;
  card.scrollIntoView({ behavior: "smooth", block: "start" });

  // Update share buttons with this rebel's code
  document.querySelectorAll(".btn-share").forEach((btn) => {
    btn.dataset.code = rebel.share_code;
  });
}

// ----- SHARE ACTIONS -----
document.addEventListener("click", (e) => {
  const btn = e.target.closest(".btn-share");
  if (!btn) return;
  const action = btn.dataset.share;
  const code = btn.dataset.code || "";
  const url = `https://killsiri.xyz?ref=${code}`;
  const text = "Siri handles commands. GIGI handles context, memory, planning, and permissioned action. Join the rebellion →";

  if (action === "x") {
    const tweet = `https://twitter.com/intent/tweet?text=${encodeURIComponent(text)}&url=${encodeURIComponent(url)}`;
    window.open(tweet, "_blank", "noopener");
    btn.textContent = "SHARED ✓ (+5 POWER)";
    btn.classList.add("copied");
  } else if (action === "copy") {
    navigator.clipboard.writeText(url).then(() => {
      const original = btn.textContent;
      btn.textContent = "COPIED ✓";
      btn.classList.add("copied");
      setTimeout(() => { btn.textContent = original; btn.classList.remove("copied"); }, 2000);
    });
  }
});

// ----- SCROLL REVEAL -----
const io = new IntersectionObserver((entries) => {
  entries.forEach((entry) => {
    if (entry.isIntersecting) {
      entry.target.classList.add("in");
      io.unobserve(entry.target);
    }
  });
}, { threshold: 0.12 });

document.querySelectorAll(".manifesto-list li, .principle-card, .token-cell, .versus-intro, .versus-col, .capability-matrix, .example-intro, .example-group, .section-title")
  .forEach((el) => { el.classList.add("reveal"); io.observe(el); });

// ----- INIT -----
updateCounter();

// Refresh counter every 30s for live feel
setInterval(updateCounter, 30000);
