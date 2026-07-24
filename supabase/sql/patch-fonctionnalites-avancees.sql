-- ============================================================
-- Correctif — Paiements, virements, contact gouvernemental,
-- et système d'Agent de la paix (constats d'infraction)
-- À exécuter après les correctifs précédents
-- ============================================================

-- ------------------------------------------------------------
-- 0) NOTE SUR L'HYPOTHÈSE "AGENT DE LA PAIX"
-- ------------------------------------------------------------
-- Le fichier num_CAS.txt n'a qu'UN SEUL indicateur O/N (protection
-- gouvernementale). Je réutilise ce même indicateur pour donner
-- aussi l'accès au panneau Agent de la paix (O = protégé ET agent).
-- Si tu veux un indicateur séparé, il faudra changer le format du
-- fichier (ajouter un champ) et je réajuste en 2 minutes.

alter table citoyens add column if not exists est_agent_paix boolean not null default false;

-- inscrire_citoyen : on ajoute un paramètre pour transmettre le
-- drapeau O/N lu dans le fichier (le site le connaît, Postgres non).
create or replace function inscrire_citoyen(
  p_username text, p_email text, p_prenom text, p_nom text,
  p_code_social_encrypte text, p_date_naissance date,
  p_protege_gouvernement boolean default false
) returns citoyens
language plpgsql security definer set search_path = public as $$
declare
  v_age numeric;
  v_row citoyens;
  v_est_admin boolean;
begin
  if auth.uid() is null then raise exception 'Utilisateur non authentifié.'; end if;

  if exists (select 1 from citoyens where code_social_encrypte = p_code_social_encrypte) then
    raise exception 'Ce code d''assurance social est déjà associé à un compte.';
  end if;

  v_age := age_toutouien(p_date_naissance);
  if v_age < 20 then
    raise exception 'Majorité civile non atteinte (20 ans toutouïens requis, actuel: %).', round(v_age, 2);
  end if;

  v_est_admin := (upper(trim(p_nom)) = 'ADMIN' and upper(trim(p_prenom)) = 'ADMIN');

  insert into citoyens (id, username, email, prenom, nom, code_social_encrypte, date_naissance,
                         age_toutouien_inscription, est_admin, est_agent_paix)
  values (auth.uid(), p_username, p_email, p_prenom, p_nom, p_code_social_encrypte, p_date_naissance,
          v_age, v_est_admin, p_protege_gouvernement)
  returning * into v_row;

  return v_row;
end;
$$;
grant execute on function inscrire_citoyen(text,text,text,text,text,date,boolean) to authenticated;

-- ============================================================
-- 1) TRÉSOR PUBLIC (reçoit les taxes de virement — remplace le
--    besoin d'un faux compte citoyen "@gouvernement")
-- ============================================================
create table if not exists tresor_public (
  id     int primary key default 1,
  solde  numeric not null default 0,
  constraint une_seule_ligne check (id = 1)
);
insert into tresor_public (id, solde) values (1, 0) on conflict (id) do nothing;
alter table tresor_public enable row level security;
create policy "Admin consulte le trésor public"
  on tresor_public for select using (est_admin_actuel());

-- ============================================================
-- 2) REMBOURSEMENT DE DETTES ET DE PRÊTS (avec sa propre trésorerie)
-- ============================================================
create or replace function payer_dette(p_montant numeric)
returns citoyens language plpgsql security definer set search_path = public as $$
declare v_row citoyens;
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select * into v_row from citoyens where id = auth.uid();
  if v_row.tresorerie < p_montant then raise exception 'Trésorerie insuffisante.'; end if;
  update citoyens
    set tresorerie = tresorerie - p_montant,
        dettes = greatest(0, dettes - p_montant)
    where id = auth.uid()
    returning * into v_row;
  return v_row;
end; $$;
grant execute on function payer_dette(numeric) to authenticated;

create or replace function payer_pret(p_montant numeric)
returns citoyens language plpgsql security definer set search_path = public as $$
declare v_row citoyens;
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select * into v_row from citoyens where id = auth.uid();
  if v_row.tresorerie < p_montant then raise exception 'Trésorerie insuffisante.'; end if;
  update citoyens
    set tresorerie = tresorerie - p_montant,
        prets = greatest(0, prets - p_montant)
    where id = auth.uid()
    returning * into v_row;
  return v_row;
