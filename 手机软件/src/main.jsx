import { useEffect, useMemo, useRef, useState } from 'react'
import { createRoot } from 'react-dom/client'
import {
  Activity,
  ArrowLeft,
  ArrowRight,
  BadgeCheck,
  Bell,
  Check,
  CheckCircle2,
  ChevronDown,
  CircleHelp,
  ClipboardList,
  Clock3,
  Database,
  FileText,
  History,
  Home,
  Info,
  Layers3,
  Menu,
  MoreHorizontal,
  PackageCheck,
  Plus,
  Radio,
  RefreshCw,
  Search,
  Settings,
  ShieldCheck,
  SlidersHorizontal,
  Smartphone,
  Tag,
  UserRound,
  UsersRound,
  Wifi,
  X,
  Zap,
} from 'lucide-react'
import { formatWeight, loadStore, makeUid, nowLabel, saveStore } from './store'
import { accountTransport, signIn } from './accountClient'
import { syncAdapter } from './syncAdapter'
import './styles.css'

const brandOptions = ['拓竹', 'eSUN', 'JAYO', 'Polymaker', '其他']
const materialTypes = [
  { value: 'PLA', label: 'PLA', description: '易打印，适合日常模型', temp: '190–220 °C' },
  { value: 'PETG', label: 'PETG', description: '耐冲击，适合功能件', temp: '230–260 °C' },
  { value: 'ABS', label: 'ABS', description: '耐热，建议封闭腔体', temp: '240–270 °C' },
  { value: 'TPU', label: 'TPU', description: '柔性材料，低速打印', temp: '210–240 °C' },
]
const colorPresets = [
  { name: '哑光白', hex: '#F5F5F2' },
  { name: '钴蓝', hex: '#2455D6' },
  { name: '炭黑', hex: '#25282D' },
  { name: '樱花粉', hex: '#F39FB4' },
  { name: '松石绿', hex: '#17B5A3' },
]

const navItems = [
  { id: 'home', label: '工作台', icon: Home, group: '工作' },
  { id: 'rfid', label: 'RFID 写入', icon: Radio, group: '工作' },
  { id: 'ams', label: 'AMS 读取', icon: Wifi, group: '工作' },
  { id: 'inventory', label: '库存', icon: Database, group: '材料' },
  { id: 'cost', label: '耗材成本', icon: Layers3, group: '材料' },
  { id: 'history', label: '操作记录', icon: History, group: '洞察' },
  { id: 'settings', label: '设置', icon: Settings, group: '其他' },
]

const initialForm = {
  brand: '拓竹',
  materialType: 'PLA',
  colorName: '哑光白',
  colorHex: '#F5F5F2',
  model: 'PLA Matte',
  totalGrams: '1000',
  lot: 'GFA00',
  note: '',
}

const amsTrays = [
  { id: 'A1', name: 'A1 · PLA 哑光白', brand: '拓竹', materialType: 'PLA', colorName: '哑光白', colorHex: '#F5F5F2', remainingGrams: 832, uid: 'E2 10 34 8C 1A 00 7D', protocol: 'Bambu MIFARE Classic', trayUuid: 'TRAY-AMS-01-A1', updatedAt: '09:42' },
  { id: 'A2', name: 'A2 · PETG 钴蓝', brand: '拓竹', materialType: 'PETG', colorName: '钴蓝', colorHex: '#2455D6', remainingGrams: 640, uid: 'E2 10 34 8C 19 00 66', protocol: 'Bambu MIFARE Classic', trayUuid: 'TRAY-AMS-01-A2', updatedAt: '09:40' },
  { id: 'A3', name: 'A3 · ABS 炭黑', brand: 'eSUN', materialType: 'ABS', colorName: '炭黑', colorHex: '#25282D', remainingGrams: 386, uid: 'E2 10 34 8C 11 00 4A', protocol: 'Bambu MIFARE Classic', trayUuid: 'TRAY-AMS-01-A3', updatedAt: '09:38' },
  { id: 'A4', name: 'A4 · 未识别', brand: '未知', materialType: '—', colorName: '—', colorHex: '#DDE3DF', remainingGrams: 0, uid: '', protocol: '等待读取', trayUuid: '', updatedAt: '—' },
]

function accountKey(account) {
  return String(account?.id || account?.email || '').trim().toLowerCase()
}

