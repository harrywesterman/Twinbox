FROM node:24.22.1-alpine AS build
WORKDIR /app/manager-web
COPY manager-web/package*.json ./
RUN npm install
COPY manager-web/ .
COPY lib/ /app/lib/
RUN npm run build

FROM nginx:1.31.7-alpine
RUN apk upgrade --no-cache
COPY manager-web/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/manager-web/dist /usr/share/nginx/html
EXPOSE 80