end; $$;
grant execute on function payer_pret(numeric) to authenticated;

-- ============================================================
-- 3) VIREMENTS ENTRE CITOYENS
-- ============================================================
create table if not exists transferts (
  id                uuid primary key default gen_random_uuid(),
  type              text not null check (type in ('famille','business')),
  expediteur_id     uuid not null references auth.users(id) on delete cascade,
  destinataires     uuid[] not null,
  montant_par_personne numeric not null,
  taxe_pourcentage  numeric not null,
  taxe_totale       numeric not null,
  total_debite      numeric not null,
  remboursable      boolean not null default false,
  rembourse         boolean not null default false,
  cree_le           timestamptz not null default now(),
  rembourse_le      timestamptz
);
alter table transferts enable row level security;
create policy "Voir mes virements (envoyés ou reçus) ou tout si admin"
  on transferts for select
  using (auth.uid() = expediteur_id or auth.uid() = any(destinataires) or est_admin_actuel());

-- ------------------------------------------------------------
-- Virement familial : 1 destinataire, 5% de taxe (ajoutée au montant
-- débité, le destinataire reçoit le montant plein), non remboursable.
-- ------------------------------------------------------------
create or replace function virement_famille(p_destinataire_username text, p_montant numeric)
returns transferts language plpgsql security definer set search_path = public as $$
declare
  v_dest_id uuid;
  v_expediteur citoyens;
  v_taxe numeric;
  v_total numeric;
  v_row transferts;
begin
  if p_montant <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select id into v_dest_id from citoyens where lower(username) = lower(p_destinataire_username);
  if v_dest_id is null then raise exception 'Destinataire introuvable.'; end if;
  if v_dest_id = auth.uid() then raise exception 'Impossible de se virer de l''argent à soi-même.'; end if;

  select * into v_expediteur from citoyens where id = auth.uid();
  v_taxe := p_montant * 0.05;
  v_total := p_montant + v_taxe;
  if v_expediteur.tresorerie < v_total then raise exception 'Trésorerie insuffisante (total avec taxe: %).', v_total; end if;

  update citoyens set tresorerie = tresorerie - v_total where id = auth.uid();
  update citoyens set tresorerie = tresorerie + p_montant where id = v_dest_id;
  update tresor_public set solde = solde + v_taxe where id = 1;

  insert into transferts (type, expediteur_id, destinataires, montant_par_personne, taxe_pourcentage, taxe_totale, total_debite, remboursable)
  values ('famille', auth.uid(), array[v_dest_id], p_montant, 5, v_taxe, v_total, false)
  returning * into v_row;

  return v_row;
end; $$;
grant execute on function virement_famille(text, numeric) to authenticated;

