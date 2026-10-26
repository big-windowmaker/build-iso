# SPDX-License-Identifier: GPL-2.0-or-later
#
# Big WindowMaker: verificações da sessão Window Maker (live e instalada).
#
# Parte do overlay do build-iso sobre o harness openQA da BigLinux
# (biglinux/iso-profiles, openqa/). Usa só a API pública daquele harness:
# atspi->run_command (console serial do usuário da sessão), launch_command e
# cleanup (janela acessível de um processo lançado na sessão gráfica).
package bigwm;

use Mojo::Base -strict;
use testapi;
use atspi;
use guest_shell qw(marker_format shell_quote);

# Dockapps com AutoLaunch = YES no WMState padrão (big-wm,
# data/GNUstep/Defaults/WMState). O relógio é o wmclock iniciado por
# big-wm-clock.
our @DOCKAPPS = qw(wmclock wmsystemtray wmix wmcpuload wmmemload wmnet);

# Lê uma linha "chave=valor;..." impressa pelo convidado. O marcador é
# impresso com printf e escapes octais, então o eco do comando digitado não
# satisfaz a espera (ver guest_shell::marker_format).
sub _probe {
    my ($marker, $script, $timeout) = @_;
    select_console 'user-virtio-terminal';
    my $format = marker_format($marker);
    type_string "$script; printf '${format}%s${format}\\n' \"\$bwm_out\"\n";
    my $answer = wait_serial(qr/\Q$marker\E(.*?)\Q$marker\E/, timeout => $timeout // 60);
    select_console 'sut';
    die "a sonda $marker não respondeu" unless defined $answer;
    my ($fields) = $answer =~ /\Q$marker\E(.*?)\Q$marker\E/;
    my %result = map { split /=/, $_, 2 } grep { /=/ } split /;/, $fields;
    return \%result;
}

# Confere a sessão Window Maker do usuário do console serial:
#   - wmaker do usuário em execução, iniciado pelo wrapper startbigwm
#     (sessão big-wm, não o wmaker.desktop genérico);
#   - big-wm-session.target e graphical-session.target ativos no systemd --user;
#   - cada dockapp padrão em execução;
#   - XDG_CURRENT_DESKTOP=WindowMaker no ambiente do systemd --user.
# $context aparece nas mensagens ("live" ou "instalado").
sub assert_session {
    my ($class, $context) = @_;
    my $dockapps = join ' ', @DOCKAPPS;
    my $script = join ' ',
      'bwm_uid=$(id -u);',
      # Espera até 120 s pelo wmaker: logo depois do login a sessão ainda sobe.
      'bwm_i=0; while [ $bwm_i -lt 120 ] && ! pgrep -u "$bwm_uid" -x wmaker >/dev/null; do sleep 1; bwm_i=$((bwm_i+1)); done;',
      # Dá tempo ao AutoLaunch do Dock.
      'sleep 10;',
      'bwm_yes() { "$@" >/dev/null 2>&1 && echo 1 || echo 0; };',
      'bwm_out="wmaker=$(bwm_yes pgrep -u "$bwm_uid" -x wmaker)";',
      'bwm_out="$bwm_out;startbigwm=$(bwm_yes pgrep -u "$bwm_uid" -f /usr/bin/startbigwm)";',
      'bwm_out="$bwm_out;target=$(systemctl --user is-active big-wm-session.target 2>/dev/null)";',
      'bwm_out="$bwm_out;graphical=$(systemctl --user is-active graphical-session.target 2>/dev/null)";',
      'bwm_out="$bwm_out;desktop=$(systemctl --user show-environment 2>/dev/null | sed -n s/^XDG_CURRENT_DESKTOP=//p)";',
      'bwm_missing=; for bwm_app in ' . $dockapps . '; do pgrep -u "$bwm_uid" -x "$bwm_app" >/dev/null || bwm_missing="$bwm_missing,$bwm_app"; done;',
      'bwm_out="$bwm_out;missing=${bwm_missing#,}";',
      # Evidência para o relatório: processos gráficos do usuário.
      'ps -u "$bwm_uid" -o pid=,args= > /tmp/openqa-bigwm-processes.txt 2>&1';
    my $result = _probe('__BWM_SESSION__', $script, 240);
    atspi->upload_guest_file('/tmp/openqa-bigwm-processes.txt', "bigwm-processes-$context.txt");
    record_info "Sessão $context", join("\n", map { "$_=" . ($result->{$_} // '') } sort keys %$result);
    save_screenshot;

    die "Window Maker ($context): nenhum processo wmaker do usuário"
      unless ($result->{wmaker} // 0) == 1;
    die "Window Maker ($context): a sessão não foi iniciada por startbigwm (sessão big-wm)"
      unless ($result->{startbigwm} // 0) == 1;
    die "Window Maker ($context): big-wm-session.target está '" . ($result->{target} // '') . "'"
      unless ($result->{target} // '') eq 'active';
    die "Window Maker ($context): graphical-session.target está '" . ($result->{graphical} // '') . "'"
      unless ($result->{graphical} // '') eq 'active';
    die "Window Maker ($context): XDG_CURRENT_DESKTOP do systemd --user é '" . ($result->{desktop} // '') . "'"
      unless ($result->{desktop} // '') eq 'WindowMaker';
    die "Window Maker ($context): dockapps ausentes: $result->{missing}"
      if length($result->{missing} // '');
    return $result;
}

# Abre um programa na sessão gráfica (pelo supervisor do harness, com o
# ambiente do systemd --user) e exige uma janela acessível do próprio processo.
# Fecha depois com o cleanup do harness: aqui só interessa provar que a
# sessão abre janelas, não o contrato de fechamento do aplicativo.
sub assert_launches {
    my ($class, $label, $command, $timeout) = @_;
    atspi->reset_baseline;
    my (undef, $opened, undef, undef, $status_path) =
      atspi->launch_command($command, '', $timeout // 90, 'process-tree');
    save_screenshot;
    my $ok = ref $opened eq 'HASH' && ($opened->{status} // '') eq 'passed';
    my $error = $ok ? '' : ($opened->{error} // 'sem resposta');
    eval { atspi->abort_launch($status_path) } if !$ok && defined $status_path;
    eval { atspi->cleanup(30) };
    die "$label não abriu uma janela acessível: $error" unless $ok;
    atspi->record_guest_info($label, 'janela acessível: ' . ($opened->{window} // $opened->{name} // '?'));
    return $opened;
}

1;
