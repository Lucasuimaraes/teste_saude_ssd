#!/usr/bin/env bash
# Validação sequencial de servidores Debian 11 — v1.1.0
# Não executa testes de carga sem --modo completo --confirmar-manutencao.
# Não formata discos, não altera rede/firewall e não reinicia serviços.
set -uo pipefail
export LC_ALL=C
umask 077

VERSION=1.1.0
MODE=consulta
CONFIRM=0
INSTALL=0
STEPS=1,2,3,4,5,6,7,8,9,10,11
BASE=/var/log/validacao-servidor
DISK_DIR=/var/tmp
MEM_MAX=1024
TEMP_LIMIT=85
ALLOW_NO_SENSOR=0
USE_CUSTOM=0
IPERF_SERVER=
INTERNET=8.8.8.8
DNS_NAME=google.com
CLIENTE='Não informado'
TECNICO='Não informado'
declare -a DISKS=() IFACES=() VALID_DISKS=() CPU_SENSORS=()
declare -A NETWORK_TARGETS=()
REPORT= ACTIVE= WATCHER= LAST_LOG= LAST_STATUS= WORKDIR=
LAST_RC=0
SEQ=0
STAGE=0
FINISHED=0
INTERRUPTED=0
ABORT_LOAD=0
MEMTEST_DONE=0
MEM_MB=0
START_ISO=
START_JOURNAL=

