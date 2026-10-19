import {
  createContext, useCallback, useContext, useEffect, useId, useRef, useState,
  type ButtonHTMLAttributes, type InputHTMLAttributes, type ReactNode, type Ref, type SelectHTMLAttributes,
} from 'react'
import { ApiError } from '../lib/api'
import { libellesStatut, tonStatut, xof } from '../lib/format'

/* ---------------------------------------------------------------- chargement de données */
export function useFetch<T>(fn: () => Promise<T>, deps: unknown[]) {
  const [data, setData] = useState<T | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [n, setN] = useState(0)
  const seq = useRef(0)
  useEffect(() => {
    const id = ++seq.current
    setLoading(true)
    fn()
      .then((d) => {
        if (id === seq.current) {
          setData(d)
          setError(null)
        }
      })
      .catch((e: unknown) => {
        if (id === seq.current) setError(e instanceof ApiError ? e.message : 'Erreur inattendue')
      })
      .finally(() => {
        if (id === seq.current) setLoading(false)
      })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, n])
  const reload = useCallback(() => setN((x) => x + 1), [])
  return { data, error, loading, reload }
}

/* ---------------------------------------------------------------- notifications */
interface ToastApi { ok: (m: string) => void; err: (m: string) => void }
const ToastCtx = createContext<ToastApi>({ ok: () => {}, err: () => {} })
export const useToast = () => useContext(ToastCtx)

