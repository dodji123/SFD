-- =====================================================================
-- 30_institution_entete.sql
-- En-tête des pièces et documents : l'institution (une seule fiche) et les coordonnées de chaque agence.
--   institution : raison sociale, sigle, agrément, numéro d'immatriculation, adresse, contacts, logo (image en base64) et pied de page.
--   agence      : adresse, ville, téléphone et courriel de l'agence émettrice.
-- Modifiables par l'administrateur ; l'en-tête des pièces justificatives reprend ces données à l'impression.
-- Dépend de : 00, 10 (audit).
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE institution (
  id               smallint PRIMARY KEY CHECK (id = 1),          -- une seule fiche
  raison_sociale   text NOT NULL,
  sigle            varchar(20),
  agrement         text,                                          -- ex. décision d'agrément de la BCEAO / du ministère
  immatriculation  text,                                          -- RCCM, numéro d'identification
  adresse          text,
  ville            text,
  telephone        varchar(40),
  email            text,
  site_web         text,
  logo             text CHECK (logo IS NULL OR (logo LIKE 'data:image/%;base64,%' AND length(logo) <= 400000)),
  pied_de_page     text,
  modifie_le       timestamptz NOT NULL DEFAULT now()
);
INSERT INTO institution(id, raison_sociale) VALUES (1, 'Institution de microfinance');
CREATE TRIGGER audit_institution AFTER INSERT OR UPDATE OR DELETE ON institution FOR EACH ROW EXECUTE FUNCTION trg_audit();

ALTER TABLE agence ADD COLUMN adresse text;
ALTER TABLE agence ADD COLUMN ville text;
ALTER TABLE agence ADD COLUMN telephone varchar(40);
ALTER TABLE agence ADD COLUMN email text;