function App() {
  const [activePage, setActivePage] = useState('rfid')
  const [store, setStore] = useState(() => loadStore())
  const [readerOnline, setReaderOnline] = useState(true)
  const [writeStage, setWriteStage] = useState('form')
  const [writeForm, setWriteForm] = useState(initialForm)
  const [writeUid, setWriteUid] = useState('')
  const [amsStage, setAmsStage] = useState('idle')
  const [amsResult, setAmsResult] = useState(null)
  const [selectedTray, setSelectedTray] = useState(amsTrays[0])
  const [toast, setToast] = useState(null)
  const [showMenu, setShowMenu] = useState(false)
  const [showMore, setShowMore] = useState(false)
  const [showAccount, setShowAccount] = useState(false)
  const [searchQuery, setSearchQuery] = useState('')
  const [syncBusy, setSyncBusy] = useState(false)
  const [accountBusy, setAccountBusy] = useState(false)
  const operationRef = useRef({ cancelled: false })
  const amsTimerRef = useRef(null)
  const syncGenerationRef = useRef(0)
  const localMutationGenerationRef = useRef(0)

  useEffect(() => saveStore(store), [store])

  useEffect(() => {
    if (!toast) return undefined
    const timer = window.setTimeout(() => setToast(null), 3400)
    return () => window.clearTimeout(timer)
  }, [toast])

  useEffect(() => () => {
    operationRef.current.cancelled = true
    if (amsTimerRef.current) window.clearTimeout(amsTimerRef.current)
    syncGenerationRef.current += 1
  }, [])

  const notify = (message, tone = 'success') => setToast({ message, tone })
  const page = navItems.find((item) => item.id === activePage) ?? navItems[1]

  const updateStore = (updater) => setStore((current) => ({ ...current, ...updater(current) }))
  const setPage = (nextPage) => {
    setActivePage(nextPage)
    setShowMore(false)
    setShowMenu(false)
  }
  const handleFormChange = (field, value) => setWriteForm((current) => ({ ...current, [field]: value }))
  const selectColor = (color) => setWriteForm((current) => ({ ...current, colorName: color.name, colorHex: color.hex }))
  const formIsValid = Boolean(writeForm.brand && writeForm.materialType && writeForm.colorHex && Number(writeForm.totalGrams) > 0)

  const handleReaderToggle = () => {
    const wasOnline = readerOnline
    const interruptedWrite = wasOnline && (writeStage === 'writing' || writeStage === 'verify')
    const interruptedAms = wasOnline && amsStage === 'reading'
    if (interruptedWrite) {
      operationRef.current.cancelled = true
      setWriteStage('error')
    }
    if (interruptedAms) {
      if (amsTimerRef.current) window.clearTimeout(amsTimerRef.current)
      amsTimerRef.current = null
      setAmsResult(null)
      setAmsStage('idle')
    }
    setReaderOnline((online) => !online)
    const interrupted = interruptedWrite || interruptedAms
    const interruptionMessage = interruptedWrite && interruptedAms
      ? '桥接已断开，写入与 AMS 读取均已停止，请重试'
      : interruptedWrite
        ? '桥接已断开，写入已停止，请重试'
        : '桥接已断开，AMS 读取已停止，请重试'
    notify(interrupted ? interruptionMessage : wasOnline ? 'RFID 桥接已断开' : 'RFID 桥接已连接', wasOnline ? 'warning' : 'success')
  }

  const openReview = () => {
    if (!readerOnline) return notify('请先连接 BambuRfidReader 桥接设备', 'warning')
    if (!formIsValid) return notify('请补全品牌、耗材类型和净重', 'warning')
    setWriteUid(makeUid())
    setWriteStage('review')
  }

  const commitWrite = () => {
    const item = {
      id: `inv-${Date.now()}`,
      manufacturer: writeForm.brand,
      model: writeForm.model || `${writeForm.materialType} 通用`,
      materialType: writeForm.materialType,
      colorHex: writeForm.colorHex,
      colorName: writeForm.colorName,
      totalGrams: Number(writeForm.totalGrams),
      remainingGrams: Number(writeForm.totalGrams),
      uid: writeUid,
      trayUuid: `TRAY-MOBILE-${writeUid.replaceAll(' ', '').slice(-8)}`,
      batchNo: writeForm.lot,
      note: writeForm.note,
      updatedAt: nowLabel(),
      source: 'mobile',
    }
    const historyItem = {
      id: `event-${Date.now()}`,
      action: '写入并校验',
      material: `${item.materialType} ${item.colorName}`,
      uid: item.uid,
      time: nowLabel(),
      status: 'success',
      source: 'mobile',
      brand: item.manufacturer,
      materialType: item.materialType,
    }
    localMutationGenerationRef.current += 1
    updateStore((current) => ({
      inventory: [item, ...current.inventory.filter((entry) => entry.uid !== item.uid)],
      history: [historyItem, ...current.history],
      sync: { ...current.sync, state: 'pending', pending: Number(current.sync.pending || 0) + 1 },
    }))
  }

  useEffect(() => {
    if (writeStage !== 'writing' && writeStage !== 'verify') return undefined
    const timer = window.setTimeout(() => {
      if (operationRef.current.cancelled) return
      if (writeStage === 'writing') return setWriteStage('verify')
      commitWrite()
      setWriteStage('success')
      notify('写入完成，读回校验通过')
    }, writeStage === 'writing' ? 1200 : 900)
    return () => window.clearTimeout(timer)
  }, [writeStage])

  const startWrite = () => {
    if (!readerOnline) return notify('读写器已离线，无法开始写入', 'warning')
    operationRef.current = { cancelled: false }
    setWriteStage('writing')
  }

  const resetWrite = () => {
    operationRef.current.cancelled = true
    setWriteStage('form')
    setWriteUid('')
    notify('已准备下一卷耗材')
  }

  const readAms = (tray = selectedTray) => {
    if (!readerOnline) return notify('请先连接 RFID 桥接设备，再读取 AMS', 'warning')
    if (amsTimerRef.current) window.clearTimeout(amsTimerRef.current)
    setSelectedTray(tray)
    setAmsStage('reading')
    setAmsResult(null)
    amsTimerRef.current = window.setTimeout(() => {
      amsTimerRef.current = null
      if (!tray.uid) {
        setAmsStage('idle')
        notify(`${tray.id} 未识别到可用 RFID 标签`, 'warning')
        return
      }
      setAmsResult(tray)
      setAmsStage('ready')
      notify(`${tray.id} 已识别，可加入耗材库`)
    }, 1000)
  }

  const addAmsToInventory = () => {
    if (!amsResult || !amsResult.uid) return notify('当前 AMS 没有可入库的标签', 'warning')
    const item = {
      id: `inv-ams-${Date.now()}`,
      manufacturer: amsResult.brand,
      model: `${amsResult.materialType} AMS`,
      materialType: amsResult.materialType,
      colorHex: amsResult.colorHex,
      colorName: amsResult.colorName,
      totalGrams: 1000,
      remainingGrams: amsResult.remainingGrams,
      uid: amsResult.uid,
      trayUuid: amsResult.trayUuid,
      batchNo: '',
      updatedAt: nowLabel(),
      source: 'ams',
    }
    const historyItem = {
      id: `event-ams-${Date.now()}`,
      action: 'AMS 读取入库',
      material: `${item.materialType} ${item.colorName}`,
      uid: item.uid,
      time: nowLabel(),
      status: 'read',
      source: 'ams',
      brand: item.manufacturer,
      materialType: item.materialType,
    }
    localMutationGenerationRef.current += 1
    updateStore((current) => ({
      inventory: [item, ...current.inventory.filter((entry) => entry.uid !== item.uid)],
      history: [historyItem, ...current.history],
      sync: { ...current.sync, state: 'pending', pending: Number(current.sync.pending || 0) + 1 },
    }))
    notify('已加入本地耗材库，等待演示同步')
  }

  const syncNow = async () => {
    if (!store.account) {
      setShowAccount(true)
      return notify('登录 sohun 账号后才能开始演示同步', 'warning')
    }
    if (syncBusy) return
    const account = store.account
    const accountId = accountKey(account)
    const syncGeneration = syncGenerationRef.current
    const mutationGeneration = localMutationGenerationRef.current
    setSyncBusy(true)
    updateStore((current) => ({ sync: { ...current.sync, state: 'syncing' } }))
    try {
      const result = await syncAdapter.push({ account, inventory: store.inventory, history: store.history, revision: store.sync.revision })
      if (syncGenerationRef.current !== syncGeneration) return
      const changedDuringSync = localMutationGenerationRef.current !== mutationGeneration
      updateStore((current) => {
        if (accountKey(current.account) !== accountId) return {}
        if (changedDuringSync) {
          return { sync: { ...current.sync, state: 'pending', revision: result.revision } }
        }
        return { sync: { ...current.sync, state: 'synced', lastSyncedAt: '刚刚', pending: 0, revision: result.revision } }
      })
      if (changedDuringSync) {
        notify(result.transport === 'local-demo'
          ? '演示同步完成，但期间新增记录仍待处理；数据未上传服务器'
          : '同步完成，但期间新增记录仍待同步', 'warning')
      } else {
        notify(result.transport === 'local-demo'
          ? `演示同步完成：本地记录 ${result.itemCount} 卷，未上传服务器`
          : `已同步 ${result.itemCount} 卷耗材到桌面版`)
      }
    } catch (error) {
      if (syncGenerationRef.current !== syncGeneration) return
      if (accountKey(store.account) !== accountId) return
      updateStore((current) => ({ sync: { ...current.sync, state: 'error' } }))
      notify(error.message || '同步失败，请稍后重试', 'warning')
    } finally {
      if (syncGenerationRef.current === syncGeneration) setSyncBusy(false)
    }
  }

  const login = async (credentials) => {
    if (accountBusy) return
    setAccountBusy(true)
    try {
      const result = await signIn(credentials)
      const user = result.user
      syncGenerationRef.current += 1
      setSyncBusy(false)
      updateStore((current) => ({ account: { ...user, loggedInAt: new Date().toISOString(), transport: result.transport }, sync: { ...current.sync, state: 'pending' } }))
      setShowAccount(false)
      notify(result.transport === 'sohun-api' ? `已登录 sohun · ${user.displayName}` : `已进入本地演示 · ${user.displayName}`)
    } catch (error) {
      notify(error.message || 'sohun 登录失败', 'warning')
    } finally {
      setAccountBusy(false)
    }
  }

  const logout = () => {
    syncGenerationRef.current += 1
    setSyncBusy(false)
    updateStore((current) => ({ account: null, sync: { ...current.sync, state: 'local' } }))
    setShowAccount(false)
    notify('已退出 sohun 账号', 'warning')
  }

  const renderPage = () => {
    if (activePage === 'rfid') return <RfidPage writeStage={writeStage} writeForm={writeForm} writeUid={writeUid} history={store.history} readerOnline={readerOnline} formIsValid={formIsValid} onChange={handleFormChange} onColor={selectColor} onReview={openReview} onEdit={() => setWriteStage('form')} onStartWrite={startWrite} onReset={resetWrite} onHistory={() => setPage('history')} amsStage={amsStage} amsResult={amsResult} selectedTray={selectedTray} onReadAms={readAms} onAddAms={addAmsToInventory} onAmsPage={() => setPage('ams')} />
    if (activePage === 'home') return <HomePage store={store} onOpenRfid={() => setPage('rfid')} onOpenAms={() => setPage('ams')} onSync={syncNow} />
    if (activePage === 'ams') return <AmsPage readerOnline={readerOnline} amsStage={amsStage} amsResult={amsResult} selectedTray={selectedTray} onRead={readAms} onSelect={setSelectedTray} onAdd={addAmsToInventory} onInventory={() => setPage('inventory')} />
    if (activePage === 'inventory') return <InventoryPage inventory={store.inventory} query={searchQuery} onQuery={setSearchQuery} onSync={syncNow} onOpenRfid={() => setPage('rfid')} />
    if (activePage === 'history') return <HistoryPage history={store.history} onBack={() => setPage('rfid')} />
    if (activePage === 'cost') return <CostPage inventory={store.inventory} />
    return <SettingsPage account={store.account} sync={store.sync} readerOnline={readerOnline} onReader={handleReaderToggle} onSync={syncNow} onAccount={() => setShowAccount(true)} transport={accountTransport()} />
  }

  return <div className="app-shell"><DesktopSidebar activePage={activePage} account={store.account} sync={store.sync} onChange={setPage} onAccount={() => setShowAccount(true)} /><div className="app-main"><TopBar page={page} readerOnline={readerOnline} account={store.account} sync={store.sync} onReader={handleReaderToggle} onAccount={() => setShowAccount(true)} onMenu={() => setShowMenu((visible) => !visible)} showMenu={showMenu} onCloseMenu={() => setShowMenu(false)} onSync={syncNow} /><main className="page-content">{renderPage()}</main><MobileNav activePage={activePage} onChange={setPage} onMore={() => setShowMore(true)} /></div>{showMore && <MoreDrawer activePage={activePage} onChange={setPage} onClose={() => setShowMore(false)} />}{showAccount && <AccountModal account={store.account} busy={accountBusy} transport={accountTransport()} onLogin={login} onLogout={logout} onClose={() => setShowAccount(false)} />}{toast && <Toast toast={toast} onClose={() => setToast(null)} />}</div>
}

