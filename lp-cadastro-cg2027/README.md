# LP de pré-cadastro · Honda CG Start 2027 · Loka Motoka

Página estática + gravação no Supabase via n8n. Pronta para deploy em `https://cadastro.lokamotoka.com.br`.

## Conteúdo

| Caminho | O que é |
|---|---|
| `index.html` | Página completa (HTML/CSS/JS num arquivo só, sem framework) |
| `assets/` | Logo e imagem das motos (recortadas dos criativos aprovados) |
| `infra/schema.sql` | Tabela `pre_cadastro_cg2027`, função de classificação e função de upsert |
| `infra/n8n-workflow-pre-cadastro-cg2027.json` | Workflow n8n (importar **desativado**) |
| `infra/nginx-cadastro.lokamotoka.com.br.conf` | Server block Nginx (+ equivalente Caddy) e limite de envios no webhook |

## Deploy (Hermes)

1. **Supabase**: rodar `infra/schema.sql` no SQL editor. Tabela fica com RLS ligado e sem policies: só o n8n grava.
2. **n8n**: importar o workflow, configurar a credencial Postgres do Supabase no nó "Supabase · upsert", **ativar só depois do teste**.
   URL de produção do webhook: `https://<seu-n8n>/webhook/pre-cadastro-cg2027`.
3. **index.html**: trocar `CONFIG.webhookUrl` (início do `<script>`) pela URL real do webhook.
   Enquanto tiver `SEU-N8N` na URL, a página roda em **modo prévia**: não envia nada, só mostra o sucesso e loga o payload no console.
4. **Servidor**: copiar `index.html` e `assets/` para `/var/www/cadastro.lokamotoka.com.br`, aplicar a config Nginx/Caddy no mesmo padrão do `privacidade.lokamotoka.com.br`, emitir HTTPS (Let's Encrypt).
5. **Rate limit**: aplicar o `limit_req` do arquivo Nginx na rota do webhook (5 envios/min por IP).
6. **Teste**: enviar um cadastro real pelo celular, conferir a linha no Supabase, apagar o teste.

Não alterar rotas do n8n de produção nem do Evolution API. Nenhuma mensagem de WhatsApp é disparada por este fluxo.

## Regras de negócio (implementadas no banco)

**Classificação** (`classificar_pre_cadastro`)
- `PRIORITARIO`: CNH A = Sim + início "Em novembro" ou "Nos próximos 30 dias" + Americana / Santa Bárbara d'Oeste / Nova Odessa + consentimento
- `ACOMPANHAR`: CNH A = Sim e qualquer outro caso (inclui "Outra cidade" e início em 2-3 meses/pesquisando)
- `NAO_ELEGIVEL`: CNH A = Não
- EAR nunca elimina; é só informação

**Deduplicação** (`upsert_pre_cadastro_cg2027`, chave `whatsapp_normalizado`)
- Reenvio atualiza as respostas com as mais recentes, mantém `criado_em`, incrementa `envios`, grava `atualizado_em`
- Consentimento vale o último envio (texto, versão, data)
- `status_atendimento` e `observacoes` **nunca** são sobrescritos
- E-mail vazio no reenvio não apaga o e-mail anterior

**Consentimento**: obrigatório no front, no n8n e no banco (`check consentimento = true`).

## Medição sem Pixel

A página lê UTMs da URL e grava em `origem`, `campanha`, `conteudo`. Use links assim nos stories:

```
https://cadastro.lokamotoka.com.br/?utm_source=story&utm_content=v1
https://cadastro.lokamotoka.com.br/?utm_source=story&utm_content=v2
https://cadastro.lokamotoka.com.br/?utm_source=bio
https://cadastro.lokamotoka.com.br/?utm_source=whatsapp&utm_campaign=indicacao
```

Resumo rápido: `select * from vw_pre_cadastro_cg2027_resumo;`

## Segurança e LGPD

- Honeypot (`empresa`) + tempo mínimo de preenchimento (4 s) descartam bots em silêncio
- Validação completa no n8n e constraints no banco
- Sem Pixel, Analytics ou cookies de rastreamento
- Nginx sem access log; n8n não salva execuções de sucesso (`saveDataSuccessExecution: none`)
- Política: https://privacidade.lokamotoka.com.br/
