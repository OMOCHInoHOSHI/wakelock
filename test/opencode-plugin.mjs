// opencode プラグイン (adapters/opencode/wakelock.js) を、実際の wakelock を呼ばずに検証する。
// wakelock をスタブに差し替え、呼び出し引数をログファイルで観測する。
// 実行: node test/opencode-plugin.mjs

import fs from "node:fs"
import os from "node:os"
import path from "node:path"

const WORK = fs.mkdtempSync(path.join(os.tmpdir(), "wakelock-opencode-test-"))
const LOG = path.join(WORK, "calls.log")
const FAIL_ONCE = path.join(WORK, "release_fail_once")
const STUB = path.join(WORK, "wakelock")

const cleanup = () => fs.rmSync(WORK, { recursive: true, force: true })
process.on("exit", cleanup)

// 引数を 1 行ずつ記録する。FAIL_ONCE があれば release のときだけ 1 回失敗する
fs.writeFileSync(
  STUB,
  `#!/usr/bin/env bash
echo "$*" >>"${LOG}"
if [ "\${1:-}" = "release" ] && [ -f "${FAIL_ONCE}" ]; then
  rm -f "${FAIL_ONCE}"
  exit 1
fi
exit 0
`,
  { mode: 0o755 },
)
fs.writeFileSync(LOG, "")

process.env.WAKELOCK_BIN = STUB
const plugin = (await import(new URL("../adapters/opencode/wakelock.js", import.meta.url).href)).default

let PASS = 0
let FAIL = 0
let section = 0

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const heading = (title) => {
  section += 1
  console.log(`\n${section}. ${title}`)
}

const report = (ok, desc, want, got) => {
  if (ok) {
    console.log(`  \x1b[32mPASS\x1b[0m  ${desc}`)
    PASS += 1
  } else {
    console.log(`  \x1b[31mFAIL\x1b[0m  ${desc} (期待 ${want} / 実際 ${got})`)
    FAIL += 1
  }
}

const readLog = () =>
  fs
    .readFileSync(LOG, "utf8")
    .split("\n")
    .filter((l) => l !== "")

const clearLog = () => fs.writeFileSync(LOG, "")

const acq = (sid) => `acquire opencode-${sid} --pid ${process.pid} --label opencode`
/** 2.0 経路の acquire は --match-label が付く */
const acq2 = (sid) => `${acq(sid)} --match-label`
const rel = (sid) => `release opencode-${sid}`

/** 期待行数に達するまで最大 3 秒待ち、さらに 200ms 待って余計な呼び出しがないことを確かめる */
async function expectCalls(desc, want, { sorted = false } = {}) {
  const deadline = Date.now() + 3000
  while (readLog().length < want.length && Date.now() < deadline) await sleep(20)
  await sleep(200)
  let got = readLog()
  let exp = want
  if (sorted) {
    got = [...got].sort()
    exp = [...want].sort()
  }
  const g = JSON.stringify(got)
  const w = JSON.stringify(exp)
  report(g === w, desc, w, g)
}

/** 2.0 の偽 API */
function makeApi() {
  const queue = []
  const waiters = []
  let done = false
  const finish = () => {
    done = true
    while (waiters.length) waiters.shift()({ value: undefined, done: true })
  }
  const api = {
    event: {
      subscribe({ signal } = {}) {
        if (signal) {
          if (signal.aborted) finish()
          else signal.addEventListener("abort", finish, { once: true })
        }
        return {
          [Symbol.asyncIterator]() {
            return {
              next() {
                if (queue.length) return Promise.resolve({ value: queue.shift(), done: false })
                if (done) return Promise.resolve({ value: undefined, done: true })
                return new Promise((resolve) => waiters.push(resolve))
              },
              return() {
                finish()
                return Promise.resolve({ value: undefined, done: true })
              },
            }
          },
        }
      },
    },
  }
  const push = (event) => {
    if (waiters.length) waiters.shift()({ value: event, done: false })
    else queue.push(event)
  }
  return { api, push, end: finish }
}

const ev = (type, data = {}) => ({ type, data })

/** 2.0 のケースを新しい makeApi / setup で実行し、最後に後片付けしてログを空にする */
async function case20(fn) {
  clearLog()
  const m = makeApi()
  const dispose = await plugin.setup(m.api)
  try {
    await fn(m)
  } finally {
    await dispose()
    clearLog()
  }
}

