FROM node:24.22.1-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci && npm install --no-save --package-lock=false "@rolldown/binding-linux-x64-musl@$(node -p "require('rolldown/package.json').version")"
COPY . .
RUN npm run build

FROM node:24.22.1-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package*.json ./
RUN npm ci --omit=dev
RUN npm_root="$(npm root -g)" \
  && rm -rf "${npm_root}/npm" /usr/local/bin/npm /usr/local/bin/npx
COPY server.mjs ./
COPY authentik-admin.mjs ./
COPY mail-profile.mjs ./
COPY mailu-client.mjs ./
COPY src/it-department-model.js ./src/it-department-model.js
COPY --from=build /app/dist ./dist
EXPOSE 8080
CMD ["node", "server.mjs"]
