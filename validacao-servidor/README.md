# Validação de servidores Debian 11

Script por etapas para servidores com SSD ou HD SATA. Coleta hardware, rede,
SMART, logs, serviços e sincronismo; os testes de carga são habilitados em manutenção.
Os relatórios ficam no próprio servidor. Todos os comandos abaixo são para **root**.

## Instalar diretamente no servidor

O repositório é público: não exige conta GitHub, token ou que o computador do Lucas esteja ligado.
É necessário acesso HTTPS ao GitHub e repositórios APT funcionando para instalar dependências.

```bash
apt-get update && apt-get install -y git ca-certificates
git clone --branch master https://github.com/Lucasuimaraes/teste_saude_ssd.git /opt/teste_saude_ssd
bash /opt/teste_saude_ssd/validacao-servidor/instalar.sh
/usr/local/sbin/validar-servidor --instalar-dependencias
```

Se a pasta já contiver este clone, use a seção de atualização. Se algum comando
falhar, corrija a causa antes de continuar. O instalador salva uma cópia do script anterior.

## Executar

Consulta, sem stress (padrão):

```bash
/usr/local/sbin/validar-servidor --modo consulta --disco /dev/sda
```

Todas as etapas, com carga, **somente em manutenção**:

```bash
/usr/local/sbin/validar-servidor --modo completo --confirmar-manutencao --disco /dev/sda
```

O modo completo não supera pré-requisitos ausentes: sensor, cabo, IP, espaço ou
destino de teste. O relatório distingue dados coletados, testes aprovados e pendências.
Um comando terminar não significa que todo o servidor foi aprovado.

## Rede: segunda placa e iperf3

Uma placa sem cabo não pode ser validada por tráfego. Conecte-a ao switch e configure
um IP adequado antes do teste. Não é preciso criar uma segunda rota default para
testar um equipamento na rede local:

```bash
/usr/local/sbin/validar-servidor --etapas 2 --interface eth1 --alvo-rede eth1=192.168.1.1
```

Troque os nomes/IPs pelos reais. Para vazão, em **outro equipamento** da rede execute
`iperf3 -s`. Depois, no servidor em manutenção:

```bash
/usr/local/sbin/validar-servidor --etapas 2 --modo completo --confirmar-manutencao --iperf-servidor 192.168.1.10
```

O validador não altera IPs, rotas, firewall ou serviços para fazer os testes passarem.

## Atualizar um servidor instalado

```bash
git -C /opt/teste_saude_ssd pull --ff-only && bash /opt/teste_saude_ssd/validacao-servidor/instalar.sh
/usr/local/sbin/validar-servidor --versao
```

Não atualize enquanto uma rodada estiver em andamento. A atualização baixa a
versão da branch `master`, instala a cópia e guarda backup da anterior. Não executa
stress nem instala pacotes automaticamente. Se houver mudanças locais ou conflito,
o Git pode interromper a atualização; preserve e revise suas alterações.

## Relatórios e documentação

- Saída: `/var/log/validacao-servidor/AAAAMMDD-HHMMSS-identificador/`.
- Arquivos principais: `RESUMO.txt` e `RELATORIO_COMPLETO.txt`, além dos logs individuais.
- [Manual completo em TXT](MANUAL_USO_VALIDAR_SERVIDOR.txt).
- Manual instalado: `/usr/local/share/doc/validar-servidor/MANUAL_USO_VALIDAR_SERVIDOR.txt`.
- Ajuda: `/usr/local/sbin/validar-servidor --ajuda`.
- [Histórico de mudanças](CHANGELOG.md).

Não envie relatórios de clientes ao repositório público: eles podem conter IPs,
identificadores, processos e mensagens internas. Compartilhe o link do projeto para distribuir o código.

## Validação do código

```bash
bash -n validar-servidor.sh
bash -n instalar.sh
python3 test_validar.py
```

Execute dentro desta pasta. Os testes usam simulação e arquivos temporários;
não estressam discos/RAM reais. A instalação pode ser testada com `--prefix` em
um diretório isolado. Valide a compatibilidade no equipamento de destino antes da entrega.
