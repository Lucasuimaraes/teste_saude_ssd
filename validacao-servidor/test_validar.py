import os
import pty
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name('validar-servidor.sh')

class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='test-validar-')
        self.root = Path(self.tmp.name)
        self.report = self.root / 'report'
        (self.report / 'logs').mkdir(parents=True)
        (self.report / 'resultados.tsv').write_text('etapa\tstatus\tteste\tcodigo\tdetalhes\tlog\n')
        (self.report / 'comandos.txt').touch()
        (self.report / 'temperatura_memoria.tsv').write_text('data\ttemp\tmem\n')

    def tearDown(self):
        self.tmp.cleanup()

    def bash(self, code):
        env = dict(os.environ, SCRIPT=str(SCRIPT), TEST_REPORT=str(self.report), TEST_ROOT=str(self.root))
        return subprocess.run(['bash', '-c', 'source "$SCRIPT"\nREPORT=$TEST_REPORT\n' + code], env=env, text=True, capture_output=True, timeout=20)

    def test_syntax(self):
        self.assertEqual(subprocess.run(['bash', '-n', str(SCRIPT)]).returncode, 0)

    def test_cli_guards(self):
        for args in [['--modo', 'completo'], ['--disco', '/dev/sda1'], ['--etapas', '12'], ['--memoria-mb', '9999'], ['--interface', 'eth0;id'], ['--saida', 'relative'], ['--nome-dns', '-bad'], ['--modo'], ['--unknown']]:
            with self.subTest(args=args):
                result = subprocess.run(['bash', str(SCRIPT), *args], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2, result.stderr)

    def test_stage_selection(self):
        self.assertEqual(self.bash('STEPS=1,5,11; selected 1 && selected 5 && selected 11 && ! selected 2 && ! selected 10').returncode, 0)

    def test_version(self):
        r = subprocess.run(['bash', str(SCRIPT), '--versao'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), 'validar-servidor 1.2.0')

    def test_journal_failure_is_not_server_failure(self):
        (self.root/'journal').write_text('Failed to parse timestamp\n')
        r = self.bash('classify journal 1 "$TEST_ROOT/journal"; [[ $STATUS == INCONCLUSIVO ]]')
        self.assertEqual(r.returncode, 0)
        (self.root/'journal').write_text('')
        r = self.bash('classify journal 0 "$TEST_ROOT/journal"; [[ $STATUS == OK ]]')
        self.assertEqual(r.returncode, 0)
        (self.root/'journal').write_text('Sep 23 systemd: service failed\n')
        r = self.bash('classify journal 0 "$TEST_ROOT/journal"; [[ $STATUS == ATENCAO ]]')
        self.assertEqual(r.returncode, 0)

    def test_journal_timestamp(self):
        r = self.bash('''
START_JOURNAL='2026-09-23 14:20:29'
VALID_DISKS=()
run() {
 LAST_LOG=$REPORT/logs/simulado.txt; LAST_RC=0
 if [[ $1 == 'Erros novos desde início da validação' ]]; then
   printf '%s\\n' "$@" > "$TEST_ROOT/journal-args"
 fi
}
step11
''')
        self.assertEqual(r.returncode, 0, r.stderr)
        args = (self.root/'journal-args').read_text().splitlines()
        self.assertEqual(args[args.index('--since')+1], '2026-09-23 14:20:29')

    def test_network_target_without_default_route(self):
        r = self.bash('''
parse_args --interface lo --alvo-rede lo=127.0.0.1
ip() { :; }
run() {
 LAST_LOG=$REPORT/logs/simulado.txt; LAST_RC=0
 printf '%s\\n' "$*" >> "$TEST_ROOT/network-args"
 record COLETADO "$1" SIMULADO
}
step2
''')
        self.assertEqual(r.returncode, 0, r.stderr)
        args = (self.root/'network-args').read_text()
        self.assertIn('Destino local 127.0.0.1 via lo', args)
        self.assertIn('ping -n -I lo -c 50 -W 2 127.0.0.1', args)
        self.assertNotIn('Internet 8.8.8.8 via lo', args)

    def test_failed_unit_details(self):
        (self.root/'failed').write_text('example.service loaded failed failed Example\n')
        r = self.bash('''
LAST_LOG=$TEST_ROOT/failed; LAST_RC=0
run() { printf '%s\\n' "$*" >> "$TEST_ROOT/units-args"; }
failed_details
''')
        self.assertEqual(r.returncode, 0, r.stderr)
        args = (self.root/'units-args').read_text()
        self.assertIn('systemctl status example.service', args)
        self.assertIn('journalctl -u example.service', args)

    @unittest.skipUnless(os.geteuid() == 0, 'Instalador exige root; utiliza apenas prefixo temporário.')
    def test_installer_and_update_backup(self):
        installer = SCRIPT.with_name('instalar.sh')
        prefix = self.root/'installed'
        args = ['bash', str(installer), '--prefix', str(prefix)]
        first = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(first.returncode, 0, first.stderr)
        dest = prefix/'sbin/validar-servidor'
        self.assertEqual(dest.read_bytes(), SCRIPT.read_bytes())
        second = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(second.returncode, 0, second.stderr)
        backups = list((prefix/'share/validar-servidor/backups').glob('*.sh'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), SCRIPT.read_bytes())
        self.assertTrue((prefix/'share/doc/validar-servidor/MANUAL_USO_VALIDAR_SERVIDOR.txt').exists())

    def test_smart_bitmask(self):
        r = self.bash('for pair in 0:COLETADO 4:ATENCAO 8:FALHA 16:FALHA 64:ATENCAO 128:ATENCAO 124:INCONCLUSIVO; do classify smart "${pair%%:*}" /dev/null; [[ $STATUS == "${pair#*:}" ]] || exit 9; done')
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_ping(self):
        for loss, status in [(0, 'OK'), (10, 'ATENCAO')]:
            (self.root / 'ping').write_text(f'100 packets transmitted, {100-loss} received, {loss}% packet loss\n')
            r = self.bash(f'classify ping 0 "$TEST_ROOT/ping"; [[ $STATUS == {status} ]]')
            self.assertEqual(r.returncode, 0, r.stderr)

    def test_memory_budget(self):
        r = self.bash('''
available_mb() { echo 4096; }; budget_memory; [[ $MEM_MB == 1024 ]] || exit 10
available_mb() { echo 768; }; budget_memory; [[ $MEM_MB == 256 ]] || exit 11
available_mb() { echo 500; }; if budget_memory; then exit 12; fi
''')
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_load_guards(self):
        r = self.bash('''
if load_allowed consulta; then exit 1; fi
MODE=completo; cpu_temp() { echo 0; }
if load_allowed sem_sensor; then exit 2; fi
ALLOW_NO_SENSOR=1; load_allowed autorizado || exit 3
cpu_temp() { echo 90000; }
if load_allowed quente; then exit 4; fi
[[ $ABORT_LOAD == 1 ]] || exit 5
''')
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_runner(self):
        r = self.bash('''
run coleta coleta 2 bash -c 'echo resultado'; [[ $LAST_STATUS == COLETADO ]] || exit 1
run ausente coleta 2 comando_inexistente_abc123; [[ $LAST_STATUS == NAO_EXECUTADO ]] || exit 2
run limitado coleta 1 bash -c 'sleep 20'; [[ $LAST_STATUS == INCONCLUSIVO && $LAST_RC == 124 ]] || exit 3
cpu_temp() { echo 30000; }; available_mb() { echo 4096; }
run falha carga 2 bash -c 'echo erro; exit 1'; [[ $LAST_STATUS == FALHA && $ABORT_LOAD == 1 ]] || exit 4
''')
        self.assertEqual(r.returncode, 0, r.stdout+r.stderr)

    def test_smart_busy(self):
        (self.root / 'smart').write_text('Self-test execution status: ( 249) Self-test routine in progress\n')
        r = self.bash('''
[[ $(selftest_code "$TEST_ROOT/smart") == 249 ]] || exit 1
MODE=completo
run() { LAST_RC=0; LAST_LOG=$TEST_ROOT/smart; }
smart_short /dev/sda
''')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('Já há autoteste', (self.report/'resultados.tsv').read_text())

    def test_smart_completed(self):
        (self.root/'cap').write_text('Self-test execution status: ( 0) completed\n')
        (self.root/'started').write_text('Testing has begun.\n')
        (self.root/'history').write_text('# 1  Short offline       Completed without error       00%      999         -\n')
        r = self.bash('''
MODE=completo
sleep() { :; }
run() {
 LAST_RC=0
 case $1 in
   Início*) LAST_LOG=$TEST_ROOT/started ;;
   Histórico*) LAST_LOG=$TEST_ROOT/history ;;
   *) LAST_LOG=$TEST_ROOT/cap ;;
 esac
}
smart_short /dev/sda
[[ $LAST_STATUS == OK ]]
''')
        self.assertEqual(r.returncode, 0, r.stdout+r.stderr)

    def test_duration_and_estimates(self):
        r = self.bash('''
[[ $(clock_time 3661) == 01:01:01 ]] || exit 1
estimate_seconds stress-ng --cpu 0 --timeout 120s; [[ $ESTIMATE == 120 ]] || exit 2
estimate_seconds memtester 1024M 2; [[ $ESTIMATE == 0 ]] || exit 3
estimate_seconds iperf3 -c 127.0.0.1 -t 30; [[ $ESTIMATE == 30 ]] || exit 4
progress_line 10 120 150
progress_line 125 120 150
progress_line 2 0 3600
''')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('Restante estimado: 00:01:50', r.stdout)
        self.assertIn('Previsão atingida; aguardando término', r.stdout)
        self.assertIn('Duração variável | Limite: 01:00:00', r.stdout)
        self.assertNotIn('\x1b', r.stdout)

    def test_live_counter_in_terminal(self):
        master, slave = pty.openpty()
        try:
            env = dict(os.environ, TERM='xterm', SCRIPT=str(SCRIPT), TEST_REPORT=str(self.report))
            proc = subprocess.Popen(['bash', '-c',
                'source "$SCRIPT"; REPORT=$TEST_REPORT; run contador coleta 8 sleep 2.2'],
                stdout=slave, stderr=slave, env=env)
            os.close(slave)
            slave = None
            proc.wait(timeout=10)
            output = bytearray()
            while True:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                output.extend(chunk)
            self.assertEqual(proc.returncode, 0)
            text = output.decode()
            self.assertIn('Decorrido: 00:00:00', text)
            self.assertIn('Decorrido: 00:00:01', text)
            self.assertIn('Decorrido: 00:00:02', text)
            self.assertIn('\r\x1b[2K', text)
        finally:
            if slave is not None:
                os.close(slave)
            os.close(master)

    def test_full_report_is_printed_without_truncation(self):
        evidence = ''.join(f'evidencia {i}\n' for i in range(200))
        (self.report/'logs/001.txt').write_text(evidence)
        r = self.bash('STAGE=5; record OK Disco passou logs/001.txt 0; finish')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(evidence, r.stdout)
        self.assertIn('===== ETAPA 5 =====', r.stdout)
        self.assertIn('===== Disco =====', r.stdout)
        self.assertNotIn('\x1b', r.stdout)
        self.assertNotIn('\x1b', (self.report/'RELATORIO_COMPLETO.txt').read_text())

    def test_report(self):
        r = self.bash('STAGE=1; record OK exemplo passou; STAGE=2; skip opcional desabilitado; finish')
        self.assertEqual(r.returncode, 0, r.stderr)
        report = (self.report/'RELATORIO_COMPLETO.txt').read_text()
        self.assertIn('NAO_EXECUTADO', report)
        self.assertIn('não significa APROVADO', report)

    def test_interrupt(self):
        r = self.bash('''
trap finish EXIT
trap 'INTERRUPTED=1; exit 143' TERM
(sleep 0.3; kill -TERM $$) &
run longo coleta 15 bash -c 'echo parcial; sleep 10'
''')
        self.assertEqual(r.returncode, 143, r.stdout+r.stderr)
        self.assertIn('EXECUÇÃO INCOMPLETA', (self.report/'RESUMO.txt').read_text())
        self.assertIn('parcial', (self.report/'RELATORIO_COMPLETO.txt').read_text())

    def test_heat_watchdog(self):
        r = self.bash('''
cpu_temp() { echo 90000; }; available_mb() { echo 4096; }
run quente carga 10 bash -c 'sleep 9'
[[ $LAST_STATUS == FALHA && $ABORT_LOAD == 1 ]]
''')
        self.assertEqual(r.returncode, 0, r.stdout+r.stderr)

    def test_all_stages_simulated(self):
        r = self.bash('''
prepare() { START_ISO=$(date -Is); VALID_DISKS=(/dev/sda); IFACES=(); }
cpu_temp() { echo 30000; }; available_mb() { echo 4096; }
run() {
 LAST_LOG=$REPORT/logs/simulado.txt; LAST_RC=0
 printf 'SIMULADO %s\\n' "$*" >> "$LAST_LOG"
 record COLETADO "$1" SIMULADO logs/simulado.txt 0
}
smart_short() { record INFO SMART SIMULADO; }
disk_stress() { record INFO escrita SIMULADO; }
main --modo completo --confirmar-manutencao --script-saude
''')
        self.assertIn(r.returncode, (0,1), r.stdout+r.stderr)
        rows = (self.report/'resultados.tsv').read_text()
        for i in range(1,12):
            self.assertTrue(any(row.startswith(f'{i}\t') for row in rows.splitlines()), str(i))
        self.assertIn('CPU por 600s', rows)
        self.assertIn('Memtester 1024MiB', rows)
        self.assertTrue((self.report/'RELATORIO_COMPLETO.txt').exists())

if __name__ == '__main__':
    unittest.main(verbosity=2)
