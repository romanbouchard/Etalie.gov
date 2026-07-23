-- ============================================================
-- Correctif — Passage à assets/donnees/CAS/num_CAS.txt comme
-- seule source de vérité pour les CAS. Supabase ne stocke plus
-- rien à propos des CAS eux-mêmes (ni la liste, ni "utilisé",
-- ni la date d'expiration).
-- ============================================================

-- 1) citoyens.code_social_encrypte n'a plus besoin de pointer vers
--    une table cas_valides : on garde juste le champ, unique,
--    pour empêcher qu'un même CAS serve deux fois.
alter table citoyens drop constraint if exists citoyens_code_social_encrypte_fkey;
alter table citoyens add constraint citoyens_code_social_encrypte_key unique (code_social_encrypte);

-- 2) On n'a plus besoin de ces fonctions (elles lisaient cas_valides)
drop function if exists code_social_est_valide(text) cascade;
drop function if exists verifier_cas_preinscription(text, text, text) cascade;
drop function if exists mon_statut_cas() cascade;

-- 3) admin_supprimer_compte ne touche plus à cas_valides
create or replace function admin_supprimer_compte(p_uuid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not est_admin_actuel() then raise exception 'Accès refusé : réservé à l''administrateur.'; end if;
  delete from auth.users where id = p_uuid; -- cascade sur citoyens
end; $$;
grant execute on function admin_supprimer_compte(uuid) to authenticated;

-- 4) Vérifie si un CAS encrypté est déjà réclamé par un citoyen
--    (utilisable par un visiteur non connecté, avant inscription)
create or replace function cas_deja_reclame(p_code text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from citoyens where code_social_encrypte = p_code);
$$;
grant execute on function cas_deja_reclame(text) to anon, authenticated;

-- 5) inscrire_citoyen simplifiée : la validation du CAS (existence,
--    nom correspondant, pas expiré) se fait maintenant côté client
--    en lisant num_CAS.txt directement. Ici on ne garde que ce que
--    Postgres seul peut garantir : unicité du CAS et âge minimum.
--    L'admin est détecté par nom+prénom = ADMIN/ADMIN (convention
--    du fichier num_CAS.txt).
create or replace function inscrire_citoyen(
  p_username text, p_email text, p_prenom text, p_nom text,
  p_code_social_encrypte text, p_date_naissance date
) returns citoyens
language plpgsql security definer set search_path = public as $$
declare
  v_age numeric;
  v_row citoyens;
  v_est_admin boolean;
begin
  if auth.uid() is null then
    raise exception 'Utilisateur non authentifié.';
  end if;

  if exists (select 1 from citoyens where code_social_encrypte = p_code_social_encrypte) then
    raise exception 'Ce code d''assurance social est déjà associé à un compte.';
  end if;

  v_age := age_toutouien(p_date_naissance);
  if v_age < 20 then
    raise exception 'Majorité civile non atteinte (20 ans toutouïens requis, actuel: %).', round(v_age, 2);
  end if;

  v_est_admin := (upper(trim(p_nom)) = 'ADMIN' and upper(trim(p_prenom)) = 'ADMIN');

  insert into citoyens (id, username, email, prenom, nom, code_social_encrypte, date_naissance,
                         age_toutouien_inscription, est_admin)
  values (auth.uid(), p_username, p_email, p_prenom, p_nom, p_code_social_encrypte, p_date_naissance,
          v_age, v_est_admin)
  returning * into v_row;

  return v_row;
end;
$$;
grant execute on function inscrire_citoyen(text,text,text,text,text,date) to authenticated;

-- 6) La table cas_valides ne sert plus à rien : on la retire.
drop table if exists cas_valides cascade;
