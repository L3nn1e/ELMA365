#!/bin/bash
# elma-backupper-run.sh dev|prod [-n]
# Ночной запуск вендорского elma365-backupper (backup all) на deckhouse-master
# со страховкой от того, что сам бэкапер не умеет:
#   * не стартует в окно elma-sleep и при спящей ELMA (бэкапер в конце делает
#     scale --replicas=1 --all и разбудил бы её);
#   * проверяет, что конфиг бэкапера смотрит в тот же namespace, что и окружение
#     (dev не уйдёт в prod и наоборот), и что на томах копий хватает места
#     (TMP_DIR и копии по умолчанию на /, а это диск мастера Kubernetes);
#   * запоминает реплики и после любого исхода (успех, ошибка, таймаут, kill)
#     возвращает ровно их и снимает заглушку с daemonset billing — у бэкапера нет
#     trap, при обрыве ELMA осталась бы в 0;
#   * ограничивает время работы (MAX_RUNTIME), убивая всю группу процессов;
#   * вырезает пароли из лога (в бэкапере set -x: URI баз и ключи S3 попадают в вывод);
#   * проверяет, что в новой копии есть все три части.
# -n: только проверки, бэкапер не запускается.
#
# Настройки kubectl и namespace берутся из /etc/elma-sleep/<env>.conf (тот же формат).
# Переопределяемые переменные (в /etc/elma-backupper/<env>.conf или окружением):
#   BACKUPPER_CONFIG  конфиг бэкапера, по умолчанию /opt/elma365/backupper/etc/config-<env>
#   MAX_RUNTIME       предел работы, сек (по умолчанию 3 ч)
#   END_BY            к этому времени бэкап обязан закончиться (по умолчанию 00:55:
#                     в 01:00 elma-sleep усыпляет ELMA, затем снапшоты останавливают базы)
#   MIN_WINDOW        если до END_BY осталось меньше, сек, — не начинать (по умолчанию 20 мин)
#   MIN_FREE_GB       свободно на томах копий перед стартом (dev 15, prod 60)
#   LOG               журнал, по умолчанию /var/log/elma-backupper-<env>.log
#
# Расписание: systemd, юнит elma-backupper@.service и таймеры elma-backupper-prod.timer
# (23:30:00) и elma-backupper-dev.timer (23:30:30): prod первым, dev ждёт его по общему lock.
# Всё должно закончиться до END_BY (00:55), иначе бэкап прерывается и реплики возвращаются.
set -uo pipefail
umask 077

usage() { echo "usage: $0 dev|prod [-n]" >&2; exit 64; }
[ $# -ge 1 ] || usage
ENV=$1; CHECK_ONLY=0
[ "${2:-}" = "-n" ] && CHECK_ONLY=1
case "$ENV" in dev|prod) ;; *) usage ;; esac

BACKUPPER=${BACKUPPER:-/opt/elma365/backupper/bin/elma365-backupper}
BACKUPPER_CONFIG=/opt/elma365/backupper/etc/config-$ENV
MAX_RUNTIME=10800
END_BY=00:55
MIN_WINDOW=1200
case "$ENV" in dev) MIN_FREE_GB=15 ;; prod) MIN_FREE_GB=60 ;; esac
LOG=/var/log/elma-backupper-$ENV.log
LOCK=/run/elma-backupper.lock
STATE_DIR=${ELMA_BACKUPPER_STATE_DIR:-/var/lib/elma-backupper}
SLEEP_CONF=${ELMA_SLEEP_CONF_DIR:-/etc/elma-sleep}/$ENV.conf
OWN_CONF=${ELMA_BACKUPPER_CONF_DIR:-/etc/elma-backupper}/$ENV.conf

NS="" KUBE_CONTEXT="" KUBECTL="" KUBECONFIG=""
[ -r "$SLEEP_CONF" ] || { echo "нет $SLEEP_CONF (NS, KUBECTL, KUBECONFIG)" >&2; exit 78; }
. "$SLEEP_CONF"
[ -r "$OWN_CONF" ] && . "$OWN_CONF"
KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
export KUBECONFIG
[ -n "$KUBECTL" ] || KUBECTL="/opt/deckhouse/bin/d8 k"
read -ra K <<< "$KUBECTL"
K+=(--request-timeout=60s -n "$NS")
[ -n "$KUBE_CONTEXT" ] && [ "$KUBE_CONTEXT" != current ] && K+=(--context="$KUBE_CONTEXT")

# весь вывод — в журнал (и в терминал при ручном запуске)
if [ "$CHECK_ONLY" -eq 0 ]; then
    touch "$LOG" && chmod 600 "$LOG"
    # терминал или systemd (журнал) — дублируем; иначе только в файл
    if [ -t 1 ] || [ -n "${INVOCATION_ID:-}" ]; then exec > >(tee -a "$LOG") 2>&1; else exec >>"$LOG" 2>&1; fi
