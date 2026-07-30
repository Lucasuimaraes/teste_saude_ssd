#!/usr/bin/env bash
# Versão 1.1.0 — busca atributos por ID e por nome/alias como fallback.
# Compatível com Debian/Ubuntu e CentOS/RHEL.
#
# Uso:
#   sudo ./teste_saude_disco.sh [DISPOSITIVO] [report|short|long|full]
#
# Exemplos:
#   sudo ./teste_saude_disco.sh /dev/sda report
#   sudo ./teste_saude_disco.sh /dev/sda short
#   sudo ./teste_saude_disco.sh /dev/sda long
#   sudo ./teste_saude_disco.sh /dev/sda full
#
# Variáveis opcionais:
#   LOG_DIR=/var/log/saude-disco
#   POLL_INTERVAL=30
#   SMART_DEVICE_TYPE=sat       # útil para alguns adaptadores USB/SATA

set -uo pipefail

SCRIPT_VERSION="1.1.0"
PROGRAM_NAME="$(basename "$0")"
LOG_DIR="${LOG_DIR:-/var/log/saude-disco}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
SMART_DEVICE_TYPE="${SMART_DEVICE_TYPE:-}"

if [[ -t 1 ]]; then
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[1;33m'
    C_BLUE='\033[0;34m'
    C_BOLD='\033[1m'
    C_RESET='\033[0m'
else
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_BOLD=''
    C_RESET=''
fi

WARNINGS=0
CRITICALS=0
SUMMARY_MESSAGES=""
SMART_ARGS=()

usage() {
    cat <<USAGE
Uso:
  sudo $PROGRAM_NAME [DISPOSITIVO] [AÇÃO]

DISPOSITIVO:
  Disco inteiro, por exemplo /dev/sda. Não use uma partição como /dev/sda1.
  Se não informado, o script tenta detectar o disco que contém o sistema raiz (/).

AÇÕES:
  report   Apenas coleta e analisa o SMART. É a ação padrão.
  short    Executa o autoteste curto e aguarda a conclusão.
  long     Executa o autoteste estendido/completo e aguarda a conclusão.
  full     Coleta inicial, executa teste curto, teste longo e coleta final.

Exemplos:
  sudo $PROGRAM_NAME /dev/sda report
  sudo $PROGRAM_NAME /dev/sda full

Observação:
  Os testes SMART são somente leitura e não desmontam o disco. O teste longo
  pode reduzir temporariamente o desempenho do servidor.
USAGE
}

print_header() {
    printf '\n%b============================================================%b\n' "$C_BLUE" "$C_RESET"
    printf '%b%s%b\n' "$C_BOLD" "$1" "$C_RESET"
    printf '%b============================================================%b\n' "$C_BLUE" "$C_RESET"
}

## LOG INFO
info() {
    printf '%b[INFO]%b %s\n' "$C_BLUE" "$C_RESET" "$*"
}

## LOG OK
ok() {
    printf '%b[OK]%b %s\n' "$C_GREEN" "$C_RESET" "$*"
}

## LOG WARN
warn() {
    printf '%b[ATENÇÃO]%b %s\n' "$C_YELLOW" "$C_RESET" "$*"
}

## LOG WARN
error() {
    printf '%b[ERRO]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2
}

## ADD LOG WARNING
add_warning() {
    WARNINGS=$((WARNINGS + 1))
    SUMMARY_MESSAGES="${SUMMARY_MESSAGES}\nATENÇÃO: $*"
}

## Add LOG CRITICO
add_critical() {
    CRITICALS=$((CRITICALS + 1))
    SUMMARY_MESSAGES="${SUMMARY_MESSAGES}\nCRÍTICO: $*"
}

## Caso rode como usuário comum
require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        error "Execute como root: sudo $PROGRAM_NAME ..."
        exit 1
    fi
}

## Instala lib caso não tenha instalado
install_smartmontools() {
    if command -v smartctl >/dev/null 2>&1; then
        return 0
    fi

    warn "smartctl não encontrado. Tentando instalar smartmontools."

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y smartmontools
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y smartmontools
    elif command -v yum >/dev/null 2>&1; then
        yum install -y smartmontools
    else
        error "Gerenciador de pacotes não reconhecido. Instale smartmontools manualmente."
        exit 1
    fi

    if ! command -v smartctl >/dev/null 2>&1; then
        error "Não foi possível instalar ou localizar o smartctl."
        exit 1
    fi
}

