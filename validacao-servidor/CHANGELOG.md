# Histórico

## 1.3.0

- Diagnóstico prático padrão com conclusão, prioridades, evidências e ações.
- Uptime, último boot e contagem limitada ao histórico wtmp disponível.
- SMART em JSON: horas do disco, ciclos, desligamentos inesperados reconhecidos e comparação inicial/final por série.
- Resultado e cobertura do memtester; temperatura máxima e ocupação de disco.
- Diferencia desgaste, defeito de mídia, comunicação SATA e falha de execução.
- Perfis auto/hardware/ipbx e condição informada nova/usada/energia.
- Logs completos preservados; --relatorio-completo permite exibi-los.
- Novo auxiliar Python 3 instalado com o script; sem serviços externos.

## 1.2.0

- Contador ao vivo em HH:MM:SS, estimativa por comando e limite separado.
- Contagem durante a espera do autoteste SMART.
- Relatório completo exibido ao finalizar, com títulos, cores e resultados por etapa.
- Arquivos de relatório sem códigos de cor; suporte a NO_COLOR.
- Manual e README reduzidos, com comandos diretos para root.

## 1.1.0

- Distribuição pelo GitHub, instalador com backup e instruções de atualização.
- Comando `--versao` e identificação explícita do modo de execução.
- Consulta final do journal usa data no formato aceito pelo Debian 11.
- Falha de consulta ao journal é separada de entradas reais de erro.
- Alertas mostram o caminho e as últimas linhas da evidência no terminal.
- Detalhes e logs das primeiras dez unidades com falha são coletados.
- `--alvo-rede INTERFACE=IP` permite ping local sem segunda rota default.
- Mensagens distintas para ausência de link, half-duplex e iperf sem destino.
- Contadores sem incremento não são tratados como prova de tráfego na placa.
- Ausência de iptables-save é descrita sem instalar ou alterar firewall.

## 1.0.0

- Coleta em 11 etapas, relatórios locais e modo completo em manutenção.
- Limites de recursos, watchdog de temperatura/RAM e resultado parcial na interrupção.
- Comandos e exemplos para execução direta como root.
