#!/usr/bin/env bash
# resolve-edition.sh - simula, com o pacman, a instalação de todas as listas de
# pacotes da edição (Packages-Root, Packages-Desktop e Packages-Live) usando os
# mesmos repositórios que o motor da BigLinux usa no build, mais o [bigwm-local].
#
# Uso (como root, dentro de um contêiner Manjaro descartável):
#   resolve-edition.sh <dir-da-edição> <dir-do-bigwm-local> <stable|testing>
#
# Falha se algum nome não existir ou se a transação conjunta não fechar
# (dependências ou conflitos). Leva poucos minutos, contra dezenas do build:
# por isso roda antes do job privilegiado.
#
# Nada é instalado: só "pacman -Sp" (imprime URLs). Os repositórios
# BigLinux/BigCommunity entram com SigLevel = Optional TrustAll porque este
# contêiner não tem os chaveiros deles e só lê os bancos de dados; o build de
# verdade usa os chaveiros e a verificação do motor.
set -euo pipefail

die() { printf 'resolve-edition.sh: erro: %s\n' "$*" >&2; exit 1; }

(($# == 3)) || die "uso: resolve-edition.sh <dir-da-edição> <dir-do-bigwm-local> <stable|testing>"
edition=$1 local_repo=$2 branch=$3
[[ $branch =~ ^(stable|testing)$ ]] || die "branch inválido: $branch"
[[ -f $local_repo/bigwm-local.db.tar.gz ]] || die "repositório local sem banco: $local_repo"
for list in Packages-Root Packages-Desktop Packages-Live; do
    [[ -r $edition/$list ]] || die "lista ausente: $edition/$list"
done

biglinux_host=${BIGLINUX_REPO_HOST:-packages.biglinux.com.br}
community_host=${COMMUNITY_REPO_HOST:-repo.communitybig.org}

pacman-mirrors --api --set-branch "$branch" >/dev/null

section() { # nome, servidor
    printf '\n[%s]\nSigLevel = Optional TrustAll\nServer = %s\n' "$1" "$2"
}

# Mesma ordem do motor: [bigwm-local] e [biglinux-priority] acima do [core];
# multilib; comunidade e BigLinux por último (testing antes de stable).
{
    sed -n '/^\[core\]/q;p' /etc/pacman.conf
    section bigwm-local "file://$local_repo"
    section biglinux-priority "https://$biglinux_host/\$repo/\$arch"
    printf '\n[core]\nInclude = /etc/pacman.d/mirrorlist\n'
    printf '\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n'
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n'
    [[ $branch == testing ]] && section community-testing "https://$community_host/\$repo/\$arch"
    section community-stable "https://$community_host/\$repo/\$arch"
    section community-extra "https://$community_host/\$repo/\$arch"
    [[ $branch == testing ]] && section biglinux-testing "https://$biglinux_host/\$repo/\$arch"
    section biglinux-stable "https://$biglinux_host/\$repo/\$arch"
    section biglinux-extra "https://$biglinux_host/\$repo/\$arch"
} >/tmp/pacman-resolve.conf

# Banco local vazio: a simulação parte de um sistema sem nada instalado, como
# o chroot do buildiso, e não dos pacotes da imagem deste contêiner.
dbpath=$(mktemp -d)
pm() { pacman --config /tmp/pacman-resolve.conf --dbpath "$dbpath" "$@"; }
pm -Sy >/dev/null

# Nomes das listas: sem comentários, sem marcadores do manjaro-tools
# (">multilib", ">extra"...), sem restrições de versão e sem os itens ">i686"
# (o buildiso os ignora em x86_64). KERNEL é o marcador do kernel escolhido;
# basta um kernel existente para checar os pacotes que dependem dele.
mapfile -t names < <(
    cat "$edition/Packages-Root" "$edition/Packages-Desktop" "$edition/Packages-Live" |
        sed -e 's/#.*//' -e '/^[[:space:]]*>i686[[:space:]]/d' -e 's/^[[:space:]]*>[a-z0-9_]*[[:space:]]*//' |
        awk 'NF {print $1}' | sed -e 's/[<>=].*//' -e 's/KERNEL/linux612/g' | sort -u
)
printf 'Resolvendo %d nomes no branch %s\n' "${#names[@]}" "$branch"

missing=()
for name in "${names[@]}"; do
    pm -Sp --print-format '%n' "$name" >/dev/null 2>&1 \
        || missing+=("$name")
done
if ((${#missing[@]})); then
    printf '::error::%d pacote(s) não resolvem sozinhos:\n' "${#missing[@]}"
    for name in "${missing[@]}"; do
        printf '  %s: ' "$name"
        pm -Sp "$name" 2>&1 | grep -v '^warning' | head -3 | tr '\n' ' '
        printf '\n'
    done
    exit 1
fi

# Transação conjunta: pega conflitos entre pacotes que sozinhos resolvem.
if ! pm -Sp --print-format '%r/%n %v' "${names[@]}" \
    >/tmp/resolved.txt 2>/tmp/resolve.err; then
    grep -v '^warning' /tmp/resolve.err >&2
    die "a transação conjunta não fecha (conflito ou dependência)"
fi

printf '%d pacotes na transação; vindos do [bigwm-local]:\n' "$(wc -l </tmp/resolved.txt)"
grep '^bigwm-local/' /tmp/resolved.txt | sed 's/^/  /'