## Detecta automaticamente o disco root no sistema de arquivos
detect_root_disk() {
    local source=""
    local disk=""

    if command -v findmnt >/dev/null 2>&1; then
        source="$(findmnt -n -o SOURCE / 2>/dev/null | head -n1 || true)"
    fi

    if [[ -z "$source" ]]; then
        source="$(df -P / 2>/dev/null | awk 'NR==2 {print $1}' || true)"
    fi

    if [[ "$source" == /dev/* ]] && command -v lsblk >/dev/null 2>&1; then
        disk="$(lsblk -sno NAME,TYPE "$source" 2>/dev/null | awk '$2 == "disk" {print "/dev/" $1; exit}' || true)"
    fi

    if [[ -z "$disk" && "$source" =~ ^/dev/[a-zA-Z]+[0-9]+$ ]]; then
        disk="$(printf '%s' "$source" | sed -E 's/[0-9]+$//')"
    fi

    if [[ -z "$disk" ]]; then
        error "Não consegui detectar automaticamente o disco raiz. Informe-o, por exemplo: /dev/sda"
        exit 1
    fi

    disk=$(printf '%s' "$disk" | sed 's/└─//g')

    printf '%s\n' "$disk"
}

## Trata oo device enviado pelo usuário
normalize_device() {
    local requested="$1"
    local type=""
    local parent=""

    if [[ ! -b "$requested" ]]; then
        error "$requested não é um dispositivo de bloco válido."
        exit 1
    fi

    if command -v lsblk >/dev/null 2>&1; then
        type="$(lsblk -ndo TYPE "$requested" 2>/dev/null | head -n1 || true)"
        if [[ "$type" == "part" ]]; then
            parent="$(lsblk -ndo PKNAME "$requested" 2>/dev/null | head -n1 || true)"
            if [[ -n "$parent" ]]; then
                warn "$requested é uma partição. Usando o disco inteiro /dev/$parent."
                requested="/dev/$parent"
            fi
        fi
    fi

    requested=$(printf '%s' "$requested" | sed 's/└─//g')

    printf '%s\n' "$requested"
}

## Organiza SMART 
prepare_smart_args() {
    if [[ -n "$SMART_DEVICE_TYPE" ]]; then
        SMART_ARGS=(-d "$SMART_DEVICE_TYPE")
    fi
}

## ENVIA PARA ARQUIVO DE LOG
smartctl_run() {
    # Bash antigo com `set -u` pode tratar uma matriz vazia como nao definida.
    # So expandimos SMART_ARGS quando ela existe e possui argumentos.
    if [[ -n "${SMART_ARGS[*]-}" ]]; then
        smartctl "${SMART_ARGS[@]}" "$@"
        return $?
    fi

    smartctl "$@"
}

smartctl_capture() {
    local output_file="$1"
    shift
    smartctl_run "$@" "$DEVICE" >"$output_file" 2>&1
    return $?
}

## RETORNA TEXTO
smartctl_text() {
    smartctl_run "$@" "$DEVICE" 2>&1
    return $?
}

## CONVERTE OS ERROS
decode_smartctl_exit() {
    local rc="$1"

    (( rc & 1 ))   && warn "smartctl encontrou erro de linha de comando."
    (( rc & 2 ))   && warn "O dispositivo não abriu corretamente ou houve falha de identificação."
    (( rc & 4 ))   && warn "Algum comando SMART falhou ou não é suportado."
    (( rc & 8 ))   && add_critical "O SMART informa que o disco está em estado de falha iminente."
    (( rc & 16 ))  && add_critical "Há atributo SMART do tipo Pre-fail no limite ou abaixo dele."
    (( rc & 32 ))  && add_warning "Um atributo SMART ficou abaixo do limite em algum momento no passado."
    (( rc & 64 ))  && add_warning "O log de erros do dispositivo contém registros."
    (( rc & 128 )) && add_warning "O histórico de autotestes contém erro atual ou recente."
}

## VALOR DO CAMPO
field_value() {
    local field="$1"
    sed -n "s/^${field}:[[:space:]]*//p" "$SMART_REPORT" | head -n1
}

# Localiza uma linha de atributo SMART sem depender da ordem da tabela.
# Primeiro procura pelo ID numérico (mais estável); caso não encontre, tenta
# cada nome/alias informado na segunda coluna ATTRIBUTE_NAME.
attr_line() {
    local id="${1:-}"
    shift || true

    local line=""
    local attribute_name=""

    # O nome confirma a semantica do atributo. O ID fica como fallback,
    # porque alguns fabricantes reutilizam o mesmo ID para finalidades diferentes.
    for attribute_name in "$@"; do
        line="$(awk -v wanted_name="$attribute_name" '
            $2 == wanted_name {print; exit}
        ' "$SMART_REPORT")"
        [[ -n "$line" ]] && break
    done

    if [[ -z "$line" ]] && [[ "$id" =~ ^[0-9]+$ ]] && (( id > 0 )); then
        line="$(awk -v wanted="$id" '
            $1 ~ /^[0-9]+$/ && ($1 + 0) == (wanted + 0) {print; exit}
        ' "$SMART_REPORT")"
    fi

    [[ -n "$line" ]] && printf '%s\n' "$line"
}

attr_line_by_name() {
    local attribute_name line

    for attribute_name in "$@"; do
        line="$(awk -v wanted_name="$attribute_name" '
            $2 == wanted_name {print; exit}
        ' "$SMART_REPORT")"
        if [[ -n "$line" ]]; then
            printf '%s\n' "$line"
            return 0
        fi
    done
}

## ATT DO VALOR
attr_value() {
    local id="${1:-}"
    shift || true

    local line
    line="$(attr_line "$id" "$@")"
    [[ -n "$line" ]] && awk '{print $4}' <<<"$line"
}

## ATT QNT DE LINHAS
attr_raw_number() {
    local id="${1:-}"
    shift || true

    local line
    line="$(attr_line "$id" "$@")"
    [[ -n "$line" ]] && awk '{print $10}' <<<"$line" | grep -oE '^[0-9]+' || true
}


attr_raw_full() {
    local id="${1:-}"
    shift || true

    local line
    line="$(attr_line "$id" "$@")"
    if [[ -n "$line" ]]; then
        awk '{for (i=10; i<=NF; i++) printf "%s%s", $i, (i<NF ? OFS : ORS)}' <<<"$line"
    fi
}

# CONVERT PARA INT
to_integer() {
    awk -v value="${1:-0}" 'BEGIN {printf "%d", value + 0}'
}

# CONVERT PARA HORAS HUMANAS DISCO LIGADO
human_power_hours() {
    local hours="${1:-0}"
    awk -v h="$hours" 'BEGIN {
        years = int(h / 8760)
        days = int((h % 8760) / 24)
        rem = h % 24
        if (years > 0) printf "%d ano(s), %d dia(s) e %d hora(s)", years, days, rem
        else printf "%d dia(s) e %d hora(s)", days, rem
    }'
}

# CONVERT PARA TAMANHO HUMANO
human_written() {
    local lbas="${1:-0}"
    local sector_size="${2:-512}"
    awk -v l="$lbas" -v s="$sector_size" 'BEGIN {
        bytes = l * s
        printf "%.2f TB (%.2f TiB)", bytes / 1000000000000, bytes / 1099511627776
    }'
}

