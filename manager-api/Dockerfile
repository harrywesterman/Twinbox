FROM node:20-bookworm-slim

ARG BW_VERSION=1.22.1

WORKDIR /opt/twinbox

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl iputils-ping unzip \
  && curl -fsSL "https://github.com/bitwarden/cli/releases/download/${BW_VERSION}/bw-linux-${BW_VERSION#v}.zip" -o /tmp/bw.zip \
  && unzip -q /tmp/bw.zip -d /tmp/bw \
  && install -m 0755 /tmp/bw/bw /usr/local/bin/bw \
  && bw --version \
  && rm -rf /tmp/bw /tmp/bw.zip \
  && rm -rf /var/lib/apt/lists/*

COPY manager-api/package.json ./manager-api/package.json
RUN cd /opt/twinbox/manager-api && npm install --omit=dev

COPY lib ./lib
COPY manager-api/src ./manager-api/src

WORKDIR /opt/twinbox/manager-api
EXPOSE 8080
CMD ["npm", "start"]
