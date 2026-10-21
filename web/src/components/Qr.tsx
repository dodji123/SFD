import { useEffect, useRef, useState } from 'react'
import QRCode from 'qrcode'
import { Button, FormModal, Field, Input } from './ui'

/** Contenu des QR codes générés par le système : `SFD|CY|<numéro de cycle>` ou `SFD|CL|<numéro de client>`. */
export const contenuQr = (nature: 'CY' | 'CL', numero: string) => `SFD|${nature}|${numero}`

/** Décode le texte d'un QR du système ; un texte libre (numéro saisi à la main) est renvoyé tel quel. */
export function lireQr(texte: string): { nature: 'CY' | 'CL' | null; numero: string } {
  const m = /^SFD\|(CY|CL)\|(.+)$/.exec(texte.trim())
  return m ? { nature: m[1] as 'CY' | 'CL', numero: m[2] } : { nature: null, numero: texte.trim() }
}

/** QR code généré localement (aucune donnée n'est envoyée à un service externe). */
export function QrCode({ valeur, taille = 160, legende }: { valeur: string; taille?: number; legende?: string }) {
  const [src, setSrc] = useState<string | null>(null)
  useEffect(() => {
    let ok = true
    QRCode.toDataURL(valeur, { width: taille * 2, margin: 1, errorCorrectionLevel: 'M' }).then((u) => ok && setSrc(u)).catch(() => ok && setSrc(null))
    return () => { ok = false }
  }, [valeur, taille])
  return (
    <figure className="qr-fiche" style={{ margin: 0, textAlign: 'center' }}>
      {src ? <img src={src} width={taille} height={taille} alt={`QR code ${legende ?? valeur}`} /> : <div style={{ width: taille, height: taille }} />}
      {legende && <figcaption style={{ fontSize: '0.8rem' }}>{legende}</figcaption>}
    </figure>
  )
}

interface DetecteurCode { detect: (s: HTMLVideoElement) => Promise<{ rawValue: string }[]> }
type FabriqueDetecteur = new (o: { formats: string[] }) => DetecteurCode

/** Bouton « Scanner » : lit un QR avec la caméra (navigateurs compatibles, en HTTPS ou localhost) ou accepte une saisie manuelle. */
export function BoutonScanner({ onLu, libelle = 'Scanner un QR' }: { onLu: (texte: string) => void; libelle?: string }) {
  const [ouvert, setOuvert] = useState(false)
  return (
    <>
      <Button type="button" onClick={() => setOuvert(true)}>{libelle}</Button>
      {ouvert && <Scanner onClose={() => setOuvert(false)} onLu={(t) => { setOuvert(false); onLu(t) }} />}
    </>
  )
}

function Scanner({ onClose, onLu }: { onClose: () => void; onLu: (texte: string) => void }) {
  const video = useRef<HTMLVideoElement>(null)
  const rappel = useRef(onLu)
  rappel.current = onLu
  const [message, setMessage] = useState<string | null>(null)
  const [saisie, setSaisie] = useState('')

  useEffect(() => {
    const Detecteur = (window as unknown as { BarcodeDetector?: FabriqueDetecteur }).BarcodeDetector
    if (!Detecteur || !navigator.mediaDevices?.getUserMedia) {
      setMessage('Lecture par caméra indisponible sur ce navigateur ou hors HTTPS : saisissez le code ci-dessous.')
      return
    }
    let actif = true
    let flux: MediaStream | null = null
    const detecteur = new Detecteur({ formats: ['qr_code'] })
    navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } }).then((s) => {
      if (!actif) { s.getTracks().forEach((t) => t.stop()); return }
      flux = s
      if (video.current) { video.current.srcObject = s; void video.current.play() }
      const boucle = async () => {
        if (!actif) return
        try {
          const trouves = video.current ? await detecteur.detect(video.current) : []
          if (trouves.length > 0) { rappel.current(trouves[0].rawValue); return }
        } catch { /* image pas encore prête : on réessaie */ }
        setTimeout(() => void boucle(), 250)
      }
      void boucle()
    }).catch(() => setMessage('Caméra refusée ou absente : saisissez le code ci-dessous.'))
    return () => { actif = false; flux?.getTracks().forEach((t) => t.stop()) }
  }, [])

  return (
    <FormModal titre="Scanner un QR code" onClose={onClose} valider="Valider la saisie" onSubmit={() => { if (saisie.trim()) onLu(saisie) }}>
      {!message && <video ref={video} muted playsInline style={{ width: '100%', borderRadius: 8, background: '#000' }} />}
      {message && <p className="muted" style={{ margin: 0 }}>{message}</p>}
      <Field label="Ou saisir le code / le numéro"><Input value={saisie} onChange={(e) => setSaisie(e.target.value)} placeholder="SFD|CY|CY-LOM-2026-000015 ou numéro" /></Field>
    </FormModal>
  )
}
