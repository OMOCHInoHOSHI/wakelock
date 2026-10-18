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
function makeApi(opts) {
  let getCalls = 0
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
  // opts があるときだけ session.get を偽装する (なければ api.session を持たない)
  if (opts) {
    api.session = {
      async get({ sessionID }) {
        getCalls += 1
        if (getCalls <= (opts.failFirst ?? 0)) throw new Error("get failed")
        if ((opts.failGet ?? []).includes(sessionID)) throw new Error("get failed")
        return opts.sessions?.[sessionID] ?? {}
      },
    }
  }
  const push = (event) => {
    if (waiters.length) waiters.shift()({ value: event, done: false })
    else queue.push(event)
  }
  return { api, push, end: finish, getCalls: () => getCalls }
}

const ev = (type, data = {}) => ({ type, data })

/** 2.0 のケースを新しい makeApi / setup で実行し、最後に後片付けしてログを空にする */
async function case20(fn, opts) {
  clearLog()
  const m = makeApi(opts)
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
heading("サブエージェント: hold の単位はルート")
await case20(async ({ push }) => {
  push(ev("session.execution.started", { sessionID: "P" }))
  await expectCalls("P の started で acquire", [acq2("P")])
  clearLog()
  push(ev("session.created", { sessionID: "C", parentID: "P" }))
  await expectCalls("created では何も呼ばない", [])
  push(ev("session.execution.started", { sessionID: "C" }))
  await expectCalls("C の started でも何も呼ばない (ルートは取得済み)", [])
  push(ev("session.step.started", { sessionID: "C" }))
  await expectCalls("C の step.started でルートを取り直す", [acq2("P")])
})

// ------------------------------------------------------------------
heading("サブエージェント: 子の承認待ちでルートごと解除")
await case20(async ({ push }) => {
  push(ev("session.created", { sessionID: "P" }))
  push(ev("session.execution.started", { sessionID: "P" }))
  await expectCalls("P の started で acquire", [acq2("P")])
  clearLog()
  push(ev("session.created", { sessionID: "C", parentID: "P" }))
  push(ev("session.execution.started", { sessionID: "C" }))
  await expectCalls("C の started では何も呼ばない", [])
  push(ev("permission.asked", { sessionID: "C", id: "per1" }))
  await expectCalls("C の asked でルートを release", [rel("P")])
  clearLog()
  push(ev("permission.replied", { sessionID: "C", requestID: "per1", reply: "once" }))
  await expectCalls("C の replied でルートを acquire", [acq2("P")])
  clearLog()
  push(ev("session.execution.succeeded", { sessionID: "C" }))
  await expectCalls("C の succeeded では何も呼ばない", [])
  push(ev("session.execution.succeeded", { sessionID: "P" }))
  await expectCalls("P の succeeded で release", [rel("P")])
})

// ------------------------------------------------------------------
heading("サブエージェント: 並列の子")
await case20(async ({ push }) => {
  push(ev("session.execution.started", { sessionID: "P" }))
  await expectCalls("P の started で acquire", [acq2("P")])
  clearLog()
  for (const c of ["C1", "C2"]) {
    push(ev("session.created", { sessionID: c, parentID: "P" }))
    push(ev("session.execution.started", { sessionID: c }))
  }
  await expectCalls("C1, C2 の created / started では何も呼ばない", [])
  push(ev("permission.asked", { sessionID: "C1", id: "per1" }))
  await expectCalls("C1 の asked では何も呼ばない (C2 が作業中)", [])
  push(ev("session.execution.succeeded", { sessionID: "C2" }))
  await expectCalls("C2 の succeeded で release (C1 は承認待ち)", [rel("P")])
  clearLog()
  push(ev("permission.replied", { sessionID: "C1", requestID: "per1", reply: "once" }))
  await expectCalls("C1 の replied で acquire", [acq2("P")])
  clearLog()
  push(ev("session.execution.succeeded", { sessionID: "C1" }))
  await expectCalls("C1 の succeeded では何も呼ばない", [])
  push(ev("session.execution.succeeded", { sessionID: "P" }))
  await expectCalls("P の succeeded で release", [rel("P")])
})

// ------------------------------------------------------------------
heading("サブエージェント: 孫")
await case20(async ({ push }) => {
  push(ev("session.execution.started", { sessionID: "P" }))
  await expectCalls("P の started で acquire", [acq2("P")])
  clearLog()
  push(ev("session.created", { sessionID: "C", parentID: "P" }))
  push(ev("session.created", { sessionID: "G", parentID: "C" }))
  push(ev("session.execution.started", { sessionID: "C" }))
  push(ev("session.execution.started", { sessionID: "G" }))
  await expectCalls("C, G の started では何も呼ばない", [])
  push(ev("permission.asked", { sessionID: "G", id: "per1" }))
  await expectCalls("G の asked でルートを release", [rel("P")])
  clearLog()
  push(ev("permission.replied", { sessionID: "G", requestID: "per1", reply: "once" }))
  await expectCalls("G の replied でルートを acquire", [acq2("P")])
})

// ------------------------------------------------------------------
heading("サブエージェント: created 未受信の子は session.get で親を引く")
await case20(
  async ({ push }) => {
    push(ev("session.execution.started", { sessionID: "P" }))
    await expectCalls("P の started で acquire", [acq2("P")])
    clearLog()
    push(ev("session.step.started", { sessionID: "C" }))
    await expectCalls("C の step.started でルートを acquire", [acq2("P")])
    clearLog()
    push(ev("permission.asked", { sessionID: "C", id: "per1" }))
    await expectCalls("C の asked でルートを release", [rel("P")])
  },
  { sessions: { C: { parentID: "P" } } },
)

// ------------------------------------------------------------------
heading("サブエージェント: session.get が失敗した子はルート扱い")
await case20(
  async ({ push }) => {
    push(ev("session.execution.started", { sessionID: "P" }))
    await expectCalls("P の started で acquire", [acq2("P")])
    clearLog()
    push(ev("session.execution.started", { sessionID: "C" }))
    await expectCalls("C の started は C 自身の hold になる", [acq2("C")])
  },
  { sessions: { C: { parentID: "P" } }, failGet: ["C"] },
)

// ------------------------------------------------------------------
heading("サブエージェント: 承認待ちの子が削除されると親の作業に戻る")
await case20(async ({ push }) => {
  push(ev("session.execution.started", { sessionID: "P" }))
  await expectCalls("P の started で acquire", [acq2("P")])
  clearLog()
  push(ev("session.created", { sessionID: "C", parentID: "P" }))
  push(ev("session.execution.started", { sessionID: "C" }))
  push(ev("permission.asked", { sessionID: "C", id: "per1" }))
  await expectCalls("C の asked でルートを release", [rel("P")])
  clearLog()
  push(ev("session.deleted", { sessionID: "C" }))
  await expectCalls("C の deleted でルートを acquire", [acq2("P")])
})

// ------------------------------------------------------------------
heading("サブエージェント: 親子が分かっていれば session.get を呼ばない")
await case20(
  async ({ push, getCalls }) => {
    push(ev("session.created", { sessionID: "P" }))
    push(ev("session.created", { sessionID: "C", parentID: "P" }))
    push(ev("session.execution.started", { sessionID: "P" }))
    push(ev("session.execution.started", { sessionID: "C" }))
    push(ev("permission.asked", { sessionID: "C", id: "per1" }))
    await expectCalls("流れが処理される", [acq2("P"), rel("P")])
    report(getCalls() === 0, "session.get の呼び出しが 0 回", "0", String(getCalls()))
  },
  {},
)

// ------------------------------------------------------------------
heading("サブエージェント: 破棄でルートの hold を 1 回ずつ release")
{
  clearLog()
  const m = makeApi()
  const dispose = await plugin.setup(m.api)
  m.push(ev("session.execution.started", { sessionID: "P" }))
  m.push(ev("session.created", { sessionID: "C", parentID: "P" }))
  m.push(ev("session.execution.started", { sessionID: "C" }))
  await expectCalls("ルートの acquire だけ", [acq2("P")])
  clearLog()
  await dispose()
  await expectCalls("ルートを 1 回だけ release", [rel("P")])
  clearLog()
}

// ------------------------------------------------------------------
heading("サブエージェント: 問い合わせ失敗の後に created で親が分かるとルートを付け替える")
await case20(
  async ({ push }) => {
    push(ev("session.created", { sessionID: "P" }))
    push(ev("session.execution.started", { sessionID: "P" }))
    await expectCalls("P の started で acquire", [acq2("P")])
    clearLog()
    push(ev("session.execution.started", { sessionID: "C" }))
    await expectCalls("C の started は C 自身の hold になる", [acq2("C")])
    clearLog()
    push(ev("session.created", { sessionID: "C", parentID: "P" }))
    await expectCalls("created では何も呼ばない", [])
    push(ev("session.step.started", { sessionID: "C" }))
    await expectCalls("step.started で P を取り直し、C を release", [acq2("P"), rel("C")])
    clearLog()
    push(ev("permission.asked", { sessionID: "C", id: "per1" }))
    await expectCalls("C の asked でルートを release", [rel("P")])
    clearLog()
    push(ev("session.execution.succeeded", { sessionID: "C" }))
    await expectCalls("C の succeeded で P が作業に戻り acquire", [acq2("P")])
  },
  { failGet: ["C"] },
)

// ------------------------------------------------------------------
heading("サブエージェント: 問い合わせの失敗は覚えず、次のイベントで引き直す")
await case20(
  async ({ push, getCalls }) => {
    push(ev("session.created", { sessionID: "P" }))
    push(ev("session.execution.started", { sessionID: "P" }))
    await expectCalls("P の started で acquire", [acq2("P")])
    clearLog()
    push(ev("session.execution.started", { sessionID: "C" }))
    await expectCalls("get 失敗中の C の started は C 自身の hold", [acq2("C")])
    clearLog()
    push(ev("session.step.started", { sessionID: "C" }))
    await expectCalls("引き直しに成功し P を取り直して C を release", [acq2("P"), rel("C")])
    report(getCalls() === 2, "session.get の呼び出しが 2 回", "2", String(getCalls()))
  },
  { failFirst: 1, sessions: { C: { parentID: "P" } } },
)

// ------------------------------------------------------------------
heading("サブエージェント: parentID なしで成功したらルートとして覚え、再問い合わせしない")
await case20(
  async ({ push, getCalls }) => {
    push(ev("session.execution.started", { sessionID: "C" }))
    push(ev("session.step.started", { sessionID: "C" }))
    push(ev("session.step.started", { sessionID: "C" }))
    await expectCalls("C の hold が 3 回 acquire される", [acq2("C"), acq2("C"), acq2("C")])
    report(getCalls() === 1, "session.get の呼び出しが 1 回", "1", String(getCalls()))
  },
  { sessions: { C: {} } },
)

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
