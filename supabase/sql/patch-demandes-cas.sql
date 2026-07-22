-- ============================================================
-- Correctif — Demandes d'Assurance Sociale (formulaire public)
-- À exécuter après schema-portail-citoyen-v2.sql (+ patch-verification-cas.sql)
-- ============================================================

create table if not exists demandes_assurance_sociale (
  id                          uuid primary key default gen_random_uuid(),
  pays_origine                text not null,
  numero_passeport            text not null,
  date_naissance               date not null,
  prenom                       text not null,
  nom                          text not null,
  email_contact                text not null,
  adresse_residence_origine    text not null,
  adresse_residence_etalie     text not null,
  duree_sur_territoire         text not null,
  a_travaille_sur_territoire   boolean not null,
  a_travaille_gouvernement     boolean not null,
  parle_francais                boolean not null, texte_francais text,
  parle_anglais                 boolean not null, texte_anglais text,
  parle_italien                 boolean not null, texte_italien text,
  connaissance_pays             boolean not null, texte_connaissance text,
  casier_judiciaire             boolean not null, numero_casier text,
  emploi_actuel                 text not null,
  revenus                       text not null,
  pourquoi_assurance_sociale    text not null,
  a_famille_ou_epoux            boolean not null, pourquoi_rejoindre text,
  contribution_societe          text not null,
  serment_autorite               text not null,
  serment_fidelite                text not null,
  statut                        text not null default 'en_attente' check (statut in ('en_attente','approuvee','refusee')),
  soumise_le                    timestamptz not null default now(),

  constraint longueur_francais      check (not parle_francais or char_length(texte_francais) >= 50),
  constraint longueur_anglais       check (not parle_anglais or char_length(texte_anglais) >= 50),
  constraint longueur_italien       check (not parle_italien or char_length(texte_italien) >= 50),
  constraint longueur_connaissance  check (not connaissance_pays or char_length(texte_connaissance) >= 50),
  constraint casier_numero_requis   check (not casier_judiciaire or numero_casier is not null),
  constraint longueur_pourquoi      check (char_length(pourquoi_assurance_sociale) >= 100),
  constraint longueur_rejoindre     check (not a_famille_ou_epoux or char_length(pourquoi_rejoindre) >= 3),
  constraint longueur_contribution  check (char_length(contribution_societe) >= 100),
  constraint longueur_autorite      check (char_length(serment_autorite) >= 30),
  constraint longueur_fidelite      check (char_length(serment_fidelite) >= 89)
);

alter table demandes_assurance_sociale enable row level security;

-- N'importe qui (même non connecté) peut soumettre une demande
create policy "Soumission publique d'une demande de CAS"
  on demandes_assurance_sociale for insert
  with check (true);
grant insert on demandes_assurance_sociale to anon, authenticated;

-- Seul l'admin peut consulter les demandes
create policy "Admin consulte les demandes de CAS"
  on demandes_assurance_sociale for select
  using (est_admin_actuel());
grant select on demandes_assurance_sociale to authenticated;

-- Seul l'admin peut changer le statut (suivi de traitement — l'ajout du
-- vrai CAS dans num_CAS.txt et son chargement via parse_cas.py restent
-- un geste manuel de ta part)
create or replace function admin_maj_statut_demande(p_id uuid, p_statut text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé à l''administrateur.'; end if;
  if p_statut not in ('en_attente','approuvee','refusee') then raise exception 'Statut invalide.'; end if;
  update demandes_assurance_sociale set statut = p_statut where id = p_id;
end; $$;
grant execute on function admin_maj_statut_demande(uuid, text) to authenticated;