function DesktopSidebar({ activePage, account, sync, onChange, onAccount }) {
  const groups = [...new Set(navItems.map((item) => item.group))]
  return <aside className="desktop-sidebar"><div className="brand-lockup"><img src="/sohun-logo.webp" alt="sohun" /><div><strong>sohun</strong><span>耗材工作台</span></div></div><button className="sidebar-account" onClick={onAccount}><div className="avatar">{account ? initials(account.displayName) : '访'}</div><div className="account-copy"><strong>{account ? account.displayName : '登录 sohun 账号'}</strong><span>{account ? '个人版 · 已连接' : '同步个人版数据'}</span></div><ChevronDown size={15} /></button><nav className="sidebar-nav" aria-label="主导航">{groups.map((group) => <div className="nav-group" key={group}><p>{group}</p>{navItems.filter((item) => item.group === group).map((item) => { const Icon = item.icon; const active = item.id === activePage; return <button className={`sidebar-item ${active ? 'active' : ''}`} key={item.id} onClick={() => onChange(item.id)}><Icon size={19} strokeWidth={active ? 2.25 : 1.8} /><span>{item.label}</span>{item.id === 'rfid' && <span className="nav-dot" />}</button> })}</div>)}</nav><div className="sidebar-footer"><button className="sidebar-help"><CircleHelp size={18} /><span>支持与帮助</span></button><div className="sidebar-sync"><span className={`sync-dot ${sync.state}`} /><span>{syncLabel(sync)}</span><span className="mono">{sync.lastSyncedAt.replace('今天 ', '')}</span></div></div></aside>
}

