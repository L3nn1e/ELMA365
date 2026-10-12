# elma-backupper-run: ночной elma365-backupper по таймеру systemd

Ставится на deckhouse-master (root, SELinux enforcing). Разбор рисков и подготовка конфигов бэкапера: `runbooks/elma-backupper-review.md`.

Предварительно:
- `/var/storage/backup` на отдельном диске, конфиги `/opt/elma365/backupper/etc/config-dev` и `config-prod` созданы (KUBECONFIG, K8S_NS_APP, STORAGE_PATH=/var/storage/backup/<env>/, TMP_DIR=/var/storage/backup/<env>/tmp/);
- `/etc/elma-sleep/{dev,prod}.conf` на месте (обёртка берёт оттуда NS и kubectl).

```sh
install -m 755 elma-backupper-run.sh /usr/local/sbin/
install -m 644 elma-backupper@.service elma-backupper-dev.timer elma-backupper-prod.timer /etc/systemd/system/
restorecon -v /usr/local/sbin/elma-backupper-run.sh /etc/systemd/system/elma-backupper*
systemctl daemon-reload

# проверки как будет ночью (из-под systemd, без HOME из сессии), ничего не запускает
systemd-run --wait --pipe -p Environment=HOME=/root /usr/local/sbin/elma-backupper-run.sh dev -n
systemd-run --wait --pipe -p Environment=HOME=/root /usr/local/sbin/elma-backupper-run.sh prod -n

# первый боевой прогон dev днём, через тот же юнит (ELMA dev будет недоступна на время копии)
systemctl start elma-backupper@dev.service      # вернёт управление по окончании
journalctl -u elma-backupper@dev -n 50 --no-pager

# включить расписание
systemctl enable --now elma-backupper-dev.timer elma-backupper-prod.timer
systemctl list-timers 'elma-*'
```

Состояние и журналы:
- `systemctl status elma-backupper@prod` — последний запуск и код выхода (failed = копии нет или что-то не вернулось);
- `journalctl -u elma-backupper@prod` или файл `/var/log/elma-backupper-prod.log` (пароли вырезаны);
- реплики до запуска: `/var/lib/elma-backupper/<env>.replicas`.

Расписание: prod 23:30, dev 23:30:30 (ждёт конца prod по общему lock). Всё обязано закончиться к 00:55: в 01:00 elma-sleep усыпляет ELMA, а ZFS-снапшоты на elma-backend останавливают базы. Если бэкап не успевает, обёртка прерывает его и возвращает реплики; если до 00:55 осталось меньше 20 мин, не начинает (END_BY, MIN_WINDOW).

Остановить идущий бэкап: `systemctl stop elma-backupper@prod` — обёртка погасит бэкапер и вернёт реплики.

## Пробный дамп без остановки ELMA

`elma-backupper-probe.sh dev|prod [pg] [mongo] [s3] [-k]` снимает части теми же `pg_dump`, `mongodump` и `mcc`, с теми же ключами, что бэкапер, но **не трогает реплики**: базы и бакет только читаются. Показывает время каждой части, ошибки, из-за которых ночной бэкап не прошёл бы (любой stderr у pg_dump, нет `done dumping` у mongodump, ошибки mirror), и сравнивает MongoDB с живой базой. Пробная копия кладётся в `/var/storage/backup/<env>/tmp/probe-*` и по окончании удаляется (с `-k` остаётся). Не запускается, пока идёт бэкап (общий lock).

```sh
install -m 755 elma-backupper-probe.sh /usr/local/sbin/ && restorecon -v /usr/local/sbin/elma-backupper-probe.sh
elma-backupper-probe.sh prod 2>&1 | tee /root/probe-prod-$(date +%F).log
```

Нагрузка на elma-backend как у ночного бэкапа: читается вся база PostgreSQL, MongoDB и весь бакет MinIO.
