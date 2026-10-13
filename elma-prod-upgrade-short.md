# Обновление ELMA365 на prod: краткий порядок

Краткая версия [elma-prod-upgrade.md](elma-prod-upgrade.md): там подготовка, прогон на dev и откат. Все команды от root. На deckhouse-master `kubectl` — это алиас на `/opt/deckhouse/bin/d8 k`, `export KUBECONFIG=/etc/kubernetes/admin.conf`.

## 0. Перед началом (deckhouse-master)

```bash
helm list -n mscelma365                  # имя релиза и текущая версия чарта
helm history elma365 -n mscelma365       # ЗАПИСАТЬ номер текущей ревизии (для отката)
```

## 1. Приостановить ночные задачи prod

deckhouse-master:

```bash
systemctl stop elma-backupper-prod.timer elma-sleep-prod.timer
systemctl list-timers 'elma-*'           # prod-таймеров в списке быть не должно
```

elma-backend: в `/etc/crontab` закомментировать строку prod (`30 1 * * * root /usr/local/bin/elma-backup.sh -e prod`).

## 2. Логическая копия prod (deckhouse-master)

```bash
systemctl start elma-backupper@prod.service      # ждёт окончания: 13.10 днём шёл 36 мин, ELMA стояла ~30
systemctl status elma-backupper@prod.service     # Result: success
ls -1d /var/storage/backup/prod/ELMA365_* | tail -1
```

Унести копию из-под 7-дневной ротации (удалить вручную через несколько недель):

```bash
mkdir -p /var/storage/backup/preupgrade
mv /var/storage/backup/prod/ELMA365_<дата> /var/storage/backup/preupgrade/
du -sh /var/storage/backup/preupgrade/*          # около 33 ГБ
```

## 3. Остановить ELMA prod (deckhouse-master)

```bash
/usr/local/sbin/elma-sleep.sh prod down
kubectl -n mscelma365 get deploy | awk 'NR>1 && $2 != "0/0"'   # пусто = всё остановлено
```

## 4. ZFS-набор prod (elma-backend)

```bash
/usr/local/bin/elma-backup.sh -e prod >>/var/log/elma-prod-backup.log 2>&1   # именно в лог: по нему elma-restore.sh ставит YES
tail -5 /var/log/elma-prod-backup.log            # finished successfully
/usr/local/bin/elma-restore.sh -e prod -l        # последний набор YES; ЗАПИСАТЬ имя @automatic-<дата>
```

## 5. Поднять ELMA на старой версии (deckhouse-master)

```bash
/usr/local/sbin/elma-sleep.sh prod up
kubectl -n mscelma365 get deploy | awk 'NR>1 {split($2,a,"/"); if (a[1]!=a[2]) print}'   # пусто
```

Сразу после `up` все деплойменты 0/1: поды стартуют 3–5 минут. Повторять проверку, пока вывод не станет пустым.

Пользователи до конца окна ничего не вводят: при откате всё после шага 4 пропадёт.

## 6. Обновление по рекомендациям вендора (deckhouse-master)

По [статье вендора](https://elma365.com/ru/help/platform/version-update-enterprise.html): мажорные версии не пропускать, каждый шаг на последний минорный релиз. Запускать в tmux или screen.

```bash
V=<версия чарта этого шага>
helm upgrade elma365 elma365/elma365 -n mscelma365 -f values-prod.yaml \
  --version "$V" --timeout=30m --wait 2>&1 | tee helm-prod-$V.log
```

- `-n mscelma365` обязателен; `--install` из команды вендора не используем.
- `--timeout` равен `deploy.appconfig.migrateTimeout` в values, если его меняли.
- helm до конца ничего не выводит. Следить во втором окне:

```bash
helm status elma365 -n mscelma365      # pending-upgrade = идёт, deployed = готово, failed = упало
kubectl -n mscelma365 get pods -w
kubectl -n mscelma365 get deploy -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}{"\n"}{end}' | sed 's/.*://' | sort | uniq -c   # сколько уже на новой версии
```

После каждого шага:

```bash
helm list -n mscelma365                                                                 # STATUS deployed
kubectl -n mscelma365 get deploy | awk 'NR>1 {split($2,a,"/"); if (a[1]!=a[2]) print}'   # пусто
kubectl -n mscelma365 get pods | awk 'NR>1 && $3 != "Completed" {split($2,a,"/"); if (a[1]!=a[2]) print}'   # пусто
```

Проверить в интерфейсе: вход, новая версия, записи с вложениями, загрузка файла, шаг бизнес-процесса.

## 7. Включить ночные задачи (до 23:00)

deckhouse-master:

```bash
/usr/local/sbin/elma-backupper-probe.sh prod     # без ошибок; иначе таймер бэкапера не включать
systemctl start elma-backupper-prod.timer elma-sleep-prod.timer
systemctl list-timers 'elma-*'                   # четыре таймера: backupper и sleep для dev и prod
```

elma-backend: в `/etc/crontab` раскомментировать строку prod (`30 1 * * * root /usr/local/bin/elma-backup.sh -e prod`).

Наутро проверить, что ночью бэкапер, сон и снапшот prod отработали.

## Если что-то пошло не так

Одного `helm rollback` мало: миграции уже изменили базы. Порядок отката:

1. deckhouse-master: `/usr/local/sbin/elma-sleep.sh prod down`
2. elma-backend: `/usr/local/bin/elma-restore.sh -e prod`, выбрать набор из шага 4, корни jail'ов не откатывать
3. deckhouse-master: `helm rollback elma365 <ревизия из шага 0> -n mscelma365 --wait --timeout=30m`
4. Проверить, как в шаге 6, затем шаг 7

Подробности и запасной путь из копии бэкапера: раздел 5 в [elma-prod-upgrade.md](elma-prod-upgrade.md).

## Опыт 13 октября 2026

- Бэкапер днём шёл 36 минут, ELMA простаивала около 30 (ночью 20). Простой окна закладывать с запасом.
- `elma-backup.sh`, запущенный вручную без `>>/var/log/elma-prod-backup.log`, пишет только в терминал. Набор тогда получает `yes*`: откатиться можно, но без подтверждения остановки баз. Переснять с перенаправлением.
- `elma-sleep.sh` живёт на deckhouse-master, не на elma-backend.
- `systemctl start elma-backupper@prod` возвращает управление только по окончании; предел 3 ч или до 00:55. SIGKILL в журнале в конце — добивается `tee` логов, не ошибка.
