# Histórico

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
