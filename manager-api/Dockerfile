FROM node:26-alpine

WORKDIR /opt/twinbox

RUN apk update \
  && apk add --no-cache ca-certificates curl iproute2 iputils-ping \
  && rm -rf /var/cache/apk/*

COPY manager-api/package.json ./manager-api/package.json
RUN cd /opt/twinbox/manager-api && npm install --omit=dev

COPY lib ./lib
COPY categories ./categories
COPY gitops ./gitops
COPY manager-web/src/assets/step-icons ./manager-web/src/assets/step-icons
COPY manager-api/src ./manager-api/src

WORKDIR /opt/twinbox/manager-api
EXPOSE 8080
CMD ["npm", "start"]
