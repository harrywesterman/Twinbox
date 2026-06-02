FROM node:24-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci && npm install --no-save --package-lock=false "@rolldown/binding-linux-x64-musl@$(node -p "require('rolldown/package.json').version")"
COPY . .
RUN npm run build

FROM node:24-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package*.json ./
RUN npm ci --omit=dev
COPY server.mjs ./
COPY authentik-admin.mjs ./
COPY --from=build /app/dist ./dist
EXPOSE 8080
CMD ["node", "server.mjs"]
