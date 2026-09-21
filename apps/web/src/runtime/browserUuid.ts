/** HTTP/IP installations still expose getRandomValues, but not randomUUID. */
export function installBrowserUuid(target: Crypto): void {
  if (typeof target.randomUUID === 'function') return
  if (typeof target.getRandomValues !== 'function') {
    throw new Error('A browser with cryptographically secure random values is required')
  }
  Object.defineProperty(target, 'randomUUID', {
    configurable: true,
    value: (): ReturnType<Crypto['randomUUID']> => {
      const bytes = target.getRandomValues(new Uint8Array(16))
      bytes[6] = (bytes[6] & 0x0f) | 0x40
      bytes[8] = (bytes[8] & 0x3f) | 0x80
      const hex = Array.from(bytes, (value) => value.toString(16).padStart(2, '0')).join('')
      return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
    },
  })
}
