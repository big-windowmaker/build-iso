# SPDX-License-Identifier: GPL-2.0-or-later
#
# Big WindowMaker: métricas do sistema instalado logo depois do login gráfico
# e de novo após BIGWM_IDLE_SECONDS (padrão 300) ocioso. Só coleta: a saída
# literal de data/vm-metrics.sh (scripts/vm-metrics.sh do build-iso) vai para
# ulogs/bigwm-metrics-installed-*.txt; nada aqui reprova a instalação.
use Mojo::Base 'basetest';
use testapi;
use atspi;
use biglinux;
use guest_shell qw(shell_quote);

sub test_flags {
    return {fatal => 0};
}

sub collect {
    my ($user, $mode, $label) = @_;
    my $url = data_url('vm-metrics.sh');
    my $file = "/tmp/openqa-metrics-$label.txt";
    my $status = atspi->run_command(
        'curl --fail --silent --show-error --max-time 15 ' . shell_quote($url)
          . ' --output /tmp/vm-metrics.sh && sudo -n bash /tmp/vm-metrics.sh '
          . shell_quote($user) . " $mode " . shell_quote($label) . " >$file 2>&1", 240);
    atspi->upload_guest_file($file, "bigwm-metrics-installed-$label.txt");
    record_soft_failure "métricas $label: a coleta terminou com código " . ($status // 'sem resposta')
      unless defined $status && $status == 0;
}

sub run {
    my $user = get_var('BIGLINUX_TEST_USER', 'openqa');
    die "usuário inválido: $user" unless $user =~ /\A[a-z_][a-z0-9_-]{0,31}\z/;
    select_console 'user-virtio-terminal';
    unless (biglinux->become_root) {
        select_console 'sut';
        record_soft_failure 'métricas: sem root no console serial; nada foi coletado';
        return;
    }
    select_console 'sut';
    collect($user, 'completo', 'sessao');

    my $idle = get_var('BIGWM_IDLE_SECONDS', 300);
    die "BIGWM_IDLE_SECONDS inválido: $idle" unless $idle =~ /\A[0-9]{1,4}\z/;
    if ($idle > 0) {
        sleep $idle;
        # O sudo -v do become_root expira em minutos: renova antes.
        select_console 'user-virtio-terminal';
        biglinux->become_root;
        select_console 'sut';
        collect($user, 'memoria', "ocioso-${idle}s");
    }
    else {
        record_info 'Métricas ocioso', 'não coletadas (BIGWM_IDLE_SECONDS=0)';
    }
}

1;
