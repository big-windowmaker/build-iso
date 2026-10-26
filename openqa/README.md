# Teste de instalação (harness openQA da BigLinux + overlay do Big WindowMaker)

O job `install-test` do `build-iso.yml` e o `scripts/install-test.sh` instalam
a ISO de verdade numa VM e iniciam o sistema instalado:

1. boot da ISO (GRUB → entrada padrão) e login no console serial `hvc0` com o
   usuário live (`community`/`big`);
2. **assistente live** (GTK4): idioma por busca ("Brazil"), teclado e estilo de
   tema claro/escuro — a edição Window Maker é um ambiente "simplificado",
   sem a etapa de layout do Plasma;
3. **sessão live Window Maker** (`bigwm_live_session`): `wmaker` iniciado por
   `startbigwm`, `big-wm-session.target` e `graphical-session.target` ativos,
   `XDG_CURRENT_DESKTOP=WindowMaker`, os seis dockapps padrão rodando e um
   terminal (`xdg-terminal-exec`) abrindo janela acessível;
4. **Calamares** (`calamares-biglinux_polkit`): lançador GTK (aviso de UEFI,
   "Instalar", dicas), Calamares Qt, localização, teclado, **"Apagar disco"**
   (particionamento automático), usuário `openqa` com senha aleatória, resumo,
   instalação até o botão "Reiniciar o sistema";
5. **reinício pelo disco instalado** (o próprio Calamares reinicia; a ISO
   continua no drive e o QEMU só dá boot por ela uma vez) e login no console
   serial com a conta criada;
6. **LightDM**: `lightdm` e `slick-greeter` rodando, senha digitada no
   greeter, sessão gráfica X11 ativa do usuário com `wmaker`;
7. **sessão instalada** (`bigwm_installed_session`): a sessão padrão é a
   `big-wm` (`startbigwm`, não o `wmaker.desktop` genérico), Dock completo,
   terminal abre janela; a configuração do LightDM vai para os logs;
8. **métricas** (`bigwm_metrics`, informativo): saída literal de
   `scripts/vm-metrics.sh` como root — `systemd-analyze` e `blame`, `free -m`,
   número de processos, RSS dos processos do usuário e do `wmaker`, unidades
   com falha do sistema e do usuário, `journalctl -b -p err`, `coredumpctl
   list`, `df -h /` — logo depois do login e de novo (memória) após
   `BIGWM_IDLE_SECONDS` (300) ocioso; em `ulogs/bigwm-metrics-installed-*.txt`;
9. **saúde** (`installed_health`): raiz num dispositivo real (não overlay),
   `/etc/big-release`, **nenhuma unidade systemd com falha**, e em UEFI
   `/boot/efi` montado e entrada no `efibootmgr`;
10. **segurança** (`installed_security`, não bloqueante): postura registrada
    como *softfail*.

Cada passo lê a árvore de acessibilidade (AT-SPI) e o console serial; não há
*needles* (comparação de imagem). Capturas de tela e vídeo são só evidência.

## Por que o harness da BigLinux

A BigLinux já valida as ISOs dela instalando pelo Calamares com
[os-autoinst](https://github.com/os-autoinst/os-autoinst) (`isotovideo`, o
motor do openQA, sem servidor), dirigindo o instalador pelo AT-SPI. O
Calamares, o lançador e o assistente live da BigCommunity são os mesmos
(`biglinux-livecd`, perfil `bigcommunity`). Reaproveitar esse harness — cerca
de 5 mil linhas, com a sonda AT-SPI já calibrada contra o Calamares — é mais
simples e mais robusto do que escrever outro.

## Como o harness é montado

Nada da BigLinux é copiado para este repositório. `scripts/install-test.sh`:

1. obtém `biglinux/iso-profiles` no commit fixado em
   [`upstream.env`](upstream.env) (`UPSTREAM_SHA`; o mesmo `ENGINE_SHA` do
   build) — no CI por `actions/checkout`, localmente por `git fetch`;
2. extrai só `openqa/` e `data/` para `<out>/harness`;
3. aplica [`patches/`](patches) com `patch --fuzz=0` (falha se o trecho mudou
   no upstream);
4. copia [`overlay/`](overlay) por cima;
5. chama o `openqa/production/run-plan.sh` da BigLinux, que roda o
   `isotovideo` no contêiner fixado por digest (`OPENQA_IMAGE`) com
   `/dev/kvm`, e gera o relatório (`report/RESULTADO.md`, em português).

### Patches (mudanças mínimas, todas com padrão igual ao comportamento da BigLinux)

