-- ============================================================
-- Schéma Supabase — Portail citoyen d'Étalie — v2
-- Remplace entièrement schema-portail-citoyen.sql (v1)
-- À exécuter dans Database > SQL Editor, en une fois
-- ============================================================

-- ------------------------------------------------------------
-- 0) NETTOYAGE (si la v1 a déjà été exécutée)
-- ------------------------------------------------------------
drop trigger if exists proteger_champs_citoyens on citoyens;
drop table if exists signalements cascade;
drop table if exists messages cascade;
drop table if exists citoyens cascade;
drop table if exists cas_valides cascade;
drop function if exists empecher_modif_champs_proteges() cascade;
drop function if exists age_toutouien(date) cascade;
drop function if exists code_social_est_valide(text) cascade;
drop function if exists inscrire_citoyen(text,text,text,text,date) cascade;

-- ============================================================
-- 1) LE COFFRE DES CAS (chargé depuis num_CAS.txt via parse_cas.py)
-- ============================================================
create table cas_valides (
  id                          uuid primary key default gen_random_uuid(),
  code_encrypte               text unique not null,   -- ex: "B-N-E/Z-B-Q/H-V-Z"
  nom_legal                   text not null,           -- MAJUSCULES, insensible à la casse à la vérification
  prenom_legal                text not null,
  chiffre_identification      int  not null default 0, -- désambiguïsation des homonymes
  date_expiration             date not null,
  protection_gouvernementale  boolean not null default false, -- O = exempté d'expiration
  est_admin                   boolean not null default false, -- ce CAS donne le rôle admin
  utilise                     boolean not null default false,
  citoyen_id                  uuid references auth.users(id) on delete set null,
  cree_le                     timestamptz not null default now(),
  utilise_le                  timestamptz
);
alter table cas_valides enable row level security;
-- Aucune policy = invisible depuis le client. Seules les fonctions security definer y touchent.

-- ============================================================
-- 2) TABLE DES CITOYENS
-- ============================================================
create table citoyens (
  id                          uuid primary key references auth.users(id) on delete cascade,
  username                    text unique not null check (char_length(username) between 3 and 24),
  email                       text unique not null,
  prenom                      text not null,
  nom                         text not null,
  code_social_encrypte        text not null references cas_valides(code_encrypte),
  date_naissance              date not null,
  age_toutouien_inscription   numeric not null,
  est_admin                   boolean not null default false,
  tresorerie                  numeric not null default 0,
  dettes                      numeric not null default 0,
  prets                       numeric not null default 0,
  argent_attendu              numeric not null default 0,
  derniere_synchro_tresorerie timestamptz not null default now(),
  reste_connecte              boolean not null default false,
  cree_le                     timestamptz not null default now()
);
alter table citoyens enable row level security;

create policy "Lecture de son propre profil"
  on citoyens for select
  using (auth.uid() = id);

create policy "Admin lit tous les profils"
  on citoyens for select
  using (exists (select 1 from citoyens a where a.id = auth.uid() and a.est_admin));

-- Toute écriture (insert/update) passe par des fonctions security definer ci-dessous.
-- Pas de policy insert/update directe : empêche un citoyen de se donner de l'argent,
-- de devenir admin, ou de changer son CAS/date de naissance lui-même.

-- ------------------------------------------------------------
-- Fonction utilitaire : suis-je admin ?
-- ------------------------------------------------------------
create or replace function est_admin_actuel()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select est_admin from citoyens where id = auth.uid()), false);
$$;

-- ============================================================
-- 3) ÂGE TOUTOUÏEN (formule officielle confirmée — option 1)
-- ============================================================
create or replace function age_toutouien(p_date_naissance date)
returns numeric language sql immutable as $$
  select (extract(epoch from (now() - p_date_naissance::timestamptz)) / 86400.0 / 365.25) * 12.1666667;
$$;