# CONVERTE CONTADORES DO FABRICANTE EXPRESSOS EM BLOCOS DE 32 MIB
human_written_mib() {
    local blocks="${1:-0}"
    awk -v b="$blocks" 'BEGIN {
        bytes = b * 33554432
        printf "%.2f TB (%.2f TiB)", bytes / 1000000000000, bytes / 1099511627776
    }'
}

# PRINTA ATTRS DO DISCO
print_attr() {
    local id="$1"
    local label="$2"
    local normalized raw

    shift 2
    normalized="$(attr_value "$id" "$@")"
    raw="$(attr_raw_full "$id" "$@")"

    if [[ -n "$normalized" || -n "$raw" ]]; then
        printf '  %-31s valor=%-4s bruto=%s\n' "$label (ID $id):" "${normalized:--}" "${raw:--}"
    fi
}

print_attr_by_name() {
    local label="$1"
    shift
    local line normalized raw id

    line="$(attr_line_by_name "$@")"
    [[ -n "$line" ]] || return 0
    id="$(awk '{print $1}' <<<"$line")"
    normalized="$(awk '{print $4}' <<<"$line")"
    raw="$(awk '{for (i=10; i<=NF; i++) printf "%s%s", $i, (i<NF ? OFS : ORS)}' <<<"$line")"
    printf '  %-31s valor=%-4s bruto=%s\n' "$label (ID $id):" "${normalized:--}" "${raw:--}"
}

# CRIA O REPORT DA PASTA DE LOGS
collect_report() {
    local suffix="$1"
    local rc=0

    SMART_REPORT="$RUN_DIR/smart-${suffix}.txt"
    smartctl_capture "$SMART_REPORT" -x
    rc=$?
    decode_smartctl_exit "$rc"

    cp -f "$SMART_REPORT" "$RUN_DIR/smart-ultimo.txt"
    return 0
}

