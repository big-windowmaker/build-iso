# SPDX-License-Identifier: GPL-2.0-or-later
#
# Big WindowMaker: sessão Wayland (big-wm-wayland, wlmaker) no sistema
# instalado, no backend DRM real da VM (sem GPU: renderizador por software).
#
# Só para o teste: um drop-in do LightDM faz o login automático do usuário
# de teste na sessão big-wm-wayland e o sistema reinicia. Confere que o
# wlmaker roda como o usuário, que o socket WAYLAND_DISPLAY existe, que o
# Xwayland subiu e que o logind vê uma sessão Wayland; guarda captura de tela,
# log do LightDM, ~/.xsession-errors e o journal.
#
# Se a sessão não subir e BIGWM_WAYLAND_RETRY=1 (padrão), tenta de novo,
# só para diagnóstico e dizendo o que mudou: (1) se o Config.plist do
# wlmaker tem o layout de teclado "(unset)", troca por "us"; (2) se ainda
# falhar, WLR_RENDERER=pixman em /etc/environment. O resultado da sessão sem
# ajustes é o que vale: com BIGWM_WAYLAND_REQUIRED=1 uma falha reprova o
# módulo; com 0 (padrão, a sessão é experimental) vira soft failure.
use Mojo::Base 'basetest';
use testapi;
use atspi;
use biglinux;

sub test_flags {
    return {fatal => 0};
}

