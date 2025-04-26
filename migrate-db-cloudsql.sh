#!/bin/bash

INSTANCE_ORIGIN=...
INSTANCE_INTERMEDIATE=...
INSTANCE_DESTINATION=...
POSTGRES_DEST_PASSWORD=...
PROJ_ID=...
BUCKET_MIGRATION=...
DBs=(...)
ROLES=(...)
DEVELOPER_ROLE=...
DEVELOPER_ROLE_PWD=...
USER_ROLE=...
USER_ROLE_PWD=...
POSTGRES_ORIGIN_PWD=...
KUBECTX=...
NAMESPACE=...

# GET PASSWORDS FOR EACH ROLE FOR EACH DB #
kubectx $KUBECTX
kubens $NAMESPACE
PASSWORDS=()
for ROLE in "${ROLES[@]}"
    PASSWORDS+=$(eval 'kubectl get secret ${ROLE}-user-credentials -o jsonpath="{.data.SPRING_DATASOURCE_PASSWORD}" | base64 --decode')
#echo $PASSWORDS

# SET PROJECT ID #
gcloud config set project $PROJ_ID
#gcloud auth login

# CREATE DEST INSTANCE #
terraform init
terraform apply --auto-approve # Previous step to create new IP range, it has to run in its entirety before the next cloning step

# CLONE ORIGIN INSTANCE #
gcloud sql instances clone $INSTANCE_ORIGIN $INSTANCE_INTERMEDIATE

# CREATE BUCKET AND ASSIGN PERMISSIONS TO IT #
SA_NAME_ORIGIN=$(gcloud sql instances describe $INSTANCE_INTERMEDIATE --format="value(serviceAccountEmailAddress)")
gcloud storage buckets create $BUCKET_MIGRATION
gsutil iam ch serviceAccount:${SA_NAME_ORIGIN}:objectAdmin $BUCKET_MIGRATION

