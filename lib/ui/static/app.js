// airlock ui (D36). Every fact here comes from `airlock status --json`, by way
// of the server; every change is an airlock command the server runs as a job.
//
// Branch names, task names and command output are written by agents, so
// nothing from the server ever reaches innerHTML: the page is built with
// textContent only.
"use strict";

// --- the token -------------------------------------------------------------
//
// It arrives in the fragment of the URL `airlock ui` printed, which the
// browser never sends; it is kept for this tab and taken out of the address.

const TOKEN = (() => {
  const m = location.hash.match(/token=([A-Za-z0-9_-]+)/);
  try {
    if (m) {
      sessionStorage.setItem("airlock-token", m[1]);
      history.replaceState(null, "", location.pathname);
      return m[1];
    }
    return sessionStorage.getItem("airlock-token") || "";
  } catch (_) {
    return m ? m[1] : "";
  }
})();

async function api(path, body) {
  const opts = { headers: { Authorization: "Bearer " + TOKEN } };
  if (body !== undefined) {
    opts.method = "POST";
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(body);
  }
  const res = await fetch("/api/" + path, opts);
  let data = null;
  try { data = await res.json(); } catch (_) { /* reported below */ }
  if (!res.ok) {
    const err = new Error((data && data.error) || res.status + " " + res.statusText);
    err.status = res.status;
    throw err;
  }
  return data;
}

// --- DOM -------------------------------------------------------------------

function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === "class") el.className = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (v === true) el.setAttribute(k, "");
    else el.setAttribute(k, v);
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

const $ = (sel, root = document) => root.querySelector(sel);
const plural = (n, one, many) => n + " " + (n === 1 ? one : (many || one + "s"));

function dot(kind) { return h("span", { class: kind ? "dot dot-" + kind : "dot" }); }

function copyButton(text) {
  const b = h("button", { type: "button", class: "ghost small", title: "Copy to the clipboard" }, "Copy");
  b.addEventListener("click", async (e) => {
    e.stopPropagation();
    try {
      await navigator.clipboard.writeText(text);
      b.textContent = "Copied";
    } catch (_) {
      b.textContent = "Select it";
    }
    setTimeout(() => { b.textContent = "Copy"; }, 1500);
  });
  return b;
}

function copyLine(text) {
  return h("div", { class: "copyline" }, h("code", {}, text), copyButton(text));
}

// Shell quoting for commands shown to copy: names are narrow, but be exact.
function sh(word) {
  return /^[A-Za-z0-9._\/:=@%+-]+$/.test(word) ? word : "'" + word.replace(/'/g, "'\\''") + "'";
}

// --- state -----------------------------------------------------------------

const state = {
  status: null,          // airlock status --json
  details: new Map(),    // workspace -> airlock status <name> --json, or {error}
  open: new Set(),       // workspaces shown expanded
  error: null,
};

try {
  for (const n of JSON.parse(sessionStorage.getItem("airlock-open") || "[]")) state.open.add(n);
} catch (_) { /* a convenience only */ }
function saveOpen() {
  try { sessionStorage.setItem("airlock-open", JSON.stringify([...state.open])); } catch (_) { /* ignore */ }
}

// --- refreshing --------------------------------------------------------------

let refreshing = null;

async function refresh() {
  if (refreshing) return refreshing;
  refreshing = (async () => {
    try {
      state.status = await api("status");
      state.error = null;
      const names = new Set(state.status.workspaces.map((w) => w.name));
      for (const n of [...state.open]) if (!names.has(n)) state.open.delete(n);
      await Promise.all([...state.open].map(loadDetail));
      $("#updated").textContent = "updated " + new Date().toLocaleTimeString();
    } catch (e) {
      state.error = e;
    } finally {
      refreshing = null;
      render();
    }
  })();
  return refreshing;
}

async function loadDetail(name) {
  try {
    state.details.set(name, await api("workspaces/" + encodeURIComponent(name)));
  } catch (e) {
    state.details.set(name, { error: e.message });
  }
}

// Every few seconds while the tab is visible; at once when it becomes so.
setInterval(() => { if (!document.hidden) refresh(); }, 5000);
document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); });

// --- rendering ---------------------------------------------------------------

