-- =====================================================================
-- Loka Motoka · Pré-cadastro CG Start 2027
-- Tabela + função de upsert (dedup por WhatsApp + classificação)
-- Rodar uma vez no Supabase (SQL editor) ou via psql.
-- =====================================================================

create table if not exists public.pre_cadastro_cg2027 (
  id                    bigint generated always as identity primary key,
  criado_em             timestamptz not null default now(),
  atualizado_em         timestamptz not null default now(),
  envios                int not null default 1,

  nome                  text not null,
  estado_civil          text not null check (estado_civil in ('Solteiro(a)','Casado(a)')),
  whatsapp_original     text not null,
  whatsapp_normalizado  text not null unique check (whatsapp_normalizado ~ '^55[1-9]{2}9[0-9]{8}$'),
  email                 text,

  cnh_a                 text not null check (cnh_a in ('Sim','Não')),
  ear                   text not null check (ear in ('Sim','Não','Não sei informar')),
  atividade_app         text not null check (atividade_app in (
                          'Sim, com delivery (iFood, 99Food etc.)',
                          'Sim, com transporte de passageiros (Uber/99)',
                          'Sim, com delivery e transporte de passageiros',
                          'Não, ainda não trabalho com aplicativos')),
  previsao_inicio       text not null check (previsao_inicio in (
                          'Em novembro, assim que estiver disponível',
                          'Nos próximos 30 dias',
                          'Daqui a 2 ou 3 meses',
                          'Estou apenas pesquisando')),
  cidade                text not null check (cidade in ('Americana','Santa Bárbara d''Oeste','Nova Odessa','Outra cidade')),

  consentimento         boolean not null check (consentimento = true),
  consentimento_texto   text not null,
  consentimento_versao  text not null,
  consentimento_em      timestamptz not null default now(),

  origem                text,
  campanha              text,
  conteudo              text,
  user_agent            text,

  status_qualificacao   text not null check (status_qualificacao in ('PRIORITARIO','ACOMPANHAR','NAO_ELEGIVEL')),
  status_atendimento    text not null default 'NOVO',
  observacoes           text
);

create index if not exists idx_pc_cg2027_qualif on public.pre_cadastro_cg2027 (status_qualificacao);
create index if not exists idx_pc_cg2027_criado on public.pre_cadastro_cg2027 (criado_em desc);

-- Tabela fica fechada para acesso público (RLS ligado, sem policies).
-- Só o n8n grava, usando conexão Postgres direta / service role.
alter table public.pre_cadastro_cg2027 enable row level security;

-- ---------------------------------------------------------------------
-- Regras de classificação
--   PRIORITARIO : CNH A = Sim + início em novembro ou 30 dias
--                 + cidade Americana/SBO/Nova Odessa + consentimento
--   ACOMPANHAR  : CNH A = Sim e qualquer outro caso
--   NAO_ELEGIVEL: CNH A = Não
--   EAR nunca elimina (só informação)
-- ---------------------------------------------------------------------
create or replace function public.classificar_pre_cadastro(
  p_cnh_a text, p_previsao text, p_cidade text, p_consent boolean
) returns text language sql immutable as $$
  select case
    when p_cnh_a = 'Não' then 'NAO_ELEGIVEL'
    when p_cnh_a = 'Sim'
     and p_previsao in ('Em novembro, assim que estiver disponível','Nos próximos 30 dias')
     and p_cidade in ('Americana','Santa Bárbara d''Oeste','Nova Odessa')
     and p_consent then 'PRIORITARIO'
    else 'ACOMPANHAR'
  end
$$;

-- ---------------------------------------------------------------------
-- Upsert: recebe o JSON do formulário (já validado no n8n)
--   - novo telefone  -> insere
--   - telefone já existe -> atualiza respostas com as mais recentes,
--     mantém criado_em, incrementa envios, grava atualizado_em,
--     consentimento vale o último envio,
--     NUNCA mexe em status_atendimento nem observacoes
-- ---------------------------------------------------------------------
create or replace function public.upsert_pre_cadastro_cg2027(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_status text;
  v_id bigint;
  v_novo boolean;
begin
  v_status := classificar_pre_cadastro(p->>'cnh_a', p->>'previsao_inicio', p->>'cidade', (p->>'consentimento')::boolean);

  insert into pre_cadastro_cg2027 as t (
    nome, estado_civil, whatsapp_original, whatsapp_normalizado, email,
    cnh_a, ear, atividade_app, previsao_inicio, cidade,
    consentimento, consentimento_texto, consentimento_versao, consentimento_em,
    origem, campanha, conteudo, user_agent, status_qualificacao
  ) values (
    p->>'nome', p->>'estado_civil', p->>'whatsapp_original', p->>'whatsapp_normalizado', nullif(p->>'email',''),
    p->>'cnh_a', p->>'ear', p->>'atividade_app', p->>'previsao_inicio', p->>'cidade',
    (p->>'consentimento')::boolean, p->>'consentimento_texto', p->>'consentimento_versao', now(),
    p->>'origem', p->>'campanha', p->>'conteudo', left(p->>'user_agent',300), v_status
  )
  on conflict (whatsapp_normalizado) do update set
    atualizado_em        = now(),
    envios               = t.envios + 1,
    nome                 = excluded.nome,
    estado_civil         = excluded.estado_civil,
    whatsapp_original    = excluded.whatsapp_original,
    email                = coalesce(excluded.email, t.email),
    cnh_a                = excluded.cnh_a,
    ear                  = excluded.ear,
    atividade_app        = excluded.atividade_app,
    previsao_inicio      = excluded.previsao_inicio,
    cidade               = excluded.cidade,
    consentimento        = excluded.consentimento,
    consentimento_texto  = excluded.consentimento_texto,
    consentimento_versao = excluded.consentimento_versao,
    consentimento_em     = now(),
    origem               = coalesce(excluded.origem, t.origem),
    campanha             = coalesce(nullif(excluded.campanha,''), t.campanha),
    conteudo             = coalesce(nullif(excluded.conteudo,''), t.conteudo),
    user_agent           = excluded.user_agent,
    status_qualificacao  = excluded.status_qualificacao
    -- status_atendimento e observacoes ficam intocados
  returning id, (xmax = 0) into v_id, v_novo;

  return jsonb_build_object('id', v_id, 'novo', v_novo, 'status_qualificacao', v_status);
end
$$;

revoke all on function public.upsert_pre_cadastro_cg2027(jsonb) from public, anon, authenticated;

-- Visão rápida para o Rico / Hermes
create or replace view public.vw_pre_cadastro_cg2027_resumo as
select status_qualificacao, cidade, count(*) as total
from public.pre_cadastro_cg2027
group by 1,2 order by 1,2;
