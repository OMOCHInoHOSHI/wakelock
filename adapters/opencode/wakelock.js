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

/**
 * 2.0 は作業をサーバーが持ち、プラグインもそこで動く。
 * 通常は常駐サービス (`opencode serve --service`、親は launchd) なので、
 * process.pid は TUI ではなくサービスになる。TUI を閉じても作業はサービスで続くため、
 * hold をサービスに紐付けるのは実態どおりでもある。
 */
const setup = async (api) => {
  // 1.x も setup を呼ぶが event を渡さない。そちらは server 側が処理する
  if (typeof api?.event?.subscribe !== "function") return

  /**
   * サービスは `wakelock run opencode` で包んだ TUI の子孫にならないため、
   * 祖先の照合では run の arm に届かない。ラベルの一致でも照合させる。
   */
  const acquireWork = (sessionID) => acquire(sessionID, "--match-label")

  /** sessionID -> { executing, pending: 応答待ちの承認 requestID } */
  const sessions = new Map()
  /** acquire 済みの sessionID */
  const held = new Set()

  const state = (sessionID) => {
    let s = sessions.get(sessionID)
    if (!s) sessions.set(sessionID, (s = { executing: false, pending: new Set() }))
    return s
  }

  /**
   * 実行中で、承認待ちを 1 件も抱えていないときだけ hold を持つ。
   * 承認待ちを件数で持つのは、並列のツール呼び出しで承認が複数出たときに
   * 最初の応答だけで起きてしまわないようにするため。
   * refresh は状態が変わらなくても acquire し直す (CLI 側は同内容なら即返す)。
   */
  const sync = async (sessionID, { refresh = false } = {}) => {
    const s = sessions.get(sessionID)
    const want = !!s && s.executing && s.pending.size === 0
    if (s && !s.executing && s.pending.size === 0) sessions.delete(sessionID)

    if (want && (refresh || !held.has(sessionID))) {
      held.add(sessionID)
      await acquireWork(sessionID)
    } else if (!want && held.has(sessionID)) {
      held.delete(sessionID)
      await release(sessionID)
    }
  }

  const handle = async (event) => {
    const data = event?.data
    const sessionID = data?.sessionID
    if (!sessionID) return
    switch (event.type) {
      /** 作業開始 */
      case "session.execution.started":
        state(sessionID).executing = true
        return sync(sessionID)

      /**
       * ステップの開始は実行中の証拠になる。プラグインの再読み込みで
       * execution.started を取り逃がしていても、ここで追い付く。
       * 後から arm された場合や、前回の acquire が失敗していた場合にも効くよう取り直す。
       */
      case "session.step.started":
        state(sessionID).executing = true
        return sync(sessionID, { refresh: true })

      /** 承認待ち */
      case "permission.asked":
        state(sessionID).pending.add(data.id)
        return sync(sessionID)

      /** 承認が返ってきた (拒否でも作業は続く) */
      case "permission.replied":
        state(sessionID).pending.delete(data.requestID)
        return sync(sessionID)

      /** 応答完了・失敗・中断・セッション消滅はいずれも解除 */
      case "session.execution.succeeded":
      case "session.execution.failed":
      case "session.execution.interrupted":
      case "session.deleted":
        sessions.delete(sessionID)
        return sync(sessionID)
    }
  }

  const releaseAll = () => {
    const ids = [...held]
    held.clear()
    sessions.clear()
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
    abort.abort()
    await Promise.race([loop, new Promise((resolve) => setTimeout(resolve, 3000))])
    await releaseAll()
  }
}

export default { id: "wakelock", setup, server }