# CRIA O REPORTA DE IDENTIFICAÇÃO DO DISCO
show_identification() {
    local model_family device_model serial firmware capacity sector rotation form_factor trim ata sata

    model_family="$(field_value 'Model Family')"
    device_model="$(field_value 'Device Model')"
    serial="$(field_value 'Serial Number')"
    firmware="$(field_value 'Firmware Version')"
    capacity="$(field_value 'User Capacity')"
    sector="$(field_value 'Sector Size')"
    rotation="$(field_value 'Rotation Rate')"
    form_factor="$(field_value 'Form Factor')"
    trim="$(field_value 'TRIM Command')"
    ata="$(field_value 'ATA Version is')"
    sata="$(field_value 'SATA Version is')"

    print_header "IDENTIFICAÇÃO DO DISCO"
    printf '  Dispositivo:                  %s\n' "$DEVICE"
    printf '  Família:                      %s\n' "${model_family:--}"
    printf '  Modelo:                       %s\n' "${device_model:--}"
    printf '  Número de série:              %s\n' "${serial:--}"
    printf '  Firmware:                     %s\n' "${firmware:--}"
    printf '  Capacidade:                   %s\n' "${capacity:--}"
    printf '  Setor lógico/físico:          %s\n' "${sector:--}"
    printf '  Tipo:                         %s\n' "${rotation:--}"
    printf '  Formato:                      %s\n' "${form_factor:--}"
    printf '  TRIM:                         %s\n' "${trim:--}"
    printf '  ATA:                          %s\n' "${ata:--}"
    printf '  SATA:                         %s\n' "${sata:--}"
}

