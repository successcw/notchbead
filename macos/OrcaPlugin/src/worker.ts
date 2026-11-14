// Tells NotchBead the moment something changes in Orca, so it doesn't have to start the Orca CLI
// every few seconds to find out. Nothing about the agents leaves Orca: NotchBead only hears that
// something changed, then asks Orca itself.
//
// - On each agent status change (working, blocked, waiting, done) and each move to another
//   workspace, it posts the Darwin notification CHANGED with /usr/bin/notifyutil.
// - Whenever it starts or posts, it touches SEEN_FILE in NotchBead's folder. While that file was
//   touched in the last 12 hours, NotchBead counts on these posts and checks Orca on its own only
//   every 30 seconds instead of every 3. (Orca stops an idle worker, so this can't be a timer.)
import { execFile } from 'node:child_process'
import { mkdirSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import type { OrcaWorkerApi } from 'orca/worker'

export const CHANGED = 'com.notchbead.orca.changed'
export const SEEN_FILE = join(homedir(), 'Library', 'Application Support', 'NotchBead', 'orca-bridge-seen')

export type Notify = {
  /** NotchBead should check Orca now. */
  changed(): void
  /** The bridge is installed and running. */
  seen(): void
}

const system: Notify = {
  changed() {
    execFile('/usr/bin/notifyutil', ['-p', CHANGED], () => {})
  },
  seen() {
    try {
      mkdirSync(join(SEEN_FILE, '..'), { recursive: true })
      writeFileSync(SEEN_FILE, `${new Date().toISOString()}\n`)
    } catch {
      // NotchBead then just keeps checking Orca every 3 seconds, as without the bridge.
    }
  }
}

export function bridge(orca: OrcaWorkerApi, notify: Notify): void {
  notify.seen()
  const changed = () => {
    notify.seen()
    notify.changed()
  }

  orca.events.on('agent.status.changed', changed)

  // This also fires when a terminal opens, closes or is renamed, and agents rename theirs all the
  // time. Only moving to another workspace matters to NotchBead.
  let focused: string | undefined
  orca.events.on('workspace.changed', ({ context }) => {
    const key = context ? `${context.branch}\n${context.displayName}` : ''
    if (key === focused) return
    const first = focused === undefined
    focused = key
    if (!first) changed()
  })
}

export default function activate(orca: OrcaWorkerApi): void {
  bridge(orca, system)
}
