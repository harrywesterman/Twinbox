FROM node:25-alpine

WORKDIR /opt/twinbox

COPY config ./config

RUN apk update \
  && apk add --no-cache ca-certificates curl iproute2 iputils-ping \
  && . /opt/twinbox/config/pinned-defaults.sh \
  && curl -fsSL "https://dl.k8s.io/release/${PINNED_KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /tmp/kubectl \
  && install -m 0755 /tmp/kubectl /usr/local/bin/kubectl \
  && chmod +x /usr/local/bin/kubectl \
  && rm -rf /tmp/kubectl \
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
