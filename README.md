<p align="center">
  <img src="docs/images/banner.svg" alt="migrate-psql banner" width="900">
</p>

<h1 align="center">migrate-psql</h1>

<p align="center">A bash script that splits one Cloud SQL PostgreSQL 15 instance into two, database by database, through a clone and a bucket export.</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/GeiserX/migrate-psql" alt="License"></a>
</p>

---

The script creates the destination instance with Terraform, clones the origin instance, exports each database (the `search` database table by table) to a Cloud Storage bucket, then creates the databases and roles on the destination, imports the dumps and grants read access. Role passwords come from Kubernetes secrets. It needs `gcloud`, `gsutil`, `psql`, `terraform`, `kubectl`, `kubectx`, `kubens`, and your own Terraform config for the destination instance: the repository ships none, and the script runs `terraform init` and `terraform apply` in the directory you start it from.

## Quick start

```bash
curl -O https://raw.githubusercontent.com/GeiserX/migrate-psql/main/migrate-db-cloudsql.sh
$EDITOR migrate-db-cloudsql.sh   # fill in the variables at the top: instances, project, bucket, databases, roles
bash migrate-db-cloudsql.sh      # from the directory that holds your Terraform config
```

This is the record of one migration (a Spring application with a Hibernate Search database), not a general tool: it runs end to end with no confirmation prompts, and the Hibernate tables and sequences near the end are specific to that application. Read it and adapt it before pointing it at a production instance.

## License

[GPL-3.0-or-later](LICENSE)
