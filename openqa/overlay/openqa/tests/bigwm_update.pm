# SPDX-License-Identifier: GPL-2.0-or-later
#
# Big WindowMaker: atualização do sistema instalado.
#
# Como root, no sistema que o Calamares instalou: pacman -Syu com os
# repositórios configurados pelo instalador, instalação e remoção de um pacote
# de teste e conferência dos arquivos dos pacotes do Big WindowMaker
# (pacman -Qkk). Depois reinicia; o módulo seguinte (bigwm_wayland_session)
# faz o login no sistema já atualizado.
#
# A saída completa vai para ulogs/bigwm-update.txt. Falha do pacman reprova o
# módulo: atualizar é parte do que o sistema instalado precisa fazer.
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
    return atspi->run_command("sudo -n sh -c '$command'", $timeout // 60);
}

sub run {
    my $log = '/tmp/openqa-bigwm-update.txt';
    my %result;

    $result{sincronizar} = as_root("pacman -Syu --noconfirm >$log 2>&1", 2400);
    $result{instalar} = as_root("pacman -S --noconfirm xorg-xeyes >>$log 2>&1", 600);
    $result{remover} = as_root("pacman -Rns --noconfirm xorg-xeyes >>$log 2>&1", 300);
    # pacman -Qkk dos pacotes do Big WindowMaker. Alterações em
    # /usr/share/applications/*.desktop são esperadas: no primeiro boot o
    # big-first-boot da BigLinux roda render-menu-options.sh, que acrescenta a
    # ação "Software Render" a todo .desktop. Qualquer outro arquivo alterado
    # reprova.
    my $qkk = '/tmp/openqa-bigwm-qkk.txt';
    as_root("LC_ALL=C pacman -Qkk big-wm-session big-wm-themes big-wm-wayland windowmaker wlmaker >$qkk 2>&1; "
          . "cat $qkk >>$log", 300);
    $result{integridade} = as_root(
        "! grep -E \"^warning: \" $qkk | grep -v -E \" /usr/share/applications/[^ ]+[.]desktop \"", 60);
    as_root("{ echo; echo \"### pacman -Q (Big WindowMaker)\"; pacman -Q big-wm-session big-wm-themes big-wm-wayland windowmaker wlmaker; } >>$log 2>&1", 60);
    as_root("chmod 644 $log", 30);
    atspi->upload_guest_file($log, 'bigwm-update.txt');

    my $summary = join "\n", map { "$_=" . ($result{$_} // 'sem resposta') } sort keys %result;
    record_info 'Atualização', $summary;
    my @failed = grep { !defined $result{$_} || $result{$_} != 0 } sort keys %result;
    die "falhou: @failed (ver ulogs/bigwm-update.txt)" if @failed;

    # Reinício: o próximo módulo entra no sistema atualizado.
    select_console 'user-virtio-terminal';
    type_string "sudo -n systemctl reboot\n";
    reset_consoles;
    select_console 'user-virtio-terminal';
    select_console 'sut';
    my $boot = atspi->run_command_until('systemctl is-active graphical.target >/dev/null && '
          . '[ -z "$(systemctl --failed --no-legend)" ]', 300);
    die 'depois da atualização o sistema não chegou ao graphical.target sem unidades com falha'
      unless defined $boot && $boot == 0;
    record_info 'Reinício', 'graphical.target ativo e nenhuma unidade com falha depois da atualização';
}

sub post_fail_hook {
    eval { select_console 'sut'; save_screenshot; };
}

1;
