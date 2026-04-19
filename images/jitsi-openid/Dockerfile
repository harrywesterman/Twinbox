FROM rust:slim-bookworm AS builder

ARG JITSI_OPENID_REF=5a023e2eb51dfbeb551d04861c11f52e886b53d6

RUN update-ca-certificates

ENV USER=jitsi-openid
ENV UID=10001

RUN adduser \
  --disabled-password \
  --gecos "" \
  --home "/nonexistent" \
  --shell "/sbin/nologin" \
  --no-create-home \
  --uid "${UID}" \
  "${USER}"

RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  git \
  libssl-dev \
  pkg-config \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /jitsi-openid

RUN git clone https://github.com/MarcelCoding/jitsi-openid.git /jitsi-openid \
  && git checkout "${JITSI_OPENID_REF}"

COPY 0001-room-scoped-short-lived-jwt.patch /tmp/0001-room-scoped-short-lived-jwt.patch
RUN git apply /tmp/0001-room-scoped-short-lived-jwt.patch \
  && cargo build --release

FROM debian:bookworm-slim

ENV LISTEN_ADDR=0.0.0.0:3000
EXPOSE 3000

COPY --from=builder /etc/passwd /etc/passwd
COPY --from=builder /etc/group /etc/group

RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  libssl3 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /jitsi-openid

COPY --from=builder /jitsi-openid/target/release/jitsi-openid ./jitsi-openid

USER jitsi-openid:jitsi-openid

CMD ["/jitsi-openid/jitsi-openid"]