function TopBar({ page, readerOnline, account, sync, onReader, onAccount, onMenu, showMenu, onCloseMenu, onSync }) {
  const Icon = page.icon
  return <header className="topbar"><div className="topbar-title"><img className="mobile-topbar-logo" src="/sohun-logo.webp" alt="sohun" /><Icon size={21} /><h1>{page.label}</h1><span className="crumb">/ 个人工作区</span></div><div className="topbar-actions"><button className="icon-button topbar-only" aria-label="刷新同步" onClick={onSync}><RefreshCw size={17} className={sync.state === 'syncing' ? 'spin' : ''} /></button><button className="icon-button topbar-only" aria-label="搜索"><Search size={18} /></button><button className="icon-button topbar-only" aria-label="通知"><Bell size={18} /><i className="notification-dot" /></button><button className={`reader-status ${readerOnline ? 'online' : 'offline'}`} onClick={onReader}><span className="reader-led" /><span>{readerOnline ? '桥接在线' : '桥接离线'}</span></button><button className="account-trigger" onClick={onAccount} aria-label={account ? `打开 ${account.displayName} 账号` : '登录 sohun 账号'}><span className="avatar small">{account ? initials(account.displayName) : <UserRound size={14} />}</span><span className="account-trigger-name">{account ? account.displayName : '登录'}</span></button><button className="icon-button menu-trigger" aria-label="更多操作" onClick={onMenu}><MoreHorizontal size={19} /></button></div>{showMenu && <div className="topbar-menu" onMouseLeave={onCloseMenu}><button onClick={onSync}><RefreshCw size={15} />立即同步</button><button onClick={onAccount}><UsersRound size={15} />sohun 账号</button><button onClick={onReader}><ShieldCheck size={15} />检查 RFID 桥接</button><button onClick={onCloseMenu}><FileText size={15} />导出操作记录</button></div>}</header>
}

function RfidPage({ writeStage, writeForm, writeUid, history, readerOnline, formIsValid, onChange, onColor, onReview, onEdit, onStartWrite, onReset, onHistory, amsStage, amsResult, selectedTray, onReadAms, onAddAms, onAmsPage }) {
  const isReview = writeStage === 'review'
  const isWriting = writeStage === 'writing'
  const isVerify = writeStage === 'verify'
  const isSuccess = writeStage === 'success'
  const isError = writeStage === 'error'
  return <div className="rfid-page"><section className="page-heading"><div><div className="section-kicker"><Radio size={14} /> RFID 工作流</div><h2>写入耗材标签</h2><p>先填写品牌与耗材类型，再写入 RFID；完成后可交给 AMS 识别。</p></div><button className="outline-button desktop-history" onClick={onHistory}><History size={16} />操作记录</button></section><div className="rfid-layout"><section className="workflow-panel glass-panel"><div className="panel-heading"><div><h3>写入工作区</h3><span>{isSuccess ? '标签数据已写入并读回校验' : isError ? '桥接中断 · 可重试' : '01 · 录入耗材信息'}</span></div><div className={`status-chip ${isSuccess ? 'success' : isError ? 'error' : isWriting || isVerify ? 'busy' : isReview ? 'review' : 'neutral'}`}><span className="status-chip-dot" />{isSuccess ? '已完成' : isError ? '需重试' : isWriting ? '写入中' : isVerify ? '校验中' : isReview ? '待确认' : '准备就绪'}</div></div><div className="capability-note"><ShieldCheck size={14} /><span>官方 Bambu 标签为加密 MIFARE 并带签名。手机端通过 BambuRfidReader 外置桥接读写；普通手机 NFC 不代表 AMS 兼容。</span></div>{isSuccess ? <SuccessWritePanel writeForm={writeForm} writeUid={writeUid} onReset={onReset} onHistory={onHistory} /> : <><WriteForm form={writeForm} onChange={onChange} onColor={onColor} disabled={isReview || isWriting || isVerify} />{isError && <div className="write-error"><Info size={15} /><span>设备连接已断开，尚未登记本次写入。请重新连接桥接后再次确认，避免半写入标签进入库存。</span></div>}<WriteSteps stage={writeStage} /><div className="write-footer">{isReview ? <><div className="review-actions"><button className="outline-button" onClick={onEdit}>返回编辑</button><button className="primary-button" onClick={onStartWrite} disabled={!readerOnline}><Zap size={17} />确认写入</button></div><PayloadPreview form={writeForm} uid={writeUid} /></> : isError ? <button className="primary-button scan-button" onClick={onEdit} disabled={!readerOnline}><RefreshCw size={17} />{readerOnline ? '重新检查并重试' : '连接桥接后重试'}<ArrowRight size={17} /></button> : <button className="primary-button scan-button" onClick={onReview} disabled={!readerOnline || !formIsValid}><ShieldCheck size={17} />{readerOnline ? '检查信息并预览' : '连接桥接后继续'}<ArrowRight size={17} /></button>}</div></>}</section><aside className="rfid-side-column"><AmsReaderCard readerOnline={readerOnline} stage={amsStage} result={amsResult} selectedTray={selectedTray} onRead={onReadAms} onAdd={onAddAms} onOpen={onAmsPage} /><ReaderCard readerOnline={readerOnline} /><TagDetails writeStage={writeStage} writeForm={writeForm} writeUid={writeUid} /><RecentWrites history={history} onHistory={onHistory} /></aside></div></div>
}

function WriteForm({ form, onChange, onColor, disabled }) {
  return <div className="write-form"><div className="form-heading"><div><span className="section-kicker"><ClipboardList size={13} /> 写入字段</span><h4>耗材身份信息</h4></div><span className="required-note">* 必填</span></div><div className="form-grid"><label className="field"><span>品牌 <b>*</b></span><select value={form.brand} onChange={(event) => onChange('brand', event.target.value)} disabled={disabled}>{brandOptions.map((item) => <option key={item}>{item}</option>)}</select></label><label className="field"><span>耗材类型 <b>*</b></span><select value={form.materialType} onChange={(event) => onChange('materialType', event.target.value)} disabled={disabled}>{materialTypes.map((item) => <option key={item.value} value={item.value}>{item.label} · {item.description}</option>)}</select></label><label className="field"><span>型号 / 系列</span><input value={form.model} onChange={(event) => onChange('model', event.target.value)} placeholder="例如 PLA Matte" disabled={disabled} /></label><label className="field"><span>净重 (g) <b>*</b></span><input type="number" min="1" step="1" value={form.totalGrams} onChange={(event) => onChange('totalGrams', event.target.value)} disabled={disabled} /></label><label className="field"><span>批次号</span><input value={form.lot} onChange={(event) => onChange('lot', event.target.value)} placeholder="可选" disabled={disabled} /></label><label className="field"><span>备注</span><input value={form.note} onChange={(event) => onChange('note', event.target.value)} placeholder="可选" disabled={disabled} /></label></div><div className="color-field"><span>颜色 <b>*</b></span><div className="color-row">{colorPresets.map((color) => <button type="button" key={color.hex} className={`color-option ${color.hex === form.colorHex ? 'selected' : ''}`} onClick={() => onColor(color)} disabled={disabled} title={color.name}><span style={{ background: color.hex }} /></button>)}<label className="hex-input"><span className="hex-swatch" style={{ background: form.colorHex }} /><input value={form.colorHex} onChange={(event) => onChange('colorHex', event.target.value)} disabled={disabled} aria-label="颜色 HEX" /></label><strong>{form.colorName}</strong></div></div></div>
}

