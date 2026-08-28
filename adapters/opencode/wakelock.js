/**
 * wakelock plugin for opencode
 *
 * opencode が実際に作業している間だけ hold を取り、承認待ちになったら手放す。
 * これにより `wakelock run opencode` で起動したセッションは
 * 「作業中は蓋を閉じても動き、承認待ちで放置されたら通常どおりスリープする」挙動になる。
 *
 * wakelock 側で arm されていないセッションからの acquire は無視されるため、
 * このプラグインを常設しても素の opencode の挙動は変わらない。
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
 */
function wakelock(...args) {
  return new Promise((resolve) => {
    execFile(WAKELOCK_BIN, args, { timeout: 5000 }, () => resolve())
  })
}

const holdID = (sessionID) => `opencode-${sessionID}`

const acquire = (sessionID) =>
  sessionID
    ? wakelock("acquire", holdID(sessionID), "--pid", String(process.pid), "--label", "opencode")
    : Promise.resolve()

const release = (sessionID) =>
  sessionID ? wakelock("release", holdID(sessionID)) : Promise.resolve()

export const WakelockPlugin = async () => {
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

export default WakelockPlugin
