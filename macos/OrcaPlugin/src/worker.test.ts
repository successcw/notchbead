// Runs the worker as Orca would, recording what it tells NotchBead instead of telling it.
import { assert, mountWorker, test } from 'orca/testing'
import type { OrcaWorkerApi } from 'orca/worker'
import { bridge } from './worker'

async function mount() {
  const said: string[] = []
  const worker = await mountWorker({
    default: (orca: OrcaWorkerApi) =>
      bridge(orca, { changed: () => said.push('changed'), seen: () => said.push('seen') })
  })
  return { worker, said, changes: () => said.filter((word) => word === 'changed').length }
}

const agent = (state: 'working' | 'blocked' | 'waiting' | 'done') => ({
  workspaceId: 'w1',
  paneKey: 'p1',
  state,
  receivedAt: 1
})

const context = (displayName: string, terminals: string[] = []) => ({
  context: { branch: 'main', displayName, terminals: terminals.map((id) => ({ id })) }
})

test('marks itself seen as soon as it starts', async () => {
  const { worker, said } = await mount()
  assert.equal(said[0], 'seen')
  await worker.deactivate()
})

test('tells NotchBead about every agent status change, marking itself seen each time', async () => {
  const { worker, said, changes } = await mount()
  const before = said.length
  await worker.emit('agent.status.changed', agent('working'))
  await worker.emit('agent.status.changed', agent('done'))
  assert.equal(changes(), 2)
  assert.deepEqual(said.slice(before), ['seen', 'changed', 'seen', 'changed'])
  await worker.deactivate()
})

test('tells NotchBead when the focused workspace changes, not when its terminals do', async () => {
  const { worker, changes } = await mount()
  // Orca first delivers the current context as the worker subscribes: that alone isn't a change.
  assert.equal(changes(), 0)
  await worker.emit('workspace.changed', context('alpha'))
  const before = changes()
  await worker.emit('workspace.changed', context('alpha', ['t1']))
  await worker.emit('workspace.changed', context('alpha', ['t1', 't2']))
  assert.equal(changes(), before)
  await worker.emit('workspace.changed', context('beta'))
  await worker.emit('workspace.changed', { context: null })
  assert.equal(changes(), before + 2)
  await worker.deactivate()
})
