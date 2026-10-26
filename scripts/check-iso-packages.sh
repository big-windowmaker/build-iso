#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# check-iso-packages.sh - confere, depois do build, que a ISO recebeu os
# pacotes do repositório local [bigwm-local] (mesmo nome e mesma versão).
#
# Uso: check-iso-packages.sh <iso.pkgs> <bigwm-local.manifest>
#                            [<arquivo.iso> <Packages-Live>]
#
# <iso.pkgs> é a lista "nome versão" que o motor publica ao lado da ISO
# (pacman -Qr da imagem desktop, que inclui a imagem raiz). Os pacotes de
# Packages-Live (por exemplo o biglinux-livecd) vão para a camada live
# (livefs.sfs) e NÃO aparecem no .pkgs: com <arquivo.iso> e <Packages-Live>,
# cada pacote do manifesto listado em Packages-Live e ausente do .pkgs é
# procurado no banco do pacman do livefs.sfs da ISO
# (var/lib/pacman/local/<nome>-<versão>/), com a mesma exigência de versão.
# Precisa de xorriso e unsquashfs nesse caso.
#
# Variáveis: EXPECTED_PACKAGES - nomes que precisam estar na ISO. Pacotes do
# manifesto que não são esperados e não estão na ISO (por exemplo wmcube, que
# a edição não instala) são só listados.
set -euo pipefail

die() { printf 'check-iso-packages.sh: erro: %s\n' "$*" >&2; exit 1; }

(($# == 2 || $# == 4)) || die "uso: check-iso-packages.sh <iso.pkgs> <manifesto> [<arquivo.iso> <Packages-Live>]"
pkgs=$1 manifest=$2 iso_file=${3:-} live_list=${4:-}
[[ -s "$pkgs" ]] || die "lista de pacotes da ISO vazia ou ausente: $pkgs"
[[ -s "$manifest" ]] || die "manifesto ausente: $manifest"

declare -A iso=() wanted=() live_names=() live=()
while read -r name version _; do
    [[ -n "$name" ]] && iso[$name]=$version
done <"$pkgs"
for name in ${EXPECTED_PACKAGES:-}; do
    wanted[$name]=1
done

# Camada live: nomes de Packages-Live (aceita ">repo nome" e restrições de
# versão, como biglinux-livecd>=26.10.19-0000) e o banco do pacman do livefs.
if [[ -n "$iso_file" ]]; then
    [[ -f "$iso_file" ]] || die "ISO não encontrada: $iso_file"
    [[ -f "$live_list" ]] || die "Packages-Live não encontrado: $live_list"
    while read -r line; do
        line=${line%%#*}
        line=${line#>* }
        name=$(sed -E 's/[<>=].*//; s/[[:space:]]+//g' <<<"$line")
        [[ -n "$name" ]] && live_names[$name]=1
    done <"$live_list"

    need_live=0
    while read -r name _; do
        [[ -z "$name" || "$name" == \#* ]] && continue
        [[ -z "${iso[$name]:-}" && -n "${live_names[$name]:-}" ]] && need_live=1
    done <"$manifest"

    if ((need_live)); then
        command -v xorriso >/dev/null || die "xorriso é necessário para ler a camada live da ISO"
        command -v unsquashfs >/dev/null || die "unsquashfs é necessário para ler a camada live da ISO"
        work=$(mktemp -d)
        trap 'rm -rf -- "$work"' EXIT
        mapfile -t sfs < <(xorriso -indev "$iso_file" -find / -name livefs.sfs 2>/dev/null | tr -d "'")
        ((${#sfs[@]} == 1)) || die "esperado 1 livefs.sfs na ISO, encontrados ${#sfs[@]}"
        xorriso -osirrox on -indev "$iso_file" -extract "${sfs[0]}" "$work/livefs.sfs" >/dev/null 2>&1 \
            || die "não foi possível extrair ${sfs[0]} da ISO"
        # Entradas var/lib/pacman/local/<nome>-<versão> (a versão pode ter
        # época, "1:...").
        while IFS= read -r entry; do
            live[${entry##*/}]=1
        done < <(unsquashfs -l -d '' "$work/livefs.sfs" 2>/dev/null \
            | sed -nE 's#^/?var/lib/pacman/local/([^/]+)$#\1#p')
        ((${#live[@]} > 0)) || die "banco do pacman vazio no ${sfs[0]} da ISO"
    fi
fi

bad=0
printf '%-24s %-32s %s\n' pacote versão-local na-ISO
while read -r name version _; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    in_iso=${iso[$name]:-}
    where=""
    if [[ -z "$in_iso" && -n "${live_names[$name]:-}" && -n "$iso_file" ]]; then
        if [[ -n "${live[$name-$version]:-}" ]]; then
            in_iso=$version where=" (livefs)"
        else
            # Presente com outra versão? Só para a mensagem de erro.
            for entry in "${!live[@]}"; do
                [[ "$entry" =~ ^"$name"-[^-]+-[^-]+$ ]] && in_iso="${entry#"$name"-}" where=" (livefs)"
            done
        fi
    fi
    printf '%-24s %-32s %s\n' "$name" "$version" "${in_iso:--}$where"
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
