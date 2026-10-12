#!/bin/bash
# Пробный дамп без остановки ELMA: теми же pg_dump / mongodump / mcc и с теми же
# ключами, что elma365-backupper 1.0.18, но без scale_0/scale_1. Только чтение баз.
# Меряет время каждой части и ловит ошибки, из-за которых ночной бэкап не прошёл бы.
#
#   elma-backupper-probe.sh dev|prod [pg] [mongo] [s3] [-k]
#   без списка частей — все три; -k — не удалять пробную копию
set -u
umask 077

ENV=${1:-}; shift || true
case "$ENV" in
    dev)  NS=elma365 ;;
    prod) NS=mscelma365 ;;
    *) echo "usage: $0 dev|prod [pg] [mongo] [s3] [-k]" >&2; exit 2 ;;
esac
KEEP=0; PARTS=()
for a in "$@"; do
    case "$a" in
        pg|mongo|s3) PARTS+=("$a") ;;
        -k) KEEP=1 ;;
        *) echo "неизвестный аргумент: $a" >&2; exit 2 ;;
    esac
done
[ ${#PARTS[@]} -eq 0 ] && PARTS=(pg mongo s3)

B=${PROBE_BIN:-/opt/elma365/backupper/bin}
export KUBECONFIG=/etc/kubernetes/admin.conf
BASE=${PROBE_BASE:-/var/storage/backup/$ENV/tmp}
OUT=$BASE/probe-$(date +%Y%m%d-%H%M%S)
ALIAS=probe$$
MIN_FREE_GB=15; [ "$ENV" = prod ] && MIN_FREE_GB=60

[ "$(id -u)" = 0 ] || { echo "запускать от root (sudo -i)" >&2; exit 1; }
for x in kubectl pg_dump mongodump mcc; do [ -x "$B/$x" ] || { echo "нет $B/$x" >&2; exit 1; }; done
command -v jq >/dev/null || { echo "нет jq" >&2; exit 1; }

# не пересекаться с ночным бэкапом
exec 9>"${PROBE_LOCK:-/run/elma-backupper.lock}"
flock -n 9 || { echo "идёт бэкап (занят /run/elma-backupper.lock), пробу не запускаю" >&2; exit 1; }

free=$(df -P -BG "$BASE" | awk 'NR==2{gsub("G","",$4); print $4}')
[ "${free:-0}" -ge "$MIN_FREE_GB" ] || { echo "на $BASE свободно ${free} ГБ, нужно не меньше $MIN_FREE_GB" >&2; exit 1; }

sec=$("$B/kubectl" get secret elma365-db-connections -n "$NS" -o json) || { echo "не прочитан секрет в $NS" >&2; exit 1; }
get() { printf '%s' "$sec" | jq -r ".data.$1 // empty" | base64 --decode; }
PSQL_URL=$(get PSQL_URL); MONGO_URL=$(get MONGO_URL)
S3_ADDR=$(get S3_BACKEND_ADDRESS); S3_KEY=$(get S3_KEY); S3_SECRET=$(get S3_SECRET)
S3_BUCKET=$(get S3_BUCKET); S3_SSL=$(get S3_SSL_ENABLED); S3_VHS=$(get S3_VIRTUAL_HOSTED_STYLE_ENABLED)
PG_DB=$(printf '%s' "$PSQL_URL" | sed 's|postgres://||' | awk -F@ '{print $2}' | awk -F'?' '{print $1}' | awk -F/ '{print $2}')
MONGO_DB=$(printf '%s' "$MONGO_URL" | sed 's|mongodb://||' | awk -F/ '{print $2}' | awk -F'?' '{print $1}')
MONGO_TLS=""; [[ $MONGO_URL == *"tls=true"* ]] && MONGO_TLS="--ssl --sslAllowInvalidCertificates"

redact() {
    awk -v k="$S3_KEY" -v s="$S3_SECRET" '
        function cut(line, x,   i, out) { if (x == "") return line; out = ""
            while ((i = index(line, x)) > 0) { out = out substr(line, 1, i - 1) "***"; line = substr(line, i + length(x)) }
            return out line }
        { gsub(/:\/\/[^\/@ \t"]+@/, "://***@"); print cut(cut($0, s), k) }'
}

cleanup() {
    "$B/mcc" alias remove "$ALIAS" >/dev/null 2>&1
    if [ "$KEEP" = 0 ] && [ -n "$OUT" ] && [ -d "$OUT" ]; then rm -rf "$OUT"; fi
}
trap cleanup EXIT
trap 'echo "прервано"; exit 130' INT TERM

mkdir -p "$OUT"
NICE="nice -n 10 ionice -c2 -n7"
echo "проба $ENV ($NS): базы $PG_DB / $MONGO_DB, бакет $S3_BUCKET, папка $OUT"
echo "ELMA не останавливается; базы и бакет только читаются"
RC=0; T_PG=0; T_MG=0; T_S3=0

for p in "${PARTS[@]}"; do
    t0=$(date +%s)
    case $p in
    pg)
        echo "--- pg_dump начат $(date +%T)"
        $NICE "$B/pg_dump" "$PSQL_URL" -C -c --if-exists -F directory -f "$OUT/$PG_DB" 2>"$OUT/pg.err"
        r=$?; T_PG=$(( $(date +%s) - t0 ))
        if [ -s "$OUT/pg.err" ]; then
            echo "!!! pg_dump писал в stderr — ночью бэкапер счёл бы это ошибкой и удалил копию:"
            head -n 20 "$OUT/pg.err" | redact; RC=1
        fi
        [ $r = 0 ] || { echo "!!! pg_dump rc=$r"; RC=1; }
        echo "pg: ${T_PG} с, $(du -sh "$OUT/$PG_DB" 2>/dev/null | cut -f1), таблиц с данными: $(grep -c 'TABLE DATA' <("$B/pg_restore" -l "$OUT/$PG_DB" 2>/dev/null))"
        ;;
    mongo)
        echo "--- mongodump начат $(date +%T)"
        # кавычки вокруг URI — ровно как в бэкапере (стр. 1470)
        st=$($NICE "$B/mongodump" $MONGO_TLS --uri \"$MONGO_URL\" --gzip --out "$OUT/mongo" 2>&1)
        T_MG=$(( $(date +%s) - t0 ))
        if [[ "$st" != *"done dumping"* ]]; then
            echo "!!! mongodump не дошёл до 'done dumping':"; printf '%s\n' "$st" | tail -n 20 | redact; RC=1
        fi
        echo "mongo: ${T_MG} с, $(du -sh "$OUT/mongo" 2>/dev/null | cut -f1), коллекций в дампе: $(find "$OUT/mongo" -name '*.bson.gz' | wc -l), папки баз: $(ls "$OUT/mongo" 2>/dev/null | tr '\n' ' ')"
        if [ -x "$B/mongosh" ]; then
            live=$("$B/mongosh" $MONGO_TLS "$MONGO_URL" --quiet --eval \
                'const s=db.stats(); print(db.getName()+" коллекций: "+db.getCollectionNames().length+", данных: "+Math.round(s.dataSize/1048576)+" МБ")' 2>&1 | tail -n 1)
            echo "mongo живая база: $(printf '%s' "$live" | redact)"
        fi
        ;;
    s3)
        echo "--- mcc mirror начат $(date +%T)"
        host=${S3_ADDR%%:*}; port=""; [[ $S3_ADDR == *:* ]] && port=${S3_ADDR#*:}
        scheme=http; sslopt=""; [ "$S3_SSL" = true ] && { scheme=https; sslopt="--insecure"; }
        style="-path=on"; [ "$S3_VHS" = true ] && style="-path=off"
        if ! "$B/mcc" alias set --quiet $sslopt "$ALIAS" "$scheme://$host:$port" "$S3_KEY" "$S3_SECRET" $style >/dev/null 2>&1; then
            echo "!!! mcc alias set не прошёл"; RC=1
        else
            mkdir -p "$OUT/s3/$S3_BUCKET"
            st=$($NICE "$B/mcc" mirror $sslopt "$ALIAS/$S3_BUCKET" "$OUT/s3/$S3_BUCKET" --insecure --remove --preserve --quiet 2>&1)
            T_S3=$(( $(date +%s) - t0 ))
            if [[ "$st" == *"mcc: <ERROR>"* ]]; then
                echo "!!! ошибки mirror (ночью бэкап бы не прервался, но копия S3 была бы неполной):"
                printf '%s\n' "$st" | grep -m 20 'ERROR' | redact; RC=1
            fi
            echo "s3: ${T_S3} с, $(du -sh "$OUT/s3" 2>/dev/null | cut -f1), файлов: $(find "$OUT/s3" -type f | wc -l)"
        fi
        ;;
    esac
done

echo "=== итог $ENV"
[ $T_PG -gt 0 ] || [ $T_MG -gt 0 ] && echo "простой ELMA ночью ≈ $(( (T_PG + T_MG) / 60 )) мин дампа баз + 2–5 мин остановка и подъём подов"
echo "всего ≈ $(( (T_PG + T_MG + T_S3) / 60 )) мин + 2–5 мин (окно до 00:55: 85 мин от 23:30)"
[ "$KEEP" = 1 ] && echo "копия оставлена: $OUT (удалить вручную)"
echo "результат: $([ $RC = 0 ] && echo OK || echo 'ЕСТЬ ОШИБКИ')"
exit $RC
