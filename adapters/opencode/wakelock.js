/**
 * wakelock plugin for opencode (1.x / 2.0 両対応)
 *
 * opencode が実際に作業している間だけ hold を取り、承認待ちになったら手放す。
 * これにより自動モードや `wakelock run opencode` で起動したセッションは
 * 「作業中は蓋を閉じても動き、承認待ちで放置されたら通常どおりスリープする」挙動になる。
 *
 * wakelock 側で arm されていないセッションからの acquire は無視されるため、
 * このプラグインを常設しても素の opencode の挙動は変わらない。
 *
 * 1 つの default export を両方のローダーに読ませる。
 *   1.x : `server` を v1 プラグインとして呼ぶ。`setup` も呼ぶが、渡す API に event がない
 *   2.0 : `{ id, setup }` だけを見る。`server` は無視される
 * setup は event.subscribe があるときだけ動くので、1.x で二重に動くことはない。
 *
 * 設置先: ~/.config/opencode/plugin/wakelock.js
 */

import { execFile } from "node:child_process"
import { homedir } from "node:os"
import { join } from "node:path"

const WAKELOCK_BIN =
  process.env.WAKELOCK_BIN ?? join(homedir(), "Coding", "wakelock", "bin", "wakelock")

/**
 * wakelock を呼ぶ。失敗しても opencode 本体の動作は止めない。
 * 成功したかどうかだけを返す。
 */
function wakelock(...args) {
  return new Promise((resolve) => {
    execFile(WAKELOCK_BIN, args, { timeout: 5000 }, (err) => resolve(!err))
  })
}

const holdID = (sessionID) => `opencode-${sessionID}`

const acquire = (sessionID, ...extra) =>
  sessionID
    ? wakelock("acquire", holdID(sessionID), "--pid", String(process.pid), "--label", "opencode", ...extra)
    : Promise.resolve()

/**
 * 解除の取りこぼしは「起き続ける」側に倒れるため、失敗したら一度だけ再試行する。
 */
const release = async (sessionID) => {
  if (!sessionID) return
  if (!(await wakelock("release", holdID(sessionID)))) await wakelock("release", holdID(sessionID))
}

// ---------------------------------------------------------------- 1.x

/**
 * 1.x はプラグインが TUI と同じプロセスで動くので、process.pid は TUI 本体になる。
 */
const server = async () => {
  return {
    /** ユーザーが投げた時点で作業開始とみなす */
    "chat.message": async (input) => {
      await acquire(input?.sessionID)
    },

    /** 承認待ちに入ったら手放し、通常のスリープ設定に戻す */
    "permission.ask": async (input) => {
      await release(input?.sessionID)
    },

    event: async ({ event }) => {
      const sessionID = event?.properties?.sessionID
      switch (event?.type) {
        /** 承認が返ってきた = 作業再開 */
        case "permission.replied":
          await acquire(sessionID)
          break

        /** 応答完了・セッション消滅・エラーはいずれも解除 */
        case "session.idle":
        case "session.deleted":
        case "session.error":
          await release(sessionID)
          break
      }
    },
  }
}

// ---------------------------------------------------------------- 2.0

/** hold に関わるイベント。session.created は親子関係を覚えるためだけに別に扱う */
const TRACKED = new Set([
  "session.execution.started",
  "session.step.started",
  "permission.asked",
  "permission.replied",
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
  "session.deleted",
])

/**
 * 2.0 は作業をサーバーが持ち、プラグインもそこで動く。
 * 通常は常駐サービス (`opencode serve --service`、親は launchd) なので、
 * process.pid は TUI ではなくサービスになる。TUI を閉じても作業はサービスで続くため、
 * hold をサービスに紐付けるのは実態どおりでもある。
 *
 * サブエージェントは親とは別のセッションとして動き、承認待ちも子のセッションで起きる。
 * セッションごとに hold を持つと、子が承認待ちで止まっていても、子の完了を待つ親の分で
 * 起き続けてしまう。そのため hold は会話のツリー (ルートのセッション) ごとに 1 つ持ち、
 * ツリーの中で実際に作業しているセッションがあるかで決める。
 */
