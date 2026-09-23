# Ferramentas de diagnóstico Linux

## Validação completa de servidores Debian 11

O validador por etapas, o instalador e o manual estão em
[validacao-servidor](validacao-servidor/README.md).

Nessa pasta estão os comandos para baixar diretamente no servidor pelo GitHub,
instalar como root, executar os testes e atualizar versões. Os relatórios são
gerados localmente no servidor e não são enviados ao repositório.

---

Teste de Saúde de Disco com SMART

Script Bash para coletar, analisar e registrar informações de saúde de discos ATA/SATA, incluindo HDDs e SSDs

O script utiliza o smartctl, do pacote smartmontools, e funciona em distribuições baseadas em:

Debian e Ubuntu;

CentOS e RHEL;

sistemas com apt-get, dnf ou yum.

O teste é não destrutivo: ele não apaga dados, não formata o disco e não executa fsck.

Recursos

Detecta automaticamente o disco que contém o sistema raiz /;

aceita a indicação manual de um disco, como /dev/sda;

converte automaticamente uma partição, como /dev/sda1, para o disco pai;

instala o smartmontools quando o smartctl não estiver disponível;

exibe modelo, serial, firmware, capacidade, setor, TRIM e versão SATA;

analisa os principais atributos SMART de HDDs e SSDs SATA;

busca atributos pelo ID SMART e, como fallback, pelo nome ou alias;

não depende da ordem das linhas da tabela SMART;

executa autoteste curto, longo ou uma sequência completa;

acompanha o progresso dos autotestes;

procura erros de disco e sistema de arquivos no log do kernel;

mostra as montagens relacionadas ao disco;

grava relatório bruto, resumo e log completo da execução;

retorna código de saída apropriado para automações, cron e monitoramento.

Requisitos

Bash;

privilégios de root;

smartctl do pacote smartmontools;

utilitários comuns como awk, sed, grep, lsblk, findmnt e tee.

O próprio script tenta instalar o smartmontools quando necessário.

Instalação

Copie o script para o servidor:

cp teste_saude_disco.sh /usr/local/sbin/teste-saude-disco
chmod 750 /usr/local/sbin/teste-saude-disco
chown root:root /usr/local/sbin/teste-saude-disco

Confira a versão:

sudo /usr/local/sbin/teste-saude-disco --version

Saída esperada:

teste-saude-disco versão 1.1.0

Uso

sudo ./teste_saude_disco.sh [DISPOSITIVO] [AÇÃO]

O dispositivo deve ser o disco inteiro, por exemplo:

/dev/sda

Evite informar apenas uma partição, como /dev/sda1. Caso isso aconteça, o script tenta localizar e usar automaticamente o disco pai.

Ajuda

./teste_saude_disco.sh --help

Versão

./teste_saude_disco.sh --version

Modos de execução

Ação

Descrição

report

Coleta e analisa o SMART sem iniciar autoteste. É a ação padrão.

short

Executa o autoteste SMART curto e aguarda a conclusão.

long

Executa o autoteste SMART estendido e aguarda a conclusão.

full

Coleta inicial, executa teste curto, teste longo e coleta final.

Exemplos

Somente relatório

sudo ./teste_saude_disco.sh /dev/sda report

Também pode ser executado sem indicar a ação:

sudo ./teste_saude_disco.sh /dev/sda

Detectar automaticamente o disco raiz

sudo ./teste_saude_disco.sh report

Ou simplesmente:

sudo ./teste_saude_disco.sh

Teste curto

sudo ./teste_saude_disco.sh /dev/sda short

O teste curto normalmente leva alguns minutos, dependendo do modelo do disco.

Teste longo

sudo ./teste_saude_disco.sh /dev/sda long

O teste longo pode levar de dezenas de minutos a várias horas. O tempo é informado pelo firmware do próprio disco.

Teste completo

sudo ./teste_saude_disco.sh /dev/sda full

Essa opção executa:

coleta inicial do SMART;

análise dos principais atributos;

verificação dos logs do kernel;

autoteste curto;

nova coleta do SMART;

autoteste longo;

coleta final;

classificação do resultado.

Execução remota ou em segundo plano

Para testes longos em uma conexão SSH, prefira tmux ou screen.

Usando tmux

tmux new -s teste-disco
sudo ./teste_saude_disco.sh /dev/sda full

Para sair da sessão sem interromper o teste:

Ctrl+B, depois D

Para retornar:

tmux attach -t teste-disco

Usando nohup

sudo nohup ./teste_saude_disco.sh /dev/sda full \

> /root/teste-saude-disco-console.log 2>&1 &

Acompanhe a saída:

tail -f /root/teste-saude-disco-console.log

Diretório de relatórios

Por padrão, cada execução cria um diretório em:

/var/log/saude-disco/<disco>-AAAAMMDD-HHMMSS/

Exemplo:

/var/log/saude-disco/sda-20260730-101500/

Arquivos que podem ser gerados:

Arquivo

Conteúdo

execucao.log