-- ============================================================
-- 4) RÉSOLUTION USERNAME -> EMAIL (pour permettre la connexion par username)
-- ============================================================
create or replace function email_pour_identifiant(p_identifiant text)
returns text language sql stable security definer set search_path = public as $$
  select email from citoyens
  where lower(username) = lower(p_identifiant) or lower(email) = lower(p_identifiant)
  limit 1;
$$;
grant execute on function email_pour_identifiant(text) to anon;

-- ============================================================
-- 5) STATUT DE MON PROPRE CAS (expiration, protection, identité)
-- ============================================================
create or replace function mon_statut_cas()
returns table(date_expiration date, protection_gouvernementale boolean,
              chiffre_identification int, prenom_legal text, nom_legal text)
language sql stable security definer set search_path = public as $$
  select cv.date_expiration, cv.protection_gouvernementale, cv.chiffre_identification,
         cv.prenom_legal, cv.nom_legal
  from citoyens c join cas_valides cv on cv.code_encrypte = c.code_social_encrypte
  where c.id = auth.uid();
$$;
grant execute on function mon_statut_cas() to authenticated;

-- ============================================================
-- 6) INSCRIPTION D'UN CITOYEN
-- ============================================================
create or replace function inscrire_citoyen(
  p_username text, p_email text, p_prenom text, p_nom text,
  p_code_social_encrypte text, p_date_naissance date
) returns citoyens
language plpgsql security definer set search_path = public as $$
declare
  v_age numeric;
  v_cas cas_valides;
  v_row citoyens;
begin
  if auth.uid() is null then
    raise exception 'Utilisateur non authentifié.';
  end if;

  select * into v_cas from cas_valides where code_encrypte = p_code_social_encrypte;
  if v_cas is null then
    raise exception 'Code d''assurance social invalide.';
  end if;
  if v_cas.utilise then
    raise exception 'Ce code d''assurance social est déjà associé à un compte.';
  end if;
  if upper(trim(v_cas.nom_legal)) <> upper(trim(p_nom)) or upper(trim(v_cas.prenom_legal)) <> upper(trim(p_prenom)) then
    raise exception 'Le nom légal fourni ne correspond pas au code d''assurance social.';
  end if;

  v_age := age_toutouien(p_date_naissance);
  if v_age < 20 then
    raise exception 'Majorité civile non atteinte (20 ans toutouïens requis, actuel: %).', round(v_age, 2);
  end if;

  insert into citoyens (id, username, email, prenom, nom, code_social_encrypte, date_naissance,
                         age_toutouien_inscription, est_admin)
  values (auth.uid(), p_username, p_email, p_prenom, p_nom, p_code_social_encrypte, p_date_naissance,
          v_age, v_cas.est_admin)
  returning * into v_row;

  update cas_valides set utilise = true, citoyen_id = auth.uid(), utilise_le = now()
    where code_encrypte = p_code_social_encrypte;

  return v_row;
end;
$$;
grant execute on function inscrire_citoyen(text,text,text,text,text,date) to authenticated;

-- ============================================================
-- 7) TRÉSORERIE — REVENU AUTOMATIQUE (12,5 R$/minute)
-- ============================================================
-- Appelée par le client toutes les 5 minutes pendant que le citoyen
-- est connecté et actif sur le site.
create or replace function deposer_revenu_citoyen(p_minutes numeric default 5)
returns numeric language plpgsql security definer set search_path = public as $$
declare
  v_nouveau numeric;
begin
  if auth.uid() is null then
    raise exception 'Non authentifié.';
  end if;
  update citoyens
    set tresorerie = tresorerie + (p_minutes * 12.5),
        derniere_synchro_tresorerie = now()
    where id = auth.uid()
    returning tresorerie into v_nouveau;
  return v_nouveau;
end;
$$;
grant execute on function deposer_revenu_citoyen(numeric) to authenticated;