# CRIA O REPORTA DE STATUS E ATT DO DISCO
show_health_and_attributes() {
    local health smart_available smart_enabled
    local reallocated program_fail erase_fail reported pending offline crc temp
    local power_hours power_cycles unexpected_loss life_remaining life_used
    local avg_erase reserve lbas sector_size latest_test
    local raw_reallocated raw_program_fail raw_erase_fail raw_reported raw_pending
    local raw_offline raw_crc raw_temp raw_power_hours raw_power_cycles
    local raw_unexpected_loss raw_avg_erase raw_reserve raw_lbas
    local life_line life_name life_raw host_writes host_reads

    health="$(grep -Ei 'SMART overall-health self-assessment test result:|SMART Health Status:' "$SMART_REPORT" | head -n1 | sed -E 's/^[^:]+:[[:space:]]*//' || true)"
    smart_available="$(grep -F 'SMART support is: Available' "$SMART_REPORT" | head -n1 || true)"
    smart_enabled="$(grep -F 'SMART support is: Enabled' "$SMART_REPORT" | head -n1 || true)"

    print_header "SAÚDE GERAL"
    printf '  SMART disponível:             %s\n' "$([[ -n "$smart_available" ]] && echo SIM || echo NÃO/INDETERMINADO)"
    printf '  SMART habilitado:             %s\n' "$([[ -n "$smart_enabled" ]] && echo SIM || echo NÃO/INDETERMINADO)"
    printf '  Resultado geral:              %s\n' "${health:--}"

    if [[ "$health" =~ PASSED|OK ]]; then
        ok "Avaliação geral SMART aprovada."
    elif [[ -n "$health" ]]; then
        add_critical "Avaliação geral SMART não foi aprovada: $health"
    else
        add_warning "Não foi possível identificar o resultado geral do SMART."
    fi

    # Os nomes confirmam a semantica; o ID e usado como fallback.
    # Assim, mudancas na ordem da tabela nao alteram o resultado e IDs
    # reutilizados por fabricantes diferentes nao recebem rotulos incorretos.
    raw_reallocated="$(attr_raw_number 5 Reallocate_NAND_Blk_Cnt Reallocated_Sector_Ct)"
    raw_program_fail="$(attr_raw_number 171 Program_Fail_Count Program_Fail_Cnt_Total)"
    raw_erase_fail="$(attr_raw_number 172 Erase_Fail_Count Erase_Fail_Count_Total)"
    raw_reported="$(attr_raw_number 187 Reported_Uncorrect Reported_Uncorrectable_Errors)"
    raw_pending="$(attr_raw_number 197 Current_Pending_ECC_Cnt Current_Pending_Sector)"
    raw_offline="$(attr_raw_number 198 Offline_Uncorrectable)"
    raw_crc="$(attr_raw_number 199 UDMA_CRC_Error_Count)"
    raw_temp="$(attr_raw_number 194 Temperature_Celsius)"
    raw_power_hours="$(attr_raw_number 9 Power_On_Hours)"
    raw_power_cycles="$(attr_raw_number 12 Power_Cycle_Count)"
    raw_unexpected_loss="$(attr_raw_number 174 Unexpect_Power_Loss_Ct Unexpected_Power_Loss_Ct)"
    raw_avg_erase="$(attr_raw_number 173 Ave_Block-Erase_Count Average_Block_Erase_Count)"
    raw_reserve="$(attr_raw_number 180 Unused_Reserve_NAND_Blk Unused_Reserve_NAND_Blocks Unused_Rsvd_Blk_Cnt_Tot)"
    raw_lbas="$(attr_raw_number 246 Total_LBAs_Written)"

    reallocated="$(to_integer "$raw_reallocated")"
    program_fail="$(to_integer "$raw_program_fail")"
    erase_fail="$(to_integer "$raw_erase_fail")"
    reported="$(to_integer "$raw_reported")"
    pending="$(to_integer "$raw_pending")"
    offline="$(to_integer "$raw_offline")"
    crc="$(to_integer "$raw_crc")"
    temp="$(to_integer "$raw_temp")"
    power_hours="$(to_integer "$raw_power_hours")"
    power_cycles="$(to_integer "$raw_power_cycles")"
    unexpected_loss="$(to_integer "$raw_unexpected_loss")"
    avg_erase="$(to_integer "$raw_avg_erase")"
    reserve="$(to_integer "$raw_reserve")"
    lbas="$raw_lbas"
    life_line="$(attr_line_by_name Percent_Lifetime_Remain Remaining_Lifetime_Perc SSD_Life_Left)"
    life_name="$(awk '{print $2}' <<<"$life_line")"
    life_remaining="$(awk '{print $4}' <<<"$life_line" | grep -oE '^[0-9]+' || true)"
    [[ -n "$life_remaining" ]] && life_remaining="$(to_integer "$life_remaining")"
    life_raw="$(awk '{print $10}' <<<"$life_line" | grep -oE '^[0-9]+' || true)"
    life_used=""
    [[ "$life_name" == "Percent_Lifetime_Remain" ]] && life_used="$life_raw"
    host_writes="$(attr_raw_number 241 Host_Writes_32MiB)"
    host_reads="$(attr_raw_number 242 Host_Reads_32MiB)"
    sector_size="$(grep -E '^Sector Size:' "$SMART_REPORT" | grep -oE '[0-9]+ bytes logical' | grep -oE '^[0-9]+' | head -n1 || true)"
    sector_size="${sector_size:-512}"

    print_header "PRINCIPAIS INDICADORES DO SSD"
    [[ -n "$raw_power_hours" ]] && printf '  Horas ligado:                 %s h (%s)\n' "$power_hours" "$(human_power_hours "$power_hours")"
    [[ -n "$raw_power_cycles" ]] && printf '  Ciclos de energia:            %s\n' "$power_cycles"
    [[ -n "$raw_unexpected_loss" ]] && printf '  Perdas inesperadas de energia:%s\n' " $unexpected_loss"
    [[ -n "$raw_temp" ]] && printf '  Temperatura atual:            %s °C\n' "$temp"
    [[ -n "$life_remaining" ]] && printf '  Vida útil restante:           %s %%\n' "$life_remaining"
    [[ -n "$life_used" ]] && printf '  Desgaste informado (RAW):     %s %%\n' "$life_used"
    [[ -n "$raw_avg_erase" ]] && printf '  Média de apagamentos/bloco:   %s\n' "$avg_erase"
    [[ -n "$raw_reserve" ]] && printf '  Blocos NAND de reserva:       %s\n' "$reserve"
    [[ -n "$lbas" ]] && printf '  Total gravado:                %s\n' "$(human_written "$lbas" "$sector_size")"
    [[ -n "$host_writes" ]] && printf '  Escrita do host:              %s\n' "$(human_written_mib "$host_writes")"
    [[ -n "$host_reads" ]] && printf '  Leitura do host:              %s\n' "$(human_written_mib "$host_reads")"
    [[ -n "$raw_reallocated" ]] && printf '  Blocos NAND realocados:       %s\n' "$reallocated"
    [[ -n "$raw_program_fail" ]] && printf '  Falhas de programação:        %s\n' "$program_fail"
    [[ -n "$raw_erase_fail" ]] && printf '  Falhas de apagamento:         %s\n' "$erase_fail"
    [[ -n "$raw_reported" ]] && printf '  Erros não corrigíveis:        %s\n' "$reported"
    [[ -n "$raw_pending" ]] && printf '  Setores/ECC pendentes:        %s\n' "$pending"
    [[ -n "$raw_offline" ]] && printf '  Offline não corrigível:       %s\n' "$offline"
    [[ -n "$raw_crc" ]] && printf '  Erros CRC SATA:               %s\n' "$crc"

    (( reallocated > 0 )) && add_warning "$reallocated bloco(s) NAND realocado(s). Verifique se o valor está aumentando."
    (( program_fail > 0 )) && add_critical "$program_fail falha(s) de programação NAND."
    (( erase_fail > 0 )) && add_critical "$erase_fail falha(s) de apagamento NAND."
    (( reported > 0 )) && add_critical "$reported erro(s) não corrigível(is) reportado(s)."
    (( pending > 0 )) && add_critical "$pending setor(es)/ECC pendente(s)."
    (( offline > 0 )) && add_critical "$offline erro(s) offline não corrigível(is)."
    (( crc > 0 )) && add_warning "$crc erro(s) CRC SATA. Verifique cabo, conector e controladora."
    (( temp >= 70 )) && add_critical "Temperatura muito alta: ${temp} °C."
    (( temp >= 60 && temp < 70 )) && add_warning "Temperatura elevada: ${temp} °C."
    (( life_remaining > 0 && life_remaining <= 10 )) && add_critical "Vida útil restante muito baixa: ${life_remaining}%."
    (( life_remaining > 10 && life_remaining <= 20 )) && add_warning "Vida útil restante baixa: ${life_remaining}%."

    print_header "TABELA SMART PRINCIPAL"
    print_attr 1   "Taxa de erro de leitura" Raw_Read_Error_Rate
    print_attr 5   "Blocos NAND realocados" Reallocate_NAND_Blk_Cnt Reallocated_Sector_Ct
    print_attr 9   "Horas ligado" Power_On_Hours
    print_attr 12  "Ciclos de energia" Power_Cycle_Count
    print_attr 171 "Falhas de programação" Program_Fail_Count Program_Fail_Cnt_Total
    print_attr 172 "Falhas de apagamento" Erase_Fail_Count Erase_Fail_Count_Total
    print_attr 173 "Média de apagamentos" Ave_Block-Erase_Count Average_Block_Erase_Count
    print_attr 174 "Perdas inesperadas energia" Unexpect_Power_Loss_Ct Unexpected_Power_Loss_Ct
    print_attr 180 "NAND de reserva" Unused_Reserve_NAND_Blk Unused_Reserve_NAND_Blocks
    print_attr 183 "Redução de velocidade SATA" SATA_Interfac_Downshift
    print_attr 184 "Correções de erro" Error_Correction_Count
    print_attr 187 "Erros não corrigíveis" Reported_Uncorrect Reported_Uncorrectable_Errors
    print_attr 194 "Temperatura" Temperature_Celsius
    print_attr 196 "Eventos de realocação" Reallocated_Event_Count
    print_attr 197 "ECC/setores pendentes" Current_Pending_ECC_Cnt Current_Pending_Sector
    print_attr 198 "Offline não corrigível" Offline_Uncorrectable
    print_attr 199 "Erros CRC SATA" UDMA_CRC_Error_Count
    print_attr_by_name "Vida útil restante" Percent_Lifetime_Remain Remaining_Lifetime_Perc SSD_Life_Left
    print_attr 206 "Taxa de erro de escrita" Write_Error_Rate
    print_attr 246 "LBAs gravados" Total_LBAs_Written
    print_attr 247 "Páginas programadas host" Host_Program_Page_Count
    print_attr 248 "Páginas programadas FTL" FTL_Program_Page_Count
    print_attr 250 "Tentativas de leitura" Read_Error_Retry_Rate

    print_header "ÚLTIMO AUTOTESTE REGISTRADO"
    latest_test="$(awk '/^# 1[[:space:]]/ {print; exit}' "$SMART_REPORT" || true)"
    if [[ -n "$latest_test" ]]; then
        printf '  %s\n' "$latest_test"
        if grep -Eqi 'Completed without error|Completed:.*without error' <<<"$latest_test"; then
            ok "Último autoteste concluído sem erro."
        elif grep -Eqi 'in progress' <<<"$latest_test"; then
            info "Há um autoteste em andamento."
        else
            add_warning "O último autoteste merece verificação: $latest_test"
        fi
    else
        info "Nenhum autoteste registrado ou log não disponível."
    fi
}