export function ToastProvider({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<{ id: number; type: 'ok' | 'bad'; msg: string }[]>([])
  const push = useCallback((type: 'ok' | 'bad', msg: string) => {
    const id = Date.now() + Math.random()
    setItems((x) => [...x, { id, type, msg }])
    setTimeout(() => setItems((x) => x.filter((i) => i.id !== id)), type === 'bad' ? 8000 : 4000)
  }, [])
  const api: ToastApi = { ok: (m) => push('ok', m), err: (m) => push('bad', m) }
  return (
    <ToastCtx.Provider value={api}>
      {children}
      <div className="toasts" role="status" aria-live="polite">
        {items.map((i) => (
          <div key={i.id} className={`toast ${i.type}`}>{i.msg}</div>
        ))}
      </div>
    </ToastCtx.Provider>
  )
}

/** Exécute une action API : message de succès, erreur affichée, rechargement. Retourne true si réussie. */
export function useAction() {
  const toast = useToast()
  const [busy, setBusy] = useState(false)
  const run = useCallback(
    async (fn: () => Promise<unknown>, succes?: string, apres?: () => void): Promise<boolean> => {
      setBusy(true)
      try {
        await fn()
        if (succes) toast.ok(succes)
        apres?.()
        return true
      } catch (e) {
        toast.err(e instanceof ApiError ? e.message : 'Erreur inattendue')
        return false
      } finally {
        setBusy(false)
      }
    },
    [toast],
  )
  return { run, busy }
}

/* ---------------------------------------------------------------- éléments de page */
export function Page({ title, subtitle, actions, children }: { title: string; subtitle?: string; actions?: ReactNode; children: ReactNode }) {
  return (
    <div className="stack">
      <div className="page-h">
        <div>
          <h1>{title}</h1>
          {subtitle && <p>{subtitle}</p>}
        </div>
        {actions && <div className="actions">{actions}</div>}
      </div>
      {children}
    </div>
  )
}

export function Card({ title, actions, children, flush }: { title?: ReactNode; actions?: ReactNode; children: ReactNode; flush?: boolean }) {
  return (
    <section className="card">
      {(title || actions) && (
        <div className="card-h">
          <h2>{title}</h2>
          {actions && <div className="actions">{actions}</div>}
        </div>
      )}
      <div className={flush ? '' : 'card-b'}>{children}</div>
    </section>
  )
}

export function Kpi({ label, value, tone }: { label: string; value: ReactNode; tone?: 'warn' | 'bad' }) {
  return (
    <div className={`card kpi ${tone ?? ''}`}>
      <div className="v">{value}</div>
      <div className="l">{label}</div>
    </div>
  )
}

export function Badge({ children, tone = 'neutre' }: { children: ReactNode; tone?: 'ok' | 'warn' | 'bad' | 'info' | 'neutre' }) {
  return <span className={`badge ${tone}`}>{children}</span>
}

export function Statut({ s }: { s: string }) {
  return <Badge tone={tonStatut[s] ?? 'neutre'}>{libellesStatut[s] ?? s}</Badge>
}

export const Money = ({ v }: { v: number | null | undefined }) => <span className="num">{xof(v)}</span>

export function Alert({ tone = 'bad', children }: { tone?: 'bad' | 'warn' | 'info'; children: ReactNode }) {
  return <div className={`alert ${tone}`} role={tone === 'bad' ? 'alert' : 'status'}>{children}</div>
}

export function Spinner() {
  return <div className="spinner" role="status" aria-label="Chargement" />
}

/** Affiche le chargement ou l'erreur d'un useFetch, sinon le contenu. */
export function Charge<T>({ q, children }: { q: { data: T | null; error: string | null; loading: boolean }; children: (d: T) => ReactNode }) {
  if (q.error) return <Alert>{q.error}</Alert>
  if (q.data === null) return q.loading ? <Spinner /> : null
  return <>{children(q.data)}</>
}

/* ---------------------------------------------------------------- tableau */
export interface Col<T> {
  titre: string
  render: (r: T, i: number) => ReactNode
  num?: boolean
}

export function Table<T>({ cols, rows, onRowClick, vide = 'Aucun élément' }: { cols: Col<T>[]; rows: T[]; onRowClick?: (r: T) => void; vide?: string }) {
  if (rows.length === 0) return <div className="empty">{vide}</div>
  return (
    <div className="table-wrap">
      <table className="t">
        <thead>
          <tr>{cols.map((c) => <th key={c.titre} className={c.num ? 'num' : ''}>{c.titre}</th>)}</tr>
        </thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={i} className={onRowClick ? 'click' : ''} onClick={onRowClick ? () => onRowClick(r) : undefined}
                onKeyDown={onRowClick ? (e) => { if (e.key === 'Enter') onRowClick(r) } : undefined} tabIndex={onRowClick ? 0 : undefined}>
              {cols.map((c) => <td key={c.titre} className={c.num ? 'num' : ''}>{c.render(r, i)}</td>)}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

/* ---------------------------------------------------------------- formulaires */
export function Field({ label, hint, children }: { label: string; hint?: string; children: ReactNode }) {
  const id = useId()
  return (
    <div className="field">
      <label htmlFor={id}>{label}</label>
      {/* le premier enfant reçoit l'id pour lier l'étiquette */}
      {injecterId(children, id)}
      {hint && <span className="hint">{hint}</span>}
    </div>
  )
}

function injecterId(children: ReactNode, id: string): ReactNode {
  if (children && typeof children === 'object' && 'props' in (children as object)) {
    const el = children as React.ReactElement<{ id?: string }>
    return { ...el, props: { ...el.props, id: el.props.id ?? id } } as React.ReactElement
  }
  return children
}

export const Input = (p: InputHTMLAttributes<HTMLInputElement> & { ref?: Ref<HTMLInputElement> }) => <input className="input" {...p} />
export const Select = (p: SelectHTMLAttributes<HTMLSelectElement>) => <select className="input" {...p} />

export function Button({ variant, small, className, ...p }: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: 'primary' | 'danger'; small?: boolean }) {
  const cls = ['btn', variant ? `btn-${variant}` : '', small ? 'btn-sm' : '', className ?? ''].join(' ').trim()
  return <button type="button" className={cls} {...p} />
}

/* ---------------------------------------------------------------- modale */
export function Modal({ titre, onClose, children, footer, large }: { titre: string; onClose: () => void; children: ReactNode; footer?: ReactNode; large?: boolean }) {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const prev = document.activeElement as HTMLElement | null
    ref.current?.focus()
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }
    document.addEventListener('keydown', onKey)
    return () => { document.removeEventListener('keydown', onKey); prev?.focus() }
  }, [onClose])
  return (
    <div className="overlay" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose() }}>
      <div className={`modal ${large ? 'wide' : ''}`} role="dialog" aria-modal="true" aria-label={titre} ref={ref} tabIndex={-1}>
        <div className="modal-h">
          <h2>{titre}</h2>
          <Button small onClick={onClose} aria-label="Fermer">✕</Button>
        </div>
        <div className="modal-b">{children}</div>
        {footer && <div className="modal-f">{footer}</div>}
      </div>
    </div>
  )
}

/** Fenêtre de formulaire : valide avec Entrée, désactive pendant l'envoi. */
export function FormModal({ titre, onClose, onSubmit, children, valider = 'Enregistrer', busy, large }: {
  titre: string; onClose: () => void; onSubmit: () => void; children: ReactNode; valider?: string; busy?: boolean; large?: boolean
}) {
  return (
    <Modal titre={titre} onClose={onClose} large={large}
      footer={<><Button onClick={onClose}>Annuler</Button><Button variant="primary" disabled={busy} onClick={onSubmit}>{busy ? 'En cours…' : valider}</Button></>}>
      <form onSubmit={(e) => { e.preventDefault(); onSubmit() }}>
        <div className="form-grid">{children}</div>
        <button type="submit" className="sr-only" tabIndex={-1}>Valider</button>
      </form>
    </Modal>
  )
}

/* ---------------------------------------------------------------- onglets */
export function Tabs({ tabs, actif, onChange }: { tabs: { id: string; titre: string }[]; actif: string; onChange: (id: string) => void }) {
  return (
    <div className="tabs" role="tablist">
      {tabs.map((t) => (
        <button key={t.id} type="button" role="tab" className="tab" aria-selected={actif === t.id} onClick={() => onChange(t.id)}>{t.titre}</button>
      ))}
    </div>
  )
}
