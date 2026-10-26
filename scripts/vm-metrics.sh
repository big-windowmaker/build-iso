#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# vm-metrics.sh - métricas de desempenho e saúde coletadas DENTRO da VM de
# teste (como root), sem interpretar nada: cada seção é a saída literal do
# comando, com o código de saída. Usado pelo smoke test (sessão live, pela
# serial) e pelo teste de instalação (sistema instalado, módulo openQA
# bigwm_metrics, servido pelo harness como data/vm-metrics.sh).
#
# Uso: vm-metrics.sh USUÁRIO completo|memoria [rótulo]
#   completo  systemd-analyze (+ blame), free -m, nº de processos, RSS dos
#             processos do usuário, unidades com falha (sistema e usuário),
#             erros do journal deste boot, coredumps e uso do disco de /
#   memoria   só free -m, nº de processos e RSS (para a amostra após ocioso)

user=${1:?usuário}
mode=${2:-completo}
label=${3:-$mode}
uid=$(id -u "$user") || exit 1

section() { printf '\n### %s\n' "$*"; }
run() {
    section "$*"
    "$@" 2>&1
    printf '(código de saída: %s)\n' "$?"
}
as_user() {
    runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" "$@"
}

printf '# Métricas: %s (%s), usuário %s\n' "$label" "$mode" "$user"
run date -u '+%Y-%m-%dT%H:%M:%SZ'
section 'uptime (s)'
cut -d' ' -f1 /proc/uptime

if [[ "$mode" == completo ]]; then
    run uname -r
    run systemd-analyze
    section 'systemd-analyze blame | head -15'
    systemd-analyze blame 2>&1 | head -15
fi

run free -m
section 'ps -e --no-headers | wc -l'
ps -e --no-headers | wc -l
section "ps -o rss,comm -u $user --sort=-rss | head -20"
ps -o rss,comm -u "$user" --sort=-rss | head -20
section "soma do RSS dos processos de $user (KiB)"
ps -o rss= -u "$user" | awk '{s += $1} END {print s + 0}'
section 'RSS do wmaker/wlmaker (KiB)'
ps -o pid=,rss=,args= -C wmaker,wlmaker 2>&1 || echo 'nenhum processo'

if [[ "$mode" == completo ]]; then
    run systemctl --failed --no-pager
    section "systemctl --user --failed ($user)"
    as_user systemctl --user --failed --no-pager 2>&1
    printf '(código de saída: %s)\n' "$?"
    section 'journalctl -b -p err --no-pager (últimas 200 linhas)'
    journalctl -b -p err --no-pager 2>&1 | tail -n 200
    run coredumpctl list --no-pager
    run df -h /
fi
