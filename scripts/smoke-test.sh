#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# smoke-test.sh - teste de fumaça da ISO live do Big WindowMaker em QEMU.
#
# Inicializa a ISO sem interface gráfica (BIOS/SeaBIOS ou UEFI/OVMF), pelo
# caminho real do usuário: firmware -> GRUB da ISO -> entrada padrão
# "1 - Start ...". Não é o gate openQA da BigLinux (que instala o sistema e
# abre aplicativos pela árvore de acessibilidade); é um teste curto e
# autocontido que responde a uma pergunta: a sessão live chega ao Window Maker?
#
# Como a ISO não tem console serial, o script edita a entrada padrão do GRUB
# pelo QMP do QEMU (teclas simuladas) e só acrescenta parâmetros de
# diagnóstico à variável kopts (que o kernels.cfg do perfil põe no fim da linha
# do kernel), sem mudar nenhum outro parâmetro:
#
#   console=tty0 console=ttyS0,115200      log do kernel/journal na serial 0
#   systemd.journald.forward_to_console=1  journal completo na serial 0
#   systemd.debug_shell=ttyS1              shell root de depuração na serial 1
#
# O debug shell existe só nesta VM de teste (é um parâmetro de boot digitado
# aqui); a ISO não é alterada. Pela serial 1 o script executa as sondas abaixo
# e lê os marcadores BWM_*=valor que elas imprimem.
#
# Critérios de aprovação (todos obrigatórios, nesta ordem):
#   1. O QEMU não termina sozinho (usamos -no-reboot: reboot/triple fault = falha).
#   2. O debug shell responde na serial 1  -> o kernel e o systemd subiram a
#      partir da entrada padrão do GRUB (o GRUB/firmware funcionam).
#   3. lightdm.service fica "active".
#   4. Existe um processo Xorg.
#   5. Existe uma sessão do logind para o usuário live (autologin funcionou).
#   6. O biglinux-livecd instalado tem o patch do Window Maker (startbiglive
#      chama startbigwm). Sem ele a sessão live entra em loop no login.
#      Pode ser rebaixado a aviso com --require-livecd-patch false.
#   7. Depois de fechar o assistente live (simula o usuário concluindo-o),
#      surge um processo wmaker do usuário live. Se o critério 6 foi rebaixado
#      e o patch não está presente, este critério também vira aviso.
#   8. A captura de tela final tem conteúdo gráfico (>= SMOKE_MIN_COLORS cores
#      distintas; uma tela preta ou um console de texto tem poucas).
#
# Informativo (não reprova): unidades systemd com falha, presença do assistente.
#
# Saída em --out: serial0.log (kernel+journal), serial1.log (sondas),
# qmp.log, capturas *.ppm (e *.png quando o QEMU suporta), result.txt.
#
# Requisitos: qemu-system-x86_64, /dev/kvm (ou SMOKE_ALLOW_TCG=1, muito lento),
# OVMF para --firmware uefi. Não precisa de root.
set -euo pipefail

usage() {
    cat <<'EOF'
Uso: smoke-test.sh --iso ARQUIVO.iso --firmware bios|uefi --out DIR
                   [--ovmf-code OVMF_CODE.fd --ovmf-vars OVMF_VARS.fd]
                   [--require-livecd-patch true|false] [--live-user NOME]

Variáveis opcionais: SMOKE_BOOT_TIMEOUT (s, padrão 900), SMOKE_GRUB_WAIT
(s, padrão 45), SMOKE_MEMORY_MB (4096), SMOKE_CPUS (2), SMOKE_MIN_COLORS (64),
SMOKE_MONITOR_PORT (45454), SMOKE_SERIAL_PORT (45455), SMOKE_ALLOW_TCG (0).
EOF
}

iso="" firmware="" out="" ovmf_code="" ovmf_vars=""
require_patch=true
live_user=community