function WriteSteps({ stage }) {
  const index = stage === 'form' ? 0 : stage === 'review' ? 1 : stage === 'success' ? 3 : 2
  return <div className="workflow-steps"><Step number="01" label="录入字段" active={index === 0} complete={index > 0} /><div className="step-line" /><Step number="02" label="确认预览" active={index === 1} complete={index > 1} /><div className="step-line" /><Step number="03" label="写入校验" active={index >= 2} complete={stage === 'success'} /></div>
}

function Step({ number, label, active, complete }) {
  return <div className={`workflow-step ${active ? 'active' : ''} ${complete ? 'complete' : ''}`}><span className="step-number">{complete ? <Check size={13} /> : number}</span><span>{label}</span></div>
}

function PayloadPreview({ form, uid }) {
  const material = materialTypes.find((item) => item.value === form.materialType)
  return <section className="payload-preview"><div className="payload-heading"><div><span className="section-kicker"><Tag size={13} /> 写入预览</span><strong>AMS 识别字段</strong></div><span className="protocol-badge">Bambu MIFARE</span></div><div className="payload-grid"><PayloadRow label="品牌" value={form.brand} /><PayloadRow label="耗材类型" value={form.materialType} /><PayloadRow label="颜色" value={`${form.colorName} · ${form.colorHex}`} swatch={form.colorHex} /><PayloadRow label="净重" value={`${form.totalGrams} g`} /><PayloadRow label="喷嘴温度" value={material?.temp || '—'} /><PayloadRow label="标签 UID" value={uid || '写入时生成'} mono /></div><div className="payload-warning"><Info size={14} /><span>字段会写入本地编码并交给桥接设备执行；AMS 最终是否接受取决于标签类型、签名和设备固件。</span></div></section>
}

function PayloadRow({ label, value, swatch, mono }) {
  return <div className="payload-row"><span>{label}</span><strong className={mono ? 'mono' : ''}>{swatch && <i style={{ background: swatch }} />}{value}</strong></div>
}

function SuccessWritePanel({ writeForm, writeUid, onReset, onHistory }) {
  return <div className="success-write"><div className="success-hero"><div className="success-icon"><CheckCircle2 size={28} /></div><div><strong>写入完成</strong><span>{writeForm.brand} · {writeForm.materialType} · {writeForm.colorName}</span></div><BadgeCheck size={22} /></div><div className="verify-list"><div><CheckCircle2 size={15} /><span>标签 UID 已读回</span><strong className="mono">{writeUid}</strong></div><div><CheckCircle2 size={15} /><span>品牌与耗材类型字段一致</span><strong>已校验</strong></div><div><CheckCircle2 size={15} /><span>已加入手机耗材库</span><strong>待演示同步</strong></div></div><div className="success-actions"><button className="primary-button" onClick={onReset}><Plus size={17} />写入下一卷</button><button className="outline-button" onClick={onHistory}><History size={16} />查看记录</button></div></div>
}

function AmsReaderCard({ readerOnline, stage, result, selectedTray, onRead, onAdd, onOpen }) {
  const isReading = stage === 'reading'
  return <section className="ams-card glass-panel"><div className="panel-heading compact"><div><h3>从 AMS 读取</h3><span>识别后直接加入耗材库</span></div><button className="text-button" onClick={onOpen}>查看全部</button></div><div className="ams-device"><div className="ams-device-icon"><Wifi size={18} /></div><div><strong>AMS 01 · {selectedTray.id}</strong><span>{readerOnline ? '桥接设备可读取' : '等待桥接连接'}</span></div><span className={`ams-state ${isReading ? 'reading' : result ? 'ready' : ''}`}>{isReading ? '读取中' : result ? '已识别' : '待机'}</span></div>{result ? <div className="ams-result"><span className="ams-swatch" style={{ background: result.colorHex }} /><div><strong>{result.brand} · {result.materialType}</strong><span>{result.colorName} · 剩余 {formatWeight(result.remainingGrams)}</span></div><CheckCircle2 size={17} /></div> : <div className="ams-empty"><Radio size={18} /><span>把料卷放入 AMS，读取标签后会显示品牌和耗材类型。</span></div>}<div className="ams-actions"><button className="outline-button" onClick={() => onRead(selectedTray)} disabled={!readerOnline || isReading}><RefreshCw size={15} className={isReading ? 'spin' : ''} />{isReading ? '正在读取' : '读取当前槽位'}</button>{result && <button className="primary-button" onClick={onAdd}><PackageCheck size={15} />加入库存</button>}</div></section>
}

function ReaderCard({ readerOnline }) {
  return <section className="reader-card glass-panel"><div className="reader-card-icon"><Smartphone size={20} /></div><div className="reader-card-copy"><strong>BambuRfidReader 桥接</strong><span>{readerOnline ? 'Android NFC / USB · 演示连接' : '等待设备连接'}</span></div><span className={`reader-mini-status ${readerOnline ? 'online' : 'offline'}`}>{readerOnline ? '在线' : '离线'}</span><div className="reader-limit"><Info size={13} /><span>官方 Bambu 标签的加密读取与写入需要支持 MIFARE Classic 的外置设备。</span></div></section>
}

function TagDetails({ writeStage, writeForm, writeUid }) {
  const active = writeStage === 'review' || writeStage === 'writing' || writeStage === 'verify' || writeStage === 'success' || writeStage === 'error'
  return <section className="detail-panel glass-panel"><div className="panel-heading compact"><div><h3>标签详情</h3><span>{active ? '写入任务的标签上下文' : '写入前尚未分配标签'}</span></div><Info size={17} /></div><div className="detail-grid"><DetailRow label="标签 UID" value={active ? writeUid || '写入时生成' : '待生成'} mono muted={!active} /><DetailRow label="协议" value="Bambu MIFARE Classic" /><DetailRow label="数据来源" value="手机写入字段" /><DetailRow label="当前内容" value={active ? `${writeForm.brand} · ${writeForm.materialType}` : '—'} /></div><div className={`detail-footer ${writeStage === 'success' ? 'verified' : writeStage === 'error' ? 'error' : ''}`}><span className="footer-icon">{writeStage === 'success' ? <CheckCircle2 size={14} /> : writeStage === 'error' ? <Info size={14} /> : <Clock3 size={14} />}</span><span>{writeStage === 'success' ? '读回校验 · 刚刚' : writeStage === 'error' ? '桥接中断 · 未登记' : active ? '等待写入确认' : '尚未开始写入'}</span></div></section>
}