-- ============================================================
-- 8) FONCTIONS ADMIN — TRÉSORERIE, DETTES, PRÊTS, ARGENT ATTENDU
-- ============================================================
create or replace function admin_modifier_tresorerie(p_uuid uuid, p_montant numeric)
returns citoyens language plpgsql security definer set search_path = public as $$
declare v_row citoyens;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé à l''administrateur.'; end if;
  update citoyens set tresorerie = tresorerie + p_montant where id = p_uuid returning * into v_row;
  if v_row is null then raise exception 'Citoyen introuvable.'; end if;
  return v_row;
end; $$;
grant execute on function admin_modifier_tresorerie(uuid, numeric) to authenticated;

create or replace function admin_modifier_dette(p_uuid uuid, p_montant numeric)
returns citoyens language plpgsql security definer set search_path = public as $$
declare v_row citoyens;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé à l''administrateur.'; end if;
  update citoyens set dettes = greatest(0, dettes + p_montant) where id = p_uuid returning * into v_row;
  if v_row is null then raise exception 'Citoyen introuvable.'; end if;
  return v_row;
end; $$;
grant execute on function admin_modifier_dette(uuid, numeric) to authenticated;

-- Les prêts ajoutés par l'admin sont majorés de 20% (montant à rembourser),
-- seulement quand on AJOUTE un prêt (montant positif). Un retrait (négatif,
-- ex. remboursement) se fait au montant exact demandé.
create or replace function admin_modifier_pret(p_uuid uuid, p_montant numeric)
returns citoyens language plpgsql security definer set search_path = public as $$
declare v_row citoyens; v_ajuste numeric;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé à l''administrateur.'; end if;
  v_ajuste := case when p_montant > 0 then p_montant * 1.20 else p_montant end;
  update citoyens set prets = greatest(0, prets + v_ajuste) where id = p_uuid returning * into v_row;
  if v_row is null then raise exception 'Citoyen introuvable.'; end if;
  return v_row;
end; $$;
grant execute on function admin_modifier_pret(uuid, numeric) to authenticated;

create or replace function admin_modifier_argent_attendu(p_uuid uuid, p_montant numeric)
returns citoyens language plpgsql security definer set search_path = public as $$
declare v_row citoyens;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé à l''administrateur.'; end if;
  update citoyens set argent_attendu = greatest(0, argent_attendu + p_montant) where id = p_uuid returning * into v_row;
  if v_row is null then raise exception 'Citoyen introuvable.'; end if;
  return v_row;
end; $$;
grant execute on function admin_modifier_argent_attendu(uuid, numeric) to authenticated;

create or replace function admin_supprimer_compte(p_uuid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé à l''administrateur.'; end if;
  update cas_valides set utilise = false, citoyen_id = null, utilise_le = null
    where citoyen_id = p_uuid;
  delete from auth.users where id = p_uuid; -- cascade sur citoyens
end; $$;
grant execute on function admin_supprimer_compte(uuid) to authenticated;

-- ============================================================
-- 9) MESSAGERIE
-- ============================================================
create table messages (
  id                       uuid primary key default gen_random_uuid(),
  type                     text not null default 'normal' check (type in ('normal','gouvernemental')),
  expediteur_id            uuid references auth.users(id) on delete set null,
  destinataire_id          uuid not null references auth.users(id) on delete cascade,
  nom_affiche              text,          -- pour les messages gouvernementaux (ex: "Congrès Royal")
  liste_gouvernementale    text check (liste_gouvernementale in ('royale','gouvernementale','congressionnelle','anonyme')),
  titre                    text not null,
  contenu                  text not null,
  est_avertissement        boolean not null default false,
  supprime_pour_expediteur boolean not null default false,
  supprime_pour_destinataire boolean not null default false,
  modifie                  boolean not null default false,
  envoye_le                timestamptz not null default now(),
  modifie_le               timestamptz,
  constraint limite_normal check (
    type <> 'normal' or (char_length(contenu) <= 500 and char_length(titre) <= 120)
  )
);
alter table messages enable row level security;

