#!/usr/bin/env bash
# Instala/atualiza a cópia local; não baixa código nem inicia testes.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077
PREFIX=/usr/local
if [[ ${1:-} == --ajuda || ${1:-} == --help ]]; then
    printf 'Uso como root: bash instalar.sh [--prefix /usr/local]\nInstala o validador e o manual; preserva cópia da versão anterior.\n'
    exit 0
fi
if [[ ${1:-} == --prefix && $# == 2 ]]; then PREFIX=$2
elif (($#)); then printf 'Opção inválida. Use --ajuda.\n' >&2; exit 2; fi
[[ $PREFIX == /* && $PREFIX != / && $PREFIX != *$'\n'* ]] || { printf 'Prefixo absoluto inválido.\n' >&2; exit 2; }
((EUID == 0)) || { printf 'Execute conectado como root.\n' >&2; exit 2; }
SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SOURCE_FILE="$SOURCE_DIR/validar-servidor.sh"
MANUAL="$SOURCE_DIR/MANUAL_USO_VALIDAR_SERVIDOR.txt"
DEST="$PREFIX/sbin/validar-servidor"
DOC_DIR="$PREFIX/share/doc/validar-servidor"
BACKUP_DIR="$PREFIX/share/validar-servidor/backups"
[[ -f $SOURCE_FILE && -f $MANUAL && -f $SOURCE_DIR/diagnostico.py ]] || { printf 'Mantenha instalar.sh, validar-servidor.sh, diagnostico.py e o manual na mesma pasta.\n' >&2; exit 2; }
bash -n "$SOURCE_FILE"
mkdir -p -- "$PREFIX/sbin" "$DOC_DIR" "$BACKUP_DIR"
[[ ! -L $DEST && ! -d $DEST ]] || { printf 'Destino é link/diretório; revise antes de instalar.\n' >&2; exit 2; }
backup=
if [[ -f $DEST ]]; then
    backup=$(mktemp "$BACKUP_DIR/validar-servidor-$(date +%Y%m%d-%H%M%S)-XXXXXX.sh")
    cp -p -- "$DEST" "$backup"
fi
staged=$(mktemp "$PREFIX/sbin/.validar-servidor.XXXXXX")
cleanup() { [[ ! -f ${staged:-} ]] || rm -f -- "$staged"; }
trap cleanup EXIT
install -m 0640 -- "$SOURCE_DIR/diagnostico.py" "$PREFIX/share/validar-servidor/diagnostico-1.3.0.py"
install -m 0750 -- "$SOURCE_FILE" "$staged"
install -m 0640 -- "$MANUAL" "$DOC_DIR/MANUAL_USO_VALIDAR_SERVIDOR.txt"
mv -f -- "$staged" "$DEST"
printf 'Instalado: %s\nManual: %s/MANUAL_USO_VALIDAR_SERVIDOR.txt\n' "$DEST" "$DOC_DIR"
[[ -z $backup ]] || printf 'Versão anterior: %s\n' "$backup"
"$DEST" --versao
printf 'Próximo passo: %s --instalar-dependencias\n' "$DEST"
printf 'Consulta: %s --modo consulta --disco /dev/sda\n' "$DEST"