function render() {
  const notice = $("#notice");
  if (!TOKEN) {
    notice.hidden = false;
    notice.textContent = "This page needs the URL `airlock ui` printed, token and all. Open that.";
  } else if (state.error) {
    notice.hidden = false;
    notice.textContent = state.error.status === 401
      ? "The token was refused: this tab is from an earlier `airlock ui`. Open the URL it printed this time."
      : "Could not read status: " + state.error.message;
  } else {
    notice.hidden = true;
  }
  renderServices();
  renderWorkspaces();
}

function renderServices() {
  const box = $("#services");
  box.replaceChildren();
  const s = state.status && state.status.services;
  if (!s) return;
  const hub = s.hub.state;
  box.append(h("span", { class: "chip", title: "The SSH service guests fetch from and push to (D33)" },
    dot(hub === "active" ? "ok" : hub === "failed" ? "bad" : hub === "activating" ? "warn" : ""),
    "hub " + (hub || "unknown"),
    hub === null ? null : h("button", {
      type: "button", class: "ghost",
      onclick: () => startJob(hub === "active" ? "hub/stop" : "hub/start", {}),
    }, hub === "active" ? "stop" : "start")));

  const regs = s.registry;
  const known = regs.filter((r) => r.state !== null);
  const up = regs.filter((r) => r.state === "active").length;
  box.append(h("span", {
    class: "chip",
    title: regs.map((r) => r.upstream + " :" + r.port + " " + (r.state || "unknown")).join("\n"),
  },
  dot(up === regs.length ? "ok" : up ? "warn" : ""),
  known.length ? "registry caches " + up + "/" + regs.length : "registry caches unknown",
  known.length ? h("button", {
    type: "button", class: "ghost",
    onclick: () => startJob(up ? "registry/stop" : "registry/start", {}),
  }, up ? "stop" : "start") : null));
}

function renderWorkspaces() {
  const box = $("#workspaces");
  if (!state.status) {
    if (!box.childElementCount && TOKEN && !state.error) box.append(h("p", { class: "empty" }, "Loading…"));
    return;
  }
  const wss = state.status.workspaces;
  if (!wss.length) {
    box.replaceChildren(h("div", { class: "empty" },
      h("p", {}, "No workspaces yet."),
      h("button", { type: "button", class: "primary", onclick: openNewWorkspace }, "Create one")));
    return;
  }
  // Rebuilt whole each time; keep what the person is looking at in place.
  const y = window.scrollY;
  box.replaceChildren(...wss.map(renderWorkspace));
  window.scrollTo(0, y);
}

function renderWorkspace(ws) {
  const open = state.open.has(ws.name);
  const card = h("article", { class: "ws" + (open ? " open" : "") + (ws.ok ? "" : " broken") });
  const toggle = () => {
    if (state.open.has(ws.name)) state.open.delete(ws.name);
    else { state.open.add(ws.name); loadDetail(ws.name).then(render); }
    saveOpen();
    render();
  };

  const meta = h("div", { class: "ws-meta" });
  if (!ws.ok) {
    meta.append(h("span", { class: "chip" }, dot("bad"), "broken — run airlock doctor " + ws.name));
  } else {
    const running = ws.tasks.filter((t) => t.running).length;
    const drift = ws.tasks.some((t) => t.running && (t.drift.length || t.plan_broken));
    meta.append(h("span", { class: "chip" },
      dot(running ? (drift ? "warn" : "ok") : ""),
      ws.tasks.length ? plural(ws.tasks.length, "task") + (running ? ", " + running + " running" : "") : "no tasks"));
    meta.append(h("span", { class: "chip", title: "Hub branches carrying commits " + (ws.default_branch || "the default branch") + " lacks" },
      ws.ahead.length
        ? plural(ws.ahead.length, "branch", "branches") + " ahead, " + plural(ws.commits, "commit")
        : "nothing ahead of " + (ws.default_branch || "the default branch")));
    if (ws.substrate_override) meta.append(h("span", { class: "chip", title: ws.substrate || "" }, "own substrate"));
  }

  card.append(h("div", {
    class: "ws-head", role: "button", tabindex: "0", "aria-expanded": String(open),
    onclick: toggle,
    onkeydown: (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggle(); } },
  },
  h("span", { class: "caret", "aria-hidden": "true" }, "▸"),
  h("div", { class: "ws-title" },
    h("h2", {}, ws.name),
    h("span", { class: "muted" }, [ws.project, ws.flavor, ws.default_branch].filter(Boolean).join(" · "))),
  meta));

  if (open && ws.ok) card.append(renderDetail(ws));
  return card;
}