while (($#)); do
    case "$1" in
        --iso) iso=${2:?}; shift 2 ;;
        --firmware) firmware=${2:?}; shift 2 ;;
        --out) out=${2:?}; shift 2 ;;
        --ovmf-code) ovmf_code=${2:?}; shift 2 ;;
        --ovmf-vars) ovmf_vars=${2:?}; shift 2 ;;
        --require-livecd-patch) require_patch=${2:?}; shift 2 ;;
        --live-user) live_user=${2:?}; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

boot_timeout=${SMOKE_BOOT_TIMEOUT:-900}
grub_wait=${SMOKE_GRUB_WAIT:-45}
memory=${SMOKE_MEMORY_MB:-4096}
cpus=${SMOKE_CPUS:-2}
min_colors=${SMOKE_MIN_COLORS:-64}
mon_port=${SMOKE_MONITOR_PORT:-45454}
ser_port=${SMOKE_SERIAL_PORT:-45455}

log() { printf '[smoke %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf 'smoke-test.sh: erro: %s\n' "$*" >&2; exit 2; }

[[ -f "$iso" ]] || die "ISO não encontrada: $iso"
[[ -n "$out" ]] || die "--out é obrigatório"
case "$firmware" in bios | uefi) ;; *) die "--firmware deve ser bios ou uefi" ;; esac
case "$require_patch" in true | false) ;; *) die "--require-livecd-patch deve ser true ou false" ;; esac
[[ "$live_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "usuário live inválido: $live_user"
for n in "$boot_timeout" "$grub_wait" "$memory" "$cpus" "$min_colors" "$mon_port" "$ser_port"; do
    [[ "$n" =~ ^[0-9]+$ ]] || die "valor numérico inválido: $n"
done
command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 não instalado"

mkdir -p "$out"
out=$(cd "$out" && pwd)
# O caminho vai dentro de comandos JSON do QMP: nada de aspas ou barras invertidas.
[[ "$out" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "caminho de saída com caracteres não suportados: $out"

#--- QEMU ----------------------------------------------------------------------

if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    accel=kvm cpu_model=host
elif [[ "${SMOKE_ALLOW_TCG:-0}" == "1" ]]; then
    log "AVISO: sem /dev/kvm, usando TCG (muito lento)"
    accel=tcg cpu_model=max
else
    die "/dev/kvm indisponível (defina SMOKE_ALLOW_TCG=1 para emulação pura)"
fi

# As vírgulas são a sintaxe de opções do QEMU, não separadores de array.
# shellcheck disable=SC2054
qemu=(
    qemu-system-x86_64
    -name "bigwm-smoke-$firmware"
    -machine "q35,accel=$accel" -cpu "$cpu_model" -smp "$cpus" -m "$memory"
    -display none -vga std
    -no-reboot
    -drive "file=$iso,media=cdrom,readonly=on,if=none,id=cd0,format=raw"
    -device ide-cd,drive=cd0,bootindex=0
    -nic user,model=virtio-net-pci
    -qmp "tcp:127.0.0.1:$mon_port,server=on,wait=off"
    -serial "file:$out/serial0.log"
    -chardev "socket,id=ser1,host=127.0.0.1,port=$ser_port,server=on,wait=off,logfile=$out/serial1.log"
    -serial chardev:ser1
)

if [[ "$firmware" == "uefi" ]]; then
    [[ -f "$ovmf_code" && -f "$ovmf_vars" ]] || die "--ovmf-code e --ovmf-vars são obrigatórios para uefi"
    # Cópia gravável das variáveis: o QEMU recusa um arquivo somente leitura.
    install -m 0644 "$ovmf_vars" "$out/OVMF_VARS.fd"
    qemu+=(
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=$ovmf_code"
        -drive "if=pflash,format=raw,unit=1,file=$out/OVMF_VARS.fd"
    )
fi

printf '%q ' "${qemu[@]}" >"$out/qemu-command.txt"
echo >>"$out/qemu-command.txt"

: >"$out/serial1.log"
"${qemu[@]}" 2>"$out/qemu-stderr.log" &
qemu_pid=$!
mon_fd="" ser_fd=""
drain_pids=()

cleanup() {
    local pid
    if kill -0 "$qemu_pid" 2>/dev/null; then
        if [[ -n "$mon_fd" ]]; then
            printf '{"execute":"quit"}\n' >&"$mon_fd" || true
        fi
        sleep 2
        kill "$qemu_pid" 2>/dev/null || true
    fi
    for pid in "${drain_pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT

alive() {
    kill -0 "$qemu_pid" 2>/dev/null && return 0
    log "FALHA: o QEMU terminou antes do fim do teste (reboot, desligamento ou erro)"
    tail -n 20 "$out/qemu-stderr.log" >&2 || true
    exit 1
}

# Conecta numa porta TCP do QEMU (/dev/tcp do bash) e drena o que chega para
# um arquivo, para que o QEMU nunca bloqueie escrevendo nela. O número do
# descritor fica em OPEN_FD (um $(...) perderia o descritor aberto).
OPEN_FD=""
open_tcp() {
    local port=$1 log_file=$2 fd i
    for i in $(seq 1 100); do
        alive
        if { exec {fd}<>"/dev/tcp/127.0.0.1/$port"; } 2>/dev/null; then
            cat <&"$fd" >>"$log_file" 2>/dev/null &
            drain_pids+=($!)
            OPEN_FD=$fd
            return 0
        fi
        sleep 0.2
    done
    die "não foi possível conectar na porta $port do QEMU"
}

open_tcp "$mon_port" "$out/qmp.log"
mon_fd=$OPEN_FD

# QMP (JSON) em vez do monitor humano: sem eco de linha nem prompt.
qmp() { printf '%s\n' "$1" >&"$mon_fd"; }
qmp '{"execute":"qmp_capabilities"}'

sendkey() {
    # "shift-minus" -> teclas simultâneas shift + minus (nomes QKeyCode).
    local keys="" code
    local -a codes
    IFS=- read -r -a codes <<<"$1"
    for code in "${codes[@]}"; do
        keys+="${keys:+,}{\"type\":\"qcode\",\"data\":\"$code\"}"
    done
    qmp "{\"execute\":\"send-key\",\"arguments\":{\"keys\":[$keys]}}"
    sleep "${SMOKE_KEY_DELAY:-0.1}"
}

# Digita texto ASCII simples pelo teclado virtual (layout US do GRUB).
type_text() {
    local text=$1 i ch key
    for ((i = 0; i < ${#text}; i++)); do
        ch=${text:i:1}
        case "$ch" in
            [a-z0-9]) key=$ch ;;
            [A-Z]) key="shift-${ch,,}" ;;
            ' ') key=spc ;;
            '=') key=equal ;;
            ',') key=comma ;;
            '.') key='dot' ;;
            '-') key=minus ;;
            '_') key=shift-minus ;;
            '/') key=slash ;;
            '"') key=shift-apostrophe ;;
            '$') key=shift-4 ;;
            '{') key=shift-bracket_left ;;
            '}') key=shift-bracket_right ;;
            *) die "caractere não suportado em type_text: $ch" ;;
        esac
        sendkey "$key"
    done
}