fi
log() { echo "$(date '+%F %T') [$ENV] $*"; }
die() { log "ERROR: $*"; exit 1; }

# один бэкапер за раз на хосте
exec 9>"$LOCK"
flock -w 5400 9 || die "lock $LOCK занят больше 1.5 ч"

log "=== start (config $BACKUPPER_CONFIG, ns $NS, check-only $CHECK_ONLY)"

# окно до END_BY (ближайшее в будущем); предел работы не дальше него
now=$(date +%s)
end=$(date -d "today $END_BY" +%s) || die "END_BY=$END_BY не разобрать"
[ "$end" -gt "$now" ] || end=$((end + 86400))
left=$((end - now))
log "до $END_BY осталось $((left / 60)) мин"
[ "$left" -ge "$MIN_WINDOW" ] || die "до $END_BY меньше $((MIN_WINDOW / 60)) мин — не начинаю, чтобы не попасть в окно снапшотов"
[ "$left" -lt "$MAX_RUNTIME" ] && MAX_RUNTIME=$left

# ---------- проверки до любого изменения ----------
[ -x "$BACKUPPER" ] || die "нет $BACKUPPER"
[ -r "$BACKUPPER_CONFIG" ] || die "нет $BACKUPPER_CONFIG"

cfg() { (set +u; . "$BACKUPPER_CONFIG" >/dev/null 2>&1; eval "printf '%s' \"\${$1}\""); }
B_NS=$(cfg K8S_NS_APP); B_DST=$(cfg BACKUP_DST); B_STORAGE=$(cfg STORAGE_PATH); B_TMP=$(cfg TMP_DIR)
B_KCFG=$(cfg KUBECONFIG)
# под systemd нет HOME: при пустом KUBECONFIG бэкапер ищет /.kube/config и выходит
[ -n "$B_KCFG" ] && [ -r "$B_KCFG" ] || die "в $BACKUPPER_CONFIG KUBECONFIG пуст или файла нет: впишите /etc/kubernetes/admin.conf"
[ "$B_NS" = "$NS" ] || die "в $BACKUPPER_CONFIG K8S_NS_APP=$B_NS, а окружение $ENV — это $NS"
[ "$B_DST" = filesystem ] || die "ожидается BACKUP_DST=filesystem, в конфиге '$B_DST'"
[ -n "$B_STORAGE" ] && [ "$B_STORAGE" != / ] || die "STORAGE_PATH пуст или /"
[ -n "$B_TMP" ] && [ "$B_TMP" != / ] || die "TMP_DIR пуст или /"
mkdir -p "$B_STORAGE" "$B_TMP" || die "не создать $B_STORAGE / $B_TMP"

for d in "$B_STORAGE" "$B_TMP"; do
    read -r mp free <<< "$(df -P -BG "$d" | awk 'NR==2 {sub("G","",$4); print $6, $4}')"
    log "том $d: точка монтирования $mp, свободно ${free} ГБ (нужно ${MIN_FREE_GB})"
    [ "$free" -ge "$MIN_FREE_GB" ] || die "мало места на $mp для $d"
    [ "$mp" = / ] && log "WARNING: $d на корне мастера Kubernetes — переполнение уронит узел"
done

# юнит oneshot: во время сна он в состоянии activating, а не active
sleep_state=$(systemctl show -p ActiveState --value "elma-sleep@$ENV.service" 2>/dev/null)
if [[ "$sleep_state" =~ ^(active|activating|deactivating|reloading)$ ]]; then
    die "идёт elma-sleep@$ENV (окно ZFS-бэкапа) — бэкапер разбудил бы ELMA, не запускаю"
fi

mapfile -t DEPLOYS < <("${K[@]}" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}')
[ "${#DEPLOYS[@]}" -gt 0 ] || die "не получить список деплойментов в $NS"
running=$(printf '%s\n' "${DEPLOYS[@]}" | awk '$2 > 0' | wc -l)
log "деплойментов: ${#DEPLOYS[@]}, работающих: $running"
[ "$running" -gt 0 ] || die "ELMA в $NS спит (все реплики 0) — не запускаю"

if [ "$CHECK_ONLY" -eq 1 ]; then
    log "проверки пройдены, бэкапер не запускаю (-n)"
    exit 0
fi

# ---------- запоминаем реплики, возвращаем при любом исходе ----------
mkdir -p "$STATE_DIR"
STATE=$STATE_DIR/$ENV.replicas
printf '%s\n' "${DEPLOYS[@]}" > "$STATE"
BPID=""

