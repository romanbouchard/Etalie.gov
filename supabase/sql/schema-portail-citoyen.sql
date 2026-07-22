-- ============================================================
-- Schéma Supabase — Portail citoyen d'Étalie
-- À exécuter dans l'éditeur SQL de Supabase (Database > SQL Editor)
-- ============================================================

-- ------------------------------------------------------------
-- 1) TABLE DES CODES SOCIAUX VALIDES (le "coffre")
-- ------------------------------------------------------------
-- Contient uniquement la version ENCRYPTÉE des vrais CAS
-- (celle produite par encrypt.html). Le vrai numéro en clair
-- ne transite jamais vers Supabase.
create table if not exists cas_valides (
  id             uuid primary key default gen_random_uuid(),
  code_encrypte  text unique not null,       -- ex: "Q-E-Z/V-X-T/H-N-B"
  utilise        boolean not null default false,
  citoyen_id     uuid references auth.users(id) on delete set null,
  cree_le        timestamptz not null default now(),
  utilise_le     timestamptz
);

-- Personne ne peut lire cette table directement depuis le site :
-- la vérification passe uniquement par la fonction ci-dessous.
alter table cas_valides enable row level security;
-- Aucune policy de select/insert/update pour les utilisateurs anonymes ou connectés
-- => la table est invisible depuis le client, seule la fonction security definer y touche.

-- ------------------------------------------------------------
-- 2) TABLE DES CITOYENS (profil public, lié à l'authentification)
-- ------------------------------------------------------------
create table if not exists citoyens (
  id                 uuid primary key references auth.users(id) on delete cascade,
  username           text unique not null check (char_length(username) between 3 and 24),
  prenom             text not null,
  nom                text not null,
  code_social_encrypte text not null references cas_valides(code_encrypte),
  date_naissance     date not null,
  age_toutouien_inscription numeric not null,  -- calculé et figé au moment de l'inscription
  cree_le            timestamptz not null default now()
);

alter table citoyens enable row level security;

-- Un citoyen peut lire son propre profil
create policy "Lecture de son propre profil"
  on citoyens for select
  using (auth.uid() = id);

-- Un citoyen peut mettre à jour son propre profil (sauf le code social et la date de naissance,
-- protégés par un trigger plus bas)
create policy "Mise à jour de son propre profil"
  on citoyens for update
  using (auth.uid() = id);

-- L'insertion se fait uniquement via la fonction inscrire_citoyen() ci-dessous,
-- jamais directement par le client.

-- Empêche un citoyen de modifier son code social ou sa date de naissance après coup
create or replace function empecher_modif_champs_proteges()
returns trigger language plpgsql as $$
begin
  if new.code_social_encrypte <> old.code_social_encrypte
     or new.date_naissance <> old.date_naissance then
    raise exception 'Le code social et la date de naissance ne peuvent pas être modifiés.';
  end if;
  return new;
end;
$$;

create trigger proteger_champs_citoyens
  before update on citoyens
  for each row execute function empecher_modif_champs_proteges();

-- ------------------------------------------------------------
-- 3) CALCUL DE L'ÂGE TOUTOUÏEN
-- ------------------------------------------------------------
-- IMPORTANT — À CONFIRMER AVANT MISE EN PRODUCTION :
-- Cette fonction applique la même formule que le convertisseur du site
-- (années réelles × 12,1666667) à la date de naissance de la personne.
-- Concrètement, ça veut dire qu'une personne ayant environ 1 an et 7 mois
-- d'âge RÉEL atteint déjà "20 ans toutouïens". Si ce n'est pas l'effet
-- recherché pour la majorité civile (Bright Bill, Section II, Article 1),
-- remplacez la constante 12.1666667 par 1 dans la fonction ci-dessous
-- pour exiger littéralement 20 années réelles.
create or replace function age_toutouien(p_date_naissance date)
returns numeric
language sql
immutable
as $$
  select (extract(epoch from (now() - p_date_naissance::timestamptz)) / 86400.0 / 365.25) * 12.1666667;
$$;

-- ------------------------------------------------------------
-- 4) VÉRIFICATION D'UN CODE SOCIAL (sans exposer la table)
-- ------------------------------------------------------------
create or replace function code_social_est_valide(p_code text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_utilise boolean;
begin
  select utilise into v_utilise from cas_valides where code_encrypte = p_code;
  if v_utilise is null then
    return false;  -- code inexistant dans le coffre
  end if;
  return not v_utilise;  -- valide seulement si pas déjà réclamé
end;
$$;

grant execute on function code_social_est_valide(text) to anon, authenticated;

-- ------------------------------------------------------------
-- 5) INSCRIPTION D'UN CITOYEN (tout-en-un, transactionnel)
-- ------------------------------------------------------------
-- Appelée après supabase.auth.signUp() côté client, avec l'id
-- de l'utilisateur nouvellement créé (auth.uid()).
create or replace function inscrire_citoyen(
  p_username text,
  p_prenom text,
  p_nom text,
  p_code_social_encrypte text,
  p_date_naissance date
)
returns citoyens
language plpgsql
security definer
set search_path = public
as $$
declare
  v_age numeric;
  v_row citoyens;
begin
  if auth.uid() is null then
    raise exception 'Utilisateur non authentifié.';
  end if;

  if not code_social_est_valide(p_code_social_encrypte) then
    raise exception 'Code social invalide ou déjà utilisé.';
  end if;

  v_age := age_toutouien(p_date_naissance);
  if v_age < 20 then
    raise exception 'Âge insuffisant : majorité civile requise (20 ans toutouïens, actuel: %).', round(v_age, 2);
  end if;

  insert into citoyens (id, username, prenom, nom, code_social_encrypte, date_naissance, age_toutouien_inscription)
  values (auth.uid(), p_username, p_prenom, p_nom, p_code_social_encrypte, p_date_naissance, v_age)
  returning * into v_row;

  update cas_valides
    set utilise = true, citoyen_id = auth.uid(), utilise_le = now()
    where code_encrypte = p_code_social_encrypte;

  return v_row;
end;
$$;

grant execute on function inscrire_citoyen(text, text, text, text, date) to authenticated;

-- ============================================================
-- COMMENT CHARGER LES CODES VALIDES (le "coffre")
-- ============================================================
-- 1. Ouvrez encrypt.html localement (hors ligne, jamais publié sur le site).
-- 2. Collez vos vrais CAS (un par ligne) dans la section "Encryption en lot".
-- 3. Copiez les résultats encryptés.
-- 4. Insérez-les dans Supabase, par exemple :
--
-- insert into cas_valides (code_encrypte) values
--   ('Q-E-Z/V-X-T/H-N-B'),
--   ('...');
--
-- Les vrais numéros ne sont jamais stockés dans Supabase.

-- ============================================================
-- COMMENT S'INSCRIRE CÔTÉ CLIENT (résumé du flux)
-- ============================================================
-- 1. supabase.auth.signUp({ email: `${username}@citoyens.etalie`, password })
--    (Supabase Auth exige un champ email : on en fabrique un factice à partir
--    du username. Désactivez la confirmation par courriel dans
--    Authentication > Settings pour ce projet.)
-- 2. Une fois connecté, appeler :
--    supabase.rpc('inscrire_citoyen', {
--      p_username, p_prenom, p_nom,
--      p_code_social_encrypte: encrypterCode(casEntre),  -- même fonction que encrypt.html
--      p_date_naissance
--    })
-- 3. Si la fonction lève une exception (code invalide, âge insuffisant,
--    username déjà pris), afficher l'erreur retournée par Supabase.