screendump() {
    local name=$1 file="$out/$1.ppm" i
    rm -f "$file"
    qmp "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$file\"}}"
    for i in $(seq 1 50); do
        [[ -s "$file" ]] && break
        sleep 0.2
    done
    sleep 0.5
    qmp "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$out/$name.png\",\"format\":\"png\"}}"
}

# Número de cores distintas numa captura PPM (P6) gerada pelo QEMU.
count_colors() {
    local file=$1 header
    [[ -s "$file" ]] || { echo 0; return; }
    header=$(head -n 3 "$file" | wc -c)
    tail -c "+$((header + 1))" "$file" | od -An -v -tx1 -w3 | sort -u | wc -l
}

#--- 1. GRUB: parar a contagem, editar a entrada padrão ------------------------

log "QEMU iniciado ($firmware, accel=$accel); aguardando o GRUB por ${grub_wait}s"
# "home" seleciona a primeira entrada e interrompe a contagem regressiva do
# GRUB; é inofensiva no SeaBIOS/OVMF. Enviada repetidamente porque não há como
# saber, sem console serial, o instante em que o menu aparece.
start=$SECONDS
while ((SECONDS - start < grub_wait)); do
    alive
    sendkey home
    sleep 2
done
screendump 01-grub-menu
sendkey e
sleep 2
# O editor abre com o cursor no início da primeira linha da entrada. Em vez de
# procurar a linha do "linux" (o corpo da entrada muda entre versões do GRUB e
# do perfil), inserimos no topo uma linha nova que acrescenta os parâmetros à
# variável kopts, que boot_<distro> (kernels.cfg do perfil) já coloca no fim da
# linha do kernel. "ret" quebra a linha: o set fica antes do resto da entrada.
for _ in $(seq 1 12); do
    sendkey up