# Query to fetch the table names from Search, necessary for next step # 
INTERMEDIATE_INSTANCE_IP=$(gcloud sql instances describe ${INSTANCE_INTERMEDIATE} --format="value(ipAddresses[0].ipAddress)")
query="SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname != 'pg_catalog' AND schemaname != 'information_schema' AND tablename NOT LIKE 'hsearch%';"
output=$(psql postgresql://postgres:${POSTGRES_ORIGIN_PWD}@${INTERMEDIATE_INSTANCE_IP}/search -A -t -c "$query")
TABLE_NAMES=()
while IFS= read -r line; do
    TABLE_NAMES+=("$line")
done <<< "$output"


# EXPORT DATABASES TO GCS #
for DB in "${DBs[@]}"; do
    if [[ $DB == "search" ]]; then
        for TABLE in "${TABLE_NAMES[@]}"; do
            gcloud sql export sql $INSTANCE_INTERMEDIATE ${BUCKET_MIGRATION}/${DB}-${TABLE}.sql --database=$DB --async -t ${TABLE}
            gcloud sql operations list --instance=$INSTANCE_INTERMEDIATE --filter='NOT status:done' --format='value(name)' | xargs -I {} gcloud sql operations wait {} --timeout=unlimited
        done
    else
        gcloud sql export sql $INSTANCE_INTERMEDIATE ${BUCKET_MIGRATION}/${DB}.sql --database=$DB --async
        gcloud sql operations list --instance=$INSTANCE_INTERMEDIATE --filter='NOT status:done' --format='value(name)' | xargs -I {} gcloud sql operations wait {} --timeout=unlimited
    fi
done

# DELETE INTERMEDIATE INSTANCE #
gcloud sql instances delete $INSTANCE_INTERMEDIATE

# DEST INSTANCE CONFIG #
gcloud sql users set-password postgres --instance=${INSTANCE_DESTINATION} --password=${POSTGRES_DEST_PASSWORD}
DEST_INSTANCE_IP=$(gcloud sql instances describe ${INSTANCE_DESTINATION} --format="value(ipAddresses[0].ipAddress)")

# ASSIGN PERMISSIONS TO BUCKET #
SA_NAME_DEST=$(gcloud sql instances describe $INSTANCE_DESTINATION --format="value(serviceAccountEmailAddress)")
gsutil iam ch serviceAccount:${SA_NAME_DEST}:objectAdmin $BUCKET_MIGRATION

# CREATE DEFAULT USERS # 
psql postgresql://postgres:${POSTGRES_DEST_PASSWORD}@${DEST_INSTANCE_IP}/postgres << EOF
    CREATE role '${DEVELOPER_ROLE}' login encrypted password '${DEVELOPER_ROLE_PWD}';
    CREATE role '${USER_ROLE}' login encrypted password '${USER_ROLE_PWD}';
EOF

# FUNCTION TO RUN SQL STATEMENTS #
function run_sql {
    psql postgresql://postgres:${POSTGRES_DEST_PASSWORD}@${DEST_INSTANCE_IP}/postgres << EOF
        CREATE database ${1};
        CREATE role "${3}" login encrypted password '${2}'; 
        GRANT ALL PRIVILEGES ON DATABASE ${1} to "${3}";
        GRANT "${3}" to postgres;

        GRANT USAGE ON SCHEMA public TO '${DEVELOPER_ROLE}';
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO '${DEVELOPER_ROLE}';
        GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO '${DEVELOPER_ROLE}';
        ALTER DEFAULT PRIVILEGES FOR ROLE "${3}" IN SCHEMA public GRANT SELECT ON SEQUENCES to '${DEVELOPER_ROLE}';
        ALTER DEFAULT PRIVILEGES FOR ROLE "${3}" IN SCHEMA public GRANT SELECT ON TABLES to '${DEVELOPER_ROLE}';
EOF
}

# CREATE DATABASES AND ROLES IN NEW DB
LEN_DBS=${#DBs[@]}
for ((i=1; i<=$LEN_DBS; i+=1)); do
    echo ${DBs[i]}
    run_sql ${DBs[i]} ${PASSWORDS[i]} ${ROLES[i]}
done

for ((i=1; i<=$LEN_DBS; i+=1)); do
  ALTER TABLE  OWNER TO new_role_name;
# IMPORT DATABASES FROM GCS #
for ((i=1; i<=$LEN_DBS; i+=1)); do
    echo ${DBs[i]}
    if [[ ${DBs[i]} == "search" ]]; then
        for TABLE in "${TABLE_NAMES[@]}"; do
            gcloud sql import sql $INSTANCE_DESTINATION ${BUCKET_MIGRATION}/${DBs[i]}-${TABLE}.sql --database=${DBs[i]} --user=${ROLES[i]} -q
        done
    else
        gcloud sql import sql $INSTANCE_DESTINATION ${BUCKET_MIGRATION}/${DBs[i]}.sql --database=${DBs[i]} --user=${ROLES[i]} -q
    fi
    sleep 10
done

# TABLES omitted, retry
for TABLE in "${TABLE_NAMES[@]}"; do
    gcloud sql import sql $INSTANCE_DESTINATION ${BUCKET_MIGRATION}/search-${TABLE}.sql --database=search --user=search -q
    sleep 10
done

# HIBERNATE-specific
psql postgresql://search:${PASSWORDS[7]}@${DEST_INSTANCE_IP}/search << EOF
    create table if not exists hsearch_outbox_event
            (
                id bigint not null primary key,
                entityname varchar(256),
                entityid varchar(256),
                entityidhash integer,
                payload oid,
                retries integer,
                processafter timestamp,
                status integer
            );

            create index if not exists entityidhash
                on hsearch_outbox_event (entityidhash);

            create index if not exists processafter
                on hsearch_outbox_event (processafter);

            create index if not exists status
                on hsearch_outbox_event (status);

            create table if not exists hsearch_agent
            (
                id bigint not null primary key,
                type integer,
                name varchar(255),
                expiration timestamp,
                state integer,
                totalshardcount integer,
                assignedshardindex integer,
                payload oid
            );

            create sequence hsearch_outbox_event_generator;

            create sequence hsearch_agent_generator;

            create sequence base_order_id_sequence start with 1;
            create sequence hibernate_sequence start with [REDACTED];
EOF

# IMPORT DATABASES FROM GCS #
for ((i=1; i<=$LEN_DBS; i+=1)); do
    echo ${DBs[i]}
    psql postgresql://${ROLES[i]}:${PASSWORDS[i]}@${DEST_INSTANCE_IP}/${DBs[i]} << EOF
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO '${USER_ROLE}';
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO '${USER_ROLE}';
        GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO '${USER_ROLE}';
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO '${USER_ROLE}';
EOF
done

# Delete migration bucket
gcloud storage rm --recursive $BUCKET_MIGRATION

# TODO: Delete the DBs from the old DB
