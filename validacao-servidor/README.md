# Validação de servidores Debian 11 — v1.2.0

Execute como **root**. Disco padrão: `/dev/sda` (disco inteiro).

## Instalar

```bash
apt-get update && apt-get install -y git ca-certificates
git clone --branch master https://github.com/Lucasuimaraes/teste_saude_ssd.git /opt/teste_saude_ssd
bash /opt/teste_saude_ssd/validacao-servidor/instalar.sh
/usr/local/sbin/validar-servidor --instalar-dependencias
```

Se a pasta já existe, use a atualização. Pare se algum comando falhar.

## Atualizar

Aguarde os testes terminarem. O instalador guarda backup da versão anterior.

```bash
git -C /opt/teste_saude_ssd pull --ff-only && bash /opt/teste_saude_ssd/validacao-servidor/instalar.sh
/usr/local/sbin/validar-servidor --versao
```

## Executar

Consulta, sem stress:

```bash
/usr/local/sbin/validar-servidor --modo consulta --disco /dev/sda
```

Teste completo: **somente em manutenção e com backup confirmado**.

```bash
/usr/local/sbin/validar-servidor --modo completo --confirmar-manutencao --disco /dev/sda --cliente "Nome do cliente" --tecnico "Lucas"
```

## Acompanhamento e relatório

- Contador ao vivo: tempo decorrido, restante estimado e limite em `HH:MM:SS`.
- Duração desconhecida: aparece “Duração variável”. Limite não é previsão de término.
- SMART: atualização visual a cada segundo e consulta ao disco a cada 15 segundos.
- Relatório completo aparece ao finalizar, com seções e cores no terminal.
- Verde: OK. Amarelo: atenção/inconclusivo. Vermelho: falha. Roxo: não executado.
- `COLETADO` não significa aprovado. Confira as evidências e teste a telefonia.
- Arquivos sem cores: `/var/log/validacao-servidor/<execução>/RESUMO.txt` e `RELATORIO_COMPLETO.txt`.
- Para reler: `less /var/log/validacao-servidor/<execução>/RELATORIO_COMPLETO.txt` (substitua `<execução>` pela pasta mostrada).
- `Ctrl+C` interrompe os comandos e salva relatório parcial; SMART no firmware pode continuar.

## Selecionar testes

| Etapa | Teste |
|---|---|
| 1 | Hardware, CPU/RAM, memtester e SMART |
| 2 | Placas de rede, ping e DNS |
| 3 | CPU |
| 4 | Memória |
| 5 | Disco e autoteste SMART |
| 6 | Logs |
| 7 | Serviços e Asterisk |
| 8 | Rotas, IPs e firewall |
| 9 | Hora e NTP |
| 10 | Sistema |
| 11 | Stress adicional de CPU, RAM e disco |

Acrescente `--etapas 1,5,11` para selecionar etapas. Carga exige modo completo.

Segunda placa (substitua interface e IP; conecte cabo e configure IP antes):

```bash
/usr/local/sbin/validar-servidor --etapas 2 --interface eth1 --alvo-rede eth1=192.168.1.1
```

Vazão: rode `iperf3 -s` em outro equipamento e acrescente `--iperf-servidor IP` ao modo completo.

Ajuda: `validar-servidor --ajuda`. [Manual direto em TXT](MANUAL_USO_VALIDAR_SERVIDOR.txt).
Relatórios de clientes devem ficar fora deste repositório público.
