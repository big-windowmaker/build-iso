#!/usr/bin/env bash
# publish-release.sh - publica como pre-release do GitHub uma ISO já aprovada.
#
# Uso: publish-release.sh <dir-com-a-iso> <nome.iso> <tag> <branch>
#
# <dir-com-a-iso> tem a ISO e os arquivos que o job build gera ao lado dela
# (.sha256, .pkgs, .bigwm-local.manifest, .bigwm-local.sources.tsv,
# .build-info). O script confere o SHA-256, gera SHA256SUMS, divide a ISO em
# partes 7z de 2000 MB (limite de 2 GiB por arquivo de release), cria a
# release como RASCUNHO, envia os arquivos e só então a publica.
#
# A tag aponta para a ponta do <branch> (main) no momento da publicação, não
# para o commit que gerou a ISO: criar uma tag num commit cujos workflows
# diferem dos atuais exige a permissão "workflows", que o GITHUB_TOKEN nunca
# tem (HTTP 403). O commit do build continua registrado no .build-info, que
# vai nas notas da release.
#
# O arquivo publicado se chama <tag>.iso (o build gera o nome sem o -rNN e,
# numa versão com nome, com o ramo dos pacotes no lugar dela).
#
# Variáveis: GH_TOKEN (contents: write), GITHUB_REPOSITORY.
#            VERSAO (opcional): nome da versão, por exemplo "Beta 1"; vai no
#            título e nas notas. Sem ela, a release é uma Alpha.
# Em caso de falha da API, a resposta completa fica em gh-api-debug.txt.
set -euo pipefail

die() { printf 'publish-release.sh: erro: %s\n' "$*" >&2; exit 1; }

(($# == 4)) || die "uso: publish-release.sh <dir> <nome.iso> <tag> <branch>"
dir=$1 iso=$2 tag=$3 target=$4
[[ "$iso" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.iso$ ]] || die "nome de ISO inválido: $iso"
[[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "tag inválida: $tag"
[[ "$target" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$ && "$target" != *..* ]] || die "branch inválido: $target"
[[ -n "${GITHUB_REPOSITORY:-}" ]] || die "GITHUB_REPOSITORY não definido"
versao=${VERSAO:-}
[[ -z "$versao" || "$versao" =~ ^[A-Z][a-z]+\ [0-9]+$ ]] || die "VERSAO inválida (ex.: Beta 1): $versao"

scripts=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$dir"
sha256sum --check --strict -- "$iso.sha256"

# O nome publicado é o da tag: leva o número do build (-rNN), porque duas
# ISOs do mesmo dia tinham o mesmo nome de arquivo e quem baixou a anterior
# conferia o SHA-256 da página errada (r70 e r71, 2026-11-26), e numa versão
# com nome leva o nome dela (big-windowmaker_BETA1_...).
if [[ "$iso" != "$tag.iso" ]]; then
    novo="$tag.iso"
    for f in "$iso" "$iso".*; do
        mv -- "$f" "$novo${f#"$iso"}"
    done
    sed -i "s|  $iso\$|  $novo|" "$novo.sha256"
    iso=$novo
    sha256sum --check --strict -- "$iso.sha256"
fi

# SHA256SUMS cobre a ISO inteira (o que se confere depois de juntar as
# partes) e os arquivos auxiliares.
sha256sum -- "$iso" "$iso.pkgs" "$iso.bigwm-local.manifest" \
    "$iso.bigwm-local.sources.tsv" "$iso.build-info" >SHA256SUMS
if [[ -n "$(du --threshold=2000M -- "$iso")" ]]; then
    command -v 7z >/dev/null || die "7z (p7zip) é necessário para dividir a ISO"
    7z a -mx=0 -v2000m -- "$iso.7z" "$iso" >/dev/null
    rm -- "$iso"
    sha256sum -- "$iso".7z.* >>SHA256SUMS
fi
cat SHA256SUMS

{
    if [[ -n "$versao" ]]; then
        echo "**Big WindowMaker $versao.** Versão para testes públicos: instale num computador com backup e relate os problemas (menu Sessão > Relatar problema)."
    else
        echo "**Big WindowMaker — Alpha (ISO de teste). Não use em produção.**"
    fi
    echo
    echo "Sessão padrão: Big WindowMaker — X11 (Window Maker). Sessão experimental: Big WindowMaker — Wayland (wlmaker)."
    echo
    echo "- A ISO é montada com os pacotes do Big WindowMaker dos artefatos de CI ([bigwm-local], só no build). O sistema instalado recebe as atualizações deles pelo repositório assinado [big-wm] (https://github.com/big-windowmaker/repo), já configurado: \`sudo pacman -Syu\`."
    echo "- Aprovada no smoke test em QEMU (BIOS e UEFI) e no teste de instalação pelo Calamares (BIOS e UEFI): instalação, boot pelo disco, login, sessões X11 e Wayland."
    echo "- Modo live: entra direto, sem tela de login. Ao sair da sessão, a tela do wdm pede usuário \`bigwindowmaker\`, senha \`big\` (F1 mostra)."
    echo
    # Gerado a cada publicação (versões dos pacotes e PRs desde a ISO
    # anterior): o texto fixo que havia aqui ficou semanas desatualizado.
    bash "$scripts/release-notes.sh" "$iso.bigwm-local.manifest"
    echo
    echo "Desenvolvimento: Rafael Ruscher <rruscher@gmail.com> e Barnabé Di Kartola <barnabedikartola@gmail.com>."
    echo
    echo "Para juntar e conferir: \`7z x $iso.7z.001\` e depois \`sha256sum -c SHA256SUMS --ignore-missing\`."
    echo
    echo '```'
    cat "$iso.build-info"
    echo '```'
} >notes.md

mapfile -t files < <(find . -maxdepth 1 -type f ! -name notes.md ! -name gh-api-debug.txt -printf '%f\n' | sort)

publish() {
    # Rascunho primeiro: a criação não depende dos envios; publica no fim.
    gh release create "$tag" --repo "$GITHUB_REPOSITORY" --target "$target" \
        --draft --prerelease --title "Big WindowMaker ${versao:-Alpha} — $iso" --notes-file notes.md
    gh release upload "$tag" --repo "$GITHUB_REPOSITORY" --clobber -- "${files[@]}"
    gh release edit "$tag" --repo "$GITHUB_REPOSITORY" --draft=false --prerelease
}

if ! GH_DEBUG=api publish 2>gh-api-debug.txt; then
    grep -E '^(\* Request to|< HTTP|\{"message)|"message"' gh-api-debug.txt | tail -20 >&2 || true
    die "falha ao publicar a release (resposta completa em $dir/gh-api-debug.txt)"
fi
gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json url --jq .url
