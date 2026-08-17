FROM mongo:7.0.40

# The official image bundles Go-built database CLI tools (bsondump, mongodump,
# mongorestore, mongoexport, mongoimport, mongofiles, mongostat, mongotop)
# that this application never uses. Each is a self-contained, statically linked
# Go 1.25.9 binary for which Trivy reports HIGH/CRITICAL Go stdlib CVEs.
#
# The official docker-entrypoint.sh and this deployment require only:
#   - mongod      (server, C++)
#   - mongosh     (shell, used by entrypoint to run /docker-entrypoint-initdb.d/*.js)
#   - gosu        (privilege drop in entrypoint)
#   - jq, js-yaml (entrypoint config parsing)
# None of the removed tools are referenced by the entrypoint, charts, scripts,
# backups (AWS Backup EBS snapshots), or health checks (TCP probes).
RUN rm -f \
    /usr/bin/bsondump \
    /usr/bin/mongodump \
    /usr/bin/mongorestore \
    /usr/bin/mongoexport \
    /usr/bin/mongoimport \
    /usr/bin/mongofiles \
    /usr/bin/mongostat \
    /usr/bin/mongotop

COPY *.js /docker-entrypoint-initdb.d/