create policy "Voir mes messages envoyés ou reçus (non supprimés pour moi)"
  on messages for select
  using (
    (auth.uid() = destinataire_id and not supprime_pour_destinataire)
    or (auth.uid() = expediteur_id and not supprime_pour_expediteur)
    or est_admin_actuel()
  );
-- Écriture uniquement via les fonctions ci-dessous.

create table signalements (
  id            uuid primary key default gen_random_uuid(),
  message_id    uuid not null references messages(id) on delete cascade,
  rapporteur_id uuid not null references auth.users(id) on delete cascade,
  contenu       text not null check (char_length(contenu) <= 100),
  cree_le       timestamptz not null default now()
);
alter table signalements enable row level security;

create policy "Un citoyen voit ses propres signalements"
  on signalements for select using (auth.uid() = rapporteur_id or est_admin_actuel());
create policy "Un citoyen peut signaler"
  on signalements for insert with check (auth.uid() = rapporteur_id);

-- ------------------------------------------------------------
-- Filtre anti-emoji (grossier mais efficace) + UTF-8 déjà garanti par Postgres
-- ------------------------------------------------------------
create or replace function contient_emoji(p_texte text)
returns boolean language sql immutable as $$
  select p_texte ~ '[\U0001F300-\U0001FAFF\u2600-\u27BF\U0001F1E6-\U0001F1FF]';
$$;

-- ------------------------------------------------------------
-- Envoi d'un message normal (utilisateur -> utilisateur)
-- ------------------------------------------------------------
create or replace function envoyer_message(p_destinataire_username text, p_titre text, p_contenu text)
returns messages language plpgsql security definer set search_path = public as $$
declare
  v_dest uuid;
  v_row messages;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if char_length(p_contenu) > 500 then raise exception 'Message limité à 500 caractères.'; end if;
  if char_length(p_titre) > 120 then raise exception 'Titre trop long.'; end if;
  if contient_emoji(p_contenu) or contient_emoji(p_titre) then
    raise exception 'Les émojis ne sont pas acceptés.';
  end if;

  select id into v_dest from citoyens where lower(username) = lower(p_destinataire_username);
  if v_dest is null then raise exception 'Destinataire introuvable.'; end if;

  insert into messages (type, expediteur_id, destinataire_id, titre, contenu)
  values ('normal', auth.uid(), v_dest, p_titre, p_contenu)
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function envoyer_message(text,text,text) to authenticated;

-- ------------------------------------------------------------
-- Modifier un message normal (expéditeur seulement)
-- ------------------------------------------------------------
create or replace function modifier_message(p_message_id uuid, p_nouveau_contenu text)
returns messages language plpgsql security definer set search_path = public as $$
declare v_row messages;
begin
  if char_length(p_nouveau_contenu) > 500 then raise exception 'Message limité à 500 caractères.'; end if;
  if contient_emoji(p_nouveau_contenu) then raise exception 'Les émojis ne sont pas acceptés.'; end if;
  update messages set contenu = p_nouveau_contenu, modifie = true, modifie_le = now()
    where id = p_message_id and expediteur_id = auth.uid() and type = 'normal'
    returning * into v_row;
  if v_row is null then raise exception 'Message introuvable ou modification non autorisée.'; end if;
  return v_row;
