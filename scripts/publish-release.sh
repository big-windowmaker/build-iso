#!/usr/bin/env bash
# publish-release.sh - publica como pre-release do GitHub uma ISO já aprovada.
#
# Uso: publish-release.sh <dir-com-a-iso> <nome.iso> <tag> <commit-alvo>
#
# <dir-com-a-iso> tem a ISO e os arquivos que o job build gera ao lado dela
# (.sha256, .pkgs, .bigwm-local.manifest, .bigwm-local.sources.tsv,
# .build-info). O script confere o SHA-256, gera SHA256SUMS, divide a ISO em
# partes 7z de 2000 MB (limite de 2 GiB por arquivo de release), cria a
# release como RASCUNHO, envia os arquivos e só então a publica.
#
# Variáveis: GH_TOKEN (contents: write), GITHUB_REPOSITORY.
# Em caso de falha da API, a resposta completa fica em gh-api-debug.txt.
set -euo pipefail

die() { printf 'publish-release.sh: erro: %s\n' "$*" >&2; exit 1; }

(($# == 4)) || die "uso: publish-release.sh <dir> <nome.iso> <tag> <commit-alvo>"
dir=$1 iso=$2 tag=$3 target=$4
[[ "$iso" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.iso$ ]] || die "nome de ISO inválido: $iso"
[[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "tag inválida: $tag"
[[ "$target" =~ ^[0-9a-f]{40}$ ]] || die "commit-alvo deve ser o SHA completo: $target"
[[ -n "${GITHUB_REPOSITORY:-}" ]] || die "GITHUB_REPOSITORY não definido"

cd "$dir"
sha256sum --check --strict -- "$iso.sha256"

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
    echo "**Big WindowMaker — Alpha (ISO de teste). Não use em produção.**"
    echo
    echo "Sessão padrão: Big WindowMaker — X11 (Window Maker). Sessão experimental: Big WindowMaker — Wayland (wlmaker)."
    echo
    echo "- Os pacotes do Big WindowMaker vêm de um repositório local **não assinado** ([bigwm-local]), montado a partir de artefatos de CI. Repositório e chave próprios são a fase 2."
    echo "- Aprovada no smoke test em QEMU (BIOS e UEFI) e no teste de instalação pelo Calamares (BIOS e UEFI): instalação, boot pelo disco, login, sessões X11 e Wayland."
    echo "- Modo live: usuário \`community\`, senha \`big\`."
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
        --draft --prerelease --title "Big WindowMaker Alpha — $iso" --notes-file notes.md
    gh release upload "$tag" --repo "$GITHUB_REPOSITORY" --clobber -- "${files[@]}"
    gh release edit "$tag" --repo "$GITHUB_REPOSITORY" --draft=false --prerelease
}

if ! GH_DEBUG=api publish 2>gh-api-debug.txt; then
    grep -E '^(\* Request to|< HTTP|\{"message)|"message"' gh-api-debug.txt | tail -20 >&2 || true
    die "falha ao publicar a release (resposta completa em $dir/gh-api-debug.txt)"
fi
gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json url --jq .url
