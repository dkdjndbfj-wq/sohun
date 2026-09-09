const SYNC_DELAY = 850

function wait(ms) {
  return new Promise((resolve) => window.setTimeout(resolve, ms))
}

/**
 * The UI talks to this boundary instead of embedding transport details in
 * the RFID workflow. A production build can replace this adapter with the
 * sohun API client while keeping the local queue and conflict UI unchanged.
 */
export const syncAdapter = {
  async push({ account, inventory, history, revision }) {
    if (!account) throw new Error('请先登录 sohun 账号')
    await wait(SYNC_DELAY)
    return {
      revision: Number(revision || 0) + 1,
      syncedAt: new Date().toISOString(),
      itemCount: inventory.length,
      eventCount: history.length,
      transport: 'local-demo',
    }
  },
}

