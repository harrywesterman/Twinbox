FROM node:26-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:26-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package*.json ./
RUN npm ci --omit=dev
COPY server.mjs ./
COPY authentik-admin.mjs ./
COPY --from=build /app/dist ./dist
EXPOSE 8080
CMD ["node", "server.mjs"]