// ------------------------------------------------------------------
heading("default export の形")
report(plugin.id === "wakelock", "id が wakelock", "wakelock", plugin.id)
report(typeof plugin.setup === "function", "setup が関数", "function", typeof plugin.setup)
report(typeof plugin.server === "function", "server が関数", "function", typeof plugin.server)

// ------------------------------------------------------------------
heading("1.x フック")
{
  const hooks = await plugin.server()
  clearLog()
  await hooks["chat.message"]({ sessionID: "s1" })
  await expectCalls("chat.message で acquire", [acq("s1")])

  clearLog()
  await hooks["permission.ask"]({ sessionID: "s1" })
  await expectCalls("permission.ask で release", [rel("s1")])

  clearLog()
  await hooks.event({ event: { type: "permission.replied", properties: { sessionID: "s1" } } })
  await expectCalls("permission.replied で acquire", [acq("s1")])

  for (const type of ["session.idle", "session.deleted", "session.error"]) {
    clearLog()
    await hooks.event({ event: { type, properties: { sessionID: "s1" } } })
    await expectCalls(`${type} で release`, [rel("s1")])
  }

  clearLog()
  await hooks["chat.message"]({})
  await hooks["permission.ask"]({})
  await hooks.event({ event: { type: "permission.replied", properties: {} } })
  await hooks.event({ event: { type: "session.idle", properties: {} } })
  await expectCalls("sessionID がなければ何も呼ばない", [])
  clearLog()
}

// ------------------------------------------------------------------
heading("1.x が渡す限定 API での setup")
{
  clearLog()
  const r = await plugin.setup({ options: {}, agent: {}, command: {} })
  report(r === undefined, "戻り値が undefined", "undefined", String(r))
  await expectCalls("呼び出しがない", [])
}

// ------------------------------------------------------------------
heading("--match-label は 2.0 経路だけに付く")
{
  clearLog()
  const hooks = await plugin.server()
  await hooks["chat.message"]({ sessionID: "s1" })
  await expectCalls("1.x の acquire には付かない", [acq("s1")])
  clearLog()
  await case20(async ({ push }) => {
    push(ev("session.execution.started", { sessionID: "s1" }))
    await expectCalls("2.0 の acquire には付く", [`${acq("s1")} --match-label`])
  })
}

// ------------------------------------------------------------------
heading("2.0 の基本の流れ")
await case20(async ({ push }) => {
  push(ev("session.execution.started", { sessionID: "s1" }))
  await expectCalls("started で acquire", [acq2("s1")])
  clearLog()
  push(ev("permission.asked", { sessionID: "s1", id: "per1" }))
  await expectCalls("asked で release", [rel("s1")])
  clearLog()
  push(ev("permission.replied", { sessionID: "s1", requestID: "per1", reply: "once" }))
  await expectCalls("replied で acquire", [acq2("s1")])
  clearLog()
  push(ev("session.execution.succeeded", { sessionID: "s1" }))
  await expectCalls("succeeded で release", [rel("s1")])
})

// ------------------------------------------------------------------
heading("2.0 の並列承認")
await case20(async ({ push }) => {
  push(ev("session.execution.started", { sessionID: "s1" }))
  await expectCalls("started で acquire", [acq2("s1")])
  clearLog()
  push(ev("permission.asked", { sessionID: "s1", id: "per1" }))
  await expectCalls("asked per1 で release", [rel("s1")])
  clearLog()
  push(ev("permission.asked", { sessionID: "s1", id: "per2" }))
  await expectCalls("asked per2 では何も呼ばない", [])
  push(ev("permission.replied", { sessionID: "s1", requestID: "per1", reply: "once" }))
  await expectCalls("replied per1 でも何も呼ばない", [])
  push(ev("permission.replied", { sessionID: "s1", requestID: "per2", reply: "once" }))
  await expectCalls("replied per2 で acquire", [acq2("s1")])
  clearLog()
  push(ev("session.execution.succeeded", { sessionID: "s1" }))
  await expectCalls("succeeded で release", [rel("s1")])
})

