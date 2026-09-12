# Protótipo de UI — versão final

**Descartável.** Não é código de produção, não tem testes, não entra no app.

## Rodar

```sh
python3 -m http.server -d prototype/ui 8000
# abra http://localhost:8000/app.html
```

Ou duplo clique em `app.html` (alguns navegadores bloqueiam
`history.replaceState` em `file://`; a navegação continua).

## `app.html` — protótipo final

Direção: **Editorial Cinema** (variante C) com **Cinemascope de sangria no
Remote**, paleta escura com **acento testável** e vidro discreto.

### Telas (abas do topo)

Home · Detalhe (série) · Detalhe (filme) · Busca vazia · Busca carregando ·
Busca resultados · Minha Lista · Perfil · Remote · Grade · Ajustes · Home rows ·
Conectar · Conectar (escaneando).

### Remote — Cinemascope com sangria

O backdrop 16:9 ocupa o topo **em sangria total**, com scrim e o título serifado
sobre a arte. Seek e transporte logo abaixo; **volume, legendas, “a seguir”,
Navigate e campo de texto ficam fora da primeira dobra** (só rolam até lá).
Fundo com blur sutil da própria capa (duas camadas: cheia `opacity .09` + halo
`opacity .2`).

### Acento testável

A pílula flutuante tem **7 opções de cor** (bolinhas), navegáveis também por
`←` / `→`, e o estado é compartilhável via `?accent=`:

`indigo` (padrão) · `violet` · `gold` · `coral` · `teal` · `green` · `sky`

O acento é aplicado em runtime numa variável CSS (`--accent`) e as variações
(`--accent-2`, `--accent-dim`, `--accent-line`, `--accent-ink`) derivam dela com
`color-mix`. Muda botões primários, progresso, item ativo da nav, switches,
toggles, réguas e o botão central do transporte.

## Outros arquivos

- **`cinematic-hero.html`** — primeira rodada, com as 3 variantes estruturais
  (A/B/C). Guardado como referência da decisão.

## Dados

Baseados nos seus prints (Paradise Hotel, Coyote vs. Acme, Hacks, Upcoming,
menotifilho, stremio, Settings). Posters/backdrops são placeholders do
`picsum.photos` — caem para um gradiente sem rede.

## Contexto no código real

`Meta.background` (backdrop 16:9) **já existe** em `lib/app/home/meta.dart` e
**não é renderizado em nenhuma tela** — é o que o Cinemascope coloca em
destaque.