end; $$;
grant execute on function modifier_message(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- Suppression — expéditeur (supprime pour les deux, messages normaux seulement)
-- ------------------------------------------------------------
create or replace function supprimer_message_expediteur(p_message_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from messages
    where id = p_message_id and expediteur_id = auth.uid() and type = 'normal';
end; $$;
grant execute on function supprimer_message_expediteur(uuid) to authenticated;

-- ------------------------------------------------------------
-- Suppression — destinataire (masque seulement pour lui ; impossible sur un
-- message gouvernemental ou sur un message envoyé par l'admin)
-- ------------------------------------------------------------
create or replace function supprimer_message_destinataire(p_message_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_msg messages; v_admin_expediteur boolean;
begin
  select * into v_msg from messages where id = p_message_id and destinataire_id = auth.uid();
  if v_msg is null then raise exception 'Message introuvable.'; end if;
  if v_msg.type = 'gouvernemental' then
    raise exception 'Un message gouvernemental ne peut pas être supprimé par le destinataire.';
  end if;
  select est_admin into v_admin_expediteur from citoyens where id = v_msg.expediteur_id;
  if coalesce(v_admin_expediteur, false) then
    raise exception 'Un message envoyé par l''administration ne peut pas être supprimé par le destinataire.';
  end if;
  update messages set supprime_pour_destinataire = true where id = p_message_id;
end; $$;
grant execute on function supprimer_message_destinataire(uuid) to authenticated;

-- ------------------------------------------------------------
-- Signaler un message
-- ------------------------------------------------------------
create or replace function signaler_message(p_message_id uuid, p_raison text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if char_length(p_raison) > 100 then raise exception 'Signalement limité à 100 caractères.'; end if;
  insert into signalements (message_id, rapporteur_id, contenu) values (p_message_id, auth.uid(), p_raison);
end; $$;
grant execute on function signaler_message(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- ADMIN — Envoi (normal ou gouvernemental), à 1 / plusieurs / tous
-- p_destinataires : tableau de usernames ; NULL ou vide + p_tous=true => tout le monde
-- ------------------------------------------------------------
create or replace function admin_envoyer_message(
  p_destinataires text[],
  p_tous boolean,
  p_type text,                 -- 'normal' | 'gouvernemental'
  p_titre text,
  p_contenu text,
  p_est_avertissement boolean default false,
  p_nom_affiche text default null,
  p_liste_gouvernementale text default null
) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_dest_ids uuid[];
  v_count int := 0;
  v_id uuid;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé à l''administrateur.'; end if;
  if p_type not in ('normal','gouvernemental') then raise exception 'Type de message invalide.'; end if;
  if p_type = 'gouvernemental' and (p_nom_affiche is null or p_liste_gouvernementale is null) then
    raise exception 'Un message gouvernemental doit avoir un nom affiché et une liste.';
  end if;

  if p_tous then
    select array_agg(id) into v_dest_ids from citoyens;
  else
    select array_agg(id) into v_dest_ids from citoyens where lower(username) = any (select lower(u) from unnest(p_destinataires) as u);
  end if;

  if v_dest_ids is null or array_length(v_dest_ids, 1) is null then
    raise exception 'Aucun destinataire valide.';
  end if;

  foreach v_id in array v_dest_ids loop
    insert into messages (type, expediteur_id, destinataire_id, nom_affiche, liste_gouvernementale,
                           titre, contenu, est_avertissement)
    values (p_type, auth.uid(), v_id,
            case when p_type = 'gouvernemental' then p_nom_affiche else null end,
            case when p_type = 'gouvernemental' then p_liste_gouvernementale else null end,
            p_titre, p_contenu, p_est_avertissement);
    v_count := v_count + 1;
  end loop;

  return v_count;
end; $$;
grant execute on function admin_envoyer_message(text[],boolean,text,text,text,boolean,text,text) to authenticated;

-- ------------------------------------------------------------
-- ADMIN — Suppression (n'importe quel message, y compris gouvernemental)
-- ------------------------------------------------------------
create or replace function admin_supprimer_message(p_message_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé à l''administrateur.'; end if;
  delete from messages where id = p_message_id;
end; $$;
grant execute on function admin_supprimer_message(uuid) to authenticated;

-- ============================================================
-- 10) REALTIME — activer les mises à jour en direct
-- ============================================================
alter publication supabase_realtime add table citoyens;
alter publication supabase_realtime add table messages;

-- ============================================================
-- FIN DU SCHÉMA — voir README-portail.md pour le câblage du site
-- ============================================================