Saída completa apresentada no terminal.

resumo.txt

Resultado resumido, quantidade de avisos e críticos.

smart-inicial.txt

Relatório SMART coletado no início.

smart-apos-short.txt

Relatório coletado após o teste curto.

smart-apos-long.txt

Relatório coletado após o teste longo.

smart-final.txt

Relatório final do modo full.

smart-ultimo.txt

Cópia da coleta SMART mais recente.

inicio-teste-short.txt

Resposta do disco ao iniciar o teste curto.

inicio-teste-long.txt

Resposta do disco ao iniciar o teste longo.

resultado-teste-short.txt

Histórico de autoteste após o teste curto.

resultado-teste-long.txt

Histórico de autoteste após o teste longo.

erros-kernel.txt

Erros relacionados a disco, ATA, I/O ou sistema de arquivos.

Variáveis de ambiente

Diretório de log

sudo LOG_DIR=/root/relatorios-disco \
 ./teste_saude_disco.sh /dev/sda report

Valor padrão:

/var/log/saude-disco

Intervalo de acompanhamento

Define, em segundos, o intervalo entre as consultas de progresso do autoteste:

sudo POLL_INTERVAL=60 \
 ./teste_saude_disco.sh /dev/sda long

O valor mínimo aceito é 5 segundos. O padrão é:

30 segundos

Adaptadores USB/SATA

Alguns adaptadores USB/SATA exigem que o tipo do dispositivo seja informado ao smartctl:

sudo SMART_DEVICE_TYPE=sat \
 ./teste_saude_disco.sh /dev/sdb report

Isso faz o script executar comandos equivalentes a:

smartctl -d sat ... /dev/sdb

Dependendo da ponte USB, outros tipos podem ser necessários. Consulte os dispositivos reconhecidos com:

smartctl --scan-open

Atributos analisados

O script prioriza o ID numérico do atributo e usa o nome como fallback. Isso evita problemas quando a ordem da tabela muda.

Exemplo:

197 Current_Pending_ECC_Cnt

O script procura primeiro pelo ID 197. Caso ele não esteja disponível, tenta nomes como:

Current_Pending_ECC_Cnt
Current_Pending_Sector

Principais atributos avaliados:

ID

Atributo comum

Interpretação

1

Raw_Read_Error_Rate

Erros de leitura registrados pelo dispositivo.

5

Reallocate_NAND_Blk_Cnt ou Reallocated_Sector_Ct

Blocos ou setores substituídos por reserva.

9

Power_On_Hours

Horas totais de funcionamento.

12

Power_Cycle_Count

Quantidade de ciclos de energia.

171

Program_Fail_Count

Falhas ao programar a memória NAND.

172

Erase_Fail_Count

Falhas ao apagar blocos NAND.

173

Ave_Block-Erase_Count

Média de ciclos de apagamento.

174

Unexpect_Power_Loss_Ct

Desligamentos ou perdas inesperadas de energia.

180

Unused_Reserve_NAND_Blk

Blocos NAND de reserva disponíveis.

183

SATA_Interfac_Downshift

Reduções de velocidade da interface SATA.

184

Error_Correction_Count

Eventos de correção de erro.

187

Reported_Uncorrect

Erros não corrigíveis reportados ao sistema.

194

Temperature_Celsius

Temperatura atual do disco.

196

Reallocated_Event_Count

Eventos de realocação.

197

Current_Pending_ECC_Cnt ou Current_Pending_Sector

Setores ou erros ECC pendentes.

198

Offline_Uncorrectable

Erros não corrigíveis encontrados offline.

199

UDMA_CRC_Error_Count

Erros de comunicação SATA, cabo ou conector.

202

Percent_Lifetime_Remain

Vida útil restante ou desgaste, conforme o fabricante.

206

Write_Error_Rate

Erros relacionados à escrita.

246

Total_LBAs_Written

Total de setores lógicos gravados.

247

Host_Program_Page_Count

Páginas programadas pelo host.

248

FTL_Program_Page_Count

Páginas programadas internamente pela FTL.

250

Read_Error_Retry_Rate

Tentativas adicionais de leitura.

Crucial BX500 e o atributo 202

No Crucial BX500, é comum o atributo aparecer como:

202 Percent_Lifetime_Remain VALUE 097 RAW_VALUE 3

O script interpreta:

VALUE 097 como aproximadamente 97% de vida útil restante;

RAW_VALUE 3 como aproximadamente 3% de desgaste utilizado.

Esses campos são específicos do fabricante. Em outros modelos, o significado do valor normalizado ou do valor bruto pode ser diferente.

Total gravado

O script calcula o total aproximado gravado usando:

Total_LBAs_Written × tamanho do setor lógico

O tamanho do setor é obtido pela linha:

Sector Size: 512 bytes logical/physical

Quando o tamanho não pode ser identificado, o script utiliza 512 bytes como fallback.

O resultado é apresentado em TB decimal e TiB binário, por exemplo:

2.26 TB (2.06 TiB)

