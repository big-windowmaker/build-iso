#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# release-notes.sh - a seção "O que mudou" das notas de uma ISO, gerada:
# as versões dos pacotes do Big WindowMaker comparadas com as da ISO
# publicada antes (o .bigwm-local.manifest anexado a cada release) e os
# PRs mergeados nos repositórios da organização desde aquela publicação.
#
# Uso: release-notes.sh <manifesto-desta-iso>
#
# Variáveis: GITHUB_REPOSITORY (dono/build-iso), GH_TOKEN.
#            PREVIOUS_MANIFEST e PREVIOUS_TAG/PREVIOUS_DATE: em vez de buscar
#            a release anterior (testes).
#
# Escreve Markdown na saída padrão. Nunca falha: o que não der para obter
# vira uma linha dizendo isso, para a publicação seguir.
set -uo pipefail

manifest=${1:?uso: release-notes.sh <manifesto>}
repo=${GITHUB_REPOSITORY:-big-windowmaker/build-iso}
owner=${repo%%/*}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

prev_tag=${PREVIOUS_TAG:-} prev_date=${PREVIOUS_DATE:-} prev_manifest=${PREVIOUS_MANIFEST:-}
if [[ -z "$prev_tag" ]]; then
    read -r prev_tag prev_date < <(gh release list --repo "$repo" --exclude-drafts --limit 1 \
        --json tagName,publishedAt -q '.[0] | "\(.tagName) \(.publishedAt)"' 2>/dev/null)
fi
if [[ -z "$prev_manifest" && -n "$prev_tag" ]] &&
    gh release download "$prev_tag" --repo "$repo" -p '*.bigwm-local.manifest' -D "$tmp/prev" 2>/dev/null; then
    prev_manifest=$(find "$tmp/prev" -name '*.bigwm-local.manifest' | head -1)
fi

echo "### O que mudou${prev_tag:+ desde ${prev_tag}}"
echo
if [[ -z "$prev_manifest" || ! -s "$prev_manifest" ]]; then
    echo "_Sem a ISO anterior para comparar os pacotes._"
else
    # nome versão (as linhas com # são comentário)
    awk '!/^#/ && NF >= 2 { print $1, $2 }' "$prev_manifest" | sort >"$tmp/antes"
    awk '!/^#/ && NF >= 2 { print $1, $2 }' "$manifest" | sort >"$tmp/depois"
    changes=$(join -a1 -a2 -e '-' -o 0,1.2,2.2 "$tmp/antes" "$tmp/depois" |
        awk '$2 != $3 {
            if ($2 == "-") printf "| `%s` | — | %s (novo) |\n", $1, $3
            else if ($3 == "-") printf "| `%s` | %s | — (saiu) |\n", $1, $2
            else printf "| `%s` | %s | %s |\n", $1, $2, $3 }')
    if [[ -n "$changes" ]]; then
        echo "| Pacote | Antes | Agora |"
        echo "| --- | --- | --- |"
        echo "$changes"
    else
        echo "_Os pacotes do Big WindowMaker são os mesmos da ISO anterior._"
    fi
fi
echo
if [[ -n "$prev_date" ]] &&
    prs=$(gh search prs --owner "$owner" --merged --merged-at ">=${prev_date%%T*}" --limit 100 \
        --json repository,number,title,closedAt \
        -q 'sort_by(.repository.name, .number) | .[] | "- \(.repository.name)#\(.number): \(.title)"' 2>/dev/null); then
    if [[ -n "$prs" ]]; then
        echo "**PRs mergeados desde ${prev_date%%T*}:**"
        echo
        echo "$prs"
    else
        echo "_Nenhum PR mergeado desde ${prev_date%%T*}._"
    fi
else
    echo "_Lista de PRs indisponível nesta publicação._"
fi