function DetailRow({ label, value, mono, muted }) {
  return <div className="detail-row"><span>{label}</span><strong className={`${mono ? 'mono' : ''} ${muted ? 'muted' : ''}`}>{value}</strong></div>
}

function RecentWrites({ history, onHistory }) {
  return <section className="recent-panel glass-panel"><div className="panel-heading compact"><div><h3>最近操作</h3><span>写入与 AMS 读取</span></div><button className="text-button" onClick={onHistory}>全部</button></div><div className="recent-list">{history.slice(0, 3).map((item) => <div className="recent-row" key={item.id}><span className={`recent-check ${item.status}`}><Check size={14} /></span><div><strong>{item.material}</strong><span>{item.time} · {item.source === 'ams' ? 'AMS' : item.source === 'desktop' ? '桌面版' : '手机'} · {item.uid ? item.uid.slice(-8) : '无 UID'}</span></div><ChevronDown className="row-arrow" size={15} /></div>)}</div></section>
}

function AmsPage({ readerOnline, amsStage, amsResult, selectedTray, onRead, onSelect, onAdd, onInventory }) {
  return <div className="subpage"><section className="page-heading"><div><div className="section-kicker"><Wifi size={14} /> 工作</div><h2>AMS 读取</h2><p>从 AMS 读取已识别耗材，确认后加入手机端本地库存。</p></div><button className="outline-button" onClick={onInventory}><Database size={16} />打开库存</button></section><div className="ams-page-grid"><section className="ams-tray-panel glass-panel"><div className="panel-heading"><div><h3>AMS 01 · 4 个槽位</h3><span>选择槽位后读取当前标签</span></div><span className={`status-chip ${readerOnline ? 'success' : 'neutral'}`}><span className="status-chip-dot" />{readerOnline ? '桥接在线' : '桥接离线'}</span></div><div className="tray-list">{amsTrays.map((tray) => <button className={`tray-row ${tray.id === selectedTray.id ? 'selected' : ''}`} key={tray.id} onClick={() => onSelect(tray)}><span className="tray-index">{tray.id}</span><span className="tray-swatch" style={{ background: tray.colorHex }} /><span className="tray-copy"><strong>{tray.name}</strong><small>{tray.uid ? `${tray.protocol} · ${formatWeight(tray.remainingGrams)}` : '没有可用的识别数据'}</small></span><span className="tray-time">{tray.updatedAt}</span><ChevronDown size={16} className="tray-chevron" /></button>)}</div><button className="primary-button full-button" onClick={() => onRead(selectedTray)} disabled={!readerOnline || amsStage === 'reading'}><RefreshCw size={16} className={amsStage === 'reading' ? 'spin' : ''} />{amsStage === 'reading' ? '正在读取 AMS…' : `读取槽位 ${selectedTray.id}`}</button></section><section className="ams-detail-panel glass-panel"><div className="panel-heading compact"><div><h3>识别结果</h3><span>来自 {selectedTray.id} 的读回数据</span></div><Radio size={17} /></div>{amsResult ? <><div className="ams-detail-hero"><span className="large-swatch" style={{ background: amsResult.colorHex }} /><div><span>{amsResult.brand}</span><strong>{amsResult.materialType} · {amsResult.colorName}</strong><small>剩余 {formatWeight(amsResult.remainingGrams)}</small></div></div><div className="detail-grid"><DetailRow label="标签 UID" value={amsResult.uid} mono /><DetailRow label="AMS 托盘" value={`${amsResult.trayUuid} · ${amsResult.id}`} /><DetailRow label="协议" value={amsResult.protocol} /><DetailRow label="最后读取" value={`今天 ${amsResult.updatedAt}`} /></div><button className="primary-button full-button" onClick={onAdd}><PackageCheck size={16} />加入耗材库</button></> : <div className="ams-detail-empty"><Radio size={28} /><strong>还没有读取结果</strong><span>选择一个槽位并读取，识别到的品牌和耗材类型会在这里出现。</span></div>}</section></div></div>
}

function HomePage({ store, onOpenRfid, onOpenAms, onSync }) {
  const totalRemaining = store.inventory.reduce((sum, item) => sum + Number(item.remainingGrams || 0), 0)
  const writeCount = store.history.filter((item) => item.action.includes('写入')).length
  return <div className="subpage"><section className="page-heading"><div><div className="section-kicker"><Home size={14} /> 工作台</div><h2>今天，从一卷耗材开始。</h2><p>手机端沿用桌面版的库存字段和操作记录；当前数据保存在本机。</p></div><button className="primary-button" onClick={onOpenRfid}><Radio size={17} />打开 RFID 写入</button></section><div className="metrics-grid"><Metric icon={PackageCheck} label="库存卷数" value={String(store.inventory.length)} suffix="卷" tone="green" /><Metric icon={Radio} label="RFID 写入" value={String(writeCount)} suffix="次" tone="blue" /><Metric icon={Activity} label="剩余耗材" value={(totalRemaining / 1000).toFixed(1)} suffix="kg" tone="orange" /><Metric icon={Wifi} label="同步状态" value={store.sync.pending ? String(store.sync.pending) : '✓'} suffix={store.sync.pending ? '待处理' : '本地已更新'} tone="green" /></div><div className="home-grid"><section className="home-hero-panel glass-panel"><div className="home-hero-copy"><span className="mini-label">RFID + AMS</span><h3>让每一卷耗材，<br /><em>都能被准确识别。</em></h3><p>先录入品牌和耗材类型，再通过外置桥接写入；也可以从 AMS 读取后直接入库。</p><div className="home-hero-actions"><button className="primary-button" onClick={onOpenRfid}>开始写入 <ArrowRight size={16} /></button><button className="outline-button" onClick={onOpenAms}><Wifi size={16} />读取 AMS</button></div></div><div className="home-wave"><div className="wave-ring" /><div className="wave-ring" /><div className="wave-ring" /><Radio size={34} /></div></section><section className="home-history glass-panel"><div className="panel-heading compact"><div><h3>最近活动</h3><span>{store.sync.pending ? `${store.sync.pending} 条待处理` : `上次演示同步 ${store.sync.lastSyncedAt}`}</span></div><button className="text-button" onClick={onSync}><RefreshCw size={14} />演示同步</button></div>{store.history.slice(0, 4).map((item) => <div className="activity-row" key={item.id}><span className={`activity-icon ${item.status}`}><CheckCircle2 size={16} /></span><div><strong>{item.action} · {item.material}</strong><span>{item.time} · {item.source === 'ams' ? 'AMS' : item.source === 'desktop' ? '桌面版' : '手机'} · {item.uid ? item.uid.slice(-8) : '无 UID'}</span></div></div>)}</section></div></div>
}