# CRIA O REPORTA DE ERRO NO KERNEL DE ERROS DO DISCO
show_kernel_errors() {
    local device_name
    local kernel_file="$RUN_DIR/erros-kernel.txt"

    device_name="$(basename "$DEVICE")"

    {
        if command -v journalctl >/dev/null 2>&1; then
            journalctl -k --no-pager 2>/dev/null || true
        else
            dmesg 2>/dev/null || true
        fi
    } | grep -Ei "I/O error|Buffer I/O|medium error|uncorrect|EXT[234]-fs error|XFS.*error|${device_name}.*error|ata[0-9]+.*(error|failed)" \
      | tail -n 200 >"$kernel_file" || true

    print_header "ERROS DE DISCO NO KERNEL"
    if [[ -s "$kernel_file" ]]; then
        warn "Foram encontradas mensagens relacionadas a I/O, disco ou sistema de arquivos:"
        tail -n 20 "$kernel_file"
        add_warning "Há mensagens de erro no kernel. Consulte $kernel_file."
    else
        ok "Nenhum erro relevante de disco encontrado no log atual do kernel."
    fi
}

# PRINTA MONTAGEM DO DISCO
show_mount_status() {
    print_header "MONTAGENS RELACIONADAS"
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,RO,MODEL,SERIAL "$DEVICE" 2>/dev/null || true
    fi

    if command -v findmnt >/dev/null 2>&1; then
        printf '\nSistema raiz:\n'
        findmnt -no SOURCE,FSTYPE,OPTIONS / 2>/dev/null || true
    fi
}

