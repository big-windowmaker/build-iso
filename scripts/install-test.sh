#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# install-test.sh - teste de instalação da ISO do Big WindowMaker com o
# harness openQA da BigLinux (os-autoinst/isotovideo, sem servidor openQA).
#
# O que roda (plano bios ou uefi; ver openqa/README.md):
#   boot da ISO -> assistente live -> sessão Window Maker -> Calamares pela
#   árvore de acessibilidade (AT-SPI) -> "Apagar disco" -> usuário -> instalar
#   -> reiniciar pelo disco -> login no LightDM -> sessão big-wm -> saúde do
#   sistema instalado.
#
# Monta o harness em <out>/harness a partir de biglinux/iso-profiles no commit
# fixado em openqa/upstream.env (só openqa/ e data/), aplica openqa/patches/
# sem fuzz e copia openqa/overlay/ por cima. Depois chama o
# openqa/production/run-plan.sh da BigLinux, que executa o isotovideo no
# contêiner fixado por digest, com /dev/kvm. O código de saída é o do
# run-plan.sh (0 = todos os módulos ok).
#
# Saída em <out>:
#   artifacts/   o que vale guardar: testresults/ (capturas e resultado de
#                cada módulo), ulogs/ (logs enviados pelo convidado, inclusive
#                o session.log do Calamares), autoinst-log.txt, vars.json,
#                virtio_console.log, video.ogv e report/ (RESULTADO.md/.html)
#   results/     diretório de trabalho do isotovideo (o disco do convidado é
#                apagado no fim, a menos que --keep-disk)
#   harness/     o harness montado (CASEDIR)
#
# Requisitos: docker, /dev/kvm, git, patch, ruby (o run-plan.sh lê o YAML com
# ruby), python3 >= 3.11 (relatório). Não precisa de root.
set -euo pipefail

usage() {
    cat <<'EOF'
Uso: install-test.sh --iso ARQUIVO.iso --plan bios|uefi|live --out DIR
                     [--upstream DIR] [--ovmf-code F --ovmf-vars F]
                     [--setting KEY=VALUE]... [--timeout SEGUNDOS] [--keep-disk]

  --upstream DIR   checkout de biglinux/iso-profiles já no UPSTREAM_SHA (CI);
                   sem ele, o commit é baixado com git em <out>/upstream
  --setting K=V    configuração extra do isotovideo (repetível), por exemplo
                   STORAGE_KEEP_FREE_RATIO=0 num disco pequeno
  --timeout S      limite do plano (padrão 6600)
EOF
}

die() {
    printf 'install-test.sh: erro: %s\n' "$*" >&2
    exit 2
}
log() { printf '[install-test %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

iso="" plan="" out="" upstream="" ovmf_code="" ovmf_vars=""
timeout_seconds=6600
keep_disk=false
settings=()

while (($#)); do
    case "$1" in
        --iso) iso=${2:?}; shift 2 ;;
        --plan) plan=${2:?}; shift 2 ;;
        --out) out=${2:?}; shift 2 ;;
        --upstream) upstream=${2:?}; shift 2 ;;
        --ovmf-code) ovmf_code=${2:?}; shift 2 ;;
        --ovmf-vars) ovmf_vars=${2:?}; shift 2 ;;
        --setting) settings+=(--setting "${2:?}"); shift 2 ;;
        --timeout) timeout_seconds=${2:?}; shift 2 ;;
        --keep-disk) keep_disk=true; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck disable=SC1091 # UPSTREAM_REPO, UPSTREAM_SHA, OPENQA_IMAGE
. "$repo_root/openqa/upstream.env"

