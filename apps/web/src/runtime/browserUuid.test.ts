import { describe, expect, it, vi } from 'vitest'
import { installBrowserUuid } from './browserUuid'

describe('HTTP browser UUID compatibility', () => {
  it('preserves the native implementation', () => {
    const native = vi.fn()
    const target = { randomUUID: native } as unknown as Crypto
    installBrowserUuid(target)
    expect(target.randomUUID).toBe(native)
  })

  it('uses secure random bytes and sets UUID v4 version and variant', () => {
    const random = vi.fn((bytes: Uint8Array) => bytes.fill(255))
    const target = { getRandomValues: random } as unknown as Crypto
    installBrowserUuid(target)
    expect(target.randomUUID()).toBe('ffffffff-ffff-4fff-bfff-ffffffffffff')
    expect(random).toHaveBeenCalledOnce()
  })

  it('fails explicitly if secure randomness is unavailable', () => {
    expect(() => installBrowserUuid({} as Crypto)).toThrow('cryptographically secure')
  })
})
