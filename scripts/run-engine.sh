#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# run-engine.sh - executa o motor de ISO da BigLinux (biglinux/iso-profiles,
# build-iso/build-iso.sh) com o repositório local [bigwm-local] injetado.
#
# Roda como root dentro do contêiner privilegiado de build. Variáveis:
#   ENGINE_DIR        checkout do biglinux/iso-profiles (fixado por SHA)
#   BIGWM_LOCAL_REPO  diretório absoluto do repositório local (bigwm-local.db)
#   + o contrato de ambiente do motor (EDITION, KERNEL, PROFILES_ROOT,
#     DISTRONAME, BIGCOMMUNITY_BRANCH, WORK_PATH...; ver build-iso/README.md
#     do motor).
#
# Por que não basta editar os arquivos antes de chamar o motor:
#
#   O buildiso monta os chroots com /usr/share/manjaro-tools/pacman-<arch>.conf
#   (pacman-multilib.conf em x86_64). Esses arquivos pertencem ao pacote
#   manjaro-tools-base-git, que o próprio motor atualiza/instala em
#   prepare_host (pacman -Syu; pacman -S --needed manjaro-tools-*): uma
#   atualização do pacote substitui os arquivos e apaga a injeção. Depois,
#   configure_build_repos anexa [biglinux-priority] (antes de [core]) e as
#   seções community-*/biglinux-*. Nada mais reescreve esses arquivos até o
#   buildiso, que os lê em load_profile (get_pacman_conf) e os passa ao
#   mkchroot/basestrap (-C).
#
#   Por isso a injeção acontece imediatamente antes do buildiso: este script
#   carrega o motor com `source` (interface que o próprio motor suporta, é
#   como os testes dele o usam), embrulha a etapa run_build e chama o main()
#   original do motor, sem reimplementar a ordem das etapas.
#
#   O repositório file:// é lido pelo pacman do contêiner (basestrap usa
#   pacman --root no chroot), não de dentro do chroot. O único pacman que roda
#   dentro de um chroot (copy_from_cache, imagem mhwd) usa o pacman.conf do
#   perfil, que não recebe [bigwm-local]; por isso a ISO final também não
#   carrega o repositório local (o pacman.conf instalado é o do perfil).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
engine="${ENGINE_DIR:?ENGINE_DIR não definido}/build-iso/build-iso.sh"
local_repo="${BIGWM_LOCAL_REPO:?BIGWM_LOCAL_REPO não definido}"

[[ -f "$engine" ]] || { echo "run-engine.sh: motor não encontrado: $engine" >&2; exit 1; }

# shellcheck source=/dev/null
source "$engine"

# O motor foi carregado com set -euo pipefail e define msg/die.
for fn in main run_build configure_build_repos configure_profile prepare_host; do
    declare -F "$fn" >/dev/null || die "o motor não define $fn(): versão incompatível com run-engine.sh"
done

# A injeção depende de run_build vir depois de prepare_host e
# configure_build_repos. Se uma atualização do motor mudar isso, falhar aqui,
# em segundos, e não com um build de horas sem o repositório local.
main_body=$(declare -f main)
order=$(grep -o -E '\b(prepare_host|configure_build_repos|run_build)\b' <<<"$main_body" | paste -sd' ' -)
[[ "$order" == "prepare_host configure_build_repos run_build" ]] \
    || die "ordem inesperada das etapas em main() do motor: '$order'"

# configure_profile (embrulhado abaixo) precisa vir antes de run_build.
order=$(grep -o -E '\b(configure_profile|run_build)\b' <<<"$main_body" | paste -sd' ' -)
[[ "$order" == "configure_profile run_build" ]] \
    || die "ordem inesperada de configure_profile/run_build em main() do motor: '$order'"

eval "bigwm_engine_$(declare -f run_build)"

# O motor grava os repositórios do sistema instalado (community-*, biglinux-*
# e o ramo) em shared/pacman.conf, que as edições usam por link. A edição
# wmaker tem um pacman.conf próprio (IgnorePkg = windowmaker, ver o arquivo),
# que o motor não conhece: o sistema instalado saía só com [biglinux-priority]
# e os repositórios da Manjaro, sem BigCommunity nem BigLinux (pamac sem
# atualizações nem programas deles). Depois da etapa do motor, o arquivo da
# edição é refeito a partir do shared/pacman.conf final, com as linhas
# IgnorePkg ativas da edição no [options].
eval "bigwm_engine_$(declare -f configure_profile)"

configure_profile() {
    bigwm_engine_configure_profile "$@"
    local shared="$PROFILES_ROOT/shared/pacman.conf"
    local own="$PROFILES_ROOT/$DISTRONAME/$EDITION/root-overlay/etc/pacman.conf"
    [[ -f "$own" && ! -L "$own" && -f "$shared" ]] || return 0
    msg "big-windowmaker: repositórios do shared/pacman.conf no pacman.conf da edição"
    local ignore merged
    ignore=$(grep -E '^[[:space:]]*IgnorePkg[[:space:]]*=' "$own" || true)
    merged=$(mktemp)
    awk -v ignore="$ignore" '
        /^\[options\]/ { opts = 1 }
        opts && !done && (/^#?IgnorePkg/ || /^\[/ && !/^\[options\]/) {
            if (ignore != "") print ignore
            done = 1
        }
        /^\[/ && !/^\[options\]/ { opts = 0 }
        { print }' "$shared" >"$merged"
    cat "$merged" >"$own"
    rm -f "$merged"
    local section
    for section in community-stable community-extra biglinux-stable biglinux-extra; do
        assert_present "^\\[$section\\]" "$own"
    done
    [[ -z "$ignore" ]] || assert_present '^[[:space:]]*IgnorePkg[[:space:]]*=' "$own"
}

run_build() {
    msg "big-windowmaker: injetando [bigwm-local] nas configurações do buildiso"
    bash "$here/inject-local-repo.sh" "$local_repo" \
        /usr/share/manjaro-tools/pacman-default.conf \
        /usr/share/manjaro-tools/pacman-multilib.conf
    bash "$here/preflight-local-repo.sh" "$local_repo" \
        /usr/share/manjaro-tools/pacman-multilib.conf
    bigwm_engine_run_build "$@"
}

main "$@"
