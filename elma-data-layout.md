# Где лежат данные ELMA365 на FreeBSD-бэкенде

Источник: `elma-backup.sh -n` (dev 2026-10-10 13:30, prod 2026-10-10 13:37) и `zfs list` от Lenny.

| Компонент | Окр. | Jail | Путь в jail'е | Датасет | Данные (REFER) |
|---|---|---|---|---|---|
| PostgreSQL | prod | postgresql-prod | `/var/db/postgres/data16` (PG **16**) | `elma-zdata/db/postgresql-prod` | 12.5 ГБ |
| PostgreSQL WAL | prod | postgresql-prod | `/var/db/postgres/data16/pg_wal` | `elma-zdata/db/postgresql-prod/pg_wal` | 16 МБ |
| PostgreSQL | dev | postgresql-dev | `/var/db/postgres/data15` (PG **15**), WAL внутри | `elma-zdata/newdev/postgres-testing` | 32.3 ГБ |
| MongoDB | prod | mongodb-prod | `/var/db/mongodb` | `elma-zdata/db/mongodb-prod` | 4.9 ГБ |
| MongoDB | dev | mongodb-dev | `/var/db/mongodb` | `elma-zdata/newdev/mongodb-test` | 438 МБ |
| MinIO (файлы) | prod | minio-prod | `/var/lib/minio/data1/minio` | `elma-zdata/s3/minio-prod` | 26.9 ГБ |
| MinIO (файлы) | dev | minio-dev | `/var/lib/minio/data1/minio` | `elma-zdata/newdev/minio-test` | 147 МБ |
| Корни jail'ов | prod | *-prod | — | `zroot/jail/bsd/{postgresql,mongodb,minio}-prod` | — |
| Корни jail'ов | dev | *-dev | — | `zroot/jail/bsd/{postgresql,mongodb,minio}-dev` | 1.1–2.1 ГБ |
| Корень хоста | общий (снимает prod) | — | — | `zroot/ROOT/default` | — |

## Не используются сейчас

| Датасет | Окр. | Данные | Что это |
|---|---|---|---|
| `elma-zdata/db/postgresql-prod/pg_data` | prod | 96 КБ | пустой, остаток старой раскладки |
| `elma-zdata/db/postgresql-dev` | dev | 1.8 ГБ | старая раскладка dev, не смонтирован |
| `elma-zdata/db/mongodb-dev` | dev | 439 МБ | старая раскладка dev, не смонтирован |
| `elma-zdata/s3/minio-dev` | dev | 146 МБ | старая раскладка dev, не смонтирован |
| `elma-zdata/postgres-dev-preupd-preupd` | dev | 7.3 ГБ (USED) | копия перед обновлением 2026-09-07 |
| `elma-zdata/mongodb-dev-preupd-preupd` | dev | 2.1 ГБ (USED) | копия перед обновлением 2026-09-07 |
| `elma-zdata/backups/minio-dev-preupd-preupd` | dev | 0.7 ГБ (USED) | копия перед обновлением 2026-09-07 |
| `elma-zdata/db/postgresql-stash` | — | 96 КБ | ничей, пустой |

Вне этого сервера: сама ELMA, Redis и RabbitMQ работают в Deckhouse (Kubernetes); их тома здесь не учтены.
