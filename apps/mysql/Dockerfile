FROM mysql:8.4.11

# MYSQL_ROOT_PASSWORD is supplied only at runtime by the deployment secret.
# Never bake credentials into the image or Docker build arguments.
COPY db/ /docker-entrypoint-initdb.d