self_test_in_progress() {
    local output="$1"
    grep -Eqi 'Self-test routine in progress|Self-test execution status:.*in progress' <<<"$output"
}

wait_for_self_test() {
    local test_type="$1"
    local max_seconds="$2"
    local elapsed=0
    local status=""
    local progress=""

    info "Acompanhando o teste $test_type. Intervalo de consulta: ${POLL_INTERVAL}s."

    while (( elapsed < max_seconds )); do
        status="$(smartctl_text -c || true)"

        if ! self_test_in_progress "$status"; then
            printf '\n'
            ok "O teste $test_type não está mais em execução."
            return 0
        fi

        progress="$(grep -Eio '[0-9]+% of test remaining|[0-9]+% remaining' <<<"$status" | head -n1 || true)"
        printf '\r[AGUARDANDO] teste %-8s | %-25s | decorrido: %02d:%02d:%02d' \
            "$test_type" "${progress:-em andamento}" \
            $((elapsed / 3600)) $(((elapsed % 3600) / 60)) $((elapsed % 60))

        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done

    printf '\n'
    add_warning "Tempo máximo de espera atingido para o teste $test_type. O teste pode continuar no disco."
    return 1
}

run_self_test() {
    local test_type="$1"
    local max_seconds="$2"
    local start_output=""
    local rc=0
    local test_log="$RUN_DIR/inicio-teste-${test_type}.txt"

    print_header "INICIANDO AUTOTESTE SMART: ${test_type^^}"

    start_output="$(smartctl_text -t "$test_type")"
    rc=$?
    printf '%s\n' "$start_output" | tee "$test_log"
    decode_smartctl_exit "$rc"

    if grep -Eqi 'test has begun|Please wait|Self-test routine in progress' <<<"$start_output"; then
        ok "Teste $test_type iniciado."
    else
        add_critical "Não foi possível confirmar o início do teste $test_type."
        return 1
    fi

    wait_for_self_test "$test_type" "$max_seconds" || true

    print_header "RESULTADO DO AUTOTESTE: ${test_type^^}"
    smartctl_text -l selftest | tee "$RUN_DIR/resultado-teste-${test_type}.txt" || true

    local latest
    latest="$(smartctl_text -l selftest | awk '/^# 1[[:space:]]/ {print; exit}' || true)"

    if [[ -z "$latest" ]]; then
        add_warning "Não foi possível localizar o resultado do teste $test_type no histórico."
    elif grep -Eqi 'Completed without error|Completed:.*without error' <<<"$latest"; then
        ok "Teste $test_type concluído sem erros."
    elif grep -Eqi 'in progress' <<<"$latest"; then
        add_warning "O teste $test_type ainda aparece como em andamento."
    else
        add_critical "O teste $test_type não terminou normalmente: $latest"
    fi
}

