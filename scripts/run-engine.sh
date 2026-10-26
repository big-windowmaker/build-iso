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
for fn in main run_build configure_build_repos prepare_host; do
    declare -F "$fn" >/dev/null || die "o motor não define $fn(): versão incompatível com run-engine.sh"
done

# A injeção depende de run_build vir depois de prepare_host e
# configure_build_repos. Se uma atualização do motor mudar isso, falhar aqui,
# em segundos, e não com um build de horas sem o repositório local.
main_body=$(declare -f main)
order=$(grep -o -E '\b(prepare_host|configure_build_repos|run_build)\b' <<<"$main_body" | paste -sd' ' -)
[[ "$order" == "prepare_host configure_build_repos run_build" ]] \
    || die "ordem inesperada das etapas em main() do motor: '$order'"

eval "bigwm_engine_$(declare -f run_build)"

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