done
sendkey home
extra_args="console=tty0 console=ttyS0,115200 systemd.journald.forward_to_console=1 systemd.debug_shell=ttyS1"
type_text "set kopts=\"\${kopts} $extra_args\""
sendkey ret
sleep 1
screendump 02-grub-editada
sendkey ctrl-x
log "Entrada padrão do GRUB iniciada com: $extra_args"

#--- 2. Debug shell na serial 1 ----------------------------------------------

# A saída da serial 1 já vai para serial1.log (logfile= do chardev).
open_tcp "$ser_port" /dev/null
ser_fd=$OPEN_FD

guest() { printf '%s\n' "$*" >&"$ser_fd"; }

# Os marcadores são impressos como "BWM""_X": o eco do terminal mostra as
# aspas, então só a saída real casa com BWM_X.
# Sem o marcador, imprime vazio (e não falha: o set -e encerraria o teste
# sem o relatório).
marker() { { tr -d '\r' <"$out/serial1.log" | grep -a -o "BWM_$1=[^[:space:]]*" | tail -n1 | cut -d= -f2-; } || true; }

deadline=$((SECONDS + boot_timeout))
log "Aguardando o debug shell na serial 1 (até ${boot_timeout}s)"
shell_ok=false
next_dump=$((SECONDS + 60))
n=0
while ((SECONDS < deadline)); do
    alive
    guest 'echo "BWM""_PING=ok"'
    sleep 10
    if [[ "$(marker PING)" == ok ]]; then
        shell_ok=true
        break
    fi
    if ((SECONDS >= next_dump)); then
        n=$((n + 1))
        screendump "10-boot-$n"
        next_dump=$((SECONDS + 60))
    fi
done

result_file="$out/result.txt"
: >"$result_file"
failures=0 warnings=0
record() { # status criterio detalhe
    printf '%-5s %-28s %s\n' "$1" "$2" "$3" | tee -a "$result_file"
    case "$1" in
        FAIL) failures=$((failures + 1)) ;;
        WARN) warnings=$((warnings + 1)) ;;
    esac
}

if ! $shell_ok; then
    screendump 90-final
    record FAIL boot "o debug shell não respondeu em ${boot_timeout}s (kernel/systemd não subiram ou a edição do GRUB falhou)"
    log "Últimas linhas da serial 0:"
    tail -n 40 "$out/serial0.log" | tr -d '\r' || true
    exit 1
fi
record PASS boot "kernel e systemd subiram pela entrada padrão do GRUB ($firmware)"

#--- 3. Sondas -----------------------------------------------------------------