usage() {
cat <<'EOF'
Validação de servidores Debian 11 — SSD/HD SATA
Uso (conectado como root): bash validar-servidor.sh [opções]
  --modo consulta|completo   Consulta é o padrão, sem carga proposital.
  --confirmar-manutencao     Obrigatório para o modo completo.
  --disco /dev/sda           Repita para outros discos SATA; padrão /dev/sda.
  --interface eth0           Repita para selecionar NICs; padrão autodetectar.
  --alvo-rede eth1=IP        Testa um destino por placa, mesmo sem rota default.
  --etapas 1,2,5             Etapas de 1 a 11, na ordem do manual.
  --saida /caminho           Pasta-base; padrão /var/log/validacao-servidor.
  --diretorio-disco /pasta   Local do teste de escrita; padrão /var/tmp.
  --memoria-mb 1024          Teto de RAM por teste; máximo aceito 4096 MiB.
  --limite-temp 85           Limite de temperatura CPU em °C (40 a 110).
  --permitir-sem-sensor      Autoriza carga sem sensor CPU reconhecido.
  --script-saude             Inclui o script local teste-saude-disco, se instalado.
  --iperf-servidor IP        Testa vazão em manutenção; iperf3 -s no destino.
  --ip-internet IP           Destino ICMP; padrão 8.8.8.8.
  --nome-dns dominio         Nome para resolver; padrão google.com.
  --cliente 'Nome'           Identificação no relatório.
  --tecnico 'Nome'           Responsável no relatório.
  --instalar-dependencias    Só instala ferramentas, não executa a validação.
  --ajuda                   Mostra esta ajuda.
  --versao                  Mostra a versão instalada.

Exemplo completo (somente em manutenção, com backup confirmado):
  bash validar-servidor.sh --modo completo --confirmar-manutencao --disco /dev/sda

Saídas: RESUMO.txt, RELATORIO_COMPLETO.txt, resultados.tsv e logs por comando.
Códigos: 0 = coleta concluída sem alertas detectados (não certifica o servidor);
         1 = alertas/falhas/itens inconclusivos; 2 = uso ou preparação inválidos;
         130/143 = execução interrompida. Testes omitidos continuam explícitos.
EOF
}
die() { printf 'ERRO: %s\n' "$*" >&2; exit 2; }
need_value() { [[ $# -ge 2 && -n $2 ]] || die "Falta valor para $1"; }
parse_args() {
    while (($#)); do
        case $1 in
            --ajuda|-h|--help) usage; exit 0 ;;
            --versao|--version) printf 'validar-servidor %s\n' "$VERSION"; exit 0 ;;
            --confirmar-manutencao) CONFIRM=1; shift ;;
            --permitir-sem-sensor) ALLOW_NO_SENSOR=1; shift ;;
            --script-saude) USE_CUSTOM=1; shift ;;
            --instalar-dependencias) INSTALL=1; shift ;;
            --alvo-rede)
                need_value "$@"
                local net_iface=${2%%=*} net_target=${2#*=}
                [[ $2 == *=* && $net_iface =~ ^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,14}$ && $net_target =~ ^[a-zA-Z0-9][a-zA-Z0-9.:-]*$ ]] || die 'Use --alvo-rede INTERFACE=IP.'
                NETWORK_TARGETS["$net_iface"]=$net_target
                shift 2 ;;
            --modo|--saida|--diretorio-disco|--memoria-mb|--limite-temp|--etapas|--disco|--interface|--iperf-servidor|--ip-internet|--nome-dns|--cliente|--tecnico)
                need_value "$@"
                case $1 in
                    --modo) MODE=$2 ;; --saida) BASE=$2 ;; --diretorio-disco) DISK_DIR=$2 ;;
                    --memoria-mb) MEM_MAX=$2 ;; --limite-temp) TEMP_LIMIT=$2 ;;
                    --etapas) STEPS=$2 ;; --disco) DISKS+=("$2") ;;
                    --interface) IFACES+=("$2") ;; --iperf-servidor) IPERF_SERVER=$2 ;;
                    --ip-internet) INTERNET=$2 ;; --nome-dns) DNS_NAME=$2 ;;
                    --cliente) CLIENTE=$2 ;; --tecnico) TECNICO=$2 ;;
                esac
                shift 2 ;;
            *) die "Opção desconhecida: $1" ;;
        esac
    done
    [[ $MODE == consulta || $MODE == completo ]] || die 'Modo inválido.'
    [[ $MODE != completo || $CONFIRM == 1 ]] || die 'Modo completo exige --confirmar-manutencao.'
    [[ $MEM_MAX =~ ^[1-9][0-9]{0,3}$ ]] || die 'Memória inválida.'
    ((MEM_MAX >= 64 && MEM_MAX <= 4096)) || die 'Use entre 64 e 4096 MiB.'
    [[ $TEMP_LIMIT =~ ^[1-9][0-9]{1,2}$ ]] || die 'Temperatura inválida.'
    ((TEMP_LIMIT >= 40 && TEMP_LIMIT <= 110)) || die 'Limite deve estar entre 40 e 110 °C.'
    [[ $STEPS =~ ^(10|11|[1-9])(,(10|11|[1-9]))*$ ]] || die 'Etapas inválidas.'
    [[ $BASE == /* && $DISK_DIR == /* ]] || die 'Os diretórios devem ser caminhos absolutos.'
    local item
    for item in "$BASE" "$DISK_DIR" "$CLIENTE" "$TECNICO"; do
        [[ $item != *$'\n'* && $item != *$'\r'* && $item != *$'\t'* ]] || die 'Caracteres de controle não permitidos.'
    done
    for item in "$INTERNET" "$DNS_NAME" "${IPERF_SERVER:-na}"; do
        [[ $item =~ ^[a-zA-Z0-9][a-zA-Z0-9.:-]*$ ]] || die "Destino inválido: $item"
    done
    ((${#DISKS[@]})) || DISKS=(/dev/sda)
    for item in "${DISKS[@]}"; do
        [[ $item =~ ^/dev/sd[a-z]+$ ]] || die 'Selecione discos inteiros SATA, por exemplo /dev/sda; não partições.'
    done
    for item in "${IFACES[@]}"; do
        [[ $item =~ ^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,14}$ ]] || die "Interface inválida: $item"
    done
}

record() {
    local status=$1 title=$2 details=${3:-} logfile=${4:-} rc=${5:--}
    details=${details//$'\n'/ }; details=${details//$'\t'/ }
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$STAGE" "$status" "$title" "$rc" "$details" "$logfile" >> "$REPORT/resultados.tsv"
    printf '[%s] %s — %s\n' "$status" "$title" "$details"
    LAST_STATUS=$status
}
skip() { record NAO_EXECUTADO "$1" "$2"; }
stage() { STAGE=$1; printf '\n===== ETAPA %s — %s =====\n' "$1" "$2"; }
selected() { [[ ,$STEPS, == *,$1,* ]]; }

# Exit codes SMART são bitmask, não o código genérico de uma falha de disco.
classify() {
    local policy=$1 rc=$2 file=$3
    STATUS=COLETADO; DETAIL='Saída coletada; revisar evidência.'
    if ((rc == 124 || rc == 137)); then
        STATUS=INCONCLUSIVO; DETAIL='Tempo limite excedido ou processo encerrado; teste incompleto.'; return
    fi
    case $policy in
        smart)
            if ((rc & 24)); then STATUS=FALHA; DETAIL="SMART: condição crítica/limiar excedido; bitmask=$rc."
            elif ((rc != 0)); then STATUS=ATENCAO; DETAIL="SMART: comando parcial, histórico ou atributos; bitmask=$rc, não equivale automaticamente a defeito."
            else DETAIL='SMART coletado; código 0 não substitui análise de desgaste e atributos.'; fi ;;
        carga)
            if ((rc == 0)); then STATUS=OK; DETAIL='Teste terminou sem erro informado pela ferramenta.'
            else STATUS=FALHA; DETAIL="Teste retornou $rc; investigar log (pode ser ambiente/recursos, não só hardware)."; fi ;;
        ping)
            if ((rc != 0)); then STATUS=ATENCAO; DETAIL='Sem resposta ou erro de rede; ICMP pode ser bloqueado.'
            elif grep -Eq '(^|[[:space:],])0% packet loss' "$file"; then STATUS=OK; DETAIL='0% de perda no destino testado.'
            else STATUS=ATENCAO; DETAIL='Há perda ou não foi possível interpretar o resultado.'; fi ;;
        failed_units)
            if ((rc != 0)); then STATUS=INCONCLUSIVO; DETAIL='Não foi possível consultar systemd.'
            elif [[ -s $file ]]; then STATUS=ATENCAO; DETAIL='Há unidades com falha; revisar saída.'
            else STATUS=OK; DETAIL='Nenhuma unidade failed encontrada.'; fi ;;
        journal)
            if ((rc != 0)); then STATUS=INCONCLUSIVO; DETAIL='Falha ao consultar o journal; ver mensagem do comando, não confundir com erro do servidor.'
            elif grep -qvE '^--|^[[:space:]]*$' "$file"; then STATUS=ATENCAO; DETAIL='Há entradas de erro no período consultado; revisar evidência.'
            else STATUS=OK; DETAIL='Nenhuma entrada de erro encontrada no período consultado.'; fi ;;
        service_status)
            if ((rc == 3)); then STATUS=ATENCAO; DETAIL='Serviço não ativo ou sistema degradado; conferir saída.'
            elif ((rc != 0)); then STATUS=INCONCLUSIVO; DETAIL="Consulta do serviço retornou $rc."
            else DETAIL='Status coletado.'; fi ;;
        ntp)
            if ((rc != 0)); then STATUS=INCONCLUSIVO; DETAIL='Não foi possível verificar sincronismo.'
            elif grep -qx yes "$file"; then STATUS=OK; DETAIL='Sistema informa relógio sincronizado.'
            else STATUS=ATENCAO; DETAIL='Sincronismo não confirmado; conferir serviço NTP.'; fi ;;
        check)
            if ((rc == 0)); then STATUS=OK; DETAIL='Verificação respondeu com sucesso.'
            else STATUS=ATENCAO; DETAIL="Verificação retornou $rc; revisar saída."; fi ;;
        *) if ((rc != 0)); then STATUS=INCONCLUSIVO; DETAIL="Coleta retornou $rc; não inferir defeito automaticamente."; fi ;;
    esac
}

discover_sensors() {
    CPU_SENSORS=()
    local dir name file
    for dir in /sys/class/hwmon/hwmon*; do
        [[ -r $dir/name ]] || continue
        read -r name < "$dir/name"
        case $name in coretemp|k10temp|k8temp|zenpower|cpu_thermal)
            for file in "$dir"/temp[0-9]*_input; do [[ -r $file ]] && CPU_SENSORS+=("$file"); done ;;
        esac
    done
}
cpu_temp() {
    local file n max=0
    for file in "${CPU_SENSORS[@]}"; do
        read -r n < "$file" || continue
        [[ $n =~ ^[0-9]+$ ]] || continue
        ((n > 0 && n < 150000 && n > max)) && max=$n
    done
    printf '%s\n' "$max"
}
available_mb() { awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo; }
budget_memory() {
    local available
    available=$(available_mb)
    [[ $available =~ ^[0-9]+$ ]] || available=0
    MEM_MB=$((available / 2))
    ((MEM_MB > MEM_MAX)) && MEM_MB=$MEM_MAX
    ((available - MEM_MB < 512)) && MEM_MB=$((available - 512))
    ((MEM_MB >= 64))
}
load_allowed() {
    local title=$1 temp
    if [[ $MODE != completo ]]; then skip "$title" 'Exige modo completo em manutenção.'; return 1; fi
    if ((ABORT_LOAD)); then skip "$title" 'Carga bloqueada após alerta crítico anterior.'; return 1; fi
    temp=$(cpu_temp)
    if ((temp == 0 && !ALLOW_NO_SENSOR)); then
        skip "$title" 'Sem sensor CPU reconhecido; use --permitir-sem-sensor somente com supervisão externa.'; return 1
    fi
    if ((temp >= TEMP_LIMIT * 1000)); then
        ABORT_LOAD=1; record FALHA "$title" 'Temperatura CPU já acima do limite; carga bloqueada.'; return 1
    fi
    return 0
}
watch_load() {
    # Vigia somente o grupo deste teste. Não controla processos de terceiros.
    trap 'exit 0' TERM INT
    local target=$1 marker=$2 temp avail
    while kill -0 "$target" 2>/dev/null; do
        temp=$(cpu_temp); avail=$(available_mb)
        printf '%s\t%s\t%s\n' "$(date -Is)" "$temp" "${avail:-0}" >> "$REPORT/temperatura_memoria.tsv"
        if ((temp == 0 && !ALLOW_NO_SENSOR)); then
            printf 'Leitura do sensor CPU ficou indisponível; carga interrompida.\n' > "$marker"
        elif ((temp >= TEMP_LIMIT * 1000)); then
            printf 'Temperatura CPU atingiu %s miligraus (limite %s °C).\n' "$temp" "$TEMP_LIMIT" > "$marker"
        elif [[ $avail =~ ^[0-9]+$ ]] && ((avail < 128)); then
            printf 'MemAvailable inferior a 128 MiB; carga interrompida.\n' > "$marker"
        fi
        if [[ -s $marker ]]; then
            kill -TERM -- "-$target" 2>/dev/null || true
            sleep 2
            kill -KILL -- "-$target" 2>/dev/null || true
            return
        fi
        sleep 5
    done
}

run() {
    local title=$1 policy=$2 limit=$3 rc marker started
    shift 3
    SEQ=$((SEQ + 1)); LAST_RC=127; LAST_STATUS=NAO_EXECUTADO
    printf -v LAST_LOG '%s/logs/%03d_etapa_%02d.txt' "$REPORT" "$SEQ" "$STAGE"
    if ! command -v "$1" >/dev/null 2>&1; then
        skip "$title" "Ferramenta ausente: $1"; return 0
    fi
    marker="$REPORT/.interromper-$SEQ"
    printf '\nExecutando: %s (limite %ss)\n' "$title" "$limit"
    { printf 'Título: %s\nInício: %s\nComando: ' "$title" "$(date -Is)"; printf '%q ' "$@"; printf '\n'; } >> "$REPORT/comandos.txt"
    started=$SECONDS
    # Grupo isolado permite interromper também os subprocessos do teste.
    setsid timeout --signal=TERM --kill-after=10s "${limit}s" "$@" > "$LAST_LOG" 2>&1 &
    ACTIVE=$!
    if [[ $policy == carga ]]; then watch_load "$ACTIVE" "$marker" & WATCHER=$!; fi
    wait "$ACTIVE"; rc=$?
    # Elimina descendentes remanescentes somente no grupo isolado deste comando.
    kill -KILL -- "-$ACTIVE" 2>/dev/null || true
    ACTIVE=
    if [[ -n $WATCHER ]]; then kill "$WATCHER" 2>/dev/null || true; wait "$WATCHER" 2>/dev/null || true; WATCHER=; fi
    LAST_RC=$rc
    classify "$policy" "$rc" "$LAST_LOG"
    if [[ $policy == smart && $STATUS == FALHA ]]; then ABORT_LOAD=1; fi
    if [[ $1 == memtester && $rc == 0 ]] && grep -Eqi 'warning|failed|could not' "$LAST_LOG"; then
        STATUS=ATENCAO; DETAIL='Memtester terminou, mas há avisos; revisar bloqueio da RAM e cobertura efetiva.'
    fi
    if [[ -s $marker ]]; then
        ABORT_LOAD=1; STATUS=FALHA; DETAIL=$(<"$marker")
    elif [[ $policy == carga && $rc != 0 ]]; then
        ABORT_LOAD=1
        DETAIL+=' As próximas cargas foram bloqueadas por precaução.'
    fi
    record "$STATUS" "$title" "$DETAIL Duração: $((SECONDS - started))s." "${LAST_LOG#"$REPORT/"}" "$rc"
    if [[ $STATUS == FALHA || $STATUS == ATENCAO || $STATUS == INCONCLUSIVO ]]; then
        printf 'Evidência: %s\nÚltimas linhas do comando:\n' "$LAST_LOG"
        tail -n 6 "$LAST_LOG"
    fi
    return 0
}

stop_children() {
    if [[ -n $WATCHER ]]; then kill "$WATCHER" 2>/dev/null || true; wait "$WATCHER" 2>/dev/null || true; WATCHER=; fi
    if [[ -n $ACTIVE ]]; then
        kill -TERM -- "-$ACTIVE" 2>/dev/null || true
        sleep 1
        kill -KILL -- "-$ACTIVE" 2>/dev/null || true
        wait "$ACTIVE" 2>/dev/null || true
        ACTIVE=
    fi
}
finish() {
    local exit_code=$? file
    ((FINISHED)) && return
    FINISHED=1
    stop_children
    [[ -d $REPORT ]] || return
    if [[ -n $WORKDIR && -d $WORKDIR ]]; then
        rmdir -- "$WORKDIR" 2>/dev/null || record ATENCAO 'Arquivos temporários' "Restaram arquivos em $WORKDIR; revisar e remover manualmente."
    fi
    if ((INTERRUPTED || exit_code != 0)); then record INCONCLUSIVO 'Execução parcial' "Interrompida ou encerrada com código $exit_code; veja últimos logs."; fi
    {
        printf 'VALIDAÇÃO DE SERVIDOR — versão %s\n' "$VERSION"
        printf 'Cliente: %s\nTécnico: %s\n' "$CLIENTE" "$TECNICO"
        printf 'Host: %s\nInício: %s\nFim: %s\nModo: %s\nEtapas: %s\n' "$(hostname)" "$START_ISO" "$(date -Is)" "$MODE" "$STEPS"
        printf 'Discos solicitados: %s\nInterfaces: %s\n' "${DISKS[*]}" "${IFACES[*]:-nenhuma}"
        printf 'Relatório: %s\n\n' "$REPORT"
        if ((INTERRUPTED || exit_code != 0)); then printf 'RESULTADO: EXECUÇÃO INCOMPLETA.\n'
        elif awk -F '\t' 'NR>1 && ($2=="FALHA" || $2=="ATENCAO" || $2=="INCONCLUSIVO") {found=1} END {exit !found}' "$REPORT/resultados.tsv"; then
            printf 'RESULTADO: REVISÃO TÉCNICA NECESSÁRIA.\n'
        else printf 'RESULTADO: COLETA CONCLUÍDA SEM ALERTAS AUTOMÁTICOS.\n'; fi
        printf 'Não é um certificado de aprovação. COLETADO não significa APROVADO.\n'
        printf 'NAO_EXECUTADO: não testado; não pode ser considerado aprovado.\n'
        printf 'Verificar logs, itens omitidos e chamadas reais antes da entrega.\n\n'
        awk -F '\t' 'NR>1 {n[$2]++} END {for(k in n) printf "%s: %d\n", k, n[k]}' "$REPORT/resultados.tsv"
        if [[ -s $REPORT/temperatura_memoria.tsv ]]; then
            awk -F '\t' 'NR>1 && $2>m {m=$2} END {if(m>0) printf "Maior temperatura CPU amostrada: %.1f °C\n",m/1000; else print "Temperatura CPU máxima: não disponível"}' "$REPORT/temperatura_memoria.tsv"
        fi
        printf '\nRESULTADOS POR ETAPA\n'
        awk -F '\t' 'NR>1 {printf "Etapa %s | %s | %s | %s | log: %s\n",$1,$2,$3,$5,$6}' "$REPORT/resultados.tsv"
        printf '\nPENDÊNCIAS MANUAIS\n- Conferir backup e teste de restauração.\n- Testar chamadas, áudio nos dois sentidos, transferência, filas e gravação.\n- Confirmar nobreak, cabeamento e ventilação.\n- Revisar atualizações e cobertura de segurança do Debian 11.\n- Registrar aprovação final e assinatura do técnico.\n'
        printf '\nExceções: mensagem EXT4 de remontagem com errors=remount-ro e link SATA 3 Gb/s, isoladamente, não são tratados como defeitos. Os logs brutos são preservados. Erros reais EXT4/I/O não são ocultados.\n'
    } > "$REPORT/RESUMO.txt"
    {
        cat "$REPORT/RESUMO.txt"
        printf '\nCOMANDOS EXECUTADOS\n'; cat "$REPORT/comandos.txt"
        for file in "$REPORT"/logs/*.txt; do
            [[ -f $file ]] || continue
            printf '\n===== %s =====\n' "${file##*/}"
            cat "$file"
        done
    } > "$REPORT/RELATORIO_COMPLETO.txt"
    printf '\nRelatórios salvos em: %s\nResumo: %s/RESUMO.txt\n' "$REPORT" "$REPORT"
}

