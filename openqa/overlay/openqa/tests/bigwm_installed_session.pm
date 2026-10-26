# SPDX-License-Identifier: GPL-2.0-or-later
#
# Big WindowMaker: no sistema instalado, o login pelo LightDM abre a sessão
# padrão big-wm (startbigwm, não o wmaker.desktop genérico) com o Dock
# completo, e um terminal abre janela.
use Mojo::Base 'basetest';
use testapi;
use atspi;
use bigwm;

sub test_flags {
    return {fatal => 1};
}

sub run {
    bigwm->assert_session('instalado');
    bigwm->assert_launches('Terminal (instalado)', 'xdg-terminal-exec', 90);

    # Evidência: configuração do LightDM que o Calamares deixou.
    atspi->run_command(q{grep -rhs -E '^[[:space:]]*(user-session|autologin-session|autologin-user|greeter-session)[[:space:]]*=' /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.d/ > /tmp/openqa-bigwm-lightdm.txt 2>&1; true}, 30);
    atspi->upload_guest_file('/tmp/openqa-bigwm-lightdm.txt', 'bigwm-lightdm-installed.txt');
}

sub post_fail_hook {
    eval { select_console 'sut'; save_screenshot; };
}

1;
