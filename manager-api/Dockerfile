FROM node:20-bookworm-slim

WORKDIR /opt/twinbox

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl iproute2 iputils-ping \
  && rm -rf /var/lib/apt/lists/*

COPY manager-api/package.json ./manager-api/package.json
RUN cd /opt/twinbox/manager-api && npm install --omit=dev

COPY lib ./lib
COPY categories ./categories
COPY manager-api/src ./manager-api/src

WORKDIR /opt/twinbox/manager-api
EXPOSE 8080
CMD ["npm", "start"]