-- ------------------------------------------------------------
-- Virement business : plusieurs destinataires reçoivent chacun le
-- MÊME montant, taxe de 25% sur le total versé (ajoutée, débitée à
-- l'expéditeur), remboursable par l'admin en cas de litige gagné.
-- ------------------------------------------------------------
create or replace function virement_business(p_destinataires_usernames text[], p_montant_par_personne numeric)
returns transferts language plpgsql security definer set search_path = public as $$
declare
  v_dest_ids uuid[];
  v_expediteur citoyens;
  v_total_verse numeric;
  v_taxe numeric;
  v_total_debite numeric;
  v_id uuid;
  v_row transferts;
begin
  if p_montant_par_personne <= 0 then raise exception 'Le montant doit être positif.'; end if;
  select array_agg(id) into v_dest_ids from citoyens where lower(username) = any (select lower(u) from unnest(p_destinataires_usernames) as u);
  if v_dest_ids is null or array_length(v_dest_ids, 1) is null then raise exception 'Aucun destinataire valide.'; end if;
  if auth.uid() = any(v_dest_ids) then raise exception 'Impossible de s''inclure soi-même comme destinataire.'; end if;

  select * into v_expediteur from citoyens where id = auth.uid();
  v_total_verse := p_montant_par_personne * array_length(v_dest_ids, 1);
  v_taxe := v_total_verse * 0.25;
  v_total_debite := v_total_verse + v_taxe;
  if v_expediteur.tresorerie < v_total_debite then
    raise exception 'Trésorerie insuffisante (total avec taxe: %).', v_total_debite;
  end if;

  update citoyens set tresorerie = tresorerie - v_total_debite where id = auth.uid();
  foreach v_id in array v_dest_ids loop
    update citoyens set tresorerie = tresorerie + p_montant_par_personne where id = v_id;
  end loop;
  update tresor_public set solde = solde + v_taxe where id = 1;

  insert into transferts (type, expediteur_id, destinataires, montant_par_personne, taxe_pourcentage, taxe_totale, total_debite, remboursable)
  values ('business', auth.uid(), v_dest_ids, p_montant_par_personne, 25, v_taxe, v_total_debite, true)
  returning * into v_row;

  return v_row;
end; $$;
grant execute on function virement_business(text[], numeric) to authenticated;

-- ------------------------------------------------------------
-- Remboursement (admin seulement — "si gagné")
-- ------------------------------------------------------------
create or replace function admin_rembourser_virement(p_transfert_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_t transferts; v_id uuid;
begin
  if not est_admin_actuel() then raise exception 'Accès refusé.'; end if;
  select * into v_t from transferts where id = p_transfert_id;
  if v_t is null then raise exception 'Virement introuvable.'; end if;
  if not v_t.remboursable then raise exception 'Ce type de virement n''est pas remboursable.'; end if;
  if v_t.rembourse then raise exception 'Ce virement a déjà été remboursé.'; end if;

  update citoyens set tresorerie = tresorerie + v_t.total_debite where id = v_t.expediteur_id;
  foreach v_id in array v_t.destinataires loop
    update citoyens set tresorerie = greatest(0, tresorerie - v_t.montant_par_personne) where id = v_id;
  end loop;
  update tresor_public set solde = greatest(0, solde - v_t.taxe_totale) where id = 1;

  update transferts set rembourse = true, rembourse_le = now() where id = p_transfert_id;
end; $$;
grant execute on function admin_rembourser_virement(uuid) to authenticated;

-- ============================================================
-- 4) CONTACTER UN MINISTÈRE / LE GOUVERNEMENT
-- ============================================================
-- Envoie le message à tous les comptes admin (il n'existe pas de
-- compte séparé par ministère ; le libellé choisi est mis dans le titre).
create or replace function contacter_gouvernement(p_cible text, p_titre text, p_contenu text)
returns int language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_count int := 0;
begin
  if auth.uid() is null then raise exception 'Non authentifié.'; end if;
  if char_length(p_contenu) > 500 then raise exception 'Message limité à 500 caractères.'; end if;
  for v_id in select id from citoyens where est_admin loop
    insert into messages (type, expediteur_id, destinataire_id, titre, contenu)
    values ('normal', auth.uid(), v_id, '[' || p_cible || '] ' || p_titre, p_contenu);
    v_count := v_count + 1;
  end loop;
  if v_count = 0 then raise exception 'Aucun destinataire gouvernemental disponible pour le moment.'; end if;
  return v_count;
end; $$;
grant execute on function contacter_gouvernement(text, text, text) to authenticated;

-- ============================================================
-- 5) AGENT DE LA PAIX
-- ============================================================
create or replace function est_agent_actuel()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select est_agent_paix from citoyens where id = auth.uid()), false);
$$;

