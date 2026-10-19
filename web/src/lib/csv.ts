// Export CSV généré dans le navigateur (séparateur « ; » et BOM UTF-8 : s'ouvre correctement dans Excel en français).
export function telechargerCsv(nom: string, entetes: string[], lignes: (string | number | null | undefined)[][]): void {
  const esc = (v: string | number | null | undefined) => {
    const s = v === null || v === undefined ? '' : String(v)
    return /[";\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
  }
  const contenu = '﻿' + [entetes, ...lignes].map((l) => l.map(esc).join(';')).join('\r\n')
  const blob = new Blob([contenu], { type: 'text/csv;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = nom.endsWith('.csv') ? nom : `${nom}.csv`
  document.body.appendChild(a)
  a.click()
  a.remove()
  URL.revokeObjectURL(url)
}
