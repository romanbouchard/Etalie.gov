-- ============================================================
-- Correctif — vérification du CAS AVANT inscription
-- (existence + non expiré + nom correspondant), à exécuter
-- après schema-portail-citoyen-v2.sql
-- ============================================================

-- Vérification complète, appelable AVANT de créer le compte (anon)
create or replace function verifier_cas_preinscription(p_code text, p_nom text, p_prenom text)
returns table(valide boolean, raison text)
language plpgsql security definer set search_path = public as $$
declare v_cas cas_valides;
begin
  select * into v_cas from cas_valides where code_encrypte = p_code;

  if v_cas is null then
    return query select false, 'Code d''assurance social invalide.';
    return;
  end if;

  if v_cas.utilise then
    return query select false, 'Ce code d''assurance social est déjà associé à un compte.';
    return;
  end if;

  if upper(trim(v_cas.nom_legal)) <> upper(trim(p_nom))
     or upper(trim(v_cas.prenom_legal)) <> upper(trim(p_prenom)) then
    return query select false, 'Le nom légal ne correspond pas au code d''assurance social.';
    return;
  end if;

  if v_cas.date_expiration < current_date and not v_cas.protection_gouvernementale then
    return query select false, 'Ce code d''assurance social est expiré. Faites-le renouveler avant de vous inscrire.';
    return;
  end if;

  return query select true, 'ok';
end;
$$;
grant execute on function verifier_cas_preinscription(text, text, text) to anon, authenticated;

-- inscrire_citoyen : on ajoute la vérification d'expiration côté serveur
-- aussi (sécurité), au cas où le pré-check aurait été contourné.
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
  if v_cas.date_expiration < current_date and not v_cas.protection_gouvernementale then
    raise exception 'Ce code d''assurance social est expiré.';
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
