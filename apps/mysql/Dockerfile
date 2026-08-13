FROM mysql:8.0

# MYSQL_ROOT_PASSWORD is supplied only at runtime by the deployment secret.
# Never bake credentials into the image or Docker build arguments.
COPY db/ /docker-entrypoint-initdb.d
