FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN if [ -f package-lock.json ]; then npm ci --omit=dev; else npm install --omit=dev; fi

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=8080
RUN addgroup -S twinbox && adduser -S twinbox -G twinbox
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
USER twinbox
EXPOSE 8080
CMD ["node", "src/server.mjs"]