-- Recherche d'un citoyen à partir de son CAS déchiffré (en clair,
-- ex: "982 391 743" ou "982-391-743" — les deux formats acceptés)
create or replace function agent_rechercher_citoyen(p_cas_encrypte text)
returns table(id uuid, username text, prenom text, nom text, email text,
              date_naissance date, tresorerie numeric, dettes numeric,
              prets numeric, argent_attendu numeric, cree_le timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not est_agent_actuel() and not est_admin_actuel() then
    raise exception 'Accès refusé : réservé aux agents de la paix.';
  end if;
  return query
    select c.id, c.username, c.prenom, c.nom, c.email, c.date_naissance,
           c.tresorerie, c.dettes, c.prets, c.argent_attendu, c.cree_le
    from citoyens c where c.code_social_encrypte = p_cas_encrypte;
end; $$;
grant execute on function agent_rechercher_citoyen(text) to authenticated;

-- Autoriser le type 'agent' dans messages (tag "@Message d'un agent de la paix")
alter table messages drop constraint if exists messages_type_check;
alter table messages add constraint messages_type_check check (type in ('normal','gouvernemental','agent'));

create or replace function agent_envoyer_message(p_destinataire_username text, p_titre text, p_contenu text, p_en_tant_agent boolean)
returns messages language plpgsql security definer set search_path = public as $$
declare v_dest uuid; v_row messages;
begin
  if not est_agent_actuel() and not est_admin_actuel() then raise exception 'Accès refusé : réservé aux agents de la paix.'; end if;
  if char_length(p_contenu) > 500 then raise exception 'Message limité à 500 caractères.'; end if;
  select id into v_dest from citoyens where lower(username) = lower(p_destinataire_username);
  if v_dest is null then raise exception 'Destinataire introuvable.'; end if;

  insert into messages (type, expediteur_id, destinataire_id, titre, contenu, nom_affiche)
  values (case when p_en_tant_agent then 'agent' else 'normal' end,
          auth.uid(), v_dest, p_titre, p_contenu,
          case when p_en_tant_agent then 'Agent de la paix' else null end)
  returning * into v_row;
  return v_row;
end; $$;
grant execute on function agent_envoyer_message(text, text, text, boolean) to authenticated;

-- ============================================================
-- 6) CONSTATS D'INFRACTION
-- ============================================================
create table if not exists constats_infraction (
  id                       uuid primary key default gen_random_uuid(),
  destinataire_id          uuid not null references auth.users(id) on delete cascade,
  agent_emetteur_id        uuid references auth.users(id) on delete set null,
  raison                   text not null,
  justification            text not null,
  date_infraction          date not null,
  date_infraction_toutouienne text not null,
  heure_infraction         time not null,
  infraction               text not null,
  numero_infraction        text not null,
  matricule_agent_vu       text not null,
  matricule_agent_donne    text not null,
  matricule_agent_assiste  text,
  nom_agent_vu             text not null,
  nom_agent_donne          text not null,
  nom_agent_assiste        text,
  lieu_rue                 text not null,
  lieu_ville                text not null,
  lieu_province             text not null,
  prix_infraction           numeric not null,
  prix_taxes                numeric not null,
  prix_total                numeric not null,
  commissariat               text not null,
  commissariat_type          text not null check (commissariat_type in ('provincial','federal')),
  paye                       boolean not null default false,
  paye_le                    timestamptz,
  supprime_par_agent         boolean not null default false,
  supprime_par_citoyen       boolean not null default false,
  cree_le                    timestamptz not null default now()
);
alter table constats_infraction enable row level security;

create policy "Voir ses constats (reçus ou émis) ou tout si admin"
  on constats_infraction for select
  using (
    (auth.uid() = destinataire_id and not supprime_par_citoyen)
    or (auth.uid() = agent_emetteur_id and not supprime_par_agent)
    or est_admin_actuel()
  );

