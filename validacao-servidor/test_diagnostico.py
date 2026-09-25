import json
import tempfile
import unittest
from pathlib import Path
from diagnostico import Diagnosis, smart_metrics


class DiagnosisTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / 'logs').mkdir()
        (self.root / 'resultados.tsv').write_text('etapa\tstatus\tteste\tcodigo\tdetalhes\tlog\n')
        (self.root / 'contexto.tsv').write_text('cliente\tBancada\ntecnico\tLucas\ndiscos\t/dev/sda\nperfil_efetivo\thardware\ncondicao\tusada\nuptime\t2 dias, 03h 10min\n')
        self.data = dict(model_name='Modelo simulado', serial_number='TEST-001', in_smartctl_database=True,
                         smart_status={'passed': True}, smartctl={'exit_status': 0},
                         power_on_time={'hours': 20000}, power_cycle_count=180,
                         ata_smart_attributes={'table': []})
        self.snapshot()

    def tearDown(self):
        self.tmp.cleanup()

    def snapshot(self, phase='inicial'):
        (self.root / f'smart-sda-{phase}.json').write_text(json.dumps(self.data))

    def row(self, title, status='OK', rc='0', content='sucesso', details='Teste concluído.'):
        path = f'logs/{len(list((self.root / "logs").iterdir())):03d}.txt'
        (self.root / path).write_text(content)
        with (self.root / 'resultados.tsv').open('a') as f:
            f.write(f'1\t{status}\t{title}\t{rc}\t{details}\t{path}\n')

    def report(self):
        return Diagnosis(self.root).render()[0]

    def attribute(self, name, value):
        self.data['ata_smart_attributes']['table'].append({'name': name, 'raw': {'value': value}})

    def complete(self):
        for title in ['Memtester 1024MiB, 2 passagens', 'CPU/RAM por 120s; RAM 1024MiB', 'CPU por 600s', 'RAM por 600s (1024MiB, 1 worker)', 'Stress de arquivo por 300s, 1 worker de 256MiB', 'Autoteste curto /dev/sda', 'Gateway 192.0.2.1 via eth0']:
            self.row(title)
        (self.root / 'temperatura_memoria.tsv').write_text('data\ttemp\tmem\nhoje\t65000\t1024\n')

    def test_healthy_used_machine_is_not_condemned_by_hours(self):
        self.complete()
        report = self.report()
        self.assertIn('TESTES AUTOMÁTICOS CONCLUÍDOS SEM ALERTAS', report)
        self.assertIn('20.000 horas', report)
        self.assertNotIn('[CRITICO]', report)
        self.assertIn('PASSOU nos testes executados', report)
        self.assertIn('Apenas a região alocada', report)

    def test_actual_ram_coverage(self):
        with (self.root / 'contexto.tsv').open('a') as f:
            f.write('ram_mib\t8192\n')
        self.row('Memtester 1024MiB, 2 passagens', content='got 512MB (536870912 bytes)')
        self.assertIn('512 MiB (6.2% da RAM', self.report())

    def test_new_machine_not_condemned_for_factory_use(self):
        with (self.root / 'contexto.tsv').open('a') as f:
            f.write('condicao\tnova\n')
        self.data['power_on_time']['hours'] = 4
        self.snapshot()
        report = self.report()
        self.assertIn('testes de fábrica', report)
        self.assertNotIn('[CRITICO]', report)

    def test_missing_tests_never_pass(self):
        report = self.report()
        self.assertIn('LIBERAÇÃO PENDENTE', report)
        self.assertIn('NÃO TESTADO', report)
        self.assertNotIn('TESTES AUTOMÁTICOS CONCLUÍDOS SEM ALERTAS', report)

    def test_smart_failure_recommends_replacement(self):
        self.data['smart_status']['passed'] = False
        self.snapshot()
        report = self.report()
        self.assertIn('NÃO LIBERAR', report)
        self.assertIn('substituir o disco antes da entrega', report)

    def test_unknown_model_raw_is_not_interpreted(self):
        self.attribute('Current_Pending_Sector', 999)
        self.attribute('Unsafe_Shutdown_Count', 150)
        self.data['in_smartctl_database'] = False
        self.snapshot()
        metrics = smart_metrics(self.data)
        self.assertIsNone(metrics['pending'])
        self.assertIsNone(metrics['unsafe'])
        self.assertNotIn('[CRITICO]', self.report())

    def test_pending_sectors_critical(self):
        self.attribute('Current_Pending_Sector', 5)
        self.snapshot()
        self.assertIn('Setores pendentes: 5', self.report())
        self.assertIn('NÃO LIBERAR', self.report())

    def test_crc_does_not_condemn_disk(self):
        self.attribute('UDMA_CRC_Error_Count', 27)
        self.snapshot()
        report = self.report()
        self.assertIn('cabo/porta SATA', report)
        self.assertNotIn('[CRITICO]', report)
        self.assertNotIn('substituir o disco antes da entrega', report)

    def test_reallocated_growth_is_critical(self):
        self.attribute('Reallocated_Sector_Ct', 2)
        self.snapshot()
        self.data['ata_smart_attributes']['table'][0]['raw']['value'] = 4
        self.snapshot('final')
        self.assertIn('variação nesta rodada: 2', self.report())
        self.assertIn('[CRITICO]', self.report())

    def test_different_serial_not_compared(self):
        self.attribute('Reallocated_Sector_Ct', 2)
        self.snapshot()
        self.data['serial_number'] = 'OTHER'
        self.data['ata_smart_attributes']['table'][0]['raw']['value'] = 100
        self.snapshot('final')
        self.assertNotIn('variação nesta rodada:', self.report())

    def test_power_loss_is_not_proof_of_surge(self):
        self.attribute('Unsafe_Shutdown_Count', 18)
        self.snapshot()
        report = self.report()
        self.assertIn('18 desligamentos inesperados', report)
        self.assertIn('não prova pico elétrico', report)
        self.assertNotIn('[CRITICO]', report)

    def test_ram_mismatch_vs_allocation_failure(self):
        self.row('Memtester 1024MiB, 2 passagens', 'FALHA', '4', 'FAILURE: mismatch at offset 0x10')
        self.assertIn('[CRITICO] Memória RAM', self.report())
        self.assertIn('módulo que falhar isoladamente', self.report())

    def test_ram_allocation_failure_not_a_bad_dimm(self):
        self.row('Memtester 1024MiB, 2 passagens', 'FALHA', '1', 'failed to allocate memory')
        report = self.report()
        self.assertIn('isso sozinho não prova defeito no pente', report)
        self.assertNotIn('[CRITICO] Memória RAM', report)

    def test_history_is_scoped_to_available_wtmp(self):
        self.row('Histórico de energia do sistema', 'COLETADO', '0', 'reboot system boot x\nshutdown system down x\nreboot system boot x\nwtmp begins Tue Sep 1\n')
        report = self.report()
        self.assertIn('2 inicializações e 1 desligamentos', report)
        self.assertIn('somente o wtmp atual', report)

    def test_final_corrupted_not_silently_approved(self):
        self.complete()
        (self.root / 'smart-sda-final.json').write_text('not json')
        self.assertIn('Leitura SMART final inválida', self.report())
        self.assertIn('LIBERAÇÃO PENDENTE', self.report())

    def test_missing_smart_and_interruption(self):
        (self.root / 'smart-sda-inicial.json').unlink()
        self.row('Execução parcial', 'INCONCLUSIVO', '-', '')
        self.assertIn('INCONCLUSIVO — execução interrompida', self.report())

    def test_missing_general_smart_status_not_pass(self):
        self.complete()
        self.data.pop('smart_status')
        self.snapshot()
        self.assertIn('Estado geral SMART não informado', self.report())

    def test_ipbx_requires_asterisk(self):
        self.complete()
        with (self.root / 'contexto.tsv').open('a') as f:
            f.write('perfil_efetivo\tipbx\n')
        self.assertIn('Asterisk ativo não foi comprovado', self.report())

    def test_disk_full_needs_action(self):
        self.row('Ocupação dos sistemas de arquivos', 'COLETADO', '0', 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 100000 99900 100 100% /\n')
        self.assertIn('[CRITICO] Espaço em disco', self.report())

    def test_raw_vendor_wear_never_becomes_generic_percentage(self):
        self.attribute('Unknown_Attribute', 2)
        self.snapshot()
        self.assertIn('Vida útil restante em %: não estimada', self.report())


if __name__ == '__main__':
    unittest.main(verbosity=2)
