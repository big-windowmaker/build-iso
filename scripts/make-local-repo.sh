#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# make-local-repo.sh - monta o repositório pacman local [bigwm-local] com os
# pacotes baixados dos artefatos de CI (big-windowmaker/big-wm e
# big-windowmaker/packages).
#
# Uso: make-local-repo.sh <diretório-dos-artefatos> <diretório-de-saída>
#
# Variáveis:
#   EXPECTED_PACKAGES  nomes (separados por espaço) que precisam estar no
#                      repositório; falta de qualquer um é erro.
#
# Precisa de repo-add e bsdtar (pacman/libarchive): no workflow roda dentro de
# um contêiner Manjaro fixado por digest, sem rede (--network none).
#
# SOMENTE TESTE: os pacotes e o banco NÃO são assinados. O repositório só deve
# ser usado como file:// no build de ISOs de teste (ver inject-local-repo.sh).
set -euo pipefail

readonly REPO_NAME=bigwm-local

die() { printf 'make-local-repo.sh: erro: %s\n' "$*" >&2; exit 1; }

(($# == 2)) || die "uso: make-local-repo.sh <artefatos> <saída>"
src=$1 out=$2
[[ -d "$src" ]] || die "diretório de artefatos não encontrado: $src"
command -v repo-add >/dev/null || die "repo-add não encontrado (pacman)"
command -v bsdtar >/dev/null || die "bsdtar não encontrado (libarchive)"

mkdir -p "$out"
[[ -z "$(ls -A "$out")" ]] || die "o diretório de saída precisa estar vazio: $out"

mapfile -t packages < <(find "$src" -type f -name '*.pkg.tar.zst' | sort)
((${#packages[@]} > 0)) || die "nenhum *.pkg.tar.zst em $src"

pkginfo_field() { # arquivo campo
    bsdtar -xOf "$1" .PKGINFO | awk -v k="$2" '$1 == k && $2 == "=" { sub(/^[^=]*= /, ""); print; exit }'
}

declare -A seen=()
manifest="$out/$REPO_NAME.manifest"
{
    echo "# Repositório local de TESTE [$REPO_NAME] - pacotes NÃO assinados."
    echo "# nome versão arquitetura arquivo sha256 origem"
} >"$manifest"

for pkg in "${packages[@]}"; do
    file=${pkg##*/}
    [[ "$file" =~ ^[A-Za-z0-9@._+-]+\.pkg\.tar\.zst$ ]] || die "nome de arquivo inesperado: $file"
    name=$(pkginfo_field "$pkg" pkgname)
    version=$(pkginfo_field "$pkg" pkgver)
    arch=$(pkginfo_field "$pkg" arch)
    [[ "$name" =~ ^[a-z0-9@._+-]+$ ]] || die "$file: pkgname inválido no .PKGINFO: '$name'"
    [[ "$version" =~ ^([0-9]+:)?[A-Za-z0-9._+~]+-[0-9.]+$ ]] || die "$file: versão inválida: '$version'"
    case "$arch" in x86_64 | any) ;; *) die "$file: arquitetura não suportada: $arch" ;; esac
    if [[ -n "${seen[$name]:-}" ]]; then
        die "pacote $name aparece em mais de um artefato: ${seen[$name]} e $pkg"
    fi
    seen[$name]=$pkg
    install -m 0644 "$pkg" "$out/$file"
    origin=${pkg#"$src"/}
    origin=${origin%%/*}
    printf '%s %s %s %s %s %s\n' "$name" "$version" "$arch" "$file" \
        "$(sha256sum "$out/$file" | cut -d' ' -f1)" "$origin" >>"$manifest"
done

missing=()
for name in ${EXPECTED_PACKAGES:-}; do
    [[ -n "${seen[$name]:-}" ]] || missing+=("$name")
done
((${#missing[@]} == 0)) || die "pacotes esperados ausentes dos artefatos: ${missing[*]}"

(cd "$out" && repo-add --quiet "$REPO_NAME.db.tar.gz" ./*.pkg.tar.zst)

# repo-add cria bigwm-local.db/.files como links simbólicos; artefatos do
# GitHub não preservam links, então viram cópias.
for link in "$out/$REPO_NAME.db" "$out/$REPO_NAME.files"; do
    if [[ -L "$link" ]]; then
        cp --remove-destination "$(readlink -f "$link")" "$link"
    fi
done
rm -f "$out"/*.old

cat >"$out/LEIA-ME-TESTE.txt" <<EOF
Repositório pacman local [$REPO_NAME] - SOMENTE PARA ISOs DE TESTE.

Pacotes e banco NÃO são assinados. Use apenas como Server = file://... com
SigLevel = Optional TrustAll restrito a esta seção, dentro do contêiner de
build de ISO. Nunca publique este diretório como repositório remoto.
A assinatura (chave própria + bigwm-keyring) é a fase 2; ver README.md.
EOF

printf 'make-local-repo.sh: %d pacote(s) em %s\n' "${#seen[@]}" "$out"
grep -v '^#' "$manifest" | column -t