function Metric({ icon: Icon, label, value, suffix, tone }) {
  return <div className="metric-tile glass-panel"><div className={`metric-icon ${tone}`}><Icon size={19} /></div><div><span>{label}</span><strong className="mono">{value}<small>{suffix}</small></strong></div></div>
}

function InventoryPage({ inventory, query, onQuery, onSync, onOpenRfid }) {
  const filtered = useMemo(() => inventory.filter((item) => `${item.manufacturer} ${item.model} ${item.materialType} ${item.colorName} ${item.batchNo}`.toLowerCase().includes(query.toLowerCase())), [inventory, query])
  return <div className="subpage"><section className="page-heading"><div><div className="section-kicker"><Database size={14} /> 材料</div><h2>耗材库存</h2><p>手机、AMS 与桌面版使用相同的品牌、材质、UID 和余量字段。</p></div><div className="heading-actions"><button className="outline-button" onClick={onSync}><RefreshCw size={16} />同步</button><button className="primary-button" onClick={onOpenRfid}><Plus size={17} />写入新耗材</button></div></section><div className="inventory-toolbar"><div className="search-field"><Search size={17} /><input value={query} onChange={(event) => onQuery(event.target.value)} placeholder="搜索品牌、材质或批次" /></div><button className="filter-button"><SlidersHorizontal size={16} />筛选</button></div><div className="inventory-list">{filtered.length ? filtered.map((item) => <InventoryRow item={item} key={item.id} />) : <div className="empty-state glass-panel"><Database size={22} /><strong>没有匹配的耗材</strong><span>换一个品牌、材质或批次关键词。</span></div>}</div></div>
}

function InventoryRow({ item }) {
  const percent = Math.max(0, Math.min(100, Number(item.remainingGrams || 0) / Math.max(1, Number(item.totalGrams || 1000)) * 100))
  return <div className="inventory-row"><span className="inventory-swatch" style={{ background: item.colorHex }} /><span className="inventory-copy"><strong>{item.materialType} {item.colorName || '未命名'}</strong><small>{item.manufacturer} · {item.model} · {item.batchNo || '无批次'}</small><span className="inventory-progress"><i style={{ width: `${percent}%` }} /></span></span><span className="inventory-stock"><strong className="mono">{formatWeight(item.remainingGrams)}</strong><small>{item.source === 'ams' ? 'AMS 读取' : item.source === 'desktop' ? '桌面版' : '手机写入'}</small></span><span className="inventory-uid mono">{item.uid ? item.uid.slice(-8) : '未写入'}</span></div>
}

function HistoryPage({ history, onBack }) {
  return <div className="subpage"><section className="page-heading"><div><button className="back-button" onClick={onBack}><ArrowLeft size={16} />返回 RFID 写入</button><h2>操作记录</h2><p>写入、读回和入库事件会保留标签 UID 与同步来源。</p></div><button className="outline-button"><FileText size={16} />导出记录</button></section><section className="history-table glass-panel"><div className="history-table-head"><span>动作</span><span>耗材</span><span>标签 UID</span><span>来源</span><span>状态</span></div>{history.map((item) => <div className="history-table-row" key={item.id}><span className="history-action"><span className={`history-dot ${item.status}`} />{item.action}</span><strong>{item.material}</strong><span className="mono uid">{item.uid || '—'}</span><span>{item.source === 'ams' ? 'AMS' : item.source === 'desktop' ? '桌面版' : '手机'}</span><span className="history-success"><CheckCircle2 size={15} />{item.status === 'success' ? '已校验' : '已读取'}</span><small>{item.time}</small></div>)}</section></div>
}

function CostPage({ inventory }) {
  const total = inventory.reduce((sum, item) => sum + Number(item.remainingGrams || 0), 0)
  return <div className="subpage"><section className="page-heading"><div><div className="section-kicker"><Layers3 size={14} /> 材料</div><h2>耗材成本</h2><p>根据当前库存余量查看材料规模，详细单价可在桌面版维护。</p></div></section><section className="cost-panel glass-panel"><div className="cost-total"><span>当前库存重量</span><strong className="mono">{(total / 1000).toFixed(2)} kg</strong><small>共 {inventory.length} 卷 · 数据来自手机与 AMS</small></div><div className="cost-bars"><div className="cost-axis"><span>100%</span><span>50%</span><span>0</span></div><div className="bars">{inventory.slice(0, 7).map((item) => <div className="bar-column" key={item.id}><div className="bar" style={{ height: `${Math.max(12, Math.round(Number(item.remainingGrams || 0) / Math.max(1, Number(item.totalGrams || 1000)) * 100))}%`, background: item.colorHex }} /><span>{item.materialType}</span></div>)}</div></div></section></div>
}

function SettingsPage({ account, sync, readerOnline, onReader, onSync, onAccount, transport }) {
  return <div className="subpage"><section className="page-heading"><div><div className="section-kicker"><Settings size={14} /> 其他</div><h2>设置</h2><p>管理账号、RFID 桥接和手机端演示数据。</p></div></section><div className="settings-list glass-panel"><SettingRow icon={UsersRound} title="sohun 账号" detail={account ? `${account.email} · 个人版` : '未登录 · 登录后可验证账号'} action={<button className="outline-button compact-button" onClick={onAccount}>{account ? '账号' : '登录'}</button>} /><SettingRow icon={Radio} title="BambuRfidReader 桥接" detail={readerOnline ? '演示连接在线 · 支持读取与写入流程' : '当前未连接设备'} action={<button className={`toggle ${readerOnline ? 'on' : ''}`} onClick={onReader} aria-label="切换桥接"><span /></button>} /><SettingRow icon={RefreshCw} title="桌面版同步（演示）" detail={`${syncLabel(sync)} · 修订 ${sync.revision}`} action={<button className="outline-button compact-button" onClick={onSync} disabled={sync.state === 'syncing'}><RefreshCw size={14} className={sync.state === 'syncing' ? 'spin' : ''} />同步</button>} /><SettingRow icon={ShieldCheck} title="写入后自动读回校验" detail="写入 UID、品牌和耗材类型后才会登记为成功" action={<span className="setting-check"><Check size={14} /></span>} /><SettingRow icon={SlidersHorizontal} title="默认标签协议" detail="Bambu MIFARE Classic · 外置桥接" action={<ChevronDown size={18} />} /></div><div className="settings-footnote"><Info size={14} /><span>{transport} · 生产版登录会使用短期访问令牌与刷新令牌；本地耗材数据保存在浏览器的版本化存储中。</span></div></div>
}

