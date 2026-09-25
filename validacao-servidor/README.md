# Validação de servidores Debian 11 — v1.3.0

Execute como **root**. SSD/HD SATA: selecione o disco inteiro (`/dev/sda`).

## Instalar

```bash
apt-get update && apt-get install -y git ca-certificates python3
git clone --branch master https://github.com/Lucasuimaraes/teste_saude_ssd.git /opt/teste_saude_ssd
bash /opt/teste_saude_ssd/validacao-servidor/instalar.sh
validar-servidor --instalar-dependencias
```

## Atualizar

Sem teste em andamento. O instalador preserva o script anterior.

```bash
git -C /opt/teste_saude_ssd pull --ff-only && bash /opt/teste_saude_ssd/validacao-servidor/instalar.sh
validar-servidor --instalar-dependencias
validar-servidor --versao
```

## Testar

Consulta sem carga:

```bash
validar-servidor --modo consulta --disco /dev/sda
```

Completo, **em manutenção e com backup confirmado**:

```bash
validar-servidor --modo completo --confirmar-manutencao --disco /dev/sda --cliente "Cliente" --tecnico "Lucas"
```

Acrescente conforme a máquina:

| Opção | Uso |
|---|---|
| `--perfil hardware` | Máquina sem telefonia instalada |
| `--perfil ipbx` | Exige verificação do Asterisk para entrega com Ironvox |
| `--perfil auto` | Padrão: exige telefonia se o executável Asterisk existe |
| `--condicao nova` | Nova, conforme informado pelo técnico |
| `--condicao usada` | Já utilizada |
| `--condicao energia` | Histórico informado de picos/quedas de energia |
| `--memoria-mb 2048` | Teto de RAM por teste; padrão 1024, máximo 4096 MiB |
| `--etapas 1,5,11` | Executa somente as etapas indicadas; diagnóstico geral fica pendente se faltar cobertura |
| `--relatorio-completo` | Exibe também todos os logs no final |

A condição informada não muda a duração nem comprova defeito.

## O relatório responde

- **Pode liberar?** Conclusão com bloqueios e pendências; aprovação final continua técnica.
- **O que resolver?** Ações por prioridade, acompanhadas da evidência.
- **Quanto foi usada?** Tempo ligada nesta sessão, último boot e horas acumuladas do disco, quando informadas.
- **Quantas vezes ligou?** Boots/desligamentos do wtmp atual e ciclos de alimentação do disco, separados.
- **RAM passou?** Resultado, quantidade alocada quando extraível e limite da cobertura.
- **Disco precisa de troca?** Distingue falha SMART/mídia, setores históricos e erros de cabo/porta.
- **Há urgência?** Falhas de carga, refrigeração, erros novos e falta de espaço.

Horas altas não condenam disco. Desligamentos inesperados não provam pico elétrico.
Campos não suportados aparecem como indisponíveis; não se inventa percentual de vida útil.
O teste de RAM cobre a região alocada, não todos os módulos individualmente.

## Arquivos

Em `/var/log/validacao-servidor/<execução>/`:

- `DIAGNOSTICO.txt`: resultado prático exibido na tela, com cores no terminal.
- `RESUMO.txt`: resultados de todos os comandos.
- `RELATORIO_COMPLETO.txt`: comandos e logs coletados.

O contador ao vivo continua em HH:MM:SS. `Ctrl+C` salva diagnóstico parcial.
Não publique relatórios de clientes neste repositório.

[Manual direto](MANUAL_USO_VALIDAR_SERVIDOR.txt) · [Exemplo simulado](EXEMPLO_DIAGNOSTICO.txt) · [Histórico](CHANGELOG.md)

Testes locais: `python3 -m unittest discover -s validacao-servidor -p 'test_*.py'`.
