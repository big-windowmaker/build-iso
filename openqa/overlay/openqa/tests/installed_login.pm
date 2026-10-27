# SPDX-License-Identifier: GPL-3.0-or-later
#
# Big WindowMaker: substitui o installed_login.pm da BigLinux no harness.
# Mesmo teste (tela de login do sistema instalado -> senha -> desktop), com o
# passo a mais que o wdm (WINGs Display Manager) pede: a tela abre na lista
# de usuários, com o último (no primeiro boot, o único) já escolhido, e Enter
# leva ao campo de senha. Com outro greeter (BIGLINUX_GREETER), igual ao
# original.
use Mojo::Base 'basetest';
use testapi;
use installed_system;

sub test_flags {
    return {fatal => 1};
}

sub run {
    installed_system->assert_greeter;
    save_screenshot;
    if (get_var('BIGLINUX_GREETER', '') eq 'wdmLogin') {
        send_key 'ret';
        sleep 2;
        save_screenshot;
    }
    type_password(installed_system->test_password);
    send_key 'ret';
    installed_system->assert_desktop;
    record_info 'Coverage boundary', 'Keyboard login on the installed display manager is functional evidence, not reader certification';
}

1;
