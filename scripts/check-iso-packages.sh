#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# check-iso-packages.sh - confere, depois do build, que a ISO recebeu os
# pacotes do repositório local [bigwm-local] (mesmo nome e mesma versão).
#
# Uso: check-iso-packages.sh <iso.pkgs> <bigwm-local.manifest>
#
# <iso.pkgs> é a lista "nome versão" que o motor publica ao lado da ISO
# (pacman -Qr da imagem desktop, que inclui a imagem raiz).
# Variáveis: EXPECTED_PACKAGES - nomes que precisam estar na ISO.
set -euo pipefail

die() { printf 'check-iso-packages.sh: erro: %s\n' "$*" >&2; exit 1; }

(($# == 2)) || die "uso: check-iso-packages.sh <iso.pkgs> <manifesto>"
pkgs=$1 manifest=$2
[[ -s "$pkgs" ]] || die "lista de pacotes da ISO vazia ou ausente: $pkgs"
[[ -s "$manifest" ]] || die "manifesto ausente: $manifest"

declare -A iso=() wanted=()
while read -r name version _; do
    [[ -n "$name" ]] && iso[$name]=$version
done <"$pkgs"
for name in ${EXPECTED_PACKAGES:-}; do
    wanted[$name]=1
done

bad=0
printf '%-24s %-32s %s\n' pacote versão-local na-ISO
while read -r name version _; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    in_iso=${iso[$name]:-}
    printf '%-24s %-32s %s\n' "$name" "$version" "${in_iso:--}"
    if [[ -z "$in_iso" ]]; then
        if [[ -n "${wanted[$name]:-}" ]]; then
            printf '  ERRO: %s é esperado e não está na ISO\n' "$name" >&2
            bad=1
        fi
    elif [[ "$in_iso" != "$version" ]]; then
        printf '  ERRO: %s na ISO é %s, mas o repositório local tem %s\n' "$name" "$in_iso" "$version" >&2
        bad=1
    fi
done <"$manifest"

for name in "${!wanted[@]}"; do
    grep -q "^$name " "$manifest" || { printf '  ERRO: %s esperado e ausente do manifesto\n' "$name" >&2; bad=1; }
done

((bad == 0)) || die "a ISO não contém os pacotes esperados do repositório local"
echo "check-iso-packages.sh: pacotes do repositório local presentes na ISO"
