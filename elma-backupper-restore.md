# Восстановление ELMA из копии elma365-backupper

Копии лежат на deckhouse-master в `/var/storage/backup/<env>/ELMA365_<дата>`. В каждой три части: `postgres`, `mongo`, `s3`. Ниже порядок для dev. Для prod всё то же самое, но с `prod`, `mscelma365` и `config-prod`.

Восстановление **заменяет** текущие данные целиком: всё, что пользователи сделали после момента копии, пропадёт. Поэтому перед ним делается ZFS-снапшот, чтобы можно было вернуться.

Разбор кода восстановления: [elma-backupper-review.md](elma-backupper-review.md#восстановление-что-делает---cleanup-databases).

## Когда

Днём. Не в 23:00–02:00: в 23:30 стартует ночной бэкап, в 01:00 elma-sleep, в 01:15 и 01:30 снапшоты на elma-backend. Бэкапер при восстановлении не берёт lock обёртки, поэтому сам он с ночным бэкапом не разойдётся.

## Почему не одной командой `restore all`

`restore all` восстанавливает MongoDB и PostgreSQL, **поднимает ELMA**, и только потом зеркалит MinIO с `--remove` в боевой бакет. Файлы, загруженные в эти минуты, будут удалены, а часть ссылок временно не откроется. Для prod с 27 ГБ в MinIO окно заметное.

Поэтому делаем в два захода:
1. При остановленной ELMA восстанавливаем только `s3`. Эта часть кластер не трогает.
2. Затем `mongo,postgres`. Бэкапер сам держит ELMA в 0, восстанавливает обе базы и в конце поднимает все деплойменты в 1.

## Шаги

### 1. Точка возврата (elma-backend, root)

```sh
/usr/local/bin/elma-backup.sh -e dev
```

Дождаться `finished successfully`. Проверить, что новый набор консистентный:

```sh
/usr/local/bin/elma-restore.sh -e dev -l | tail -n 3     # последний набор должен быть YES
```

### 2. Выбрать копию (deckhouse-master, `sudo -i`)

```sh
ls -1d /var/storage/backup/dev/ELMA365_*
B=/var/storage/backup/dev/ELMA365_2026.10.12-12.17.45     # нужная копия, без / в конце
ls $B                                                     # mongo  postgres  s3
du -sh $B/*
```

### 3. Остановить ELMA и восстановить MinIO

```sh
/usr/local/sbin/elma-sleep.sh dev down                    # запоминает реплики и ставит 0
umask 077
LOG=/root/restore-dev-$(date +%F-%H%M).log
cd /opt/elma365/backupper
bin/elma365-backupper restore s3 --config etc/config-dev --backup-path $B 2>&1 | tee -a $LOG
```

В выводе будут видны пароли (в бэкапере включён `set -x`). Лог создаётся с правами 600, наружу его не пересылать; если нужно прислать, только хвост и строки с ошибками.

### 4. Восстановить MongoDB и PostgreSQL

```sh
bin/elma365-backupper restore mongo,postgres --config etc/config-dev --backup-path $B --cleanup-databases 2>&1 | tee -a $LOG
```

Что происходит: очистка и восстановление MongoDB, затем очистка и восстановление PostgreSQL, затем `scale --replicas=1` для всех деплойментов и ожидание готовности подов.

### 5. Проверить

```sh
grep -n -i -E 'error|failed|ignored on restore' $LOG | grep -v '0 document(s) failed' | tail -n 40
/opt/deckhouse/bin/d8 k -n elma365 get deploy | awk 'NR>1 && $2 !~ /^([0-9]+)\/\1$/'     # пусто = всё поднялось
/usr/local/sbin/elma-sleep.sh dev up                      # вернёт сохранённые реплики (сейчас все 1, ничего не изменится)
```

Строка `errors ignored on restore` бэкапер считает успехом. Если она есть, смотреть, какие именно ошибки выше неё: «already exists» после очистки допустимы, остальное надо разбирать.

Дальше зайти в ELMA и проверить данные на дату копии: последние записи, открываются ли файлы.

### 6. Если что-то не так: откат снапшотом (elma-backend)

```sh
/usr/local/sbin/elma-sleep.sh dev down                    # на deckhouse-master: остановить ELMA
/usr/local/bin/elma-restore.sh -e dev                     # на elma-backend: выбрать набор из шага 1
```

После отката поднять ELMA: `/usr/local/sbin/elma-sleep.sh dev up` на deckhouse-master.

Снапшот откатывает PostgreSQL, MongoDB и MinIO целиком, то есть возвращает всё в состояние до шага 3.

## Частичное восстановление

- Только MinIO: шаг 3, затем `elma-sleep.sh dev up`.
- Только одна база: `restore postgres` или `restore mongo` с `--cleanup-databases`. Бэкапер сам остановит и поднимет ELMA. Базы и файлы при этом окажутся из разных моментов, ELMA может показывать ссылки на несуществующие записи или файлы. Без необходимости так не делать.

## Первый раз

Только на dev, по решению Lenny, после шага 1. Restore на prod до учений на dev не запускать.
