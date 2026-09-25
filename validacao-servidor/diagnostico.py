#!/usr/bin/env python3
"""Diagnóstico local por regras explícitas; não envia dados nem modifica hardware."""
import csv
import json
import re
import sys
from pathlib import Path

UNKNOWN = 'Não disponível'


def integer(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def load_json(path):
    try:
        obj = json.loads(path.read_text(errors='replace'))
        return obj if isinstance(obj, dict) else {}
    except (OSError, ValueError):
        return {}


def text(path):
    try:
        return path.read_text(errors='replace')
    except OSError:
        return ''


def duration(seconds):
    seconds = max(0, int(seconds))
    return f'{seconds // 86400} dias, {seconds % 86400 // 3600:02d}h {seconds % 3600 // 60:02d}min'


def smart_metrics(data):
    # Use campos já interpretados pelo smartctl. RAW vendor-specific só com
    # modelo reconhecido e nome exato; nunca adivinhar porcentagem por ID 231/233.
    attrs = {a.get('name'): a for a in data.get('ata_smart_attributes', {}).get('table', []) if isinstance(a, dict)}
    def raw(*names):
        if data.get('in_smartctl_database') is not True:
            return None
        for name in names:
            value = integer(attrs.get(name, {}).get('raw', {}).get('value'))
            if value is not None:
                return value
        return None
    return {
        'hours': integer(data.get('power_on_time', {}).get('hours')),
        'cycles': integer(data.get('power_cycle_count')),
        'unsafe': raw('Unexpected_Power_Loss_Ct', 'Unsafe_Shutdown_Count', 'Unexpect_Power_Loss_Ct'),
        'pending': raw('Current_Pending_Sector'),
        'uncorrectable': raw('Offline_Uncorrectable'),
        'reallocated': raw('Reallocated_Sector_Ct'),
        'crc': raw('UDMA_CRC_Error_Count'),
        'temperature': integer(data.get('temperature', {}).get('current')),
        'passed': data.get('smart_status', {}).get('passed'),
    }


class Diagnosis:
    def __init__(self, root):
        self.root = Path(root)
        with (self.root / 'resultados.tsv').open() as f:
            self.rows = list(csv.DictReader(f, delimiter='\t'))
        self.meta = {}
        for line in text(self.root / 'contexto.tsv').splitlines():
            key, sep, value = line.partition('\t')
            if sep:
                self.meta[key] = value
        self.findings = []
        self.sections = []
        self.used = set()

    def add(self, level, component, evidence, action, source=''):
        item = dict(level=level, component=component, evidence=evidence, action=action, source=source)
        if item not in self.findings:
            self.findings.append(item)

    def log(self, row):
        # O TSV é produzido pelo validador. Restringe leitura ao diretório de logs.
        path = (self.root / row.get('log', '')).resolve()
        try:
            path.relative_to((self.root / 'logs').resolve())
        except ValueError:
            return ''
        return text(path)

    def group(self, label, predicate):
        rows = [r for r in self.rows if predicate(r['teste'])]
        for r in rows:
            self.used.add(id(r))
        executed = [r for r in rows if r['codigo'].isdigit()]
        if any(r['status'] == 'FALHA' for r in rows):
            state = 'FALHOU / investigação necessária'
        elif any(r['status'] in ('ATENCAO', 'INCONCLUSIVO') for r in rows):
            state = 'INCONCLUSIVO / revisar pendências'
        elif executed and all(r['status'] == 'OK' for r in executed):
            state = 'PASSOU nos testes executados'
        else:
            state = 'NÃO TESTADO'
        self.sections.append(f'{label}: {state}.')
        return rows, executed, state

    def machine(self):
        self.sections.append('===== TEMPO DE USO E ENERGIA =====')
        self.sections.append('Máquina ligada nesta sessão (no início da rodada): ' + self.meta.get('uptime', UNKNOWN))
        self.sections.append('Última inicialização: ' + self.meta.get('boot', UNKNOWN))
        self.sections.append('RAM instalada disponível ao sistema: ' + self.meta.get('ram_mib', UNKNOWN) + ' MiB')
        history = next((r for r in self.rows if r['teste'] == 'Histórico de energia do sistema'), None)
        lines = self.log(history).splitlines() if history and history['codigo'] == '0' else []
        if lines:
            boots = sum(bool(re.match(r'^reboot\s', l)) for l in lines)
            shutdowns = sum(bool(re.match(r'^shutdown\s', l)) for l in lines)
            window = next((l for l in lines if 'wtmp begins' in l), 'início do histórico não informado')
            self.sections.append(f'Histórico local: {boots} inicializações e {shutdowns} desligamentos registrados.')
            self.sections.append('Janela do registro: ' + window.replace('wtmp begins', 'desde'))
            recent = [l for l in lines if re.match(r'^(reboot|shutdown)\s', l)][:3]
            self.sections.extend('  ' + l.replace('reboot', 'Inicialização', 1).replace('shutdown', 'Desligamento', 1).replace('system boot', '').replace('system down', '') for l in recent)
            self.used.add(id(history))
        else:
            self.sections.append('Histórico de inicializações/desligamentos: não disponível.')
        self.sections.append('Esses registros cobrem somente o wtmp atual; não são o total de vida da máquina.')
        self.sections.append('Horas de atividade humana e total histórico de uso da máquina: não mensuráveis por esta coleta.')
        if self.meta.get('condicao') == 'energia':
            self.add('ATENCAO', 'Energia', 'Histórico de picos/quedas informado pelo técnico; não medido pelo script.',
                     'Conferir fonte, nobreak, bateria e alimentação elétrica antes da entrega. Não substituir fonte só por esse histórico.', 'contexto.tsv')

    def disks(self):
        self.sections.append('===== HD / SSD =====')
        requested = self.meta.get('discos', '').split()
        for disk in requested:
            name = Path(disk).name
            initial_path = self.root / f'smart-{name}-inicial.json'
            final_path = self.root / f'smart-{name}-final.json'
            initial = load_json(initial_path)
            final = load_json(final_path)
            data = final or initial
            source = final_path.name if final else initial_path.name
            self.sections.append(f'{disk}: {data.get("model_name", UNKNOWN)} | Série: {data.get("serial_number", UNKNOWN)}')
            if not data:
                self.add('PENDENTE', disk, 'SMART legível não foi coletado.', 'Executar etapa 5 e conferir suporte SMART/controladora.', source)
                self.sections.append('  Tempo de uso, ciclos e condição: não disponíveis. Não considerado aprovado.')
                continue
            m = smart_metrics(data)
            before = smart_metrics(initial)
            if final_path.exists() and not final:
                self.add('PENDENTE', disk, 'Leitura SMART final inválida; exibindo a inicial.', 'Repetir SMART após os testes antes de concluir.', final_path.name)
            if m['passed'] is not True and m['passed'] is not False:
                self.add('PENDENTE', disk, 'Estado geral SMART não informado.', 'Verificar suporte SMART e concluir diagnóstico manualmente.', source)
            rc = integer(data.get('smartctl', {}).get('exit_status'))
            if rc is None or rc & 7:
                self.add('PENDENTE', disk, 'Consulta SMART ausente ou parcial; alguns dados podem estar disponíveis.', 'Revisar log SMART e acesso à controladora antes de concluir.', source)
            hours = (format(m['hours'], ',').replace(',', '.') + f' horas ({duration(m["hours"] * 3600)})') if m['hours'] is not None else UNKNOWN
            self.sections.append(f'  Uso acumulado do disco: {hours}. Não equivale à idade desde a fabricação.')
            self.sections.append(f'  Ciclos de alimentação do disco: {m["cycles"] if m["cycles"] is not None else UNKNOWN}. Não é contagem de boots do sistema.')
            self.sections.append(f'  Desligamentos inesperados informados pelo disco: {m["unsafe"] if m["unsafe"] is not None else UNKNOWN}.')
            self.sections.append(f'  Temperatura atual do disco: {str(m["temperature"]) + " °C" if m["temperature"] is not None else UNKNOWN}.')
            self.sections.append('  Vida útil restante em %: não estimada sem interpretação específica validada para o modelo.')
            self.sections.append('  Saúde SMART: ' + ('FALHOU.' if m['passed'] is False else 'sem alarme geral; não substitui os testes.' if m['passed'] is True else 'não informada.'))
            if m['passed'] is False or (rc is not None and rc & 8):
                self.add('CRITICO', disk, 'O próprio disco sinaliza falha de saúde SMART.', 'Preservar os dados e substituir o disco antes da entrega.', source)
            elif rc is not None and rc & 16:
                self.add('CRITICO', disk, 'Atributo SMART atingiu limiar de falha.', 'Preservar dados; confirmar o atributo/modelo e encaminhar o disco para substituição.', source)
            if m['pending'] or m['uncorrectable']:
                self.add('CRITICO', disk, f'Setores pendentes: {m["pending"]}; não corrigíveis: {m["uncorrectable"]}.',
                         'Não liberar. Preservar dados e confirmar leitura em bancada; substituir se o defeito de mídia persistir.', source)
            for key, label in [('reallocated', 'Setores realocados'), ('crc', 'Erros de comunicação SATA')]:
                value = m[key]
                self.sections.append(f'  {label}: {value if value is not None else UNKNOWN}.')
                if value:
                    comparable = bool(initial.get('serial_number')) and initial.get('serial_number') == data.get('serial_number') and final and initial
                    delta = value - before[key] if comparable and before[key] is not None else None
                    evidence = f'{label}: {value}' + (f'; variação nesta rodada: {delta}.' if delta is not None else '; sem comparação válida nesta rodada.')
                    if key == 'crc':
                        self.add('ATENCAO', disk, evidence, 'Revisar cabo/porta SATA e alimentação; repetir e verificar se o contador aumenta. Não condenar o SSD/HD apenas por CRC.', source)
                    else:
                        self.add('CRITICO' if delta is not None and delta > 0 else 'ATENCAO', disk, evidence,
                                 'Preservar dados; se houver crescimento ou falha de leitura, substituir o disco. Contagem histórica estável exige acompanhamento.', source)
            if m['unsafe']:
                self.add('ATENCAO', disk, f'{m["unsafe"]} desligamentos inesperados acumulados.',
                         'Revisar alimentação e histórico com o cliente. O contador não prova pico elétrico nem dano à fonte.', source)
            if self.meta.get('condicao') == 'nova' and (m['hours'] or m['cycles']):
                self.sections.append('  Declarada nova: comparar uso com fornecedor/nota; testes de fábrica podem gerar horas e ciclos.')
            self.sections.append('  Fonte dos dados: ' + source)
            selftest = [r for r in self.rows if r['teste'] == f'Autoteste curto {disk}']
            for r in selftest:
                self.used.add(id(r))
            if any(r['status'] == 'OK' for r in selftest):
                self.sections.append('  Autoteste curto desta rodada: PASSOU.')
            else:
                self.sections.append('  Autoteste curto desta rodada: NÃO COMPROVADO / não passou ou não executado.')
                self.add('PENDENTE', disk, 'Autoteste curto desta rodada sem aprovação registrada.', 'Executar/concluir etapa 5 em manutenção e revisar o histórico do autoteste.', 'resultados.tsv')
        if not requested:
            self.add('PENDENTE', 'Discos', 'Nenhum disco identificado no contexto.', 'Repetir coleta e selecionar os discos corretos.')

    def tests(self):
        self.sections.append('===== RESULTADO DOS TESTES =====')
        rows, done, state = self.group('Memória RAM (memtester)', lambda t: t.startswith('Memtester'))
        for r in done:
            log = self.log(r)
            mismatch = bool(re.search(r'FAILURE:|stuck address.*fail', log, re.I))
            if mismatch:
                self.add('CRITICO', 'Memória RAM', 'Memtester encontrou divergência de dados.',
                         'Não liberar. Repetir teste por módulo/slot e em configuração padrão; substituir apenas o módulo que falhar isoladamente.', r['log'])
            elif r['status'] != 'OK':
                self.add('PENDENTE', 'Memória RAM', r['detalhes'], 'Resolver erro de execução/recursos e repetir memtester; isso sozinho não prova defeito no pente.', r['log'])
            self.sections.append('  Cobertura solicitada: ' + r['teste'] + '. Apenas a região alocada foi testada; não todos os módulos individualmente.')
            allocated = re.search(r'got\s+\d+\s*MB\s*\((\d+)\s+bytes\)', log, re.I)
            if allocated:
                actual_mib = int(allocated.group(1)) / 1024 / 1024
                total = self.meta.get('ram_mib', '')
                fraction = f' ({actual_mib / int(total) * 100:.1f}% da RAM disponível ao SO)' if total.isdigit() and int(total) > 0 else ''
                self.sections.append(f'  RAM efetivamente alocada pelo memtester: {actual_mib:.0f} MiB{fraction}.')
            else:
                self.sections.append('  Quantidade efetivamente alocada: não extraída do log; conferir evidência do memtester.')
        if not done:
            self.add('PENDENTE', 'Memória RAM', 'Memtester não executado/concluído.', 'Executar em manutenção; para cobertura integral, complementar com teste de memória fora do sistema.')
        for label, predicate in [
            ('CPU / carga inicial', lambda t: t.startswith('CPU/RAM por')),
            ('CPU / carga adicional', lambda t: t.startswith('CPU por 600s')),
            ('RAM / carga adicional', lambda t: t.startswith('RAM por 600s')),
            ('Disco / escrita em arquivo', lambda t: t.startswith('Stress de arquivo por')),
        ]:
            rows, done, state = self.group(label, predicate)
            if not done:
                self.add('PENDENTE', label, 'Teste de carga não executado.', 'Executar as etapas 1 e 11 em manutenção; conferir sensor, RAM e espaço livre.')
            for r in done:
                if r['status'] != 'OK':
                    self.add('CRITICO' if r['status'] == 'FALHA' else 'PENDENTE', label, r['detalhes'],
                             'Não liberar até identificar a causa; conferir temperatura, alimentação e log. Falha de carga não identifica sozinha a peça defeituosa.', r['log'])
        temperatures = []
        for line in text(self.root / 'temperatura_memoria.tsv').splitlines()[1:]:
            parts = line.split('\t')
            if len(parts) > 1 and parts[1].isdigit() and 0 < int(parts[1]) < 150000:
                temperatures.append(int(parts[1]) / 1000)
        self.sections.append('Maior temperatura CPU durante as cargas: ' + (f'{max(temperatures):.1f} °C.' if temperatures else 'não medida.'))
        if not temperatures:
            self.add('PENDENTE', 'Temperatura', 'Sem amostras válidas da CPU durante a carga.', 'Conferir sensores/refrigeração; não concluir estabilidade térmica.')
        for r in self.rows:
            if r['status'] == 'FALHA' and 'Temperatura CPU' in r['detalhes']:
                self.add('CRITICO', 'Refrigeração', r['detalhes'], 'Verificar cooler, poeira, pasta térmica e ventilação; repetir carga após corrigir.', r['log'])

    def issues(self):
        self.sections.append('===== REDE E SERVIÇOS =====')
        pings = [r for r in self.rows if r['teste'].startswith(('Gateway ', 'Internet ', 'Destino local '))]
        self.sections.append('Rede: ' + (f'{sum(r["status"] == "OK" for r in pings)}/{len(pings)} verificações de tráfego passaram.' if pings else 'sem teste de tráfego comprovado.'))
        if not pings or not any(r['status'] == 'OK' for r in pings):
            self.add('PENDENTE', 'Rede', 'Nenhum teste de tráfego passou nesta rodada.', 'Conectar rede e executar etapa 2; informar destino local se não houver gateway.')
        self.sections.append('Telefonia: ' + ('exigida pelo perfil IPBX.' if self.meta.get('perfil_efetivo') == 'ipbx' else 'não exigida neste perfil de hardware.'))
        for r in self.rows:
            if r['status'] not in ('FALHA', 'ATENCAO', 'INCONCLUSIVO') or id(r) in self.used:
                continue
            title, detail = r['teste'], r['detalhes']
            action = 'Revisar a evidência indicada e repetir a verificação após corrigir a causa.'
            level = 'PENDENTE'
            if 'Eventos críticos' in title:
                level = 'ATENCAO'
                action = 'Investigar erro de hardware/filesystem. Eventos do boot podem ser anteriores ao teste; correlacionar horário antes de substituir peças.'
            elif any(t in title for t in ('Gateway', 'Internet', 'DNS', 'Link ', 'Duplex', 'Contador ', 'Vazão')):
                level = 'ATENCAO'
                action = 'Conferir cabo, porta, IP, rota e DNS. Falha de ping isolada não comprova defeito de placa.'
            elif 'Asterisk' in title or 'Unidades com falha' in title or 'Serviços com falha' in title:
                level = 'ATENCAO'
                action = 'Corrigir serviço/configuração e validar operação; não indica necessidade de trocar hardware.'
            elif 'Sincronismo' in title:
                level = 'ATENCAO'
                action = 'Revisar serviço NTP, DNS e acesso à rede.'
            self.add(level, title, detail, action, r['log'] or 'resultados.tsv')
        # Erros novos de I/O/filesystem exigem ação, mas não atribuem a peça sem teste.
        for r in self.rows:
            if r['teste'] == 'Erros novos desde início da validação' and r['codigo'] == '0':
                log = self.log(r)
                if re.search(r'I/O error|EXT4-fs error|uncorrected.*error|machine check', log, re.I):
                    self.add('CRITICO', 'Erro novo durante a rodada', 'Erro de I/O, filesystem ou hardware registrado desde o início.',
                             'Não liberar. Preservar dados; investigar disco/cabo/controladora/RAM conforme o log, sem atribuir causa automaticamente.', r['log'])
        if self.meta.get('perfil_efetivo') == 'ipbx':
            active = [r for r in self.rows if r['teste'] == 'Status Asterisk' and r['status'] == 'OK']
            if not active:
                self.add('PENDENTE', 'Telefonia', 'Asterisk ativo não foi comprovado.', 'Executar etapa 7, corrigir serviço e testar chamadas reais.')

    def storage_space(self):
        rows = [r for r in self.rows if r['teste'] == 'Ocupação dos sistemas de arquivos' and r['codigo'] == '0']
        for r in rows:
            for line in self.log(r).splitlines()[1:]:
                parts = line.split(None, 5)
                if len(parts) != 6 or not parts[4].endswith('%') or not parts[4][:-1].isdigit():
                    continue
                filesystem, total, used, free, percent, mount = parts
                if not filesystem.startswith('/dev/') and mount != '/':
                    continue
                pct = int(percent[:-1])
                if pct >= 95:
                    self.add('CRITICO' if pct >= 99 else 'ATENCAO', 'Espaço em disco',
                             f'{mount} está com {pct}% de ocupação.',
                             'Revisar gravações, logs e retenção; liberar espaço com backup ou ampliar capacidade. Não apagar arquivos automaticamente.', r['log'])
                if mount == '/':
                    self.sections.append(f'Disco do sistema: {pct}% ocupado; livre: {int(free)/1024/1024:.1f} GiB.' if free.isdigit() else f'Disco do sistema: {pct}% ocupado.')

    def render(self):
        self.machine()
        self.disks()
        self.tests()
        self.issues()
        self.storage_space()
        partial = any(r['teste'] == 'Execução parcial' for r in self.rows)
        critical = any(f['level'] == 'CRITICO' for f in self.findings)
        if critical:
            conclusion = 'NÃO LIBERAR — há condição crítica ou falha de carga a investigar.'
        elif partial:
            conclusion = 'INCONCLUSIVO — execução interrompida; testes incompletos.'
        elif self.findings:
            conclusion = 'LIBERAÇÃO PENDENTE — resolver alertas ou completar a validação.'
        else:
            conclusion = 'TESTES AUTOMÁTICOS CONCLUÍDOS SEM ALERTAS — liberação depende da conferência técnica.'
        output = ['DIAGNÓSTICO PRÁTICO DO SERVIDOR — v1.3.0',
                  f'Cliente: {self.meta.get("cliente", UNKNOWN)} | Técnico: {self.meta.get("tecnico", UNKNOWN)}',
                  f'Host: {self.meta.get("host", UNKNOWN)} | Perfil: {self.meta.get("perfil_efetivo", UNKNOWN)} | Condição informada: {self.meta.get("condicao", UNKNOWN)}',
                  f'Início: {self.meta.get("inicio", UNKNOWN)} | Fim: {self.meta.get("fim", UNKNOWN)}',
                  '', '===== CONCLUSÃO =====', conclusion, '', '===== O QUE RESOLVER PRIMEIRO =====']
        rank = {'CRITICO': 0, 'ATENCAO': 1, 'PENDENTE': 2}
        for item in sorted(self.findings, key=lambda f: rank[f['level']]):
            output.extend([f'[{item["level"]}] {item["component"]}: {item["evidence"]}',
                           '  Ação: ' + item['action'], '  Evidência: ' + (item['source'] or 'contexto da execução')])
        if not self.findings:
            output.append('Nenhuma ação corretiva automática indicada pelas evidências coletadas.')
        output.extend(['', *self.sections, '', '===== TROCA DE PEÇAS / ENTREGA =====',
                       'Troca só com evidência específica indicada acima. Idade, horas ou ciclos isolados não condenam uma peça.',
                       'Fonte, nobreak e picos elétricos exigem inspeção/teste externo; o script não mede a qualidade da alimentação.',
                       'Antes de liberar: conferir backup, refrigeração, cabos e teste real de uso; para IPBX, chamadas e áudio nos dois sentidos.',
                       'Detalhes brutos e comandos: RELATORIO_COMPLETO.txt. Resultados de cada comando: RESUMO.txt.'])
        return '\n'.join(output) + '\n', critical or partial or bool(self.findings)


def main():
    root = Path(sys.argv[1])
    report, pending = Diagnosis(root).render()
    (root / 'DIAGNOSTICO.txt').write_text(report, encoding='utf-8')
    (root / 'diagnostico-status.txt').write_text('1\n' if pending else '0\n')


if __name__ == '__main__':
    main()