[[ -f "$iso" ]] || die "ISO não encontrada: $iso"
[[ "$plan" =~ ^(bios|uefi|live)$ ]] || die "--plan deve ser bios, uefi ou live"
[[ -n "$out" ]] || die "--out é obrigatório"
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || die "--timeout inválido"
[[ "$UPSTREAM_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "UPSTREAM_REPO inválido"
[[ "$UPSTREAM_SHA" =~ ^[0-9a-f]{40}$ ]] || die "UPSTREAM_SHA inválido"
if [[ "$plan" == uefi ]]; then
    [[ -f "$ovmf_code" && -f "$ovmf_vars" ]] || die "--ovmf-code e --ovmf-vars são obrigatórios para uefi"
fi
for tool in docker git patch ruby python3; do
    command -v "$tool" >/dev/null || die "$tool não instalado"
done
[[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm indisponível para este usuário"

# Imagem do isotovideo: o espelho no GHCR; sem acesso a ele (por exemplo sem
# docker login no ghcr.io), a origem no openSUSE com o mesmo digest.
image=$OPENQA_IMAGE
if ! docker image inspect "$image" >/dev/null 2>&1 && ! docker pull --quiet "$image" >/dev/null 2>&1; then
    [[ -n "${OPENQA_IMAGE_SOURCE:-}" && "${OPENQA_IMAGE_SOURCE##*@}" == "${OPENQA_IMAGE##*@}" ]] \
        || die "não foi possível baixar $image e não há origem com o mesmo digest"
    log "sem acesso a $image; usando a origem $OPENQA_IMAGE_SOURCE (mesmo digest)"
    image=$OPENQA_IMAGE_SOURCE
fi

mkdir -p -- "$out"
out=$(cd -- "$out" && pwd -P)
iso=$(realpath -- "$iso")

#--- 1. Harness da BigLinux no commit fixado --------------------------------

if [[ -z "$upstream" ]]; then
    upstream="$out/upstream"
    if [[ "$(git -C "$upstream" rev-parse HEAD 2>/dev/null || true)" != "$UPSTREAM_SHA" ]]; then
        log "Baixando $UPSTREAM_REPO@$UPSTREAM_SHA"
        rm -rf -- "$upstream"
        git init --quiet "$upstream"
        git -C "$upstream" fetch --quiet --depth 1 "https://github.com/$UPSTREAM_REPO.git" "$UPSTREAM_SHA"
        git -C "$upstream" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
    fi
fi
head_sha=$(git -C "$upstream" rev-parse HEAD)
[[ "$head_sha" == "$UPSTREAM_SHA" ]] || die "o checkout em $upstream está em $head_sha, esperado $UPSTREAM_SHA"

harness="$out/harness"
rm -rf -- "$harness"
mkdir -p -- "$harness"
git -C "$upstream" archive --format=tar "$UPSTREAM_SHA" openqa data | tar -x -C "$harness"

for p in "$repo_root"/openqa/patches/*.patch; do
    log "Patch: ${p##*/}"
    patch -d "$harness" -p1 --forward --batch --fuzz=0 --quiet <"$p" \
        || die "o patch ${p##*/} não se aplica a $UPSTREAM_REPO@$UPSTREAM_SHA"
done
cp -a -- "$repo_root/openqa/overlay/." "$harness/"
# Servido à VM pelo isotovideo (data_url) para o módulo bigwm_metrics.
install -m 0644 -- "$repo_root/scripts/vm-metrics.sh" "$harness/data/vm-metrics.sh"
find "$harness" -name '*.orig' -delete

#--- 2. Execução ----------------------------------------------------------------

# Senha do usuário criado no Calamares: aleatória, num arquivo que o contêiner
# lê sem passar por vars.json (que é publicado). Ver openqa/README.md da BigLinux.
umask 077
secret_dir="$out/secret"
mkdir -p -- "$secret_dir"
password_file="$secret_dir/test-password"
python3 -c 'import secrets; print(secrets.token_hex(18), end="")' >"$password_file"
umask 022
[[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::add-mask::$(<"$password_file")"

results="$out/results"
rm -rf -- "$results"
mkdir -p -- "$results"

args=(
    --plan "$plan" --iso "$iso" --results "$results"
    --password-file "$password_file" --image "$image"
    --build "${INSTALL_TEST_BUILD:-local}"
    --commit "$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)"
    --iso-sha256 "${INSTALL_TEST_ISO_SHA256:-$(sha256sum -- "$iso" | cut -d' ' -f1)}"
    --timeout "$timeout_seconds"
    "${settings[@]}"
)
if [[ "$plan" == uefi ]]; then
    # Cópia gravável das variáveis: o Calamares grava a entrada de boot nela.
    install -m 0444 -- "$ovmf_code" "$out/OVMF_CODE.fd"
    install -m 0666 -- "$ovmf_vars" "$out/OVMF_VARS.fd"
    args+=(--uefi-code "$out/OVMF_CODE.fd" --uefi-vars "$out/OVMF_VARS.fd")
fi

log "Plano $plan: $(basename -- "$iso") (harness $UPSTREAM_REPO@${UPSTREAM_SHA:0:12} + patches + overlay)"
set +e
# bash explícito: o diretório de saída pode estar num /tmp montado com noexec.
bash "$harness/openqa/production/run-plan.sh" "${args[@]}"
status=$?
set -e

#--- 3. Evidências --------------------------------------------------------------

artifacts="$out/artifacts"
rm -rf -- "$artifacts"
mkdir -p -- "$artifacts"
for evidence in testresults ulogs autoinst-log.txt vars.json virtio_console.log \
    serial0 serial_terminal.txt video.ogv video_time.vtt report; do
    [[ -e "$results/$evidence" ]] && cp -a -- "$results/$evidence" "$artifacts/"
done
# Nenhum arquivo publicado pode conter a senha gerada.
secret=$(<"$password_file")
while IFS= read -r -d '' file; do
    SECRET_TO_REDACT="$secret" perl -0pi -e 's/\Q$ENV{SECRET_TO_REDACT}\E/[REDACTED]/g' "$file"
done < <(find "$artifacts" -type f \( -name '*.txt' -o -name '*.log' -o -name '*.json' \
    -o -name '*.md' -o -name '*.html' -o -name 'serial0' \) -print0)
if grep -rqF -- "$secret" "$artifacts" 2>/dev/null; then
    log "AVISO: a senha aparece num arquivo binário das evidências; removendo os vídeos"
    rm -f -- "$artifacts/video.ogv"
fi

if ! $keep_disk; then
    # O disco do convidado (qcow2 de HDDSIZEGB) e o ISO de trabalho.
    rm -rf -- "$results/raid" "$results/pool" "$results"/*.qcow2 2>/dev/null || true
fi

{
    echo "### Teste de instalação ($plan)"
    echo
    if [[ -s "$artifacts/report/RESULTADO.md" ]]; then
        sed 's/^## Resultado$//' "$artifacts/report/RESULTADO.md"
    else
        echo "Sem relatório; ver autoinst-log.txt no artefato."
    fi
} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"

if ((status == 0)); then
    log "APROVADO ($plan). Evidências: $artifacts"
else
    log "REPROVADO ($plan, código $status). Evidências: $artifacts"
fi
exit "$status"