const setup = async (api) => {
  // 1.x も setup を呼ぶが event を渡さない。そちらは server 側が処理する
  if (typeof api?.event?.subscribe !== "function") return

  /**
   * サービスは `wakelock run opencode` で包んだ TUI の子孫にならないため、
   * 祖先の照合では run の arm に届かない。ラベルの一致でも照合させる。
   */
  const acquireWork = (sessionID) => acquire(sessionID, "--match-label")

  /**
   * sessionID -> { executing, pending: 応答待ちの承認 requestID }。動きのあるセッションだけ持つ。
   * 承認待ちを件数で持つのは、並列のツール呼び出しで承認が複数出たときに
   * 最初の応答だけで起きてしまわないようにするため。
   */
  const sessions = new Map()
  /** sessionID -> 親の sessionID (ルートなら null) */
  const parents = new Map()
  /** acquire 済みのルートの sessionID */
  const held = new Set()
  /** 削除済みのセッション。遅れて届いたイベントで実行中に戻さない */
  const deleted = new Set()
  /** 破棄 (再読み込み・終了) された後は、新たに hold を取らない */
  let disposed = false

  const state = (sessionID) => {
    let s = sessions.get(sessionID)
    if (!s) sessions.set(sessionID, (s = { executing: false, pending: new Set() }))
    return s
  }

  const rootOf = (sessionID) => {
    const seen = new Set()
    let id = sessionID
    while (parents.get(id) && !seen.has(id)) {
      seen.add(id)
      id = parents.get(id)
    }
    return id
  }

  /**
   * 親子関係は session.created で覚える。それより前からあるセッション
   * (再読み込みの後など) は問い合わせる。問い合わせに失敗したら、その時点では
   * ルートとみなしてそのセッション単体で hold を持つ。失敗は一時的かもしれないので覚えず、
   * 次のイベントで引き直す。
   */
  const resolveParents = async (sessionID) => {
    let id = sessionID
    while (id && !parents.has(id)) {
      let info
      try {
        info = await api.session.get({ sessionID: id })
      } catch {
        return
      }
      const parentID = info?.parentID ?? null
      parents.set(id, parentID)
      id = parentID
    }
  }

  /**
   * 自分で作業しているセッション。実行中で、承認待ちがなく、実行中の子もいない。
   * 子の完了を待っているだけの親は数えない。
   */
  const working = (sessionID, s) =>
    s.executing &&
    s.pending.size === 0 &&
    ![...sessions].some(([id, child]) => child.executing && parents.get(id) === sessionID)

  /**
   * ツリーの中に作業しているセッションが 1 つでもあれば、そのルートの hold を持つ。
   * 並列のサブエージェントの一部が承認待ちでも、他が作業していれば起き続ける。
   *
   * イベントのツリーだけでなく全体を計算し直す。親子関係が後から分かってルートが
   * 変わったとき (問い合わせに失敗した後に session.created が届いた等) に、
   * 古いルートの hold を取り残さないため。付け替えの間にスリープ設定が
   * 揺れないよう、acquire を先に、release を後に行う。
   * refresh は root を、状態が変わらなくても acquire し直す (CLI 側は同内容なら即返す)。
   */
  const sync = async (root, { refresh = false } = {}) => {
    if (disposed) return
    const wanted = new Set()
    for (const [id, s] of sessions) if (working(id, s)) wanted.add(rootOf(id))

    for (const r of wanted) {
      if (held.has(r) && !(refresh && r === root)) continue
      held.add(r)
      await acquireWork(r)
      // 破棄と行き違った acquire は、破棄側の release より後に hold を書いたかもしれない。
      // CLI のロックの取り合い次第で順序は決まらないので、ここで取り直して手放す
      if (disposed) return release(r)
    }
    for (const r of [...held]) {
      if (wanted.has(r)) continue
      held.delete(r)
      await release(r)
    }
  }

  const handle = async (event) => {
    // 購読が abort に応じず、破棄の後にもイベントが届く場合に備える
    if (disposed) return
    const data = event?.data
    const sessionID = data?.sessionID
    if (!sessionID || deleted.has(sessionID)) return

    /** 親子関係を覚えるだけで、hold は動かさない */
    if (event.type === "session.created") {
      parents.set(sessionID, data.parentID ?? null)
      return
    }
    if (!TRACKED.has(event.type)) return

    await resolveParents(sessionID)
    // 問い合わせを待つ間に破棄されていたら、状態を作り直さない
    if (disposed) return
    const root = rootOf(sessionID)
    const s = state(sessionID)
    switch (event.type) {
      /** 作業開始 */
      case "session.execution.started":
        s.executing = true
        break

      /**
       * ステップの開始は実行中の証拠になる。プラグインの再読み込みで
       * execution.started を取り逃がしていても、ここで追い付く。
       * 後から arm された場合や、前回の acquire が失敗していた場合にも効くよう取り直す。
       */
      case "session.step.started":
        s.executing = true
        break

      /** 承認待ち */
      case "permission.asked":
        s.pending.add(data.id)
        break

      /** 承認が返ってきた (拒否でも作業は続く) */
      case "permission.replied":
        s.pending.delete(data.requestID)
        break

      /** 応答完了・失敗・中断・セッション消滅はいずれも作業の終わり */
      default:
        s.executing = false
        s.pending.clear()
        if (event.type === "session.deleted") {
          parents.delete(sessionID)
          deleted.add(sessionID)
        }
    }
    if (!s.executing && s.pending.size === 0) sessions.delete(sessionID)
    return sync(root, { refresh: event.type === "session.step.started" })
  }

  const releaseAll = () => {
    const ids = [...held]
    held.clear()
    sessions.clear()
    parents.clear()
    return Promise.all(ids.map(release))
  }

  const abort = new AbortController()
  const loop = (async () => {
    try {
      for await (const event of api.event.subscribe({ signal: abort.signal })) {
        await handle(event).catch(() => {})
      }
    } catch {
      // 購読が切れたら以後の解除を受け取れない。下で手放す
    }
    // 破棄以外で購読が終わった場合も、起き続けないよう手放しておく
    if (!abort.signal.aborted) await releaseAll()
  })()

  /**
   * 無効化・再読み込み・終了時に呼ばれる。取った hold を残さない。
   * opencode はこれを待つので、購読が止まらなくても長くは待たせない。
   */
  return async () => {
    disposed = true
    abort.abort()
    let timer
    await Promise.race([loop, new Promise((resolve) => (timer = setTimeout(resolve, 3000)))])
    clearTimeout(timer)
    await releaseAll()
  }
}

export default { id: "wakelock", setup, server }
