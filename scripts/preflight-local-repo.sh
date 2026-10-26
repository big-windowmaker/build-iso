#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# preflight-local-repo.sh - confere, antes do buildiso, que o pacman resolve
# cada pacote do repositório local a partir de [bigwm-local] (e não de um
# repositório remoto com o mesmo nome, como o windowmaker do [extra]).
#
# Uso: preflight-local-repo.sh <diretório-do-repo> <pacman.conf>
#
# Sincroniza os bancos num dbpath temporário (não toca no pacman do contêiner)
# e falha em segundos, em vez de no meio de um build de horas.
set -euo pipefail

readonly REPO_NAME=bigwm-local

die() { printf 'preflight-local-repo.sh: erro: %s\n' "$*" >&2; exit 1; }

(($# == 2)) || die "uso: preflight-local-repo.sh <diretório-do-repo> <pacman.conf>"
repo_dir=$1 conf=$2
manifest="$repo_dir/$REPO_NAME.manifest"
[[ -f "$manifest" ]] || die "manifesto não encontrado: $manifest"
[[ -f "$conf" ]] || die "pacman.conf não encontrado: $conf"

dbpath=$(mktemp -d)
trap 'rm -rf "$dbpath"' EXIT

pacman --config "$conf" --dbpath "$dbpath" -Sy --noconfirm >/dev/null \
    || die "pacman -Sy falhou com $conf"

mapfile -t names < <(awk '!/^#/ && NF { print $1 }' "$manifest")
((${#names[@]} > 0)) || die "manifesto vazio: $manifest"

# -dd: só os alvos, sem dependências; formato "repositório nome versão".
resolved=$(pacman --config "$conf" --dbpath "$dbpath" -Sdd --print \
    --print-format '%r %n %v' "${names[@]}") \
    || die "o pacman não resolveu os pacotes do repositório local"

bad=0
while read -r repo name version; do
    if [[ "$repo" != "$REPO_NAME" ]]; then
        printf '  %s %s viria de [%s], não de [%s]\n' "$name" "$version" "$repo" "$REPO_NAME" >&2
        bad=1
    fi
done <<<"$resolved"
((bad == 0)) || die "há pacotes do repositório local encobertos por outro repositório"

printf 'preflight-local-repo.sh: %d pacote(s) resolvidos a partir de [%s]\n' "${#names[@]}" "$REPO_NAME"
printf '%s\n' "$resolved"