sub as_root {
    my ($command, $timeout) = @_;
    select_console 'user-virtio-terminal';
    biglinux->become_root or die 'sem root no console serial';
    select_console 'sut';
    my $status = atspi->run_command("sudo -n sh -c '$command'", $timeout // 60);
    die "comando como root falhou ($command): " . ($status // 'sem resposta')
      unless defined $status && $status == 0;
}

sub reboot_and_login {
    # Sem esperar marcador: o comando não volta, e a recuperação do
    # run_command digitaria texto no "login:" do boot seguinte.
    select_console 'user-virtio-terminal';
    type_string "sudo -n systemctl reboot\n";
    # O console serial loga de novo com a conta instalada depois do boot.
    reset_consoles;
    select_console 'user-virtio-terminal';
    select_console 'sut';
}

# Devolve um hash com o que a sessão Wayland do usuário apresenta.
sub probe {
    my ($label) = @_;
    my %result;
    my %checks = (
        wlmaker => 'pgrep -u "$(id -u)" -x wlmaker >/dev/null',
        socket => 'ls /run/user/"$(id -u)"/wayland-[0-9] >/dev/null 2>&1',
        xwayland => 'pgrep -u "$(id -u)" -x Xwayland >/dev/null',
        logind => 'loginctl show-session "$(loginctl show-user "$(id -un)" -p Display --value)" -p Type | grep -q Type=wayland',
    );
    # Primeiro espera o compositor (até 120 s); o resto deve estar de pé logo depois.
    my $first = atspi->run_command_until($checks{wlmaker}, 120);
    $result{wlmaker} = defined $first && $first == 0 ? 1 : 0;
    for my $name (qw(socket xwayland logind)) {
        my $status = atspi->run_command_until($checks{$name}, $result{wlmaker} ? 60 : 5);
        $result{$name} = defined $status && $status == 0 ? 1 : 0;
    }
    sleep 10;
    save_screenshot;

    # Evidências (sempre). O sudo do boot anterior não vale mais.
    select_console 'user-virtio-terminal';
    biglinux->become_root;
    select_console 'sut';
    my $evidence = "/tmp/openqa-wayland-$label.txt";
    atspi->run_command('{ echo "### ps do usuário"; ps -u "$(id -u)" -o pid=,rss=,args=; '
          . 'echo "### /run/user"; ls -la /run/user/"$(id -u)"/; '
          . 'echo "### loginctl"; loginctl list-sessions --no-legend; '
          . 'loginctl show-session "$(loginctl show-user "$(id -un)" -p Display --value)" 2>&1; '
          . 'echo "### localectl status"; localectl status 2>&1; '
          . 'echo "### Keyboard em ~/.config/wlmaker/Config.plist"; sed -n "/Keyboard/,/};/p" ~/.config/wlmaker/Config.plist 2>&1; '
          . 'echo "### coredumpctl list"; sudo -n coredumpctl list --no-pager 2>&1; '
          . 'echo "### ~/.xsession-errors"; tail -n 200 ~/.xsession-errors 2>&1; '
          . 'echo "### lightdm.log"; sudo -n tail -n 200 /var/log/lightdm/lightdm.log 2>&1; '
          . 'echo "### journalctl -b (lightdm, wlmaker, startbigwm, Xwayland, coredump)"; '
          . 'sudo -n journalctl -b --no-pager 2>&1 | grep -Ei "lightdm|wlmaker|startbigwm|xwayland|wlroots|coredump|segfault" | tail -n 300; '
          . "} >$evidence 2>&1", 120);
    atspi->upload_guest_file($evidence, "bigwm-wayland-$label.txt");
    record_info "Wayland ($label)", join "\n", map { "$_=$result{$_}" } sort keys %result;
    return \%result;
}

sub ok_session {
    my ($result) = @_;
    return !grep { !$result->{$_} } qw(wlmaker socket xwayland logind);
}

sub run {
    my $user = get_var('BIGLINUX_TEST_USER', 'openqa');
    die "usuário inválido: $user" unless $user =~ /\A[a-z_][a-z0-9_-]{0,31}\z/;

    # O PAM do LightDM só aceita login automático de quem está no grupo
    # autologin (pam_succeed_if); o Calamares não o põe lá (doAutologin: false).
    as_root("groupadd -rf autologin && gpasswd -a $user autologin >/dev/null && "
          . 'mkdir -p /etc/lightdm/lightdm.conf.d && '
          . 'printf "%s\n" "# openQA (teste): login automático na sessão Wayland" "[Seat:*]" '
          . "\"autologin-user=$user\" \"autologin-session=big-wm-wayland\" "
          . '>/etc/lightdm/lightdm.conf.d/99-openqa-wayland.conf');
    reboot_and_login;
    my $default = probe('padrao');
    if (ok_session($default)) {
        record_info 'Wayland', 'big-wm-wayland subiu com o renderizador padrão';
        return;
    }

    my $message = 'big-wm-wayland não subiu sem ajustes: '
      . join(', ', map { "$_=$default->{$_}" } sort keys %$default)
      . ' (ver ulogs/bigwm-wayland-padrao.txt)';
    if (get_var('BIGWM_WAYLAND_RETRY', 1)) {
        my $retry = $default;
        my $unset = atspi->run_command(q{grep -q 'Layout = "(unset)"' ~/.config/wlmaker/Config.plist}, 30);
        if (defined $unset && $unset == 0) {
            atspi->run_command(q{sed -i 's/Layout = "(unset)"/Layout = "us"/; s/Variant = "(unset)"/Variant = ""/; s/Model = "(unset)"/Model = "pc105"/; s/Options = "(unset)"/Options = ""/' ~/.config/wlmaker/Config.plist}, 30);
            reboot_and_login;
            $retry = probe('teclado-us');
            $message .= '; o Config.plist do wlmaker tinha Layout "(unset)" e, trocado por "us" (só no teste), a sessão '
              . (ok_session($retry) ? 'sobe' : 'ainda não sobe (ver ulogs/bigwm-wayland-teclado-us.txt)');
        }
        if (!ok_session($retry)) {
            as_root(q{grep -q "^WLR_RENDERER=" /etc/environment || echo WLR_RENDERER=pixman >>/etc/environment});
            reboot_and_login;
            my $pixman = probe('pixman');
            $message .= ok_session($pixman)
              ? '; com WLR_RENDERER=pixman a sessão sobe'
              : '; com WLR_RENDERER=pixman também não (ver ulogs/bigwm-wayland-pixman.txt)';
        }
    }
    die $message if get_var('BIGWM_WAYLAND_REQUIRED', 0);
    record_soft_failure $message;
}

sub post_fail_hook {
    eval { select_console 'sut'; save_screenshot; };
}

1;
