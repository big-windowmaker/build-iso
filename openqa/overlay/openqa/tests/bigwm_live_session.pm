# SPDX-License-Identifier: GPL-2.0-or-later
#
# Big WindowMaker: depois do assistente live, a sessão é o Window Maker
# (startbiglive -> startbigwm) com o Dock completo, e um terminal abre janela.
use Mojo::Base 'basetest';
use testapi;
use bigwm;

sub test_flags {
    return {fatal => 1};
}

sub run {
    bigwm->assert_session('live');
    # O terminal padrão da edição, pelo mesmo caminho do menu do Window Maker.
    bigwm->assert_launches('Terminal (live)', 'xdg-terminal-exec', 90);
}

sub post_fail_hook {
    eval { select_console 'sut'; save_screenshot; };
}

1;
