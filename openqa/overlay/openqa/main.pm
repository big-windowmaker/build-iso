# SPDX-License-Identifier: GPL-2.0-or-later
#
# Big WindowMaker: substitui o openqa/main.pm da BigLinux no harness montado
# por scripts/install-test.sh. Os módulos openqa/tests/*.pm são os da BigLinux
# (com os patches de openqa/patches/ do build-iso); bigwm_*.pm são nossos.

use Mojo::Base -strict;
use autotest;
use File::Basename 'dirname';
use lib dirname(__FILE__) . '/lib';
use biglinux;
use testapi;

testapi::set_distribution(biglinux->new);

# Instalação pelo Calamares (particionamento automático "Apagar disco"),
# reinício pelo disco instalado, login no LightDM e verificações do sistema.
# Ficam de fora, por dependerem do KDE Plasma ou só fazerem sentido lá:
# applications (auditoria de todos os .desktop), installed_reader (Orca na
# tela de bloqueio e no polkit do Plasma), installed_critical_apps
# (aplicativos KDE da política) e os testes opcionais nonvisual_tasks e
# installed_brave.
# bigwm_metrics coleta métricas logo após o login e depois de 5 min ocioso.
my @install = map { "openqa/tests/$_.pm" } qw(
    installer_launch installer_partitions installer_user installer_install
    installed_boot installed_login bigwm_installed_session bigwm_metrics
    installed_health installed_security
);
my @live = map { "openqa/tests/$_.pm" } qw(live_desktop bigwm_live_session);

my %schedules = (
    # Só a sessão live: falha em minutos; útil numa ISO nova.
    bigwm_live => [@live],
    # O plano completo (BIOS e UEFI usam o mesmo).
    bigwm_install => [@live, @install],
    # Outras edições BigCommunity (por exemplo a XFCE, para desenvolver o
    # harness sem a ISO do Window Maker): sem as verificações bigwm_*.
    generic_install => [grep { !m{/bigwm_} } @live, @install],
);

my $schedule = get_var('BIGLINUX_SCHEDULE', 'bigwm_live');
die "Unknown openQA schedule '$schedule'" unless exists $schedules{$schedule};
autotest::loadtest($_) for @{$schedules{$schedule}};

1;
