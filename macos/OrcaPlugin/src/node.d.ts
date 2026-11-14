// The few Node APIs the worker uses, so `tsc` checks it without installing @types/node.
declare module 'node:child_process' {
  export function execFile(file: string, args: readonly string[], callback: (error: Error | null) => void): unknown
}
declare module 'node:fs' {
  export function mkdirSync(path: string, options?: { recursive?: boolean }): unknown
  export function writeFileSync(path: string, data: string): void
}
declare module 'node:os' {
  export function homedir(): string
}
declare module 'node:path' {
  export function join(...parts: string[]): string
}
