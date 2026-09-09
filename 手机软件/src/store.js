const STORAGE_KEY = 'sohun-rfid-mobile-store-v2'

const seedInventory = [
  {
    id: 'inv-pla-white',
    manufacturer: '拓竹',
    model: 'PLA Matte',
    materialType: 'PLA',
    colorHex: '#F5F5F2',
    colorName: '哑光白',
    totalGrams: 1000,
    remainingGrams: 832,
    uid: 'E2 10 34 8C 1A 00 7D',
    trayUuid: 'TRAY-AMS-01-A1',
    batchNo: 'GFA00',
    updatedAt: '今天 09:42',
    source: 'desktop',
  },
  {
    id: 'inv-petg-blue',
    manufacturer: '拓竹',
    model: 'PETG Basic',
    materialType: 'PETG',
    colorHex: '#2455D6',
    colorName: '钴蓝',
    totalGrams: 1000,
    remainingGrams: 640,
    uid: 'E2 10 34 8C 19 00 66',
    trayUuid: 'TRAY-AMS-01-A2',
    batchNo: 'GFA01',
    updatedAt: '昨天 18:16',
    source: 'desktop',
  },
  {
    id: 'inv-abs-charcoal',
    manufacturer: 'eSUN',
    model: 'ABS+',
    materialType: 'ABS',
    colorHex: '#25282D',
    colorName: '炭黑',
    totalGrams: 1000,
    remainingGrams: 386,
    uid: 'E2 10 34 8C 11 00 4A',
    trayUuid: '',
    batchNo: 'ABS-08',
    updatedAt: '昨天 16:03',
    source: 'mobile',
  },
  {
    id: 'inv-pla-pink',
    manufacturer: 'JAYO',
    model: 'PLA',
    materialType: 'PLA',
    colorHex: '#F39FB4',
    colorName: '樱花粉',
    totalGrams: 1000,
    remainingGrams: 1200,
    uid: '',
    trayUuid: '',
    batchNo: 'PLA-22',
    updatedAt: '昨天 12:20',
    source: 'mobile',
  },
]

const seedHistory = [
  { id: 'event-1', action: '写入成功', material: 'PLA 哑光白', uid: 'E2 10 34 8C 1A 00 7D', time: '今天 09:42', status: 'success', source: 'desktop' },
  { id: 'event-2', action: '读取 AMS', material: 'PETG 钴蓝', uid: 'E2 10 34 8C 19 00 66', time: '昨天 18:16', status: 'read', source: 'desktop' },
  { id: 'event-3', action: '写入成功', material: 'ABS 炭黑', uid: 'E2 10 34 8C 11 00 4A', time: '昨天 16:03', status: 'success', source: 'mobile' },
]

export const defaultStore = {
  version: 2,
  account: null,
  inventory: seedInventory,
  history: seedHistory,
  sync: {
    state: 'local',
    lastSyncedAt: '今天 09:48',
    pending: 0,
    revision: 12,
  },
}

function clone(value) {
  return JSON.parse(JSON.stringify(value))
}

export function loadStore() {
  if (typeof window === 'undefined') return clone(defaultStore)
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY)
    if (!raw) return clone(defaultStore)
    const saved = JSON.parse(raw)
    return {
      ...clone(defaultStore),
      ...saved,
      inventory: Array.isArray(saved.inventory) ? saved.inventory : clone(defaultStore.inventory),
      history: Array.isArray(saved.history) ? saved.history : clone(defaultStore.history),
      sync: { ...clone(defaultStore.sync), ...(saved.sync ?? {}) },
    }
  } catch {
    return clone(defaultStore)
  }
}

export function saveStore(store) {
  if (typeof window === 'undefined') return
  window.localStorage.setItem(STORAGE_KEY, JSON.stringify(store))
}

export function formatWeight(grams) {
  const value = Number(grams) || 0
  return value >= 1000 ? `${(value / 1000).toFixed(value % 1000 === 0 ? 0 : 1)} kg` : `${Math.round(value)} g`
}

export function makeUid() {
  const bytes = Array.from({ length: 7 }, () => Math.floor(Math.random() * 256))
  return bytes.map((value) => value.toString(16).padStart(2, '0')).join(' ').toUpperCase()
}

export function nowLabel() {
  return `今天 ${new Intl.DateTimeFormat('zh-CN', { hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date())}`
}

