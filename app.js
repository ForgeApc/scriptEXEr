/* ============================================================
   SCRIPTEXER — App logic (hash router + views)
   ============================================================ */

(function () {
  "use strict";

  const app = document.getElementById("app");
  const toast = document.getElementById("toast");
  const yearEl = document.getElementById("year");
  if (yearEl) yearEl.textContent = new Date().getFullYear();

  const DATA = window.Store.load();
  // Keep a live reference that the admin panel can mutate + re-render.
  function refreshData() {
    const fresh = window.Store.load();
    DATA.games = fresh.games;
    DATA.executors = fresh.executors;
  }

  /* ---------- Helpers ---------- */
  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function highlightLoadstring(code) {
    let html = escapeHtml(code);
    html = html.replace(/(--[^\n]*)/g, '<span class="tok-com">$1</span>');
    html = html.replace(/(&quot;[^&]*?&quot;)/g, '<span class="tok-str">$1</span>');
    html = html.replace(/\b(loadstring|game|HttpGet)\b/g, '<span class="tok-fn">$1</span>');
    return html;
  }

  /* Build a single exploit card markup. Shared by viewGame and live filtering. */
  function exploitCardHtml(game, e) {
    return `
        <a class="card exploit-card" href="#/game/${game.id}/${e.id}">
          <div class="card-img">
            <span class="img-gradient"></span>
            ${thumbDisplay(e)}
          </div>
          <div class="card-body">
            <div class="exploit-row-head">
              <span class="card-title">${escapeHtml(e.title)}</span>
              ${e.verified
                ? `<span class="verified-badge">✓ Verified</span>`
                : `<span class="unverified-badge">Unverified</span>`}
            </div>
            <span class="card-sub">↓ ${escapeHtml(e.downloads || "—")} · 🛡 Level ${e.level || "—"}</span>
          </div>
        </a>`;
  }

  /* Build the markup for a list of exploits (for a given game). */
  function cardsHtmlStatic(game, list) {
    return list.map((e) => exploitCardHtml(game, e)).join("");
  }

  function showToast(msg) {
    toast.textContent = msg;
    toast.classList.add("show");
    clearTimeout(showToast._t);
    showToast._t = setTimeout(() => toast.classList.remove("show"), 2200);
  }

  async function copyText(text) {
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(text);
        return true;
      }
    } catch (_) { /* fall through */ }
    try {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.focus();
      ta.select();
      const ok = document.execCommand("copy");
      document.body.removeChild(ta);
      return ok;
    } catch (_) {
      return false;
    }
  }

  /* ---------- Router ---------- */
  function getRoute() {
    let hash = location.hash.replace(/^#/, "");
    if (!hash.startsWith("/")) hash = "/" + hash;
    return hash;
  }

  function navigate(path) {
    if (location.hash !== "#" + path) {
      location.hash = path;
    } else {
      render();
    }
    window.scrollTo({ top: 0, behavior: "smooth" });
    closeMobileNav();
  }

  function setActiveNav(route) {
    // Cover all nav tabs (both nav-links and nav-actions)
    document.querySelectorAll(".nav-tab").forEach((tab) => {
      const r = tab.getAttribute("data-route");
      tab.classList.toggle("active", !!r && r === route);
    });
    positionNavIndicator(route);
  }

  /* Sliding nav indicator — only for nav-links (Home) */
  const navIndicator = document.getElementById("navIndicator");
  function positionNavIndicator(route) {
    const navLinks = document.getElementById("navLinks");
    if (!navIndicator || !navLinks) return;
    if (window.innerWidth <= 820) { navIndicator.classList.remove("visible"); return; }
    const tab = Array.from(navLinks.querySelectorAll(".nav-tab[data-route]")).find(
      (t) => t.getAttribute("data-route") === route
    );
    if (!tab) return;
    const parentRect = navLinks.getBoundingClientRect();
    const rect = tab.getBoundingClientRect();
    navIndicator.style.width = rect.width + "px";
    navIndicator.style.transform = `translate(${rect.left - parentRect.left}px, -50%)`;
    navIndicator.classList.add("visible");
  }

  function initNavHoverIndicator() {
    const navLinks = document.getElementById("navLinks");
    if (!navLinks || !navIndicator) return;
    navLinks.addEventListener("mouseover", (e) => {
      const tab = e.target.closest(".nav-tab[data-route]");
      if (!tab || window.innerWidth <= 820) return;
      const parentRect = navLinks.getBoundingClientRect();
      const rect = tab.getBoundingClientRect();
      navIndicator.style.width = rect.width + "px";
      navIndicator.style.transform = `translate(${rect.left - parentRect.left}px, -50%)`;
    });
    navLinks.addEventListener("mouseleave", () => {
      const active = navLinks.querySelector(".nav-tab.active[data-route]");
      if (active && window.innerWidth > 820) {
        positionNavIndicator(active.getAttribute("data-route"));
      }
    });
  }

  /* ---------- Views ---------- */

  // HOME
  function viewHome(query) {
    const q = (query || "").trim().toLowerCase();
    const games = DATA.games.filter(
      (g) => !q || g.name.toLowerCase().includes(q) || (g.sub || "").toLowerCase().includes(q)
    );

    const cards = games
      .map(
        (g) => `
        <a class="card" href="#/game/${g.id}">
          <div class="card-img">
            <span class="img-gradient" style="background:${g.gradient}"></span>
            ${thumbDisplay(g)}
          </div>
          <div class="card-body">
            <span class="card-title">${escapeHtml(g.name)}</span>
            <span class="card-sub">${escapeHtml(g.sub || "")}</span>
            <span class="card-badge">${g.exploits.length} script${g.exploits.length === 1 ? "" : "s"}</span>
          </div>
        </a>`
      )
      .join("");

    const gridHtml = games.length
      ? `<div class="grid grid-games">${cards}</div>`
      : `<div class="empty-state">
           <span class="emoji">🔍</span>
           <p>No games found for "<strong>${escapeHtml(query)}</strong>". Try another name.</p>
         </div>`;

    return `
      <section class="view">
        <div class="page-hero">
          <span class="eyebrow">SCRIPTEXER · Library</span>
          <h1>Find the perfect script</h1>
          <p>Search thousands of Roblox scripts by game name. Copy a loadstring and you're ready to run.</p>
        </div>
        <div class="search-wrap">
          <svg class="search-icon" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></svg>
          <input id="search" class="search-input" type="text" placeholder="Search by game name… (e.g. Blox Fruits)" autocomplete="off" value="${escapeHtml(query || "")}" />
        </div>
        <p class="section-label">${q ? "Results" : "Popular games"} · ${games.length}</p>
        ${gridHtml}
      </section>`;
  }

  // GAME DETAIL — grid of exploit cards
  function viewGame(gameId) {
    const game = DATA.games.find((g) => g.id === gameId);
    if (!game) return notFound("Game");

    const gridHtml = game.exploits.length
      ? `<div class="game-search">
           <svg class="game-search-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></svg>
           <input id="exploit-search" class="game-search-input" type="text" placeholder="Search scripts in ${escapeHtml(game.name)}…" autocomplete="off" />
         </div>
         <p class="section-label" id="exploit-count">Available scripts · ${game.exploits.length}</p>
         <div class="grid grid-exploits" id="exploits-grid">${cardsHtmlStatic(game, game.exploits)}</div>`
      : `<div class="empty-state"><span class="emoji">📦</span><p>No scripts available for this game yet.</p></div>`;

    return `
      <section class="view">
        <a class="back-btn" href="#/">← Back to games</a>
        <div class="detail-header">
          <div class="detail-thumb glass">
            <span class="img-gradient" style="position:absolute;inset:0;border-radius:18px;opacity:0.85"></span>
            <span style="position:relative">${thumbDisplay(game)}</span>
          </div>
          <div class="detail-title-block">
            <h1>${escapeHtml(game.name)}</h1>
            <p>${escapeHtml(game.sub || "")} · ${game.exploits.length} exploit${game.exploits.length === 1 ? "" : "s"} available</p>
          </div>
        </div>
        ${gridHtml}
      </section>`;
  }

  // EXPLOIT DETAIL — two-column layout
  function viewExploit(gameId, exploitId) {
    const game = DATA.games.find((g) => g.id === gameId);
    if (!game) return notFound("Game");
    const exploit = game.exploits.find((e) => e.id === exploitId);
    if (!exploit) return notFound("Exploit");

    const reqList = exploit.requirements && exploit.requirements.length
      ? `<div class="detail-panel glass">
          <h2>Requirements</h2>
          <ul class="req-list">
            ${exploit.requirements.map((r) => `<li>${escapeHtml(r)}</li>`).join("")}
          </ul>
        </div>`
      : "";

    return `
      <section class="view">
        <a class="back-btn" href="#/game/${game.id}">← Back to ${escapeHtml(game.name)}</a>

        <div class="detail-header">
          <div class="detail-thumb glass">
            <span class="img-gradient" style="position:absolute;inset:0;border-radius:18px;opacity:0.85"></span>
            <span style="position:relative">${thumbDisplay(exploit)}</span>
          </div>
          <div class="detail-title-block">
            <div class="detail-tags">
              ${exploit.verified
                ? `<span class="tag tag-verified">✓ Verified</span>`
                : `<span class="tag">Unverified</span>`}
              <span class="tag tag-level">🛡 Level ${exploit.level || "—"}</span>
              <span class="tag tag-strong">${escapeHtml(game.name)}</span>
            </div>
            <h1>${escapeHtml(exploit.title)}</h1>
            <p>↓ ${escapeHtml(exploit.downloads || "—")} downloads · Updated ${escapeHtml(exploit.updated || "—")}</p>
          </div>
        </div>

        <div class="detail-grid">
          <div class="detail-col">
            <div class="detail-panel glass">
              <h2>About this script</h2>
              <p>${escapeHtml(exploit.description)}</p>
            </div>

            <div class="detail-panel glass">
              <h2>Loadstring</h2>
              <p style="margin-bottom:14px;color:var(--text-dim);font-size:0.88rem">Paste this into your executor and press Execute.</p>
              <div class="code-block">
                <div class="code-block-header">
                  <span class="code-label">
                    <span class="code-dots"><span></span><span></span><span></span></span>
                    Lua
                  </span>
                  <button class="copy-btn" id="copyBtn" aria-label="Copy loadstring">
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
                    <span class="copy-label">Copy</span>
                  </button>
                </div>
                <pre><code id="loadstringCode">${highlightLoadstring(exploit.loadstring)}</code></pre>
              </div>
            </div>
          </div>

          <div class="detail-col">
            <div class="detail-panel glass">
              <h2>Details</h2>
              <ul class="detail-stats">
                <li><span>Status</span><strong>${exploit.verified ? "✓ Verified" : "Unverified"}</strong></li>
                <li><span>UNC Level</span><strong>${exploit.level || "—"}</strong></li>
                <li><span>Downloads</span><strong>${escapeHtml(exploit.downloads || "—")}</strong></li>
                <li><span>Last updated</span><strong>${escapeHtml(exploit.updated || "—")}</strong></li>
                <li><span>Game</span><strong>${escapeHtml(game.name)}</strong></li>
              </ul>
            </div>
            ${reqList}
          </div>
        </div>
      </section>`;
  }

  // EXECUTORS grid
  function viewExecutors() {
    const cards = DATA.executors
      .map(
        (ex) => `
        <a class="card executor-card" href="#/executor/${ex.id}">
          <div class="executor-img">
            <span class="img-gradient" style="position:absolute;inset:0;background:${ex.gradient};opacity:0.6"></span>
            <span style="position:relative">${thumbDisplay(ex)}</span>
          </div>
          <div class="card-body" style="align-items:center;text-align:center">
            <span class="card-title">${escapeHtml(ex.name)}</span>
            <span class="card-sub">View details & download</span>
          </div>
        </a>`
      )
      .join("");

    return `
      <section class="view">
        <div class="page-hero">
          <span class="eyebrow">SCRIPTEXER · Tools</span>
          <h1>Roblox Executors</h1>
          <p>Trusted executors to run your scripts. Pick one, view the specs, and download.</p>
        </div>
        <p class="section-label">All executors · ${DATA.executors.length}</p>
        <div class="grid grid-executors">${cards}</div>
      </section>`;
  }

  // EXECUTOR DETAIL
  function viewExecutor(executorId) {
    const ex = DATA.executors.find((e) => e.id === executorId);
    if (!ex) return notFound("Executor");

    const features = ex.features
      ? `<div class="detail-panel glass"><h2>Features & compatibility</h2><ul>${ex.features.map((f) => `<li>${escapeHtml(f)}</li>`).join("")}</ul></div>`
      : "";

    return `
      <section class="view">
        <a class="back-btn" href="#/executors">← Back to executors</a>
        <div class="detail-header">
          <div class="detail-thumb glass">
            <span class="img-gradient" style="position:absolute;inset:0;border-radius:18px;background:${ex.gradient};opacity:0.85"></span>
            <span style="position:relative">${thumbDisplay(ex)}</span>
          </div>
          <div class="detail-title-block">
            <h1>${escapeHtml(ex.name)}</h1>
            <p>Roblox executor</p>
          </div>
        </div>

        <div class="detail-panel glass">
          <h2>About ${escapeHtml(ex.name)}</h2>
          <p>${escapeHtml(ex.description)}</p>
        </div>

        ${features}

        <div class="detail-panel glass" style="text-align:center">
          <h2>Get ${escapeHtml(ex.name)}</h2>
          <p style="margin-bottom:8px">Download the latest build and start running scripts in seconds.</p>
          <a class="btn btn-download" href="${escapeHtml(ex.download)}" target="_blank" rel="noopener noreferrer">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
            Download ${escapeHtml(ex.name)}
          </a>
        </div>
      </section>`;
  }

  /* ============================================================
     Admin Panel — add/edit/delete games, exploits, executors
     ============================================================ */

  // Helper: pick the image to display. Custom image takes priority; else emoji.
  function thumbDisplay(item) {
    if (item.image && /^https?:\/\//.test(item.image)) {
      return `<img src="${escapeHtml(item.image)}" alt="${escapeHtml(item.name || item.title || "")}" class="thumb-img" onerror="this.style.display='none';this.nextElementSibling.style.display=''"/><span class="emoji" style="display:none">${escapeHtml(item.emoji || "🎮")}</span>`;
    }
    return `<span class="emoji">${escapeHtml(item.emoji || "🎮")}</span>`;
  }

  /* Small circular icon button overlaid on an admin card (edit / delete). */
  function adminCardActions(editAction, delAction, dataAttrs) {
    return `
      <div class="admin-card-actions">
        <button class="admin-icon-btn edit" data-action="${editAction}" ${dataAttrs} aria-label="Edit" title="Edit">
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z"/></svg>
        </button>
        <button class="admin-icon-btn del" data-action="${delAction}" ${dataAttrs} aria-label="Delete" title="Delete">
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2m3 0-1 14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2L4 6"/></svg>
        </button>
      </div>`;
  }

  function viewAdmin() {
    const games = DATA.games;
    const executors = DATA.executors;
    const totalExploits = games.reduce((n, g) => n + (g.exploits ? g.exploits.length : 0), 0);

    const gameCards = games
      .map((g) => {
        const count = g.exploits ? g.exploits.length : 0;
        return `
        <div class="card admin-card">
          ${adminCardActions("edit-game", "delete-game", `data-id="${escapeHtml(g.id)}"`)}
          <div class="card-img">
            <span class="img-gradient" style="background:${g.gradient || "linear-gradient(135deg,#1a1a1a,#050505)"}"></span>
            ${thumbDisplay(g, 0)}
          </div>
          <div class="card-body">
            <span class="card-title">${escapeHtml(g.name)}</span>
            <span class="card-sub">${escapeHtml(g.sub || "")}</span>
            <span class="card-badge">${count} script${count === 1 ? "" : "s"}</span>
          </div>
        </div>`;
      })
      .join("");

    const exploitCards = games
      .map((g) =>
        (g.exploits || [])
          .map(
            (e) => `
        <div class="card admin-card">
          ${adminCardActions("edit-exploit", "delete-exploit", `data-game="${escapeHtml(g.id)}" data-id="${escapeHtml(e.id)}"`)}
          <div class="card-img">
            <span class="img-gradient"></span>
            ${thumbDisplay(e, 0)}
          </div>
          <div class="card-body">
            <span class="card-title">${escapeHtml(e.title)}</span>
            <span class="card-sub">${escapeHtml(g.name)}${e.verified ? " · ✓ Verified" : " · Unverified"}${e.level ? ` · Lvl ${e.level}` : ""}</span>
          </div>
        </div>`
          )
          .join("")
      )
      .join("");

    const executorCards = executors
      .map(
        (ex) => `
        <div class="card admin-card">
          ${adminCardActions("edit-executor", "delete-executor", `data-id="${escapeHtml(ex.id)}"`)}
          <div class="card-img executor-img">
            <span class="img-gradient" style="background:${ex.gradient || "linear-gradient(135deg,#1a1a1a,#050505)"}"></span>
            ${thumbDisplay(ex, 0)}
          </div>
          <div class="card-body" style="align-items:center;text-align:center">
            <span class="card-title">${escapeHtml(ex.name)}</span>
            <span class="card-sub">${ex.features ? ex.features.length : 0} features · ${ex.download ? "has download link" : "no download link"}</span>
          </div>
        </div>`
      )
      .join("");

    return `
      <section class="view admin-view">
        <a class="back-btn" href="#/">← Back to site</a>
        <div class="page-hero">
          <span class="eyebrow">SCRIPTEXER · Admin</span>
          <h1>Admin Panel</h1>
          <p>Manage games, scripts, and executors. Changes are saved in your browser.</p>
        </div>

        <div class="admin-stats">
          <div class="admin-stat"><span class="admin-stat-num">${games.length}</span><span class="admin-stat-label">Games</span></div>
          <div class="admin-stat"><span class="admin-stat-num">${totalExploits}</span><span class="admin-stat-label">Scripts</span></div>
          <div class="admin-stat"><span class="admin-stat-num">${executors.length}</span><span class="admin-stat-label">Executors</span></div>
        </div>

        <div class="admin-section">
          <div class="admin-section-head">
            <p class="section-label">🎮 Games · ${games.length}</p>
            <button class="admin-fab" data-action="add-game" aria-label="Add game" title="Add game">+</button>
          </div>
          <div class="grid grid-games">${gameCards || ""}</div>
          ${gameCards ? "" : '<div class="empty-state"><span class="emoji">🎮</span><p>No games yet — hit + to add one.</p></div>'}
        </div>

        <div class="admin-section">
          <div class="admin-section-head">
            <p class="section-label">📜 Scripts · ${totalExploits}</p>
            <button class="admin-fab" data-action="add-exploit" aria-label="Add script" title="Add script">+</button>
          </div>
          <div class="grid grid-exploits">${exploitCards || ""}</div>
          ${exploitCards ? "" : '<div class="empty-state"><span class="emoji">📜</span><p>No scripts yet — hit + to add one.</p></div>'}
        </div>

        <div class="admin-section">
          <div class="admin-section-head">
            <p class="section-label">🛠 Executors · ${executors.length}</p>
            <button class="admin-fab" data-action="add-executor" aria-label="Add executor" title="Add executor">+</button>
          </div>
          <div class="grid grid-executors">${executorCards || ""}</div>
          ${executorCards ? "" : '<div class="empty-state"><span class="emoji">🛠</span><p>No executors yet — hit + to add one.</p></div>'}
        </div>

        <div class="admin-section">
          <div class="admin-section-head">
            <p class="section-label">🔧 Data</p>
          </div>
          <div class="admin-data-actions">
            <button class="admin-btn admin-btn-secondary" data-action="reset-data">Reset to defaults</button>
          </div>
        </div>
      </section>`;
  }

  /* ---------- Admin modal builder ---------- */
  function openAdminModal(title, innerHtml) {
    let overlay = document.getElementById("adminModal");
    if (!overlay) {
      overlay = document.createElement("div");
      overlay.id = "adminModal";
      overlay.className = "modal-overlay";
      overlay.innerHTML = `<div class="modal glass admin-modal" role="dialog" aria-modal="true">
        <button class="modal-close" data-admin-close aria-label="Close">×</button>
        <h2 class="admin-modal-title"></h2>
        <div class="admin-modal-body"></div>
      </div>`;
      document.body.appendChild(overlay);
      overlay.addEventListener("click", (e) => {
        if (e.target === overlay || e.target.matches("[data-admin-close]")) closeAdminModal();
      });
    }
    overlay.querySelector(".admin-modal-title").textContent = title;
    overlay.querySelector(".admin-modal-body").innerHTML = innerHtml;
    overlay.classList.add("open");
    overlay.setAttribute("aria-hidden", "false");
    document.body.style.overflow = "hidden";
  }

  function closeAdminModal() {
    const overlay = document.getElementById("adminModal");
    if (overlay) {
      overlay.classList.remove("open");
      overlay.setAttribute("aria-hidden", "true");
      document.body.style.overflow = "";
    }
  }

  /* ---------- Field generators for forms ---------- */
  function fieldText(id, label, value, placeholder) {
    return `<label class="admin-field"><span>${escapeHtml(label)}</span><input type="text" id="f-${id}" data-field="${escapeHtml(id)}" value="${escapeHtml(value || "")}" placeholder="${escapeHtml(placeholder || "")}"/></label>`;
  }
  function fieldTextarea(id, label, value, placeholder) {
    return `<label class="admin-field"><span>${escapeHtml(label)}</span><textarea id="f-${id}" data-field="${escapeHtml(id)}" rows="3" placeholder="${escapeHtml(placeholder || "")}">${escapeHtml(value || "")}</textarea></label>`;
  }
  function fieldNumber(id, label, value) {
    return `<label class="admin-field"><span>${escapeHtml(label)}</span><input type="number" id="f-${id}" data-field="${escapeHtml(id)}" value="${value != null ? value : ""}" placeholder="0"/></label>`;
  }
  function fieldCheckbox(id, label, checked) {
    return `<label class="admin-field admin-field-inline"><input type="checkbox" id="f-${id}" data-field="${escapeHtml(id)}" ${checked ? "checked" : ""}/><span>${escapeHtml(label)}</span></label>`;
  }
  function fieldList(id, label, value) {
    const text = Array.isArray(value) ? value.join("\n") : value || "";
    return `<label class="admin-field"><span>${escapeHtml(label)} <em>(one per line)</em></span><textarea id="f-${id}" data-field="${escapeHtml(id)}" rows="4" placeholder="Item 1&#10;Item 2">${escapeHtml(text)}</textarea></label>`;
  }
  function fieldImage(id, label, value, emojiVal) {
    return `<label class="admin-field">
      <span>${escapeHtml(label)} <em>(PNG URL — optional)</em></span>
      <input type="text" id="f-${id}" data-field="${escapeHtml(id)}" value="${escapeHtml(value || "")}" placeholder="https://example.com/image.png"/>
      <div class="admin-image-preview" id="preview-${id}"></div>
    </label>`;
  }

  /** Collect form values from an admin modal body into an object. */
  function collectForm(container) {
    const out = {};
    container.querySelectorAll("[data-field]").forEach((el) => {
      const key = el.getAttribute("data-field");
      if (el.type === "checkbox") {
        out[key] = el.checked;
      } else if (el.type === "number") {
        out[key] = el.value === "" ? "" : Number(el.value);
      } else if (el.tagName === "TEXTAREA" && el.getAttribute("data-list") === "1") {
        out[key] = el.value.split("\n").map((s) => s.trim()).filter(Boolean);
      } else {
        out[key] = el.value.trim();
      }
    });
    return out;
  }

  function saveAndRefresh() {
    window.Store.save({ games: DATA.games, executors: DATA.executors });
    closeAdminModal();
    render();
  }

  /* ---------- Image preview live updater ---------- */
  function bindImagePreview(container) {
    container.querySelectorAll('input[type="text"][data-field$="-image"], input[type="text"][data-field="image"]').forEach((input) => {
      const previewId = "preview-" + input.getAttribute("data-field");
      function update() {
        const box = container.querySelector("#" + CSS.escape(previewId));
        if (!box) return;
        const url = input.value.trim();
        if (url && /^https?:\/\//.test(url)) {
          box.innerHTML = `<img src="${escapeHtml(url)}" alt="preview" onerror="this.parentElement.innerHTML='<span class=&quot;admin-preview-err&quot;>⚠️ failed to load</span>'"/>`;
        } else {
          box.innerHTML = "";
        }
      }
      input.addEventListener("input", update);
      update();
    });
  }

  /* ---------- Admin: Games ---------- */
  function adminAddGame() {
    openAdminModal("Add Game", `
      ${fieldImage("image", "Thumbnail", "", "🎮")}
      ${fieldText("name", "Name", "", "Blox Fruits")}
      ${fieldText("sub", "Subtitle", "", "Sail the seas & grind fruits")}
      <button class="admin-btn admin-btn-save" data-admin-save="game-new">Create Game</button>
    `);
    bindImagePreview(document.getElementById("adminModal"));
  }

  function adminEditGame(gameId) {
    const g = DATA.games.find((x) => x.id === gameId);
    if (!g) return;
    openAdminModal("Edit Game", `
      ${fieldImage("image", "Thumbnail", g.image, g.emoji)}
      ${fieldText("name", "Name", g.name)}
      ${fieldText("sub", "Subtitle", g.sub || "")}
      <button class="admin-btn admin-btn-save" data-admin-save="game" data-id="${escapeHtml(gameId)}">Save Changes</button>
    `);
    bindImagePreview(document.getElementById("adminModal"));
  }

  function adminDeleteGame(gameId) {
    const g = DATA.games.find((x) => x.id === gameId);
    if (!g) return;
    if (!confirm(`Delete "${g.name}" and all its scripts? This cannot be undone.`)) return;
    DATA.games = DATA.games.filter((x) => x.id !== gameId);
    saveAndRefresh();
  }

  /* ---------- Admin: Exploits ---------- */
  function adminAddExploit(presetGameId) {
    const gameOptions = DATA.games
      .map((g) => `<option value="${escapeHtml(g.id)}" ${g.id === presetGameId ? "selected" : ""}>${escapeHtml(g.name)}</option>`)
      .join("");
    openAdminModal("Add Script", `
      <label class="admin-field"><span>Game</span>
        <select id="f-game-select" data-field="_game">
          ${gameOptions || '<option value="">No games — add one first</option>'}
        </select>
      </label>
      ${fieldImage("image", "Thumbnail", "", "📜")}
      ${fieldText("title", "Title", "", "Auto Farm Aura")}
      ${fieldTextarea("short", "Short summary", "", "One-line description")}
      ${fieldTextarea("description", "Full description", "", "Detailed description of what the script does.")}
      ${fieldText("loadstring", "Loadstring", "", 'loadstring(game:HttpGet("..."))()')}
      ${fieldNumber("level", "UNC Level", 7)}
      ${fieldCheckbox("verified", "Verified", true)}
      ${fieldText("downloads", "Downloads", "", "1.2M")}
      ${fieldText("updated", "Updated", "", "2h ago")}
      ${fieldList("requirements", "Requirements", [], "Any executor supporting UNC Level 7 or higher")}
      <button class="admin-btn admin-btn-save" data-admin-save="exploit-new">Create Script</button>
    `);
    bindImagePreview(document.getElementById("adminModal"));
    // Mark requirements textarea as a list
    const req = document.querySelector('#f-requirements');
    if (req) req.setAttribute("data-list", "1");
  }

  function adminEditExploit(gameId, exploitId) {
    const g = DATA.games.find((x) => x.id === gameId);
    if (!g) return;
    const e = (g.exploits || []).find((x) => x.id === exploitId);
    if (!e) return;
    openAdminModal("Edit Script", `
      ${fieldImage("image", "Thumbnail", e.image, e.emoji)}
      ${fieldText("title", "Title", e.title)}
      ${fieldTextarea("short", "Short summary", e.short)}
      ${fieldTextarea("description", "Full description", e.description)}
      ${fieldText("loadstring", "Loadstring", e.loadstring)}
      ${fieldNumber("level", "UNC Level", e.level)}
      ${fieldCheckbox("verified", "Verified", e.verified)}
      ${fieldText("downloads", "Downloads", e.downloads)}
      ${fieldText("updated", "Updated", e.updated)}
      ${fieldList("requirements", "Requirements", e.requirements)}
      <button class="admin-btn admin-btn-save" data-admin-save="exploit" data-game="${escapeHtml(gameId)}" data-id="${escapeHtml(exploitId)}">Save Changes</button>
    `);
    bindImagePreview(document.getElementById("adminModal"));
    const req = document.querySelector('#f-requirements');
    if (req) req.setAttribute("data-list", "1");
  }

  function adminDeleteExploit(gameId, exploitId) {
    const g = DATA.games.find((x) => x.id === gameId);
    if (!g) return;
    const e = (g.exploits || []).find((x) => x.id === exploitId);
    if (!e) return;
    if (!confirm(`Delete "${e.title}"?`)) return;
    g.exploits = (g.exploits || []).filter((x) => x.id !== exploitId);
    saveAndRefresh();
  }

  /* ---------- Admin: Executors ---------- */
  function adminAddExecutor() {
    openAdminModal("Add Executor", `
      ${fieldImage("image", "Thumbnail", "", "⚡")}
      ${fieldText("name", "Name", "", "Synapse X")}
      ${fieldTextarea("description", "Description", "", "What this executor offers.")}
      ${fieldText("download", "Download URL", "", "https://example.com/download")}
      ${fieldList("features", "Features", [], "UNC compliant (100% score)")}
      <button class="admin-btn admin-btn-save" data-admin-save="executor-new">Create Executor</button>
    `);
    bindImagePreview(document.getElementById("adminModal"));
    const feat = document.querySelector('#f-features');
    if (feat) feat.setAttribute("data-list", "1");
  }

  function adminEditExecutor(executorId) {
    const ex = DATA.executors.find((x) => x.id === executorId);
    if (!ex) return;
    openAdminModal("Edit Executor", `
      ${fieldImage("image", "Thumbnail", ex.image, ex.emoji)}
      ${fieldText("name", "Name", ex.name)}
      ${fieldTextarea("description", "Description", ex.description)}
      ${fieldText("download", "Download URL", ex.download)}
      ${fieldList("features", "Features", ex.features)}
      <button class="admin-btn admin-btn-save" data-admin-save="executor" data-id="${escapeHtml(executorId)}">Save Changes</button>
    `);
    bindImagePreview(document.getElementById("adminModal"));
    const feat = document.querySelector('#f-features');
    if (feat) feat.setAttribute("data-list", "1");
  }

  function adminDeleteExecutor(executorId) {
    const ex = DATA.executors.find((x) => x.id === executorId);
    if (!ex) return;
    if (!confirm(`Delete "${ex.name}"?`)) return;
    DATA.executors = DATA.executors.filter((x) => x.id !== executorId);
    saveAndRefresh();
  }

  /* ---------- Admin: handle save button clicks ---------- */
  function handleAdminSave(btn) {
    const modalBody = document.querySelector(".admin-modal-body");
    const data = collectForm(modalBody);
    const mode = btn.getAttribute("data-admin-save");

    if (mode === "game-new") {
      if (!data.name) return showToast("Name is required");
      const id = window.Store.slugify(data.name, DATA.games.map((g) => g.id));
      DATA.games.push({
        id, name: data.name, sub: data.sub || "", emoji: "🎮",
        image: data.image || "", gradient: "linear-gradient(135deg, #1a1a1a, #050505)",
        exploits: [],
      });
      saveAndRefresh();
      showToast("Game added");
    } else if (mode === "game") {
      const g = DATA.games.find((x) => x.id === btn.getAttribute("data-id"));
      if (!g) return;
      if (data.name) g.name = data.name;
      g.sub = data.sub || "";
      if (data.image) g.image = data.image; else delete g.image;
      saveAndRefresh();
      showToast("Game saved");
    } else if (mode === "exploit-new") {
      const gameId = data._game;
      const g = DATA.games.find((x) => x.id === gameId);
      if (!g) return showToast("Select a game first");
      if (!data.title) return showToast("Title is required");
      const id = window.Store.slugify(data.title, (g.exploits || []).map((e) => e.id));
      g.exploits = g.exploits || [];
      g.exploits.push({
        id, title: data.title, emoji: "📜", image: data.image || "",
        short: data.short || "", description: data.description || "",
        loadstring: data.loadstring || "", level: data.level || "",
        verified: !!data.verified, downloads: data.downloads || "—",
        updated: data.updated || "now", requirements: data.requirements || [],
      });
      saveAndRefresh();
      showToast("Script added");
    } else if (mode === "exploit") {
      const g = DATA.games.find((x) => x.id === btn.getAttribute("data-game"));
      const e = g && (g.exploits || []).find((x) => x.id === btn.getAttribute("data-id"));
      if (!e) return;
      if (data.title) e.title = data.title;
      e.short = data.short || "";
      e.description = data.description || "";
      e.loadstring = data.loadstring || "";
      e.level = data.level || "";
      e.verified = !!data.verified;
      e.downloads = data.downloads || "—";
      e.updated = data.updated || "now";
      e.requirements = data.requirements || [];
      if (data.image) e.image = data.image; else delete e.image;
      saveAndRefresh();
      showToast("Script saved");
    } else if (mode === "executor-new") {
      if (!data.name) return showToast("Name is required");
      const id = window.Store.slugify(data.name, DATA.executors.map((e) => e.id));
      DATA.executors.push({
        id, name: data.name, emoji: "⚡", image: data.image || "",
        description: data.description || "", download: data.download || "",
        features: data.features || [],
      });
      saveAndRefresh();
      showToast("Executor added");
    } else if (mode === "executor") {
      const ex = DATA.executors.find((x) => x.id === btn.getAttribute("data-id"));
      if (!ex) return;
      if (data.name) ex.name = data.name;
      ex.description = data.description || "";
      ex.download = data.download || "";
      ex.features = data.features || [];
      if (data.image) ex.image = data.image; else delete ex.image;
      saveAndRefresh();
      showToast("Executor saved");
    }
  }

  /* ---------- Admin: event wiring ----------
     Bound once on document (not per-render on .admin-view) because the
     admin modal is appended directly to <body>, outside the .admin-view
     subtree, so a listener scoped to .admin-view would never see clicks
     inside the modal. */
  let adminEventsBound = false;
  function bindAdminEvents() {
    if (adminEventsBound) return;
    adminEventsBound = true;
    document.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-action], [data-admin-save]");
      if (!btn) return;
      if (!btn.closest(".admin-view") && !btn.closest("#adminModal")) return;
      const action = btn.getAttribute("data-action");
      const saveMode = btn.getAttribute("data-admin-save");

      if (saveMode) { handleAdminSave(btn); return; }

      const id = btn.getAttribute("data-id");
      const gameId = btn.getAttribute("data-game");

      if (action === "add-game") adminAddGame();
      else if (action === "edit-game") adminEditGame(id);
      else if (action === "delete-game") adminDeleteGame(id);
      else if (action === "add-exploit") adminAddExploit(gameId);
      else if (action === "edit-exploit") adminEditExploit(gameId, id);
      else if (action === "delete-exploit") adminDeleteExploit(gameId, id);
      else if (action === "add-executor") adminAddExecutor();
      else if (action === "edit-executor") adminEditExecutor(id);
      else if (action === "delete-executor") adminDeleteExecutor(id);
      else if (action === "reset-data") {
        if (confirm("Reset ALL data back to defaults? This deletes your changes.")) {
          const fresh = window.Store.reset();
          DATA.games = fresh.games;
          DATA.executors = fresh.executors;
          render();
          showToast("Data reset to defaults");
        }
      }
    });
  }

  function notFound(kind) {
    return `
      <section class="view">
        <div class="empty-state">
          <span class="emoji">🤷</span>
          <p>${escapeHtml(kind)} not found.</p>
          <a class="back-btn" href="#/" style="margin-top:18px">← Back home</a>
        </div>
      </section>`;
  }

  /* ---------- Render dispatch ---------- */
  function render() {
    const route = getRoute();
    let html = "";
    let activeRoute = "/";

    if (route === "/" || route === "") {
      html = viewHome("");
      activeRoute = "/";
    } else if (route.startsWith("/search")) {
      const m = route.match(/[?&]q=([^&]*)/);
      const q = m ? decodeURIComponent(m[1].replace(/\+/g, " ")) : "";
      html = viewHome(q);
      activeRoute = "/";
    } else if (route.startsWith("/game/")) {
      const parts = route.split("/");
      const gameId = parts[2];
      const exploitId = parts[3];
      if (exploitId) {
        html = viewExploit(gameId, exploitId);
      } else {
        html = viewGame(gameId);
      }
    } else if (route === "/executors") {
      html = viewExecutors();
      activeRoute = "/executors";
    } else if (route.startsWith("/executor/")) {
      const executorId = route.split("/")[2];
      html = viewExecutor(executorId);
      activeRoute = "/executors";
    } else if (route === "/discord" || route === "discord") {
      html = viewHome("");
      activeRoute = "/";
    } else if (route === "/admin2014" || route.startsWith("/admin2014")) {
      html = viewAdmin();
      activeRoute = "/";
    } else {
      html = notFound("Page");
    }

    app.innerHTML = html;
    setActiveNav(activeRoute);
    bindViewEvents();
    bindAdminEvents();
    initMotion(app);

    const view = app.querySelector(".view");
    if (view && !prefersReduced) {
      view.style.animation = "none";
      // eslint-disable-next-line no-unused-expressions
      view.offsetHeight;
      view.style.animation = "";
    }
    // Always reveal the nav on a fresh page render
    const navEl2 = document.querySelector(".nav");
    if (navEl2) navEl2.classList.add("visible");
  }

  /* ---------- Per-view event binding ---------- */
  function bindViewEvents() {
    const route = getRoute();

    if (route === "/" || route === "" || route.startsWith("/search")) {
      const input = document.getElementById("search");
      if (input) {
        let debounce;
        input.addEventListener("input", (e) => {
          clearTimeout(debounce);
          const val = e.target.value;
          debounce = setTimeout(() => {
            const games = DATA.games.filter(
              (g) =>
                !val.trim() ||
                g.name.toLowerCase().includes(val.trim().toLowerCase()) ||
                (g.sub || "").toLowerCase().includes(val.trim().toLowerCase())
            );
            const q = val.trim();
            const cards = games
              .map(
                (g) => `
                <a class="card" href="#/game/${g.id}">
                  <div class="card-img">
                    <span class="img-gradient" style="background:${g.gradient}"></span>
                    ${thumbDisplay(g)}
                  </div>
                  <div class="card-body">
                    <span class="card-title">${escapeHtml(g.name)}</span>
                    <span class="card-sub">${escapeHtml(g.sub || "")}</span>
                    <span class="card-badge">${g.exploits.length} script${g.exploits.length === 1 ? "" : "s"}</span>
                  </div>
                </a>`
              )
              .join("");
            const listHtml = games.length
              ? `<div class="grid grid-games">${cards}</div>`
              : `<div class="empty-state"><span class="emoji">🔍</span><p>No games found for "<strong>${escapeHtml(q)}</strong>". Try another name.</p></div>`;
            const grid = app.querySelector(".grid, .empty-state");
            const label = app.querySelector(".section-label");
            if (label) label.textContent = `${q ? "Results" : "Popular games"} · ${games.length}`;
            if (grid) {
              grid.outerHTML = listHtml;
            } else if (label) {
              label.insertAdjacentHTML("afterend", listHtml);
            }
            input.focus();
            const len = input.value.length;
            input.setSelectionRange(len, len);
            initMotion(app);
          }, 160);
        });
      }
    }

    const exploitSearch = document.getElementById("exploit-search");
    if (exploitSearch) {
      const countLabel = document.getElementById("exploit-count");
      const route = getRoute();
      const gameId = route.split("/")[2];
      const game = DATA.games.find((g) => g.id === gameId);
      let debounce;
      exploitSearch.addEventListener("input", (e) => {
        clearTimeout(debounce);
        const q = e.target.value.trim().toLowerCase();
        debounce = setTimeout(() => {
          const matches = game.exploits.filter(
            (ex) =>
              !q ||
              ex.title.toLowerCase().includes(q) ||
              (ex.short || "").toLowerCase().includes(q)
          );
          // Re-query each time: outerHTML replaces the live node, so the old
          // reference would become detached after the first filter.
          const grid = document.getElementById("exploits-grid");
          if (grid) {
            grid.outerHTML = `<div class="grid grid-exploits" id="exploits-grid">${cardsHtmlStatic(game, matches)}</div>`;
          }
          if (countLabel) {
            countLabel.textContent = `${q ? "Results" : "Available scripts"} · ${matches.length}`;
          }
          initMotion(app);
        }, 140);
      });
    }

    const copyBtn = document.getElementById("copyBtn");
    if (copyBtn) {
      copyBtn.addEventListener("click", async () => {
        const codeEl = document.getElementById("loadstringCode");
        const route = getRoute();
        const parts = route.split("/");
        const game = DATA.games.find((g) => g.id === parts[2]);
        const exploit = game && game.exploits.find((e) => e.id === parts[3]);
        const text = exploit ? exploit.loadstring : codeEl.textContent;
        const ok = await copyText(text);
        const label = copyBtn.querySelector(".copy-label");
        if (ok) {
          copyBtn.classList.add("copied");
          if (label) label.textContent = "Copied!";
          showToast("Loadstring copied to clipboard");
          setTimeout(() => {
            copyBtn.classList.remove("copied");
            if (label) label.textContent = "Copy";
          }, 1800);
        } else {
          showToast("Copy failed — select and copy manually");
        }
      });
    }

    // Drag-to-scroll + shift+wheel for the code block
    enableCodeScroll();
  }

  /* Drag-to-scroll & wheel hijack for code blocks (re-bound every render) */
  function enableCodeScroll() {
    const pre = document.querySelector(".code-block pre");
    if (!pre || pre.__scrollBound) return;
    pre.__scrollBound = true;

    // Shift + vertical wheel = horizontal scroll
    pre.addEventListener("wheel", (e) => {
      if (e.shiftKey) {
        if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) {
          pre.scrollLeft += e.deltaY;
          e.preventDefault();
        }
        return;
      }
      // If content is scrollable and wheel is vertical, convert to horizontal
      const canScroll = pre.scrollWidth > pre.clientWidth;
      if (canScroll && Math.abs(e.deltaY) > Math.abs(e.deltaX)) {
        const maxScroll = pre.scrollWidth - pre.clientWidth;
        const atStart = pre.scrollLeft <= 0 && e.deltaY < 0;
        const atEnd = pre.scrollLeft >= maxScroll && e.deltaY > 0;
        if (!atStart && !atEnd) {
          pre.scrollLeft += e.deltaY;
          e.preventDefault();
        }
      }
    }, { passive: false });

    // Click-and-drag to scroll (desktop)
    let isDown = false;
    let startX = 0;
    let startScroll = 0;
    let moved = false;

    pre.addEventListener("pointerdown", (e) => {
      // Don't hijack if user is trying to select text (shift) or it's a touch (handled natively)
      if (e.pointerType === "touch") return;
      isDown = true;
      moved = false;
      startX = e.clientX;
      startScroll = pre.scrollLeft;
      pre.setPointerCapture(e.pointerId);
    });
    pre.addEventListener("pointermove", (e) => {
      if (!isDown) return;
      const dx = e.clientX - startX;
      if (Math.abs(dx) > 4) moved = true;
      pre.scrollLeft = startScroll - dx;
    });
    function endDrag(e) {
      if (!isDown) return;
      isDown = false;
      try { pre.releasePointerCapture(e.pointerId); } catch (_) {}
      // Suppress the click that follows a drag so we don't trigger card nav etc.
      if (moved) {
        pre.addEventListener("click", (ev) => ev.stopPropagation(), { capture: true, once: true });
      }
    }
    pre.addEventListener("pointerup", endDrag);
    pre.addEventListener("pointercancel", endDrag);
  }

  /* ---------- Nav interactions ---------- */
  const navToggle = document.getElementById("navToggle");
  const navLinks = document.getElementById("navLinks");

  function closeMobileNav() {
    navLinks.classList.remove("open");
    navToggle.classList.remove("open");
    navToggle.setAttribute("aria-expanded", "false");
  }

  if (navToggle) {
    navToggle.addEventListener("click", () => {
      const open = navLinks.classList.toggle("open");
      navToggle.classList.toggle("open", open);
      navToggle.setAttribute("aria-expanded", open ? "true" : "false");
    });
  }

  navLinks.querySelectorAll("a").forEach((a) => {
    a.addEventListener("click", closeMobileNav);
  });

  // Discord button -> modal
  const discordBtn = document.getElementById("discordBtn");
  const discordModal = document.getElementById("discordModal");
  const discordModalClose = document.getElementById("discordModalClose");

  function openDiscordModal(e) {
    if (e) { e.preventDefault(); }
    discordModal.classList.add("open");
    discordModal.setAttribute("aria-hidden", "false");
    if (location.hash === "#discord" || location.hash === "#/discord") {
      history.replaceState(null, "", location.pathname + location.search);
    }
  }
  function closeDiscordModal() {
    discordModal.classList.remove("open");
    discordModal.setAttribute("aria-hidden", "true");
  }

  if (discordBtn) discordBtn.addEventListener("click", openDiscordModal);
  if (discordModalClose) discordModalClose.addEventListener("click", closeDiscordModal);
  discordModal.addEventListener("click", (e) => { if (e.target === discordModal) closeDiscordModal(); });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeDiscordModal(); });

  /* ---------- Init ---------- */

  /* Motion engine — faint cursor glow + magnetic buttons (no tilt) */
  const prefersReduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const isCoarse = window.matchMedia("(pointer: coarse)").matches;

  function initCardGlow(scope) {
    if (prefersReduced || isCoarse) return;
    const cards = (scope || document).querySelectorAll(".card");
    cards.forEach((card) => {
      if (card.__glowBound) return;
      card.__glowBound = true;
      let raf = null;
      card.addEventListener("pointermove", (e) => {
        const rect = card.getBoundingClientRect();
        const px = ((e.clientX - rect.left) / rect.width) * 100;
        const py = ((e.clientY - rect.top) / rect.height) * 100;
        if (raf) cancelAnimationFrame(raf);
        raf = requestAnimationFrame(() => {
          card.style.setProperty("--mx", px.toFixed(1) + "%");
          card.style.setProperty("--my", py.toFixed(1) + "%");
        });
      });
    });
  }

  function initMagnetic() {
    if (prefersReduced || isCoarse) return;
    document.querySelectorAll(".btn, .btn-discord-lg, .nav-discord, .copy-btn, .back-btn").forEach((el) => {
      if (el.__magBound) return;
      el.__magBound = true;
      let raf = null;
      el.addEventListener("pointermove", (e) => {
        const rect = el.getBoundingClientRect();
        const dx = e.clientX - (rect.left + rect.width / 2);
        const dy = e.clientY - (rect.top + rect.height / 2);
        if (raf) cancelAnimationFrame(raf);
        raf = requestAnimationFrame(() => {
          el.style.translate = `${(dx * 0.18).toFixed(1)}px ${(dy * 0.18).toFixed(1)}px`;
        });
      });
      el.addEventListener("pointerleave", () => {
        if (raf) cancelAnimationFrame(raf);
        el.style.translate = "0 0";
      });
    });
  }

  function initMotion(scope) {
    initCardGlow(scope);
    initMagnetic();
  }

  initNavHoverIndicator();
  initMotion();
  window.addEventListener("resize", () => {
    const route = getRoute();
    // Determine active route for indicator
    let activeRoute = "/";
    if (route === "/executors" || route.startsWith("/executor/")) activeRoute = "/executors";
    positionNavIndicator(activeRoute);
  });

  window.addEventListener("hashchange", render);

  /* ---------- Scroll-aware nav: hide on scroll down, show on scroll up ---------- */
  const navEl = document.querySelector(".nav");
  let lastScrollY = window.scrollY;
  let ticking = false;

  function updateNavOnScroll() {
    const currentY = window.scrollY;
    // Always show nav near the top of the page
    if (currentY <= 80) {
      navEl.classList.add("visible");
    } else if (currentY > lastScrollY + 8) {
      // Scrolling down — hide
      navEl.classList.remove("visible");
      closeMobileNav();
    } else if (currentY < lastScrollY - 8) {
      // Scrolling up — show
      navEl.classList.add("visible");
    }
    lastScrollY = currentY;
    ticking = false;
  }

  window.addEventListener(
    "scroll",
    () => {
      if (!ticking) {
        window.requestAnimationFrame(updateNavOnScroll);
        ticking = true;
      }
    },
    { passive: true }
  );

  // Start visible
  navEl.classList.add("visible");

  if (location.hash === "#discord" || location.hash === "#/discord") {
    history.replaceState(null, "", location.pathname + location.search);
    render();
    setTimeout(openDiscordModal, 100);
  } else {
    render();
  }
})();