function renderDetail(ws) {
  const body = h("div", { class: "ws-body" });
  const d = state.details.get(ws.name);
  if (!d) { body.append(h("p", { class: "muted" }, "Loading…")); return body; }
  if (d.error) { body.append(h("p", { class: "warn" }, d.error)); return body; }

  // Tasks.
  body.append(h("section", {},
    h("div", { class: "section-head" },
      h("h3", {}, "Tasks"),
      h("div", { class: "actions" },
        h("button", { type: "button", class: "primary small", onclick: () => openNewTask(ws.name) }, "New task"))),
    d.tasks.length ? renderTasks(ws, d) : h("p", { class: "muted" }, "None yet. A task is a branch, a worktree and a VM of its own.")));

  // Hub.
  const hubHead = h("div", { class: "section-head" },
    h("h3", {}, "Hub"),
    h("div", { class: "actions" },
      h("button", {
        type: "button", class: "small",
        title: "airlock fetch: refresh the hub from its upstreams",
        disabled: d.upstreams.length ? null : true,
        onclick: () => startJob("workspaces/" + encodeURIComponent(ws.name) + "/fetch", {}),
      }, "Fetch upstreams")));
  const ahead = d.ahead.length
    ? h("div", { class: "table-wrap" }, h("table", {},
        h("thead", {}, h("tr", {}, h("th", {}, "Branch ahead of " + (d.default_branch || "the default branch")), h("th", {}, "Commits"))),
        h("tbody", {}, d.ahead.map((a) => h("tr", {}, h("td", { class: "mono" }, a.branch), h("td", {}, String(a.commits)))))))
    : h("p", { class: "muted" }, "Nothing ahead of " + (d.default_branch || "the default branch") + ".");
  body.append(h("section", {}, hubHead, ahead,
    h("p", { class: "muted small" }, "Review in your own checkout:"),
    copyLine('git remote add hub "$(airlock path ' + sh(ws.name) + ')"')));

  // Facts.
  const kv = h("dl", { class: "kv" });
  const fact = (k, v) => kv.append(h("dt", {}, k), h("dd", {}, v));
  fact("root", h("span", { class: "mono" }, d.root));
  fact("upstreams", d.upstreams.length
    ? d.upstreams.map((u, i) => [i ? ", " : "", h("span", { class: "mono" }, u.name + " → " + (u.url || "?")), " (" + plural(u.refs, "ref") + ")"])
    : "none configured");
  fact("substrate", h("span", { class: "mono" }, (d.substrate || "none pinned") + (d.substrate_override ? " (own)" : "")));
  if (d.nixpkgs) fact("nixpkgs", h("span", { class: "mono" }, d.nixpkgs));
  if (!d.repository) fact("repository", h("span", { class: "drift" }, "missing — run airlock doctor " + ws.name));
  body.append(h("section", {}, h("div", { class: "section-head" }, h("h3", {}, "Workspace")), kv));
  return body;
}