create or replace function agent_creer_constat(
  p_destinataire_username text, p_raison text, p_justification text,
  p_date_infraction date, p_date_infraction_toutouienne text, p_heure_infraction time,
  p_infraction text, p_numero_infraction text,
  p_matricule_agent_vu text, p_matricule_agent_donne text, p_matricule_agent_assiste text,
  p_nom_agent_vu text, p_nom_agent_donne text, p_nom_agent_assiste text,
  p_lieu_rue text, p_lieu_ville text, p_lieu_province text,
  p_prix_infraction numeric, p_prix_taxes numeric,
  p_commissariat text, p_commissariat_type text
) returns constats_infraction
language plpgsql security definer set search_path = public as $$
declare v_dest uuid; v_row constats_infraction; v_titre text;
begin
  if not est_agent_actuel() and not est_admin_actuel() then raise exception 'Accès refusé : réservé aux agents de la paix.'; end if;
  select id into v_dest from citoyens where lower(username) = lower(p_destinataire_username);
  if v_dest is null then raise exception 'Destinataire introuvable.'; end if;

  insert into constats_infraction (
    destinataire_id, agent_emetteur_id, raison, justification, date_infraction,
    date_infraction_toutouienne, heure_infraction, infraction, numero_infraction,
    matricule_agent_vu, matricule_agent_donne, matricule_agent_assiste,
    nom_agent_vu, nom_agent_donne, nom_agent_assiste,
    lieu_rue, lieu_ville, lieu_province,
    prix_infraction, prix_taxes, prix_total, commissariat, commissariat_type
  ) values (
    v_dest, auth.uid(), p_raison, p_justification, p_date_infraction,
    p_date_infraction_toutouienne, p_heure_infraction, p_infraction, p_numero_infraction,
    p_matricule_agent_vu, p_matricule_agent_donne, p_matricule_agent_assiste,
    p_nom_agent_vu, p_nom_agent_donne, p_nom_agent_assiste,
    p_lieu_rue, p_lieu_ville, p_lieu_province,
    p_prix_infraction, p_prix_taxes, p_prix_infraction + p_prix_taxes, p_commissariat, p_commissariat_type
  ) returning * into v_row;

  v_titre := 'Constat d''infraction commis le ' || to_char(p_date_infraction, 'DD/MM/YYYY');

  insert into messages (type, expediteur_id, destinataire_id, titre, contenu, nom_affiche)
  values ('agent', auth.uid(), v_dest, v_titre,
          'Un constat d''infraction a été émis à votre nom. Consultez l''onglet Constats de votre tableau de bord pour le détail et le paiement.',
          'Agent de la paix');

  return v_row;
end; $$;
grant execute on function agent_creer_constat(text,text,text,date,text,time,text,text,text,text,text,text,text,text,text,text,text,numeric,numeric,text,text) to authenticated;

create or replace function payer_constat(p_id uuid)
returns constats_infraction language plpgsql security definer set search_path = public as $$
declare v_constat constats_infraction; v_citoyen citoyens;
begin
  select * into v_constat from constats_infraction where id = p_id and destinataire_id = auth.uid();
  if v_constat is null then raise exception 'Constat introuvable.'; end if;
  if v_constat.paye then raise exception 'Ce constat a déjà été payé.'; end if;

  select * into v_citoyen from citoyens where id = auth.uid();
  if v_citoyen.tresorerie < v_constat.prix_total then raise exception 'Trésorerie insuffisante.'; end if;

  update citoyens set tresorerie = tresorerie - v_constat.prix_total where id = auth.uid();
  update tresor_public set solde = solde + v_constat.prix_total where id = 1;

  update constats_infraction set paye = true, paye_le = now() where id = p_id returning * into v_constat;
  return v_constat;
end; $$;
grant execute on function payer_constat(uuid) to authenticated;

-- Le citoyen ne peut supprimer (masquer) son constat qu'une fois payé
create or replace function citoyen_supprimer_constat(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_constat constats_infraction;
begin
  select * into v_constat from constats_infraction where id = p_id and destinataire_id = auth.uid();
  if v_constat is null then raise exception 'Constat introuvable.'; end if;
  if not v_constat.paye then raise exception 'Le constat doit être payé avant de pouvoir être retiré.'; end if;
  update constats_infraction set supprime_par_citoyen = true where id = p_id;
end; $$;
grant execute on function citoyen_supprimer_constat(uuid) to authenticated;

-- L'agent émetteur (ou l'admin) peut supprimer un constat à tout moment
create or replace function agent_supprimer_constat(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from constats_infraction where id = p_id and agent_emetteur_id = auth.uid())
     and not est_admin_actuel() then
    raise exception 'Accès refusé.';
  end if;
  update constats_infraction set supprime_par_agent = true where id = p_id;
end; $$;
grant execute on function agent_supprimer_constat(uuid) to authenticated;
