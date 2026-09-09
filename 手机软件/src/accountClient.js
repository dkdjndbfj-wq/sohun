const apiBaseUrl = String(import.meta.env.VITE_SOHUN_API_BASE_URL || '').trim().replace(/\/$/, '')

function previewUser(email) {
  const displayName = email.split('@')[0] || 'sohun 用户'
  return {
    id: `preview-${encodeURIComponent(email).slice(0, 20)}`,
    email,
    displayName,
    handle: displayName.toLowerCase(),
    emailVerified: false,
    mode: 'local-demo',
  }
}

/**
 * Account boundary shared by the web preview and the future native shell.
 * Set VITE_SOHUN_API_BASE_URL to use the existing sohun `/v1/auth/login`
 * contract. Tokens stay in memory here; Android/iOS builds should move the
 * returned session into Keystore/Keychain instead of localStorage.
 */
export async function signIn({ email, password }) {
  if (!apiBaseUrl) {
    await new Promise((resolve) => window.setTimeout(resolve, 280))
    return { user: previewUser(email), session: null, transport: 'local-demo' }
  }

  const response = await fetch(`${apiBaseUrl}/v1/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  })
  let payload = null
  try {
    payload = await response.json()
  } catch {
    payload = null
  }
  if (!response.ok) {
    throw new Error(payload?.error?.message || payload?.message || 'sohun 登录失败，请检查邮箱和密码')
  }
  const user = payload?.user
  if (!user?.email) throw new Error('sohun 登录响应缺少账号信息')
  return {
    user: {
      id: user.id,
      email: user.email,
      displayName: user.displayName || user.display_name || user.email.split('@')[0],
      handle: user.handle || '',
      emailVerified: user.emailVerified ?? user.email_verified ?? false,
      mode: 'sohun-api',
    },
    session: {
      accessToken: payload.accessToken || payload.access_token || '',
      refreshToken: payload.refreshToken || payload.refresh_token || '',
      expiresAt: payload.expiresAt || payload.expires_at || null,
      serverBaseUrl: apiBaseUrl,
    },
    transport: 'sohun-api',
  }
}

export function accountTransport() {
  return apiBaseUrl ? `sohun API · ${apiBaseUrl}` : '本地演示适配器'
}