prepare() {
    ((EUID == 0)) || die 'Conecte-se como root para executar este script.'
    local cmd disk iface dir
    for cmd in timeout setsid flock mktemp awk grep date stat findmnt lsblk; do
        command -v "$cmd" >/dev/null || die "Dependência básica ausente: $cmd"
    done
    # Bloqueio do processo, sem apagar arquivo ao sair.
    [[ ! -L /run/validar-servidor.lock ]] || die 'Lock é um link simbólico; revisar /run.'
    exec 9>/run/validar-servidor.lock || die 'Não foi possível abrir lock.'
    flock -n 9 || die 'Outra validação está em execução.'
    mkdir -p -- "$BASE" || die 'Não foi possível criar pasta-base.'
    BASE=$(realpath -e -- "$BASE") || die 'Pasta-base inválida.'
    [[ $(stat -c %u "$BASE") == 0 ]] || die 'Pasta-base deve pertencer ao root.'
    local perm; perm=$(stat -c %a "$BASE")
    (( (8#$perm & 0022) == 0 )) || die 'Pasta-base não pode permitir escrita para grupo/outros.'
    REPORT=$(mktemp -d "$BASE/$(date +%Y%m%d-%H%M%S)-XXXXXX") || die 'Falha ao criar pasta da execução.'
    mkdir "$REPORT/logs" || die 'Falha ao criar logs.'
    START_ISO=$(date -Is)
    START_JOURNAL=$(date '+%Y-%m-%d %H:%M:%S')
    printf 'etapa\tstatus\tteste\tcodigo\tdetalhes\tlog\n' > "$REPORT/resultados.tsv"
    printf 'data\ttemperatura_cpu_miligraus\tmem_disponivel_mib\n' > "$REPORT/temperatura_memoria.tsv"
    : > "$REPORT/comandos.txt"
    trap finish EXIT
    trap 'INTERRUPTED=1; exit 130' INT
    trap 'INTERRUPTED=1; exit 143' TERM HUP
    for disk in "${DISKS[@]}"; do
        if [[ -b $disk ]] && [[ $(lsblk -dn -o TYPE "$disk" 2>/dev/null) == disk ]]; then VALID_DISKS+=("$disk")
        else record ATENCAO 'Disco selecionado' "$disk não está disponível como disco inteiro; testes desse disco serão omitidos."; fi
    done
    if ((${#IFACES[@]} == 0)); then
        for dir in /sys/class/net/*; do
            [[ -e $dir/device && -r $dir/type ]] || continue
            [[ $(<"$dir/type") == 1 ]] && IFACES+=("${dir##*/}")
        done
    fi
    discover_sensors
    [[ $MODE == completo && ${#CPU_SENSORS[@]} == 0 ]] && record ATENCAO 'Sensor CPU' 'Nenhum sensor CPU reconhecido; sensores podem existir com outros drivers.'
    [[ $MODE == completo && $ALLOW_NO_SENSOR == 1 ]] && record ATENCAO 'Proteção térmica' 'Usuário autorizou carga sem sensor CPU; supervisão externa necessária se leitura indisponível.'
    printf 'Relatório desta execução: %s\n' "$REPORT"
    printf 'Versão: %s | Modo: %s | Etapas: %s\n' "$VERSION" "$MODE" "$STEPS"
    if [[ $MODE == consulta ]]; then
        record INFO 'Modo consulta' 'CPU/RAM, memtester, autotestes e benchmarks não serão executados. Para a rodada com carga use --modo completo --confirmar-manutencao.'
    fi
}

memtest() {
    ((MEMTEST_DONE)) && { record INFO 'Memtester' 'Resultado já registrado na etapa 1; não repetir.'; return; }
    load_allowed 'Memtester' || return
    budget_memory || { skip 'Memtester' 'Memória disponível insuficiente para manter reserva de 512 MiB.'; return; }
    run "Memtester ${MEM_MB}MiB, 2 passagens" carga 3600 memtester "${MEM_MB}M" 2
    MEMTEST_DONE=1
}
step1() {
    stage 1 HARDWARE
    run 'Temperatura inicial' coleta 20 sensors
    run 'Memória disponível' coleta 20 free -h
    if load_allowed 'Stress inicial CPU/RAM'; then
        if budget_memory; then
            run "CPU/RAM por 120s; RAM ${MEM_MB}MiB" carga 150 stress-ng --cpu 0 --cpu-method all --vm 1 --vm-bytes "${MEM_MB}M" --verify --oomable --timeout 120s --metrics-brief --tz
        else skip 'Stress inicial CPU/RAM' 'Memória insuficiente.'; fi
    fi
    memtest
    run 'Temperatura após teste' coleta 20 sensors
    local disk
    for disk in "${VALID_DISKS[@]}"; do
        run "SMART inicial $disk" smart 90 smartctl -x "$disk"
        if ((USE_CUSTOM)); then
            if load_allowed "Script local de saúde $disk"; then
                run "Script local de saúde $disk" carga 7200 /usr/local/sbin/teste-saude-disco "$disk" full
            fi
        else skip "Script local de saúde $disk" 'Opcional: habilitar --script-saude após revisar seu código. SMART nativo é coletado independentemente.'; fi
    done
    run 'Espaço em disco' coleta 30 df -h
    run 'Inodes' coleta 30 df -i
    run 'Partições' coleta 30 lsblk -f
    run 'I/O amostrado' coleta 30 iostat -xz 1 10
}
step2() {
    stage 2 'REDE ONBOARD/OFFBOARD'
    run 'Interfaces' coleta 20 ip -br link
    run 'Placas e drivers PCI (saída completa)' coleta 30 lspci -nnk
    local iface gateway before after key v1 v2 delta target link_down
    ((${#IFACES[@]})) || skip 'Teste de NICs' 'Nenhuma placa detectada; informe --interface se necessário.'
    for iface in "${IFACES[@]}"; do
        [[ -d /sys/class/net/$iface ]] || { skip "Interface $iface" 'Interface inexistente.'; continue; }
        run "Driver $iface" coleta 20 ethtool -i "$iface"
        run "Link/velocidade/duplex $iface" coleta 20 ethtool "$iface"
        link_down=0
        if [[ -f $LAST_LOG ]] && grep -q 'Link detected: no' "$LAST_LOG"; then
            link_down=1; record ATENCAO "Link $iface" 'Sem link físico: conectar cabo/porta do switch. Tráfego desta placa não poderá ser validado.'
        fi
        if [[ -f $LAST_LOG ]] && grep -q 'Duplex: Half' "$LAST_LOG"; then record ATENCAO "Duplex $iface" 'Half-duplex detectado; revisar negociação, cabo e switch.'; fi
        record INFO "Cabo $iface" 'Link detectado não certifica integridade do cabo; avaliar erros e tráfego.'
        before="$REPORT/nic-$iface-antes.tsv"; after="$REPORT/nic-$iface-depois.tsv"
        for key in rx_errors tx_errors rx_dropped tx_dropped collisions; do
            [[ -r /sys/class/net/$iface/statistics/$key ]] && printf '%s\t%s\n' "$key" "$(<"/sys/class/net/$iface/statistics/$key")"
        done > "$before"
        run "Contadores iniciais $iface" coleta 20 ip -s link show dev "$iface"
        run "Estatísticas do driver $iface" coleta 20 ethtool -S "$iface"
        gateway=$(ip -4 route show default dev "$iface" 2>/dev/null | awk '/via/ {print $3; exit}')
        target=${NETWORK_TARGETS[$iface]:-}
        if [[ -n $target && $link_down == 0 ]]; then
            run "Destino local $target via $iface" ping 110 ping -n -I "$iface" -c 50 -W 2 "$target"
        elif [[ -n $target ]]; then skip "Destino local via $iface" 'Sem link físico; conecte a placa antes de repetir.'; fi
        if [[ -n $gateway && $link_down == 0 ]]; then
            run "Gateway $gateway via $iface" ping 110 ping -n -I "$iface" -c 50 -W 2 "$gateway"
            run "Internet $INTERNET via $iface" ping 210 ping -n -I "$iface" -c 100 -W 2 "$INTERNET"
        else skip "Gateway/internet via $iface" "Link ausente ou sem rota default IPv4. Para rede local configurada, use --alvo-rede $iface=IP; não é necessário criar outra rota default."; fi
        if [[ -n $IPERF_SERVER ]]; then
            if [[ $MODE == completo && $link_down == 0 ]]; then
                local addr
                addr=$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk 'NR==1 {split($4,a,"/");print a[1]}')
                if [[ -n $addr ]]; then run "Vazão de saída $iface" check 50 iperf3 -c "$IPERF_SERVER" -B "$addr" -P 4 -t 30
                else skip "Vazão $iface" 'Sem IPv4 global configurado.'; fi
            else skip "Vazão $iface" 'iperf3 exige modo completo e link físico ativo.'; fi
        else skip "Vazão $iface" 'Execute iperf3 -s em outro equipamento e informe --iperf-servidor IP. O script não inventa um destino.'; fi
        for key in rx_errors tx_errors rx_dropped tx_dropped collisions; do
            [[ -r /sys/class/net/$iface/statistics/$key ]] && printf '%s\t%s\n' "$key" "$(<"/sys/class/net/$iface/statistics/$key")"
        done > "$after"
        while IFS=$'\t' read -r key v1; do
            v2=$(awk -v k="$key" '$1==k {print $2}' "$after")
            if [[ $v1 =~ ^[0-9]+$ && $v2 =~ ^[0-9]+$ ]]; then
                delta=$((v2-v1))
                if ((delta > 0)); then record ATENCAO "Contador $iface/$key" "Aumentou $delta ($v1 -> $v2); pode ser tráfego concorrente."
                elif ((delta < 0)); then record INCONCLUSIVO "Contador $iface/$key" 'Contador reiniciou durante a coleta.'
                else record COLETADO "Contador $iface/$key" 'Sem incremento durante a amostra; isoladamente não comprova tráfego nesta placa.'; fi
            fi
        done < "$before"
        run "Contadores finais $iface" coleta 20 ip -s link show dev "$iface"
    done
    run "Resolução DNS $DNS_NAME" check 30 getent ahosts "$DNS_NAME"
    run "Ping por nome $DNS_NAME (rota padrão)" ping 70 ping -c 20 -W 2 "$DNS_NAME"
}
step3() {
    stage 3 CPU
    run 'Modelo, núcleos e frequência' coleta 20 lscpu
    run 'Uso CPU/processos (equivalente automático ao htop)' coleta 20 top -b -n 3 -d 2
}
step4() { stage 4 MEMORIA; run 'Módulos e slots' coleta 30 dmidecode -t memory; run 'Memória/swap' coleta 20 free -h; memtest; }

selftest_code() {
    sed -n 's/.*Self-test execution status:[[:space:]]*([[:space:]]*\([0-9][0-9]*\)).*/\1/p' "$1" | head -n 1
}
smart_short() {
    local disk=$1 code deadline
    [[ $MODE == completo ]] || { skip "Autoteste curto $disk" 'Exige modo completo.'; return; }
    ((ABORT_LOAD)) && { skip "Autoteste curto $disk" 'Bloqueado após alerta crítico anterior.'; return; }
    run "Capacidades/autoteste atual $disk" smart 60 smartctl -c "$disk"
    if ((LAST_RC & 7)); then skip "Autoteste curto $disk" 'Falha ao consultar capacidades SMART.'; return; fi
    code=$(selftest_code "$LAST_LOG")
    [[ $code =~ ^[0-9]+$ ]] || { skip "Autoteste curto $disk" 'Status ATA não interpretável; verificar controlador manualmente.'; return; }
    if ((code >= 240)); then skip "Autoteste curto $disk" 'Já há autoteste em andamento; não interrompido nem substituído.'; return; fi
    run "Início autoteste curto $disk" smart 60 smartctl -t short "$disk"
    if ((LAST_RC & 7)) || ! grep -qi 'Testing has begun' "$LAST_LOG"; then
        record INCONCLUSIVO "Autoteste curto $disk" 'Início não confirmado; não declarar aprovação.'; return
    fi
    deadline=$((SECONDS + 900))
    while ((SECONDS < deadline)); do
        printf 'Aguardando autoteste SMART %s (consulta a cada 15s)...\n' "$disk"
        sleep 15
        run "Progresso autoteste $disk" smart 45 smartctl -c "$disk"
        code=$(selftest_code "$LAST_LOG")
        [[ $code =~ ^[0-9]+$ ]] || break
        ((code < 240)) && break
    done
    run "Histórico autotestes $disk" smart 60 smartctl -l selftest "$disk"
    if [[ $code == 0 ]] && grep -Eq '^#[[:space:]]*1[[:space:]]+Short offline[[:space:]]+Completed without error' "$LAST_LOG"; then
        record OK "Autoteste curto $disk" 'Controlador informa término e última entrada curta sem erro.'
    elif [[ $code =~ ^[0-9]+$ ]] && ((code > 0 && code < 240)); then
        record ATENCAO "Autoteste curto $disk" "Status ATA=$code; houve interrupção/falha. Revisar histórico."
    else record INCONCLUSIVO "Autoteste curto $disk" 'Término não comprovado no limite de 15 minutos. Teste no firmware pode continuar; não foi abortado.'; fi
}
step5() {
    stage 5 DISCO
    local disk
    ((${#VALID_DISKS[@]})) || skip 'Disco/SMART/benchmark' 'Nenhum disco SATA válido selecionado.'
    for disk in "${VALID_DISKS[@]}"; do
        run "SMART completo $disk" smart 90 smartctl -x "$disk"
        smart_short "$disk"
        if [[ $MODE == completo && $ABORT_LOAD == 0 ]]; then run "Leitura/cache $disk" coleta 90 hdparm -Tt "$disk"
        else skip "Benchmark $disk" 'Exige modo completo sem alerta crítico anterior.'; fi
    done
}
step6() {
    stage 6 LOGS
    run 'Kernel completo (sem pager)' coleta 30 dmesg -T
    run 'Erros boot atual (últimas 5000 entradas)' journal 45 journalctl -q -p err -b -n 5000 --no-pager
    run 'Kernel boot atual (últimas 5000 entradas)' coleta 45 journalctl -k -b -n 5000 --no-pager
    if [[ -f $LAST_LOG ]]; then
        grep -Ei 'error|fail|ata|I/O|mce|machine check|reset|timeout|oom|out of memory' "$LAST_LOG" > "$REPORT/logs/eventos-hardware.txt" || true
        # Exclui somente a mensagem informativa de remontagem, não erros EXT4 reais.
        if grep -Ev 'EXT4-fs .*re-mounted\. Opts: errors=remount-ro' "$REPORT/logs/eventos-hardware.txt" | grep -Eqi 'I/O error|machine check|uncorrected|out of memory|oom-kill|EXT4-fs error'; then
            record ATENCAO 'Eventos críticos no kernel' 'Há ocorrências para investigação; podem ser anteriores à validação.'
        fi
    fi
}
failed_details() {
    local failed_log=$LAST_LOG unit
    [[ $LAST_RC == 0 && -f $failed_log ]] || return
    while read -r unit; do
        [[ $unit =~ ^[a-zA-Z0-9][a-zA-Z0-9_.@:-]+$ ]] || continue
        run "Detalhes da unidade com falha: $unit" service_status 30 systemctl status "$unit" --no-pager --full
        run "Últimos logs da unidade: $unit" coleta 30 journalctl -u "$unit" -b -n 30 --no-pager
    done < <(awk 'NF {print $1}' "$failed_log" | head -n 10)
}
step7() {
    stage 7 SERVICOS
    run 'Unidades com falha' failed_units 30 systemctl --failed --no-legend --no-pager --plain
    failed_details
    run 'Visão geral systemd' service_status 30 systemctl status --no-pager --full
    run 'Serviços em execução' coleta 30 systemctl list-units --type=service --state=running --no-pager
    run 'Status Asterisk' check 30 systemctl is-active asterisk
    run 'Asterisk uptime' check 30 asterisk -rx 'core show uptime'
    run 'Asterisk canais' coleta 30 asterisk -rx 'core show channels'
    record INFO 'Telefonia' 'Status do processo não valida chamadas, RTP, troncos, filas ou gravação; testar manualmente.'
}
step8() {
    stage 8 REDE
    run 'Rotas IPv4' coleta 20 ip -4 route
    run 'Rotas IPv6' coleta 20 ip -6 route
    run 'Regras de roteamento' coleta 20 ip rule
    run 'Configuração DNS' coleta 20 cat /etc/resolv.conf
    run 'Endereços IP' coleta 20 ip addr
    run 'Portas em escuta' coleta 20 ss -lntup
    run 'Regras nftables (somente leitura)' coleta 30 nft list ruleset
    if command -v iptables-save >/dev/null 2>&1; then
        run 'Regras iptables (somente leitura)' coleta 30 iptables-save
    else record INFO 'Firewall legado' 'iptables-save não instalado. Consulta nftables registrada acima; regras legacy não verificadas. Não se instala/altera firewall durante validação.'; fi
}
step9() {
    stage 9 SINCRONISMO
    run 'Hora e timezone' coleta 20 timedatectl
    run 'Sincronismo NTP' ntp 20 timedatectl show -p NTPSynchronized --value
}
step10() {
    stage 10 SISTEMA
    run 'Identificação' coleta 20 hostnamectl
    run 'Kernel' coleta 20 uname -a
    run 'Distribuição' coleta 20 cat /etc/os-release
    run 'Reinicializações (20 registros)' coleta 20 last -x -n 20
    run 'Disco raiz' coleta 20 findmnt -no SOURCE,FSTYPE,TARGET /
    run 'Inventário discos' coleta 20 lsblk -d -o NAME,MODEL,SERIAL,SIZE,TYPE,ROTA
    record INFO 'Suporte do sistema' 'Registrar cobertura de segurança e compatibilidade; o script não altera repositórios nem atualiza o sistema.'
}
disk_stress() {
    load_allowed 'Stress de escrita em arquivo' || return
    [[ -d $DISK_DIR ]] || { skip 'Stress de escrita' 'Diretório de teste não existe.'; return; }
    local src fs free_k total_k disk match=0
    src=$(findmnt -no SOURCE --target "$DISK_DIR"); src=${src%%\[*}
    fs=$(findmnt -no FSTYPE --target "$DISK_DIR")
    case $fs in ext4|ext3|xfs|btrfs) ;; *) skip 'Stress de escrita' "Filesystem não autorizado automaticamente: $fs. Use diretório em disco local selecionado."; return ;; esac
    for disk in "${VALID_DISKS[@]}"; do
        if lsblk -snpo NAME "$src" 2>/dev/null | grep -Fxq "$disk"; then match=1; fi
    done
    ((match)) || { skip 'Stress de escrita' 'Não foi comprovado que o diretório pertence a um dos discos selecionados.'; return; }
    read -r total_k free_k < <(df -Pk "$DISK_DIR" | awk 'END {print $2,$4}')
    if [[ ! $free_k =~ ^[0-9]+$ || ! $total_k =~ ^[0-9]+$ ]] || ((free_k < 2359296 || free_k - 262144 < total_k / 10)); then
        skip 'Stress de escrita' 'Espaço insuficiente: reservar 2 GiB e 10% livres após arquivo de 256 MiB.'; return
    fi
    WORKDIR=$(mktemp -d "$DISK_DIR/validacao-io.XXXXXXXX") || { record INCONCLUSIVO 'Stress de escrita' 'Não criou pasta temporária.'; return; }
    record INFO 'Alvo de escrita' "Filesystem $src ($fs), pasta $WORKDIR. Não representa todos os discos selecionados."
    run 'Stress de arquivo por 300s, 1 worker de 256MiB' carga 330 stress-ng --hdd 1 --hdd-bytes 256M --temp-path "$WORKDIR" --verify --oomable --timeout 300s --metrics-brief
    if rmdir -- "$WORKDIR" 2>/dev/null; then WORKDIR=; fi
}
step11() {
    stage 11 'STRESS ADICIONAL'
    if load_allowed 'CPU por 10 minutos'; then run 'CPU por 600s' carga 630 stress-ng --cpu 0 --cpu-method all --verify --oomable --timeout 600s --metrics-brief --tz; fi
    if load_allowed 'RAM por 10 minutos'; then
        if budget_memory; then run "RAM por 600s (${MEM_MB}MiB, 1 worker)" carga 630 stress-ng --vm 1 --vm-bytes "${MEM_MB}M" --verify --oomable --timeout 600s --metrics-brief
        else skip 'RAM por 10 minutos' 'Memória insuficiente.'; fi
    fi
    disk_stress
    run 'Temperatura final' coleta 20 sensors
    run 'Erros novos desde início da validação' journal 45 journalctl -q -p err -b --since "${START_JOURNAL:-$(date '+%Y-%m-%d %H:%M:%S')}" -n 5000 --no-pager
    run 'Serviços com falha ao final' failed_units 30 systemctl --failed --no-legend --no-pager --plain
    failed_details
    local disk
    for disk in "${VALID_DISKS[@]}"; do run "SMART final $disk" smart 90 smartctl -x "$disk"; done
}

main() {
    parse_args "$@"
    if ((INSTALL)); then
        ((EUID == 0)) || die 'Execute a instalação como root.'
        printf 'Instalando dependências. Sem mudança de repositórios; falhas APT exigem revisão.\n'
        apt-get update || die 'apt-get update falhou; revisar repositórios/assinaturas.'
        DEBIAN_FRONTEND=noninteractive apt-get install -y stress-ng memtester lm-sensors smartmontools sysstat ethtool hdparm pciutils dmidecode htop iperf3 iputils-ping iproute2 procps util-linux coreutils less || die 'Instalação falhou.'
        printf 'Instalação concluída. Execute novamente sem --instalar-dependencias para validar.\n'
        return 0
    fi
    prepare
    local n
    for ((n=1;n<=11;n++)); do
        if selected "$n"; then "step$n"
        else STAGE=$n; skip "Etapa $n" 'Não selecionada em --etapas.'; fi
    done
    finish
    trap - EXIT INT TERM HUP
    if awk -F '\t' 'NR>1 && ($2=="FALHA" || $2=="ATENCAO" || $2=="INCONCLUSIVO") {found=1} END {exit !found}' "$REPORT/resultados.tsv"; then return 1; fi
    return 0
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    main "$@"
fi