function SettingRow({ icon: Icon, title, detail, action }) {
  return <div className="setting-row"><div className="setting-icon"><Icon size={18} /></div><div className="setting-copy"><strong>{title}</strong><span>{detail}</span></div><div className="setting-action">{action}</div></div>
}

function MobileNav({ activePage, onChange, onMore }) {
  const items = [{ id: 'home', label: '工作台', icon: Home }, { id: 'rfid', label: 'RFID', icon: Radio }, { id: 'inventory', label: '库存', icon: Database }, { id: 'ams', label: 'AMS', icon: Wifi }]
  return <nav className="mobile-nav" aria-label="移动端导航">{items.map((item) => { const Icon = item.icon; return <button className={activePage === item.id ? 'active' : ''} key={item.id} onClick={() => onChange(item.id)}><Icon size={20} strokeWidth={activePage === item.id ? 2.25 : 1.8} /><span>{item.label}</span>{item.id === 'rfid' && <i className="mobile-nav-dot" />}</button> })}<button className={['history', 'cost', 'settings'].includes(activePage) ? 'active' : ''} onClick={onMore}><MoreHorizontal size={20} /><span>更多</span></button></nav>
}

function MoreDrawer({ activePage, onChange, onClose }) {
  return <div className="drawer-backdrop" onMouseDown={onClose}><aside className="more-drawer" onMouseDown={(event) => event.stopPropagation()}><div className="drawer-heading"><div><span className="section-kicker"><Menu size={14} /> 个人工作区</span><h3>更多</h3></div><button className="close-button" onClick={onClose} aria-label="关闭"><X size={18} /></button></div>{['洞察', '其他'].map((group) => <div className="drawer-group" key={group}><p>{group}</p>{navItems.filter((item) => item.group === group).map((item) => { const Icon = item.icon; return <button className={activePage === item.id ? 'active' : ''} key={item.id} onClick={() => onChange(item.id)}><Icon size={18} /><span>{item.label}</span><ArrowRight size={15} /></button> })}</div>)}<div className="drawer-note"><ShieldCheck size={15} /><span>导航与桌面个人版保持同构，低频功能收纳在这里。</span></div></aside></div>
}

function AccountModal({ account, busy, transport, onLogin, onLogout, onClose }) {
  const [email, setEmail] = useState(account?.email || '')
  const [password, setPassword] = useState('')
  const isDemo = account ? account.transport !== 'sohun-api' : transport === '本地演示适配器'
  const submit = (event) => {
    event.preventDefault()
    if (!email.trim() || password.length < 4) return
    onLogin({ email, password })
  }

  return (
    <div className="modal-backdrop" onMouseDown={onClose}>
      <section className="account-modal" onMouseDown={(event) => event.stopPropagation()}>
        <div className="modal-heading">
          <div>
            <span className="section-kicker"><UsersRound size={14} /> sohun 账号</span>
            <h3>{account ? '账号已连接' : '登录个人版账号'}</h3>
          </div>
          <button className="close-button" onClick={onClose} aria-label="关闭"><X size={18} /></button>
        </div>
        {account ? (
          <>
            <div className="account-profile">
              <div className="avatar large">{initials(account.displayName)}</div>
              <div>
                <strong>{account.displayName}</strong>
                <span>{account.email}</span>
                <small>{isDemo ? '个人版账号 · 本地演示数据' : '个人版账号 · API 已连接'}</small>
              </div>
            </div>
            <div className="account-sync-box">
              <CheckCircle2 size={17} />
              <div>
                <strong>{isDemo ? '本地演示已就绪' : '账号已验证'}</strong>
                <span>{isDemo ? '新增 RFID 记录会进入本机演示队列，不会上传到服务器。' : '账号已通过 sohun API 验证；个人库存同步接口接入后可跨设备共享。'}</span>
              </div>
            </div>
            <div className="modal-actions">
              <button className="outline-button" onClick={onClose}>关闭</button>
              <button className="danger-button" onClick={onLogout}>退出账号</button>
            </div>
          </>
        ) : (
          <form onSubmit={submit}>
            <p className="modal-help">使用现有 sohun 账号登录可验证账号边界；浏览器演示的库存和操作记录仍保存在本机。</p>
            <label className="field">
              <span>邮箱</span>
              <input type="email" value={email} onChange={(event) => setEmail(event.target.value)} placeholder="name@example.com" autoFocus autoComplete="username" />
            </label>
            <label className="field">
              <span>密码</span>
              <input type="password" value={password} onChange={(event) => setPassword(event.target.value)} placeholder="至少 4 位（演示）" autoComplete="current-password" />
            </label>
            <div className="login-contract"><ShieldCheck size={14} /><span>{transport} · 生产接入调用 `/v1/auth/login`；浏览器演示不会把密码写入本地存储。</span></div>
            <div className="modal-actions">
              <button type="button" className="outline-button" onClick={onClose}>取消</button>
              <button type="submit" className="primary-button" disabled={busy || !email.trim() || password.length < 4}>{busy ? <><RefreshCw size={14} className="spin" />登录中…</> : '登录并继续'}</button>
            </div>
          </form>
        )}
      </section>
    </div>
  )
}

function Toast({ toast, onClose }) {
  return <div className={`toast ${toast.tone}`} role="status"><span>{toast.tone === 'warning' ? <Info size={16} /> : <CheckCircle2 size={16} />}</span><strong>{toast.message}</strong><button onClick={onClose} aria-label="关闭提示"><X size={15} /></button></div>
}

function initials(value) {
  return String(value || '访').trim().slice(0, 2).toUpperCase()
}

function syncLabel(sync) {
  if (sync.state === 'syncing') return '同步中'
  if (sync.state === 'pending') return `${sync.pending || 0} 条待处理`
  if (sync.state === 'error') return '同步失败'
  if (sync.state === 'synced') return '演示数据已更新'
  return '本地数据'
}

export default App

createRoot(document.getElementById('root')).render(<App />)
