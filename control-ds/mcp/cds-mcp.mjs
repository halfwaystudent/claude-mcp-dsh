#!/usr/bin/env node
// control-ds MCP server: lets Claude Code drive DeepSeek V4.1 Flash (Command Code channel) inside
// DeepSeek Harness (dsh) through one long-lived ACP process. Stdio JSON-RPC (MCP), no extra deps.
// Rules enforced here: model must be commandcode/deepseek-v4.1-flash, modes only workspace-write/read-only,
// permission escalations are always rejected, one dsh process at a time, context limits from config.json.
import { spawn, spawnSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import net from 'node:net'
import { Readable, Writable } from 'node:stream'
import { pathToFileURL, fileURLToPath } from 'node:url'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

console.log = (...a) => console.error(...a)   // stdout belongs to MCP

const HERE = path.dirname(fileURLToPath(import.meta.url))
const SKILL = path.dirname(HERE)
const CFG = JSON.parse(fs.readFileSync(path.join(SKILL, 'config.json'), 'utf8'))
const RUNS = CFG.runsDir.replace(/%([^%]+)%/g, (_, v) => process.env[v] ?? '')
fs.mkdirSync(RUNS, { recursive: true })
const OVERLAY = path.join(SKILL, 'assets', 'acp-flash-overlay.yml').replace(/\\/g, '/')

// Fixed install first (<dshRuntimeRoot>\<version>, see config.json); the npx cache is only a fallback because it
// disappears when the npm cache is cleaned. Returns { nm, source } or null.
function findDsh(version) {
  const expand = s => s.replace(/%([^%]+)%/g, (_, v) => process.env[v] ?? '')
  const dirs = []
  if (CFG.dshRuntimeRoot) dirs.push({ dir: path.join(expand(CFG.dshRuntimeRoot), version), source: 'fixed' })
  const root = path.join(process.env.LOCALAPPDATA ?? '', 'npm-cache', '_npx')
  for (const d of fs.existsSync(root) ? fs.readdirSync(root) : []) dirs.push({ dir: path.join(root, d), source: 'npx-cache' })
  for (const { dir, source } of dirs) {
    const nm = path.join(dir, 'node_modules')
    const pj = path.join(nm, '@deepseek-ai', 'dsh', 'package.json')
    try { if (JSON.parse(fs.readFileSync(pj, 'utf8')).version === version) return { nm, source } } catch {}
  }
  return null
}
const DSH = findDsh(CFG.dshVersion)
const NM = DSH?.nm
const INSTALL_HINT = `npm install @deepseek-ai/dsh@${CFG.dshVersion} --prefix "${path.join((CFG.dshRuntimeRoot ?? '').replace(/%([^%]+)%/g, (_, v) => process.env[v] ?? ''), CFG.dshVersion)}"`
let ACP = null

// read-only sandbox fix: dsh's read-only token can write nowhere, not even %TEMP%. Windows PowerShell 5.1 then fails
// its AppLocker probe (it writes a test script to %TEMP%) and drops to ConstrainedLanguage, so every pwsh command fails
// on dsh's encoding preamble. A dedicated scratch dir that Everyone may modify and that is labeled Low is writable
// for the read-only token (Everyone is in its restricting list) without granting anything else.
const RO_TEMP = (CFG.readOnlyTempDir ?? '').replace(/%([^%]+)%/g, (_, v) => process.env[v] ?? '')
function ensureRoTemp() {
  if (!RO_TEMP) throw new Error('config.readOnlyTempDir is not set')
  fs.mkdirSync(RO_TEMP, { recursive: true })
  for (const args of [['/grant', '*S-1-1-0:(OI)(CI)M'], ['/setintegritylevel', '(OI)(CI)L']]) {
    const r = spawnSync('icacls', [RO_TEMP, ...args], { windowsHide: true, encoding: 'utf8' })
    if (r.status !== 0) throw new Error(`icacls ${args.join(' ')} failed on ${RO_TEMP}: ${(r.stdout || '') + (r.stderr || '')}`)
  }
  return RO_TEMP
}
async function loadAcp() {
  if (!NM) throw new Error(`dsh ${CFG.dshVersion} not installed. Run: ${INSTALL_HINT}`)
  if (!ACP) ACP = await import(pathToFileURL(path.join(NM, '@agentclientprotocol', 'sdk', 'dist', 'acp.js')).href)
  return ACP
}

// ---------------- state ----------------
let S = null   // { child, agent, workspace, mode, sessionId, transcript, busy, turn, usage, stderr, dead, perms }
const now = () => new Date().toISOString()
const clip = (s, n) => (typeof s === 'string' && s.length > n ? s.slice(0, n) + `…(+${s.length - n})` : s)

function rec(kind, data) {
  if (!S?.transcript) return
  try { fs.appendFileSync(S.transcript, JSON.stringify({ t: now(), kind, ...data }) + '\n') } catch {}
}

// Session registry (survives MCP restarts): RUNS/sessions.json, keyed by sessionId.
const REGISTRY = path.join(RUNS, 'sessions.json')
function loadRegistry() {
  try { return JSON.parse(fs.readFileSync(REGISTRY, 'utf8')) } catch { return {} }
}
function remember(entry) {
  const reg = loadRegistry()
  reg[entry.sessionId] = { ...reg[entry.sessionId], ...entry, updatedAt: now() }
  const tmp = REGISTRY + '.tmp'
  try { fs.writeFileSync(tmp, JSON.stringify(reg, null, 2)); fs.renameSync(tmp, REGISTRY) } catch {}
}
const sameDir = (a, b) => !!a && !!b && path.resolve(a).toLowerCase() === path.resolve(b).toLowerCase()
// One-time backfill from transcripts written before the registry existed.
if (!fs.existsSync(REGISTRY)) {
  const reg = {}
  for (const f of fs.readdirSync(RUNS).filter(f => /^acp-.+\.jsonl$/.test(f))) {
    try {
      const lines = fs.readFileSync(path.join(RUNS, f), 'utf8').split('\n').filter(Boolean)
      const head = lines.map(l => JSON.parse(l)).find(x => x.kind === 'session')
      if (!head) continue
      const last = JSON.parse(lines.at(-1))
      reg[head.sessionId] = { sessionId: head.sessionId, workspace: head.workspace, mode: head.mode, transcript: path.join(RUNS, f), startedAt: head.t, updatedAt: last.t, backfilled: true }
    } catch {}
  }
  try { fs.writeFileSync(REGISTRY, JSON.stringify(reg, null, 2)) } catch {}
}
function sessionsFor(workspace) {
  return Object.values(loadRegistry())
    .filter(e => !workspace || sameDir(e.workspace, workspace))
    .sort((a, b) => (b.updatedAt ?? '').localeCompare(a.updatedAt ?? ''))
}

// ---------------- dsh web workspace registration ----------------
// ACP sessions are saved under ~/.dsh/sessions/<cwd>/ but the web UI only lists sessions owned by a workspace in
// ~/.dsh/storages/workspace.json. The running web server keeps that file in memory and only rescans session headers at
// startup, so it is edited only while the web server is down; otherwise the session stays pending until the next sync
// (web.ps1 start runs `node cds-mcp.mjs --sync-web` before launching the server).
const DSH_HOME = process.env.DSH_HOME || path.join(os.homedir(), '.dsh')
const WS_FILE = path.join(DSH_HOME, 'storages', 'workspace.json')
function webUp(port = 3080) {
  return new Promise(res => {
    const sock = net.connect({ host: '127.0.0.1', port })
    sock.setTimeout(800)
    sock.on('connect', () => { sock.destroy(); res(true) })
    sock.on('timeout', () => { sock.destroy(); res(false) })
    sock.on('error', () => res(false))
  })
}
function registerInWebFile(entries) {
  const doc = JSON.parse(fs.readFileSync(WS_FILE, 'utf8'))
  if (doc.unit?.name !== 'workspace' || doc.unit?.version !== 2 || !doc.global?.initialized || doc.global.pendingMutation) throw new Error(`unexpected ${WS_FILE} format/state; not touching it`)
  const table = doc.tables.workspaces
  const owned = new Set(Object.values(table).flatMap(w => w.sessionIds))
  const done = []
  for (const { workspace, sessionId } of entries) {
    if (owned.has(sessionId)) { done.push(sessionId); continue }
    let canon; try { canon = fs.realpathSync.native(workspace) } catch { continue }
    let id = Object.keys(table).find(k => sameDir(table[k].path, canon))
    const ts = now()
    if (!id) {
      id = randomUUID()
      table[id] = { path: canon, title: path.basename(canon), sessionIds: [], createdAt: ts, updatedAt: ts }
      doc.global.workspaceIds.unshift(id)
    }
    table[id].sessionIds.unshift(sessionId)
    table[id].updatedAt = ts
    owned.add(sessionId); done.push(sessionId)
  }
  const bak = WS_FILE + '.bak-cds'
  if (!fs.existsSync(bak)) fs.copyFileSync(WS_FILE, bak)
  const tmp = WS_FILE + '.tmp-cds'
  fs.writeFileSync(tmp, JSON.stringify(doc, null, 2)); fs.renameSync(tmp, WS_FILE)
  return done
}
async function syncWeb() {
  const tmpRoot = path.resolve(os.tmpdir()).toLowerCase() + path.sep
  const pending = Object.values(loadRegistry()).filter(e => !e.webRegistered && e.workspace && e.sessionId
    && !path.resolve(e.workspace).toLowerCase().startsWith(tmpRoot))   // scratch trials stay out of the web list
  if (!pending.length) return { synced: [], pending: [] }
  if (await webUp()) return { synced: [], pending: pending.map(e => e.sessionId), note: 'dsh web is running; restart it with web.ps1 to show these sessions' }
  const done = registerInWebFile(pending)
  for (const sessionId of done) remember({ sessionId, webRegistered: true })
  return { synced: done, pending: pending.map(e => e.sessionId).filter(x => !done.includes(x)) }
}

function onUpdate(u) {
  const k = u.sessionUpdate
  const T = S?.turn
  if (k === 'usage_update') {
    S.usage = { used: u.used, size: u.size }; rec('usage', S.usage)
    if (T && !T.done) {
      // one usage update per model call: count steps and the context re-sent each step (what the tokens are spent on)
      T.steps++; T.contextSent += u.used
      if (u.used >= CFG.hardLimitTokens) trip(T, `context ${u.used} >= ${CFG.hardLimitTokens} (stop before dsh auto-compaction)`)
      else if (T.steps > T.limits.steps) trip(T, `${T.limits.steps} model steps in one turn`)
    }
    return
  }
  if (!T) return
  T.lastEventAt = Date.now()
  if (k === 'agent_message_chunk' && u.content?.type === 'text') { T.reply += u.content.text; T.lastText = now() }
  else if (k === 'agent_thought_chunk' && u.content?.type === 'text') { T.thought += u.content.text }
  else if (k === 'tool_call') {
    // free-text fields ("attempt 3") must not make identical calls look different to the loop detector
    const { description, explanation, reason, purpose, ...input } = (u.rawInput && typeof u.rawInput === 'object') ? u.rawInput : { v: u.rawInput ?? null }
    const key = `${u.kind ?? ''}|${u.title ?? ''}|${JSON.stringify(input)}`
    T.tools.set(u.toolCallId, { title: u.title, kind: u.kind, status: u.status, at: now(), startedMs: Date.now(), key })
    T.events.push({ t: now(), e: `tool ${u.kind ?? ''} ${clip(u.title ?? '', 160)} [${u.status ?? ''}]` })
    rec('tool_call', { id: u.toolCallId, title: clip(u.title, 1000), toolKind: u.kind, status: u.status, rawInput: clip(JSON.stringify(u.rawInput ?? null), 3000) })
  } else if (k === 'tool_call_update') {
    const x = T.tools.get(u.toolCallId) ?? {}
    x.status = u.status ?? x.status
    T.tools.set(u.toolCallId, x)
    if (u.status && u.status !== 'in_progress') {
      const out = (u.content ?? []).map(c => c?.content?.text ?? c?.text ?? '').join(' ')
      T.events.push({ t: now(), e: `  -> ${u.status} ${clip(x.title ?? '', 80)}${u.status === 'failed' ? ' :: ' + clip(out, 200) : ''}` })
      rec('tool_result', { id: u.toolCallId, status: u.status, output: clip(out, 4000) })
      // loop detection: the same call with the same outcome over and over makes no progress but costs a full step each time
      const sig = `${x.key}|${u.status}|${out.slice(0, 2000)}`
      T.repeat = sig === T.lastSig ? T.repeat + 1 : 1
      T.lastSig = sig
      if (T.repeat >= T.limits.repeats) trip(T, `same tool call with the same result ${T.repeat} times in a row (${clip(x.title ?? '', 80)})`)
    }
  }
  if (T.events.length > 400) T.events.splice(0, T.events.length - 400)
}

// Token guard tripped: cancel the turn (session and memory stay). The process is never killed here; if the cancel does
// not take effect, status reports it as stuck and the coordinator decides (flash_shutdown).
function trip(T, why) {
  const s = S
  if (T.done || T.stoppedBy || !s || s.turn !== T) return
  T.stoppedBy = why; T.stoppedAt = now()
  T.events.push({ t: now(), e: `GUARD (${why}): cancelling turn` })
  rec('guard_cancel', { turn: T.n, reason: why })
  s.agent.notify(s.methods.agent.session.cancel, { sessionId: s.sessionId }).catch(() => {})
  setTimeout(() => { if (!T.done && !s.dead) { T.stuck = true; rec('guard_stuck', { turn: T.n }) } }, 60000).unref()
}

async function start({ workspace, mode = CFG.defaultMode, resume_session_id, model, reasoning_effort }) {
  if (!['workspace-write', 'read-only'].includes(mode)) throw new Error('mode must be workspace-write or read-only (danger-full-access is never allowed)')
  if (!workspace || !fs.existsSync(workspace)) throw new Error(`workspace not found: ${workspace}`)
  workspace = path.resolve(workspace)
  if (resume_session_id === 'last') {
    const last = sessionsFor(workspace)[0]
    if (!last) throw new Error(`no recorded flash session for workspace ${workspace}; start a new one (omit resume_session_id)`)
    resume_session_id = last.sessionId
  }
  if (S && !S.dead) {
    if (S.workspace.toLowerCase() === workspace.toLowerCase() && S.mode === mode && !resume_session_id) {
      if (model || reasoning_effort !== undefined) await setModel({ model, reasoning_effort })
      return { reused: true, ...brief() }
    }
    throw new Error(`a flash session is already running (workspace ${S.workspace}, mode ${S.mode}). Call flash_shutdown first (one dsh process at a time).`)
  }
  const freeGB = os.freemem() / 2 ** 30
  if (freeGB < CFG.minFreeGB) throw new Error(`free memory ${freeGB.toFixed(1)} GB < ${CFG.minFreeGB} GB; not starting`)
  const { client, methods, ndJsonStream } = await loadAcp()
  const child = spawn(process.execPath, [path.join(NM, '@deepseek-ai', 'dsh', 'lib', 'bin.js'), '--profile', 'acp', '--patch', OVERLAY], {
    cwd: workspace, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'],
    env: { ...process.env, DSH_PERMISSION_MODE: mode, PYTHONDONTWRITEBYTECODE: '1', PYTHONIOENCODING: 'utf-8',
      ...(mode === 'read-only' ? (t => ({ TEMP: t, TMP: t }))(ensureRoTemp()) : {}) },
  })
  S = { child, workspace, mode, busy: false, turn: null, usage: null, stderr: '', dead: false, perms: [], turns: 0, startedAt: now() }
  child.stderr.setEncoding('utf8')
  child.stderr.on('data', c => { S.stderr = (S.stderr + c).slice(-4000) })
  child.on('exit', (code, sig) => { if (S && S.child === child) { S.dead = true; S.exit = { code, sig, at: now() }; rec('process_exit', S.exit) } })
  const pass = new Readable({ read() {} })
  child.stdout.on('data', b => pass.push(b)); child.stdout.on('end', () => pass.push(null))
  const stream = ndJsonStream(Writable.toWeb(child.stdin), Readable.toWeb(pass))
  const app = client({ name: 'control-ds-mcp' })
    .onNotification(methods.client.session.update, ({ params }) => { try { onUpdate(params.update) } catch {} })
    .onRequest(methods.client.session.requestPermission, ({ params }) => {
      S.perms.push({ t: now(), title: params?.toolCall?.title })
      rec('permission_rejected', { request: clip(JSON.stringify(params), 2000) })
      return { outcome: { outcome: 'selected', optionId: 'reject-once' } }
    })
  S.agent = app.connect(stream).agent
  S.methods = methods
  await S.agent.request(methods.agent.initialize, { protocolVersion: 1, clientCapabilities: {} })
  const res = resume_session_id
    ? await S.agent.request(methods.agent.session.resume, { sessionId: resume_session_id, cwd: workspace, mcpServers: [] })
    : await S.agent.request(methods.agent.session.new, { cwd: workspace, mcpServers: [] })
  S.sessionId = resume_session_id ?? res.sessionId
  S.transcript = path.join(RUNS, `acp-${S.sessionId}.jsonl`)
  S.configOptions = res.configOptions ?? []
  cacheModels(S.configOptions)
  // Model selection, fail closed: a new session gets the requested model or the default; a resumed session keeps the
  // model in its own log unless one is requested. Either way the provider must be allowed and the reported current
  // model must equal what we asked for (a missing report counts as wrong).
  try {
    // a resumed session without an explicit model goes back to the model this MCP last recorded for it (dsh only logs
    // the route once a prompt has run, so an unprompted session would otherwise fall back to the deployment default)
    const recorded = resume_session_id ? loadRegistry()[S.sessionId]?.model : undefined
    const want = model ? parseModel(model) : resume_session_id ? (recorded ?? null) : JSON.stringify([CFG.expectedProvider, CFG.expectedModel])
    await applyModel(want, reasoning_effort)
  } catch (e) {
    rec('session', { sessionId: S.sessionId, workspace, mode, model: currentModel(), resumed: !!resume_session_id, error: e.message })
    await shutdown()
    throw new Error(`${e.message}. Shut down; nothing was sent.`)
  }
  rec('session', { sessionId: S.sessionId, workspace, mode, model: S.model, reasoningEffort: S.effort, resumed: !!resume_session_id, dshVersion: CFG.dshVersion })
  remember({ sessionId: S.sessionId, workspace, mode, transcript: S.transcript, startedAt: S.startedAt, resumed: !!resume_session_id, model: S.model })
  let web; try { web = await syncWeb() } catch (e) { web = { error: String(e?.message ?? e) } }
  return { reused: false, ...brief(), web }
}

// ---------------- model selection ----------------
// dsh reports models as the JSON string '["provider","model"]'. Users pass "model" (default provider) or
// "provider:model" (model ids contain slashes, so ':' separates the provider).
const MODELS_CACHE = path.join(RUNS, 'models-cache.json')
const allowedProviders = () => CFG.allowedProviders ?? [CFG.expectedProvider]
function parseModel(spec) {
  const s = String(spec).trim()
  if (s.startsWith('[')) return JSON.stringify(JSON.parse(s))
  const i = s.indexOf(':')
  const [provider, id] = i > 0 && !s.slice(0, i).includes('/') ? [s.slice(0, i), s.slice(i + 1)] : [CFG.expectedProvider, s]
  return JSON.stringify([provider, id])
}
const providerOf = v => { try { return JSON.parse(v)[0] } catch { return undefined } }
const option = id => S.configOptions.find(o => o.id === id)
const currentModel = () => option('model')?.currentValue
function modelChoices(options) {
  const o = options.find(x => x.id === 'model')
  return (o?.options ?? []).flatMap(g => g.options ? g.options.map(x => ({ ...x, group: g.group ?? g.name })) : [g])
}
function cacheModels(options) {
  const list = modelChoices(options).map(x => ({ provider: providerOf(x.value), id: (() => { try { return JSON.parse(x.value)[1] } catch { return x.value } })(), name: x.name }))
  if (list.length) try { fs.writeFileSync(MODELS_CACHE, JSON.stringify({ at: now(), models: list }, null, 2)) } catch {}
}
async function setOption(configId, value) {
  const r = await S.agent.request(S.methods.agent.session.setConfigOption, { sessionId: S.sessionId, configId, value })
  if (r?.configOptions) S.configOptions = r.configOptions
}
async function applyModel(want, effort) {
  if (want) {
    if (!allowedProviders().includes(providerOf(want))) throw new Error(`provider ${providerOf(want)} is not allowed (config.allowedProviders: ${allowedProviders().join(', ')})`)
    if (!modelChoices(S.configOptions).some(x => x.value === want)) throw new Error(`model ${want} is not offered by dsh; see flash_models`)
    if (currentModel() !== want) await setOption('model', want)
  }
  if (effort !== undefined) {
    const allowed = (option('reasoning_effort')?.options ?? []).map(x => x.value)
    if (!allowed.includes(effort)) throw new Error(`reasoning_effort must be one of: ${allowed.map(x => x || '(provider default)').join(', ')}`)
    await setOption('reasoning_effort', effort)
  }
  const cur = currentModel()
  if (want ? cur !== want : !allowedProviders().includes(providerOf(cur)))
    throw new Error(`model check failed: session model is ${cur ?? '(not reported)'}, expected ${want ?? `a model from ${allowedProviders().join(', ')}`}`)
  S.model = cur
  S.effort = option('reasoning_effort')?.currentValue || '(provider default)'
}
async function setModel({ model, reasoning_effort }) {
  if (!S || S.dead) throw new Error('no running flash session; call flash_start first')
  if (S.busy) throw new Error('flash is busy; switch models between turns (flash_wait first)')
  if (!model && reasoning_effort === undefined) throw new Error('pass model and/or reasoning_effort')
  const before = S.model
  await applyModel(model ? parseModel(model) : null, reasoning_effort)
  rec('model_switch', { from: before, to: S.model, reasoningEffort: S.effort })
  remember({ sessionId: S.sessionId, workspace: S.workspace, model: S.model })
  return { model: S.model, reasoningEffort: S.effort, note: before !== S.model ? 'the next turn starts without prompt cache (different model)' : undefined }
}
function models({ filter } = {}) {
  let list
  if (S && !S.dead) list = modelChoices(S.configOptions).map(x => ({ provider: providerOf(x.value), id: JSON.parse(x.value)[1], name: x.name }))
  else { try { list = JSON.parse(fs.readFileSync(MODELS_CACHE, 'utf8')).models } catch { return { note: 'no model list yet; call flash_start once (it caches the list)' } } }
  const f = filter?.toLowerCase()
  return {
    current: S && !S.dead ? { model: S.model, reasoningEffort: S.effort } : undefined,
    default: `${CFG.expectedProvider}:${CFG.expectedModel}`, allowedProviders: allowedProviders(),
    models: list.filter(x => !f || `${x.provider} ${x.id} ${x.name}`.toLowerCase().includes(f))
      .map(x => ({ use: x.provider === CFG.expectedProvider ? x.id : `${x.provider}:${x.id}`, name: x.name, allowed: allowedProviders().includes(x.provider) })),
  }
}

function brief() {
  return { sessionId: S.sessionId, workspace: S.workspace, mode: S.mode, model: S.model, reasoningEffort: S.effort, pid: S.child.pid, transcript: S.transcript, usage: S.usage,
    dsh: { version: CFG.dshVersion, source: DSH?.source, path: NM, warning: DSH?.source === 'fixed' ? undefined : `dsh is running from the npx cache; install the fixed copy: ${INSTALL_HINT}` } }
}

// No wall-clock limits: waiting (a backtest, a long command) costs no tokens and the coordinator is watching.
// Token guards only (see onUpdate/trip): steps = model calls per turn, repeats = identical call+result in a row,
// plus the context hard limit checked on every step.
function turnLimits(over = {}) {
  const lim = {}
  for (const k of ['steps', 'repeats']) {
    const v = over[k] ?? CFG.turnGuards[k]
    const max = CFG.maxTurnGuards[k]
    if (!(Number.isInteger(v) && v > 0 && v <= max)) throw new Error(`limits.${k} must be an integer in [1, ${max}]`)
    lim[k] = v
  }
  return lim
}

async function send({ text, text_file, interrupt = false, limits }) {
  if (!S || S.dead) throw new Error('no running flash session; call flash_start first')
  if (text_file) text = fs.readFileSync(text_file, 'utf8')
  if (!text || !text.trim()) throw new Error('empty message')
  const lim = turnLimits(limits)
  const used = S.usage?.used ?? 0
  if (used >= CFG.hardLimitTokens) throw new Error(`context ${used} >= hard limit ${CFG.hardLimitTokens}; write a handoff note and start a new session`)
  if (S.busy) {
    if (!interrupt) throw new Error('flash is busy with the previous message; use flash_wait, or flash_send with interrupt=true to cancel it and send this instead')
    await cancel()
    const t0 = Date.now(); while (S.busy && Date.now() - t0 < 30000) await new Promise(r => setTimeout(r, 200))
    // Never stack a new turn on one that is still running: the two would share state and status would lie.
    if (S.busy) throw new Error(`turn ${S.turn?.n} did not stop within 30s after cancel; nothing was sent. Check flash_status, then retry or flash_shutdown.`)
  }
  const T = { n: ++S.turns, sentAt: now(), lastEventAt: Date.now(), text, reply: '', thought: '', tools: new Map(), events: [], done: false, stopReason: null, error: null,
    limits: lim, steps: 0, contextSent: 0, repeat: 0, lastSig: null, stoppedBy: null }
  S.turn = T; S.busy = true
  rec('prompt', { turn: T.n, text, limits: lim })
  remember({ sessionId: S.sessionId, workspace: S.workspace, lastPromptAt: T.sentAt })
  const s = S
  s.agent.request(s.methods.agent.session.prompt, { sessionId: s.sessionId, prompt: [{ type: 'text', text }] })
    .then(r => { T.stopReason = r?.stopReason ?? null })
    .catch(e => { T.error = String(e?.message ?? e) })
    .finally(() => {
      T.done = true; T.doneAt = now()
      if (s.turn === T) s.busy = false   // only the current turn may clear the busy flag
      rec('turn_end', { turn: T.n, stopReason: T.stopReason, error: T.error, stoppedBy: T.stoppedBy, steps: T.steps, contextSent: T.contextSent, reply: T.reply })
    })
  const warn = used >= CFG.continueBelowTokens ? `WARNING: context ${used} >= ${CFG.continueBelowTokens}; after this task, write a handoff note and start a new session.` : undefined
  return { sent: true, turn: T.n, sessionId: S.sessionId, guards: { ...lim, contextHardLimit: CFG.hardLimitTokens }, warning: warn }
}

async function cancel() {
  if (!S || S.dead) throw new Error('no running flash session')
  if (!S.busy) return { cancelled: false, note: 'flash was idle' }
  await S.agent.notify(S.methods.agent.session.cancel, { sessionId: S.sessionId })
  rec('cancel', { turn: S.turn?.n })
  return { cancelled: true, turn: S.turn?.n }
}

function status({ tail = 15, full_reply = false } = {}) {
  if (!S) return { state: 'none', note: 'no flash session in this Claude Code session' }
  const T = S.turn
  const out = {
    state: S.dead ? 'process-exited' : S.busy ? 'working' : 'idle',
    sessionId: S.sessionId, workspace: S.workspace, mode: S.mode, model: S.model, pid: S.child.pid,
    context: S.usage ? `${S.usage.used} / ${S.usage.size} tokens` : 'unknown',
    contextAdvice: !S.usage ? undefined : S.usage.used >= CFG.hardLimitTokens ? 'hard limit reached: new session required'
      : S.usage.used >= CFG.continueBelowTokens ? 'above continue limit: switch session after this task' : 'ok',
    cacheStats: 'not reported by ACP (only context size); see transcript',
    permissionRejections: S.perms.length,
    transcript: S.transcript,
    freeMemoryGB: +(os.freemem() / 2 ** 30).toFixed(1),
  }
  if (S.dead) { out.exit = S.exit; out.stderrTail = clip(S.stderr, 1500) }
  if (T) {
    out.turn = {
      n: T.n, sentAt: T.sentAt, done: T.done, doneAt: T.doneAt, stopReason: T.stopReason, error: T.error,
      guards: T.limits, steps: T.steps, contextSent: T.contextSent, sameResultInARow: T.repeat,
      stoppedBy: T.stoppedBy || undefined,
      idleSec: Math.round((Date.now() - T.lastEventAt) / 1000),
      runningTools: [...T.tools.values()].filter(x => x.status !== 'completed' && x.status !== 'failed')
        .map(x => `${clip(x.title ?? '', 100)} (${Math.round((Date.now() - x.startedMs) / 60000)} min)`),
      guardNote: T.stuck ? 'STUCK: guard cancelled the turn but it did not stop within 60s; decide whether to flash_shutdown'
        : T.stoppedBy ? (!T.done ? 'guard cancel sent; waiting for the turn to stop'
          : T.stopReason === 'cancelled' ? `turn was cancelled by a token guard (${T.stoppedBy}); the result is incomplete`
          : `token guard tripped (${T.stoppedBy}) but the turn ended on its own (${T.stopReason}) before the cancel landed`) : undefined,
      elapsedSec: Math.round(((T.done ? Date.parse(T.doneAt) : Date.now()) - Date.parse(T.sentAt)) / 1000),
      toolCalls: T.tools.size,
      recent: T.events.slice(-Math.max(1, Math.min(60, tail))).map(x => `${x.t.slice(11, 19)} ${x.e}`),
      thinkingTail: clip(T.thought.slice(-600), 600),
      reply: T.done || full_reply ? clip(T.reply, full_reply ? 40000 : 8000) : clip(T.reply.slice(-600), 600),
    }
  }
  return out
}

async function wait({ seconds = 45, tail = 15 } = {}) {
  if (!S) throw new Error('no flash session')
  const until = Date.now() + Math.min(Math.max(1, seconds), 110) * 1000
  while (S.busy && !S.dead && Date.now() < until) await new Promise(r => setTimeout(r, 500))
  return status({ tail })
}

async function shutdown() {
  if (!S) return { stopped: false, note: 'nothing running' }
  const s = S
  try { if (s.busy && !s.dead) await cancel() } catch {}
  try { s.child.stdin.end() } catch {}
  await new Promise(r => setTimeout(r, 3000))
  if (s.child.exitCode === null) {
    try { spawn('taskkill', ['/PID', String(s.child.pid), '/T', '/F'], { windowsHide: true }) } catch {}
    await new Promise(r => setTimeout(r, 1500))
  }
  rec('shutdown', {})
  remember({ sessionId: s.sessionId, workspace: s.workspace, stoppedAt: now(), lastContext: s.usage ?? undefined })
  const res = { stopped: true, sessionId: s.sessionId, transcript: s.transcript, resumeWith: s.sessionId }
  S = null
  return res
}

// ---------------- MCP (stdio JSON-RPC) ----------------
const TOOLS = [
  { name: 'flash_start', description: 'Start (or reuse) the long-lived dsh ACP process and a session in a workspace. Model: the default (config) unless `model` is given; only config.allowedProviders are accepted and the selected model is verified (fails closed). Pass resume_session_id to continue an earlier session in the same workspace, or "last" for the most recent recorded one (see flash_sessions); a resumed session keeps its own model unless `model` is given.',
    inputSchema: { type: 'object', properties: { workspace: { type: 'string', description: 'absolute path of the change worktree' }, mode: { type: 'string', enum: ['workspace-write', 'read-only'] }, resume_session_id: { type: 'string', description: 'session id, or "last"' },
      model: { type: 'string', description: 'model id from flash_models, e.g. "deepseek/deepseek-v4-pro" (default provider) or "provider:model"' }, reasoning_effort: { type: 'string', description: '"" (provider default), low, high, max' } }, required: ['workspace'] } },
  { name: 'flash_models', description: 'List the models dsh offers (from the running session, or the cached list), with the current/default model and whether each is allowed.',
    inputSchema: { type: 'object', properties: { filter: { type: 'string', description: 'substring filter, e.g. "deepseek" or "kimi"' } } } },
  { name: 'flash_set_model', description: 'Switch the running session to another allowed model and/or reasoning effort between turns. The conversation is kept; the next turn starts without prompt cache.',
    inputSchema: { type: 'object', properties: { model: { type: 'string' }, reasoning_effort: { type: 'string' } } } },
  { name: 'flash_sessions', description: 'List flash sessions recorded by this MCP (survives Claude Code restarts), newest first, optionally filtered by workspace.',
    inputSchema: { type: 'object', properties: { workspace: { type: 'string' }, limit: { type: 'number' } } } },
  { name: 'flash_send', description: 'Send a message/task to flash in the current session. Returns immediately; use flash_wait / flash_status. With interrupt=true, cancels the running turn first (use for course corrections). No time limits; the turn is cancelled only by token guards: too many model steps, the same tool call+result repeated, or context reaching the hard limit.',
    inputSchema: { type: 'object', properties: { text: { type: 'string' }, text_file: { type: 'string', description: 'UTF-8 file with the task text (alternative to text)' }, interrupt: { type: 'boolean' },
      limits: { type: 'object', description: 'override token guards (defaults config.turnGuards, caps config.maxTurnGuards). No time limits.', properties: { steps: { type: 'integer', description: 'max model steps in this turn' }, repeats: { type: 'integer', description: 'cancel after this many identical tool call+result in a row' } } } } } },
  { name: 'flash_wait', description: 'Wait up to `seconds` (max 110) for the current turn to finish, then return status.',
    inputSchema: { type: 'object', properties: { seconds: { type: 'number' }, tail: { type: 'number' } } } },
  { name: 'flash_status', description: 'Current state: working/idle, context usage, recent tool calls, thinking tail, reply (full when done).',
    inputSchema: { type: 'object', properties: { tail: { type: 'number' }, full_reply: { type: 'boolean' } } } },
  { name: 'flash_cancel', description: 'Cancel the running turn (the session stays; flash keeps its memory).', inputSchema: { type: 'object', properties: {} } },
  { name: 'flash_shutdown', description: 'End the dsh process. The session is saved by dsh and can be resumed later with flash_start(resume_session_id).', inputSchema: { type: 'object', properties: {} } },
]
const HANDLERS = { flash_start: start, flash_models: models, flash_set_model: setModel, flash_sessions: ({ workspace, limit = 20 } = {}) => ({ registry: REGISTRY, sessions: sessionsFor(workspace).slice(0, limit) }), flash_send: send, flash_wait: wait, flash_status: status, flash_cancel: cancel, flash_shutdown: shutdown }

const write = msg => process.stdout.write(JSON.stringify(msg) + '\n')
async function handle(m) {
  const { id, method, params } = m
  if (id === undefined) return   // notification
  try {
    if (method === 'initialize') return write({ jsonrpc: '2.0', id, result: {
      protocolVersion: params?.protocolVersion ?? '2025-06-18',
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: 'control-ds', version: '0.1.0' },
      instructions: 'Drive DeepSeek V4.1 Flash (Command Code) inside dsh. Follow the control-ds skill: one dsh process at a time, never escalate permissions, verify results independently.',
    } })
    if (method === 'ping') return write({ jsonrpc: '2.0', id, result: {} })
    if (method === 'tools/list') return write({ jsonrpc: '2.0', id, result: { tools: TOOLS } })
    if (method === 'tools/call') {
      const h = HANDLERS[params?.name]
      if (!h) return write({ jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: `unknown tool ${params?.name}` }], isError: true } })
      try {
        const r = await h(params.arguments ?? {})
        return write({ jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: JSON.stringify(r, null, 2) }] } })
      } catch (e) {
        return write({ jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: 'ERROR: ' + (e?.message ?? e) }], isError: true } })
      }
    }
    return write({ jsonrpc: '2.0', id, error: { code: -32601, message: `method not found: ${method}` } })
  } catch (e) {
    return write({ jsonrpc: '2.0', id, error: { code: -32603, message: String(e?.message ?? e) } })
  }
}

if (process.argv.includes('--sync-web')) {
  // CLI mode for web.ps1: register pending ACP sessions in the dsh web workspace list, then exit.
  syncWeb().then(r => { process.stdout.write(JSON.stringify(r) + '\n'); process.exit(0) },
    e => { process.stdout.write('ERROR: ' + (e?.message ?? e) + '\n'); process.exit(1) })
} else {
let buf = ''
process.stdin.setEncoding('utf8')
process.stdin.on('data', chunk => {
  buf += chunk
  let i
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1)
    if (!line) continue
    let m; try { m = JSON.parse(line) } catch { continue }
    handle(m)
  }
})
const bye = async () => { try { await shutdown() } catch {} ; process.exit(0) }
process.stdin.on('end', bye)
process.on('SIGTERM', bye)
process.on('SIGINT', bye)
}