# Comandos executados no convidado: as expansões são do shell de lá, por isso
# ficam entre aspas simples.
# shellcheck disable=SC2016
probe=(
    'stty -echo 2>/dev/null'
    'bwm_wait() { local t=$1; shift; while ((t-- > 0)); do "$@" >/dev/null 2>&1 && return 0; sleep 5; done; return 1; }'
    'bwm_yes() { "$@" >/dev/null 2>&1 && echo yes || echo no; }'
    'bwm_session() { loginctl list-sessions --no-legend | awk -v u="$1" '"'"'$3 == u {f=1} END {exit !f}'"'"'; }'
    'bwm_wait 60 systemctl is-active --quiet lightdm.service; echo "BWM""_DM=$(systemctl is-active lightdm.service)"'
    'bwm_wait 36 pgrep -x Xorg; echo "BWM""_XORG=$(bwm_yes pgrep -x Xorg)"'
    'bwm_wait 36 bwm_session LIVEUSER; echo "BWM""_SESSION=$(bwm_yes bwm_session LIVEUSER)"'
    'echo "BWM""_LIVECD_PATCH=$(bwm_yes grep -q startbigwm /usr/bin/startbiglive)"'
    'bwm_wait 12 pgrep -f /usr/share/biglinux/livecd/main.py; echo "BWM""_WIZARD=$(bwm_yes pgrep -f /usr/share/biglinux/livecd/main.py)"'
    'pkill -f /usr/share/biglinux/livecd/main.py; sleep 5'
    'bwm_wait 24 pgrep -u LIVEUSER -x wmaker; echo "BWM""_WMAKER=$(bwm_yes pgrep -u LIVEUSER -x wmaker)"'
    'echo "BWM""_FAILED_UNITS=$(systemctl --failed --no-legend --plain | awk '"'"'{print $1}'"'"' | paste -sd, - | sed '"'"'s/^$/nenhuma/'"'"')"'
    'echo "BWM""_DONE=1"'
)
screendump 20-antes-das-sondas
for line in "${probe[@]}"; do
    guest "${line//LIVEUSER/$live_user}"
    sleep 0.3
done

log "Sondas enviadas; aguardando o resultado"
probe_deadline=$((SECONDS + 900))
while [[ "$(marker DONE)" != 1 ]]; do
    alive
    ((SECONDS < probe_deadline)) || break
    sleep 5
done
screendump 90-final

dm=$(marker DM) xorg=$(marker XORG) session=$(marker SESSION)
patch=$(marker LIVECD_PATCH) wizard=$(marker WIZARD) wmaker=$(marker WMAKER)
failed_units=$(marker FAILED_UNITS)

if [[ "$(marker DONE)" != 1 ]]; then
    record FAIL sondas "as sondas não terminaram em 900s"
fi
if [[ "$dm" == active ]]; then
    record PASS lightdm "lightdm.service ativo"
else
    record FAIL lightdm "lightdm.service: ${dm:-sem resposta}"
fi
if [[ "$xorg" == yes ]]; then
    record PASS xorg "processo Xorg presente"
else
    record FAIL xorg "nenhum processo Xorg"
fi
if [[ "$session" == yes ]]; then
    record PASS sessao-live "sessão logind de $live_user"
else
    record FAIL sessao-live "sem sessão logind de $live_user (autologin falhou)"
fi

check_wmaker=true
if [[ "$patch" == yes ]]; then
    record PASS livecd-patch "startbiglive inicia startbigwm"
elif [[ "$require_patch" == true ]]; then
    record FAIL livecd-patch "biglinux-livecd sem o patch do Window Maker: a sessão live entra em loop no login"
else
    record WARN livecd-patch "biglinux-livecd sem o patch do Window Maker (aceito por --require-livecd-patch false)"
    check_wmaker=false
fi

if [[ "$wmaker" == yes ]]; then
    record PASS wmaker "processo wmaker de $live_user após fechar o assistente"
elif $check_wmaker; then
    record FAIL wmaker "nenhum wmaker de $live_user após fechar o assistente"
else
    record WARN wmaker "nenhum wmaker (esperado sem o patch do biglinux-livecd)"
fi

colors=$(count_colors "$out/90-final.ppm")
if ((colors >= min_colors)); then
    record PASS tela "captura final com $colors cores distintas"
else
    record FAIL tela "captura final com só $colors cores distintas (mínimo $min_colors): tela preta ou só texto"
fi

record INFO assistente "assistente live em execução: ${wizard:-?}"
record INFO unidades-falhas "${failed_units:-?}"

{
    echo "### Smoke test ($firmware)"
    echo
    echo '```'
    cat "$result_file"
    echo '```'
} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"

if ((failures > 0)); then
    log "REPROVADO: $failures critério(s) falharam, $warnings aviso(s)"
    exit 1
fi
log "APROVADO ($warnings aviso(s))"
