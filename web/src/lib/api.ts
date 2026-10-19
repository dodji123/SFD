// Client HTTP de l'API. Le jeton est gardé en sessionStorage (effacé à la fermeture de l'onglet).
// Pour un utilisateur du siège, l'agence choisie est ajoutée automatiquement aux requêtes.

export class ApiError extends Error {
  status: number
  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
}

type Params = Record<string, string | number | boolean | null | undefined>

const TOKEN_KEY = 'sfd_token'
const AGENCE_KEY = 'sfd_agence'

let token: string | null = safeGet(TOKEN_KEY)
let agence: number | null = Number(safeGet(AGENCE_KEY)) || null
let onUnauthorized: () => void = () => {}

function safeGet(k: string): string | null {
  try {
    return sessionStorage.getItem(k)
  } catch {
    return null
  }
}
function safeSet(k: string, v: string | null) {
  try {
    if (v === null) sessionStorage.removeItem(k)
    else sessionStorage.setItem(k, v)
  } catch {
    /* stockage indisponible : la session ne survivra pas au rechargement */
  }
}

export const session = {
  getToken: () => token,
  setToken(t: string | null) {
    token = t
    safeSet(TOKEN_KEY, t)
  },
  getAgence: () => agence,
  setAgence(id: number | null) {
    agence = id
    safeSet(AGENCE_KEY, id === null ? null : String(id))
  },
  onUnauthorized(fn: () => void) {
    onUnauthorized = fn
  },
}

function messageErreur(detail: unknown, status: number): string {
  if (typeof detail === 'string') return detail
  if (Array.isArray(detail)) {
    return detail
      .map((d) => {
        const champ = Array.isArray(d?.loc) ? d.loc.filter((x: unknown) => x !== 'body').join('.') : ''
        return champ ? `${champ} : ${d.msg}` : String(d?.msg ?? d)
      })
      .join(' ; ')
  }
  return status >= 500 ? 'Erreur interne du serveur' : `Erreur ${status}`
}

async function request<T>(method: string, path: string, opts: { params?: Params; body?: unknown } = {}): Promise<T> {
  const url = new URL(path, window.location.origin)
  const params: Params = { ...opts.params }
  if (agence && method === 'GET' && params.agence_id === undefined) params.agence_id = agence
  for (const [k, v] of Object.entries(params)) {
    if (v !== undefined && v !== null && v !== '') url.searchParams.set(k, String(v))
  }
  let body = opts.body
  if (agence && body && typeof body === 'object' && !Array.isArray(body) && !('agence_id' in (body as object))) {
    body = { ...(body as object), agence_id: agence }
  }
  const headers: Record<string, string> = {}
  if (body !== undefined) headers['Content-Type'] = 'application/json'
  if (token) headers.Authorization = `Bearer ${token}`
  let res: Response
  try {
    res = await fetch(url, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) })
  } catch {
    throw new ApiError(0, 'Serveur injoignable. Vérifiez la connexion.')
  }
  if (res.status === 204) return undefined as T
  let data: unknown = null
  try {
    data = await res.json()
  } catch {
    /* corps vide ou non JSON */
  }
  if (!res.ok) {
    if (res.status === 401 && token) onUnauthorized()
    throw new ApiError(res.status, messageErreur((data as { detail?: unknown } | null)?.detail, res.status))
  }
  return data as T
}

export const api = {
  get: <T = any>(path: string, params?: Params) => request<T>('GET', path, { params }),
  post: <T = any>(path: string, body?: unknown) => request<T>('POST', path, { body: body ?? {} }),
  put: <T = any>(path: string, body?: unknown) => request<T>('PUT', path, { body }),
  patch: <T = any>(path: string, body?: unknown) => request<T>('PATCH', path, { body }),
  del: <T = any>(path: string) => request<T>('DELETE', path),
}
