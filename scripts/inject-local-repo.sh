#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# inject-local-repo.sh - insere o repositório local [bigwm-local] nas
# configurações do pacman que o buildiso (manjaro-tools) usa para montar os
# chroots da ISO.
#
# Uso: inject-local-repo.sh <diretório-do-repo> <pacman.conf>...
#
# Normalmente chamado por run-engine.sh logo antes do buildiso, com
#   /usr/share/manjaro-tools/pacman-default.conf
#   /usr/share/manjaro-tools/pacman-multilib.conf
# (o buildiso escolhe pacman-multilib.conf em x86_64; ver get_pacman_conf em
# manjaro-tools/lib/util-iso.sh).
#
# A seção entra ACIMA de todas as outras (inclusive [biglinux-priority] e
# [core]): o pacman usa o primeiro repositório que tem o pacote, e o nosso
# windowmaker precisa vencer o windowmaker do [extra].
#
# SOMENTE PARA ISOs DE TESTE. Os pacotes e o banco não são assinados, então a
# seção usa "SigLevel = Optional TrustAll" - e só ela: o script recusa o
# arquivo se qualquer outra seção, ou o [options], ficar com TrustAll.
#
# Idempotente: uma seção [bigwm-local] já existente é removida e reescrita.
set -euo pipefail

readonly REPO_NAME=bigwm-local

die() { printf 'inject-local-repo.sh: erro: %s\n' "$*" >&2; exit 1; }

(($# >= 2)) || die "uso: inject-local-repo.sh <diretório-do-repo> <pacman.conf>..."
repo_dir=$1
shift

# Caminho absoluto e sem caracteres que precisem de escape numa URL file://.
[[ "$repo_dir" =~ ^/[A-Za-z0-9._/-]+$ && "$repo_dir" != *..* ]] \
    || die "diretório do repositório inválido (absoluto, sem '..'): $repo_dir"
[[ -f "$repo_dir/$REPO_NAME.db" ]] || die "banco não encontrado: $repo_dir/$REPO_NAME.db"

section_block() {
    cat <<EOF
# Inserido por big-windowmaker/build-iso (scripts/inject-local-repo.sh).
# SOMENTE TESTE: pacotes e banco NÃO assinados. A confiança relaxada vale
# apenas para este repositório local (file://), nunca para repositórios remotos.
[$REPO_NAME]
SigLevel = Optional TrustAll
Server = file://$repo_dir

EOF
}

inject() {
    local conf=$1 block tmp
    [[ -f "$conf" ]] || die "arquivo não encontrado: $conf"
    block=$(mktemp)
    tmp=$(mktemp)
    section_block >"$block"

    # 1) remove uma seção [bigwm-local] anterior (e o comentário que a
    #    precede); 2) insere o bloco antes da primeira seção que não seja
    #    [options]; se não houver nenhuma, anexa ao final.
    awk -v name="$REPO_NAME" -v block="$block" '
        function flush_block(  line) {
            while ((getline line < block) > 0) print line
            close(block)
            done = 1
        }
        /^# Inserido por big-windowmaker\/build-iso/ { skip_comment = 1; next }
        skip_comment && /^#/ { next }
        { skip_comment = 0 }
        /^\[/ {
            in_ours = ($0 == "[" name "]")
            if (in_ours) next
            if (!done && $0 != "[options]") flush_block()
        }
        in_ours { next }
        { print }
        END { if (!done) flush_block() }
    ' "$conf" >"$tmp"
    cat "$tmp" >"$conf"
    rm -f "$block" "$tmp"

    verify "$conf"
    printf 'inject-local-repo.sh: [%s] -> %s (file://%s)\n' "$REPO_NAME" "$conf" "$repo_dir"
}

line_of() { grep -n -m1 -x "$1" "$2" | cut -d: -f1; }

verify() {
    local conf=$1 ours other count
    count=$(grep -c -x "\[$REPO_NAME\]" "$conf" || true)
    [[ "$count" == 1 ]] || die "$conf: esperado exatamente um [$REPO_NAME], encontrado $count"
    ours=$(line_of "\[$REPO_NAME\]" "$conf")

    # Acima de qualquer outro repositório.
    other=$(grep -n '^\[' "$conf" | grep -v -e '\[options\]' -e "\[$REPO_NAME\]" | head -n1 | cut -d: -f1 || true)
    if [[ -n "$other" ]] && ((ours > other)); then
        die "$conf: [$REPO_NAME] (linha $ours) não está acima dos demais repositórios (linha $other)"
    fi

    # TrustAll só dentro da nossa seção.
    awk -v name="$REPO_NAME" '
        /^\[/ { section = $0 }
        /^[[:space:]]*SigLevel[[:space:]]*=.*TrustAll/ && section != "[" name "]" {
            printf "%s:%d: TrustAll fora de [%s] (%s)\n", FILENAME, FNR, name, section > "/dev/stderr"
            bad = 1
        }
        END { exit bad }
    ' "$conf" || die "$conf: TrustAll fora do repositório local"

    # E a nossa seção tem o Server esperado.
    awk -v name="$REPO_NAME" -v server="Server = file://$repo_dir" '
        /^\[/ { section = $0; next }
        section == "[" name "]" && $0 == server { found = 1 }
        END { exit !found }
    ' "$conf" || die "$conf: Server de [$REPO_NAME] ausente ou diferente"
}

for conf in "$@"; do
    inject "$conf"
done