function renderTasks(ws, d) {
  const rows = d.tasks.map((t) => {
    const run = "airlock run " + sh(ws.name) + " " + sh(t.name);
    let st;
    if (t.running) {
      st = h("span", { class: "state" }, dot(t.drift.length || t.plan_broken ? "warn" : "ok"),
        "running" + (t.pid ? " (pid " + t.pid + ")" : ""));
    } else {
      st = h("span", { class: "state" }, dot(), "stopped");
    }
    const notes = [];
    if (t.plan_broken) notes.push(h("div", { class: "drift" }, "config changed; would not launch now"));
    else if (t.drift.length) notes.push(h("div", { class: "drift" }, "config changed since launch: " + t.drift.join(", ")));

    let tree;
    if (!t.worktree) tree = h("span", { class: "drift" }, "worktree missing");
    else {
      const bits = [];
      bits.push(t.changes ? plural(t.changes, "uncommitted change") : "clean");
      if (t.unpushed) bits.push(plural(t.unpushed, "unpushed commit"));
      tree = h("span", { class: t.changes || t.unpushed ? "drift" : "muted" }, bits.join(", "));
    }

    const actions = h("td", { class: "actions" });
    if (t.running) {
      actions.append(h("button", {
        type: "button", class: "small",
        title: "airlock stop: power the VM off from outside",
        onclick: () => startJob(taskPath(ws.name, t.name, "stop"), {}),
      }, "Stop"));
    } else {
      // A run is the agent's terminal session, which belongs in a terminal.
      actions.append(copyButtonLabelled("Copy run command", run));
      actions.append(h("button", {
        type: "button", class: "small ghost",
        onclick: () => openRemoveTask(ws.name, t),
      }, "Remove"));
    }

    return h("tr", {},
      h("td", {}, h("strong", {}, t.name), notes),
      h("td", {}, st),
      h("td", { class: "mono" }, t.on || (t.worktree ? "detached" : "?")),
      h("td", {}, tree),
      actions);
  });
  return h("div", { class: "table-wrap" }, h("table", {},
    h("thead", {}, h("tr", {}, h("th", {}, "Task"), h("th", {}, "VM"), h("th", {}, "On"), h("th", {}, "Worktree"), h("th", {}))),
    h("tbody", {}, rows)));
}

function copyButtonLabelled(label, text) {
  const b = copyButton(text);
  b.textContent = label;
  b.title = text;
  b.addEventListener("click", () => setTimeout(() => { b.textContent = label; }, 1600));
  return b;
}

const taskPath = (ws, task, action) =>
  "workspaces/" + encodeURIComponent(ws) + "/tasks/" + encodeURIComponent(task) + (action ? "/" + action : "");

// --- jobs --------------------------------------------------------------------

const jobs = new Map();  // id -> {view, el, pre, offset}

async function startJob(path, body) {
  try {
    const view = await api(path, body);
    trackJob(view, true);
    return view;
  } catch (e) {
    showJobs();
    $("#job-list").prepend(h("li", { class: "job" },
      h("details", { open: true }, h("summary", {}, dot("bad"), "could not start: " + path), h("pre", {}, e.message))));
    return null;
  }
}

function trackJob(view, fresh) {
  const pre = h("pre", {});
  const summary = h("summary", {});
  const det = h("details", { open: fresh || null }, summary, pre);
  const el = h("li", { class: "job" }, det);
  const job = { view, el, pre, summary, offset: 0 };
  jobs.set(view.id, job);
  $("#job-list").prepend(el);
  updateJob(job, view);
  if (fresh) showJobs();
  if (view.state === "running") pollJob(job);
}

function updateJob(job, view) {
  job.view = view;
  if (view.output) {
    const atEnd = job.pre.scrollTop + job.pre.clientHeight >= job.pre.scrollHeight - 4;
    job.pre.append(view.output);
    if (atEnd) job.pre.scrollTop = job.pre.scrollHeight;
  }
  job.offset = view.offset;
  const kind = view.state === "running" ? "warn" : view.state === "ok" ? "ok" : "bad";
  job.summary.replaceChildren(dot(kind),
    h("span", {}, view.title),
    h("span", { class: "muted small when" },
      view.state === "running" ? "running…" : view.state === "ok" ? "done" : "failed (exit " + view.code + ")"));
  if (!job.pre.textContent) job.pre.textContent = view.state === "running" ? "" : "(no output)";
  updateJobsToggle();
}

async function pollJob(job) {
  while (true) {
    await new Promise((r) => setTimeout(r, 700));
    let view;
    try {
      view = await api("jobs/" + job.view.id + "?since=" + job.offset);
    } catch (e) {
      // A restarted server has neither this job nor this token.
      if (e.status === 401 || e.status === 404) return null;
      continue;
    }
    updateJob(job, view);
    if (view.state !== "running") {
      refresh();
      return view;
    }
  }
}

function showJobs() { $("#jobs").hidden = false; $("#jobs-toggle").hidden = true; }
function hideJobs() { $("#jobs").hidden = true; updateJobsToggle(); }
function updateJobsToggle() {
  const t = $("#jobs-toggle");
  const running = [...jobs.values()].filter((j) => j.view.state === "running").length;
  t.textContent = running ? "Commands (" + running + " running)" : "Commands";
  t.hidden = !$("#jobs").hidden || jobs.size === 0;
}

