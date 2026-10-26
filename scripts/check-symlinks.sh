#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# check-symlinks.sh - confere os links simbólicos de uma edição do
# iso-profiles (bigcommunity/<edição>/ aponta para ../../shared/...).
#
# Uso: check-symlinks.sh <raiz-do-iso-profiles> <caminho-da-edição>
#      ex.: check-symlinks.sh profiles bigcommunity/wmaker
#
# Para cada link da edição, segue a cadeia salto a salto:
#   - alvo relativo: precisa continuar dentro do repositório e existir;
#   - alvo absoluto (ex.: /usr/share/zoneinfo/... em etc/localtime): é
#     resolvido dentro da imagem, não aqui; aceito e listado.
set -euo pipefail

die() { printf 'check-symlinks.sh: erro: %s\n' "$*" >&2; exit 1; }

(($# == 2)) || die "uso: check-symlinks.sh <raiz> <edição>"
root=$(cd "$1" && pwd -P)
edition=$2
[[ "$edition" =~ ^[A-Za-z0-9._/-]+$ && "$edition" != *..* ]] || die "caminho de edição inválido: $edition"
[[ -d "$root/$edition" ]] || die "edição não encontrada: $root/$edition"

errors=0 total=0
report() { printf '  %s\n' "$*" >&2; errors=$((errors + 1)); }

check_link() {
    local link=$1 current=$1 target hops=0 next
    while [[ -L "$current" ]]; do
        hops=$((hops + 1))
        ((hops <= 20)) || { report "${link#"$root"/}: cadeia de links longa demais (laço?)"; return; }
        target=$(readlink "$current")
        if [[ "$target" == /* ]]; then
            printf '  %s -> %s (absoluto, resolvido na imagem)\n' "${link#"$root"/}" "$target"
            return
        fi
        next=$(realpath -m -s "$(dirname "$current")/$target")
        if [[ "$next" != "$root" && "$next" != "$root"/* ]]; then
            report "${link#"$root"/}: sai do repositório ($target)"
            return
        fi
        current=$next
    done
    if [[ ! -e "$current" ]]; then
        report "${link#"$root"/}: alvo inexistente (${current#"$root"/})"
        return
    fi
    # Também a resolução completa (diretórios intermediários) fica no repositório.
    next=$(realpath -e "$link")
    if [[ "$next" != "$root" && "$next" != "$root"/* ]]; then
        report "${link#"$root"/}: resolve para fora do repositório ($next)"
    fi
}

while IFS= read -r -d '' link; do
    total=$((total + 1))
    check_link "$link"
done < <(find "$root/$edition" -type l -print0)

((total > 0)) || die "nenhum link simbólico em $edition (a edição deveria herdar de shared/)"
if ((errors > 0)); then
    die "$errors link(s) quebrado(s) de $total em $edition"
fi
printf 'check-symlinks.sh: %d link(s) em %s conferidos\n' "$total" "$edition"
