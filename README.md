# build-iso — ISO de teste do Big WindowMaker

Pipeline do GitHub Actions que gera a ISO live da edição **Big WindowMaker**
(`bigcommunity/wmaker`) da BigCommunity, usando o motor de ISO da BigLinux
sem modificá-lo.

> **IMPORTANTE — sessão live.** A sessão live só chega ao Window Maker com o
> patch do `biglinux-livecd` que está no branch
> [`window-maker` de big-windowmaker/biglinux-livecd](https://github.com/big-windowmaker/biglinux-livecd/tree/window-maker)
> (o `startbiglive` passa a executar `startbigwm`). Enquanto esse patch não
> entrar no `biglinux-livecd` da BigLinux e chegar aos repositórios, a ISO
> **entra em loop no login**: o autologin abre a sessão `livecd`, o assistente
> termina e o display manager é reiniciado em vez de abrir o Window Maker.
> O smoke test detecta isso e **reprova a ISO por padrão**
> (`require_livecd_patch: true`).

> **IMPORTANTE — somente teste.** Os pacotes do Big WindowMaker ainda não
> estão em nenhum repositório público assinado. Esta ISO usa um repositório
> local **não assinado** (`[bigwm-local]`), montado com os artefatos de CI de
> outros repositórios. As ISOs geradas aqui são para teste e são publicadas,
> quando publicadas, apenas como *pre-release*. Não há assinatura da ISO
> nesta fase.

## O que o workflow faz

`.github/workflows/build-iso.yml` — gatilhos: `workflow_dispatch` e agendamento
semanal (segunda-feira, 05:17 UTC, ISO *testing* com os valores padrão).

| Job | Privilégios | O que faz |
|---|---|---|
| `lint` | `contents: read`, sem contêiner | Valida as entradas (regex/allowlist); faz checkout de `big-windowmaker/iso-profiles` no ref pedido e fixa o SHA resultante para os jobs seguintes; confere os links simbólicos de `bigcommunity/wmaker` (`scripts/check-symlinks.sh`); confere que os pacotes esperados estão em `Packages-Desktop`; roda `pytest tests/` do iso-profiles; `bash -n` e `shellcheck` em `scripts/`. |
| `local-repo` | `contents: read`, `actions: read` | Baixa os pacotes dos artefatos de CI (`scripts/fetch-package-artifacts.sh`), monta o repositório `[bigwm-local]` com `repo-add` num contêiner Manjaro **sem rede** (`scripts/make-local-repo.sh`) e o publica como artefato (retenção de 3 dias). |
| `build` | `contents: read`; contêiner `--privileged` | Roda `build-iso/build-iso.sh` de `biglinux/iso-profiles` **fixado por commit** (`ENGINE_SHA`) no **mesmo contêiner, fixado pelo mesmo digest**, que o workflow *Build ISO* da BigLinux usa, com `PROFILES_ROOT` apontando para o checkout dos perfis, `DISTRONAME=bigcommunity`, `EDITION=wmaker`. Injeta `[bigwm-local]` logo antes do `buildiso` (`scripts/run-engine.sh`). Gera `.iso`, `.iso.sha256`, `.iso.pkgs` (lista de pacotes), o manifesto do repositório local e `.build-info` (commits do motor e dos perfis); confere que a ISO recebeu as versões do repositório local (`scripts/check-iso-packages.sh`). Artefato com retenção de 3 dias. |
| `smoke-test` | `contents: read` | Boot da ISO em QEMU/KVM, BIOS e UEFI (OVMF), até a sessão live, e prova de que a sessão Window Maker é utilizável (`scripts/smoke-test.sh`; critérios abaixo). Logs e capturas de tela ficam como artefato por 7 dias. |
| `release` | `contents: write`, environment `iso-release` | Só em `workflow_dispatch` com `publish: true` e depois do smoke test aprovado nos dois firmwares: confere o sha256, gera `SHA256SUMS`, divide a ISO em partes 7z se passar de 2 GiB (limite por asset) e cria uma **pre-release** com `gh release create`. |

Entradas do `workflow_dispatch`:

| Entrada | Valores | Padrão |
|---|---|---|
| `branch` | `testing`, `stable` (repositórios BigCommunity/BigLinux) | `testing` |
| `kernel` | `lts`, `oldlts`, `latest`, `big` (seletores do motor) | `lts` |
| `profiles_ref` | branch, tag ou SHA de `big-windowmaker/iso-profiles` | `wmaker-edition` |
| `require_livecd_patch` | reprovar se o `biglinux-livecd` não tiver o patch | `true` |
| `publish` | publicar como pre-release | `false` |

O Manjaro é sempre `stable`. Nome gerado pelo motor:
`bigcommunity_TESTING_wmaker_<data>_k<kernel>.iso` (testing) ou
`bigcommunity_wmaker_<data>_k<kernel>.iso` (stable).

### Fontes dos pacotes (uma variável)

As fontes do repositório local estão **numa única variável**, `PACKAGE_SOURCES`,
no topo do workflow — uma fonte por linha, `<dono/repo> <workflow> <artefato>`:

```text
big-windowmaker/big-wm    ci.yml     big-wm-packages
big-windowmaker/packages  build.yml  packages-windowmaker
big-windowmaker/packages  build.yml  packages-wlmaker
big-windowmaker/packages  build.yml  packages-big-dockapps
```

`big-windowmaker/packages` publica um artefato por diretório de pacote
(`packages-<diretório>`). `EXPECTED_PACKAGES` lista o que precisa sair do
repositório local e estar na ISO (big-wm-session, big-wm-wayland,
big-wm-themes, windowmaker, wlmaker, wmcpuload, wmbattery, wmusic, wmudmount,
wmshutdown, wmmoonclock); faltar qualquer um é erro.

Para cada fonte, `fetch-package-artifacts.sh` escolhe o artefato mais recente
que: tem o nome exato e não expirou; vem de um run do workflow indicado; do
evento `push` no branch `main`; concluído com `success`; e cujo
`head_repository` é o próprio repositório (exclui PRs de forks, que também
podem ter `head_branch == main`). O zip baixado precisa ter o sha256 igual ao
`digest` informado pela API e conter só arquivos simples. A proveniência
(repositório, run, commit, digest) vai para `bigwm-local.sources.tsv`, que
acompanha a ISO.

## Como o repositório local é injetado

O `buildiso` (manjaro-tools) monta os chroots da ISO com
`/usr/share/manjaro-tools/pacman-multilib.conf` (x86_64; `pacman-default.conf`
nas outras arquiteturas) — ver `get_pacman_conf` em `lib/util-iso.sh` do
manjaro-tools. Esses arquivos:

1. pertencem ao pacote `manjaro-tools-base-git`, que o motor atualiza/instala
   em `prepare_host` (`pacman -Syu` e `pacman -S --needed manjaro-tools-*`):
   uma atualização substitui os arquivos e apagaria uma injeção feita antes do
   motor;
2. recebem, em `configure_build_repos`, `[biglinux-priority]` (antes de
   `[core]`) e as seções `community-*`/`biglinux-*` (`append_build_repos`);
3. não são mais tocados até o `buildiso`, que os passa ao `mkchroot`/`basestrap`
   (`-C`).

Por isso `scripts/run-engine.sh` carrega o motor com `source` (interface que o
motor suporta: é como os testes dele o usam), confere que `main()` chama
`prepare_host` → `configure_build_repos` → `run_build` nessa ordem, embrulha
`run_build` e chama o `main()` original. Imediatamente antes do `buildiso`:

- `scripts/inject-local-repo.sh` insere, **acima de todas as seções** (o pacman
  usa o primeiro repositório que tem o pacote, e o nosso `windowmaker` precisa
  vencer o do `[extra]`):

  ```ini
  [bigwm-local]
  SigLevel = Optional TrustAll
  Server = file:///srv/bigwm-local
  ```

  e recusa o arquivo se `TrustAll` aparecer em qualquer outra seção;
- `scripts/preflight-local-repo.sh` sincroniza os bancos num `dbpath`
  temporário e confere que cada pacote do manifesto resolve a partir de
  `[bigwm-local]` — falha em segundos, não depois de uma hora de build.

O `file://` é lido pelo pacman do contêiner (o `basestrap` instala com
`pacman --root`), não de dentro do chroot. O único pacman que roda dentro de um
chroot (`copy_from_cache`, imagem mhwd) usa o `pacman.conf` do perfil, que não
recebe `[bigwm-local]`; pelo mesmo motivo **o repositório local não vai para a
ISO** (o `/etc/pacman.conf` instalado é o do perfil). Depois do build,
`check-iso-packages.sh` confere na lista `.pkgs` que a ISO tem exatamente as
versões do repositório local. Os pacotes de `Packages-Live` (o
`biglinux-livecd`) ficam na camada live (`livefs.sfs`) e não entram no
`.pkgs`: para eles o script extrai o `livefs.sfs` da ISO (`xorriso`) e procura
`var/lib/pacman/local/<nome>-<versão>` (`unsquashfs -l`).

## Smoke test: o que é verificado

Não é o gate openQA da BigLinux (que instala o sistema e abre aplicativos
pela árvore de acessibilidade). É um teste curto e autocontido, rodado para
`bios` (SeaBIOS) e `uefi` (OVMF sem Secure Boot), com KVM, 4 GiB de RAM e
`-no-reboot`:

1. O firmware dá boot pela ISO e o **GRUB da ISO** aparece; o script
   interrompe a contagem (tecla `Home`), abre a entrada padrão
   (`1 - Start BigCommunity`) e insere no topo
   `set kopts="${kopts} console=tty0 console=ttyS0,115200 systemd.journald.forward_to_console=1 systemd.debug_shell=ttyS1"`.
   Nenhum outro parâmetro muda; a ISO não é alterada. O debug shell existe só
   nesta VM de teste.
2. **Boot**: o debug shell responde na serial 1 → kernel, initramfs e systemd
   subiram pela entrada padrão.
3. **lightdm**: `lightdm.service` fica `active`.
4. **Xorg**: há um processo `Xorg`.
5. **Sessão live**: o logind tem uma sessão do usuário `community` (o
   autologin funcionou).
6. **Patch do livecd**: `/usr/bin/startbiglive` chama `startbigwm`. Sem o
   patch, reprova (ou vira aviso com `require_livecd_patch: false`).
7. **Window Maker**: depois de fechar o assistente live (simula o usuário
   concluindo-o), aparece um processo `wmaker` do usuário live. Vira aviso se o
   item 6 foi rebaixado e o patch não está presente.
8. **Tela**: a captura final tem ≥ 64 cores distintas (não é tela preta nem
   só texto).

**Sessão utilizável** (desligável com `--usability false`; só quando o item 7
passou). Os comandos rodam como o usuário live com o ambiente do próprio
processo `wmaker` (`DISPLAY`, `XAUTHORITY`, D-Bus), e as janelas são lidas do
servidor X pela EWMH com `scripts/smoke-x11-probe.py` (só libX11 via ctypes,
enviado à VM pela serial):

9. **EWMH**: `_NET_SUPPORTING_WM_CHECK` aponta para "Window Maker" (o WM
   gerencia o display `:0`).
10. **Dock**: wmclock, wmsystemtray, wmix, wmcpuload, wmmemload e wmnet
    rodando (AutoLaunch do `WMState` padrão).
11. **Menu raiz**: F12 abre o menu do Window Maker (a tela muda).
12. **Terminal**: `xdg-terminal-exec` abre uma janela nova gerenciada pelo WM
    e ela **aparece na tela** (`terminal-visivel`: a captura de antes e a de
    depois diferem em pelo menos `SMOKE_MIN_WINDOW_BYTES` bytes — uma janela
    mapeada que o compositor não desenha reprova).
13. **Instalador**: `calamares-biglinux_polkit` (o atalho de instalação da
    live) abre uma janela nova, que também precisa aparecer na tela
    (`instalador-visivel`).

Informativo: unidades systemd com falha e se o assistente estava rodando. O
artefato `smoke-<firmware>-<run>` guarda `serial0.log` (kernel + journal
completo), `serial1.log` (sondas), capturas `.ppm`/`.png` (menu do GRUB,
entrada editada, boot, final e `30-area-de-trabalho`, `31-menu-raiz`,
`32-terminal`, `33-instalador`), o comando do QEMU e `result.txt`.

Rodar localmente (sem root; precisa de `/dev/kvm`):

```bash
scripts/smoke-test.sh --iso bigcommunity_TESTING_wmaker_*.iso --firmware bios --out /tmp/smoke-bios
scripts/smoke-test.sh --iso bigcommunity_TESTING_wmaker_*.iso --firmware uefi --out /tmp/smoke-uefi \
  --ovmf-code /usr/share/edk2/x64/OVMF_CODE.4m.fd --ovmf-vars /usr/share/edk2/x64/OVMF_VARS.4m.fd
```

## Como executar

Pela aba *Actions* → *Build ISO* → *Run workflow*, ou:

```bash
gh workflow run build-iso.yml -R big-windowmaker/build-iso \
  -f branch=testing -f kernel=lts -f profiles_ref=wmaker-edition \
  -f require_livecd_patch=true -f publish=false
```

Antes de rodar, os CIs de origem precisam ter um run de push em `main` bem
sucedido com artefatos não expirados (ver *Limites*). O build leva de 1 a 4
horas.

## Configuração necessária do repositório

- **Environment `iso-release`** (*Settings → Environments*): revisor
  obrigatório e *Deployment branches* restrito a `main`. O job `release` só
  roda nele; sem o environment configurado, qualquer pessoa com permissão de
  disparar o workflow publicaria a pre-release.
- *Settings → Actions → General*: *Workflow permissions* = **read**
  (o workflow declara `permissions: {}` e concede o mínimo por job; só
  `release` recebe `contents: write`).
- **Secret opcional `ARTIFACTS_READ_TOKEN`**: token *fine-grained* (ou de um
  GitHub App) somente leitura de **Actions** em `big-windowmaker/big-wm` e
  `big-windowmaker/packages`. Usado só no job `local-repo` (ver *Limites*).
- Proteção do branch `main` e `CODEOWNERS` (regra 8 do relatório 04).
- Dependabot (`.github/dependabot.yml`) mantém os SHAs das actions.

## Fase 1 e fase 2

Conforme o relatório 04 (seções 4 e 7) e a ADR-0001 (D5):

**Fase 1 (agora).** A edição `bigcommunity/wmaker` vive no fork
`big-windowmaker/iso-profiles` (branch `wmaker-edition`) até ser aceita em
`big-comm/iso-profiles`; os pacotes genéricos devem ir para os repositórios
`community-*`, assinados pela BigCommunity. Enquanto isso não acontece, este
repositório gera **apenas ISOs de teste** com o repositório local não
assinado. Nenhum segredo é usado no build; a ISO tem `.sha256` e
`SHA256SUMS`, sem assinatura.

**Fase 2.** Chave própria (primária offline, **subchave só de assinatura** com
validade no secret do environment `iso-release`), pacote `bigwm-keyring`,
repositório `bigwm-*` com banco assinado (`repo-add --sign`,
`SigLevel = Required` só nessas seções), `SHA256SUMS.sig`, atestado de
proveniência (`actions/attest-build-provenance`) e gate de boot obrigatório.
Com pacotes em repositório assinado, o job `local-repo`, a injeção e o
`TrustAll` deixam de existir; o ideal é que o motor da BigLinux ganhe suporte a
repositórios e keyrings extras (`EXTRA_REPOS`/`EXTRA_KEYRINGS`) e a um terceiro
produto, em vez da injeção feita aqui.

## Limites e riscos conhecidos

- **Artefatos entre repositórios.** O `GITHUB_TOKEN` é um token de instalação
  restrito a este repositório. Para repositórios públicos, listar artefatos e
  runs funciona até sem autenticação, mas **baixar o zip exige autenticação**
  (HTTP 401 anônimo); a documentação do `actions/download-artifact` pede um
  token com `actions: read` no repositório de origem. O job tenta com
  `ARTIFACTS_READ_TOKEN` e, se ele não existir, com o `GITHUB_TOKEN`; se o
  download falhar, configure o secret.
- **Retenção.** `big-wm` guarda o artefato por 7 dias e `packages` por 14. Sem
  push recente em `main`, não há artefato válido: rode o CI de origem de novo
  (o `ci.yml` do `big-wm` não tem `workflow_dispatch`; adicioná-lo facilitaria).
- **`packages` compila só o que mudou.** Cada artefato `packages-<dir>` é
  procurado separadamente; os pacotes podem vir de runs diferentes. Um run de
  `packages` com qualquer perna da matriz falhando não é aceito (exige-se
  `success` do run inteiro).
- **Pacotes não assinados.** `SigLevel = Optional TrustAll` vale só para
  `[bigwm-local]`, que só existe dentro do contêiner de build. Não reutilize o
  diretório do repositório como repositório remoto.
- **Motor e contêiner de terceiros.** O motor fica fixado por SHA
  (`ENGINE_SHA`), mas clona `biglinux/biglinux-key` e `big-comm/community-keyring`
  sem fixar commit e consulta kernel.org / `biglinux/linux-latest` para
  resolver o kernel. A imagem `xivastudio/biglinux_build_package` é a mesma da
  BigLinux, fixada pelo mesmo digest, mas não tem Dockerfile público. Ao
  atualizar `ENGINE_SHA`, copie o digest do `build-iso.yml` da BigLinux nesse
  commit e revise `build-iso/build-iso.sh` (o `run-engine.sh` falha se a ordem
  das etapas mudar).
- **Sem gate de instalação.** O smoke test não instala o sistema nem testa o
  Calamares. A edição do GRUB por teclas depende do layout do `kernels.cfg`
  do perfil (`boot_<distro> ... ${kopts}`); se o perfil mudar isso, o teste
  falha em "boot" e as capturas `01-grub-menu`/`02-grub-editada` mostram o
  motivo.
- **Tamanho e tempo.** ISO de ~5 GB (dividida em partes 7z na release), build
  de 1–4 h (timeout de 300 min), disco de `/mnt` do runner hospedado.

## Atualizar fixações

```bash
# Motor da BigLinux
gh api repos/biglinux/iso-profiles/commits/main --jq .sha
# SHA de uma action (tags anotadas precisam ser desreferenciadas)
tag=$(gh api repos/actions/checkout/releases/latest --jq .tag_name)
gh api repos/actions/checkout/git/ref/tags/$tag --jq '.object'
```

## Licença

GPL-3.0 (mesma licença do motor `biglinux/iso-profiles`, do qual os scripts
derivam); ver `LICENSE`.