## CRIA ARQUIVO FINAL DO RELATORIO
write_summary_file() {
    local summary_file="$RUN_DIR/resumo.txt"
    {
        echo "Teste de saúde do disco"
        echo "Data: $(date '+%Y-%m-%d %H:%M:%S %z')"
        echo "Dispositivo: $DEVICE"
        echo "Ação: $ACTION"
        echo "Avisos: $WARNINGS"
        echo "Críticos: $CRITICALS"
        printf '%b\n' "$SUMMARY_MESSAGES"
        echo
        echo "Relatório SMART bruto: $RUN_DIR/smart-ultimo.txt"
    } >"$summary_file"
}

## PPRINTA RESULTADO FINAL
show_final_summary() {
    print_header "RESULTADO FINAL"

    if (( CRITICALS > 0 )); then
        printf '%bSTATUS: CRÍTICO%b\n' "$C_RED" "$C_RESET"
        printf 'Foram encontrados %d problema(s) crítico(s) e %d aviso(s).\n' "$CRITICALS" "$WARNINGS"
        printf '%b\n' "$SUMMARY_MESSAGES"
        printf '\nRecomendação: faça backup imediato e planeje a substituição/investigação do disco.\n'
        FINAL_RC=2
    elif (( WARNINGS > 0 )); then
        printf '%bSTATUS: ATENÇÃO%b\n' "$C_YELLOW" "$C_RESET"
        printf 'Foram encontrados %d aviso(s).\n' "$WARNINGS"
        printf '%b\n' "$SUMMARY_MESSAGES"
        printf '\nRecomendação: acompanhe a evolução dos atributos e mantenha backup atualizado.\n'
        FINAL_RC=1
    else
        printf '%bSTATUS: SAUDÁVEL%b\n' "$C_GREEN" "$C_RESET"
        printf 'Nenhum indicador crítico foi encontrado.\n'
        FINAL_RC=0
    fi

    printf '\nRelatórios salvos em: %s\n' "$RUN_DIR"
}

# MAIN
main() {
    local requested_device="${1:-}"

    if [[ "$requested_device" == "-h" || "$requested_device" == "--help" ]]; then
        usage
        exit 0
    fi

    require_root
    install_smartmontools
    prepare_smart_args

    if [[ -z "$requested_device" || "$requested_device" =~ ^(report|short|long|full)$ ]]; then
        if [[ "$requested_device" =~ ^(report|short|long|full)$ ]]; then
            ACTION="$requested_device"
        else
            ACTION="${2:-report}"
        fi
        DEVICE="$(detect_root_disk)"
        info "DEVICE": $DEVICE
    else
        DEVICE="$(normalize_device "$requested_device")"
        info "DEVICE 2": $DEVICE
        ACTION="${2:-report}"
    fi

    case "$ACTION" in
        report|short|long|full) ;;
        *)
            error "Ação inválida: $ACTION"
            usage
            exit 1
            ;;
    esac

    if ! [[ "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || (( POLL_INTERVAL < 5 )); then
        error "POLL_INTERVAL deve ser um número inteiro maior ou igual a 5."
        exit 1
    fi

    local timestamp
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    RUN_DIR="$LOG_DIR/$(basename "$DEVICE")-$timestamp"
    mkdir -p "$RUN_DIR"

    exec > >(tee -a "$RUN_DIR/execucao.log") 2>&1

    print_header "TESTE DE SAÚDE DO DISCO — VERSÃO $SCRIPT_VERSION"
    info "Data: $(date '+%Y-%m-%d %H:%M:%S %z')"
    info "Dispositivo: $DEVICE"
    info "Ação: $ACTION"
    info "Diretório de relatório: $RUN_DIR"

    collect_report "inicial"
    show_identification
    show_mount_status
    show_health_and_attributes
    show_kernel_errors

    case "$ACTION" in
        report)
            ;;
        short)
            run_self_test short 1800
            collect_report "apos-short"
            ;;
        long)
            run_self_test long 43200
            collect_report "apos-long"
            ;;
        full)
            run_self_test short 1800
            collect_report "apos-short"
            run_self_test long 43200
            collect_report "final"
            print_header "RELATÓRIO FINAL COLETADO"
            info "O relatório SMART final foi salvo em $SMART_REPORT."
            ;;
    esac

    write_summary_file
    show_final_summary
    exit "$FINAL_RC"
}

main "$@"
