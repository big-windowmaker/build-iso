# SPDX-License-Identifier: GPL-3.0-or-later
#
# Big WindowMaker: a sessão live entra pela tela do wdm (WINGs Display
# Manager), não por login automático. A tela abre na lista de usuários com o
# usuário live (BIGLINUX_LIVE_USER) escolhido e a sessão "Big WindowMaker
# Live" (o assistente e depois o Window Maker) como padrão: Enter leva ao
# campo de senha, a senha live (BIGLINUX_LIVE_PASSWORD), Enter. Roda antes do
# live_desktop, que espera o assistente já aberto.
use Mojo::Base 'basetest';
use testapi;
use installed_system;

sub test_flags {
    return {fatal => 1};
}

sub run {
    # O mesmo processo da tela do sistema instalado (BIGLINUX_GREETER).
    installed_system->assert_greeter;
    save_screenshot;
    wait_still_screen(stilltime => 2, timeout => 60);
    die 'wdm: o Enter na lista de usuários não abriu o campo de senha'
      unless wait_screen_change(sub { send_key 'ret' }, 20);
    wait_still_screen(stilltime => 1, timeout => 15);
    type_password(get_var('BIGLINUX_LIVE_PASSWORD', 'big'));
    send_key 'ret';
    save_screenshot;
    record_info 'Live login', 'wdm: ' . get_var('BIGLINUX_LIVE_USER', 'bigwindowmaker') . ' entrou pela tela de login';
}

1;
