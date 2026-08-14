# syntax=docker/dockerfile:1

FROM node:22-alpine AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY *.js .

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
EXPOSE 8080
COPY --from=builder /app /app
RUN addgroup -S roboshop && adduser -S roboshop -G roboshop && \
    rm -rf \
      /usr/local/lib/node_modules/npm \
      /usr/local/lib/node_modules/corepack \
      /opt/yarn* \
      /usr/local/bin/npm /usr/local/bin/npx \
      /usr/local/bin/yarn /usr/local/bin/corepack && \
    chown -R roboshop:roboshop /app
USER roboshop
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD node -e "require('http').get('http://127.0.0.1:8080/health',(r)=>{process.exit(r.statusCode===200?0:1)}).on('error',()=>process.exit(1))"
ENTRYPOINT ["node"]
CMD ["server.js"]