// ------------------------------------------------------------------
heading("2.0 の session.step.started")
await case20(async ({ push }) => {
  push(ev("session.execution.started", { sessionID: "s1" }))
  await expectCalls("started で acquire", [acq2("s1")])
  clearLog()
  push(ev("session.step.started", { sessionID: "s1", assistantMessageID: "msg1" }))
  await expectCalls("step.started で再度 acquire (取り直し)", [acq2("s1")])
  clearLog()
  push(ev("permission.asked", { sessionID: "s1", id: "per1" }))
  await expectCalls("asked で release", [rel("s1")])
  clearLog()
  push(ev("session.step.started", { sessionID: "s1", assistantMessageID: "msg2" }))
  await expectCalls("承認待ちの最中の step.started では何も呼ばない", [])
})
await case20(async ({ push }) => {
  push(ev("session.step.started", { sessionID: "s2", assistantMessageID: "msg1" }))
  await expectCalls("started 未受信のセッションでも step.started で acquire", [acq2("s2")])
})

// ------------------------------------------------------------------
heading("2.0 の終了系イベント")
for (const type of ["session.execution.failed", "session.execution.interrupted", "session.deleted"]) {
  await case20(async ({ push }) => {
    push(ev("session.execution.started", { sessionID: "s1" }))
    await expectCalls(`started で acquire (${type} 用)`, [acq2("s1")])
    clearLog()
    push(ev(type, { sessionID: "s1" }))
    await expectCalls(`${type} で release`, [rel("s1")])
  })
}

// ------------------------------------------------------------------
heading("2.0 で reply が reject")
await case20(async ({ push }) => {
  push(ev("session.execution.started", { sessionID: "s1" }))
  await expectCalls("started で acquire", [acq2("s1")])
  clearLog()
  push(ev("permission.asked", { sessionID: "s1", id: "per1" }))
  await expectCalls("asked で release", [rel("s1")])
  clearLog()
  push(ev("permission.replied", { sessionID: "s1", requestID: "per1", reply: "reject" }))
  await expectCalls("reject でも acquire (作業は続く)", [acq2("s1")])
})

// ------------------------------------------------------------------
heading("2.0 で何もしないイベント")
await case20(async ({ push }) => {
  push(ev("session.text.delta", { sessionID: "s1", delta: "x" }))
  push(ev("location.shutdown", {}))
  push({ type: "session.execution.started" })
  push(ev("session.execution.succeeded", {}))
  await expectCalls("関係ないイベント・sessionID なしでは何も呼ばない", [])
  push(ev("permission.asked", { sessionID: "s9", id: "perX" }))
  push(ev("permission.replied", { sessionID: "s9", requestID: "perX", reply: "once" }))
  await expectCalls("実行中でないセッションの asked / replied では何も呼ばない", [])
})

// ------------------------------------------------------------------
heading("2.0 の破棄")
{
  clearLog()
  const m = makeApi()
  const dispose = await plugin.setup(m.api)
  m.push(ev("session.execution.started", { sessionID: "s1" }))
  m.push(ev("session.execution.started", { sessionID: "s2" }))
  await expectCalls("s1 と s2 の acquire", [acq2("s1"), acq2("s2")], { sorted: true })
  clearLog()
  await dispose()
  await expectCalls("後片付けで両方 release", [rel("s1"), rel("s2")], { sorted: true })
  clearLog()
  m.push(ev("session.execution.started", { sessionID: "s3" }))
  await expectCalls("破棄後の push では何も呼ばない", [])
  clearLog()
}

// ------------------------------------------------------------------
heading("2.0 で購読が abort なしに終わる")
{
  clearLog()
  const m = makeApi()
  const dispose = await plugin.setup(m.api)
  m.push(ev("session.execution.started", { sessionID: "s1" }))
  await expectCalls("started で acquire", [acq2("s1")])
  clearLog()
  m.end()
  await expectCalls("end() で保持中の hold を release", [rel("s1")])
  clearLog()
  await dispose()
  clearLog()
}

// ------------------------------------------------------------------
heading("release の再試行")
{
  const hooks = await plugin.server()
  clearLog()
  fs.writeFileSync(FAIL_ONCE, "")
  await hooks.event({ event: { type: "session.idle", properties: { sessionID: "s1" } } })
  await expectCalls("最初の release が失敗しても release 行が 2 行出る", [rel("s1"), rel("s1")])
  clearLog()
}

console.log(`\n結果: ${PASS} PASS / ${FAIL} FAIL`)
process.exit(FAIL > 0 ? 1 : 0)
