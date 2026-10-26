#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# fetch-package-artifacts.sh - baixa, de outros repositórios, o artefato de
# pacotes mais recente produzido por um run BEM-SUCEDIDO de push no branch
# principal, confere o digest e extrai os arquivos.
#
# Uso: fetch-package-artifacts.sh <diretório-de-saída>
#
# Variáveis:
#   PACKAGE_SOURCES  uma fonte por linha: "<dono/repo> <workflow.yml> <artefato>"
#                    (linhas vazias e começadas por # são ignoradas)
#   SOURCE_BRANCH    branch aceito (padrão: main)
#   GH_TOKEN         token usado pelo gh (ver "Limites" no README)
#
# Regras de seleção (por fonte), para nunca pegar pacotes não revisados:
#   - artefato com o nome exato, não expirado;
#   - run do workflow indicado (path .github/workflows/<arquivo>);
#   - evento "push" no SOURCE_BRANCH, conclusão "success";
#   - head_repository == repository (exclui PRs vindos de forks, que também
#     podem ter head_branch "main").
# Depois do download: sha256 do zip == digest informado pela API, e o zip só
# pode conter arquivos simples (sem diretórios, sem caminhos relativos).
#
# Saída: <saída>/<artefato>/... e <saída>/sources.tsv (proveniência).
set -euo pipefail

die() { printf 'fetch-package-artifacts.sh: erro: %s\n' "$*" >&2; exit 1; }

(($# == 1)) || die "uso: fetch-package-artifacts.sh <diretório-de-saída>"
out=$1
branch=${SOURCE_BRANCH:-main}
[[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] || die "SOURCE_BRANCH inválido: $branch"
[[ -n "${PACKAGE_SOURCES:-}" ]] || die "PACKAGE_SOURCES vazio"
for tool in gh jq unzip sha256sum; do
    command -v "$tool" >/dev/null || die "$tool não encontrado"
done

mkdir -p "$out"
provenance="$out/sources.tsv"
printf 'repositorio\tworkflow\tartefato\tartifact_id\trun_id\thead_sha\tdigest\tcriado_em\n' >"$provenance"

fetch_one() {
    local repo=$1 workflow=$2 artifact=$3
    local candidates id run_id head_sha digest created run zip dest entries

    # Até 100 artefatos com esse nome, do mais novo para o mais antigo.
    candidates=$(gh api -X GET "repos/$repo/actions/artifacts" \
        -f name="$artifact" -F per_page=100 \
        | jq -r --arg b "$branch" '
            .artifacts[]
            | select(.expired == false)
            | select(.workflow_run.head_branch == $b)
            | select(.workflow_run.head_repository_id == .workflow_run.repository_id)
            | [.id, .workflow_run.id, .workflow_run.head_sha, (.digest // ""), .created_at]
            | @tsv') || die "$repo: falha ao listar artefatos"

    while IFS=$'\t' read -r id run_id head_sha digest created; do
        [[ -n "$id" ]] || continue
        run=$(gh api "repos/$repo/actions/runs/$run_id" \
            | jq -r --arg b "$branch" --arg p ".github/workflows/$workflow" --arg r "$repo" '
                select(.event == "push" and .conclusion == "success"
                       and .head_branch == $b and .path == $p
                       and .repository.full_name == $r
                       and .head_repository.full_name == $r)
                | .id') || die "$repo: falha ao consultar o run $run_id"
        [[ "$run" == "$run_id" ]] || continue

        echo "==> $repo $artifact: artefato $id do run $run_id ($head_sha, $created)"
        [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] \
            || die "$repo $artifact: artefato $id sem digest sha256 (upload-artifact < v4?)"

        zip=$(mktemp --suffix=.zip)
        gh api "repos/$repo/actions/artifacts/$id/zip" >"$zip" \
            || die "$repo $artifact: falha no download (o token precisa de leitura de Actions; ver README)"
        [[ "sha256:$(sha256sum "$zip" | cut -d' ' -f1)" == "$digest" ]] \
            || die "$repo $artifact: o sha256 do zip não confere com o digest da API"

        entries=$(unzip -Z1 "$zip")
        while read -r entry; do
            [[ "$entry" =~ ^[A-Za-z0-9@._+-]+$ ]] \
                || die "$repo $artifact: entrada não permitida no zip: '$entry'"
        done <<<"$entries"

        dest="$out/$artifact"
        [[ ! -e "$dest" ]] || die "artefato repetido em PACKAGE_SOURCES: $artifact"
        mkdir -p "$dest"
        unzip -q "$zip" -d "$dest"
        rm -f "$zip"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" "$workflow" "$artifact" \
            "$id" "$run_id" "$head_sha" "$digest" "$created" >>"$provenance"
        return 0
    done <<<"$candidates"

    die "$repo: nenhum artefato '$artifact' válido (run de push em $branch, sucesso, não expirado) do workflow $workflow. Rode o CI de $repo de novo."
}

count=0
while read -r repo workflow artifact extra; do
    [[ -z "$repo" || "$repo" == \#* ]] && continue
    [[ -z "${extra:-}" ]] || die "linha com campos demais em PACKAGE_SOURCES: $repo $workflow $artifact $extra"
    [[ "$repo" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || die "repositório inválido: $repo"
    [[ "$workflow" =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] || die "workflow inválido: $workflow"
    [[ "$artifact" =~ ^[A-Za-z0-9._-]+$ ]] || die "nome de artefato inválido: $artifact"
    fetch_one "$repo" "$workflow" "$artifact"
    count=$((count + 1))
done <<<"$PACKAGE_SOURCES"

((count > 0)) || die "PACKAGE_SOURCES não tem nenhuma fonte"
echo "==> $count artefato(s) baixados; proveniência em $provenance"