Classificação do resultado

Saudável

O script retorna SAUDÁVEL quando não encontra indicadores críticos nem avisos.

Atenção

Pode ser gerado por situações como:

blocos realocados;

erros CRC SATA;

vida útil restante entre 11% e 20%;

temperatura entre 60 °C e 69 °C;

registros de erros no histórico SMART;

mensagens de I/O ou sistema de arquivos no kernel;

autoteste ainda em execução ou sem resultado conclusivo.

Crítico

Pode ser gerado por situações como:

avaliação SMART indicando falha iminente;

atributo Pre-fail abaixo do limite;

falhas de programação ou apagamento NAND;

erros não corrigíveis;

setores ou ECC pendentes;

erros offline não corrigíveis;

vida útil restante igual ou inferior a 10%;

temperatura igual ou superior a 70 °C;

autoteste concluído com erro.

Códigos de saída

Código

Estado

0

Saudável.

1

Atenção.

2

Crítico.

Exemplo de uso em outro script:

sudo ./teste_saude_disco.sh /dev/sda report
rc=$?

case "$rc" in 0) echo "Disco saudável" ;;

1. echo "Disco requer atenção" ;;
2. echo "Disco em estado crítico" ;;
   \*) echo "Falha ao executar o diagnóstico" ;;
   esac

Execução pelo cron

Exemplo de relatório semanal às 02:00 de domingo:

0 2 \* \* 0 root /usr/local/sbin/teste-saude-disco /dev/sda report >> /var/log/teste-saude-disco-cron.log 2>&1

Não é recomendável executar o modo full com muita frequência. Para monitoramento recorrente, normalmente o modo report é suficiente, deixando o teste longo para janelas de manutenção.

Integração com Zabbix

O código de saída pode ser usado por um UserParameter ou por um script externo.

Exemplo conceitual:

UserParameter=disk.smart.health,/usr/local/sbin/teste-saude-disco /dev/sda report >/dev/null 2>&1; echo $?

Interpretação:

0 = saudável
1 = atenção
2 = crítico

Em ambientes Zabbix, avalie também coletar diretamente atributos individuais com smartctl, para evitar executar um relatório completo a cada consulta do agente.

Cuidados importantes

SMART não substitui backup

Um disco pode falhar mesmo apresentando PASSED. Mantenha backup atualizado e teste regularmente a restauração.

SMART não substitui fsck

O SMART avalia principalmente o dispositivo físico e seu firmware. Ele não corrige inconsistências em ext4, XFS ou outros sistemas de arquivos.

Não execute fsck em uma partição montada para leitura e escrita.

Impacto do teste longo

O autoteste estendido normalmente pode ser executado com o sistema online, mas pode reduzir temporariamente o desempenho de I/O. Em servidores críticos, prefira uma janela de manutenção.

Erros CRC SATA

Um valor maior que zero em UDMA_CRC_Error_Count pode indicar:

cabo SATA com defeito;

conector frouxo;

porta SATA problemática;

interferência elétrica;

controladora ou backplane com falha.

Esse atributo não significa necessariamente defeito na memória NAND. O mais importante é verificar se o contador continua aumentando.

Perdas inesperadas de energia

O atributo Unexpect_Power_Loss_Ct registra desligamentos inesperados. Valores elevados podem justificar a verificação de:

nobreak;

fonte de alimentação;

desligamentos forçados;

quedas de energia;

reinicializações por hardware.

Limitações

Os IDs SMART e seus significados podem variar entre fabricantes;

alguns atributos são específicos do firmware do dispositivo;

adaptadores USB podem bloquear comandos SMART;

controladoras RAID podem exigir parâmetros específicos em SMART_DEVICE_TYPE;

a análise detalhada foi pensada principalmente para discos ATA/SATA;

discos NVMe possuem estrutura SMART diferente e não são o foco desta versão;

mensagens antigas do kernel podem gerar aviso mesmo quando o problema já foi corrigido;

o cálculo de dados gravados depende da interpretação correta de Total_LBAs_Written pelo fabricante.

Para NVMe, use ferramentas como:

nvme smart-log /dev/nvme0

Verificação manual

Relatório completo:

sudo smartctl -x /dev/sda

Saúde geral:

sudo smartctl -H /dev/sda

Histórico de autotestes:

sudo smartctl -l selftest /dev/sda

Erros registrados pelo disco:

sudo smartctl -l error /dev/sda

Mensagens relacionadas a disco no kernel:

journalctl -k --no-pager | \
 grep -Ei 'I/O error|Buffer I/O|medium error|uncorrect|EXT[234]-fs error|XFS._error|ata[0-9]+._(error|failed)'

Compatibilidade testada pelo projeto

Versão documentada do script:

1.1.0

A compatibilidade com outros discos depende do suporte oferecido pelo smartctl e pelo firmware do dispositivo.

Licença

Uso interno e operacional. Revise e adapte o script às políticas de segurança, manutenção e backup do seu ambiente antes de utilizá-lo em produção.