| Patch | Arquivo(s) | Por quê |
|---|---|---|
| `0001-live-credentials` | `openqa/lib/biglinux.pm` | O usuário live era fixo `biglinux`/`biglinux`; vira `BIGLINUX_LIVE_USER`/`BIGLINUX_LIVE_PASSWORD` (BigCommunity: `community`/`big`). |
| `0002-simplified-wizard-optional-orca` | `openqa/tests/live_desktop.pm` | Com `BIGLINUX_WIZARD_SIMPLIFIED=1`, o assistente é idioma → teclado → "Escolha um estilo de tema" (sem a etapa de layout do Plasma). `BIGLINUX_ORCA=0` não inicia o Orca (a verificação de fala é do gate de acessibilidade da BigLinux, fora do escopo aqui). |
| `0003-x11-session` | `data/desktop_session.py`, `openqa/lib/atspi.pm` | O harness exige sessão Wayland; com `BIGLINUX_SESSION_TYPE=x11` exige uma sessão X11 (`DISPLAY` local, socket `/tmp/.X11-unix/X<n>`) e recusa Wayland. |
| `0004-installed-display-manager` | `openqa/lib/installed_system.pm` | `sddm`, `sddm-greeter`, `plasmashell` e `Type=wayland` viram `BIGLINUX_DISPLAY_MANAGER`, `BIGLINUX_GREETER`, `BIGLINUX_DESKTOP_SHELL` e `BIGLINUX_SESSION_TYPE` (aqui: `lightdm`, `slick-greeter`, `wmaker`, `x11`). |
| `0005-run-plan-setting` | `openqa/production/run-plan.sh` | `--setting KEY=VALUE` para ajustes locais (por exemplo `STORAGE_KEEP_FREE_RATIO=0` num `/tmp` pequeno). |

Os patches são candidatos a contribuição para a BigLinux: não mudam nada
quando as variáveis não são definidas.

### Overlay (arquivos nossos)

| Arquivo | Conteúdo |
|---|---|
| `overlay/openqa/main.pm` | Substitui o `main.pm`: schedules `bigwm_live`, `bigwm_install` e `generic_install` (outras edições, sem os módulos `bigwm_*`). Fora: `applications`, `installed_reader`, `installed_critical_apps`, `nonvisual_tasks`, `installed_brave` (dependem do Plasma/política KDE ou do Orca). |
| `overlay/openqa/release-gate.yaml` | Substitui o `release-gate.yaml`: planos `live`, `bios` e `uefi`, disco de 30 GiB e as configurações da edição acima. |
| `overlay/openqa/lib/bigwm.pm` | Verificações da sessão Window Maker. |
| `overlay/openqa/tests/bigwm_live_session.pm`, `bigwm_installed_session.pm` | Módulos da sessão live e da instalada. |
| `overlay/openqa/tests/bigwm_metrics.pm` | Métricas do sistema instalado. |
| `scripts/vm-metrics.sh` (copiado para `data/`) | Coleta de métricas, a mesma do smoke test. |

## Rodar localmente

Requisitos: `docker` (usuário no grupo `docker`), `/dev/kvm` acessível, `git`,
`patch`, `ruby`, `python3` ≥ 3.11 e ~25 GiB livres no diretório de saída
(ISO à parte). Não precisa de root.

```bash
# BIOS
scripts/install-test.sh --iso bigcommunity_wmaker_*.iso --plan bios --out /var/tmp/install-bios

# UEFI (OVMF sem Secure Boot; caminhos do Arch/Manjaro)
scripts/install-test.sh --iso bigcommunity_wmaker_*.iso --plan uefi --out /var/tmp/install-uefi \
  --ovmf-code /usr/share/edk2/x64/OVMF_CODE.4m.fd --ovmf-vars /usr/share/edk2/x64/OVMF_VARS.4m.fd

# Só a sessão live (alguns minutos)
scripts/install-test.sh --iso bigcommunity_wmaker_*.iso --plan live --out /var/tmp/install-live
```

Num disco pequeno (por exemplo um `/tmp` em tmpfs), o os-autoinst recusa o
disco de 30 GiB; acrescente `--setting STORAGE_KEEP_FREE_RATIO=0` (o qcow2 é
esparso e a instalação ocupa ~15 GiB). Outras edições BigCommunity, para
desenvolver o harness: `--setting BIGLINUX_SCHEDULE=generic_install
--setting BIGLINUX_DESKTOP_SHELL=xfce4-panel`.

Resultado em `<out>/artifacts`: `report/RESULTADO.md` (veredito por módulo),
`testresults/` (capturas `*.png` e saída de cada passo), `ulogs/` (inclui
`calamares-session.log`, processos e configuração do LightDM),
`autoinst-log.txt`, `virtio_console.log` e `video.ogv`. O código de saída é o
do `isotovideo` (0 aprovado, 101 algum módulo falhou). O disco do convidado é
apagado no fim (`--keep-disk` para mantê-lo).

## Limites

- **Imagem do contêiner.** A BigLinux usa um espelho privado em `ghcr.io`; o
  digest dela já foi removido do registry do openSUSE, que guarda poucas
  versões. O nosso digest também pode sumir: o job falha no `docker pull` e é
  preciso escolher outro (comandos em `upstream.env`) ou espelhar a imagem num
  registry próprio.
- **Acessibilidade como interface.** O harness encontra telas e botões pelos
  nomes acessíveis (inglês e português). Um texto renomeado no Calamares ou no
  assistente quebra o teste até a lista do `calamares.pm`/`live_desktop.pm`
  ser atualizada (patch aqui ou contribuição na BigLinux).
- **Fora do escopo:** fala do Orca, auditoria de todos os `.desktop`, Wayland
  (`big-wm-wayland`), particionamento manual, criptografia.

## Atribuição e licença

O harness (`openqa/`, `data/`) é da BigLinux, em
[biglinux/iso-profiles](https://github.com/biglinux/iso-profiles), sob
GPL-2.0-or-later nos arquivos (repositório GPL-3.0). Os patches e o overlay
seguem a mesma licença dos arquivos que alteram (GPL-2.0-or-later), para
poderem voltar à BigLinux.