$("#jobs-close").addEventListener("click", hideJobs);
$("#jobs-toggle").addEventListener("click", showJobs);

// Jobs started before this page was loaded, such as by another tab.
async function loadJobs() {
  try {
    const { jobs: views } = await api("jobs");
    for (const v of views) if (!jobs.has(v.id)) trackJob(v, false);
  } catch (_) { /* refresh reports a bad token */ }
}

// --- dialogs -------------------------------------------------------------------

for (const b of document.querySelectorAll("[data-close]")) {
  b.addEventListener("click", () => b.closest("dialog").close());
}

function openNewWorkspace() {
  const f = $("#form-workspace");
  f.reset();
  syncSource();
  $("#dlg-workspace").showModal();
}
function syncSource() {
  const f = $("#form-workspace");
  const local = f.source.value === "local";
  $("#location-label").textContent = local ? "Path" : "URL";
  f.location.placeholder = local ? "/home/you/src/project" : "https://github.com/acme/widget";
}
$("#new-workspace").addEventListener("click", openNewWorkspace);
for (const r of document.querySelectorAll("#form-workspace input[name=source]")) r.addEventListener("change", syncSource);

$("#form-workspace").addEventListener("submit", (e) => {
  const f = e.target;
  if (e.submitter && e.submitter.value !== "ok") return;
  const body = {
    name: f.elements.namedItem("name").value.trim(),
    source: f.source.value,
    location: f.location.value.trim(),
    branch: f.branch.value.trim(),
    project: f.project.value.trim(),
    flavor: f.flavor.value,
  };
  startJob("workspaces", body).then((v) => { if (v) { state.open.add(body.name); saveOpen(); } });
});

let taskWs = null;
function openNewTask(ws) {
  taskWs = ws;
  const f = $("#form-task");
  f.reset();
  $("[data-ws]", f).textContent = ws;
  $("[data-task-name]", f).textContent = "…";
  $("#dlg-task").showModal();
}
$("#form-task").task.addEventListener("input", (e) => {
  $("[data-task-name]", $("#form-task")).textContent = e.target.value || "…";
});
$("#form-task").addEventListener("submit", (e) => {
  const f = e.target;
  if (e.submitter && e.submitter.value !== "ok") return;
  startJob("workspaces/" + encodeURIComponent(taskWs) + "/tasks", {
    task: f.task.value.trim(),
    prompt: f.prompt.value,
    base: f.base.value.trim(),
  });
});

// The same two levels of asking as `airlock task rm`: a yes when nothing would
// be lost, the task's name typed when something would. What would be lost is
// status's offline view; task rm checks again after fetching the hub.
let removing = null;
function openRemoveTask(ws, t) {
  removing = { ws, task: t.name };
  const f = $("#form-remove");
  f.reset();
  for (const el of f.querySelectorAll("[data-task]")) el.textContent = t.name;
  const lost = [];
  if (t.changes) lost.push(plural(t.changes, "uncommitted change") + " in its worktree");
  if (t.unpushed) lost.push(plural(t.unpushed, "commit") + " on agent/" + t.name + " not pushed to the hub");
  const pending = $("[data-pending]", f);
  pending.hidden = !lost.length;
  pending.replaceChildren(
    "It holds work the hub does not have. Removing the task loses it:",
    h("ul", {}, lost.map((l) => h("li", {}, l))));
  const typed = $("[data-typed]", f);
  typed.hidden = !lost.length;
  f.confirm.required = lost.length > 0;
  f.confirm.setCustomValidity("");
  $("#dlg-remove").showModal();
}
$("#form-remove").confirm.addEventListener("input", (e) => {
  e.target.setCustomValidity(removing && e.target.value !== removing.task ? "Type the task name exactly" : "");
});
$("#form-remove").addEventListener("submit", (e) => {
  if (e.submitter && e.submitter.value !== "ok") return;
  if (!removing) return;
  startJob(taskPath(removing.ws, removing.task, "rm"), {});
  removing = null;
});

// --- start -----------------------------------------------------------------------

render();
if (TOKEN) { refresh(); loadJobs(); }
