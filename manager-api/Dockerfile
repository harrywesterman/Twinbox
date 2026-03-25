FROM node:20-alpine

ARG BW_VERSION=1.22.1

WORKDIR /opt/twinbox

RUN apk add --no-cache iputils curl unzip \
  && curl -fsSL "https://github.com/bitwarden/cli/releases/download/v${BW_VERSION}/bw-linux-${BW_VERSION}.zip" -o /tmp/bw.zip \
  && unzip -q /tmp/bw.zip -d /tmp/bw \
  && install -m 0755 /tmp/bw/bw /usr/local/bin/bw \
  && rm -rf /tmp/bw /tmp/bw.zip

COPY manager-api/package.json ./manager-api/package.json
RUN cd /opt/twinbox/manager-api && npm install --omit=dev

COPY lib ./lib
COPY manager-api/src ./manager-api/src

WORKDIR /opt/twinbox/manager-api
EXPOSE 8080
CMD ["npm", "start"]