restore_state() {
    local rc=0 name want cur
    trap - EXIT INT TERM HUP
    if [ -n "$BPID" ] && kill -0 "$BPID" 2>/dev/null; then
        log "останавливаю бэкапер (группа $BPID)"
        kill -TERM -- "-$BPID" 2>/dev/null; sleep 30; kill -KILL -- "-$BPID" 2>/dev/null
    fi
    while read -r name want; do
        cur=$("${K[@]}" get deploy "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null) || continue
        if [ "$cur" != "$want" ]; then
            log "реплики $name: $cur -> $want"
            "${K[@]}" scale deploy "$name" --replicas="$want" >/dev/null </dev/null || rc=1
        fi
    done < "$STATE"
    # бэкапер «выключает» billing несуществующим nodeSelector и при обрыве не снимает его
    if "${K[@]}" get daemonset billing -o jsonpath='{.spec.template.spec.nodeSelector}' 2>/dev/null | grep -q non-existing; then
        log "снимаю заглушку nodeSelector с daemonset billing"
        "${K[@]}" patch daemonset billing --type json \
            -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector/non-existing"}]' >/dev/null || rc=1
    fi
    [ "$rc" -eq 0 ] || log "ERROR: не всё удалось вернуть, проверьте: ${KUBECTL} -n $NS get deploy,ds"
    return $rc
}
trap 'restore_state; log "=== end rc=${RC:-1}"; exit ${RC:-1}' EXIT
trap 'log "сигнал, прерываю"; RC=1; exit 1' INT TERM HUP

# секреты для вырезания из лога (set -x бэкапера печатает их)
S3_KEY=$("${K[@]}" get secret elma365-db-connections -o jsonpath='{.data.S3_KEY}' 2>/dev/null | base64 -d 2>/dev/null)
S3_SECRET=$("${K[@]}" get secret elma365-db-connections -o jsonpath='{.data.S3_SECRET}' 2>/dev/null | base64 -d 2>/dev/null)
redact() {
    awk -v k="$S3_KEY" -v s="$S3_SECRET" '
        function cut(line, x,   i, out) { if (x == "") return line; out = ""
            while ((i = index(line, x)) > 0) { out = out substr(line, 1, i - 1) "***"; line = substr(line, i + length(x)) }
            return out line }
        { gsub(/:\/\/[^\/@ \t"]+@/, "://***@"); print cut(cut($0, s), k); fflush() }'
}

# ---------- бэкап ----------
before=$(ls -1d "${B_STORAGE%/}"/ELMA365_* 2>/dev/null | sort | tail -n 1)
START=$(date +%s)
log "запускаю: $BACKUPPER backup all --config $BACKUPPER_CONFIG (предел ${MAX_RUNTIME} с)"
cd /root || cd /
setsid "$BACKUPPER" backup all --config "$BACKUPPER_CONFIG" > >(redact) 2>&1 </dev/null &
BPID=$!
while kill -0 "$BPID" 2>/dev/null; do
    if [ $(( $(date +%s) - START )) -ge "$MAX_RUNTIME" ]; then
        log "ERROR: превышен предел ${MAX_RUNTIME} с"
        RC=1; exit 1        # restore_state убьёт группу и вернёт реплики
    fi
    sleep 10
done
wait "$BPID"; BRC=$?
BPID=""
log "бэкапер завершился с кодом $BRC за $(( $(date +%s) - START )) с"

# ---------- проверка копии ----------
after=$(ls -1d "${B_STORAGE%/}"/ELMA365_* 2>/dev/null | sort | tail -n 1)
RC=$BRC
if [ "$BRC" -eq 0 ]; then
    if [ -z "$after" ] || [ "$after" = "$before" ]; then
        log "ERROR: новая копия не появилась в $B_STORAGE"; RC=1
    else
        for part in mongo postgres s3; do
            [ -d "$after/$part" ] || { log "ERROR: в $after нет $part"; RC=1; }
        done
        find "$after/postgres" -name toc.dat 2>/dev/null | grep -q . || { log "ERROR: нет postgres/*/toc.dat"; RC=1; }
        find "$after/mongo" -name '*.bson.gz' 2>/dev/null | grep -q . || { log "ERROR: нет mongo/*/*.bson.gz"; RC=1; }
        # S3 бэкапер при ошибке mirror не прерывается; пустая папка s3 — не копия
        n3=$(find "$after/s3" -type f 2>/dev/null | wc -l)
        log "  s3: файлов $n3"
        [ "$n3" -gt 0 ] || { log "ERROR: папка s3 пустая"; RC=1; }
        du -sh "$after"/* 2>/dev/null | while read -r l; do log "  $l"; done
        [ "$RC" -eq 0 ] && log "копия $after в порядке"
    fi
fi
exit "$RC"
