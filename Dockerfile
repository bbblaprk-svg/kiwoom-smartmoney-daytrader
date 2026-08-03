# Upload this file as Dockerfile together with kiwoom-smartmoney-daytrader-v3.1.3-FINAL.zip.
FROM node:22-alpine AS build

RUN apk add --no-cache unzip
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1

COPY kiwoom-smartmoney-daytrader-v3.1.3-FINAL.zip /tmp/app.zip
RUN mkdir -p /tmp/source \
    && unzip -q /tmp/app.zip -d /tmp/source \
    && cp -a /tmp/source/kiwoom-smartmoney-daytrader-v3.1.3/. /app/ \
    && rm -rf /tmp/app.zip /tmp/source

RUN sha256sum -c SOURCE_MANIFEST.sha256
RUN npm config set registry https://registry.npmjs.org/ \
    && npm install --no-audit --no-fund
RUN npm run check && npm run check:load && npm run build

FROM node:22-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
RUN mkdir -p /app/data

COPY --from=build /app/package.json ./package.json
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/.next ./.next
COPY --from=build /app/public ./public
COPY --from=build /app/server.js ./server.js
COPY --from=build /app/next.config.js ./next.config.js
COPY --from=build /app/lib ./lib
COPY --from=build /app/worker ./worker
COPY --from=build /app/pages ./pages

VOLUME ["/app/data"]
EXPOSE 3000
CMD ["npm", "start"]
